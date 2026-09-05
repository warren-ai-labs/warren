package server

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type staticAgentFinder struct {
	path string
}

func (f staticAgentFinder) Find(context.Context, string, string, time.Time) (string, error) {
	return f.path, nil
}

func TestAgentTranscriptStreamsToWeb(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-agent.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-agent", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	runtime := newMemoryOutputRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-agent", directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath},
	}
	service.lazyInit()
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()
	attachBrowser(t, connection, "session-agent", nil)
	readBrowserMessage(t, connection, "attached")
	readBinaryFrame(t, connection)
	readBrowserMessage(t, connection, "synced")

	initialStatus := readAgentStatus(t, connection)
	if initialStatus.Activity != api.AgentActivityReady {
		t.Fatalf("initial status = %#v, want ready", initialStatus)
	}
	initial := readAgentEvents(t, connection)
	if len(initial) != 1 {
		t.Fatalf("initial agent tail = %#v, want 1", initial)
	}
	if initial[0]["type"] != "assistant" {
		t.Fatalf("initial event type = %#v", initial[0]["type"])
	}

	file, err := os.OpenFile(transcriptPath, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"live prompt"}]}}` + "\n")
	closeErr := file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}

	live := readAgentEvents(t, connection)
	if len(live) != 1 || live[0]["content"] != "live prompt" {
		t.Fatalf("live agent events = %#v", live)
	}
	liveStatus := readAgentStatus(t, connection)
	if liveStatus.Activity != api.AgentActivityWorking {
		t.Fatalf("live status = %#v, want working", liveStatus)
	}
	liveTurn := readAgentTurn(t, connection)
	if liveTurn != (api.AgentTurn{ID: 1, Status: api.AgentTurnStarted}) {
		t.Fatalf("live turn = %#v, want turn 1 started", liveTurn)
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID != "session-agent" {
			continue
		}
		if candidate.AgentStatus == nil || candidate.AgentStatus.Activity != api.AgentActivityWorking {
			t.Fatalf("roster status = %#v, want working", candidate.AgentStatus)
		}
		if candidate.AgentTurn == nil || *candidate.AgentTurn != liveTurn {
			t.Fatalf("roster turn = %#v, want %#v", candidate.AgentTurn, liveTurn)
		}
	}
	if history := service.agentHistory("session-agent"); len(history) != 2 || history[1].Turn != 1 {
		t.Fatalf("history = %#v, want second event on turn 1", history)
	}
	if snapshot := service.agentSnapshot("session-agent"); snapshot.Turn != liveTurn || snapshot.Sequence != 2 {
		t.Fatalf("snapshot = %#v, want live turn and sequence 2", snapshot)
	}
}

func TestWaitAgentReadyAllowsRunningDedicatedAgentBeforeBinding(t *testing.T) {
	state, session := testSession(t)
	session.Kind = "codex"
	session.Title = "Codex"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	if err := service.waitAgentReady(context.Background(), session.ID); err != nil {
		t.Fatalf("waitAgentReady() = %v, want nil before first transcript binding", err)
	}
}

func TestEnsureAgentPrefersCodexBinding(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-bound.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-bound","cwd":"`+directory+`"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	binding := agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-bound",
		TranscriptPath: transcriptPath,
		Cwd:            directory,
	}
	if err := agent.WriteBinding(agent.BindPath("session-bound"), binding); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-bound", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-bound", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     newMemoryRuntime(t),
		AgentFinder: staticAgentFinder{path: filepath.Join(directory, "wrong-path.jsonl")},
	}
	service.lazyInit()
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a bound watcher")
	}
	if got := entry.watcher.Path(); got != transcriptPath {
		t.Fatalf("watcher path = %q, want %q", got, transcriptPath)
	}
	current, _ := state.SnapshotVersion()
	if current.Sessions[0].AgentSessionID != "thread-bound" || current.Sessions[0].TranscriptPath != transcriptPath {
		t.Fatalf("session meta = %#v", current.Sessions[0])
	}
	entry.watcher.Close()
}

func TestEnsureAgentRebindsDedicatedTranscript(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	oldPath := filepath.Join(directory, "rollout-old.jsonl")
	newPath := filepath.Join(directory, "rollout-new.jsonl")
	writeTranscriptLine := func(path, content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(
			`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"`+content+`"}]}}`+"\n",
		), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeTranscriptLine(oldPath, "Hello old")
	writeTranscriptLine(newPath, "Hello new")

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-rebind", WorkspaceID: workspaceID, Title: "Codex", CustomTitle: "Previous Topic", Kind: "codex",
		Runtime: "runtime-rebind", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     newMemoryRuntime(t),
		AgentFinder: staticAgentFinder{path: oldPath},
	}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-old",
		TranscriptPath: oldPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a watcher for the first binding")
	}
	if got := entry.watcher.Path(); got != oldPath {
		t.Fatalf("watcher path = %q, want %q", got, oldPath)
	}
	waitForAgentHistory(t, service, session.ID, "Hello old")
	epochBefore := service.currentAgentEpoch()

	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-new",
		TranscriptPath: newPath,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}
	currentSession := state.Snapshot().Sessions[0]
	entry, err = service.ensureAgent(context.Background(), currentSession)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a watcher after re-binding")
	}
	if got := entry.watcher.Path(); got != newPath {
		t.Fatalf("watcher path after rebind = %q, want %q", got, newPath)
	}
	if got := service.currentAgentEpoch(); got <= epochBefore {
		t.Fatalf("agent epoch = %d, want greater than %d", got, epochBefore)
	}
	waitForAgentHistory(t, service, session.ID, "Hello new")
	if history := service.agentHistory(session.ID); len(history) != 1 || history[0].Content != "Hello new" {
		t.Fatalf("history after rebind = %#v, want only the new transcript event", history)
	}
	snapshot, _ := state.SnapshotVersion()
	if snapshot.Sessions[0].AgentSessionID != "thread-new" || snapshot.Sessions[0].TranscriptPath != newPath || snapshot.Sessions[0].CustomTitle != "" {
		t.Fatalf("session meta after rebind = %#v", snapshot.Sessions[0])
	}
	entry.watcher.Close()
}

func TestEnsureAgentDerivesClaudePathFromSessionID(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(directory, "claude"))
	transcriptPath := agent.ClaudeTranscriptPath(agent.ClaudeProjectsRoot(), directory, "uuid-claude")
	if err := os.MkdirAll(filepath.Dir(transcriptPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(transcriptPath, []byte(
		`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"user","content":"Hello"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-claude", WorkspaceID: workspaceID, Title: "Claude", Kind: "claude",
		AgentSessionID: "uuid-claude", Runtime: "runtime-claude", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     newMemoryRuntime(t),
		AgentFinder: staticAgentFinder{path: filepath.Join(directory, "wrong-path.jsonl")},
	}
	service.lazyInit()
	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected a bound watcher")
	}
	if got := entry.watcher.Path(); got != transcriptPath {
		t.Fatalf("watcher path = %q, want %q", got, transcriptPath)
	}
	entry.watcher.Close()
}

func TestBoundTranscriptKeepsPersistedPathAfterContextMove(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	transcriptPath := filepath.Join(directory, "rollout-moved.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"uuid-moved","cwd":"`+directory+`"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	session := api.Session{
		ID: "session-moved", Kind: "claude", AgentSessionID: "uuid-moved",
		TranscriptPath: transcriptPath, Runtime: "runtime-moved", Lifecycle: "running",
		CreatedAt: time.Now().UTC(),
	}
	// The session now lives in a Terminal Group whose home is a different
	// directory. The persisted transcript is the only path that still points
	// at the CLI's original rollout, so it must win over cwd-based discovery.
	if got := service.boundTranscript(session, filepath.Join(directory, "group-home")); got != transcriptPath {
		t.Fatalf("bound transcript = %q, want %q", got, transcriptPath)
	}
}

func TestEnsureAgentDoesNotStealAnotherSessionsTranscript(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-shared.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-a","cwd":"`+directory+`"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	sessionA := api.Session{
		ID: "session-a", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-a", Lifecycle: "running", TranscriptPath: transcriptPath, CreatedAt: time.Now().UTC(),
	}
	sessionB := api.Session{
		ID: "session-b", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-b", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{sessionA, sessionB}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     newMemoryRuntime(t),
		AgentFinder: staticAgentFinder{path: transcriptPath},
	}
	service.lazyInit()
	entry, err := service.ensureAgent(context.Background(), sessionB)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher != nil {
		t.Fatal("session B must not adopt a transcript already owned by session A")
	}
}

func TestAgentStateFileReflectsShellReturn(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	session := api.Session{
		ID: "session-agent", Title: "Shell", Kind: "shell",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	service := &Service{Store: state, Runtime: newMemoryOutputRuntime(t)}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-agent",
		TranscriptPath: filepath.Join(directory, "rollout.jsonl"),
	}); err != nil {
		t.Fatal(err)
	}

	statePath := agent.StatePath(session.ID)
	if err := agent.WriteAgentState(statePath, "thread-agent", api.AgentStatus{Activity: api.AgentActivityExited}); err != nil {
		t.Fatal(err)
	}
	service.applyAgentState(session)
	if got := service.agentStatus(session.ID).Activity; got != api.AgentActivityExited {
		t.Fatalf("after SessionEnd state = %q, want exited", got)
	}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID == session.ID && (candidate.AgentStatus == nil || candidate.AgentStatus.Activity != api.AgentActivityExited) {
			t.Fatalf("roster status = %#v, want exited", candidate.AgentStatus)
		}
	}

	if err := agent.WriteAgentState(statePath, "thread-agent", api.AgentStatus{Activity: api.AgentActivityReady}); err != nil {
		t.Fatal(err)
	}
	service.applyAgentState(session)
	if got := service.agentStatus(session.ID).Activity; got != api.AgentActivityReady {
		t.Fatalf("after new SessionStart state = %q, want ready", got)
	}
}

func TestDedicatedCodexThreadEndDoesNotGraySession(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	transcriptPath := filepath.Join(directory, "rollout.jsonl")
	if err := os.WriteFile(transcriptPath, []byte{}, 0o600); err != nil {
		t.Fatal(err)
	}
	session := api.Session{
		ID: "session-codex", Title: "Codex", Kind: "codex",
		Runtime: "runtime-codex", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	service := &Service{Store: state, Runtime: newMemoryOutputRuntime(t)}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-current",
		TranscriptPath: transcriptPath,
	}); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteAgentState(agent.StatePath(session.ID), "thread-current", api.AgentStatus{Activity: api.AgentActivityExited}); err != nil {
		t.Fatal(err)
	}

	service.applyAgentState(session)
	entry := service.startAgentWatcher(session.ID, "codex", transcriptPath, false, nil)
	if entry == nil || entry.watcher == nil {
		t.Fatal("dedicated Codex thread end must not prevent the watcher from starting")
	}
	defer entry.watcher.Close()
	if got := service.agentStatus(session.ID).Activity; got == api.AgentActivityExited {
		t.Fatalf("dedicated Codex thread end changed activity to %q", got)
	}
}

func TestAgentHookStateDoesNotOverwriteNewerTranscriptStatus(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	session := api.Session{
		ID: "session-agent", Title: "Claude", Kind: "claude",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	service := &Service{Store: state, Runtime: newMemoryOutputRuntime(t)}
	service.lazyInit()

	statePath := agent.StatePath(session.ID)
	if err := agent.WriteAgentStatus(statePath, api.AgentStatus{
		Activity:  api.AgentActivityBlocked,
		Attention: &api.AgentAttention{Kind: api.AgentAttentionApproval, Reason: "permission"},
	}); err != nil {
		t.Fatal(err)
	}
	service.applyAgentState(session)
	if got := service.agentStatus(session.ID).Activity; got != api.AgentActivityBlocked {
		t.Fatalf("hook status = %q, want blocked", got)
	}

	// The transcript watcher has observed progress. Reconciliation must not
	// re-apply the same hook snapshot and resurrect the old approval badge.
	service.recordAgentStatus(session.ID, api.AgentStatus{Activity: api.AgentActivityWorking})
	service.applyAgentState(session)
	if got := service.agentStatus(session.ID).Activity; got != api.AgentActivityWorking {
		t.Fatalf("stale hook status = %q, want working", got)
	}

	// A new Stop/session.idle hook is the provider's explicit turn boundary.
	// It must clear a working transcript projection even when the final text
	// was observed on a later watcher tick.
	time.Sleep(2 * time.Millisecond)
	if err := agent.WriteAgentStatus(statePath, api.AgentStatus{Activity: api.AgentActivityReady}); err != nil {
		t.Fatal(err)
	}
	service.applyAgentState(session)
	if got := service.agentStatus(session.ID).Activity; got != api.AgentActivityReady {
		t.Fatalf("new ready hook status = %q, want ready", got)
	}

	// A new provider observation changes the file token and is applied once.
	time.Sleep(2 * time.Millisecond)
	if err := agent.WriteAgentStatus(statePath, api.AgentStatus{
		Activity:  api.AgentActivityBlocked,
		Attention: &api.AgentAttention{Kind: api.AgentAttentionInput, Reason: "question"},
	}); err != nil {
		t.Fatal(err)
	}
	service.applyAgentState(session)
	status := service.agentStatus(session.ID)
	if status.Activity != api.AgentActivityBlocked || status.Attention == nil || status.Attention.Kind != api.AgentAttentionInput {
		t.Fatalf("new hook status = %#v, want blocked/input", status)
	}
}

func TestExitedAgentActivityIsNotResurrectedByWatcher(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t)}
	service.lazyInit()

	service.recordAgentStatus("session-agent", api.AgentStatus{Activity: api.AgentActivityExited})
	service.recordAgentStatus("session-agent", api.AgentStatus{Activity: api.AgentActivityReady})
	if got := service.agentStatus("session-agent").Activity; got != api.AgentActivityExited {
		t.Fatalf("activity after watcher-style ready update = %q, want exited", got)
	}

	service.forceAgentStatus("session-agent", api.AgentStatus{Activity: api.AgentActivityReady})
	if got := service.agentStatus("session-agent").Activity; got != api.AgentActivityReady {
		t.Fatalf("activity after SessionStart reset = %q, want ready", got)
	}
}

func readAgentEvents(t *testing.T, connection interface {
	SetReadDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
}) []map[string]any {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	if err := connection.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("agent message never arrived: %v", err)
		}
		var message struct {
			Type   string           `json:"t"`
			Events []map[string]any `json:"events"`
		}
		if json.Unmarshal(data, &message) != nil || message.Type != "agent" {
			continue
		}
		return message.Events
	}
}

func readAgentStatus(t *testing.T, connection interface {
	SetReadDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
}) api.AgentStatus {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	if err := connection.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("agent status message never arrived: %v", err)
		}
		var message struct {
			Type   string          `json:"t"`
			Status api.AgentStatus `json:"status"`
		}
		if json.Unmarshal(data, &message) != nil || message.Type != "agent.status" {
			continue
		}
		return message.Status
	}
}

func readAgentTurn(t *testing.T, connection interface {
	SetReadDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
}) api.AgentTurn {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	if err := connection.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("agent turn message never arrived: %v", err)
		}
		var message api.AgentTurnMessage
		if json.Unmarshal(data, &message) != nil || message.Type != "agent.turn" {
			continue
		}
		return api.AgentTurn{ID: message.Turn, Status: message.Status}
	}
}

func TestAgentHistoryIncludesInitialAndLiveEvents(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-agent.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(strings.Join([]string{
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`,
	}, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-history", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-history", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryOutputRuntime(t)
	_ = runtime.Create(context.Background(), "runtime-history", directory, "", nil)
	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath},
	}
	service.lazyInit()
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for len(service.agentHistory("session-history")) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if history := service.agentHistory("session-history"); len(history) != 1 {
		t.Fatalf("history length = %d, want 1", len(history))
	}
}

func TestAgentHistoryPagePaginates(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	service.agentsMu.Lock()
	service.agents["session-page"] = &agentSession{}
	service.agentsMu.Unlock()
	events := make([]api.AgentEvent, 5)
	for index := range events {
		events[index] = api.AgentEvent{
			Sequence: uint64(index + 1),
			Type:     "assistant",
			Content:  strings.Repeat("x", 64),
		}
	}
	service.recordAgentEvents("session-page", events, api.AgentStatus{Activity: api.AgentActivityWorking})

	first := service.agentHistoryPage("session-page", 0, 2)
	if len(first.Events) != 2 || first.Events[0].Sequence != 4 || first.Events[1].Sequence != 5 {
		t.Fatalf("first page = %#v, want sequences 4,5", first.Events)
	}
	if first.Cursor != 4 || !first.HasMore {
		t.Fatalf("first page cursor=%d hasMore=%t, want cursor=4 hasMore=true", first.Cursor, first.HasMore)
	}

	second := service.agentHistoryPage("session-page", first.Cursor, 2)
	if len(second.Events) != 2 || second.Events[0].Sequence != 2 || second.Events[1].Sequence != 3 {
		t.Fatalf("second page = %#v, want sequences 2,3", second.Events)
	}
	if second.Cursor != 2 || !second.HasMore {
		t.Fatalf("second page cursor=%d hasMore=%t, want cursor=2 hasMore=true", second.Cursor, second.HasMore)
	}

	third := service.agentHistoryPage("session-page", second.Cursor, 2)
	if len(third.Events) != 1 || third.Events[0].Sequence != 1 {
		t.Fatalf("third page = %#v, want sequence 1", third.Events)
	}
	if third.Cursor != 1 || third.HasMore {
		t.Fatalf("third page cursor=%d hasMore=%t, want cursor=1 hasMore=false", third.Cursor, third.HasMore)
	}
}

func TestAgentHistoryConversationPrioritySkipsToolBurst(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	service.agentsMu.Lock()
	service.agents["session-conversation-priority"] = &agentSession{}
	service.agentsMu.Unlock()

	events := []api.AgentEvent{
		{Sequence: 1, Type: "user", Content: "first prompt"},
		{Sequence: 2, Type: "assistant", Content: "first answer"},
	}
	for sequence := uint64(3); sequence <= 102; sequence++ {
		events = append(events, api.AgentEvent{
			Sequence:  sequence,
			Type:      "tool_call",
			ToolName:  "shell",
			ToolInput: map[string]any{"command": "echo noisy"},
		})
	}
	events = append(events,
		api.AgentEvent{Sequence: 103, Type: "user", Content: "second prompt"},
		api.AgentEvent{Sequence: 104, Type: "assistant", Content: "second answer"},
	)
	service.recordAgentEvents(
		"session-conversation-priority",
		events,
		api.AgentStatus{Activity: api.AgentActivityReady},
	)

	first := service.agentHistoryPageWithOptions(
		"session-conversation-priority", 0, 0, 2, true,
	)
	if got := first.Events; len(got) != 2 || got[0].Sequence != 103 || got[1].Sequence != 104 {
		t.Fatalf("priority page = %#v, want conversation sequences 103,104", got)
	}
	if first.Cursor != 103 || !first.HasMore {
		t.Fatalf("priority metadata = cursor=%d hasMore=%t, want cursor=103 hasMore=true", first.Cursor, first.HasMore)
	}

	second := service.agentHistoryPageWithOptions(
		"session-conversation-priority", 0, first.Cursor, 2, true,
	)
	if got := second.Events; len(got) != 2 || got[0].Sequence != 1 || got[1].Sequence != 2 {
		t.Fatalf("older priority page = %#v, want conversation sequences 1,2", got)
	}
	if second.Cursor != 1 || second.HasMore {
		t.Fatalf("older priority metadata = cursor=%d hasMore=%t, want cursor=1 hasMore=false", second.Cursor, second.HasMore)
	}
}

func TestAgentHistoryConversationPriorityCoalescesOpenCodeDeltas(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	service.agentsMu.Lock()
	service.agents["session-conversation-deltas"] = &agentSession{}
	service.agentsMu.Unlock()

	service.recordAgentEvents(
		"session-conversation-deltas",
		[]api.AgentEvent{
			{Sequence: 1, Provider: "opencode", ID: "part-1", Type: "user", Content: "fix"},
			{Sequence: 2, Provider: "opencode", ID: "part-2", Type: "assistant", Content: "hel"},
			{Sequence: 3, Provider: "opencode", ID: "part-2", Type: "assistant", Content: "lo", ContentDelta: true},
			{Sequence: 4, Type: "tool_call", ToolName: "shell"},
		},
		api.AgentStatus{Activity: api.AgentActivityReady},
	)

	page := service.agentHistoryPageWithOptions(
		"session-conversation-deltas", 0, 0, 1, true,
	)
	if len(page.Events) != 1 || page.Events[0].Content != "hello" {
		t.Fatalf("priority page = %#v, want one coalesced assistant message", page.Events)
	}
	if page.Events[0].Sequence != 2 || page.Cursor != 2 || !page.HasMore {
		t.Fatalf("priority cursor = event=%d cursor=%d hasMore=%t, want event=2 cursor=2 hasMore=true", page.Events[0].Sequence, page.Cursor, page.HasMore)
	}

	older := service.agentHistoryPageWithOptions(
		"session-conversation-deltas", 0, page.Cursor, 1, true,
	)
	if len(older.Events) != 1 || older.Events[0].Content != "fix" || older.Events[0].Sequence != 1 {
		t.Fatalf("older priority page = %#v, want user event sequence 1", older.Events)
	}
	if older.HasMore {
		t.Fatal("older priority page unexpectedly reports more events")
	}
}

func TestAgentHistoryConversationPriorityKeepsStructuredEvents(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	service.agentsMu.Lock()
	service.agents["session-conversation-structured"] = &agentSession{}
	service.agentsMu.Unlock()

	service.recordAgentEvents(
		"session-conversation-structured",
		[]api.AgentEvent{
			{Sequence: 1, Type: "user", Content: "prompt"},
			{Sequence: 2, Type: "question", ID: "question-1", Payload: map[string]any{
				"requestId": "request-1", "state": "pending", "questions": []any{},
			}},
			{Sequence: 3, Type: "tool_call", ToolName: "shell"},
			{Sequence: 4, Type: "plan", ID: "plan-1", Payload: map[string]any{
				"planId": "plan-1", "state": "in_progress", "items": []any{},
			}},
			{Sequence: 5, Type: "assistant", Content: "answer"},
		},
		api.AgentStatus{Activity: api.AgentActivityReady},
	)

	page := service.agentHistoryPageWithOptions(
		"session-conversation-structured", 0, 0, 3, true,
	)
	if got := page.Events; len(got) != 3 || got[0].Sequence != 2 || got[1].Sequence != 4 || got[2].Sequence != 5 {
		t.Fatalf("priority page = %#v, want structured sequences 2,4 and assistant 5", got)
	}
	if page.Cursor != 2 || !page.HasMore {
		t.Fatalf("priority metadata = cursor=%d hasMore=%t, want cursor=2 hasMore=true", page.Cursor, page.HasMore)
	}

	older := service.agentHistoryPageWithOptions(
		"session-conversation-structured", 0, page.Cursor, 3, true,
	)
	if got := older.Events; len(got) != 1 || got[0].Sequence != 1 {
		t.Fatalf("older priority page = %#v, want user sequence 1", got)
	}
}

func TestSplitAgentEventsBoundsBatches(t *testing.T) {
	events := make([]api.AgentEvent, 100)
	for index := range events {
		events[index] = api.AgentEvent{
			Sequence: uint64(index + 1),
			Type:     "assistant",
			Content:  strings.Repeat("x", 10*1024),
		}
	}
	batches := splitAgentEvents(events, 256*1024)
	if len(batches) < 2 {
		t.Fatalf("batches = %d, want multiple batches", len(batches))
	}
	total := 0
	for index, batch := range batches {
		total += len(batch)
		encoded, err := json.Marshal(api.AgentMessage{Type: "agent", Events: batch})
		if err != nil {
			t.Fatal(err)
		}
		if len(encoded) > 256*1024 {
			t.Fatalf("batch %d encoded %d bytes, want <= 256 KiB", index, len(encoded))
		}
	}
	if total != len(events) {
		t.Fatalf("split total = %d, want %d", total, len(events))
	}
}

func TestAgentTailIsBounded(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	service.agentsMu.Lock()
	service.agents["session-tail"] = &agentSession{}
	service.agentsMu.Unlock()
	events := make([]api.AgentEvent, 200)
	for index := range events {
		events[index] = api.AgentEvent{
			Sequence: uint64(index + 1),
			Type:     "assistant",
			Content:  strings.Repeat("x", 4*1024),
		}
	}
	service.recordAgentEvents("session-tail", events, api.AgentStatus{Activity: api.AgentActivityWorking})

	tail := service.agentTail("session-tail", agentAttachHistoryMaxEvents, agentAttachHistoryMaxBytes)
	if len(tail) > agentAttachHistoryMaxEvents {
		t.Fatalf("tail length = %d, want <= %d", len(tail), agentAttachHistoryMaxEvents)
	}
	encoded, err := json.Marshal(api.AgentMessage{Type: "agent", Events: tail})
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > agentAttachHistoryMaxBytes {
		t.Fatalf("tail encoded %d bytes, want <= %d", len(encoded), agentAttachHistoryMaxBytes)
	}
	if got := tail[len(tail)-1].Sequence; got != 200 {
		t.Fatalf("tail newest sequence = %d, want 200", got)
	}
}

func TestAgentHistoryOverWebSocket(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-history.jsonl")
	lines := make([]string, 3)
	for index := range lines {
		lines[index] = fmt.Sprintf(
			`{"timestamp":"2026-08-16T10:00:0%dZ","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello-%d"}]}}`,
			index, index,
		)
	}
	if err := os.WriteFile(transcriptPath, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-history-ws", WorkspaceID: workspaceID, Title: "Codex", Kind: "codex",
		Runtime: "runtime-history-ws", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryOutputRuntime(t)
	_ = runtime.Create(context.Background(), "runtime-history-ws", directory, "", nil)
	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath},
	}
	service.lazyInit()
	if _, err := service.ensureAgent(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for len(service.agentHistory("session-history-ws")) < 3 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if history := service.agentHistory("session-history-ws"); len(history) != 3 {
		t.Fatalf("history length = %d, want 3", len(history))
	}

	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	result := requestResult[map[string]any](t, connection, "agent.history", map[string]any{
		"session": "session-history-ws",
		"limit":   2,
	})
	events, ok := result["events"].([]any)
	if !ok || len(events) != 2 {
		t.Fatalf("history events = %#v, want 2", result["events"])
	}
	first, ok := events[0].(map[string]any)
	if !ok || first["seq"] != float64(2) {
		t.Fatalf("first history event = %#v, want seq 2", events[0])
	}
	if result["cursor"] != float64(2) || result["hasMore"] != true {
		t.Fatalf("history metadata = cursor %v hasMore %v, want cursor 2 hasMore true", result["cursor"], result["hasMore"])
	}

	previous := requestResult[map[string]any](t, connection, "agent.history", map[string]any{
		"session": "session-history-ws",
		"before":  float64(2),
		"limit":   2,
	})
	previousEvents, ok := previous["events"].([]any)
	if !ok || len(previousEvents) != 1 {
		t.Fatalf("previous history events = %#v, want 1", previous["events"])
	}
	previousFirst, ok := previousEvents[0].(map[string]any)
	if !ok || previousFirst["seq"] != float64(1) {
		t.Fatalf("previous first event = %#v, want seq 1", previousEvents[0])
	}
	if previous["hasMore"] != false {
		t.Fatalf("previous history hasMore = %v, want false", previous["hasMore"])
	}

	service.recordAgentEvents("session-history-ws", []api.AgentEvent{{
		Sequence: 4, Type: "tool_output", Output: "hidden",
	}}, api.AgentStatus{Activity: api.AgentActivityReady})
	projected := requestResult[map[string]any](t, connection, "agent.history", map[string]any{
		"session":     "session-history-ws",
		"since":       "4",
		"wireOptions": map[string]any{"omitFields": []string{"output"}},
	})
	projectedEvents := projected["events"].([]any)
	if event := projectedEvents[0].(map[string]any); event["output"] != nil {
		t.Fatalf("history event retained omitted output: %#v", event)
	}
}

func TestAgentTranscriptChunkOverWebSocketStreamsOnlyBoundJSONL(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-raw.jsonl")
	want := "{\"type\":\"user\",\"message\":\"first\"}\n{\"type\":\"assistant\",\"message\":\"second\"}\n"
	if err := os.WriteFile(transcriptPath, []byte(want), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session-raw", Kind: "codex", Lifecycle: "running",
			TranscriptPath: transcriptPath, CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	var got strings.Builder
	var offset int64
	for {
		chunk := requestResult[api.AgentTranscriptChunk](t, connection, "agent.transcript", map[string]any{
			"session": "session-raw",
			"offset":  strconv.FormatInt(offset, 10),
			"limit":   "11",
		})
		got.WriteString(chunk.Data)
		if chunk.EOF {
			break
		}
		if chunk.Next <= offset {
			t.Fatalf("transcript chunk did not advance: %d -> %d", offset, chunk.Next)
		}
		offset = chunk.Next
	}
	if got.String() != want {
		t.Fatalf("raw transcript = %q, want %q", got.String(), want)
	}

	if _, err := service.agentTranscriptChunk(context.Background(), "session-raw", 0, agentTranscriptChunkBytes+1); err == nil {
		t.Fatal("oversized transcript chunk was accepted")
	}
	if _, err := service.agentTranscriptChunk(context.Background(), "missing", 0, 1); err == nil {
		t.Fatal("missing session was accepted")
	}
}

func TestAgentTurnSnapshotAndEventsOverWebSocket(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	service.lazyInit()
	service.recordAgentTurns("session-turn", []api.AgentTurn{{ID: 3, Status: api.AgentTurnCompleted}}, false)
	service.recordAgentEvents("session-turn", []api.AgentEvent{{
		Sequence: 1, Turn: 3, Type: "assistant", Content: "done", Output: "hidden",
	}}, api.AgentStatus{Activity: api.AgentActivityReady})

	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	snapshot := requestResult[map[string]any](t, connection, "agent.snapshot", map[string]any{
		"session": "session-turn",
	})
	turn, ok := snapshot["turn"].(map[string]any)
	if !ok || turn["id"] != float64(3) || turn["status"] != string(api.AgentTurnCompleted) {
		t.Fatalf("snapshot turn = %#v, want turn 3 completed", snapshot["turn"])
	}
	events := requestResult[[]any](t, connection, "agent.turn.events", map[string]any{
		"session":     "session-turn",
		"turn":        float64(3),
		"wireOptions": map[string]any{"omitFields": []string{"output"}},
	})
	if len(events) != 1 {
		t.Fatalf("turn events = %#v, want one event", events)
	}
	event, ok := events[0].(map[string]any)
	if !ok || event["content"] != "done" || event["output"] != nil {
		t.Fatalf("turn event = %#v, want assistant result", events[0])
	}
}

func TestAgentSubscribeDoesNotAttachTerminalOutput(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout-subscribe.jsonl")
	if err := os.WriteFile(transcriptPath, []byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{}}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-subscribe", WorkspaceID: workspaceID, Kind: "codex", AgentSessionID: "thread-subscribe",
		Runtime: "runtime-subscribe", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Path: directory, CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryOutputRuntime(t)
	if err := runtime.Create(context.Background(), session.Runtime, directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime, AgentFinder: staticAgentFinder{path: transcriptPath}}
	service.lazyInit()
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	subscription := requestResult[map[string]any](t, connection, "agent.subscribe", map[string]any{"session": session.ID})
	snapshot, ok := subscription["snapshot"].(map[string]any)
	if !ok || snapshot["epoch"] == nil || snapshot["turn"] == nil {
		t.Fatalf("subscription snapshot = %#v", subscription["snapshot"])
	}
	service.outputMu.Lock()
	terminalPeers := len(service.peers[session.ID])
	agentPeers := len(service.agentPeers[session.ID])
	service.outputMu.Unlock()
	if terminalPeers != 0 || agentPeers != 1 {
		t.Fatalf("peer registration = terminal %d agent %d, want 0 and 1", terminalPeers, agentPeers)
	}

	service.recordAgentTurns(session.ID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnStarted}}, true)
	if turn := readAgentTurn(t, connection); turn != (api.AgentTurn{ID: 1, Status: api.AgentTurnStarted}) {
		t.Fatalf("subscribed turn = %#v", turn)
	}
	service.stopOutput(session.ID, true)
	readBrowserMessage(t, connection, "exited")
}

func waitForAgentHistory(t *testing.T, service *Service, sessionID, content string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, event := range service.agentHistory(sessionID) {
			if event.Content == content {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("event %q never appeared in agent history", content)
}

func TestAgentHistorySinceRange(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "agent-events.db")

	service := &Service{
		AgentStorePath: dbPath,
	}
	service.lazyInit()

	sessionID := "session-since-test"
	events := []api.AgentEvent{
		{Sequence: 1, Type: "user", Content: "1"},
		{Sequence: 2, Type: "assistant", Content: "2"},
		{Sequence: 3, Type: "tool_call", Content: "3"},
		{Sequence: 4, Type: "tool_output", Content: "4"},
		{Sequence: 5, Type: "assistant", Content: "5"},
	}

	service.agentsMu.Lock()
	service.agents[sessionID] = &agentSession{}
	service.agentsMu.Unlock()

	service.recordAgentEvents(sessionID, events, api.AgentStatus{Activity: api.AgentActivityReady})

	// Query since 2, before 5 -> sequence 2, 3, 4
	page := service.agentHistoryPageWithOptions(sessionID, 2, 5, 10, false)
	if len(page.Events) != 3 {
		t.Fatalf("page len = %d, want 3", len(page.Events))
	}
	if page.Events[0].Sequence != 2 || page.Events[1].Sequence != 3 || page.Events[2].Sequence != 4 {
		t.Fatalf("page sequences = %d, %d, %d, want 2, 3, 4", page.Events[0].Sequence, page.Events[1].Sequence, page.Events[2].Sequence)
	}

	// Query since 4 -> sequence 4, 5
	sincePage := service.agentHistoryPageWithOptions(sessionID, 4, 0, 10, false)
	if len(sincePage.Events) != 2 {
		t.Fatalf("sincePage len = %d, want 2", len(sincePage.Events))
	}
	if sincePage.Events[0].Sequence != 4 || sincePage.Events[1].Sequence != 5 {
		t.Fatalf("sincePage sequences = %d, %d, want 4, 5", sincePage.Events[0].Sequence, sincePage.Events[1].Sequence)
	}
}

func TestAgentSubscribeWithGapEvents(t *testing.T) {
	directory := t.TempDir()
	transcriptPath := filepath.Join(directory, "rollout.jsonl")
	_ = os.WriteFile(transcriptPath, []byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`+"\n"), 0o600)

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID: "session-sub-gap", WorkspaceID: workspaceID, Kind: "codex", AgentSessionID: "thread-gap",
		Runtime: "runtime-gap", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Path: directory, CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryOutputRuntime(t)
	if err := runtime.Create(context.Background(), session.Runtime, directory, "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:          state,
		Runtime:        runtime,
		AgentFinder:    staticAgentFinder{path: transcriptPath},
		AgentStorePath: filepath.Join(directory, "events.db"),
	}
	service.lazyInit()

	events := []api.AgentEvent{
		{Sequence: 1, Type: "user", Content: "1"},
		{Sequence: 2, Type: "assistant", Content: "2", Output: "hidden"},
		{Sequence: 3, Type: "tool_call", Content: "3"},
	}
	service.agentsMu.Lock()
	service.agents[session.ID] = &agentSession{}
	service.agentsMu.Unlock()
	service.recordAgentEvents(session.ID, events, api.AgentStatus{Activity: api.AgentActivityReady})

	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	// Subscribe with lastSequence: 1 -> should return gapEvents 2 and 3
	epoch := service.currentAgentEpoch()
	subResult := requestResult[map[string]any](t, connection, "agent.subscribe", map[string]any{
		"session":      session.ID,
		"epoch":        strconv.FormatUint(epoch, 10),
		"lastSequence": 1,
		"wireOptions":  map[string]any{"omitFields": []string{"output"}},
	})
	gapEventsRaw, ok := subResult["gapEvents"].([]any)
	if !ok || len(gapEventsRaw) != 2 {
		t.Fatalf("gapEvents = %#v, want 2 events", subResult["gapEvents"])
	}
	if event, ok := gapEventsRaw[0].(map[string]any); !ok || event["output"] != nil {
		t.Fatalf("gap event retained omitted output: %#v", gapEventsRaw[0])
	}

	service.broadcastAgentBatch(session.ID, []api.AgentEvent{{Sequence: 4, Type: "tool_output", Output: "hidden"}})
	message := readBrowserMessage(t, connection, "agent")
	liveEvents := message["events"].([]any)
	if event := liveEvents[0].(map[string]any); event["output"] != nil {
		t.Fatalf("live event retained omitted output: %#v", event)
	}
}

func TestSessionSubscribeProjectsAgentTail(t *testing.T) {
	const sessionID = "session-wire-tail"
	service, _, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	service.agentsMu.Lock()
	service.agents[sessionID] = &agentSession{}
	service.agentsMu.Unlock()
	service.recordAgentEvents(sessionID, []api.AgentEvent{{
		Sequence: 1, Type: "tool_output", Output: "hidden",
	}}, api.AgentStatus{Activity: api.AgentActivityReady})

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()
	requestResult[map[string]bool](t, connection, "session.subscribe", map[string]any{
		"id":          sessionID,
		"wireOptions": map[string]any{"omitFields": []string{"output"}},
	})
	readBrowserMessage(t, connection, "synced")
	message := readBrowserMessage(t, connection, "agent")
	events := message["events"].([]any)
	if event := events[0].(map[string]any); event["output"] != nil {
		t.Fatalf("attach tail retained omitted output: %#v", event)
	}
}

func TestCodexSessionIsolationInSameWorkspace(t *testing.T) {
	directory := t.TempDir()
	dataDir := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", dataDir)

	transcriptPath1 := filepath.Join(directory, "rollout-1.jsonl")
	if err := os.WriteFile(transcriptPath1, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"`+directory+`"}}`+"\n"+
			`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Old conversation from session 1"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteBinding(agent.BindPath("session-1"), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-1",
		TranscriptPath: transcriptPath1,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session1 := api.Session{
		ID: "session-1", WorkspaceID: workspaceID, Title: "Codex 1", Kind: "codex",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		AgentSessionID: "thread-1", TranscriptPath: transcriptPath1,
	}
	session2 := api.Session{
		ID: "session-2", WorkspaceID: workspaceID, Title: "Codex 2", Kind: "codex",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session1, session2}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	runtime := newMemoryOutputRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-agent", directory, "", nil); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath1}, // Decoy finder returning session 1's path
	}
	service.AgentProviders = NewTUIAgentProviderRegistry(service)
	service.lazyInit()

	// Ensure Session 1 is bound
	entry1, err := service.ensureAgent(context.Background(), session1)
	if err != nil || entry1 == nil || entry1.handle == nil {
		t.Fatalf("session 1 failed to bind: %v", err)
	}
	defer entry1.handle.Close()

	// Ensure Session 2 before its binding appears.
	// It must NOT use fuzzy fallback (staticAgentFinder decoy) and must NOT adopt session 1's transcript.
	entry2, err := service.ensureAgent(context.Background(), session2)
	if err != nil {
		t.Fatalf("ensureAgent returned error: %v", err)
	}
	if entry2 != nil && entry2.handle != nil {
		t.Fatalf("session 2 unexpectedly bound to handle before binding was written")
	}

	// Verify session 2 did not replay session 1 events or borrow its title
	service.agentsMu.Lock()
	session2Agent := service.agents["session-2"]
	if session2Agent != nil {
		session2Agent.mu.Lock()
		if len(session2Agent.events) > 0 {
			t.Fatalf("session 2 has replayed events: %#v", session2Agent.events)
		}
		if session2Agent.titleUser != "" {
			t.Fatalf("session 2 titleUser was polluted: %q", session2Agent.titleUser)
		}
		session2Agent.mu.Unlock()
	}
	service.agentsMu.Unlock()

	// Now simulate session 2 writing its own binding and transcript
	transcriptPath2 := filepath.Join(directory, "rollout-2.jsonl")
	if err := os.WriteFile(transcriptPath2, []byte(
		`{"timestamp":"2026-08-16T10:01:00Z","type":"session_meta","payload":{"id":"thread-2","cwd":"`+directory+`"}}`+"\n"+
			`{"timestamp":"2026-08-16T10:01:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"New conversation for session 2"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteBinding(agent.BindPath("session-2"), agent.Binding{
		Provider:       "codex",
		SessionID:      "thread-2",
		TranscriptPath: transcriptPath2,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	// Reconcile session 2 now that binding exists
	entry2Bound, err := service.ensureAgent(context.Background(), session2)
	if err != nil || entry2Bound == nil || entry2Bound.handle == nil {
		t.Fatalf("session 2 failed to bind after binding was written: %v", err)
	}
	defer entry2Bound.handle.Close()

	if meta, ok := entry2Bound.handle.(interface{ BindingMetadata() (string, string) }); ok {
		if _, path := meta.BindingMetadata(); path != transcriptPath2 {
			t.Fatalf("session 2 watcher path = %q, want %q", path, transcriptPath2)
		}
	} else {
		t.Fatal("handle does not implement BindingMetadata")
	}

	// Wait briefly for watcher to process session 2's transcript
	for i := 0; i < 50; i++ {
		service.agentsMu.Lock()
		s2 := service.agents["session-2"]
		var title string
		if s2 != nil {
			s2.mu.Lock()
			title = s2.titleUser
			s2.mu.Unlock()
		}
		service.agentsMu.Unlock()
		if title == "New conversation for session 2" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	service.agentsMu.Lock()
	s2 := service.agents["session-2"]
	if s2 != nil {
		s2.mu.Lock()
		if s2.titleUser != "New conversation for session 2" {
			t.Fatalf("session 2 titleUser = %q, want %q", s2.titleUser, "New conversation for session 2")
		}
		s2.mu.Unlock()
	}
	service.agentsMu.Unlock()
}

func TestClaudeSessionIsolationInSameWorkspace(t *testing.T) {
	claudeHome := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", claudeHome)

	directory := t.TempDir()
	projectsRoot := filepath.Join(claudeHome, "projects")

	claudeID1 := "claude-uuid-1"
	claudeID2 := "claude-uuid-2"

	transcriptPath1 := agent.ClaudeTranscriptPath(projectsRoot, directory, claudeID1)
	if err := os.MkdirAll(filepath.Dir(transcriptPath1), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(transcriptPath1, []byte(
		`{"type":"summary","summary":"Claude 1 conversation","leafUuid":null}`+"\n"+
			`{"type":"user","uuid":"u1","cwd":"`+directory+`","message":{"role":"user","content":"Initial prompt for session 1"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session1 := api.Session{
		ID: "session-claude-1", WorkspaceID: workspaceID, Title: "Claude 1", Kind: "claude",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		AgentSessionID: claudeID1, TranscriptPath: transcriptPath1,
	}
	session2 := api.Session{
		ID: "session-claude-2", WorkspaceID: workspaceID, Title: "Claude 2", Kind: "claude",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		AgentSessionID: claudeID2,
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session1, session2}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	runtime := newMemoryOutputRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-agent", directory, "", nil); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath1}, // Decoy finder returning session 1's path
	}
	service.AgentProviders = NewTUIAgentProviderRegistry(service)
	service.lazyInit()

	// Ensure Session 1 is bound
	entry1, err := service.ensureAgent(context.Background(), session1)
	if err != nil || entry1 == nil || entry1.handle == nil {
		t.Fatalf("session 1 failed to bind: %v", err)
	}
	defer entry1.handle.Close()

	// Ensure Session 2 before its transcript file is written by Claude CLI.
	// It must NOT use fuzzy fallback (staticAgentFinder decoy) and must NOT adopt session 1's transcript.
	entry2, err := service.ensureAgent(context.Background(), session2)
	if err != nil {
		t.Fatalf("ensureAgent returned error: %v", err)
	}
	if entry2 != nil && entry2.handle != nil {
		t.Fatalf("session 2 unexpectedly bound to handle before file was written")
	}

	// Verify session 2 did not replay session 1 events or borrow its title
	service.agentsMu.Lock()
	session2Agent := service.agents["session-claude-2"]
	if session2Agent != nil {
		session2Agent.mu.Lock()
		if len(session2Agent.events) > 0 {
			t.Fatalf("session 2 has replayed events: %#v", session2Agent.events)
		}
		if session2Agent.titleUser != "" {
			t.Fatalf("session 2 titleUser was polluted: %q", session2Agent.titleUser)
		}
		session2Agent.mu.Unlock()
	}
	service.agentsMu.Unlock()

	// Now simulate Claude writing its transcript for session 2
	transcriptPath2 := agent.ClaudeTranscriptPath(projectsRoot, directory, claudeID2)
	if err := os.WriteFile(transcriptPath2, []byte(
		`{"type":"summary","summary":"Claude 2 conversation","leafUuid":null}`+"\n"+
			`{"type":"user","uuid":"u2","cwd":"`+directory+`","message":{"role":"user","content":"New prompt for session 2"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	// Reconcile session 2 now that file exists
	entry2Bound, err := service.ensureAgent(context.Background(), session2)
	if err != nil || entry2Bound == nil || entry2Bound.handle == nil {
		t.Fatalf("session 2 failed to bind after transcript was written: %v", err)
	}
	defer entry2Bound.handle.Close()

	if meta, ok := entry2Bound.handle.(interface{ BindingMetadata() (string, string) }); ok {
		if _, path := meta.BindingMetadata(); path != transcriptPath2 {
			t.Fatalf("session 2 watcher path = %q, want %q", path, transcriptPath2)
		}
	} else {
		t.Fatal("handle does not implement BindingMetadata")
	}
}

func TestAntigravitySessionIsolationInSameWorkspace(t *testing.T) {
	antigravityHome := t.TempDir()
	t.Setenv("ANTIGRAVITY_HOME", antigravityHome)

	directory := t.TempDir()

	// Populate conversation_summaries.db with a past conversation in this workspace
	dbPath := filepath.Join(antigravityHome, "conversation_summaries.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE conversation_summaries (
		conversation_id TEXT PRIMARY KEY,
		workspace_uris TEXT,
		last_modified_time TEXT
	)`)
	if err != nil {
		t.Fatal(err)
	}

	convoID1 := "convo-1"
	transcriptDir1 := filepath.Join(antigravityHome, "brain", convoID1, ".system_generated", "logs")
	if err := os.MkdirAll(transcriptDir1, 0o755); err != nil {
		t.Fatal(err)
	}
	transcriptPath1 := filepath.Join(transcriptDir1, "transcript.jsonl")
	if err := os.WriteFile(transcriptPath1, []byte(
		`{"timestamp":"2026-08-16T10:00:00Z","type":"USER_INPUT","content":"Prior conversation"}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err = db.Exec(
		`INSERT INTO conversation_summaries VALUES (?, ?, ?)`,
		convoID1,
		`["`+directory+`"]`,
		time.Now().UTC().Format(time.RFC3339),
	)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session1 := api.Session{
		ID: "session-agy-1", WorkspaceID: workspaceID, Title: "Antigravity 1", Kind: "antigravity",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		AgentSessionID: convoID1, TranscriptPath: transcriptPath1,
	}
	session2 := api.Session{
		ID: "session-agy-2", WorkspaceID: workspaceID, Title: "Antigravity 2", Kind: "antigravity",
		Runtime: "runtime-agent", Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session1, session2}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	runtime := newMemoryOutputRuntime(t)
	if err := runtime.Create(context.Background(), "runtime-agent", directory, "", nil); err != nil {
		t.Fatal(err)
	}

	service := &Service{
		Store:       state,
		Runtime:     runtime,
		AgentFinder: staticAgentFinder{path: transcriptPath1}, // Decoy finder returning session 1's path
	}
	service.AgentProviders = NewTUIAgentProviderRegistry(service)
	service.lazyInit()

	// Ensure Session 1 is bound
	entry1, err := service.ensureAgent(context.Background(), session1)
	if err != nil || entry1 == nil || entry1.handle == nil {
		t.Fatalf("session 1 failed to bind: %v", err)
	}
	defer entry1.handle.Close()

	// Ensure Session 2 before its binding appears.
	// It must NOT adopt convo 1 from DB or finder fallback.
	entry2, err := service.ensureAgent(context.Background(), session2)
	if err != nil {
		t.Fatalf("ensureAgent returned error: %v", err)
	}
	if entry2 != nil && entry2.handle != nil {
		t.Fatalf("session 2 unexpectedly bound to handle before binding was written")
	}

	// Verify session 2 did not borrow session 1
	service.agentsMu.Lock()
	session2Agent := service.agents["session-agy-2"]
	if session2Agent != nil {
		session2Agent.mu.Lock()
		if len(session2Agent.events) > 0 {
			t.Fatalf("session 2 has replayed events: %#v", session2Agent.events)
		}
		if session2Agent.titleUser != "" {
			t.Fatalf("session 2 titleUser was polluted: %q", session2Agent.titleUser)
		}
		session2Agent.mu.Unlock()
	}
	service.agentsMu.Unlock()

	// Now simulate session 2 writing its own binding and transcript
	convoID2 := "convo-2"
	transcriptDir2 := filepath.Join(antigravityHome, "brain", convoID2, ".system_generated", "logs")
	if err := os.MkdirAll(transcriptDir2, 0o755); err != nil {
		t.Fatal(err)
	}
	transcriptPath2 := filepath.Join(transcriptDir2, "transcript.jsonl")
	if err := os.WriteFile(transcriptPath2, []byte(
		`{"timestamp":"2026-08-16T10:01:00Z","type":"USER_INPUT","content":"Fresh convo 2 prompt"}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := agent.WriteBinding(agent.BindPath("session-agy-2"), agent.Binding{
		Provider:       "antigravity",
		SessionID:      convoID2,
		TranscriptPath: transcriptPath2,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	// Reconcile session 2 now that binding exists
	entry2Bound, err := service.ensureAgent(context.Background(), session2)
	if err != nil || entry2Bound == nil || entry2Bound.handle == nil {
		t.Fatalf("session 2 failed to bind after binding was written: %v", err)
	}
	defer entry2Bound.handle.Close()

	if meta, ok := entry2Bound.handle.(interface{ BindingMetadata() (string, string) }); ok {
		if _, path := meta.BindingMetadata(); path != transcriptPath2 {
			t.Fatalf("session 2 watcher path = %q, want %q", path, transcriptPath2)
		}
	} else {
		t.Fatal("handle does not implement BindingMetadata")
	}
}

func TestAgentHistoryClipsToolOutput(t *testing.T) {
	service := &Service{
		AgentStorePath: filepath.Join(t.TempDir(), "agent_store.db"),
	}
	service.lazyInit()
	sessionID := "session-clip-test"

	service.agentsMu.Lock()
	service.agents[sessionID] = &agentSession{}
	service.agentsMu.Unlock()

	longOutput := strings.Repeat("A", 10000)
	longContent := strings.Repeat("B", 50000)
	events := []api.AgentEvent{
		{
			Sequence: 1,
			Type:     "tool_output",
			Output:   longOutput,
		},
		{
			Sequence: 2,
			Type:     "message",
			Role:     "assistant",
			Content:  longContent,
		},
		{
			Sequence: 3,
			Type:     "tool_call",
			ToolName: "execute",
			ToolInput: map[string]any{
				"cmd": strings.Repeat("C", 8000),
			},
		},
	}

	service.recordAgentEvents(sessionID, events, api.AgentStatus{Activity: api.AgentActivityReady})

	// Default clipping (4096)
	page := service.agentHistoryPageWithOptions(sessionID, 0, 0, 10, false)
	if len(page.Events) != 3 {
		t.Fatalf("expected 3 events, got %d", len(page.Events))
	}

	// Tool output must be clipped to 4096 runes + ellipsis
	if len(page.Events[0].Output) > 4096+len("…") {
		t.Fatalf("tool output length = %d, want <= %d", len(page.Events[0].Output), 4096+len("…"))
	}
	if !strings.HasSuffix(page.Events[0].Output, "…") {
		t.Fatalf("expected tool output to end with ellipsis")
	}

	// Assistant conversational Content must NEVER be clipped regardless of size
	if len(page.Events[1].Content) != 50000 {
		t.Fatalf("assistant content was clipped: got len %d, want 50000", len(page.Events[1].Content))
	}

	// Tool input must be clipped
	inputMap, ok := page.Events[2].ToolInput.(map[string]any)
	if !ok {
		t.Fatalf("expected tool input to be map[string]any, got %T", page.Events[2].ToolInput)
	}
	cmdStr, ok := inputMap["cmd"].(string)
	if !ok || len(cmdStr) > 4096+len("…") {
		t.Fatalf("tool input cmd length = %d, want <= %d", len(cmdStr), 4096+len("…"))
	}

}

func TestClipWireEvents(t *testing.T) {
	// Test multi-byte UTF-8 string truncation
	chineseStr := strings.Repeat("中", 100)
	clipped := truncateString(chineseStr, 10)
	if clipped != strings.Repeat("中", 10)+"…" {
		t.Fatalf("unexpected utf-8 truncation result: %s", clipped)
	}

	// Test nested tool input
	nested := map[string]any{
		"nested": []any{
			map[string]any{
				"key": strings.Repeat("X", 20),
			},
			strings.Repeat("Y", 20),
		},
	}
	limited := limitToolInput(nested, 5).(map[string]any)
	arr := limited["nested"].([]any)
	innerMap := arr[0].(map[string]any)
	if innerMap["key"] != "XXXXX…" {
		t.Fatalf("inner key = %v, want XXXXX…", innerMap["key"])
	}
	if arr[1] != "YYYYY…" {
		t.Fatalf("inner array item = %v, want YYYYY…", arr[1])
	}
}

func TestProjectWireEventsOmitsRequestedFields(t *testing.T) {
	original := []api.AgentEvent{{
		Sequence:  1,
		Type:      "tool_output",
		Output:    "secret output",
		ToolInput: map[string]any{"cmd": "pwd"},
		Files:     []string{"result.txt"},
		Payload:   map[string]any{"state": "done"},
		Usage:     &api.AgentUsage{TotalTokens: 3},
	}}

	projected := projectWireEvents(original, wireOptions{omitFields: map[string]struct{}{
		"output": {}, "toolInput": {}, "files": {}, "payload": {}, "usage": {},
	}})
	if projected[0].Output != "" || projected[0].ToolInput != nil || projected[0].Files != nil || projected[0].Payload != nil || projected[0].Usage != nil {
		t.Fatalf("requested fields were not omitted: %#v", projected[0])
	}
	if original[0].Output == "" || original[0].ToolInput == nil || original[0].Files == nil || original[0].Payload == nil || original[0].Usage == nil {
		t.Fatalf("wire projection mutated the source event: %#v", original[0])
	}
	encoded, err := json.Marshal(projected[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"output", "toolInput", "files", "payload", "usage"} {
		if bytes.Contains(encoded, []byte(`"`+field+`"`)) {
			t.Fatalf("JSON contains omitted field %q: %s", field, encoded)
		}
	}
}

func TestPeerProjectsAgentEventsPerSession(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	var messages []api.AgentMessage
	messageReady := make(chan struct{}, 2)
	peer := newRelayPeer(&HTTPServer{Service: service}, func(item outboundMessage) bool {
		var message api.AgentMessage
		if err := json.Unmarshal(item.data, &message); err != nil {
			t.Fatal(err)
		}
		messages = append(messages, message)
		messageReady <- struct{}{}
		return true
	})
	peer.agentWireOptions = map[string]wireOptions{
		"lean": {omitFields: map[string]struct{}{"output": {}}},
		"full": {},
	}
	event := []api.AgentEvent{{Sequence: 1, Type: "tool_output", Output: "visible"}}
	if err := peer.enqueueAgentEvents("lean", event); err != nil {
		t.Fatal(err)
	}
	if err := peer.enqueueAgentEvents("full", event); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		select {
		case <-messageReady:
		case <-time.After(time.Second):
			t.Fatal("timed out waiting for Relay peer writer")
		}
	}
	if len(messages) != 2 || messages[0].Events[0].Output != "" || messages[1].Events[0].Output != "visible" {
		t.Fatalf("per-session projection = %#v", messages)
	}
	peer.close()
}

func TestParseWireOptionsRejectsUnsupportedFields(t *testing.T) {
	_, err := parseWireOptions(map[string]any{
		"wireOptions": map[string]any{"omitFields": []any{"content"}},
	})
	if err == nil || !strings.Contains(err.Error(), "content") {
		t.Fatalf("protected field error = %v", err)
	}
}
