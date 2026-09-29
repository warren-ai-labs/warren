package server

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// The test binary doubles as a scripted ACP agent. A Session whose command is
// the test binary starts it with WARREN_FAKE_ACP_AGENT set, and TestMain hands
// control to runFakeACPAgent instead of running tests.

const fakeACPAgentEnv = "WARREN_FAKE_ACP_AGENT"

func init() {
	if os.Getenv(fakeACPAgentEnv) != "" {
		runFakeACPAgent()
		os.Exit(0)
	}
}

type fakeACPAgent struct {
	writeMu sync.Mutex
	out     *bufio.Writer
	log     *os.File

	mu        sync.Mutex
	nextID    int
	pending   map[string]chan json.RawMessage
	cancelled chan struct{}
	sessionID string
	model     string
}

// fakeModes is a legacy mode list; the fake's config options carry only a
// model, so the Host must surface the mode from here.
var fakeModes = map[string]any{"currentModeId": "ask", "availableModes": []any{
	map[string]any{"id": "ask", "name": "Ask"},
	map[string]any{"id": "code", "name": "Code"},
}}

func (a *fakeACPAgent) configOptions() []any {
	a.mu.Lock()
	model := a.model
	a.mu.Unlock()
	if model == "" {
		model = "small"
	}
	return []any{map[string]any{
		"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model,
		"options": []any{
			map[string]any{"group": "fast", "name": "Fast", "options": []any{map[string]any{"value": "small", "name": "Small"}}},
			map[string]any{"group": "smart", "name": "Smart", "options": []any{map[string]any{"value": "large", "name": "Large", "description": "Slower"}}},
		},
	}}
}

func runFakeACPAgent() {
	agent := &fakeACPAgent{out: bufio.NewWriter(os.Stdout), pending: make(map[string]chan json.RawMessage)}
	if path := os.Getenv("WARREN_FAKE_ACP_LOG"); path != "" {
		agent.log, _ = os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 16<<20)
	for scanner.Scan() {
		var message struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(scanner.Bytes(), &message) != nil {
			continue
		}
		if message.Method == "" {
			agent.mu.Lock()
			reply := agent.pending[string(message.ID)]
			delete(agent.pending, string(message.ID))
			agent.mu.Unlock()
			if reply != nil {
				reply <- message.Result
			}
			continue
		}
		agent.record(message.Method)
		if len(message.ID) == 0 {
			if message.Method == "session/cancel" {
				agent.mu.Lock()
				if agent.cancelled != nil {
					close(agent.cancelled)
					agent.cancelled = nil
				}
				agent.mu.Unlock()
			}
			continue
		}
		go agent.handle(message.ID, message.Method, message.Params)
	}
}

func (a *fakeACPAgent) record(method string) {
	if a.log != nil {
		fmt.Fprintln(a.log, method)
	}
}

func (a *fakeACPAgent) send(value any) {
	encoded, _ := json.Marshal(value)
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	a.out.Write(encoded)
	a.out.WriteByte('\n')
	a.out.Flush()
}

func (a *fakeACPAgent) reply(id json.RawMessage, result any) {
	a.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func (a *fakeACPAgent) replyError(id json.RawMessage, code int, message string) {
	a.send(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
}

func (a *fakeACPAgent) update(update map[string]any) {
	a.send(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": a.sessionID, "update": update}})
}

func (a *fakeACPAgent) request(method string, params any) json.RawMessage {
	a.mu.Lock()
	a.nextID++
	id := fmt.Sprintf("%d", 1000+a.nextID)
	reply := make(chan json.RawMessage, 1)
	a.pending[id] = reply
	a.mu.Unlock()
	a.send(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(id), "method": method, "params": params})
	return <-reply
}

func (a *fakeACPAgent) handle(id json.RawMessage, method string, params json.RawMessage) {
	switch method {
	case "initialize":
		capabilities := map[string]any{"loadSession": os.Getenv("WARREN_FAKE_ACP_LOAD") != ""}
		if os.Getenv("WARREN_FAKE_ACP_RESUME") != "" {
			capabilities["sessionCapabilities"] = map[string]any{"resume": map[string]any{}}
		}
		a.reply(id, map[string]any{
			"protocolVersion":   1,
			"agentCapabilities": capabilities,
			"authMethods":       []any{map[string]any{"id": "login", "name": "Login", "description": "Run `fake login` in a terminal"}},
		})
	case "session/new":
		if os.Getenv("WARREN_FAKE_ACP_AUTH") != "" {
			a.replyError(id, -32000, "Authentication required")
			return
		}
		a.sessionID = fmt.Sprintf("fake-session-%d", time.Now().UnixNano())
		a.reply(id, map[string]any{"sessionId": a.sessionID, "configOptions": a.configOptions(), "modes": fakeModes})
	case "session/set_config_option":
		var request struct {
			ConfigID string `json:"configId"`
			Value    string `json:"value"`
		}
		_ = json.Unmarshal(params, &request)
		if request.ConfigID != "model" {
			a.replyError(id, -32602, "unknown config option")
			return
		}
		a.mu.Lock()
		a.model = request.Value
		a.mu.Unlock()
		a.reply(id, map[string]any{"configOptions": a.configOptions()})
	case "session/resume":
		var request struct {
			SessionID string `json:"sessionId"`
		}
		_ = json.Unmarshal(params, &request)
		if os.Getenv("WARREN_FAKE_ACP_RESUME_FAIL") != "" {
			a.replyError(id, -32002, "Resource not found")
			return
		}
		a.sessionID = request.SessionID
		a.reply(id, map[string]any{"configOptions": a.configOptions(), "modes": fakeModes})
	case "session/load":
		var request struct {
			SessionID string `json:"sessionId"`
		}
		_ = json.Unmarshal(params, &request)
		a.sessionID = request.SessionID
		// Replayed history must never reach the journal.
		a.update(map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "old prompt"}})
		a.update(map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "old answer"}})
		a.reply(id, map[string]any{})
	case "session/prompt":
		var request struct {
			Prompt []struct {
				Text string `json:"text"`
			} `json:"prompt"`
		}
		_ = json.Unmarshal(params, &request)
		text := ""
		if len(request.Prompt) > 0 {
			text = request.Prompt[0].Text
		}
		a.prompt(id, text)
	case "session/set_mode":
		a.reply(id, map[string]any{})
	default:
		a.replyError(id, -32601, "method not found")
	}
}

func (a *fakeACPAgent) chunk(text string) {
	a.update(map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}})
}

func (a *fakeACPAgent) prompt(id json.RawMessage, text string) {
	// Phone keyboards capitalize the first word.
	text = strings.ToLower(text[:min(1, len(text))]) + text[min(1, len(text)):]
	switch {
	case strings.HasPrefix(text, "hello"):
		a.update(map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "thinking"}})
		for _, part := range []string{"Hel", "lo", " there"} {
			a.chunk(part)
		}
		a.reply(id, map[string]any{"stopReason": "end_turn", "usage": map[string]any{"inputTokens": 10, "outputTokens": 3, "totalTokens": 13}})
	case strings.HasPrefix(text, "tool"):
		a.chunk("Looking.")
		a.update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "bash", "kind": "execute", "status": "pending"})
		update := map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "in_progress", "title": "ls", "rawInput": map[string]any{"command": "ls"}}
		a.update(update)
		a.update(update) // an identical repeat must be dropped
		a.update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed", "content": []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "a.txt\n"}}}})
		a.update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call-2", "title": "Edit a.txt", "kind": "edit", "status": "completed",
			"content": []any{map[string]any{"type": "diff", "path": "/tmp/a.txt", "oldText": "one\ntwo\n", "newText": "one\n2\nthree\n"}}})
		a.update(map[string]any{"sessionUpdate": "plan", "entries": []any{
			map[string]any{"content": "Look", "priority": "high", "status": "completed"},
			map[string]any{"content": "Answer", "priority": "medium", "status": "in_progress"},
		}})
		a.chunk("Done.")
		a.reply(id, map[string]any{"stopReason": "end_turn"})
	case strings.HasPrefix(text, "permission"):
		a.update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call-p", "title": "Run rm", "kind": "execute", "status": "pending", "rawInput": map[string]any{"command": "rm -rf build"}})
		raw := a.request("session/request_permission", map[string]any{
			"sessionId": a.sessionID,
			"toolCall":  map[string]any{"toolCallId": "call-p", "title": "Run rm", "kind": "execute", "rawInput": map[string]any{"command": "rm -rf build"}},
			"options": []any{
				map[string]any{"optionId": "reject", "name": "Reject", "kind": "reject_once"},
				map[string]any{"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
				map[string]any{"optionId": "always", "name": "Always allow", "kind": "allow_always"},
			},
		})
		var response struct {
			Outcome struct {
				Outcome  string `json:"outcome"`
				OptionID string `json:"optionId"`
			} `json:"outcome"`
		}
		_ = json.Unmarshal(raw, &response)
		if response.Outcome.Outcome == "cancelled" {
			a.reply(id, map[string]any{"stopReason": "cancelled"})
			return
		}
		a.chunk("chose " + response.Outcome.OptionID)
		a.reply(id, map[string]any{"stopReason": "end_turn"})
	case strings.HasPrefix(text, "later"):
		// Answers after a pause, while a restarting Host is away.
		a.chunk("before ")
		time.Sleep(400 * time.Millisecond)
		a.chunk("after")
		a.reply(id, map[string]any{"stopReason": "end_turn"})
	case strings.HasPrefix(text, "wait"):
		cancelled := make(chan struct{})
		a.mu.Lock()
		a.cancelled = cancelled
		a.mu.Unlock()
		a.chunk("working")
		select {
		case <-cancelled:
			a.reply(id, map[string]any{"stopReason": "cancelled"})
		case <-time.After(20 * time.Second):
			a.reply(id, map[string]any{"stopReason": "end_turn"})
		}
	case strings.HasPrefix(text, "slow"):
		// Paced steps, for watching a live turn in a real client.
		a.update(map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "Planning the change."}})
		steps := []struct{ id, title, kind, detail string }{
			{"s1", "Read reaper.go", "read", "/tmp/wacp/proj/reaper.go"},
			{"s2", "grep Clock", "search", ""},
			{"s3", "go test ./...", "execute", ""},
			{"s4", "Edit reaper.go", "edit", ""},
		}
		for _, step := range steps {
			update := map[string]any{"sessionUpdate": "tool_call", "toolCallId": step.id, "title": step.title, "kind": step.kind, "status": "in_progress"}
			if step.kind == "execute" {
				update["rawInput"] = map[string]any{"command": step.title}
			}
			if step.kind == "read" {
				update["locations"] = []any{map[string]any{"path": step.detail}}
			}
			a.update(update)
			time.Sleep(1500 * time.Millisecond)
			done := map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": step.id, "status": "completed"}
			if step.kind == "edit" {
				done["content"] = []any{map[string]any{"type": "diff", "path": "/tmp/wacp/proj/reaper.go", "oldText": "a\nb\n", "newText": "a\nc\nd\n"}}
			}
			a.update(done)
		}
		for _, part := range []string{"The reaper ", "now takes a ", "Clock, and the ", "suite passes."} {
			a.chunk(part)
			time.Sleep(300 * time.Millisecond)
		}
		a.reply(id, map[string]any{"stopReason": "end_turn"})
	case strings.HasPrefix(text, "mode"):
		a.update(map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": "code"})
		a.chunk("switched")
		a.reply(id, map[string]any{"stopReason": "end_turn"})
	case strings.HasPrefix(text, "terminal"):
		var created struct {
			TerminalID string `json:"terminalId"`
		}
		_ = json.Unmarshal(a.request("terminal/create", map[string]any{
			"sessionId": a.sessionID, "command": "sh", "args": []any{"-c", "printf 'one\\r\\ntwo\\n'; printf '\\033[31mred\\033[0m\\n'; exit 3"},
			"env": []any{map[string]any{"name": "FAKE_TERMINAL", "value": "1"}},
		}), &created)
		a.update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call-t", "title": "Run script", "kind": "execute", "status": "in_progress",
			"content": []any{map[string]any{"type": "terminal", "terminalId": created.TerminalID}}})
		exit := a.request("terminal/wait_for_exit", map[string]any{"sessionId": a.sessionID, "terminalId": created.TerminalID})
		var output struct {
			Output     string          `json:"output"`
			ExitStatus json.RawMessage `json:"exitStatus"`
		}
		_ = json.Unmarshal(a.request("terminal/output", map[string]any{"sessionId": a.sessionID, "terminalId": created.TerminalID}), &output)
		a.update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call-t", "status": "failed"})
		if !strings.HasPrefix(text, "terminal keep") {
			a.request("terminal/release", map[string]any{"sessionId": a.sessionID, "terminalId": created.TerminalID})
		}
		a.chunk(fmt.Sprintf("exit=%s output=%q", exit, output.Output))
		a.reply(id, map[string]any{"stopReason": "end_turn"})
	case strings.HasPrefix(text, "crash"):
		a.chunk("about to crash")
		time.Sleep(50 * time.Millisecond)
		fmt.Fprintln(os.Stderr, "fake agent crashed on purpose")
		os.Exit(3)
	default:
		a.chunk("echo: " + text)
		a.reply(id, map[string]any{"stopReason": "end_turn"})
	}
}
