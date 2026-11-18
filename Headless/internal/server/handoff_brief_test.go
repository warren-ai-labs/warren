package server

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func newHandoffTestService(t *testing.T, kind string) (*Service, string) {
	t.Helper()
	state, sessionID := newSessionTitleStoreForKind(t, kind)
	service := &Service{Store: state}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	return service, sessionID
}

func TestHandoffBriefExtractsAskedRepliedAndChanged(t *testing.T) {
	service, sessionID := newHandoffTestService(t, "claude")
	replied := time.Date(2026, 11, 17, 8, 0, 0, 0, time.UTC)
	service.recordAgentEvents(sessionID, []api.AgentEvent{
		{Provider: "claude", Type: "user", ID: "u1", Content: "Add a Handoff entry to the + menu"},
		{Provider: "claude", Type: "tool_call", ID: "t1", ToolName: "Edit", ToolKind: "edit", Files: []string{"Sources/A.swift"}},
		{Provider: "claude", Type: "tool_call", ID: "t2", ToolName: "Read", ToolKind: "read", Files: []string{"Sources/Read.swift"}},
		{Provider: "claude", Type: "tool_call", ID: "t3", ToolName: "write", ToolKind: "write", ToolInput: map[string]any{"path": "Sources/B.swift"}},
		{Provider: "claude", Type: "user", ID: "u2", Content: handoffAgentPrompt},
		{Provider: "claude", Type: "assistant", ID: "a1", Content: "The menu row is in.\nTests pass.", Model: "claude-opus-5-5", Timestamp: replied,
			Usage: &api.AgentUsage{InputTokens: 10, CacheReadInputTokens: 90_000, CacheCreationInputTokens: 2_000}},
	}, api.AgentStatus{Activity: api.AgentActivityReady})

	result, err := service.HandoffBrief(context.Background(), api.HandoffBriefRequest{Session: sessionID, Mode: api.HandoffBriefExtract})
	if err != nil {
		t.Fatalf("HandoffBrief: %v", err)
	}
	text := result.Text
	for _, want := range []string{
		"earlier Claude Code session",
		"> Add a Handoff entry to the + menu",
		"- Sources/A.swift\n- Sources/B.swift",
		"> The menu row is in.\n> Tests pass.",
		"`warren agent read " + sessionID + "`",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("brief is missing %q:\n%s", want, text)
		}
	}
	for _, unwanted := range []string{"Sources/Read.swift", "Write the handoff brief"} {
		if strings.Contains(text, unwanted) {
			t.Fatalf("brief carries %q:\n%s", unwanted, text)
		}
	}

	status, err := service.HandoffStatus(context.Background(), api.HandoffStatusRequest{Session: sessionID})
	if err != nil {
		t.Fatalf("HandoffStatus: %v", err)
	}
	if status.Provider != "claude" || status.Model != "claude-opus-5-5" {
		t.Fatalf("status provider/model = %q/%q", status.Provider, status.Model)
	}
	if status.LastResponseAt == nil || !status.LastResponseAt.Equal(replied) {
		t.Fatalf("last response = %v, want %v", status.LastResponseAt, replied)
	}
	if status.CacheTTL != 300 || status.Estimated {
		t.Fatalf("cache ttl = %d estimated=%v, want documented 300", status.CacheTTL, status.Estimated)
	}
	if status.ContextTokens != 92_010 {
		t.Fatalf("context tokens = %d, want 92010", status.ContextTokens)
	}
}

func TestHandoffBriefKeepsNewestUserMessagesWithinBudget(t *testing.T) {
	events := []api.CanonicalAgentEvent{}
	long := strings.Repeat("x", handoffUserMessage+100)
	for index := 0; index < 10; index++ {
		events = append(events, api.CanonicalAgentEvent{
			EventID: "u" + string(rune('a'+index)),
			Type:    "message.created",
			Payload: map[string]any{"role": "user", "content": long},
		})
	}
	events = append(events, api.CanonicalAgentEvent{
		EventID: "last", Type: "message.created",
		Payload: map[string]any{"role": "user", "content": "the newest ask"},
	})
	brief := extractHandoffBrief(events, false, "")
	if !strings.Contains(brief, "> the newest ask") {
		t.Fatalf("brief dropped the newest message:\n%s", brief)
	}
	if !strings.Contains(brief, "(earlier ones left out)") {
		t.Fatalf("brief does not say messages were left out")
	}
	if len(brief) > handoffUserBudget+500 {
		t.Fatalf("brief is %d bytes, over the user budget", len(brief))
	}
}

func TestHandoffCacheTTLByProvider(t *testing.T) {
	cases := []struct {
		provider, model string
		estimated       bool
	}{
		{"claude", "claude-opus-5-5", false},
		{"codex", "gpt-5.6", true},
		{"antigravity", "gemini-3-pro", true},
		{"pi", "anthropic/claude-sonnet-5-5", false},
		{"pi", "deepseek/deepseek-v4.1-flash", true},
	}
	for _, item := range cases {
		ttl, estimated := handoffCacheTTL(item.provider, item.model)
		if ttl != 300 || estimated != item.estimated {
			t.Errorf("%s/%s = %d,%v; want 300,%v", item.provider, item.model, ttl, estimated, item.estimated)
		}
	}
}

func TestHandoffRejectsShellSessions(t *testing.T) {
	service, sessionID := newHandoffTestService(t, "shell")
	if _, err := service.HandoffStatus(context.Background(), api.HandoffStatusRequest{Session: sessionID}); err == nil {
		t.Fatal("a shell Session was accepted as a handoff source")
	}
}
