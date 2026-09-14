package server

import (
	"context"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type metadataRuntime struct {
	memoryRuntime
	process     string
	commandLine string
	directory   string
	mu          sync.Mutex
	calls       int
}

func (r *metadataRuntime) Metadata(context.Context, string) (runtime.RuntimeMetadata, error) {
	r.mu.Lock()
	r.calls++
	r.mu.Unlock()
	return runtime.RuntimeMetadata{Process: r.process, CommandLine: r.commandLine, Directory: r.directory}, nil
}

func (r *metadataRuntime) metadataCalls() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls
}

func TestRosterOverlaysRuntimeMetadata(t *testing.T) {
	directory := t.TempDir()
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	adapter := &metadataRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{"runtime-live": {}}},
		process:       "npm",
		commandLine:   "npm run dev",
		directory:     "/work/live",
	}
	service := &Service{
		Store:           state,
		Runtime:         adapter,
		Runtimes:        map[string]Runtime{"test": adapter},
		DefaultRuntime:  "test",
		ProbeForeground: true,
		WorktreeRoot:    filepath.Join(directory, "worktrees"),
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = append(value.Sessions, api.Session{
			ID:          "session-1",
			WorkspaceID: "workspace-1",
			Runtime:     "runtime-live",
			RuntimeKind: "test",
			Lifecycle:   "running",
			CreatedAt:   time.Now().UTC(),
		})
		return nil
	}); err != nil {
		t.Fatalf("seed session: %v", err)
	}
	service.lazyInit()
	service.refreshMetadata(context.Background())
	callsBeforeRoster := adapter.metadataCalls()
	roster, _ := service.RosterVersion(context.Background())
	if got := adapter.metadataCalls(); got != callsBeforeRoster {
		t.Fatalf("RosterVersion made %d metadata probe(s), want %d (roster must read cache only)", got, callsBeforeRoster)
	}
	if len(roster.Sessions) != 1 {
		t.Fatalf("roster sessions = %d, want 1", len(roster.Sessions))
	}
	session := roster.Sessions[0]
	if session.Process != "npm" || session.CommandLine != "npm run dev" || session.Directory != "/work/live" {
		t.Fatalf("roster metadata = %q/%q/%q, want npm/npm run dev//work/live", session.Process, session.CommandLine, session.Directory)
	}
}
