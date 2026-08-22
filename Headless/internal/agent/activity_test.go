package agent

import (
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestActivityTrackerLifecycle(t *testing.T) {
	tracker := NewActivityTracker()

	if got := tracker.Activity(); got != api.AgentActivityReady {
		t.Fatalf("initial activity = %q, want ready", got)
	}

	tracker.Observe(api.AgentEvent{Type: "user"})
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after user message = %q, want working", got)
	}

	tracker.TurnComplete()
	if got := tracker.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after turn complete = %q, want ready", got)
	}

	tracker.Observe(api.AgentEvent{Type: "error"})
	if got := tracker.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("after error = %q, want failed", got)
	}

	tracker.TurnStarted()
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after turn start = %q, want working", got)
	}

	tracker.TurnAborted()
	if got := tracker.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after turn abort = %q, want ready", got)
	}
}

func TestActivityTrackerEmitsStableTurnBoundaries(t *testing.T) {
	tracker := NewActivityTracker()

	tracker.Observe(api.AgentEvent{Type: "user"})
	tracker.TurnStarted()
	if got := tracker.DrainTurns(); len(got) != 1 || got[0].ID != 1 || got[0].Status != api.AgentTurnStarted {
		t.Fatalf("started turns = %#v, want one started turn", got)
	}

	tracker.TurnComplete()
	if got := tracker.DrainTurns(); len(got) != 1 || got[0].ID != 1 || got[0].Status != api.AgentTurnCompleted {
		t.Fatalf("completed turns = %#v, want turn 1 completed", got)
	}

	tracker.Observe(api.AgentEvent{Type: "user"})
	tracker.TurnFailed()
	if got := tracker.DrainTurns(); len(got) != 2 ||
		got[0] != (api.AgentTurn{ID: 2, Status: api.AgentTurnStarted}) ||
		got[1] != (api.AgentTurn{ID: 2, Status: api.AgentTurnFailed}) {
		t.Fatalf("failed turns = %#v, want turn 2 started then failed", got)
	}
}

func TestActivityTrackerNoticesStalledTool(t *testing.T) {
	tracker := NewActivityTracker()
	started := time.Now()

	tracker.Observe(api.AgentEvent{Type: "user"})
	tracker.Observe(api.AgentEvent{Type: "tool_call", Timestamp: started})
	tracker.Tick(started.Add(29 * time.Second))
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("before timeout = %q, want working", got)
	}

	tracker.Tick(started.Add(31 * time.Second))
	if got := tracker.Activity(); got != api.AgentActivityStalled {
		t.Fatalf("after stall = %q, want stalled", got)
	}
	status := tracker.Status()
	if status.Attention == nil || status.Attention.Kind != api.AgentAttentionWarning || status.Attention.Reason != "stalled" {
		t.Fatalf("stalled status = %#v, want warning/stalled", status)
	}

	tracker.Observe(api.AgentEvent{Type: "tool_output", ToolStatus: "success"})
	if got := tracker.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after tool result = %q, want working", got)
	}
}

func TestActivityTrackerSeparatesExplicitAttention(t *testing.T) {
	tracker := NewActivityTracker()
	tracker.TurnStarted()
	tracker.MarkAttention(api.AgentAttentionApproval, "permission", "call-1", time.Unix(10, 0))

	status := tracker.Status()
	if status.Activity != api.AgentActivityBlocked || status.Attention == nil {
		t.Fatalf("approval status = %#v, want blocked with attention", status)
	}
	if status.Attention.Kind != api.AgentAttentionApproval || status.Attention.RequestID != "call-1" {
		t.Fatalf("approval attention = %#v", status.Attention)
	}

	tracker.TurnStarted()
	if status := tracker.Status(); status.Attention != nil || status.Activity != api.AgentActivityWorking {
		t.Fatalf("new turn status = %#v, want working without attention", status)
	}
}

func TestActivityTrackerTurnFailedResetsPendingTools(t *testing.T) {
	tracker := NewActivityTracker()
	started := time.Now()

	tracker.Observe(api.AgentEvent{Type: "user"})
	tracker.Observe(api.AgentEvent{Type: "tool_call", Timestamp: started})
	tracker.TurnFailed()
	if got := tracker.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("after turn failed = %q, want failed", got)
	}

	tracker.Tick(started.Add(time.Hour))
	if got := tracker.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("failed turn moved to %q, want failed", got)
	}
}

func TestActivityTrackerIgnoresSidechains(t *testing.T) {
	tracker := NewActivityTracker()

	tracker.Observe(api.AgentEvent{
		Type:       "assistant",
		StopReason: "end_turn",
		Sidechain:  true,
	})
	if got := tracker.Activity(); got != api.AgentActivityReady {
		t.Fatalf("sidechain end_turn changed activity to %q, want ready", got)
	}
}

func TestParserDrivesCodexActivity(t *testing.T) {
	parser := newParser("codex")

	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}`))
	if got := parser.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after task_started = %q, want working", got)
	}

	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"task_complete"}}`))
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after task_complete = %q, want ready", got)
	}

	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"turn_aborted"}}`))
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after turn_aborted = %q, want ready", got)
	}
}

func TestParserAssociatesEventsWithTurn(t *testing.T) {
	parser := newParser("codex")

	user := parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}`))
	assistant := parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}`))
	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}`))

	if len(user) != 1 || user[0].Turn != 1 {
		t.Fatalf("user events = %#v, want turn 1", user)
	}
	if len(assistant) != 1 || assistant[0].Turn != 1 {
		t.Fatalf("assistant events = %#v, want turn 1", assistant)
	}
	turns := parser.DrainTurns()
	if len(turns) != 2 || turns[0].Status != api.AgentTurnStarted || turns[1].Status != api.AgentTurnCompleted {
		t.Fatalf("turns = %#v, want started then completed", turns)
	}
}

func TestParserDrivesClaudeActivity(t *testing.T) {
	parser := newParser("claude")

	parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}`))
	if got := parser.Activity(); got != api.AgentActivityWorking {
		t.Fatalf("after user = %q, want working", got)
	}

	parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}`))
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("after end_turn = %q, want ready", got)
	}

	parser.parse([]byte(`{"type":"system","subtype":"api_error","timestamp":"2026-08-16T10:00:02Z","content":"boom"}`))
	if got := parser.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("after api_error = %q, want failed", got)
	}
}
