package api

import (
	"testing"
	"time"
)

func TestCanonicalAgentEventFromLegacy(t *testing.T) {
	recorded := time.Date(2026, 9, 5, 10, 0, 1, 0, time.UTC)
	occurred := recorded.Add(-time.Second)
	event := AgentEvent{
		Sequence:     7,
		Turn:         2,
		ID:           "message-1",
		Provider:     "claude",
		Type:         "assistant",
		Role:         "assistant",
		Content:      "hello",
		Timestamp:    occurred,
		ContentDelta: true,
		Payload:      map[string]any{"messageId": "message-1"},
	}

	canonical := CanonicalAgentEventFromLegacy(event, "exec-1", "exec-1", 0, recorded)
	if canonical.EventID != "message-1" || canonical.StreamID != "exec-1" || canonical.ExecutionID != "exec-1" {
		t.Fatalf("identity = %#v", canonical)
	}
	if canonical.Sequence != 7 || canonical.TurnID != "2" || canonical.Type != "message.delta" {
		t.Fatalf("position/type = %#v", canonical)
	}
	if !canonical.OccurredAt.Equal(occurred) || !canonical.RecordedAt.Equal(recorded) {
		t.Fatalf("timestamps = %#v", canonical)
	}
	if canonical.Payload["content"] != "hello" || canonical.Payload["messageId"] != "message-1" {
		t.Fatalf("payload = %#v", canonical.Payload)
	}
}

func TestCanonicalAgentEventGeneratesStableIdentity(t *testing.T) {
	event := CanonicalAgentEventFromLegacy(AgentEvent{Type: "tool_call"}, "exec-1", "exec-1", 9, time.Time{})
	if event.EventID != "exec-1:9" || event.Sequence != 9 || event.Type != "tool.started" {
		t.Fatalf("event = %#v", event)
	}
	if event.OccurredAt.IsZero() || event.RecordedAt.IsZero() {
		t.Fatal("canonical timestamps must be populated")
	}
}
