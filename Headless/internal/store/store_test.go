package store

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestOpenMigratesMissingTerminalGroups(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	data, err := json.Marshal(api.State{
		Schema: 1,
		Host:   api.Host{ID: "host-1", Name: "test"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	snapshot := state.Snapshot()
	if snapshot.Schema != currentSchema {
		t.Fatalf("schema = %d, want %d", snapshot.Schema, currentSchema)
	}
	if len(snapshot.TerminalGroups) != 1 {
		t.Fatalf("terminal groups = %#v, want one migrated Inbox", snapshot.TerminalGroups)
	}
	group := snapshot.TerminalGroups[0]
	if group.Name != "Inbox" || group.Order != 0 || group.ID == "" {
		t.Fatalf("migrated group = %#v", group)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("migrated state was not persisted: %v", err)
	}
}

func TestOpenMigratesSchemaOneWithoutLosingResources(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	data, err := json.Marshal(api.State{
		Schema:     1,
		Host:       api.Host{ID: "host-1", Name: "test"},
		Projects:   []api.Project{{ID: "project-1", Name: "project"}},
		Workspaces: []api.Workspace{{ID: "workspace-1", ProjectID: "project-1", Name: "main"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	snapshot := state.Snapshot()
	if snapshot.Schema != currentSchema || len(snapshot.Projects) != 1 || len(snapshot.Workspaces) != 1 {
		t.Fatalf("migrated state = %#v", snapshot)
	}
	persisted, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var reopened api.State
	if err := json.Unmarshal(persisted, &reopened); err != nil {
		t.Fatal(err)
	}
	if reopened.Schema != currentSchema {
		t.Fatalf("persisted schema = %d, want %d", reopened.Schema, currentSchema)
	}
}

func TestOpenRejectsFutureSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(path, []byte(`{"schema":999}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path, "test"); err == nil {
		t.Fatal("expected unsupported schema error")
	}
}

func BenchmarkSnapshot(b *testing.B) {
	state := api.State{Schema: 1, Host: api.Host{ID: NewID(), Name: "benchmark"}}
	for projectIndex := 0; projectIndex < 50; projectIndex++ {
		projectID := NewID()
		state.Projects = append(state.Projects, api.Project{
			ID: projectID, Name: fmt.Sprintf("project-%d", projectIndex), Path: "/work/project",
		})
		for workspaceIndex := 0; workspaceIndex < 4; workspaceIndex++ {
			workspaceID := NewID()
			state.Workspaces = append(state.Workspaces, api.Workspace{
				ID: workspaceID, ProjectID: projectID, Name: "workspace", Path: "/work/project/worktree",
			})
			for sessionIndex := 0; sessionIndex < 2; sessionIndex++ {
				endedAt := time.Now()
				state.Sessions = append(state.Sessions, api.Session{
					ID: NewID(), WorkspaceID: workspaceID, Runtime: "warren_session", EndedAt: &endedAt,
				})
			}
		}
	}
	store := &Store{state: state}

	b.ReportAllocs()
	for b.Loop() {
		_ = store.Snapshot()
	}
}

func TestSnapshotDoesNotShareMutableState(t *testing.T) {
	endedAt := time.Now()
	store := &Store{changed: make(chan struct{}), state: api.State{
		Tasks:    []api.Task{{ID: "task"}},
		Projects: []api.Project{{ID: "project"}},
		Sessions: []api.Session{{ID: "session", AgentCapabilities: []string{"agent-timeline-v1"}, EndedAt: &endedAt}},
	}}

	snapshot := store.Snapshot()
	snapshot.Tasks[0].ID = "changed-task"
	snapshot.Projects[0].ID = "changed"
	snapshot.Sessions[0].AgentCapabilities[0] = "changed-capability"
	changedTime := endedAt.Add(time.Hour)
	*snapshot.Sessions[0].EndedAt = changedTime

	current := store.Snapshot()
	if current.Tasks[0].ID != "task" || current.Projects[0].ID != "project" ||
		current.Sessions[0].AgentCapabilities[0] != "agent-timeline-v1" ||
		!current.Sessions[0].EndedAt.Equal(endedAt) {
		t.Fatalf("snapshot mutated store: %#v", current)
	}
}

func TestUpdateAdvancesRevisionAndNotifiesWatchers(t *testing.T) {
	store := &Store{changed: make(chan struct{})}
	_, revision := store.SnapshotVersion()
	changed := store.ChangesSince(revision)
	store.path = filepath.Join(t.TempDir(), "state.json")
	if err := store.Update(func(state *api.State) error {
		state.Schema = 1
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	select {
	case <-changed:
	default:
		t.Fatal("watcher was not notified")
	}
	_, nextRevision := store.SnapshotVersion()
	if nextRevision != revision+1 {
		t.Fatalf("revision=%d, want %d", nextRevision, revision+1)
	}
	select {
	case <-store.ChangesSince(revision):
	default:
		t.Fatal("stale revision did not report an immediate change")
	}
}
