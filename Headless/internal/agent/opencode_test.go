package agent

import (
	"encoding/json"
	"testing"
)

func TestOpenCodeEnvelopeParsesToEvents(t *testing.T) {
	line := `{
		"role": "assistant",
		"finish": "end_turn",
		"modelId": "claude-sonnet",
		"providerId": "anthropic",
		"time": {"created": 1700000000000, "completed": 1700000001000},
		"summary": {"title": "say hi"},
		"parts": [
			{"id": "p1", "type": "text", "text": "hello"},
			{"id": "p2", "type": "reasoning", "reasoning": "thinking"},
			{"id": "p3", "type": "tool", "tool": "bash", "state": {"status": "completed", "input": "{\"command\":\"ls\"}", "output": "file\n"}}
		]
	}`
	events := newParser("opencode").parseOpenCode([]byte(line))
	if len(events) != 4 {
		t.Fatalf("expected 4 events, got %d: %+v", len(events), events)
	}
	if events[0].Type != "assistant" || events[0].Content != "hello" {
		t.Fatalf("expected assistant text first, got %+v", events[0])
	}
	if events[1].Type != "reasoning" || events[1].Content != "thinking" {
		t.Fatalf("expected reasoning second, got %+v", events[1])
	}
	if events[2].Type != "tool_call" || events[2].ToolName != "bash" {
		t.Fatalf("expected bash tool_call third, got %+v", events[2])
	}
	if events[3].Type != "tool_output" || events[3].ToolStatus != "success" || events[3].Output != "file\n" {
		t.Fatalf("expected successful bash tool_output fourth, got %+v", events[3])
	}
	if events[3].StopReason != "end_turn" {
		t.Fatalf("expected final event to carry end_turn stop reason, got %q", events[3].StopReason)
	}
}

func TestOpenCodeUserAndErrorEvents(t *testing.T) {
	userLine := `{"role":"user","time":{"created":1700000000000},"summary":{"title":"do a thing"}}`
	userEvents := newParser("opencode").parseOpenCode([]byte(userLine))
	if len(userEvents) != 1 || userEvents[0].Type != "user" {
		t.Fatalf("expected one user event, got %+v", userEvents)
	}

	errorLine := `{"role":"assistant","time":{"created":1700000000000},"error":{"message":"boom"}}`
	errorEvents := newParser("opencode").parseOpenCode([]byte(errorLine))
	if len(errorEvents) != 1 || errorEvents[0].Type != "error" || errorEvents[0].Error != "boom" {
		t.Fatalf("expected one error event, got %+v", errorEvents)
	}
}

func TestOpenCodeFoldsEventsIntoActivity(t *testing.T) {
	session := newParser("opencode")
	env := openCodeEnvelope{
		Role: "user",
		Time: openCodeTime{Created: 1700000000000},
	}
	env.Summary.Title = "hi"
	input, _ := json.Marshal(env)
	if evs := session.parse(input); len(evs) != 1 || session.Activity() != "working" {
		t.Fatalf("user turn should be working, got %q", session.Activity())
	}
}
