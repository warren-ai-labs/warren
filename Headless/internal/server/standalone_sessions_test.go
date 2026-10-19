package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/store"
)

type blockingCreateRuntime struct {
	*memoryRuntime
	entered chan struct{}
	release chan struct{}
}

func (runtime *blockingCreateRuntime) Create(ctx context.Context, name, directory, command string, env []string) error {
	select {
	case <-runtime.entered:
	default:
		close(runtime.entered)
	}
	select {
	case <-runtime.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	return runtime.memoryRuntime.Create(ctx, name, directory, command, env)
}

// A Host upgraded from a release with Terminal Groups still has their Sessions
// on disk. They decode without a Workspace, so the Host kills their runtimes and
// drops them, together with any arrangement they owned.
func TestRetireStandaloneSessionsFromRemovedTerminalGroups(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	legacy := `{
  "schema": 4,
  "host": {"id": "host-1", "name": "test"},
  "workspaces": [{"id": "workspace-1", "project": "project-1", "name": "main", "kind": "main"}],
  "terminalGroups": [{"id": "group-1", "name": "Inbox"}],
  "sessions": [
    {"id": "workspace-session", "workspace": "workspace-1", "scope": "workspace", "runtime": "warren_workspace", "lifecycle": "running"},
    {"id": "group-session", "terminalGroup": "group-1", "scope": "terminalGroup", "runtime": "warren_group", "lifecycle": "running"}
  ],
  "paneGroups": [
    {"id": "pane-group-1", "terminalGroup": "group-1", "scope": "terminalGroup", "revision": 1, "tree": {"paneId": "pane-1", "sessionId": "group-session"}}
  ]
}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := store.Open(path, "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryRuntime(t)
	for _, name := range []string{"warren_workspace", "warren_group"} {
		if err := runtime.Create(context.Background(), name, "", "", nil); err != nil {
			t.Fatal(err)
		}
	}
	service := &Service{Store: state, Runtime: runtime}

	service.retireStandaloneSessions(context.Background())

	snapshot := state.Snapshot()
	if len(snapshot.Sessions) != 1 || snapshot.Sessions[0].ID != "workspace-session" {
		t.Fatalf("sessions = %#v, want only the workspace session", snapshot.Sessions)
	}
	if len(snapshot.PaneGroups) != 0 {
		t.Fatalf("pane groups = %#v, want the group-owned arrangement dropped", snapshot.PaneGroups)
	}
	if runtime.Exists(context.Background(), "warren_group") {
		t.Fatal("the retired session's runtime is still running")
	}
	if !runtime.Exists(context.Background(), "warren_workspace") {
		t.Fatal("a workspace session's runtime was killed")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "terminalGroup") {
		t.Fatalf("state still records terminal groups:\n%s", data)
	}
}

func TestSessionCreateRequiresWorkspace(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	if _, err := service.CreateSession(context.Background(), "", "", "shell", "", ""); err == nil || !strings.Contains(err.Error(), "workspace is required") {
		t.Fatalf("create without workspace error = %v", err)
	}
}
