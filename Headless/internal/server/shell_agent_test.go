package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

func TestEnsureAgentAdoptsShellBinding(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-shell.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-shell",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentStatus(agent.StatePath(session.ID), api.AgentStatus{Activity: api.AgentActivityReady}); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a watcher for the shell overlay")
	}
	if got := entry.watcher.Path(); got != transcriptPath {
		t.Fatalf("watcher path = %q, want %q", got, transcriptPath)
	}
	if got := service.agentStatus(session.ID).Activity; got != api.AgentActivityReady {
		t.Fatalf("activity = %q, want ready", got)
	}
	current := state.Snapshot()
	if current.Sessions[0].AgentSessionID != "thread-shell" || current.Sessions[0].TranscriptPath != transcriptPath {
		t.Fatalf("shell session meta = %#v", current.Sessions[0])
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID && (candidate.AgentStatus == nil || candidate.AgentStatus.Activity != api.AgentActivityReady) {
			t.Fatalf("roster status = %#v, want ready", candidate.AgentStatus)
		}
	}
	entry.watcher.Close()
}

func TestEnsureAgentClearsShellBindingOnExit(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-shell.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "claude",
		SessionID:      "claude-shell",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentStatus(agent.StatePath(session.ID), api.AgentStatus{Activity: api.AgentActivityReady}); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentStatus(agent.StatePath(session.ID), api.AgentStatus{Activity: api.AgentActivityExited}); err != nil {
		t.Fatal(err)
	}

	active := state.Snapshot().Sessions[0]
	entry, err := service.ensureAgent(context.Background(), active)
	if err != nil {
		t.Fatal(err)
	}
	if entry != nil {
		t.Fatal("shell overlay must be torn down after SessionEnd")
	}
	current := state.Snapshot()
	if current.Sessions[0].AgentSessionID != "" || current.Sessions[0].TranscriptPath != "" {
		t.Fatalf("shell session meta was not cleared: %#v", current.Sessions[0])
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == active.ID && candidate.AgentStatus != nil {
			t.Fatalf("roster status = %#v, want empty", candidate.AgentStatus)
		}
	}
}

func TestPlainShellSessionHasNoAgentActivity(t *testing.T) {
	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", t.TempDir(), "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry != nil {
		t.Fatal("plain shell must not start an agent watcher")
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID && candidate.AgentStatus != nil {
			t.Fatalf("plain shell status = %#v, want empty", candidate.AgentStatus)
		}
	}
}

func TestShellOverlayResetsReadyAfterExitOnSameTranscript(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-shell.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := newSpoolRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-shell", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	session := state.Snapshot().Sessions[0]
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-shell",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentStatus(agent.StatePath(session.ID), api.AgentStatus{Activity: api.AgentActivityReady}); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	service.forceAgentStatus(session.ID, api.AgentStatus{Activity: api.AgentActivityExited})
	if err := agent.WriteAgentStatus(agent.StatePath(session.ID), api.AgentStatus{Activity: api.AgentActivityReady}); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if got := service.agentStatus(session.ID).Activity; got != api.AgentActivityReady {
		t.Fatalf("activity after same-transcript SessionStart = %q, want ready", got)
	}
}

func TestCreateSessionInjectsShellBindEnvironment(t *testing.T) {
	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := &envRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	service := &Service{Store: state, Runtime: runtime}
	workspace := state.Snapshot().Workspaces[0]

	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	env := runtime.lastEnv()
	joined := strings.Join(env, "\n")
	for _, expected := range []string{
		agent.BindEnvSession + "=" + session.ID,
		agent.BindEnvFile + "=" + agent.BindPath(session.ID),
		agent.BindEnvState + "=" + agent.StatePath(session.ID),
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("shell env missing %q: %#v", expected, env)
		}
	}
	if strings.Contains(joined, agent.BindEnvKind+"=") {
		t.Fatalf("shell env must not pin an agent kind: %#v", env)
	}
}

func TestCreateSessionAppliesRuntimeEnvironmentOverrides(t *testing.T) {
	state := newStateWithSession(t, "session-shell", "runtime-shell")
	runtime := &envRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	service := &Service{
		Store:   state,
		Runtime: runtime,
		Settings: settings.Settings{RuntimeEnv: map[string]string{
			"TERM":      "xterm-256color",
			"GIT_PAGER": "less",
			"PAGER":     "",
		}},
	}
	workspace := state.Snapshot().Workspaces[0]

	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "", "")
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	env := runtime.lastEnv()
	values := make(map[string]string, len(env))
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if !ok {
			t.Fatalf("invalid environment entry %q", entry)
		}
		values[key] = value
	}
	if values["TERM"] != "xterm-256color" {
		t.Fatalf("TERM = %q, want xterm-256color: %#v", values["TERM"], env)
	}
	if values["GIT_PAGER"] != "less" {
		t.Fatalf("GIT_PAGER = %q, want less: %#v", values["GIT_PAGER"], env)
	}
	if _, ok := values["PAGER"]; ok {
		t.Fatalf("empty runtime override must not be sent: %#v", env)
	}
	if values[agent.BindEnvSession] != session.ID {
		t.Fatalf("session binding was lost: %#v", env)
	}
}

func TestCreateSessionSeparatesDefaultAndCustomTitle(t *testing.T) {
	state := newStateWithSession(t, "session-title", "runtime-title")
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	workspace := state.Snapshot().Workspaces[0]

	session, err := service.CreateSession(context.Background(), workspace.ID, "", "shell", "My Shell", "")
	if err != nil {
		t.Fatalf("CreateSession with title: %v", err)
	}
	if session.Title != "Shell" || session.CustomTitle != "My Shell" {
		t.Fatalf("custom title semantics = %q/%q, want Shell/My Shell", session.Title, session.CustomTitle)
	}
	if err := service.RenameSession(session.ID, "Renamed Shell"); err != nil {
		t.Fatalf("RenameSession: %v", err)
	}
	renamed, ok := service.Session(session.ID)
	if !ok || renamed.Title != "Shell" || renamed.CustomTitle != "Renamed Shell" {
		t.Fatalf("renamed title semantics = %q/%q, want Shell/Renamed Shell", renamed.Title, renamed.CustomTitle)
	}

	defaultSession, err := service.CreateSession(context.Background(), workspace.ID, "", "codex", "", "")
	if err != nil {
		t.Fatalf("CreateSession without title: %v", err)
	}
	if defaultSession.Title != "Codex" || defaultSession.CustomTitle != "" {
		t.Fatalf("default title semantics = %q/%q, want Codex/empty", defaultSession.Title, defaultSession.CustomTitle)
	}
}

type envRecordingRuntime struct {
	*memoryRuntime
	mu   sync.Mutex
	envs [][]string
}

func (r *envRecordingRuntime) Create(ctx context.Context, name, directory, command string, env []string) error {
	r.mu.Lock()
	r.envs = append(r.envs, append([]string(nil), env...))
	r.mu.Unlock()
	return r.memoryRuntime.Create(ctx, name, directory, command, env)
}

func (r *envRecordingRuntime) lastEnv() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.envs) == 0 {
		return nil
	}
	return r.envs[len(r.envs)-1]
}
