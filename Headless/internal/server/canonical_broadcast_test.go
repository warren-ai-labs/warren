package server

import (
	"encoding/json"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestEncodeCanonicalAgentEventBatches(t *testing.T) {
	events := []api.CanonicalAgentEvent{
		{
			EventID:     "event-1",
			StreamID:    "stream-1",
			ExecutionID: "execution-1",
			Sequence:    1,
			Type:        "message.created",
			Payload:     map[string]any{"content": "hello"},
		},
	}

	encoded, err := encodeCanonicalAgentBatches(
		"stream-1",
		"execution-1",
		splitCanonicalAgentEvents(events, agentMessageMaxBytes),
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) != 1 {
		t.Fatalf("encoded batches = %d, want 1", len(encoded))
	}

	var message api.CanonicalAgentEventsMessage
	if err := json.Unmarshal(encoded[0], &message); err != nil {
		t.Fatal(err)
	}
	if message.Type != "agent.events" || message.StreamID != "stream-1" || message.ExecutionID != "execution-1" {
		t.Fatalf("message identity = %#v", message)
	}
	if len(message.Events) != 1 || message.Events[0].EventID != "event-1" {
		t.Fatalf("message events = %#v", message.Events)
	}
}
