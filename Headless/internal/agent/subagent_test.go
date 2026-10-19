package agent

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestClaudeSpawnAgentProjectsToSubagentFromMeta(t *testing.T) {
	dir := t.TempDir()
	subagentsDir := filepath.Join(dir, "subagents")
	writeMetaFile(t, filepath.Join(subagentsDir, "agent-child1.meta.json"), `{"agentType":"Explore","description":"Map the repo","toolUseId":"toolu_spawn_1"}`)

	parser := newParser("claude").(*claudeParser)
	parser.SetSubagentsDir(subagentsDir)

	call := []byte(`{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_spawn_1","name":"Agent","input":{"subagent_type":"Explore","description":"Map the repo"}}]}}`)
	if events := parser.parse(call); len(events) != 1 || events[0].Type != "tool_call" {
		t.Fatalf("spawn call events = %#v, want one tool_call", events)
	}

	result := []byte(`{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_spawn_1","content":[{"type":"text","text":"Async agent launched successfully. agentId: deadbeef (internal ID)"}]}]}}`)
	events := parser.parse(result)
	if len(events) != 1 || events[0].Type != "subagent" {
		t.Fatalf("spawn result events = %#v, want one subagent", events)
	}
	payload := events[0].Payload
	if payload["subagentId"] != "child1" {
		t.Errorf("subagentId = %v, want child1 (from the meta file)", payload["subagentId"])
	}
	if payload["parentCallId"] != "toolu_spawn_1" {
		t.Errorf("parentCallId = %v, want toolu_spawn_1", payload["parentCallId"])
	}
	if payload["label"] != "Explore" || payload["summary"] != "Map the repo" {
		t.Errorf("unexpected subagent payload: %#v", payload)
	}
}

func TestClaudeSpawnAgentFallsBackToResultText(t *testing.T) {
	parser := newParser("claude").(*claudeParser)
	call := []byte(`{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_spawn_1","name":"Task","input":{"subagent_type":"Reviewer","description":"Review code"}}]}}`)
	parser.parse(call)
	result := []byte(`{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_spawn_1","content":[{"type":"text","text":"Async agent launched. agentId: abc123xyz (internal ID)"}]}]}}`)
	events := parser.parse(result)
	if len(events) != 1 || events[0].Type != "subagent" {
		t.Fatalf("events = %#v, want one subagent", events)
	}
	if events[0].Payload["subagentId"] != "abc123xyz" || events[0].Payload["label"] != "Reviewer" {
		t.Fatalf("unexpected subagent payload: %#v", events[0].Payload)
	}
}

func TestWatcherTailsClaudeSubagentTranscript(t *testing.T) {
	dir := t.TempDir()
	session := "11111111-1111-1111-1111-111111111111"
	main := filepath.Join(dir, session+".jsonl")
	subagentsDir := filepath.Join(dir, session, "subagents")
	childID := "childagent1"
	writeLines(t, main,
		`{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_spawn_1","name":"Agent","input":{"subagent_type":"Explore","description":"Map the repo"}}]}}`,
		`{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_spawn_1","content":[{"type":"text","text":"Async agent launched. agentId: `+childID+` (internal ID)"}]}]}}`,
	)
	writeMetaFile(t, filepath.Join(subagentsDir, "agent-"+childID+".meta.json"), `{"agentType":"Explore","description":"Map the repo","toolUseId":"toolu_spawn_1"}`)
	writeLines(t, filepath.Join(subagentsDir, "agent-"+childID+".jsonl"),
		`{"type":"assistant","uuid":"c1","isSidechain":true,"agentId":"`+childID+`","message":{"role":"assistant","content":[{"type":"text","text":"working"},{"type":"tool_use","id":"tu_bash","name":"Bash","input":{"command":"ls -la"}}]}}`,
	)

	seen := collectWatcherEvents(t, "claude", main)
	requireChildToolCall(t, seen, childID, "shell")
	// The child's own message is activity under the row, never a second row
	// describing the same subagent, and it carries the stable identity.
	rows := 0
	childText := 0
	for _, event := range seen {
		if event.Type == "subagent" && event.Payload["subagentId"] == childID {
			rows++
		}
		if event.Type == "assistant" && event.Sidechain && event.Payload["subagentId"] == childID {
			childText++
		}
	}
	if rows != 1 {
		t.Errorf("subagent rows = %d, want 1", rows)
	}
	if childText != 1 {
		t.Errorf("child assistant events = %d, want 1", childText)
	}
}

func TestWatcherTailsCodexSubagentRollout(t *testing.T) {
	home := t.TempDir()
	dateDir := filepath.Join(home, "sessions", "2026", "01", "02")
	mainThread := "aaaaaaaa-1111-1111-1111-111111111111"
	childThread := "bbbbbbbb-2222-2222-2222-222222222222"
	main := filepath.Join(dateDir, "rollout-2026-01-02T00-00-00-"+mainThread+".jsonl")
	writeLines(t, main,
		`{"timestamp":"2026-01-02T00:00:00Z","type":"session_meta","payload":{"id":"`+mainThread+`"}}`,
		`{"timestamp":"2026-01-02T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","call_id":"call_spawn_1","arguments":"{\"agent_type\":\"worker\",\"prompt\":\"Run tests\"}"}}`,
		`{"timestamp":"2026-01-02T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn_1","output":"{\"agent_id\":\"`+childThread+`\",\"nickname\":\"Gibbs\"}"}}`,
	)
	writeLines(t, filepath.Join(dateDir, "rollout-2026-01-02T00-00-03-"+childThread+".jsonl"),
		`{"timestamp":"2026-01-02T00:00:03Z","type":"session_meta","payload":{"id":"`+childThread+`","parent_thread_id":"`+mainThread+`"}}`,
		`{"timestamp":"2026-01-02T00:00:04Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_exec_1","arguments":"{\"command\":\"go test ./...\"}"}}`,
	)

	seen := collectWatcherEvents(t, "codex", main)
	requireChildToolCall(t, seen, childThread, "shell")
}

// collectWatcherEvents tails one transcript and waits until a child tool call
// proves the subagent transcript was discovered and merged.
func collectWatcherEvents(t *testing.T, provider, path string) []api.AgentEvent {
	t.Helper()
	var mu sync.Mutex
	var seen []api.AgentEvent
	watcher := Start("session-1", provider, path, func(events []api.AgentEvent, _ api.AgentStatus) {
		mu.Lock()
		seen = append(seen, events...)
		mu.Unlock()
	}, nil, nil)
	defer watcher.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := watcher.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	// The child tailer is polled right after the parent replay, so give the
	// loop one more tick before reading the accumulated events.
	deadline := time.Now().Add(3 * time.Second)
	for {
		mu.Lock()
		snapshot := append([]api.AgentEvent(nil), seen...)
		mu.Unlock()
		for _, event := range snapshot {
			if event.Type == "tool_call" && event.Sidechain {
				return snapshot
			}
		}
		if time.Now().After(deadline) {
			return snapshot
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func requireChildToolCall(t *testing.T, events []api.AgentEvent, subagentID, toolName string) {
	t.Helper()
	for _, event := range events {
		if event.Type == "subagent" && event.Payload["subagentId"] == subagentID {
			if event.Payload["parentCallId"] == nil {
				t.Errorf("subagent row %q has no parentCallId: %#v", subagentID, event.Payload)
			}
			continue
		}
		if event.Type == "tool_call" && event.Sidechain && event.ToolName == toolName {
			if event.Payload["subagentId"] != subagentID {
				t.Errorf("child tool_call subagentId = %v, want %q", event.Payload["subagentId"], subagentID)
			}
			return
		}
	}
	t.Fatalf("no sidechain %s tool_call for subagent %q in %#v", toolName, subagentID, events)
}

func writeMetaFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// TestCodexChildQuestionLiftsParentAttention drives the whole child-waiting
// chain with a real Codex child rollout shape: the parent's spawn_agent output
// names the child thread (real `{"agent_id":...,"nickname":...}` output), and
// the child rollout carries a `request_user_input` call. The call and its
// arguments are copied from a real rollout in the local Codex store (a
// request_user_input record); that record came from a user thread, because no
// child thread in the local store ever raised an approval or a question, so its
// placement in the child rollout is what is synthesized here. The parser's
// event shape, the identity tagging, and the attention lift are all real.
func TestCodexChildQuestionLiftsParentAttention(t *testing.T) {
	home := t.TempDir()
	dateDir := filepath.Join(home, "sessions", "2026", "01", "02")
	mainThread := "aaaaaaaa-1111-1111-1111-111111111111"
	childThread := "bbbbbbbb-2222-2222-2222-222222222222"
	main := filepath.Join(dateDir, "rollout-2026-01-02T00-00-00-"+mainThread+".jsonl")
	child := filepath.Join(dateDir, "rollout-2026-01-02T00-00-03-"+childThread+".jsonl")
	writeLines(t, main,
		`{"timestamp":"2026-01-02T00:00:00Z","type":"session_meta","payload":{"id":"`+mainThread+`"}}`,
		`{"timestamp":"2026-01-02T00:00:01Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","call_id":"call_spawn_1","arguments":"{\"agent_type\":\"worker\",\"message\":\"Ask the person\"}"}}`,
		`{"timestamp":"2026-01-02T00:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_spawn_1","output":"{\"agent_id\":\"`+childThread+`\",\"nickname\":\"Gibbs\"}"}}`,
	)
	// The function_call line is a real request_user_input record; only its
	// presence inside a child rollout is constructed for this test.
	writeLines(t, child,
		`{"timestamp":"2026-01-02T00:00:03Z","type":"session_meta","payload":{"id":"`+childThread+`","parent_thread_id":"`+mainThread+`"}}`,
		`{"timestamp":"2026-01-02T00:00:04Z","type":"response_item","payload":{"type":"function_call","id":"fc_ask_1","name":"request_user_input","call_id":"call_ask_1","arguments":"{\"questions\":[{\"header\":\"Next\",\"id\":\"next_step\",\"question\":\"What next?\",\"options\":[{\"label\":\"Fix code\"},{\"label\":\"Explain\"}]}]}"}}`,
	)

	var mu sync.Mutex
	var seen []api.AgentEvent
	var lastStatus api.AgentStatus
	watcher := Start("session-1", "codex", main, func(events []api.AgentEvent, status api.AgentStatus) {
		mu.Lock()
		seen = append(seen, events...)
		lastStatus = status
		mu.Unlock()
	}, func(status api.AgentStatus) {
		mu.Lock()
		lastStatus = status
		mu.Unlock()
	}, nil)
	defer watcher.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := watcher.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}

	question := waitForCondition(t, &mu, func() bool {
		return hasSubagentQuestion(seen)
	})
	if !question {
		t.Fatalf("no sidechain question for child %q in %#v", childThread, snapshotEvents(&mu, seen))
	}
	event := firstSubagentQuestion(&mu, seen)
	if event == nil {
		t.Fatal("question event vanished")
	}
	if event.Payload["subagentId"] != childThread {
		t.Fatalf("question subagentId = %v, want %q", event.Payload["subagentId"], childThread)
	}
	if !event.Sidechain {
		t.Fatal("child question is not marked sidechain")
	}
	if !waitForCondition(t, &mu, func() bool {
		return lastStatus.Attention != nil && lastStatus.Attention.Kind == api.AgentAttentionInput
	}) {
		t.Fatalf("parent attention = %#v, want input from the child's question", lastStatus.Attention)
	}

	// The child answers: Codex records the call's output, the child parser emits
	// a resolved interaction, and the parent stops asking.
	output := `{"timestamp":"2026-01-02T00:00:05Z","type":"response_item","payload":{"type":"function_call_output","id":"fco_1","call_id":"call_ask_1","output":"{\"answers\":{\"next_step\":{\"answers\":[\"Fix code\"]}}}"}}` + "\n"
	file, err := os.OpenFile(child, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(output); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if !waitForCondition(t, &mu, func() bool {
		return lastStatus.Attention == nil
	}) {
		t.Fatalf("parent attention = %#v, want it cleared after the child's answer", lastStatus.Attention)
	}
}

func hasSubagentQuestion(events []api.AgentEvent) bool {
	for _, event := range events {
		if event.Type == "question" && event.Sidechain && event.Payload["subagentId"] != nil {
			return true
		}
	}
	return false
}

func firstSubagentQuestion(mu *sync.Mutex, events []api.AgentEvent) *api.AgentEvent {
	mu.Lock()
	defer mu.Unlock()
	for index := range events {
		if events[index].Type == "question" && events[index].Sidechain && events[index].Payload["subagentId"] != nil {
			event := events[index]
			return &event
		}
	}
	return nil
}

func snapshotEvents(mu *sync.Mutex, events []api.AgentEvent) []api.AgentEvent {
	mu.Lock()
	defer mu.Unlock()
	return append([]api.AgentEvent(nil), events...)
}

// waitForCondition polls a predicate to a bounded deadline, for tailer tests
// where the child file is read on the poll interval rather than synchronously.
func waitForCondition(t *testing.T, mu *sync.Mutex, predicate func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for {
		mu.Lock()
		ok := predicate()
		mu.Unlock()
		if ok {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}
