package drift

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

var testTime = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// TestAgentPayloadTypes pins the JSON type of every payload field the schema
// declares for the message and tool families.
//
// A canonical payload is an open map: providers add keys the contract does not
// name, and clients ignore what they do not read. What the schema can promise
// is narrow and worth a test — that a field it does name carries the type it
// says, in the Host's own projection and in the shared client fixture.
func TestAgentPayloadTypes(t *testing.T) {
	s, root := loadSchema(t)
	payloads := s.Properties.AgentEvents.Properties.Payloads
	if len(payloads.ByType) == 0 {
		t.Fatal("schema declares no agentEvents.payloads.byType")
	}
	for _, name := range s.Properties.AgentEvents.Properties.Types.Items.Enum {
		if _, ok := payloads.ByType[name]; !ok {
			t.Errorf("event type %q has no agentEvents.payloads.byType entry; add one, empty when it carries only common fields", name)
		}
	}

	declared := func(eventType string) map[string]string {
		fields := map[string]string{}
		for name, schema := range payloads.Common.Properties {
			fields[name] = schema.Type
		}
		for name, schema := range payloads.ByType[eventType].Properties {
			fields[name] = schema.Type
		}
		return fields
	}

	check := func(t *testing.T, eventType string, payload map[string]any) {
		t.Helper()
		// A client only ever sees the JSON form, so measure that form: the
		// Host's in-memory payload still holds Go values such as *api.AgentUsage.
		encoded, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("%s payload does not marshal: %v", eventType, err)
		}
		var wire map[string]any
		if err := json.Unmarshal(encoded, &wire); err != nil {
			t.Fatalf("%s payload does not decode: %v", eventType, err)
		}
		payload = wire
		fields := declared(eventType)
		if len(fields) == 0 {
			t.Fatalf("%s: schema declares no payload fields", eventType)
		}
		for name, value := range payload {
			expected, ok := fields[name]
			if !ok {
				continue
			}
			if actual := jsonType(value); actual != expected {
				t.Errorf("%s payload %q: schema says %s, payload has %s (%T)", eventType, name, expected, actual, value)
			}
		}
	}

	t.Run("host_projection_matches_declared_types", func(t *testing.T) {
		message := api.CanonicalAgentEventFromObservation(api.AgentEvent{
			ID:         "m1",
			Provider:   "codex",
			Type:       "assistant",
			Role:       "assistant",
			Content:    "Done.",
			Model:      "gpt-5",
			StopReason: "stop",
			Usage:      &api.AgentUsage{InputTokens: 10, OutputTokens: 2},
			DurationMs: 1200,
		}, "stream-1", "exec-1", 1, testTime)
		// The completion type is assigned by the server projection, so both
		// message families are measured against the same payload here.
		check(t, "message.created", message.Payload)
		check(t, "message.completed", message.Payload)

		tool := api.CanonicalAgentEventFromObservation(api.AgentEvent{
			ID:         "c1",
			Provider:   "codex",
			Type:       "tool",
			ToolName:   "Edit",
			ToolKind:   "edit",
			ToolDetail: "a.go",
			ToolStatus: "completed",
			CallID:     "c1",
			Output:     "ok",
			Files:      []string{"a.go"},
		}, "stream-1", "exec-1", 2, testTime)
		tool.Type = "tool.completed"
		check(t, tool.Type, tool.Payload)

		started := api.CanonicalAgentEventFromObservation(api.AgentEvent{
			ID:         "c2",
			Provider:   "codex",
			Type:       "tool",
			ToolName:   "Read",
			ToolKind:   "read",
			ToolDetail: "a.go",
			CallID:     "c2",
			ToolInput:  map[string]any{"path": "a.go"},
			ToolStatus: "running",
		}, "stream-1", "exec-1", 3, testTime)
		started.Type = "tool.started"
		check(t, started.Type, started.Payload)
	})

	t.Run("provider_payload_fields_pass_through_unchanged", func(t *testing.T) {
		// The Host spreads the provider's own payload into the canonical row.
		// These cases pin that each declared field keeps the type the schema
		// names, so a retyped value cannot reach a client unnoticed.
		cases := []struct {
			eventType string
			payload   map[string]any
		}{
			{"interaction.requested", map[string]any{
				"interactionId": "i1", "kind": "permission", "title": "Run rm", "version": 1,
				"state": "pending", "options": []any{map[string]any{"id": "allow"}},
			}},
			{"plan.updated", map[string]any{
				"planId": "p1", "items": []any{map[string]any{"title": "Read", "state": "pending"}},
			}},
			{"context.updated", map[string]any{"used": 1024, "size": 200000}},
			{"subagent.updated", map[string]any{
				"subagentId": "s1", "parentCallId": "c1", "title": "explorer", "summary": "one line", "state": "running",
			}},
			{"config.updated", map[string]any{
				"configId": "cfg", "configOptions": []any{map[string]any{"id": "model", "currentValue": "gpt-5"}},
			}},
			{"queue.updated", map[string]any{"queueId": "q1", "itemId": "i1", "requestId": "r1"}},
			{"diff.updated", map[string]any{
				"diffId": "d1", "file": "a.go", "diff": map[string]any{"file": "a.go", "additions": 1, "deletions": 0},
			}},
		}
		for _, tc := range cases {
			event := api.CanonicalAgentEventFromObservation(api.AgentEvent{
				ID:      "e-" + tc.eventType,
				Provider: "codex",
				Type:    tc.eventType,
				Payload: tc.payload,
			}, "stream-1", "exec-1", 1, testTime)
			event.Type = tc.eventType
			check(t, event.Type, event.Payload)
		}
	})

	t.Run("client_fixture_matches_declared_types", func(t *testing.T) {
		path := filepath.Join(root, "protocol", "fixtures", "agent", "conversation-basic.json")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		var fixture struct {
			Events []struct {
				Type    string         `json:"type"`
				Payload map[string]any `json:"payload"`
			} `json:"events"`
		}
		if err := json.Unmarshal(data, &fixture); err != nil {
			t.Fatalf("parse fixture: %v", err)
		}
		seen := 0
		for _, event := range fixture.Events {
			if len(payloads.ByType[event.Type].Properties) == 0 {
				continue
			}
			check(t, event.Type, event.Payload)
			seen++
		}
		if seen == 0 {
			t.Fatal("fixture covers no event type the schema declares")
		}
	})
}

// jsonType names the JSON type of a decoded value the way the schema does.
func jsonType(value any) string {
	switch value := value.(type) {
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64:
		if value == float64(int64(value)) {
			return "integer"
		}
		return "number"
	case int:
		return "integer"
	case int64:
		return "integer"
	case map[string]any:
		return "object"
	case []any:
		return "array"
	default:
		return "unknown"
	}
}
