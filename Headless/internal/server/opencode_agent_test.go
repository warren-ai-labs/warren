package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

type testOpenCodeFinder struct {
	binding agent.OpenCodeBinding
}

func (f *testOpenCodeFinder) Find(context.Context, string, string, time.Time) (string, error) {
	return f.binding.CachePath, nil
}

func (f *testOpenCodeFinder) FindBinding(context.Context, string, string, string, time.Time) (*agent.OpenCodeBinding, error) {
	binding := f.binding
	return &binding, nil
}

func (f *testOpenCodeFinder) FindBindingBySessionID(_ context.Context, _ string, _ string, sessionID string) (*agent.OpenCodeBinding, error) {
	if sessionID == "" || sessionID != f.binding.SessionID {
		return nil, nil
	}
	binding := f.binding
	return &binding, nil
}

type staleOpenCodeFinder struct {
	fallback agent.OpenCodeBinding
}

func (f *staleOpenCodeFinder) Find(context.Context, string, string, time.Time) (string, error) {
	return f.fallback.CachePath, nil
}

func (f *staleOpenCodeFinder) FindBinding(context.Context, string, string, string, time.Time) (*agent.OpenCodeBinding, error) {
	binding := f.fallback
	return &binding, nil
}

func (f *staleOpenCodeFinder) FindBindingBySessionID(context.Context, string, string, string) (*agent.OpenCodeBinding, error) {
	return nil, nil
}

type multiOpenCodeFinder struct {
	bindings []agent.OpenCodeBinding
}

func (f *multiOpenCodeFinder) Find(context.Context, string, string, time.Time) (string, error) {
	if len(f.bindings) == 0 {
		return "", nil
	}
	return f.bindings[0].CachePath, nil
}

func (f *multiOpenCodeFinder) FindBinding(_ context.Context, warrenSessionID, _ string, _ string, _ time.Time) (*agent.OpenCodeBinding, error) {
	if len(f.bindings) == 0 {
		return nil, nil
	}
	binding := f.bindings[0]
	binding.CachePath = filepath.Join(filepath.Dir(binding.CachePath), warrenSessionID+"-"+binding.SessionID+".jsonl")
	return &binding, nil
}

func (f *multiOpenCodeFinder) FindBindings(_ context.Context, warrenSessionID, _ string, _ string, _ time.Time) ([]*agent.OpenCodeBinding, error) {
	result := make([]*agent.OpenCodeBinding, 0, len(f.bindings))
	for _, source := range f.bindings {
		binding := source
		binding.CachePath = filepath.Join(filepath.Dir(source.CachePath), warrenSessionID+"-"+source.SessionID+".jsonl")
		result = append(result, &binding)
	}
	return result, nil
}

func (f *multiOpenCodeFinder) FindBindingBySessionID(_ context.Context, warrenSessionID, _ string, sessionID string) (*agent.OpenCodeBinding, error) {
	for _, source := range f.bindings {
		if source.SessionID != sessionID {
			continue
		}
		binding := source
		binding.CachePath = filepath.Join(filepath.Dir(source.CachePath), warrenSessionID+"-"+source.SessionID+".jsonl")
		return &binding, nil
	}
	return nil, nil
}

func newOpenCodeTestSession(t *testing.T, stateID, workspaceID string) *api.Session {
	t.Helper()
	now := time.Now().UTC()
	return &api.Session{
		ID: stateID, WorkspaceID: workspaceID, Title: "OpenCode", Kind: "opencode",
		Runtime: "runtime-" + stateID, Lifecycle: "running", CreatedAt: now,
	}
}

func TestEnsureAgentStartsAndRebindsOpenCodeTailer(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state := newStateWithSession(t, "session-opencode", "runtime-opencode")
	workspace := state.Snapshot().Workspaces[0]
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].Kind = "opencode"
		value.Sessions[0].Title = "OpenCode"
		value.Workspaces[0].Path = directory
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	cacheA := filepath.Join(directory, "cache-a.jsonl")
	finder := &testOpenCodeFinder{binding: agent.OpenCodeBinding{
		Provider:  "opencode",
		SessionID: "ses_a", Backend: "sqlite", DatabasePath: filepath.Join(directory, "missing.db"),
		CachePath: cacheA, WorkspacePath: workspace.Path,
	}}
	service := &Service{Store: state, AgentFinder: finder}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil || entry.tailer == nil {
		t.Fatal("OpenCode ensure must start both tailer and watcher")
	}
	oldWatcher, oldTailer := entry.watcher, entry.tailer
	if got := oldWatcher.Path(); got != cacheA {
		t.Fatalf("initial watcher path = %q, want %q", got, cacheA)
	}
	bound := state.Snapshot().Sessions[0]
	if bound.AgentSessionID != "ses_a" || bound.TranscriptPath != cacheA {
		t.Fatalf("persisted OpenCode binding = %#v", bound)
	}

	cacheB := filepath.Join(directory, "cache-b.jsonl")
	finder.binding.SessionID = "ses_b"
	finder.binding.CachePath = cacheB
	current := state.Snapshot().Sessions[0]
	rebound, err := service.ensureAgent(context.Background(), current)
	if err != nil {
		t.Fatal(err)
	}
	if rebound == nil || rebound.watcher == nil || rebound.tailer == nil || rebound.watcher == oldWatcher || rebound.tailer == oldTailer {
		t.Fatal("OpenCode rebind must replace the old watcher and tailer")
	}
	if got := rebound.watcher.Path(); got != cacheB {
		t.Fatalf("rebound watcher path = %q, want %q", got, cacheB)
	}
	bound = state.Snapshot().Sessions[0]
	if bound.AgentSessionID != "ses_b" || bound.TranscriptPath != cacheB {
		t.Fatalf("rebound OpenCode binding = %#v", bound)
	}
	service.stopAgent(session.ID)
	service.agentsMu.Lock()
	_, stillTracked := service.agents[session.ID]
	service.agentsMu.Unlock()
	if stillTracked {
		t.Fatal("stopped OpenCode agent must be removed from the service")
	}
}

func TestEnsureAgentDerivesMissingOpenCodeCachePath(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state := newStateWithSession(t, "session-opencode-default-cache", "runtime-opencode-default-cache")
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].Kind = "opencode"
		value.Workspaces[0].Path = directory
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	finder := &testOpenCodeFinder{binding: agent.OpenCodeBinding{
		Provider:     "opencode",
		SessionID:    "ses_default_cache",
		Backend:      "sqlite",
		DatabasePath: filepath.Join(directory, "missing.db"),
	}}
	service := &Service{Store: state, AgentFinder: finder}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil || entry.tailer == nil {
		t.Fatal("OpenCode ensure must start with a derived cache path")
	}
	want := agent.OpenCodeCachePath(session.ID, finder.binding.SessionID)
	if got := entry.watcher.Path(); got != want {
		t.Fatalf("derived watcher path = %q, want %q", got, want)
	}
	if got := state.Snapshot().Sessions[0].TranscriptPath; got != want {
		t.Fatalf("derived persisted cache path = %q, want %q", got, want)
	}
	service.stopAgent(session.ID)
}

func TestEnsureAgentDoesNotShareOpenCodeBinding(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state := newStateWithSession(t, "session-opencode-a", "runtime-opencode-a")
	workspaceID := state.Snapshot().Workspaces[0].ID
	second := newOpenCodeTestSession(t, "session-opencode-b", workspaceID)
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].Kind = "opencode"
		value.Workspaces[0].Path = directory
		value.Sessions = append(value.Sessions, *second)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	finder := &testOpenCodeFinder{binding: agent.OpenCodeBinding{
		Provider:  "opencode",
		SessionID: "ses_shared", Backend: "sqlite", DatabasePath: filepath.Join(directory, "missing.db"),
		CachePath: filepath.Join(directory, "shared.jsonl"), WorkspacePath: directory,
	}}
	service := &Service{Store: state, AgentFinder: finder}
	service.lazyInit()
	sessions := state.Snapshot().Sessions
	if entry, err := service.ensureAgent(context.Background(), sessions[0]); err != nil || entry == nil {
		t.Fatalf("first OpenCode binding = %v, %v", entry, err)
	}
	if entry, err := service.ensureAgent(context.Background(), sessions[1]); err != nil {
		t.Fatal(err)
	} else if entry != nil {
		t.Fatal("second Warren session must not adopt an already-bound OpenCode session")
	}
	if got := state.Snapshot().Sessions[1].AgentSessionID; got != "" {
		t.Fatalf("second session unexpectedly persisted shared binding %q", got)
	}
	service.stopAgent(sessions[0].ID)
}

func TestEnsureAgentSelectsNextOpenCodeCandidateAfterFirstIsBound(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state := newStateWithSession(t, "session-opencode-candidate-a", "runtime-opencode-candidate-a")
	workspaceID := state.Snapshot().Workspaces[0].ID
	second := newOpenCodeTestSession(t, "session-opencode-candidate-b", workspaceID)
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].Kind = "opencode"
		value.Workspaces[0].Path = directory
		value.Sessions = append(value.Sessions, *second)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	finder := &multiOpenCodeFinder{bindings: []agent.OpenCodeBinding{
		{Provider: "opencode", SessionID: "ses_candidate_a", Backend: "sqlite", DatabasePath: filepath.Join(directory, "missing.db"), CachePath: filepath.Join(directory, "provider-a.jsonl")},
		{Provider: "opencode", SessionID: "ses_candidate_b", Backend: "sqlite", DatabasePath: filepath.Join(directory, "missing.db"), CachePath: filepath.Join(directory, "provider-b.jsonl")},
	}}
	service := &Service{Store: state, AgentFinder: finder}
	service.lazyInit()
	sessions := state.Snapshot().Sessions
	first, err := service.ensureAgent(context.Background(), sessions[0])
	if err != nil || first == nil {
		t.Fatalf("first candidate ensure = %v, %v", first, err)
	}
	secondEntry, err := service.ensureAgent(context.Background(), sessions[1])
	if err != nil || secondEntry == nil {
		t.Fatalf("second candidate ensure = %v, %v", secondEntry, err)
	}
	bound := state.Snapshot().Sessions
	if bound[0].AgentSessionID != "ses_candidate_a" || bound[1].AgentSessionID != "ses_candidate_b" {
		t.Fatalf("candidate bindings = %#v", bound)
	}
	service.stopAgent(sessions[0].ID)
	service.stopAgent(sessions[1].ID)
}

func TestEnsureAgentDoesNotReplaceMissingOpenCodeBinding(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state := newStateWithSession(t, "session-opencode-stale", "runtime-opencode-stale")
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].Kind = "opencode"
		value.Sessions[0].AgentSessionID = "ses_missing"
		value.Workspaces[0].Path = directory
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	finder := &staleOpenCodeFinder{fallback: agent.OpenCodeBinding{
		Provider: "opencode", SessionID: "ses_other", Backend: "sqlite",
		DatabasePath: filepath.Join(directory, "missing.db"),
		CachePath:    filepath.Join(directory, "other.jsonl"), WorkspacePath: directory,
	}}
	service := &Service{Store: state, AgentFinder: finder}
	service.lazyInit()
	entry, err := service.ensureAgent(context.Background(), state.Snapshot().Sessions[0])
	if err != nil {
		t.Fatal(err)
	}
	if entry != nil {
		t.Fatal("a missing durable OpenCode binding must not adopt another session")
	}
	if got := state.Snapshot().Sessions[0].AgentSessionID; got != "ses_missing" {
		t.Fatalf("missing durable binding was replaced with %q", got)
	}
}

func TestEnsureAgentSerializesConcurrentOpenCodeBinding(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state := newStateWithSession(t, "session-opencode-a", "runtime-opencode-a")
	workspaceID := state.Snapshot().Workspaces[0].ID
	second := newOpenCodeTestSession(t, "session-opencode-b", workspaceID)
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].Kind = "opencode"
		value.Workspaces[0].Path = directory
		value.Sessions = append(value.Sessions, *second)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	finder := &testOpenCodeFinder{binding: agent.OpenCodeBinding{
		Provider: "opencode", SessionID: "ses_shared", Backend: "sqlite",
		DatabasePath: filepath.Join(directory, "missing.db"),
		CachePath:    filepath.Join(directory, "shared.jsonl"), WorkspacePath: directory,
	}}
	service := &Service{Store: state, AgentFinder: finder}
	service.lazyInit()
	sessions := state.Snapshot().Sessions
	start := make(chan struct{})
	var wait sync.WaitGroup
	results := make([]*agentSession, len(sessions))
	errors := make([]error, len(sessions))
	for index := range sessions {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			<-start
			results[index], errors[index] = service.ensureAgent(context.Background(), sessions[index])
		}(index)
	}
	close(start)
	wait.Wait()
	if (results[0] == nil) == (results[1] == nil) {
		t.Fatalf("exactly one concurrent ensure should bind: results=%#v errors=%#v", results, errors)
	}
	for index, err := range errors {
		if err != nil {
			t.Fatalf("ensure %d failed: %v", index, err)
		}
	}
	bound := state.Snapshot().Sessions
	boundCount := 0
	for _, session := range bound {
		if session.AgentSessionID == "ses_shared" {
			boundCount++
		}
	}
	if boundCount != 1 {
		t.Fatalf("concurrent binding persisted for %d sessions, want one: %#v", boundCount, bound)
	}
	for _, session := range sessions {
		service.stopAgent(session.ID)
	}
}

func TestDeleteSessionRemovesOpenCodeCache(t *testing.T) {
	directory := t.TempDir()
	cachePath := filepath.Join(directory, "opencode-cache.jsonl")
	if err := os.WriteFile(cachePath, []byte(`{"messageId":"msg"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	state := newStateWithSession(t, "session-opencode-delete", "runtime-opencode-delete")
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].Kind = "opencode"
		value.Sessions[0].TranscriptPath = cachePath
		value.Sessions[0].AgentSessionID = "ses_delete"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	if err := service.DeleteSession(context.Background(), "session-opencode-delete"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("deleted OpenCode session cache still exists, stat error = %v", err)
	}
}

func TestCreateSessionRejectsOpenCodeSessionReuseAtHostBoundary(t *testing.T) {
	state := newStateWithSession(t, "session-opencode-validate", "runtime-opencode-validate")
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	workspace := state.Snapshot().Workspaces[0]
	for _, command := range []string{"opencode --continue", "opencode --session ses_existing", "opencode --fork"} {
		if _, err := service.CreateSession(context.Background(), workspace.ID, command, "opencode", "", ""); err == nil || !strings.Contains(err.Error(), "start a new session") {
			t.Fatalf("CreateSession(%q) = %v, want session reuse rejection", command, err)
		}
	}
}
