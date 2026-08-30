package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

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
		if len(body.Messages) == 0 {
			t.Errorf("title request has no messages")
		} else {
			requestBody <- body.Messages[0].Content
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
	body := <-requestBody
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
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatalf("open state: %v", err)
	}
	sessionID := "session-title"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID:        sessionID,
			Title:     "Codex",
			Kind:      "codex",
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
