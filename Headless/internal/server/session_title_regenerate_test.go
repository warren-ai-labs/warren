package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	sessiontitle "github.com/abcdlsj/warren/Headless/internal/title"
)

// A regeneration reads the conversation the Host recorded, not the first
// exchange: a long conversation's subject has moved on since then.
func TestRegenerateSessionTitleUsesTheNewestConversationText(t *testing.T) {
	prompts := make(chan string, 4)
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
		prompts <- body.Messages[0].Content
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"Title: Export the ledger"}}]}`))
	}))
	defer server.Close()

	state, sessionID := newSessionTitleStoreForKind(t, "pi")
	// The user's switch is off: an explicit regeneration does not depend on it.
	service := &Service{Store: state, Settings: settings.Settings{
		OpenAIBaseURL: server.URL + "/v1",
		OpenAIModel:   "title-model",
		OpenAIKey:     "test-key",
	}}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix the reconnect flow"},
		{Provider: "pi", Type: "tool_call", Content: "ran npm test", ToolName: "bash"},
		{Provider: "pi", Type: "reasoning", Content: "the socket drops"},
		{Provider: "pi", Type: "assistant", Content: "Reconnect fixed"},
		{Provider: "pi", Type: "tool_output", Output: "2 passing"},
		{Provider: "pi", Type: "user", Content: "Now add a CSV export of the ledger"},
		{Provider: "pi", Type: "assistant", Content: "The export writes a CSV file"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})

	titleValue, err := service.RegenerateSessionTitle(context.Background(), sessionID)
	if err != nil {
		t.Fatalf("RegenerateSessionTitle: %v", err)
	}
	if titleValue != "Export the ledger" {
		t.Fatalf("returned title = %q", titleValue)
	}
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "Export the ledger" {
		t.Fatalf("session title = %q, want the regenerated title", got)
	}
	prompt := <-prompts
	for _, want := range []string{
		"User: Fix the reconnect flow",
		"Assistant: Reconnect fixed",
		"User: Now add a CSV export of the ledger",
		"Assistant: The export writes a CSV file",
	} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt omitted %q: %q", want, prompt)
		}
	}
	for _, unwanted := range []string{"ran npm test", "2 passing", "the socket drops"} {
		if strings.Contains(prompt, unwanted) {
			t.Fatalf("prompt included %q: %q", unwanted, prompt)
		}
	}
	if strings.Index(prompt, "Fix the reconnect flow") > strings.Index(prompt, "Now add a CSV export") {
		t.Fatalf("prompt reordered the conversation: %q", prompt)
	}
}

// A regeneration is a rename the user asked for, so it replaces whatever the
// Session showed, manual title included.
func TestRegenerateSessionTitleOverwritesAManualTitle(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"Ledger export"}}]}`))
	}))
	defer server.Close()

	state, sessionID := newSessionTitleStoreForKind(t, "pi")
	service := &Service{Store: state, Settings: settings.Settings{
		OpenAIBaseURL: server.URL + "/v1",
		OpenAIKey:     "test-key",
	}}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix it"},
		{Provider: "pi", Type: "assistant", Content: "Fixed"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})
	if err := service.RenameSession(sessionID, "My own name"); err != nil {
		t.Fatalf("rename: %v", err)
	}

	if _, err := service.RegenerateSessionTitle(context.Background(), sessionID); err != nil {
		t.Fatalf("RegenerateSessionTitle: %v", err)
	}
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "Ledger export" {
		t.Fatalf("session title = %q, want the regenerated title", got)
	}
}

// The agent CLI names its own conversations, and that name normally wins over
// the Host's. A title the user regenerated is not the Host's, so a late CLI name
// must leave it alone.
func TestRegeneratedTitleIsNotReplacedByALateCLIName(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"Ledger export"}}]}`))
	}))
	defer server.Close()

	state, sessionID := newSessionTitleStoreForKind(t, "claude")
	service := &Service{Store: state, Settings: settings.Settings{
		OpenAIBaseURL: server.URL + "/v1",
		OpenAIKey:     "test-key",
	}}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "claude", Type: "user", Content: "Fix it"},
		{Provider: "claude", Type: "assistant", Content: "Fixed"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})
	// The Session shows a title the Host's own request produced for this
	// conversation, which is the one a CLI name is normally allowed to replace.
	entry := service.agents[sessionID]
	entry.mu.Lock()
	entry.aiTitleValue = "Fixed the bug"
	entry.mu.Unlock()
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].CustomTitle = "Fixed the bug"
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := service.RegenerateSessionTitle(context.Background(), sessionID); err != nil {
		t.Fatalf("RegenerateSessionTitle: %v", err)
	}
	service.applyAgentCLITitle(sessionID, "A name the CLI chose")
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "Ledger export" {
		t.Fatalf("session title = %q, want the regenerated title", got)
	}
}

// The Host's automatic request may not replace a regenerated title either,
// whether it was already in flight or starts afterwards.
func TestRegeneratedTitleIsNotReplacedByTheAutomaticFlow(t *testing.T) {
	var regenerations atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode title request: %v", err)
		}
		answer := "Automatic title"
		if strings.Contains(body.Messages[0].Content, "RECENT MESSAGES") {
			regenerations.Add(1)
			answer = "Ledger export"
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"` + answer + `"}}]}`))
	}))
	defer server.Close()

	state, sessionID := newSessionTitleStoreForKind(t, "pi")
	// The switch is on here, which is the only way the automatic request exists.
	service := &Service{Store: state, Settings: settings.Settings{
		OpenAIBaseURL:      server.URL + "/v1",
		OpenAIKey:          "test-key",
		OpenAITitleEnabled: true,
	}}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix it"},
		{Provider: "pi", Type: "assistant", Content: "Fixed"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})

	// The automatic name for the first exchange, written before the user asks
	// for a new one.
	service.generateSessionTitle(
		sessionID,
		service.conversationGeneration(sessionID),
		service.titleConfig(),
		sessiontitle.Input{User: "Fix it", Assistant: "Fixed"},
		false,
	)
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "Automatic title" {
		t.Fatalf("automatic title = %q", got)
	}

	regenerated, err := service.RegenerateSessionTitle(context.Background(), sessionID)
	if err != nil {
		t.Fatalf("RegenerateSessionTitle: %v", err)
	}
	if regenerated != "Ledger export" {
		t.Fatalf("regenerated title = %q", regenerated)
	}
	// Later automatic passes must not claim the conversation again.
	service.tryStartSessionTitle(sessionID)
	service.startEarlySessionTitles()
	if _, err := service.RegenerateSessionTitle(context.Background(), sessionID); err != nil {
		t.Fatalf("second RegenerateSessionTitle: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "Ledger export" {
		t.Fatalf("session title = %q, want the regenerated title", got)
	}
	if got := regenerations.Load(); got != 2 {
		t.Fatalf("regenerations = %d, want two explicit requests", got)
	}
}

// A name captured for one conversation must never label the conversation that
// replaced it.
func TestRegeneratedTitleDiscardsAStaleGeneration(t *testing.T) {
	state, sessionID := newSessionTitleStoreForKind(t, "pi")
	service := &Service{Store: state}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix it"},
		{Provider: "pi", Type: "assistant", Content: "Fixed"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})
	generation := service.conversationGeneration(sessionID)
	if generation == "" {
		t.Fatal("the conversation has no generation")
	}

	// The conversation is replaced while the title request is in flight.
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].AgentExecutionID = "conversation-after-a-clear"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	err := service.applyRegeneratedTitle(sessionID, generation, "Stale title")
	if err == nil || !strings.Contains(err.Error(), "conversation changed") {
		t.Fatalf("apply error = %v, want a stale-conversation error", err)
	}
	if got := state.Snapshot().Sessions[0].CustomTitle; got != "" {
		t.Fatalf("session title = %q, want the replacement conversation unnamed", got)
	}
}

func TestRegenerateSessionTitleRequiresAnEndpointAndAnExchange(t *testing.T) {
	state, sessionID := newSessionTitleStoreForKind(t, "pi")
	service := &Service{Store: state}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix it"},
		{Provider: "pi", Type: "assistant", Content: "Fixed"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})

	if _, err := service.RegenerateSessionTitle(context.Background(), sessionID); err == nil ||
		!strings.Contains(err.Error(), "not configured") {
		t.Fatalf("error without an endpoint = %v, want not configured", err)
	}
	if service.sessionTitleRegeneratable(sessionID) {
		t.Fatal("a Host with no title endpoint reports a regeneratable title")
	}

	service.Settings = settings.Settings{OpenAIBaseURL: "http://127.0.0.1:1/v1", OpenAIKey: "test-key"}
	if _, err := service.RegenerateSessionTitle(context.Background(), "unknown-session"); err == nil ||
		!strings.Contains(err.Error(), "session not found") {
		t.Fatalf("error for an unknown session = %v, want session not found", err)
	}
	if !service.sessionTitleRegeneratable(sessionID) {
		t.Fatal("a conversation with an exchange and an endpoint reports no regeneratable title")
	}

	// A conversation whose agent has not replied yet has nothing to name.
	emptyState, emptyID := newSessionTitleStoreForKind(t, "pi")
	emptyService := &Service{Store: emptyState, Settings: service.Settings}
	emptyService.lazyInit()
	emptyService.agents[emptyID] = &agentSession{}
	emptyService.recordAgentEvents(emptyID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix it"},
	}, api.AgentStatus{Activity: api.AgentActivityWorking})
	if _, err := emptyService.RegenerateSessionTitle(context.Background(), emptyID); err == nil ||
		!strings.Contains(err.Error(), "no user and assistant text") {
		t.Fatalf("error without a reply = %v, want no user and assistant text", err)
	}
	if emptyService.sessionTitleRegeneratable(emptyID) {
		t.Fatal("a conversation without a reply reports a regeneratable title")
	}
}

// Provider deltas are fragments of one message, not separate messages.
func TestConversationTextsFoldsProviderDeltas(t *testing.T) {
	messages := conversationTexts([]api.AgentEvent{
		{Provider: "opencode", ID: "user-1", Type: "user", Content: "Add a reconnect"},
		{Provider: "opencode", ID: "user-1", Type: "user", Content: " flow", ContentDelta: true},
		{Provider: "opencode", ID: "assistant-1", Type: "assistant", Content: "I will"},
		{Provider: "opencode", ID: "assistant-1", Type: "assistant", Content: " inspect it", ContentDelta: true},
		// A replayed observation of the same message is not a second one.
		{Provider: "opencode", ID: "user-1", Type: "user", Content: "Add a reconnect flow"},
		{Provider: "opencode", ID: "child", Type: "user", Content: "a subagent's prompt", Sidechain: true},
	})
	want := []string{"Add a reconnect flow", "I will inspect it"}
	if len(messages) != len(want) {
		t.Fatalf("messages = %#v, want %d", messages, len(want))
	}
	for index, text := range want {
		if messages[index].Text != text {
			t.Fatalf("message %d = %q, want %q", index, messages[index].Text, text)
		}
	}
}
