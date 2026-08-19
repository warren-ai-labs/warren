package server

import (
	"context"
	"sync"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

// kindRecordingRuntime records which engine handled a session and implements
// the full runtime surface so it can be registered alongside others.
type kindRecordingRuntime struct {
	mu       sync.Mutex
	kind     string
	sessions map[string]bool
	created  []string
	resized  int
	captured int
	killed   []string
}

func newKindRecordingRuntime(kind string) *kindRecordingRuntime {
	return &kindRecordingRuntime{kind: kind, sessions: map[string]bool{}}
}

func (r *kindRecordingRuntime) Create(_ context.Context, name, _, _ string, _ []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sessions[name] = true
	r.created = append(r.created, name)
	return nil
}
func (r *kindRecordingRuntime) Exists(_ context.Context, name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.sessions[name]
}
func (r *kindRecordingRuntime) Capture(context.Context, string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.captured++
	return []byte("snapshot"), nil
}
func (r *kindRecordingRuntime) Input(context.Context, string, []byte) error { return nil }
func (r *kindRecordingRuntime) Resize(context.Context, string, int, int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resized++
	return nil
}
func (r *kindRecordingRuntime) Kill(_ context.Context, name string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.sessions, name)
	r.killed = append(r.killed, name)
	return nil
}

func newCoexistService(t *testing.T) (*Service, *kindRecordingRuntime, *kindRecordingRuntime) {
	t.Helper()
	state := newStateWithSession(t, "session-coexist", "warren_coexist")
	ghostlineRuntime := newKindRecordingRuntime("ghostline")
	tmuxRuntime := newKindRecordingRuntime("tmux")
	service := &Service{
		Store:          state,
		Runtime:        ghostlineRuntime,
		Runtimes:       map[string]Runtime{"ghostline": ghostlineRuntime, "tmux": tmuxRuntime},
		DefaultRuntime: "ghostline",
	}
	return service, ghostlineRuntime, tmuxRuntime
}

func TestAdoptRuntimeKindFixesLegacySessions(t *testing.T) {
	service, ghostlineRuntime, tmuxRuntime := newCoexistService(t)
	ctx := context.Background()

	// A legacy session owned by tmux gets its runtimeKind fixed.
	tmuxRuntime.mu.Lock()
	tmuxRuntime.sessions["warren_legacy_tmux"] = true
	tmuxRuntime.mu.Unlock()
	adopted, changed := service.adoptRuntimeKind(ctx, api.Session{Runtime: "warren_legacy_tmux"})
	if !changed || adopted.RuntimeKind != "tmux" {
		t.Fatalf("adopt tmux = %+v, changed=%v", adopted, changed)
	}

	// A legacy session owned by ghostline gets fixed the other way.
	ghostlineRuntime.mu.Lock()
	ghostlineRuntime.sessions["warren_legacy_ghost"] = true
	ghostlineRuntime.mu.Unlock()
	adopted, changed = service.adoptRuntimeKind(ctx, api.Session{Runtime: "warren_legacy_ghost"})
	if !changed || adopted.RuntimeKind != "ghostline" {
		t.Fatalf("adopt ghostline = %+v, changed=%v", adopted, changed)
	}

	// No runtime owns the session: unchanged, so the caller can end it.
	adopted, changed = service.adoptRuntimeKind(ctx, api.Session{Runtime: "warren_nobody"})
	if changed || adopted.RuntimeKind != "" {
		t.Fatalf("adopt nobody = %+v, changed=%v", adopted, changed)
	}

	// Sessions that already record a kind are left alone.
	adopted, changed = service.adoptRuntimeKind(ctx, api.Session{Runtime: "warren_known", RuntimeKind: "tmux"})
	if changed || adopted.RuntimeKind != "tmux" {
		t.Fatalf("adopt known = %+v, changed=%v", adopted, changed)
	}
}

func TestCreateSessionRoutesToRequestedRuntime(t *testing.T) {
	service, ghostlineRuntime, tmuxRuntime := newCoexistService(t)
	workspace := service.Store.Snapshot().Workspaces[0]

	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "tmux")
	if err != nil {
		t.Fatalf("CreateSession tmux: %v", err)
	}
	if session.RuntimeKind != "tmux" {
		t.Fatalf("session runtimeKind = %q", session.RuntimeKind)
	}
	tmuxRuntime.mu.Lock()
	tmuxCreated := len(tmuxRuntime.created)
	tmuxRuntime.mu.Unlock()
	if tmuxCreated != 1 {
		t.Fatalf("tmux created = %d, want 1", tmuxCreated)
	}

	session, err = service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "")
	if err != nil {
		t.Fatalf("CreateSession default: %v", err)
	}
	if session.RuntimeKind != "ghostline" {
		t.Fatalf("default session runtimeKind = %q", session.RuntimeKind)
	}
	ghostlineRuntime.mu.Lock()
	ghostlineCreated := len(ghostlineRuntime.created)
	ghostlineRuntime.mu.Unlock()
	if ghostlineCreated != 1 {
		t.Fatalf("ghostline created = %d, want 1", ghostlineCreated)
	}
}

func TestSessionRoutesRuntimeOperations(t *testing.T) {
	service, ghostlineRuntime, tmuxRuntime := newCoexistService(t)
	workspace := service.Store.Snapshot().Workspaces[0]
	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "tmux")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	if err := service.RenameSession(session.ID, "renamed"); err != nil {
		t.Fatalf("RenameSession: %v", err)
	}
	// Kill must go to the tmux engine.
	if err := service.DeleteSession(context.Background(), session.ID); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	tmuxRuntime.mu.Lock()
	killed := tmuxRuntime.killed
	tmuxRuntime.mu.Unlock()
	if len(killed) != 1 {
		t.Fatalf("tmux killed = %v, want one", killed)
	}
	ghostlineRuntime.mu.Lock()
	ghostKilled := len(ghostlineRuntime.killed)
	ghostlineRuntime.mu.Unlock()
	if ghostKilled != 0 {
		t.Fatalf("ghostline killed = %d, want 0", ghostKilled)
	}
}

func TestUpdateSettingsKeepsRuntimeWhenUnspecified(t *testing.T) {
	service, _, _ := newCoexistService(t)
	if err := service.SetDefaultRuntime("tmux"); err != nil {
		t.Fatalf("SetDefaultRuntime: %v", err)
	}
	if err := service.UpdateSettings("", nil, ""); err != nil {
		t.Fatalf("UpdateSettings with empty kind: %v", err)
	}
	if service.DefaultRuntime != "tmux" {
		t.Fatalf("default = %q, want tmux preserved", service.DefaultRuntime)
	}
}

func TestSetDefaultRuntimePersistsAndValidates(t *testing.T) {
	service, _, _ := newCoexistService(t)
	settingsPath := t.TempDir() + "/settings.json"
	service.SettingsPath = settingsPath
	service.Settings = settings.Settings{RuntimeEnv: map[string]string{"GIT_PAGER": "less"}}
	if err := service.SetDefaultRuntime("tmux"); err != nil {
		t.Fatalf("SetDefaultRuntime: %v", err)
	}
	if service.DefaultRuntime != "tmux" {
		t.Fatalf("default = %q", service.DefaultRuntime)
	}
	loaded, err := settings.Load(settingsPath)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.DefaultRuntime != "tmux" || loaded.RuntimeEnv["GIT_PAGER"] != "less" {
		t.Fatalf("persisted settings = %#v", loaded)
	}
	if err := service.SetDefaultRuntime("bogus"); err == nil {
		t.Fatal("bogus runtime accepted")
	}
}
