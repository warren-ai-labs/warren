package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestOpenMigratesCompatibleStateSchemas(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	migration := &api.GhostlineMigration{
		SessionID:       "migration-1",
		SourceSocket:    "/tmp/ghostline-old.sock",
		TargetSocket:    "/tmp/ghostline-new.sock",
		SourceProtocol:  "1.0.0",
		HandoffVersion:  "warren-v0.11.2",
		Phase:           api.GhostlineMigrationCommitted,
		SkippedSessions: []string{"session-2"},
		SkipReasons:     map[string]string{"session-2": "restore failed"},
		CreatedAt:       time.Unix(1, 0).UTC(),
		UpdatedAt:       time.Unix(2, 0).UTC(),
	}
	data, err := json.Marshal(api.State{
		Schema:                    2,
		Host:                      api.Host{ID: "host-1", Name: "test"},
		GhostlineMigration:        migration,
		WorktreeOwnershipMigrated: true,
		WarrenVersion:             "v0.11.2",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := Open(path, "test")
	if err != nil {
		t.Fatalf("open schema 2: %v", err)
	}
	snapshot := state.Snapshot()
	if snapshot.Schema != currentSchema {
		t.Fatalf("schema = %d, want %d", snapshot.Schema, currentSchema)
	}
	if snapshot.WarrenVersion != "v0.11.2" || !snapshot.WorktreeOwnershipMigrated {
		t.Fatalf("compatible state fields were not preserved: %#v", snapshot)
	}
	if snapshot.GhostlineMigration == nil || snapshot.GhostlineMigration.SessionID != migration.SessionID ||
		len(snapshot.GhostlineMigration.SkippedSessions) != 1 ||
		snapshot.GhostlineMigration.SkipReasons["session-2"] != "restore failed" {
		t.Fatalf("migration journal was not preserved: %#v", snapshot.GhostlineMigration)
	}
	var persisted api.State
	data, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &persisted); err != nil {
		t.Fatal(err)
	}
	if persisted.Schema != currentSchema {
		t.Fatalf("persisted schema = %d, want %d", persisted.Schema, currentSchema)
	}

	for _, schema := range []int{1, 2} {
		data, err := json.Marshal(api.State{Schema: schema, Host: api.Host{ID: "host-1", Name: "test"}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		state, err := Open(path, "test")
		if err != nil {
			t.Fatalf("schema %d error = %v", schema, err)
		}
		if state.Snapshot().Schema != currentSchema {
			t.Fatalf("schema %d snapshot = %d, want %d", schema, state.Snapshot().Schema, currentSchema)
		}
	}
}

func TestOpenRejectsUnknownAndFutureStateSchemas(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	for _, schema := range []int{0, 999} {
		data, err := json.Marshal(api.State{Schema: schema, Host: api.Host{ID: "host-1", Name: "test"}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		_, err = Open(path, "test")
		var resetErr *StateResetError
		if !errors.As(err, &resetErr) {
			t.Fatalf("schema %d error = %v, want StateResetError", schema, err)
		}
		if resetErr.FoundSchema != schema || resetErr.RequiredSchema != currentSchema {
			t.Fatalf("reset error = %#v", resetErr)
		}
	}
}

func TestOpenCreatesFreshCurrentState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	state, err := Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	snapshot := state.Snapshot()
	if snapshot.Schema != currentSchema || len(snapshot.TerminalGroups) != 1 {
		t.Fatalf("fresh state = %#v", snapshot)
	}
	if snapshot.TerminalGroups[0].Name != "Inbox" {
		t.Fatalf("fresh terminal group = %#v", snapshot.TerminalGroups[0])
	}
}

func TestOpenRejectsFutureSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(path, []byte(`{"schema":999}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path, "test"); err == nil {
		t.Fatal("expected state_reset_required error")
	} else if !strings.Contains(err.Error(), "state_reset_required") {
		t.Fatalf("error = %v, want state_reset_required", err)
	}
}

func BenchmarkSnapshot(b *testing.B) {
	state := api.State{Schema: currentSchema, Host: api.Host{ID: NewID(), Name: "benchmark"}}
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
		state.Schema = currentSchema
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
