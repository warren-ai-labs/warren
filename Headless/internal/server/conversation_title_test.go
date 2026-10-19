package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// newTitleEndpoint answers a title request with "Final" when the prompt holds
// the agent's first text, and "Early" otherwise. Every prompt is captured.
func newTitleEndpoint(t *testing.T) (*httptest.Server, chan string) {
	t.Helper()
	prompts := make(chan string, 8)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		_ = json.NewDecoder(request.Body).Decode(&body)
		prompt := ""
		if len(body.Messages) > 0 {
			prompt = body.Messages[0].Content
		}
		prompts <- prompt
		title := "Early"
		if strings.Contains(prompt, "I will inspect the reconnect path") {
			title = "Final"
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"` + title + `"}}]}`))
	}))
	t.Cleanup(server.Close)
	return server, prompts
}

func newEarlyTitleService(t *testing.T, endpoint string) (*Service, *store.Store, string) {
	t.Helper()
	// pi does not name its own conversations, so the reply's title request is
	// made immediately rather than after the agent CLI's grace period.
	state, sessionID := newSessionTitleStoreForKind(t, "pi")
	service := &Service{
		Store: state,
		Settings: settings.Settings{
			OpenAIBaseURL:      endpoint + "/v1",
			OpenAIKey:          "test-key",
			OpenAITitleEnabled: true,
		},
	}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	return service, state, sessionID
}

// backdateFirstUserMessage moves the first user message past earlyTitleDelay.
func backdateFirstUserMessage(t *testing.T, service *Service, sessionID string) {
	t.Helper()
	service.agentsMu.Lock()
	entry := service.agents[sessionID]
	service.agentsMu.Unlock()
	entry.mu.Lock()
	defer entry.mu.Unlock()
	if entry.titleUserAt.IsZero() {
		t.Fatal("first user message time was not recorded")
	}
	entry.titleUserAt = time.Now().Add(-earlyTitleDelay - time.Second)
}

func waitForTitleValue(t *testing.T, state *store.Store, sessionID, want string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	got := ""
	for time.Now().Before(deadline) {
		for _, session := range state.Snapshot().Sessions {
			if session.ID == sessionID {
				got = session.CustomTitle
			}
		}
		if got == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("session title = %q, want %q", got, want)
}

func TestEarlyTitleIsWrittenBeforeTheReplyAndReplacedByIt(t *testing.T) {
	endpoint, prompts := newTitleEndpoint(t)
	service, state, sessionID := newEarlyTitleService(t, endpoint.URL)

	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix the reconnect flow"},
		{Provider: "pi", Type: "reasoning", Content: "The socket retry "},
		{Provider: "pi", Type: "reasoning", Content: "loop looks stuck", ContentDelta: true},
	}, api.AgentStatus{Activity: api.AgentActivityWorking})

	// Before the delay nothing is requested.
	service.pollAgentTitles()
	select {
	case prompt := <-prompts:
		t.Fatalf("early title requested before the delay: %q", prompt)
	case <-time.After(100 * time.Millisecond):
	}

	backdateFirstUserMessage(t, service, sessionID)
	service.pollAgentTitles()
	waitForTitleValue(t, state, sessionID, "Early")
	prompt := <-prompts
	if !strings.Contains(prompt, "Fix the reconnect flow") ||
		!strings.Contains(prompt, "AGENT THINKING (secondary context):\nThe socket retry loop looks stuck") {
		t.Fatalf("early prompt = %q", prompt)
	}
	if strings.Contains(prompt, "AGENT FIRST TEXT") {
		t.Fatalf("early prompt carries an empty agent text section: %q", prompt)
	}

	// A second tick must not request another early title.
	service.pollAgentTitles()

	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "assistant", Content: "I will inspect the reconnect path"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})
	waitForTitleValue(t, state, sessionID, "Final")
	if prompt := <-prompts; !strings.Contains(prompt, "I will inspect the reconnect path") {
		t.Fatalf("reply prompt = %q", prompt)
	}
	select {
	case prompt := <-prompts:
		t.Fatalf("unexpected extra title request: %q", prompt)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestEarlyTitleWithoutThinkingUsesTheUserMessageAlone(t *testing.T) {
	endpoint, prompts := newTitleEndpoint(t)
	service, state, sessionID := newEarlyTitleService(t, endpoint.URL)

	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix the reconnect flow"},
	}, api.AgentStatus{Activity: api.AgentActivityWorking})
	backdateFirstUserMessage(t, service, sessionID)
	service.pollAgentTitles()
	waitForTitleValue(t, state, sessionID, "Early")
	if prompt := <-prompts; strings.Contains(prompt, "AGENT THINKING") {
		t.Fatalf("prompt invented a thinking section: %q", prompt)
	}
}

func TestEarlyTitleDoesNotReplaceARename(t *testing.T) {
	endpoint, _ := newTitleEndpoint(t)
	service, state, sessionID := newEarlyTitleService(t, endpoint.URL)

	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "user", Content: "Fix the reconnect flow"},
	}, api.AgentStatus{Activity: api.AgentActivityWorking})
	backdateFirstUserMessage(t, service, sessionID)
	service.pollAgentTitles()
	waitForTitleValue(t, state, sessionID, "Early")

	if err := service.RenameSession(sessionID, "Mine"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "pi", Type: "assistant", Content: "I will inspect the reconnect path"},
	}, api.AgentStatus{Activity: api.AgentActivityReady})
	time.Sleep(200 * time.Millisecond)
	waitForTitleValue(t, state, sessionID, "Mine")
}

func bindConversation(t *testing.T, state *store.Store, sessionID, agentSessionID, title string) {
	t.Helper()
	if err := state.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == sessionID {
				value.Sessions[index].AgentSessionID = agentSessionID
				value.Sessions[index].CustomTitle = title
			}
		}
		return nil
	}); err != nil {
		t.Fatalf("bind conversation: %v", err)
	}
}

func storedTitle(t *testing.T, service *Service, agentSessionID string) string {
	t.Helper()
	title, _, err := service.agentStore().ConversationTitle(context.Background(), "codex", agentSessionID)
	if err != nil {
		t.Fatalf("read conversation title: %v", err)
	}
	return title
}

func TestConversationTitleIsRestoredWhenTheConversationIsResumed(t *testing.T) {
	journalPath := filepath.Join(t.TempDir(), "agent-journal.db")
	state, sessionID := newSessionTitleStore(t)
	service := &Service{Store: state, AgentStorePath: journalPath}
	t.Cleanup(func() { _ = service.agentStore().Close() })

	bindConversation(t, state, sessionID, "conv-1", "Fix reconnect")
	service.pollAgentTitles()
	if got := storedTitle(t, service, "conv-1"); got != "Fix reconnect" {
		t.Fatalf("stored conv-1 title = %q", got)
	}

	// A later title replaces the stored one.
	if err := service.RenameSession(sessionID, "Fix reconnect flow"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	service.pollAgentTitles()
	if got := storedTitle(t, service, "conv-1"); got != "Fix reconnect flow" {
		t.Fatalf("stored conv-1 title after rename = %q", got)
	}

	// `/new` clears the title and binds a fresh conversation.
	bindConversation(t, state, sessionID, "conv-2", "")
	service.pollAgentTitles()
	waitForTitleValue(t, state, sessionID, "")
	bindConversation(t, state, sessionID, "conv-2", "Add retries")
	service.pollAgentTitles()

	// Resuming the first conversation shows its title again.
	bindConversation(t, state, sessionID, "conv-1", "")
	service.pollAgentTitles()
	waitForTitleValue(t, state, sessionID, "Fix reconnect flow")
	if got := storedTitle(t, service, "conv-2"); got != "Add retries" {
		t.Fatalf("stored conv-2 title = %q", got)
	}
}

func TestConversationTitleIsNotFiledUnderTheNextConversation(t *testing.T) {
	journalPath := filepath.Join(t.TempDir(), "agent-journal.db")
	state, sessionID := newSessionTitleStore(t)
	service := &Service{Store: state, AgentStorePath: journalPath}
	t.Cleanup(func() { _ = service.agentStore().Close() })

	bindConversation(t, state, sessionID, "conv-1", "Fix reconnect")
	service.pollAgentTitles()
	// The binding moves before the previous conversation's title is cleared.
	bindConversation(t, state, sessionID, "conv-2", "Fix reconnect")
	service.pollAgentTitles()
	service.pollAgentTitles()
	if got := storedTitle(t, service, "conv-2"); got != "" {
		t.Fatalf("conv-2 inherited the previous title %q", got)
	}
}

func TestConversationTitleSurvivesAHostRestart(t *testing.T) {
	journalPath := filepath.Join(t.TempDir(), "agent-journal.db")
	state, sessionID := newSessionTitleStore(t)
	first := &Service{Store: state, AgentStorePath: journalPath}
	bindConversation(t, state, sessionID, "conv-1", "Fix reconnect")
	first.pollAgentTitles()
	_ = first.agentStore().Close()

	// A new Session resumes the conversation on a restarted Host.
	resumed, resumedID := newSessionTitleStore(t)
	second := &Service{Store: resumed, AgentStorePath: journalPath}
	t.Cleanup(func() { _ = second.agentStore().Close() })
	bindConversation(t, resumed, resumedID, "conv-1", "")
	second.pollAgentTitles()
	waitForTitleValue(t, resumed, resumedID, "Fix reconnect")
}
