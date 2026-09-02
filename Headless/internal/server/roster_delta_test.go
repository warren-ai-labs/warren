package server

import (
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

func TestMakeRosterDeltaIncludesOnlyChangedEntities(t *testing.T) {
	createdAt := time.Date(2026, 8, 25, 0, 0, 0, 0, time.UTC)
	before := api.State{
		Host: api.Host{ID: "host", Name: "before"},
		Tasks: []api.Task{
			{ID: "task-a", Name: "A", CreatedAt: createdAt},
		},
		Projects: []api.Project{
			{ID: "project-a", Name: "A", CreatedAt: createdAt},
			{ID: "project-b", Name: "B", CreatedAt: createdAt},
		},
		Workspaces:     []api.Workspace{{ID: "workspace-old", ProjectID: "project-a", CreatedAt: createdAt}},
		TerminalGroups: []api.TerminalGroup{{ID: "group-a", Name: "A", CreatedAt: createdAt}},
		Sessions: []api.Session{
			{ID: "session-a", Title: "A", WorkspaceID: "workspace-old", CreatedAt: createdAt},
			{ID: "session-b", Title: "B", WorkspaceID: "workspace-old", CreatedAt: createdAt},
		},
	}
	after := api.State{
		Host: api.Host{ID: "host", Name: "after"},
		Tasks: []api.Task{
			{ID: "task-a", Name: "A renamed", CreatedAt: createdAt},
			{ID: "task-b", Name: "B", CreatedAt: createdAt},
		},
		Projects: []api.Project{
			{ID: "project-b", Name: "B", CreatedAt: createdAt},
			{ID: "project-a", Name: "A renamed", CreatedAt: createdAt},
		},
		Workspaces:     []api.Workspace{{ID: "workspace-new", ProjectID: "project-a", CreatedAt: createdAt}},
		TerminalGroups: []api.TerminalGroup{{ID: "group-a", Name: "A", CreatedAt: createdAt}},
		Sessions: []api.Session{
			{ID: "session-b", Title: "B updated", WorkspaceID: "workspace-new", CreatedAt: createdAt},
			{ID: "session-a", Title: "A", WorkspaceID: "workspace-new", CreatedAt: createdAt},
		},
	}

	delta := makeRosterDelta(before, after, 11, 14)
	if delta.Type != "roster.delta" || delta.BaseRevision != 11 || delta.Revision != 14 {
		t.Fatalf("delta identity = %#v", delta)
	}
	if delta.Host == nil || delta.Host.Name != "after" {
		t.Fatalf("host delta = %#v", delta.Host)
	}
	if delta.Tasks == nil || len(delta.Tasks.Upsert) != 2 {
		t.Fatalf("task delta = %#v", delta.Tasks)
	}
	if delta.Projects == nil || len(delta.Projects.Upsert) != 1 || delta.Projects.Upsert[0].ID != "project-a" {
		t.Fatalf("project delta = %#v", delta.Projects)
	}
	if got, want := delta.Projects.Order, []string{"project-b", "project-a"}; !sameStrings(got, want) {
		t.Fatalf("project order = %#v, want %#v", got, want)
	}
	if delta.Workspaces == nil || len(delta.Workspaces.Upsert) != 1 || delta.Workspaces.Upsert[0].ID != "workspace-new" {
		t.Fatalf("workspace upsert = %#v", delta.Workspaces)
	}
	if got, want := delta.Workspaces.Remove, []string{"workspace-old"}; !sameStrings(got, want) {
		t.Fatalf("workspace removals = %#v, want %#v", got, want)
	}
	if delta.Groups != nil {
		t.Fatalf("unchanged terminal groups produced a delta: %#v", delta.Groups)
	}
	if delta.Sessions == nil || len(delta.Sessions.Upsert) != 2 {
		t.Fatalf("session upserts = %#v", delta.Sessions)
	}
	if got, want := delta.Sessions.Order, []string{"session-b", "session-a"}; !sameStrings(got, want) {
		t.Fatalf("session order = %#v, want %#v", got, want)
	}
}

func TestRosterDeltaCapabilityRequiresExplicitOptIn(t *testing.T) {
	for _, test := range []struct {
		capabilities []string
		want         bool
	}{
		{capabilities: nil, want: false},
		{capabilities: []string{"other"}, want: false},
		{capabilities: []string{"roster-delta"}, want: true},
		{capabilities: []string{"other", "roster-delta"}, want: true},
	} {
		if got := supportsRosterDeltas(test.capabilities); got != test.want {
			t.Errorf("supportsRosterDeltas(%q) = %t, want %t", test.capabilities, got, test.want)
		}
	}
}

func TestRosterDeltaSkipsIdenticalRoster(t *testing.T) {
	state := api.State{Host: api.Host{ID: "host", Name: "Host"}}
	if delta := makeRosterDelta(state, state, 3, 3); delta.hasChanges() {
		t.Fatalf("identical roster produced delta: %#v", delta)
	}
}

func TestRosterDeltaCanClearGhostlineMigration(t *testing.T) {
	before := api.State{
		GhostlineMigration: &api.GhostlineMigration{
			SessionID: "session", Phase: api.GhostlineMigrationCommitted,
		},
	}
	after := api.State{}
	delta := makeRosterDelta(before, after, 3, 4)
	if !delta.hasChanges() || delta.GhostlineMigration == nil {
		t.Fatalf("migration clear was omitted: %#v", delta)
	}
	if *delta.GhostlineMigration != nil {
		t.Fatalf("migration clear should carry a nil inner pointer: %#v", *delta.GhostlineMigration)
	}
	data, err := json.Marshal(delta)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"ghostlineMigration":null`) {
		t.Fatalf("migration clear was not encoded as null: %s", data)
	}
}

func TestRosterDeltaStreamUsesInitialRevisionAndChangedEntities(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	endpoint := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{
		Type:                 "auth",
		Token:                "secret",
		Version:              api.Version,
		Capabilities:         []string{"roster-delta"},
		TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome["t"] != "welcome" {
		t.Fatalf("welcome = %#v", welcome)
	}

	var initial struct {
		Type  string    `json:"t"`
		State api.State `json:"state"`
	}
	if err := connection.ReadJSON(&initial); err != nil {
		t.Fatal(err)
	}
	if initial.Type != "roster" || initial.State.Revision == 0 {
		t.Fatalf("initial roster = %#v", initial)
	}

	if err := state.Update(func(value *api.State) error {
		value.Host.Name = "renamed"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	if err := state.Update(func(value *api.State) error {
		value.Projects = append(value.Projects, api.Project{
			ID: projectID, Name: "project", Path: t.TempDir(), CreatedAt: time.Now().UTC(),
		})
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.TextMessage {
			continue
		}
		var delta rosterDeltaMessage
		if json.Unmarshal(data, &delta) != nil || delta.Type != "roster.delta" {
			continue
		}
		if delta.BaseRevision != initial.State.Revision || delta.Revision <= delta.BaseRevision {
			t.Fatalf("delta revisions = %#v after %#v", delta, initial.State.Revision)
		}
		if delta.Host == nil || delta.Host.Name != "renamed" {
			t.Fatalf("host delta = %#v", delta.Host)
		}
		if delta.Projects == nil || len(delta.Projects.Upsert) != 1 || delta.Projects.Upsert[0].ID != projectID {
			t.Fatalf("project delta = %#v", delta.Projects)
		}
		return
	}
}

func sameStrings(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}
