package server

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/pane"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// paneGroupFixture seeds one workspace with three running sessions and one
// standalone terminal group with two, which is enough for every ownership and
// isolation rule.
func paneGroupFixture(t *testing.T) (*Service, string, []string) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	workspaceID := "workspace-1"
	terminalGroupID := "group-1"
	sessions := []string{"session-1", "session-2", "session-3", "session-4", "session-5"}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: "project-1", Name: "main", Kind: "main"}}
		value.TerminalGroups = []api.TerminalGroup{{ID: terminalGroupID, Name: "Inbox"}}
		for _, id := range sessions[:3] {
			value.Sessions = append(value.Sessions, api.Session{
				ID: id, WorkspaceID: workspaceID, Scope: api.SessionScopeWorkspace, Lifecycle: "running",
			})
		}
		for _, id := range sessions[3:] {
			value.Sessions = append(value.Sessions, api.Session{
				ID: id, TerminalGroupID: terminalGroupID, Scope: api.SessionScopeTerminalGroup, Lifecycle: "running",
			})
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return &Service{Store: state, Runtime: newMemoryRuntime(t)}, workspaceID, sessions
}

func TestCreatePaneGroupRequiresAnOwnedRunningSession(t *testing.T) {
	service, workspaceID, sessions := paneGroupFixture(t)

	group, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[0], "  left  ", "")
	if err != nil {
		t.Fatal(err)
	}
	if group.Name != "left" || group.Revision != 1 || group.Scope != api.SessionScopeWorkspace {
		t.Fatalf("unexpected group: %#v", group)
	}
	if group.OwnerID() != workspaceID || group.WorkspaceID != workspaceID {
		t.Fatalf("unexpected owner: %#v", group)
	}
	if len(pane.Leaves(&group.Tree)) != 1 || group.Tree.SessionID != sessions[0] {
		t.Fatalf("unexpected tree: %#v", group.Tree)
	}
	if group.Tree.PaneID == "" {
		t.Fatal("the Host must assign a pane id")
	}

	// The same Session cannot be shown twice, and a Session from another owner
	// cannot be placed here.
	if _, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[0], "", ""); err == nil ||
		!strings.HasPrefix(err.Error(), errPaneGroupSessionInUse) {
		t.Fatalf("second placement error = %v, want %s", err, errPaneGroupSessionInUse)
	}
	if _, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[3], "", ""); err == nil ||
		!strings.Contains(err.Error(), "does not belong") {
		t.Fatalf("foreign session error = %v", err)
	}
	if _, err := service.CreatePaneGroup(api.SessionScopeWorkspace, "missing", sessions[1], "", ""); err == nil ||
		!strings.Contains(err.Error(), "workspace not found") {
		t.Fatalf("missing owner error = %v", err)
	}
	if _, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, "missing", "", ""); err == nil ||
		!strings.HasPrefix(err.Error(), errPaneGroupSessionGone) {
		t.Fatalf("missing session error = %v", err)
	}
}

func TestUpdatePaneGroupGuardsTheRevision(t *testing.T) {
	service, workspaceID, sessions := paneGroupFixture(t)
	group, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[0], "", "")
	if err != nil {
		t.Fatal(err)
	}

	// A leaf without a pane id is assigned one by the Host.
	tree := api.PaneNode{
		Axis:   pane.AxisHorizontal,
		Ratio:  0.5,
		First:  &api.PaneNode{PaneID: group.Tree.PaneID, SessionID: sessions[0]},
		Second: &api.PaneNode{SessionID: sessions[1]},
	}
	updated, err := service.UpdatePaneGroup(group.ID, tree, group.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Revision != group.Revision+1 {
		t.Fatalf("revision = %d, want %d", updated.Revision, group.Revision+1)
	}
	leaves := pane.Leaves(&updated.Tree)
	if len(leaves) != 2 || leaves[0].PaneID != group.Tree.PaneID || leaves[1].PaneID == "" {
		t.Fatalf("unexpected leaves: %#v", leaves)
	}

	// The stale revision is the lost compare-and-swap, not a silent overwrite.
	if _, err := service.UpdatePaneGroup(group.ID, tree, group.Revision); err == nil ||
		!strings.HasPrefix(err.Error(), errPaneGroupRevConflict) {
		t.Fatalf("stale update error = %v, want %s", err, errPaneGroupRevConflict)
	}
	stored, ok := service.PaneGroup(group.ID)
	if !ok || stored.Revision != updated.Revision {
		t.Fatalf("a rejected update changed the group: %#v", stored)
	}

	// A ratio outside the interactive range is clamped, not rejected: a divider
	// drag is a geometry change, not a protocol violation.
	clamped, err := service.UpdatePaneGroup(group.ID, api.PaneNode{
		Axis:   pane.AxisHorizontal,
		Ratio:  0.99,
		First:  &api.PaneNode{PaneID: leaves[0].PaneID, SessionID: sessions[0]},
		Second: &api.PaneNode{PaneID: leaves[1].PaneID, SessionID: sessions[1]},
	}, updated.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if clamped.Tree.Ratio != pane.MaxRatio {
		t.Fatalf("ratio = %v, want %v", clamped.Tree.Ratio, pane.MaxRatio)
	}
}

func TestUpdatePaneGroupRejectsMalformedAndOverfullTrees(t *testing.T) {
	service, workspaceID, sessions := paneGroupFixture(t)
	group, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[0], "", "")
	if err != nil {
		t.Fatal(err)
	}

	// Five leaves exceed the visible-pane cap.
	leafSessions := append([]string{sessions[0]}, sessions[1:]...)
	tree := api.PaneNode{PaneID: "pane-0", SessionID: leafSessions[0]}
	lastPaneID := "pane-0"
	for index := 1; index < len(leafSessions); index++ {
		paneID := fmt.Sprintf("pane-%d", index)
		splitted, err := pane.Split(&tree, lastPaneID, pane.AxisHorizontal, false,
			api.PaneNode{PaneID: paneID, SessionID: leafSessions[index]})
		if err != nil {
			t.Fatal(err)
		}
		tree = *splitted
		lastPaneID = paneID
	}
	if _, err := service.UpdatePaneGroup(group.ID, tree, group.Revision); err == nil ||
		!strings.HasPrefix(err.Error(), errPaneGroupInvalidTree) {
		t.Fatalf("overfull tree error = %v, want %s", err, errPaneGroupInvalidTree)
	}

	// A Session shown twice in one tree is rejected outright.
	duplicate := api.PaneNode{
		Axis:   pane.AxisHorizontal,
		Ratio:  0.5,
		First:  &api.PaneNode{PaneID: "pane-a", SessionID: sessions[1]},
		Second: &api.PaneNode{PaneID: "pane-b", SessionID: sessions[1]},
	}
	if _, err := service.UpdatePaneGroup(group.ID, duplicate, group.Revision); err == nil ||
		!strings.HasPrefix(err.Error(), errPaneGroupInvalidTree) {
		t.Fatalf("duplicate tree error = %v, want %s", err, errPaneGroupInvalidTree)
	}

	// A Session already shown by another group cannot be stolen silently.
	other, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[1], "", "")
	if err != nil {
		t.Fatal(err)
	}
	steal := api.PaneNode{
		Axis:   pane.AxisHorizontal,
		Ratio:  0.5,
		First:  &api.PaneNode{PaneID: group.Tree.PaneID, SessionID: sessions[0]},
		Second: &api.PaneNode{SessionID: sessions[1]},
	}
	if _, err := service.UpdatePaneGroup(group.ID, steal, group.Revision); err == nil ||
		!strings.HasPrefix(err.Error(), errPaneGroupSessionInUse) {
		t.Fatalf("cross-group steal error = %v, want %s", err, errPaneGroupSessionInUse)
	}
	if stored, _ := service.PaneGroup(other.ID); pane.Count(&stored.Tree) != 1 {
		t.Fatalf("the other group changed: %#v", stored.Tree)
	}
}

func TestPaneGroupOrderingAndIsolation(t *testing.T) {
	service, workspaceID, sessions := paneGroupFixture(t)
	terminalGroupID := "group-1"

	first, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[0], "a", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[1], "b", "")
	if err != nil {
		t.Fatal(err)
	}
	foreign, err := service.CreatePaneGroup(api.SessionScopeTerminalGroup, terminalGroupID, sessions[3], "x", "")
	if err != nil {
		t.Fatal(err)
	}

	// Moving a group within its owner leaves every other group alone, byte for
	// byte: that is what "the dimensions do not affect each other" means.
	moved, err := service.MovePaneGroup(second.ID, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if moved.Order != 0 {
		t.Fatalf("order = %d, want 0", moved.Order)
	}
	groups := service.PaneGroups(workspaceID)
	if len(groups) != 2 || groups[0].ID != second.ID || groups[1].ID != first.ID {
		t.Fatalf("unexpected order: %#v", groups)
	}
	if groups[1].Revision != first.Revision {
		t.Fatalf("reordering changed a revision: %d -> %d", first.Revision, groups[1].Revision)
	}
	untouched, ok := service.PaneGroup(foreign.ID)
	if !ok || untouched.Order != 0 || untouched.Revision != foreign.Revision {
		t.Fatalf("another owner's group changed: %#v", untouched)
	}

	// A rename is not a tree change, so a divider drag in flight stays valid.
	renamed, err := service.RenamePaneGroup(first.ID, "main")
	if err != nil {
		t.Fatal(err)
	}
	if renamed.Name != "main" || renamed.Revision != first.Revision {
		t.Fatalf("rename changed the revision: %#v", renamed)
	}
}

func TestSessionLifecycleReconcilesOnlyItsOwnGroup(t *testing.T) {
	service, workspaceID, sessions := paneGroupFixture(t)
	terminalGroupID := "group-1"

	first, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[0], "", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[1], "", "")
	if err != nil {
		t.Fatal(err)
	}
	foreign, err := service.CreatePaneGroup(api.SessionScopeTerminalGroup, terminalGroupID, sessions[3], "", "")
	if err != nil {
		t.Fatal(err)
	}

	// A Session that ends loses its pane; a group that loses its last pane is
	// deleted, and no other group's revision moves.
	service.markEnded(sessions[0])
	if _, ok := service.PaneGroup(first.ID); ok {
		t.Fatal("a group whose last session ended must be deleted")
	}
	if stored, ok := service.PaneGroup(second.ID); !ok || stored.Revision != second.Revision {
		t.Fatalf("an unrelated group changed: %#v", stored)
	}
	if stored, ok := service.PaneGroup(foreign.ID); !ok || stored.Revision != foreign.Revision {
		t.Fatalf("another owner's group changed: %#v", stored)
	}

	// Moving a Session out of its owner drops its pane from that owner's group.
	split, err := service.UpdatePaneGroup(second.ID, api.PaneNode{
		Axis:   pane.AxisHorizontal,
		Ratio:  0.5,
		First:  &api.PaneNode{PaneID: second.Tree.PaneID, SessionID: sessions[1]},
		Second: &api.PaneNode{SessionID: sessions[2]},
	}, second.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.MoveSessionWithExpectations(
		t.Context(), sessions[2], "", terminalGroupID, SessionMoveExpectations{},
	); err != nil {
		t.Fatal(err)
	}
	after, ok := service.PaneGroup(second.ID)
	if !ok {
		t.Fatal("the group lost its remaining pane")
	}
	if got := pane.Sessions(&after.Tree); len(got) != 1 || got[0] != sessions[1] {
		t.Fatalf("sessions = %v, want [%s]", got, sessions[1])
	}
	if after.Revision != split.Revision+1 {
		t.Fatalf("revision = %d, want %d", after.Revision, split.Revision+1)
	}

	// Deleting the Session behaves like an ended Session.
	if err := service.DeleteSession(t.Context(), sessions[1]); err != nil {
		t.Fatal(err)
	}
	if _, ok := service.PaneGroup(second.ID); ok {
		t.Fatal("a group whose last session was deleted must be deleted")
	}
}

func TestReconcileDropsGroupsOfRemovedOwners(t *testing.T) {
	service, workspaceID, sessions := paneGroupFixture(t)
	if _, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessions[0], "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreatePaneGroup(api.SessionScopeTerminalGroup, "group-1", sessions[3], "", ""); err != nil {
		t.Fatal(err)
	}

	state := service.Store.Snapshot()
	state.Workspaces = nil
	if !reconcilePaneGroups(&state) {
		t.Fatal("expected the removed owner's groups to be reconciled away")
	}
	if len(state.PaneGroups) != 1 || state.PaneGroups[0].OwnerID() != "group-1" {
		t.Fatalf("unexpected groups: %#v", state.PaneGroups)
	}
}

func TestPaneGroupLimitIsEnforcedPerOwner(t *testing.T) {
	service, workspaceID, sessions := paneGroupFixture(t)
	for index := 0; index < pane.MaxGroupsPerOwner; index++ {
		sessionID := ""
		if index < 3 {
			sessionID = sessions[index]
		} else {
			sessionID = fmt.Sprintf("session-extra-%d", index)
			if err := service.Store.Update(func(value *api.State) error {
				value.Sessions = append(value.Sessions, api.Session{
					ID: sessionID, WorkspaceID: workspaceID, Scope: api.SessionScopeWorkspace, Lifecycle: "running",
				})
				return nil
			}); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, sessionID, "", ""); err != nil {
			t.Fatalf("create %d: %v", index, err)
		}
	}
	// The ninth arrangement of one owner is refused, and the refusal happens
	// before the Session is considered: the limit is about the owner.
	if err := service.Store.Update(func(value *api.State) error {
		value.Sessions = append(value.Sessions, api.Session{
			ID: "session-overflow", WorkspaceID: workspaceID, Scope: api.SessionScopeWorkspace, Lifecycle: "running",
		})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreatePaneGroup(api.SessionScopeWorkspace, workspaceID, "session-overflow", "", ""); err == nil ||
		!strings.HasPrefix(err.Error(), errPaneGroupLimit) {
		t.Fatalf("limit error = %v, want %s", err, errPaneGroupLimit)
	}
}

func TestRosterDeltaCarriesOnlyTheChangedPaneGroup(t *testing.T) {
	before := api.State{
		PaneGroups: []api.PaneGroup{
			{ID: "group-a", WorkspaceID: "workspace-1", Revision: 1, Tree: api.PaneNode{PaneID: "pane-a", SessionID: "session-1"}},
			{ID: "group-b", WorkspaceID: "workspace-1", Revision: 4, Tree: api.PaneNode{PaneID: "pane-b", SessionID: "session-2"}},
		},
	}
	after := before
	after.PaneGroups = []api.PaneGroup{
		before.PaneGroups[0],
		{ID: "group-b", WorkspaceID: "workspace-1", Revision: 5, Tree: api.PaneNode{PaneID: "pane-b", SessionID: "session-2"}},
	}
	after.PaneGroups[1].Tree = api.PaneNode{
		Axis:   pane.AxisHorizontal,
		Ratio:  0.5,
		First:  &api.PaneNode{PaneID: "pane-b", SessionID: "session-2"},
		Second: &api.PaneNode{PaneID: "pane-c", SessionID: "session-3"},
	}
	delta := makeRosterDelta(before, after, 1, 2)
	if delta.PaneGroups == nil {
		t.Fatal("expected a pane group delta")
	}
	if len(delta.PaneGroups.Upsert) != 1 || delta.PaneGroups.Upsert[0].ID != "group-b" {
		t.Fatalf("unexpected upsert: %#v", delta.PaneGroups.Upsert)
	}
	if len(delta.PaneGroups.Remove) != 0 {
		t.Fatalf("unexpected removals: %#v", delta.PaneGroups.Remove)
	}
	if delta.Sessions != nil || delta.Workspaces != nil || delta.Groups != nil {
		t.Fatalf("unrelated entities travelled: %#v", delta)
	}

	encoded, err := json.Marshal(delta.PaneGroups.Upsert[0].Tree)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"sessionId":"session-3"`) {
		t.Fatalf("tree did not encode its sessions: %s", encoded)
	}

	// A removal travels as an ID, so a client can drop the arrangement without
	// needing the tree it used to have.
	after.PaneGroups = after.PaneGroups[:1]
	removal := makeRosterDelta(before, after, 1, 2)
	if removal.PaneGroups == nil || len(removal.PaneGroups.Remove) != 1 || removal.PaneGroups.Remove[0] != "group-b" {
		t.Fatalf("unexpected removal delta: %#v", removal.PaneGroups)
	}
}

func TestPaneGroupsSurviveAStoreRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	state, err := store.Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = []api.Workspace{{ID: "workspace-1", ProjectID: "project-1", Name: "main", Kind: "main"}}
		value.Sessions = []api.Session{{ID: "session-1", WorkspaceID: "workspace-1", Scope: api.SessionScopeWorkspace, Lifecycle: "running"}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	created, err := service.CreatePaneGroup(api.SessionScopeWorkspace, "workspace-1", "session-1", "left", "")
	if err != nil {
		t.Fatal(err)
	}

	reopened, err := store.Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	restarted := &Service{Store: reopened}
	stored, ok := restarted.PaneGroup(created.ID)
	if !ok {
		t.Fatal("the arrangement did not survive a restart")
	}
	if stored.Name != "left" || stored.Revision != created.Revision || !samePaneNode(&stored.Tree, &created.Tree) {
		t.Fatalf("restored group differs: %#v", stored)
	}
	if schema := reopened.Snapshot().Schema; schema != 4 {
		t.Fatalf("schema = %d, want 4", schema)
	}
}
