package agent

import (
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func todoItemsFrom(t *testing.T, payload map[string]any) []map[string]any {
	t.Helper()
	raw, ok := payload["items"].([]any)
	if !ok {
		t.Fatalf("items = %#v, want []any", payload["items"])
	}
	items := make([]map[string]any, len(raw))
	for index, item := range raw {
		items[index] = item.(map[string]any)
	}
	return items
}

func TestClaudeTaskToolsProjectToTodoSnapshots(t *testing.T) {
	parser := newParser("claude")
	createUse := func(id, subject string) []byte {
		return []byte(`{"type":"assistant","uuid":"a-` + id + `","timestamp":"2026-09-27T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_` + id + `","name":"TaskCreate","input":{"subject":"` + subject + `","activeForm":"Working","description":"details"}}]}}`)
	}
	if events := parser.parse(createUse("c1", "Protocol schema")); len(events) != 0 {
		t.Fatalf("TaskCreate call = %#v, want no row before the result", events)
	}
	events := parser.parse([]byte(`{"type":"user","uuid":"u-c1","timestamp":"2026-09-27T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_c1","content":"Task #1 created successfully: Protocol schema"}]},"toolUseResult":{"task":{"id":"1","subject":"Protocol schema"}}}`))
	if len(events) != 1 || events[0].Type != "todo" || events[0].ID != "claude-todos" {
		t.Fatalf("TaskCreate result = %#v, want one todo snapshot", events)
	}

	// The id falls back to the result text when toolUseResult is absent.
	parser.parse(createUse("c2", "Go runtime"))
	events = parser.parse([]byte(`{"type":"user","uuid":"u-c2","timestamp":"2026-09-27T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_c2","content":"Task #2 created successfully: Go runtime"}]}}`))
	items := todoItemsFrom(t, events[0].Payload)
	if len(items) != 2 || items[1]["id"] != "2" || items[1]["label"] != "Go runtime" || items[1]["state"] != "pending" {
		t.Fatalf("items = %#v, want second pending task", items)
	}

	update := func(id, input string) {
		parser.parse([]byte(`{"type":"assistant","uuid":"a-` + id + `","timestamp":"2026-09-27T10:00:03Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_` + id + `","name":"TaskUpdate","input":` + input + `}]}}`))
		events = parser.parse([]byte(`{"type":"user","uuid":"u-` + id + `","timestamp":"2026-09-27T10:00:04Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_` + id + `","content":"Updated task"}]}}`))
	}
	update("u1", `{"taskId":"1","status":"completed"}`)
	update("u2", `{"taskId":"2","status":"in_progress","subject":"Go runtime and CDP"}`)
	items = todoItemsFrom(t, events[0].Payload)
	if items[0]["state"] != "completed" || items[1]["state"] != "in_progress" || items[1]["label"] != "Go runtime and CDP" {
		t.Fatalf("items = %#v, want updated states and subject", items)
	}
	if events[0].Payload["state"] != "in_progress" {
		t.Fatalf("state = %v, want in_progress", events[0].Payload["state"])
	}

	update("u3", `{"taskId":"2","status":"deleted"}`)
	items = todoItemsFrom(t, events[0].Payload)
	if len(items) != 1 || events[0].Payload["state"] != "completed" {
		t.Fatalf("after delete = %#v, want one completed task", events[0].Payload)
	}
}

func TestClaudeTaskFailedOrUnknownUpdateEmitsNothing(t *testing.T) {
	parser := newParser("claude")
	parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-09-27T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"TaskUpdate","input":{"taskId":"9","status":"completed"}}]}}`))
	if events := parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-09-27T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_x","content":"Updated task #9 status"}]}}`)); len(events) != 0 {
		t.Fatalf("unknown task update = %#v, want nothing", events)
	}
	parser.parse([]byte(`{"type":"assistant","uuid":"a2","timestamp":"2026-09-27T10:00:02Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_y","name":"TaskCreate","input":{"subject":"Nope"}}]}}`))
	if events := parser.parse([]byte(`{"type":"user","uuid":"u2","timestamp":"2026-09-27T10:00:03Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_y","content":"denied","is_error":true}]}}`)); len(events) != 0 {
		t.Fatalf("failed create = %#v, want nothing", events)
	}
}

func TestCodexExecUpdatePlanProjectsToPlan(t *testing.T) {
	p := newParser("codex")
	call := []byte(`{"timestamp":"2026-09-27T10:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_p","name":"exec","input":"const r = await tools.update_plan({explanation:\"Keep it small.\",plan:[\n  {step:\"检查 \\\"iOS\\\" 链路\",status:\"completed\"},\n  {step:'Fix parser',status:\"in_progress\"},\n]});\ntext(r);\n"}}`)
	events := p.Parse(call)
	if len(events) != 1 || events[0].Type != "plan" || events[0].ID != "codex-plan" {
		t.Fatalf("exec update_plan = %#v, want one plan", events)
	}
	items := events[0].Payload["items"].([]map[string]any)
	if len(items) != 2 || items[0]["label"] != `检查 "iOS" 链路` || items[1]["label"] != "Fix parser" || items[1]["state"] != "in_progress" {
		t.Fatalf("items = %#v", items)
	}
	output := []byte(`{"timestamp":"2026-09-27T10:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_p","output":[{"type":"input_text","text":"Script completed\nOutput:\n"},{"type":"input_text","text":"{}"}]}}`)
	if events := p.Parse(output); len(events) != 0 {
		t.Fatalf("plan-only output = %#v, want suppressed", events)
	}
}

func TestCodexExecUpdatePlanKeepsOtherWork(t *testing.T) {
	p := newParser("codex")
	mixed := []byte(`{"timestamp":"2026-09-27T10:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_m","name":"exec","input":"await tools.update_plan({plan:[{step:\"Run tests\",status:\"in_progress\"}]}); const out = await tools.exec_command({cmd:\"go test ./...\"}); text(out);"}}`)
	events := p.Parse(mixed)
	if len(events) != 2 || events[0].Type != "plan" || events[1].Type != "tool_call" {
		t.Fatalf("mixed exec = %#v, want plan then tool call", events)
	}
	if events := p.Parse([]byte(`{"timestamp":"2026-09-27T10:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_m","output":"ok"}}`)); len(events) != 1 || events[0].Type != "tool_output" {
		t.Fatalf("mixed output = %#v, want tool output", events)
	}

	shorthand := []byte(`{"timestamp":"2026-09-27T10:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_s","name":"exec","input":"const plan = [\n  {step: \"Read\", status: \"completed\"},\n  {step: \"Ship\", status: \"pending\"}\n];\nconst r = await tools.update_plan({explanation:\"Now \u0060shipping\u0060.\", plan});\ntext(r);"}}`)
	events = p.Parse(shorthand)
	if len(events) != 1 || events[0].Type != "plan" {
		t.Fatalf("shorthand plan = %#v, want plan from the const binding", events)
	}
	if items := events[0].Payload["items"].([]map[string]any); len(items) != 2 || items[1]["label"] != "Ship" {
		t.Fatalf("shorthand items = %#v", items)
	}

	variable := []byte(`{"timestamp":"2026-09-27T10:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_v","name":"exec","input":"let steps = [{step:\"x\",status:\"pending\"}]; await tools.update_plan({plan: steps});"}}`)
	events = p.Parse(variable)
	if len(events) != 1 || events[0].Type != "tool_call" {
		t.Fatalf("variable plan = %#v, want ordinary tool call", events)
	}
}

func TestCodexProposedPlanBecomesPlanCard(t *testing.T) {
	p := newParser("codex")
	line := []byte(`{"timestamp":"2026-09-27T13:29:26Z","type":"response_item","payload":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Tightened it:\n\n<proposed_plan>\n# Question tool test\n\n## Steps\n\n1. Ask one question.\n</proposed_plan>\n\nDry run passed."}]}}`)
	events := p.Parse(line)
	if len(events) != 3 {
		t.Fatalf("events = %#v, want prose, plan, prose", events)
	}
	if events[0].Type != "assistant" || events[0].Content != "Tightened it:" || events[0].ID != "msg_1" {
		t.Fatalf("leading prose = %#v", events[0])
	}
	plan := events[1]
	if plan.Type != "plan" || plan.Payload["state"] != "proposed" || plan.Payload["title"] != "Question tool test" {
		t.Fatalf("proposal = %#v", plan)
	}
	if plan.Payload["summary"] != "## Steps\n\n1. Ask one question." {
		t.Fatalf("summary = %q", plan.Payload["summary"])
	}
	if plan.ID == "codex-plan" || plan.Payload["planId"] != plan.ID {
		t.Fatalf("proposal identity = %q / %v", plan.ID, plan.Payload["planId"])
	}
	if events[2].Type != "assistant" || events[2].Content != "Dry run passed." || events[2].ID == "msg_1" {
		t.Fatalf("trailing prose = %#v", events[2])
	}

	// The mirrored agent_message is the same reply and must not duplicate it.
	mirror := []byte(`{"timestamp":"2026-09-27T13:29:26Z","type":"event_msg","payload":{"type":"agent_message","message":"Tightened it:\n\n<proposed_plan>\n# Question tool test\n\n## Steps\n\n1. Ask one question.\n</proposed_plan>\n\nDry run passed."}}`)
	if events := p.Parse(mirror); len(events) != 0 {
		t.Fatalf("mirror = %#v, want deduplicated", events)
	}
}

func TestClaudeExitPlanModeBecomesProposalCard(t *testing.T) {
	parser := newParser("claude")
	use := func(id string) []api.AgentEvent {
		return parser.parse([]byte(`{"type":"assistant","uuid":"a-` + id + `","timestamp":"2026-09-27T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_` + id + `","name":"ExitPlanMode","input":{"plan":"# Remote latency\n\n## Context\n\nSend has no delivered state.","planFilePath":"/tmp/plan.md"}}]}}`))
	}
	events := use("p1")
	if len(events) != 1 || events[0].Type != "plan" {
		t.Fatalf("ExitPlanMode = %#v, want one plan", events)
	}
	proposal := events[0]
	if proposal.Payload["state"] != "proposed" || proposal.Payload["proposal"] != true || proposal.Payload["title"] != "Remote latency" {
		t.Fatalf("proposal payload = %#v", proposal.Payload)
	}
	if proposal.Payload["summary"] != "## Context\n\nSend has no delivered state." {
		t.Fatalf("summary = %q", proposal.Payload["summary"])
	}

	events = parser.parse([]byte(`{"type":"user","uuid":"u-p1","timestamp":"2026-09-27T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_p1","content":"User has approved your plan. You can now start coding."}]},"toolUseResult":{"plan":"# Remote latency"}}`))
	if len(events) != 1 || events[0].ID != proposal.ID || events[0].Payload["state"] != "approved" || events[0].Payload["summary"] != proposal.Payload["summary"] {
		t.Fatalf("approval = %#v, want the same card approved", events)
	}

	use("p2")
	events = parser.parse([]byte(`{"type":"user","uuid":"u-p2","timestamp":"2026-09-27T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_p2","is_error":true,"content":"The user doesn't want to proceed with this tool use. To tell you how to proceed, the user said:\nThink about the UX first"}]},"toolUseResult":"Error: rejected"}`))
	if len(events) != 1 || events[0].Payload["state"] != "rejected" || events[0].Payload["feedback"] != "Think about the UX first" {
		t.Fatalf("rejection = %#v, want rejected card with feedback", events)
	}
}

func TestProposedPlanTitleDropsInlineMarkdown(t *testing.T) {
	event, ok := proposedPlanEvent(api.AgentEvent{}, "codex", "# Add `bye` to **[notes.txt](notes.txt)**\n\n1. Append it.")
	if !ok || event.Payload["title"] != "Add bye to notes.txt" || event.Content != "Add bye to notes.txt" {
		t.Fatalf("title = %v / %q", event.Payload["title"], event.Content)
	}
	if event.Payload["summary"] != "1. Append it." {
		t.Fatalf("summary = %q", event.Payload["summary"])
	}
}
