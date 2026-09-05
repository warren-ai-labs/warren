package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	execution, ok := service.canonicalExecutionForSession(session.ID)
	if !ok || execution.StreamID == "" {
		t.Fatal("agent execution identity was not created")
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()
	subscription := requestResult[api.AgentEventsSubscriptionResult](t, connection, "agent.events.subscribe", map[string]any{
		"streamId": execution.StreamID,
	})
	if len(subscription.Events) == 0 {
		t.Fatal("canonical subscription returned no initial events")
	}
	var initialMessage bool
	for _, event := range subscription.Events {
		if event.Type == "message.created" && event.Payload["content"] == "Hello" {
			initialMessage = true
		}
	}
	if !initialMessage {
		t.Fatalf("initial canonical events = %#v, want Hello message", subscription.Events)
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

	var liveMessage, liveStatus, liveTurn bool
	for attempts := 0; attempts < 4 && !(liveMessage && liveStatus && liveTurn); attempts++ {
		for _, event := range readCanonicalEvents(t, connection) {
			switch event.Type {
			case "message.created":
				if event.Payload["content"] == "live prompt" {
					liveMessage = true
				}
			case "status.changed":
				if event.Payload["activity"] == string(api.AgentActivityWorking) {
					liveStatus = true
				}
			case "turn.started":
				if event.TurnID == "1" {
					liveTurn = true
				}
			}
		}
	}
	if !liveMessage || !liveStatus || !liveTurn {
		t.Fatalf("live canonical events missing message=%t status=%t turn=%t", liveMessage, liveStatus, liveTurn)
	}
	wantTurn := api.AgentTurn{ID: 1, Status: api.AgentTurnStarted}
	roster := service.Roster(context.Background())
	for _, candidate := range roster.Sessions {
		if candidate.ID != "session-agent" {
			continue
		}
		if candidate.AgentStatus == nil || candidate.AgentStatus.Activity != api.AgentActivityWorking {
			t.Fatalf("roster status = %#v, want working", candidate.AgentStatus)
		}
		if candidate.AgentTurn == nil || *candidate.AgentTurn != wantTurn {
			t.Fatalf("roster turn = %#v, want %#v", candidate.AgentTurn, wantTurn)
		}
	}
	if history := service.agentHistory("session-agent"); len(history) != 2 || history[1].Turn != 1 {
		t.Fatalf("history = %#v, want second event on turn 1", history)
	}
	canonical, err := service.canonicalHistoryPage(context.Background(), execution.StreamID, 0, 0, 100)
	if err != nil || canonical.HeadSequence < 3 {
		t.Fatalf("canonical history = %#v, err=%v; want live event, status, and turn", canonical, err)
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

func readCanonicalEvents(t *testing.T, connection interface {
	SetReadDeadline(time.Time) error
	ReadMessage() (int, []byte, error)
}) []api.CanonicalAgentEvent {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	if err := connection.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("canonical agent event never arrived: %v", err)
		}
		var message api.CanonicalAgentEventsMessage
		if json.Unmarshal(data, &message) != nil || message.Type != "agent.events" {
			continue
		}
		return message.Events
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

	execution, ok := service.canonicalExecutionForSession(session.ID)
	if !ok || execution.StreamID == "" {
		t.Fatal("agent execution identity was not created")
	}
	result := requestResult[api.AgentEventsHistoryResult](t, connection, "agent.events.history", map[string]any{
		"streamId": execution.StreamID,
		"limit":    2,
	})
	if len(result.Events) != 2 || !result.HasMore {
		t.Fatalf("history result = %#v, want a two-event latest page", result)
	}
	if result.Events[0].Sequence != 1 || result.Events[1].Sequence != 2 || result.NextAfterSequence != 2 {
		t.Fatalf("history events are not ordered: %#v", result.Events)
	}
	next := requestResult[api.AgentEventsHistoryResult](t, connection, "agent.events.history", map[string]any{
		"streamId":      execution.StreamID,
		"afterSequence": result.NextAfterSequence,
		"limit":         2,
	})
	if len(next.Events) != 2 || next.Events[0].Sequence != 3 || next.Events[1].Sequence != 4 {
		t.Fatalf("next history result = %#v, want the second page", next)
	}

	service.recordAgentEvents("session-history-ws", []api.AgentEvent{{
		Sequence: 4, Type: "tool_output", Output: "hidden",
	}}, api.AgentStatus{Activity: api.AgentActivityReady})
	updated := requestResult[api.AgentEventsHistoryResult](t, connection, "agent.events.history", map[string]any{
		"streamId":      execution.StreamID,
		"afterSequence": next.HeadSequence,
	})
	if len(updated.Events) != 1 || updated.Events[0].Payload["output"] != "hidden" {
		t.Fatalf("updated canonical history = %#v, want the appended output", updated)
	}
}

func TestAgentTurnSnapshotAndEventsOverWebSocket(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session-turn", Kind: "codex", Lifecycle: "running",
			CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
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

	execution := requestResult[api.AgentExecution](t, connection, "agent.execution.get", map[string]any{
		"executionId": service.canonicalExecutionID("session-turn"),
	})
	if execution.ActiveTurn == nil || execution.ActiveTurn.ID != 3 || execution.ActiveTurn.Status != api.AgentTurnCompleted {
		t.Fatalf("execution turn = %#v, want turn 3 completed", execution.ActiveTurn)
	}
	history := requestResult[api.AgentEventsHistoryResult](t, connection, "agent.events.history", map[string]any{
		"streamId": execution.StreamID,
	})
	if len(history.Events) < 2 {
		t.Fatalf("canonical history = %#v, want turn and provider events", history)
	}
	var foundMessage, foundTurn bool
	for _, event := range history.Events {
		if event.TurnID != "3" {
			continue
		}
		if event.Type == "message.created" && event.Payload["content"] == "done" && event.Payload["output"] == "hidden" {
			foundMessage = true
		}
		if event.Type == "turn.completed" {
			foundTurn = true
		}
	}
	if !foundMessage || !foundTurn {
		t.Fatalf("canonical turn events = %#v, want completed turn and message payload", history.Events)
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

	execution, ok := service.canonicalExecutionForSession(session.ID)
	if !ok || execution.StreamID == "" {
		t.Fatal("agent execution identity was not created")
	}
	subscription := requestResult[api.AgentEventsSubscriptionResult](t, connection, "agent.events.subscribe", map[string]any{
		"streamId": execution.StreamID,
	})
	if !subscription.Live || subscription.StreamID != execution.StreamID {
		t.Fatalf("subscription result = %#v, want a live canonical subscription", subscription)
	}
	service.outputMu.Lock()
	terminalPeers := len(service.peers[session.ID])
	agentPeers := len(service.agentPeers[session.ID])
	service.outputMu.Unlock()
	if terminalPeers != 0 || agentPeers != 1 {
		t.Fatalf("peer registration = terminal %d agent %d, want 0 and 1", terminalPeers, agentPeers)
	}

	service.recordAgentTurns(session.ID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnStarted}}, true)
	var turnEvent bool
	for attempts := 0; attempts < 2 && !turnEvent; attempts++ {
		for _, event := range readCanonicalEvents(t, connection) {
			if event.Type == "turn.started" && event.TurnID == "1" {
				turnEvent = true
			}
		}
	}
	if !turnEvent {
		t.Fatal("subscribed canonical stream did not receive turn.started")
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

	execution, ok := service.canonicalExecutionForSession(session.ID)
	if !ok || execution.StreamID == "" {
		t.Fatal("agent execution identity was not created")
	}
	// Subscribe after sequence 1: the Host returns the immutable suffix and
	// registers the socket for subsequent canonical increments.
	subResult := requestResult[api.AgentEventsSubscriptionResult](t, connection, "agent.events.subscribe", map[string]any{
		"streamId":      execution.StreamID,
		"afterSequence": 1,
	})
	if len(subResult.Events) < 2 {
		t.Fatalf("subscription events = %#v, want the suffix after sequence 1", subResult.Events)
	}
	for _, event := range subResult.Events {
		if event.Sequence <= 1 {
			t.Fatalf("subscription returned event at or before requested sequence: %#v", event)
		}
	}

	service.recordAgentEvents(session.ID, []api.AgentEvent{{Sequence: 4, Type: "tool_output", Output: "hidden"}}, api.AgentStatus{Activity: api.AgentActivityReady})
	liveEvents := readCanonicalEvents(t, connection)
	if len(liveEvents) != 1 || liveEvents[0].Type != "tool.completed" || liveEvents[0].Payload["output"] != "hidden" {
		t.Fatalf("live canonical events = %#v, want tool output payload", liveEvents)
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
