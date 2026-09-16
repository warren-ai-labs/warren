package server

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/pane"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// Pane Groups are durable Host state: one whole-screen arrangement of running
// Sessions per group, any number of groups per Workspace or Terminal Group.
//
// The rules live here rather than in a client because the Host is the only
// authority both the arrangement and the Sessions can be validated against. A
// client stores only which group it is looking at and which pane has focus.
//
// Error messages carry a stable prefix so a script can tell the cases apart
// without parsing prose:
//
//	pane group not found: <id>
//	pane group revision conflict: ...
//	pane group invalid tree: ...
//	pane group session not found: <id>
//	pane group session in use: <id>
//	pane group limit reached: ...
const (
	errPaneGroupNotFound     = "pane group not found"
	errPaneGroupRevConflict  = "pane group revision conflict"
	errPaneGroupInvalidTree  = "pane group invalid tree"
	errPaneGroupSessionGone  = "pane group session not found"
	errPaneGroupSessionInUse = "pane group session in use"
	errPaneGroupLimit        = "pane group limit reached"
)

// PaneGroups returns the groups of one owner in draw order. The CLI reads the
// roster instead; this is for the Host's own projections and tests.
func (s *Service) PaneGroups(ownerID string) []api.PaneGroup {
	state := s.Store.Snapshot()
	result := make([]api.PaneGroup, 0, len(state.PaneGroups))
	for _, group := range state.PaneGroups {
		if group.OwnerID() == ownerID {
			result = append(result, group)
		}
	}
	sortPaneGroups(result)
	return result
}

// PaneGroup returns one group by ID.
func (s *Service) PaneGroup(id string) (api.PaneGroup, bool) {
	for _, group := range s.Store.Snapshot().PaneGroups {
		if group.ID == id {
			return group, true
		}
	}
	return api.PaneGroup{}, false
}

// CreatePaneGroup opens a single-pane arrangement around an existing Session.
// A group never exists without a pane: an empty arrangement would have nothing
// to render and nothing to own.
func (s *Service) CreatePaneGroup(ownerScope, ownerID, sessionID, name, before string) (api.PaneGroup, error) {
	name = strings.TrimSpace(name)
	if len(name) > pane.MaxNameLength {
		return api.PaneGroup{}, fmt.Errorf("%s: name is longer than %d characters", errPaneGroupInvalidTree, pane.MaxNameLength)
	}
	var created api.PaneGroup
	err := s.Store.Update(func(value *api.State) error {
		normalizedScope, err := paneGroupOwner(value, ownerScope, ownerID)
		if err != nil {
			return err
		}
		if err := validatePaneGroupSession(value, sessionID, normalizedScope, ownerID, ""); err != nil {
			return err
		}
		if count := len(paneGroupsOf(value, ownerID)); count >= pane.MaxGroupsPerOwner {
			return fmt.Errorf("%s: %s already holds %d groups", errPaneGroupLimit, ownerID, count)
		}
		now := time.Now().UTC()
		group := api.PaneGroup{
			ID:        store.NewID(),
			Scope:     normalizedScope,
			Name:      name,
			Tree:      api.PaneNode{PaneID: store.NewID(), SessionID: sessionID},
			Revision:  1,
			CreatedAt: now,
			UpdatedAt: now,
		}
		if normalizedScope == api.SessionScopeTerminalGroup {
			group.TerminalGroupID = ownerID
		} else {
			group.WorkspaceID = ownerID
		}
		value.PaneGroups = append(value.PaneGroups, group)
		if err := reorderPaneGroups(value, group.ID, before); err != nil {
			return err
		}
		created = value.PaneGroups[indexOfPaneGroup(value, group.ID)]
		return nil
	})
	if err != nil {
		return api.PaneGroup{}, err
	}
	return created, nil
}

// RenamePaneGroup sets the optional user label. A rename is not a tree change,
// so it leaves Revision alone: a divider drag in flight stays valid.
func (s *Service) RenamePaneGroup(id, name string) (api.PaneGroup, error) {
	name = strings.TrimSpace(name)
	if len(name) > pane.MaxNameLength {
		return api.PaneGroup{}, fmt.Errorf("%s: name is longer than %d characters", errPaneGroupInvalidTree, pane.MaxNameLength)
	}
	var renamed api.PaneGroup
	err := s.Store.Update(func(value *api.State) error {
		index := indexOfPaneGroup(value, id)
		if index < 0 {
			return fmt.Errorf("%s: %s", errPaneGroupNotFound, id)
		}
		value.PaneGroups[index].Name = name
		value.PaneGroups[index].UpdatedAt = time.Now().UTC()
		renamed = value.PaneGroups[index]
		return nil
	})
	if err != nil {
		return api.PaneGroup{}, err
	}
	return renamed, nil
}

// MovePaneGroup reorders one group among its owner's groups. Other owners and
// other groups keep their identity, revision, and tree.
func (s *Service) MovePaneGroup(id, before string) (api.PaneGroup, error) {
	var moved api.PaneGroup
	err := s.Store.Update(func(value *api.State) error {
		if indexOfPaneGroup(value, id) < 0 {
			return fmt.Errorf("%s: %s", errPaneGroupNotFound, id)
		}
		if err := reorderPaneGroups(value, id, before); err != nil {
			return err
		}
		moved = value.PaneGroups[indexOfPaneGroup(value, id)]
		return nil
	})
	if err != nil {
		return api.PaneGroup{}, err
	}
	return moved, nil
}

// RemovePaneGroup deletes an arrangement. The Sessions it showed keep running
// and stay reachable as ordinary Tabs: a layout edit never ends a process.
func (s *Service) RemovePaneGroup(id string) error {
	if err := s.Store.Update(func(value *api.State) error {
		index := indexOfPaneGroup(value, id)
		if index < 0 {
			return fmt.Errorf("%s: %s", errPaneGroupNotFound, id)
		}
		value.PaneGroups = append(value.PaneGroups[:index:index], value.PaneGroups[index+1:]...)
		return nil
	}); err != nil {
		return err
	}
	return nil
}

// UpdatePaneGroup replaces one group's tree. This is the only structural
// mutator: splitting, closing a pane, placing a Session into a pane, and
// dragging a divider are all one tree replacement, guarded by the revision the
// caller observed.
//
// An incoming leaf without a Pane ID is assigned one here, because pane
// identity belongs to the Host: two clients that split at the same moment must
// not be able to invent the same identity.
func (s *Service) UpdatePaneGroup(id string, tree api.PaneNode, expectedRevision uint64) (api.PaneGroup, error) {
	var updated api.PaneGroup
	err := s.Store.Update(func(value *api.State) error {
		index := indexOfPaneGroup(value, id)
		if index < 0 {
			return fmt.Errorf("%s: %s", errPaneGroupNotFound, id)
		}
		group := value.PaneGroups[index]
		if expectedRevision != group.Revision {
			return fmt.Errorf("%s: group %s is at revision %d, caller expected %d; refresh the roster and retry",
				errPaneGroupRevConflict, id, group.Revision, expectedRevision)
		}
		candidate := clonePaneNode(&tree)
		pane.Normalize(candidate)
		pane.AssignPaneIDs(candidate, store.NewID)
		if err := pane.ValidateStructure(candidate); err != nil {
			return fmt.Errorf("%s: %w", errPaneGroupInvalidTree, err)
		}
		for _, leaf := range pane.Leaves(candidate) {
			if err := validatePaneGroupSession(value, leaf.SessionID, group.OwnerScope(), group.OwnerID(), id); err != nil {
				return err
			}
		}
		group.Tree = *candidate
		group.Revision++
		group.UpdatedAt = time.Now().UTC()
		value.PaneGroups[index] = group
		updated = group
		return nil
	})
	if err != nil {
		return api.PaneGroup{}, err
	}
	return updated, nil
}

// reconcilePaneGroups prunes every arrangement against the state's own Sessions
// and owners. It is the only reconciler, so a leaf can never disagree with the
// Session it shows on the wire, in state.json, or in a renderer.
//
// It reports whether anything changed, because the caller must not rewrite the
// state file once per tick for a steady Host.
func reconcilePaneGroups(state *api.State) bool {
	if len(state.PaneGroups) == 0 {
		return false
	}
	live := make(map[string]api.Session, len(state.Sessions))
	for _, session := range state.Sessions {
		if session.Lifecycle == "running" {
			live[session.ID] = session
		}
	}
	workspaces := make(map[string]struct{}, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		workspaces[workspace.ID] = struct{}{}
	}
	groups := make(map[string]struct{}, len(state.TerminalGroups))
	for _, group := range state.TerminalGroups {
		groups[group.ID] = struct{}{}
	}
	ordered := make([]api.PaneGroup, len(state.PaneGroups))
	copy(ordered, state.PaneGroups)
	sortPaneGroups(ordered)

	claimed := make(map[string]string, len(live))
	kept := make([]api.PaneGroup, 0, len(ordered))
	changed := false
	for _, group := range ordered {
		ownerID := group.OwnerID()
		ownerGone := ownerID == ""
		if !ownerGone {
			if group.OwnerScope() == api.SessionScopeTerminalGroup {
				_, known := groups[ownerID]
				ownerGone = !known
			} else {
				_, known := workspaces[ownerID]
				ownerGone = !known
			}
		}
		if ownerGone {
			changed = true
			continue
		}
		tree := *clonePaneNode(&group.Tree)
		// A Session claimed by an earlier group is dropped here rather than
		// rendered twice: one arrangement owns a Session at a time.
		reconciled := pane.Reconcile(&tree, func(sessionID string) bool {
			session, ok := live[sessionID]
			if !ok {
				return false
			}
			if !sessionBelongsToOwner(session, group.OwnerScope(), ownerID) {
				return false
			}
			if _, taken := claimed[sessionID]; taken {
				return false
			}
			return true
		})
		if reconciled == nil {
			changed = true
			continue
		}
		for _, leaf := range pane.Leaves(reconciled) {
			claimed[leaf.SessionID] = group.ID
		}
		if !samePaneNode(reconciled, &group.Tree) {
			group.Tree = *reconciled
			group.Revision++
			group.UpdatedAt = time.Now().UTC()
			changed = true
		}
		kept = append(kept, group)
	}
	if !changed && len(kept) == len(state.PaneGroups) {
		return false
	}
	state.PaneGroups = kept
	return true
}

// paneGroupOwner validates the owner and returns its normalized scope.
func paneGroupOwner(state *api.State, ownerScope, ownerID string) (string, error) {
	ownerID = strings.TrimSpace(ownerID)
	if ownerID == "" {
		return "", errors.New("pane group requires a workspace or terminal group")
	}
	switch ownerScope {
	case api.SessionScopeWorkspace:
		if !workspaceExists(state, ownerID) {
			return "", fmt.Errorf("workspace not found: %s", ownerID)
		}
		return api.SessionScopeWorkspace, nil
	case api.SessionScopeTerminalGroup:
		if !terminalGroupExists(state, ownerID) {
			return "", fmt.Errorf("terminal group not found: %s", ownerID)
		}
		return api.SessionScopeTerminalGroup, nil
	default:
		return "", fmt.Errorf("unknown pane group owner scope %q", ownerScope)
	}
}

// validatePaneGroupSession checks that one Session may be shown by one group of
// this owner. ignoreGroup exempts the group being updated: its own panes are
// not "in use" by itself.
func validatePaneGroupSession(state *api.State, sessionID, ownerScope, ownerID, ignoreGroup string) error {
	session, ok := sessionOfState(state, sessionID)
	if !ok || session.Lifecycle != "running" {
		return fmt.Errorf("%s: %s", errPaneGroupSessionGone, sessionID)
	}
	if !sessionBelongsToOwner(session, ownerScope, ownerID) {
		return fmt.Errorf("pane group session %s does not belong to %s", sessionID, ownerID)
	}
	for _, group := range state.PaneGroups {
		if group.ID == ignoreGroup {
			continue
		}
		for _, leaf := range pane.Leaves(&group.Tree) {
			if leaf.SessionID == sessionID {
				return fmt.Errorf("%s: %s is already shown by pane group %s", errPaneGroupSessionInUse, sessionID, group.ID)
			}
		}
	}
	return nil
}

func sessionBelongsToOwner(session api.Session, ownerScope, ownerID string) bool {
	if ownerScope == api.SessionScopeTerminalGroup {
		return session.TerminalGroupID == ownerID
	}
	return session.WorkspaceID == ownerID
}

func sessionOfState(state *api.State, id string) (api.Session, bool) {
	for _, session := range state.Sessions {
		if session.ID == id {
			return session, true
		}
	}
	return api.Session{}, false
}

func paneGroupsOf(state *api.State, ownerID string) []api.PaneGroup {
	result := make([]api.PaneGroup, 0, len(state.PaneGroups))
	for _, group := range state.PaneGroups {
		if group.OwnerID() == ownerID {
			result = append(result, group)
		}
	}
	return result
}

func indexOfPaneGroup(state *api.State, id string) int {
	for index := range state.PaneGroups {
		if state.PaneGroups[index].ID == id {
			return index
		}
	}
	return -1
}

// reorderPaneGroups moves one group to sit before another of its owner, or to
// the end when before is empty, then renumbers the owner's Order values. Groups
// of other owners are never touched.
func reorderPaneGroups(state *api.State, id, before string) error {
	index := indexOfPaneGroup(state, id)
	if index < 0 {
		return fmt.Errorf("%s: %s", errPaneGroupNotFound, id)
	}
	group := state.PaneGroups[index]
	owner := group.OwnerID()
	peers := paneGroupsOf(state, owner)
	sortPaneGroups(peers)
	target := len(peers)
	if before != "" {
		found := false
		for position := range peers {
			if peers[position].ID == before {
				target = position
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("pane group move target not found: %s", before)
		}
	}
	reordered := make([]api.PaneGroup, 0, len(peers))
	for _, peer := range peers {
		if peer.ID != id {
			reordered = append(reordered, peer)
		}
	}
	if target > len(reordered) {
		target = len(reordered)
	}
	reordered = append(reordered, api.PaneGroup{})
	copy(reordered[target+1:], reordered[target:])
	reordered[target] = group
	for position := range reordered {
		reordered[position].Order = position
	}
	rebuildPaneGroups(state, owner, reordered)
	return nil
}

// rebuildPaneGroups replaces one owner's groups in place while leaving every
// other owner's entries where they were.
func rebuildPaneGroups(state *api.State, ownerID string, updated []api.PaneGroup) {
	next := make([]api.PaneGroup, 0, len(state.PaneGroups))
	inserted := false
	for _, group := range state.PaneGroups {
		if group.OwnerID() != ownerID {
			next = append(next, group)
			continue
		}
		if !inserted {
			next = append(next, updated...)
			inserted = true
		}
	}
	state.PaneGroups = next
}

func sortPaneGroups(groups []api.PaneGroup) {
	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Order != groups[j].Order {
			return groups[i].Order < groups[j].Order
		}
		if !groups[i].CreatedAt.Equal(groups[j].CreatedAt) {
			return groups[i].CreatedAt.Before(groups[j].CreatedAt)
		}
		return groups[i].ID < groups[j].ID
	})
}

// clonePaneNode deep-copies a tree so a caller's value and the stored state can
// never alias: Reconcile and Remove mutate nodes in place.
func clonePaneNode(node *api.PaneNode) *api.PaneNode {
	if node == nil {
		return nil
	}
	cloned := &api.PaneNode{
		PaneID:    node.PaneID,
		SessionID: node.SessionID,
		Axis:      node.Axis,
		Ratio:     node.Ratio,
	}
	cloned.First = clonePaneNode(node.First)
	cloned.Second = clonePaneNode(node.Second)
	return cloned
}

// samePaneNode compares two trees structurally, including pane identity, so a
// reconciliation can tell "nothing to do" from "the arrangement changed".
func samePaneNode(a, b *api.PaneNode) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	if a.Axis != b.Axis || a.PaneID != b.PaneID || a.SessionID != b.SessionID {
		return false
	}
	if a.Axis == "" {
		return true
	}
	if a.Ratio != b.Ratio {
		return false
	}
	return samePaneNode(a.First, b.First) && samePaneNode(a.Second, b.Second)
}
