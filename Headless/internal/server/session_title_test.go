package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestSessionTitleUsesFirstRealExchangeAndIgnoresTools(t *testing.T) {
	var requests atomic.Int32
	requestBody := make(chan string, 4)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode title request: %v", err)
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		if len(body.Messages) != 1 {
			t.Errorf("title request messages = %d, want 1", len(body.Messages))
		} else {
			requestBody <- body.Messages[0].Content
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"Title: Fix reconnect"}}]}`))
	}))
	defer server.Close()

	state, sessionID := newSessionTitleStore(t)
	service := &Service{
		Store: state,
		Settings: settings.Settings{
			OpenAIBaseURL:      server.URL + "/v1",
			OpenAIModel:        "title-model",
			OpenAIKey:          "test-key",
			OpenAITitleEnabled: true,
		},
	}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}

	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "codex", Type: "user", Content: "# AGENTS.md instructions for warren"},
		{Provider: "codex", Type: "tool_call", Content: "do not use this as a title"},
		{Provider: "codex", Type: "user", Content: "Fix the reconnect flow"},
		{Provider: "codex", Type: "assistant", Content: "I will inspect the reconnect path"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})

	expireAgentTitleWait(t, service, sessionID)
	if got := waitForSessionTitle(t, state, sessionID); got != "Fix reconnect" {
		t.Fatalf("generated title = %q, want Fix reconnect", got)
	}
	body := <-requestBody
	if !strings.Contains(body, "Fix the reconnect flow") || !strings.Contains(body, "I will inspect the reconnect path") {
		t.Fatalf("title prompt omitted the first exchange: %q", body)
	}
	if strings.Contains(body, "# AGENTS.md instructions") || strings.Contains(body, "do not use this as a title") {
		t.Fatalf("title prompt included filtered context: %q", body)
	}

	// Replayed or duplicate events must not issue a second request.
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "codex", Type: "assistant", Content: "I will inspect the reconnect path"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})
	time.Sleep(100 * time.Millisecond)
	if got := requests.Load(); got != 1 {
		t.Fatalf("title requests = %d, want one", got)
	}
}

func TestSessionTitleWaitsForOpenCodeTurnAndAccumulatesDeltas(t *testing.T) {
	var requests atomic.Int32
	// The turn's completion also asks for a result sentence, and both requests
	// reach this endpoint, so the channel carries every prompt and the test
	// picks the title one out.
	requestBody := make(chan string, 8)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode title request: %v", err)
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		if len(body.Messages) == 0 {
			t.Errorf("title request has no messages")
		} else {
			prompt := body.Messages[0].Content
			if strings.Contains(prompt, "Create a short label") {
				requests.Add(1)
			}
			requestBody <- prompt
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"OpenCode title"}}]}`))
	}))
	defer server.Close()

	state, sessionID := newSessionTitleStore(t)
	service := &Service{
		Store: state,
		Settings: settings.Settings{
			OpenAIBaseURL:      server.URL + "/v1",
			OpenAIModel:        "title-model",
			OpenAIKey:          "test-key",
			OpenAITitleEnabled: true,
		},
	}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}

	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "opencode", ID: "user-1", Type: "user", Content: "Add a reconnect", ContentDelta: false},
		{Provider: "opencode", ID: "assistant-1", Type: "assistant", Content: "I will", ContentDelta: false},
	}, api.AgentStatus{Activity: api.AgentActivityWorking})
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "opencode", ID: "user-1", Type: "user", Content: " flow", ContentDelta: true},
		{Provider: "opencode", ID: "assistant-1", Type: "assistant", Content: " inspect it", ContentDelta: true},
		{Provider: "opencode", ID: "user-2", Type: "user", Content: " and do not include this", ContentDelta: true},
		{Provider: "opencode", ID: "assistant-2", Type: "assistant", Content: " or this", ContentDelta: true},
	}, api.AgentStatus{Activity: api.AgentActivityWorking})
	select {
	case <-requestBody:
		t.Fatal("title generated before OpenCode turn completion")
	case <-time.After(100 * time.Millisecond):
	}

	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnCompleted}}, false)
	expireAgentTitleWait(t, service, sessionID)
	body := nextPrompt(t, requestBody, "Create a short label")
	if !strings.Contains(body, "Add a reconnect flow") || !strings.Contains(body, "I will inspect it") {
		t.Fatalf("title prompt did not contain accumulated deltas: %q", body)
	}
	if strings.Contains(body, "do not include this") || strings.Contains(body, "or this") {
		t.Fatalf("title prompt included a later message delta: %q", body)
	}
	if got := waitForSessionTitle(t, state, sessionID); got != "OpenCode title" {
		t.Fatalf("generated title = %q", got)
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("title requests = %d, want one", got)
	}
}

func TestSessionTitleDoesNotCallModelAfterManualRename(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"should not be used"}}]}`))
	}))
	defer server.Close()

	state, sessionID := newSessionTitleStore(t)
	service := &Service{
		Store: state,
		Settings: settings.Settings{
			OpenAIBaseURL:      server.URL + "/v1",
			OpenAIModel:        "title-model",
			OpenAIKey:          "test-key",
			OpenAITitleEnabled: true,
		},
	}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	if err := service.RenameSession(sessionID, "Manual title"); err != nil {
		t.Fatalf("rename session: %v", err)
	}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "codex", Type: "user", Content: "Fix it"},
		{Provider: "codex", Type: "assistant", Content: "Done"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})
	time.Sleep(100 * time.Millisecond)
	if got := requests.Load(); got != 0 {
		t.Fatalf("title requests after manual rename = %d, want zero", got)
	}
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "Manual title" {
		t.Fatalf("manual title = %q", got)
	}
}

func newSessionTitleStore(t *testing.T) (*store.Store, string) {
	t.Helper()
	return newSessionTitleStoreForKind(t, "codex")
}

func newSessionTitleStoreForKind(t *testing.T, kind string) (*store.Store, string) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatalf("open state: %v", err)
	}
	sessionID := "session-title"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID:        sessionID,
			Title:     kind,
			Kind:      kind,
			Runtime:   "runtime-title",
			Lifecycle: "running",
			CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatalf("seed state: %v", err)
	}
	return state, sessionID
}

// expireAgentTitleWait forces the bounded wait for an agent-generated name to
// its deadline, so a test can observe the Host's own title request without
// sleeping through the grace period. pollAgentTitles then runs the same path
// the lifecycle tick runs.
func expireAgentTitleWait(t *testing.T, service *Service, sessionID string) {
	t.Helper()
	service.agentsMu.Lock()
	entry := service.agents[sessionID]
	service.agentsMu.Unlock()
	if entry == nil {
		t.Fatalf("agent entry for %s is missing", sessionID)
	}
	entry.mu.Lock()
	if entry.cliTitleDeadline.IsZero() {
		entry.mu.Unlock()
		t.Fatalf("session %s is not waiting for an agent title", sessionID)
	}
	entry.cliTitleDeadline = time.Now().Add(-time.Second)
	entry.mu.Unlock()
	service.pollAgentTitles()
}

// startAgentTitleWatcher attaches a real transcript watcher so the name a
// provider writes into its own transcript is read through the production path.
func startAgentTitleWatcher(t *testing.T, service *Service, sessionID, provider, transcript string) {
	t.Helper()
	watcher := agent.Start(sessionID, provider, transcript,
		func([]api.AgentEvent, api.AgentStatus) {},
		func(api.AgentStatus) {},
		func([]api.AgentTurn, bool) {})
	t.Cleanup(watcher.Close)
	if err := watcher.WaitReady(context.Background()); err != nil {
		t.Fatalf("wait for watcher: %v", err)
	}
	service.agentsMu.Lock()
	service.agents[sessionID].watcher = watcher
	service.agentsMu.Unlock()
}

func TestSessionTitleUsesAgentGeneratedName(t *testing.T) {
	for _, testCase := range []struct {
		provider string
		record   string
	}{
		{provider: "claude", record: `{"type":"ai-title","sessionId":"s1","aiTitle":"Reconnect the socket"}`},
		{provider: "qoder", record: `{"type":"ai-title","sessionId":"s1","aiTitle":"Reconnect the socket"}`},
	} {
		t.Run(testCase.provider, func(t *testing.T) {
			state, sessionID := newSessionTitleStoreForKind(t, testCase.provider)
			// Neither the switch nor an endpoint is configured: a name the agent
			// generated for its own conversation is read on its own merits.
			service := &Service{Store: state}
			service.lazyInit()
			service.agents[sessionID] = &agentSession{}

			transcript := filepath.Join(t.TempDir(), testCase.provider+".jsonl")
			if err := os.WriteFile(transcript, []byte(testCase.record+"\n"), 0o600); err != nil {
				t.Fatalf("write transcript: %v", err)
			}
			startAgentTitleWatcher(t, service, sessionID, testCase.provider, transcript)

			service.agentsMu.Lock()
			entry := service.agents[sessionID]
			service.agentsMu.Unlock()
			entry.mu.Lock()
			entry.cliTitleDeadline = time.Now().Add(time.Minute)
			entry.mu.Unlock()

			service.pollAgentTitles()
			if got := state.Snapshot().Sessions[0].CustomTitle; got != "Reconnect the socket" {
				t.Fatalf("session title = %q, want the agent-generated name", got)
			}
			// The wait is resolved, so later ticks must not repeat the lookup.
			entry.mu.Lock()
			captured, deadline := entry.cliTitleCaptured, entry.cliTitleDeadline
			entry.mu.Unlock()
			if !captured || !deadline.IsZero() {
				t.Fatalf("wait after a captured name = captured %v deadline %v", captured, deadline)
			}
		})
	}
}

func TestSessionTitleAgentNameOnlyReplacesTheHostGeneratedTitle(t *testing.T) {
	state, sessionID := newSessionTitleStoreForKind(t, "codex")
	service := &Service{Store: state, Settings: settings.Settings{OpenAITitleEnabled: true}}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.agentsMu.Lock()
	entry := service.agents[sessionID]
	service.agentsMu.Unlock()

	entry.mu.Lock()
	entry.aiTitleValue = "Host title"
	entry.mu.Unlock()
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].CustomTitle = "Host title"
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service.applyAgentCLITitle(sessionID, "Agent title")
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "Agent title" {
		t.Fatalf("title after an agent name = %q, want the agent name", got)
	}

	// A title the user set is not the Host's, so it is never replaced.
	if err := service.RenameSession(sessionID, "User title"); err != nil {
		t.Fatal(err)
	}
	service.applyAgentCLITitle(sessionID, "Late agent title")
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "User title" {
		t.Fatalf("title after a user rename = %q, want the user title", got)
	}
}

func TestSessionTitleIsNotGeneratedForProvidersWithoutOne(t *testing.T) {
	state, sessionID := newSessionTitleStoreForKind(t, "pi")
	service := &Service{Store: state, Settings: settings.Settings{
		OpenAIBaseURL:      "http://127.0.0.1:1/v1",
		OpenAIModel:        "title-model",
		OpenAIKey:          "test-key",
		OpenAITitleEnabled: false,
	}}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}

	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix the reconnect flow"},
		{Provider: "pi", Type: "assistant", Content: "I will inspect it"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})

	service.agentsMu.Lock()
	entry := service.agents[sessionID]
	service.agentsMu.Unlock()
	entry.mu.Lock()
	deadline := entry.cliTitleDeadline
	entry.mu.Unlock()
	if !deadline.IsZero() {
		t.Fatalf("provider pi waits for an agent title; deadline = %v", deadline)
	}
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "" {
		t.Fatalf("session title = %q, want the kind-derived default", got)
	}
}

func TestProviderSuppliesTitle(t *testing.T) {
	for _, provider := range []string{"claude", "codex", "opencode", "qoder"} {
		if !providerSuppliesTitle(provider) {
			t.Errorf("providerSuppliesTitle(%q) = false, want true", provider)
		}
	}
	for _, provider := range []string{"", "shell", "custom", "pi", "antigravity", "browser"} {
		if providerSuppliesTitle(provider) {
			t.Errorf("providerSuppliesTitle(%q) = true, want false", provider)
		}
	}
}

func waitForSessionTitle(t *testing.T, state *store.Store, sessionID string) string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		for _, session := range state.Snapshot().Sessions {
			if session.ID == sessionID && session.CustomTitle != "" {
				return session.CustomTitle
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("session %s did not receive a generated title", sessionID)
	return ""
}

func TestSessionTitleFromQoderExchange(t *testing.T) {
	var requests atomic.Int32
	requestBody := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode title request: %v", err)
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		if len(body.Messages) > 0 {
			requestBody <- body.Messages[0].Content
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"Fix login styling"}}]}`))
	}))
	defer server.Close()

	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "session-qoder-title"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID:        sessionID,
			Title:     "Qoder",
			Kind:      "qoder",
			Runtime:   "runtime-title",
			Lifecycle: "running",
			CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store: state,
		Settings: settings.Settings{
			OpenAIBaseURL:      server.URL + "/v1",
			OpenAIModel:        "title-model",
			OpenAIKey:          "test-key",
			OpenAITitleEnabled: true,
		},
	}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}

	// A qoder turn: user text, thinking/reasoning, tool calls, then a final
	// assistant text carrying the terminal end_turn stop reason.
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "qoder", Type: "user", Content: "Fix the login button styling"},
		{Provider: "qoder", Type: "reasoning", Content: "I should find the login view"},
		{Provider: "qoder", Type: "tool_call", Content: "", ToolName: "read"},
		{Provider: "qoder", Type: "tool_output", Output: "file contents"},
		{Provider: "qoder", Type: "assistant", Content: "The button now uses the accent color", StopReason: "end_turn"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})

	expireAgentTitleWait(t, service, sessionID)
	if got := waitForSessionTitle(t, state, sessionID); got != "Fix login styling" {
		t.Fatalf("generated title = %q, want Fix login styling", got)
	}
	body := <-requestBody
	if !strings.Contains(body, "Fix the login button styling") || !strings.Contains(body, "The button now uses the accent color") {
		t.Fatalf("title prompt omitted the qoder exchange: %q", body)
	}
	if requests.Load() != 1 {
		t.Fatalf("title requests = %d, want one", requests.Load())
	}
}

// nextPrompt drains prompts until one contains `marker`, so a test can single
// out the request it cares about while the Host also asks for a result
// sentence on the same endpoint.
func nextPrompt(t *testing.T, prompts <-chan string, marker string) string {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case prompt := <-prompts:
			if strings.Contains(prompt, marker) {
				return prompt
			}
		case <-deadline:
			t.Fatalf("no prompt containing %q arrived", marker)
			return ""
		}
	}
}
