package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestRebindClaudeResetsTitleAndDropsHistory(t *testing.T) {
	claudeHome := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", claudeHome)
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	projectsRoot := filepath.Join(claudeHome, "projects")

	path1 := agent.ClaudeTranscriptPath(projectsRoot, directory, "claude-session-1")
	if err := os.MkdirAll(filepath.Dir(path1), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path1, []byte(
		`{"type":"summary","summary":"Claude 1","leafUuid":null}`+"\n"+
			`{"type":"user","uuid":"u1","cwd":"`+directory+`","message":{"role":"user","content":"Claude prompt 1"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	path2 := agent.ClaudeTranscriptPath(projectsRoot, directory, "claude-session-2")
	if err := os.WriteFile(path2, []byte(
		`{"type":"summary","summary":"Claude 2","leafUuid":null}`+"\n"+
			`{"type":"user","uuid":"u2","cwd":"`+directory+`","message":{"role":"user","content":"Claude prompt 2"}}`+"\n",
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
		ID:             "session-claude",
		WorkspaceID:    workspaceID,
		Title:          "Claude",
		CustomTitle:    "Initial Claude Topic",
		Kind:           "claude",
		Runtime:        "runtime-claude",
		Lifecycle:      "running",
		AgentSessionID: "claude-session-1",
		TranscriptPath: path1,
		CreatedAt:      time.Now().UTC(),
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
		AgentFinder: staticAgentFinder{path: path1},
	}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "claude",
		SessionID:      "claude-session-1",
		TranscriptPath: path1,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected watcher for initial claude session")
	}
	if got := entry.watcher.Path(); got != path1 {
		t.Fatalf("watcher path = %q, want %q", got, path1)
	}
	waitForAgentHistory(t, service, session.ID, "Claude prompt 1")
	epochBefore := service.currentAgentEpoch()

	// Rebind to session 2 (e.g. /clear in Claude CLI)
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "claude",
		SessionID:      "claude-session-2",
		TranscriptPath: path2,
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
		t.Fatal("expected watcher after claude rebind")
	}
	if got := entry.watcher.Path(); got != path2 {
		t.Fatalf("watcher path after rebind = %q, want %q", got, path2)
	}
	if got := service.currentAgentEpoch(); got <= epochBefore {
		t.Fatalf("agent epoch = %d, want greater than %d", got, epochBefore)
	}
	waitForAgentHistory(t, service, session.ID, "Claude prompt 2")
	history := service.agentHistory(session.ID)
	if len(history) != 1 || history[0].Content != "Claude prompt 2" {
		t.Fatalf("history after rebind = %#v, want only new transcript event", history)
	}
	snapshot := state.Snapshot()
	if snapshot.Sessions[0].AgentSessionID != "claude-session-2" || snapshot.Sessions[0].TranscriptPath != path2 || snapshot.Sessions[0].CustomTitle != "" {
		t.Fatalf("session state after rebind = %#v", snapshot.Sessions[0])
	}
	entry.watcher.Close()
}

func TestRebindOpenCodeResetsTitleAndDropsHistory(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)

	cache1 := filepath.Join(directory, "cache-1.jsonl")
	cache2 := filepath.Join(directory, "cache-2.jsonl")
	writeTranscriptLine := func(path, content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(
			`{"messageId":"msg-`+content+`","role":"assistant","parts":[{"id":"part-`+content+`","type":"text","text":"`+content+`"}],"time":{"created":1725000000000}}`+"\n",
		), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeTranscriptLine(cache1, "OpenCode msg 1")
	writeTranscriptLine(cache2, "OpenCode msg 2")

	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	session := api.Session{
		ID:          "session-opencode",
		WorkspaceID: workspaceID,
		Title:       "OpenCode",
		CustomTitle: "Initial OpenCode Topic",
		Kind:        "opencode",
		Runtime:     "runtime-opencode",
		Lifecycle:   "running",
		CreatedAt:   time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	finder := &testOpenCodeFinder{binding: agent.OpenCodeBinding{
		Provider:      "opencode",
		SessionID:     "ses_1",
		Backend:       "sqlite",
		DatabasePath:  filepath.Join(directory, "missing.db"),
		CachePath:     cache1,
		WorkspacePath: directory,
	}}
	service := &Service{Store: state, Runtime: newMemoryRuntime(t), AgentFinder: finder}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:  "opencode",
		SessionID: "ses_1",
		Cwd:       directory,
	}); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil || entry.tailer == nil {
		t.Fatal("expected tailer and watcher for initial OpenCode")
	}
	if got := entry.watcher.Path(); got != cache1 {
		t.Fatalf("watcher path = %q, want %q", got, cache1)
	}
	waitForAgentHistory(t, service, session.ID, "OpenCode msg 1")
	epochBefore := service.currentAgentEpoch()

	// Rebind via plugin writing new session binding (e.g. /new in OpenCode)
	finder.binding.SessionID = "ses_2"
	finder.binding.CachePath = cache2
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:  "opencode",
		SessionID: "ses_2",
		Cwd:       directory,
	}); err != nil {
		t.Fatal(err)
	}

	currentSession := state.Snapshot().Sessions[0]
	entry, err = service.ensureAgent(context.Background(), currentSession)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected watcher after OpenCode rebind")
	}
	if got := entry.watcher.Path(); got != cache2 {
		t.Fatalf("watcher path after rebind = %q, want %q", got, cache2)
	}
	if got := service.currentAgentEpoch(); got <= epochBefore {
		t.Fatalf("agent epoch = %d, want greater than %d", got, epochBefore)
	}
	waitForAgentHistory(t, service, session.ID, "OpenCode msg 2")
	history := service.agentHistory(session.ID)
	if len(history) != 1 || history[0].Content != "OpenCode msg 2" {
		t.Fatalf("history after rebind = %#v, want only new transcript event", history)
	}
	snapshot := state.Snapshot()
	if snapshot.Sessions[0].AgentSessionID != "ses_2" || snapshot.Sessions[0].TranscriptPath != cache2 || snapshot.Sessions[0].CustomTitle != "" {
		t.Fatalf("session state after rebind = %#v", snapshot.Sessions[0])
	}
	entry.watcher.Close()
}

func TestRebindPiResetsTitleAndDropsHistory(t *testing.T) {
	piDir := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", piDir)
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)

	path1 := filepath.Join(piDir, "2026-09-01T10-00-00-000Z_pi-session-1.jsonl")
	if err := os.WriteFile(path1, []byte(
		`{"type":"session","version":3,"id":"pi-session-1","timestamp":"2026-09-01T10:00:00.000Z","cwd":"`+directory+`"}`+"\n"+
			`{"type":"message","id":"m1","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"assistant","content":"Pi msg 1"}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	path2 := filepath.Join(piDir, "2026-09-01T11-00-00-000Z_pi-session-2.jsonl")
	if err := os.WriteFile(path2, []byte(
		`{"type":"session","version":3,"id":"pi-session-2","timestamp":"2026-09-01T11:00:00.000Z","cwd":"`+directory+`"}`+"\n"+
			`{"type":"message","id":"m2","timestamp":"2026-09-01T11:00:01.000Z","message":{"role":"assistant","content":"Pi msg 2"}}`+"\n",
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
		ID:          "session-pi",
		WorkspaceID: workspaceID,
		Title:       "Pi",
		CustomTitle: "Initial Pi Topic",
		Kind:        "pi",
		Runtime:     "runtime-pi",
		Lifecycle:   "running",
		CreatedAt:   time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{Store: state, Runtime: newMemoryRuntime(t), AgentFinder: staticAgentFinder{path: path1}}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "pi",
		SessionID:      "pi-session-1",
		TranscriptPath: path1,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected watcher for initial pi session")
	}
	if got := entry.watcher.Path(); got != path1 {
		t.Fatalf("watcher path = %q, want %q", got, path1)
	}
	waitForAgentHistory(t, service, session.ID, "Pi msg 1")
	epochBefore := service.currentAgentEpoch()

	// Rebind to session 2 (e.g. /new or /fork in Pi)
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "pi",
		SessionID:      "pi-session-2",
		TranscriptPath: path2,
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
		t.Fatal("expected watcher after pi rebind")
	}
	if got := entry.watcher.Path(); got != path2 {
		t.Fatalf("watcher path after rebind = %q, want %q", got, path2)
	}
	if got := service.currentAgentEpoch(); got <= epochBefore {
		t.Fatalf("agent epoch = %d, want greater than %d", got, epochBefore)
	}
	waitForAgentHistory(t, service, session.ID, "Pi msg 2")
	history := service.agentHistory(session.ID)
	if len(history) != 1 || history[0].Content != "Pi msg 2" {
		t.Fatalf("history after rebind = %#v, want only new transcript event", history)
	}
	snapshot := state.Snapshot()
	if snapshot.Sessions[0].AgentSessionID != "pi-session-2" || snapshot.Sessions[0].TranscriptPath != path2 || snapshot.Sessions[0].CustomTitle != "" {
		t.Fatalf("session state after rebind = %#v", snapshot.Sessions[0])
	}
	entry.watcher.Close()
}

func TestRebindQoderResetsTitleAndDropsHistory(t *testing.T) {
	qoderDir := t.TempDir()
	t.Setenv("QODER_CONFIG_DIR", qoderDir)
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)

	slugDir := filepath.Join(qoderDir, "projects", "myproject")
	if err := os.MkdirAll(slugDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path1 := filepath.Join(slugDir, "qoder-session-1.jsonl")
	if err := os.WriteFile(path1, []byte(
		`{"type":"session","version":1,"id":"qoder-session-1","timestamp":"2026-09-01T10:00:00.000Z","cwd":"`+directory+`"}`+"\n"+
			`{"type":"message","id":"m1","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Qoder msg 1"}]}}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	path2 := filepath.Join(slugDir, "qoder-session-2.jsonl")
	if err := os.WriteFile(path2, []byte(
		`{"type":"session","version":1,"id":"qoder-session-2","timestamp":"2026-09-01T11:00:00.000Z","cwd":"`+directory+`"}`+"\n"+
			`{"type":"message","id":"m2","timestamp":"2026-09-01T11:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Qoder msg 2"}]}}`+"\n",
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
		ID:          "session-qoder",
		WorkspaceID: workspaceID,
		Title:       "Qoder",
		CustomTitle: "Initial Qoder Topic",
		Kind:        "qoder",
		Runtime:     "runtime-qoder",
		Lifecycle:   "running",
		CreatedAt:   time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{Store: state, Runtime: newMemoryRuntime(t), AgentFinder: staticAgentFinder{path: path1}}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "qoder",
		SessionID:      "qoder-session-1",
		TranscriptPath: path1,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected watcher for initial qoder session")
	}
	if got := entry.watcher.Path(); got != path1 {
		t.Fatalf("watcher path = %q, want %q", got, path1)
	}
	waitForAgentHistory(t, service, session.ID, "Qoder msg 1")
	epochBefore := service.currentAgentEpoch()

	// Rebind to session 2
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "qoder",
		SessionID:      "qoder-session-2",
		TranscriptPath: path2,
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
		t.Fatal("expected watcher after qoder rebind")
	}
	if got := entry.watcher.Path(); got != path2 {
		t.Fatalf("watcher path after rebind = %q, want %q", got, path2)
	}
	if got := service.currentAgentEpoch(); got <= epochBefore {
		t.Fatalf("agent epoch = %d, want greater than %d", got, epochBefore)
	}
	waitForAgentHistory(t, service, session.ID, "Qoder msg 2")
	history := service.agentHistory(session.ID)
	if len(history) != 1 || history[0].Content != "Qoder msg 2" {
		t.Fatalf("history after rebind = %#v, want only new transcript event", history)
	}
	snapshot := state.Snapshot()
	if snapshot.Sessions[0].AgentSessionID != "qoder-session-2" || snapshot.Sessions[0].TranscriptPath != path2 || snapshot.Sessions[0].CustomTitle != "" {
		t.Fatalf("session state after rebind = %#v", snapshot.Sessions[0])
	}
	entry.watcher.Close()
}

func TestRebindAntigravityResetsTitleAndDropsHistory(t *testing.T) {
	agHome := t.TempDir()
	t.Setenv("ANTIGRAVITY_HOME", agHome)
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)

	dir1 := filepath.Join(agHome, "brain", "ag-convo-1", ".system_generated", "logs")
	if err := os.MkdirAll(dir1, 0o755); err != nil {
		t.Fatal(err)
	}
	path1 := filepath.Join(dir1, "transcript.jsonl")
	if err := os.WriteFile(path1, []byte(
		`{"step_index":1,"type":"USER_INPUT","content":"AG input 1","created_at":"2026-09-01T10:00:00Z"}`+"\n"+
			`{"step_index":2,"type":"PLANNER_RESPONSE","content":"Antigravity response 1","created_at":"2026-09-01T10:00:01Z"}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}

	dir2 := filepath.Join(agHome, "brain", "ag-convo-2", ".system_generated", "logs")
	if err := os.MkdirAll(dir2, 0o755); err != nil {
		t.Fatal(err)
	}
	path2 := filepath.Join(dir2, "transcript.jsonl")
	if err := os.WriteFile(path2, []byte(
		`{"step_index":1,"type":"USER_INPUT","content":"AG input 2","created_at":"2026-09-01T11:00:00Z"}`+"\n"+
			`{"step_index":2,"type":"PLANNER_RESPONSE","content":"Antigravity response 2","created_at":"2026-09-01T11:00:01Z"}`+"\n",
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
		ID:          "session-ag",
		WorkspaceID: workspaceID,
		Title:       "Antigravity",
		CustomTitle: "Initial AG Topic",
		Kind:        "antigravity",
		Runtime:     "runtime-ag",
		Lifecycle:   "running",
		CreatedAt:   time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{Store: state, Runtime: newMemoryRuntime(t), AgentFinder: staticAgentFinder{path: path1}}
	service.lazyInit()
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "antigravity",
		SessionID:      "ag-convo-1",
		TranscriptPath: path1,
		Cwd:            directory,
	}); err != nil {
		t.Fatal(err)
	}

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.watcher == nil {
		t.Fatal("expected watcher for initial antigravity session")
	}
	if got := entry.watcher.Path(); got != path1 {
		t.Fatalf("watcher path = %q, want %q", got, path1)
	}
	waitForAgentHistory(t, service, session.ID, "Antigravity response 1")
	epochBefore := service.currentAgentEpoch()

	// Rebind to conversation 2
	if err := agent.WriteBinding(agent.BindPath(session.ID), agent.Binding{
		Provider:       "antigravity",
		SessionID:      "ag-convo-2",
		TranscriptPath: path2,
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
		t.Fatal("expected watcher after antigravity rebind")
	}
	if got := entry.watcher.Path(); got != path2 {
		t.Fatalf("watcher path after rebind = %q, want %q", got, path2)
	}
	if got := service.currentAgentEpoch(); got <= epochBefore {
		t.Fatalf("agent epoch = %d, want greater than %d", got, epochBefore)
	}
	waitForAgentHistory(t, service, session.ID, "Antigravity response 2")
	history := service.agentHistory(session.ID)
	foundNew := false
	for _, evt := range history {
		if evt.Content == "Antigravity response 2" {
			foundNew = true
		}
		if evt.Content == "Antigravity response 1" {
			t.Fatalf("history after rebind contains stale event from previous conversation")
		}
	}
	if !foundNew {
		t.Fatalf("history after rebind missing new response: %#v", history)
	}
	snapshot := state.Snapshot()
	if snapshot.Sessions[0].AgentSessionID != "ag-convo-2" || snapshot.Sessions[0].TranscriptPath != path2 || snapshot.Sessions[0].CustomTitle != "" {
		t.Fatalf("session state after rebind = %#v", snapshot.Sessions[0])
	}
	entry.watcher.Close()
}

func TestAgentProviderRebindResetsCustomTitle(t *testing.T) {
	directory := t.TempDir()
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	workspaceID := store.NewID()
	session := api.Session{
		ID:          "session-provider-rebind",
		WorkspaceID: workspaceID,
		Title:       "Codex",
		CustomTitle: "Old Custom Title",
		Kind:        "codex",
		Runtime:     "runtime-1",
		Lifecycle:   "running",
		CreatedAt:   time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Workspaces = []api.Workspace{{ID: workspaceID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		value.Sessions = []api.Session{session}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	provider := &lifecycleTestProvider{
		kind:  "codex",
		ready: true,
		key:   "codex|thread-1|path-1",
	}
	service := &Service{
		Store:          state,
		AgentProviders: NewAgentProviderRegistry(provider),
	}
	service.lazyInit()

	entry, err := service.ensureAgent(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.handle == nil {
		t.Fatal("expected handle to be active")
	}
	if state.Snapshot().Sessions[0].CustomTitle != "Old Custom Title" {
		t.Fatalf("custom title before rebind = %q", state.Snapshot().Sessions[0].CustomTitle)
	}
	handle1 := entry.handle.(*lifecycleTestHandle)

	// Switch key to simulate rebind to a new thread
	provider.mu.Lock()
	provider.key = "codex|thread-2|path-2"
	provider.mu.Unlock()

	entry, err = service.ensureAgent(context.Background(), state.Snapshot().Sessions[0])
	if err != nil {
		t.Fatal(err)
	}
	if entry == nil || entry.handle == nil || entry.handle == handle1 {
		t.Fatal("expected new handle to be active after rebind")
	}
	if _, closed := handle1.counts(); closed == 0 {
		t.Fatal("expected handle1 to be closed after rebind")
	}
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "" {
		t.Fatalf("custom title after rebind = %q, want empty", got)
	}
}
