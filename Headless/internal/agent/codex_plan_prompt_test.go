package agent

import (
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func codexPlanTurn(t *testing.T, p Parser, turnID, planTitle string) []api.AgentEvent {
	t.Helper()
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:29:20Z","type":"event_msg","payload":{"type":"task_started","turn_id":"` + turnID + `","collaboration_mode_kind":"plan"}}`))
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:29:21Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"plan it ` + turnID + `"}]}}`))
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:29:26Z","type":"response_item","payload":{"type":"message","id":"msg_` + turnID + `","role":"assistant","content":[{"type":"output_text","text":"<proposed_plan>\n# ` + planTitle + `\n\n1. Do it.\n</proposed_plan>"}]}}`))
	return p.Parse([]byte(`{"timestamp":"2026-09-27T13:29:27Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"` + turnID + `","last_agent_message":null}}`))
}

func TestCodexPlanTurnOpensImplementationPrompt(t *testing.T) {
	p := newParser("codex")
	events := codexPlanTurn(t, p, "turn-1", "Ship it")
	if len(events) != 1 || events[0].Type != "confirmation" {
		t.Fatalf("task_complete = %#v, want one confirmation", events)
	}
	prompt := events[0]
	if prompt.ID != "codex-plan-implementation-turn-1" || prompt.Payload["state"] != "pending" ||
		prompt.Payload["action"] != PlanImplementationAction || prompt.Payload["description"] != "Ship it" {
		t.Fatalf("prompt = %#v", prompt)
	}
	if options, _ := prompt.Payload["options"].([]any); len(options) != 3 {
		t.Fatalf("options = %#v, want the picker's three rows", prompt.Payload["options"])
	}
	status := p.Status()
	if status.Activity != api.AgentActivityReady {
		t.Fatalf("activity = %q, want ready: the turn has ended", status.Activity)
	}
	if status.Attention == nil || status.Attention.Kind != api.AgentAttentionInput ||
		status.Attention.Reason != PlanImplementationAction || status.Attention.RequestID != prompt.ID {
		t.Fatalf("attention = %#v, want the pending picker", status.Attention)
	}
}

func TestCodexImplementPlanSettlesPromptAndApprovesProposal(t *testing.T) {
	p := newParser("codex")
	codexPlanTurn(t, p, "turn-1", "Ship it")
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:30:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2","collaboration_mode_kind":"default"}}`))
	if status := p.Status(); status.Attention != nil {
		t.Fatalf("attention = %#v, want cleared by the next turn", status.Attention)
	}
	events := p.Parse([]byte(`{"timestamp":"2026-09-27T13:30:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Implement the plan."}]}}`))
	if len(events) != 3 {
		t.Fatalf("events = %#v, want resolution, approved plan, user", events)
	}
	if events[0].Type != "confirmation" || events[0].Payload["state"] != "resolved" {
		t.Fatalf("resolution = %#v", events[0])
	}
	if response, _ := events[0].Payload["response"].(map[string]any); response["decision"] != PlanImplementationImplement {
		t.Fatalf("response = %#v", events[0].Payload["response"])
	}
	if events[1].Type != "plan" || events[1].Payload["state"] != "approved" || events[1].Payload["proposal"] != true {
		t.Fatalf("proposal = %#v, want approved proposal card", events[1])
	}
	if events[2].Type != "user" {
		t.Fatalf("user = %#v", events[2])
	}
	// The mirrored user_message must not settle the prompt twice.
	if events := p.Parse([]byte(`{"timestamp":"2026-09-27T13:30:01Z","type":"event_msg","payload":{"type":"user_message","message":"Implement the plan."}}`)); len(events) != 0 {
		t.Fatalf("mirror = %#v", events)
	}
}

func TestCodexPlanPromptExpiresWhenUserTypesOn(t *testing.T) {
	p := newParser("codex")
	codexPlanTurn(t, p, "turn-1", "Ship it")
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:30:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2","collaboration_mode_kind":"plan"}}`))
	events := p.Parse([]byte(`{"timestamp":"2026-09-27T13:30:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Also cover the web client"}]}}`))
	if len(events) != 2 || events[0].Type != "confirmation" || events[0].Payload["state"] != "expired" {
		t.Fatalf("events = %#v, want expired prompt then user", events)
	}
}

func TestCodexPlanPromptNeedsPlanModeAndProposal(t *testing.T) {
	p := newParser("codex")
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:29:20Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","collaboration_mode_kind":"default"}}`))
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:29:26Z","type":"response_item","payload":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"<proposed_plan>\n# Ship it\n</proposed_plan>"}]}}`))
	if events := p.Parse([]byte(`{"timestamp":"2026-09-27T13:29:27Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}`)); len(events) != 0 {
		t.Fatalf("default mode = %#v, want no prompt", events)
	}
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:30:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2","collaboration_mode_kind":"plan"}}`))
	if events := p.Parse([]byte(`{"timestamp":"2026-09-27T13:30:05Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}`)); len(events) != 0 {
		t.Fatalf("no proposal = %#v, want no prompt", events)
	}
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:31:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-3","collaboration_mode_kind":"plan"}}`))
	p.Parse([]byte(`{"timestamp":"2026-09-27T13:31:06Z","type":"response_item","payload":{"type":"message","id":"msg_3","role":"assistant","content":[{"type":"output_text","text":"<proposed_plan>\n# Ship it\n</proposed_plan>"}]}}`))
	if events := p.Parse([]byte(`{"timestamp":"2026-09-27T13:31:07Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-3","reason":"interrupted"}}`)); len(events) != 0 {
		t.Fatalf("aborted = %#v, want no prompt", events)
	}
}
