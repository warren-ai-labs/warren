package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestValidatePiCommand(t *testing.T) {
	cases := []struct {
		command string
		wantErr bool
	}{
		{"pi", false},
		{"pi --model sonnet", false},
		{"pi --provider openai -m gpt-5", false},
		{"pi --session-id abc", true},
		{"pi --resume", true},
		{"pi -c", true},
		{"pi --fork old-session", true},
		{"pi --no-session", true},
		{"pi -p hello", true},
		{"pi --print hello", true},
		{"pi --mode json", true},
		{"pi; rm -rf /", true},
		{"pi $(whoami)", true},
		{"", true},
	}
	for _, tc := range cases {
		err := ValidatePiCommand(tc.command)
		if (err != nil) != tc.wantErr {
			t.Errorf("ValidatePiCommand(%q) error = %v, wantErr %v", tc.command, err, tc.wantErr)
		}
	}
}

func TestPiSessionsRootHonorsEnvOverrides(t *testing.T) {
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", "/custom/sessions")
	if got := PiSessionsRoot(); got != "/custom/sessions" {
		t.Fatalf("PiSessionsRoot = %q, want /custom/sessions", got)
	}
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", "")
	t.Setenv("PI_CODING_AGENT_DIR", "/custom/agent")
	if got := PiSessionsRoot(); got != "/custom/agent/sessions" {
		t.Fatalf("PiSessionsRoot = %q, want /custom/agent/sessions", got)
	}
}

func TestFindPiTranscriptMatchesInjectedSessionID(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	// Pi writes <timestamp>_<session-id>.jsonl directly under the session
	// dir, or under a --<cwd>-- subdirectory. Both layouts must resolve.
	writePiSessionFile(t, filepath.Join(root, "2026-09-01T10-00-00-000Z_warren-pi-1.jsonl"), "warren-pi-1")
	sub := filepath.Join(root, "--Users-me-projects-demo--")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	writePiSessionFile(t, filepath.Join(sub, "2026-09-02T11-00-00-000Z_warren-pi-2.jsonl"), "warren-pi-2")

	// The injected id matches exactly one file.
	if got := FindPiTranscript("warren-pi-2"); !strings.HasSuffix(got, "warren-pi-2.jsonl") {
		t.Fatalf("FindPiTranscript(warren-pi-2) = %q, want suffix _warren-pi-2.jsonl", got)
	}
	if got := FindPiTranscript("warren-pi-1"); !strings.HasSuffix(got, "warren-pi-1.jsonl") {
		t.Fatalf("FindPiTranscript(warren-pi-1) = %q, want suffix _warren-pi-1.jsonl", got)
	}
	// Unknown id, and a file whose header id does not match, are not adopted.
	if got := FindPiTranscript("missing-id"); got != "" {
		t.Fatalf("FindPiTranscript(missing-id) = %q, want empty", got)
	}
	writePiSessionFile(t, filepath.Join(root, "2026-09-03T12-00-00-000Z_warren-pi-3.jsonl"), "some-other-id")
	if got := FindPiTranscript("warren-pi-3"); got != "" {
		t.Fatalf("FindPiTranscript(warren-pi-3) = %q, want empty (header mismatch)", got)
	}
}

func writePiSessionFile(t *testing.T, path, sessionID string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"type":"session","version":3,"id":"` + sessionID + `","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work"}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestEnsurePiBindExtensionInstallsIdempotently(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("WARREN_PI_EXTENSION_PATH", filepath.Join(dir, "ext", "warren-bind.ts"))

	changed, err := EnsurePiBindExtension()
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("first install should report changed")
	}
	data, err := os.ReadFile(filepath.Join(dir, "ext", "warren-bind.ts"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != piBindExtensionSource {
		t.Fatalf("installed extension does not match source")
	}
	if !strings.Contains(string(data), "warren-agent-bind-v1") {
		t.Fatal("installed extension is missing the marker comment")
	}

	changed, err = EnsurePiBindExtension()
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("second install should report unchanged")
	}
}

func TestPiExtensionPathHonorsPiConfigDir(t *testing.T) {
	t.Setenv("WARREN_PI_EXTENSION_PATH", "")
	t.Setenv("PI_CODING_AGENT_DIR", "/custom/agent")
	if got := PiExtensionPath(); got != "/custom/agent/extensions/warren-bind.ts" {
		t.Fatalf("PiExtensionPath = %q, want /custom/agent/extensions/warren-bind.ts", got)
	}
}

func TestPiBindingRoundTripThroughFindPiTranscript(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	bindDir := t.TempDir()
	bindPath := filepath.Join(bindDir, "shell-session.json")

	// The pi extension writes a binding whose sessionId matches the filename
	// pi will use. Simulate the flush timing: binding first, file later.
	binding := Binding{
		Provider:       piProvider,
		SessionID:      "warren-pi-shell",
		TranscriptPath: filepath.Join(root, "2026-09-01T10-00-00-000Z_warren-pi-shell.jsonl"),
		Cwd:            "/work",
	}
	if err := WriteBinding(bindPath, binding); err != nil {
		t.Fatal(err)
	}
	// The target file does not exist yet, so the finder finds nothing and the
	// binding's own transcript path is not on disk either.
	if got := FindPiTranscript("warren-pi-shell"); got != "" {
		t.Fatalf("FindPiTranscript before flush = %q, want empty", got)
	}
	if _, err := os.Stat(binding.TranscriptPath); err == nil {
		t.Fatalf("transcript should not exist yet")
	}

	// After pi flushes the file, the finder resolves it by session id.
	writePiSessionFile(t, binding.TranscriptPath, "warren-pi-shell")
	if got := FindPiTranscript("warren-pi-shell"); got != binding.TranscriptPath {
		t.Fatalf("FindPiTranscript after flush = %q, want %q", got, binding.TranscriptPath)
	}

	// And the binding round-trips through the standard reader.
	read, err := ReadBinding(bindPath)
	if err != nil {
		t.Fatal(err)
	}
	if read == nil || read.Provider != piProvider || read.SessionID != "warren-pi-shell" || read.TranscriptPath != binding.TranscriptPath {
		t.Fatalf("ReadBinding = %#v", read)
	}
}

func TestReadPiTranscriptProjectsConversation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "2026-09-01T10-00-00-000Z_pi-test.jsonl")
	lines := []string{
		`{"type":"session","version":3,"id":"pi-test","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work"}`,
		`{"type":"message","id":"a1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}],"timestamp":1788320000000}}`,
		`{"type":"message","id":"b1","parentId":"a1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reason here"},{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"/work/a.go"}}],"provider":"deepseek","model":"deepseek-v4-pro","usage":{"input":10,"output":20,"cacheRead":5,"cacheWrite":0,"reasoning":3,"totalTokens":35,"cost":{"total":0.001}},"stopReason":"toolUse","timestamp":1788320001000}}`,
		`{"type":"message","id":"c1","parentId":"b1","timestamp":"2026-09-01T10:00:03.000Z","message":{"role":"toolResult","toolCallId":"call_1","toolName":"read","content":[{"type":"text","text":"file contents"}],"isError":false,"timestamp":1788320002000}}`,
		`{"type":"message","id":"d1","parentId":"c1","timestamp":"2026-09-01T10:00:04.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"provider":"deepseek","model":"deepseek-v4-pro","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":15,"cost":{"total":0.0001}},"stopReason":"stop","timestamp":1788320003000}}`,
	}
	writeReadLines(t, path, lines...)

	events, err := ReadTranscript(context.Background(), "pi", path, ReadOptions{IncludeTypes: []string{"user", "assistant", "reasoning", "tool_call", "tool_output"}})
	if err != nil {
		t.Fatal(err)
	}
	got := eventTypes(events)
	if got != "user,reasoning,tool_call,tool_output,assistant" {
		t.Fatalf("event types = %q, want user,reasoning,tool_call,tool_output,assistant", got)
	}

	user := events[0]
	if user.Type != "user" || user.Content != "hello" {
		t.Errorf("user event = %#v", user)
	}
	reasoning := events[1]
	if reasoning.Type != "reasoning" || reasoning.Content != "reason here" {
		t.Errorf("reasoning event = %#v", reasoning)
	}
	toolCall := events[2]
	if toolCall.ToolName != "read" || toolCall.CallID != "call_1" || toolCall.ToolStatus != "" {
		t.Errorf("tool_call event = %#v", toolCall)
	}
	if input, ok := toolCall.ToolInput.(map[string]any); !ok || input["path"] != "/work/a.go" {
		t.Errorf("tool_call input = %#v", toolCall.ToolInput)
	}
	if len(toolCall.Files) != 1 || toolCall.Files[0] != "/work/a.go" {
		t.Errorf("tool_call files = %v", toolCall.Files)
	}
	toolOutput := events[3]
	if toolOutput.ToolName != "read" || toolOutput.CallID != "call_1" || toolOutput.ToolStatus != "success" || toolOutput.Output != "file contents" {
		t.Errorf("tool_output event = %#v", toolOutput)
	}
	assistant := events[4]
	if assistant.Content != "done" || assistant.StopReason != "stop" || assistant.Model != "deepseek/deepseek-v4-pro" {
		t.Errorf("assistant event = %#v", assistant)
	}
	if assistant.Usage == nil || assistant.Usage.InputTokens != 10 || assistant.Usage.OutputTokens != 5 ||
		assistant.Usage.ReasoningOutputTokens != 0 || assistant.Usage.TotalTokens != 15 {
		t.Errorf("assistant usage = %#v", assistant.Usage)
	}
}

func TestReadPiTranscriptErrorAndAbort(t *testing.T) {
	path := filepath.Join(t.TempDir(), "2026-09-01T10-00-00-000Z_pi-test.jsonl")
	lines := []string{
		`{"type":"session","version":3,"id":"pi-test","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work"}`,
		`{"type":"message","id":"e1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"failed"}],"provider":"x","model":"m","stopReason":"error","errorMessage":"boom","timestamp":1788320000000}}`,
		`{"type":"message","id":"f1","parentId":"e1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"user","content":"second try","timestamp":1788320001000}}`,
		`{"type":"message","id":"g1","parentId":"f1","timestamp":"2026-09-01T10:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"interrupted"}],"provider":"x","model":"m","stopReason":"aborted","timestamp":1788320002000}}`,
	}
	writeReadLines(t, path, lines...)

	events, err := ReadTranscript(context.Background(), "pi", path, ReadOptions{IncludeTypes: []string{"assistant", "error", "user"}})
	if err != nil {
		t.Fatal(err)
	}
	got := eventTypes(events)
	if got != "assistant,error,user,assistant" {
		t.Fatalf("event types = %q, want assistant,error,user,assistant", got)
	}
	if events[1].Type != "error" || events[1].Error != "boom" {
		t.Errorf("error event = %#v", events[1])
	}
	// A single transcript read drains turns per line, so the abort boundary is
	// not observable through the event list; the tracker transition is what
	// matters for live sessions and is covered by the watcher test.
}

func TestParsePiBashExecutionProjection(t *testing.T) {
	path := filepath.Join(t.TempDir(), "2026-09-01T10-00-00-000Z_pi-test.jsonl")
	lines := []string{
		`{"type":"session","version":3,"id":"pi-test","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work"}`,
		`{"type":"message","id":"h1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"bashExecution","command":"ls -la","output":"total 0","exitCode":0,"cancelled":false,"truncated":false,"timestamp":1788320000000}}`,
		`{"type":"message","id":"i1","parentId":"h1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"bashExecution","command":"rm -rf /","output":"permission denied","exitCode":1,"cancelled":false,"truncated":false,"timestamp":1788320001000}}`,
	}
	writeReadLines(t, path, lines...)

	events, err := ReadTranscript(context.Background(), "pi", path, ReadOptions{IncludeTypes: []string{"tool_call", "tool_output"}})
	if err != nil {
		t.Fatal(err)
	}
	got := eventTypes(events)
	if got != "tool_call,tool_output,tool_call,tool_output" {
		t.Fatalf("event types = %q, want tool_call,tool_output,tool_call,tool_output", got)
	}
	if events[0].ToolName != "bash" || events[0].CallID != "h1" {
		t.Errorf("bash call = %#v", events[0])
	}
	if events[1].ToolStatus != "success" || events[1].Output != "total 0" {
		t.Errorf("bash success output = %#v", events[1])
	}
	if events[2].ToolName != "bash" || events[3].ToolStatus != "error" || events[3].Error != "permission denied" {
		t.Errorf("bash error output = %#v %#v", events[2], events[3])
	}
}

func TestPiWatcherTracksTurnLifecycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "2026-09-01T10-00-00-000Z_pi-test.jsonl")
	lines := []string{
		`{"type":"session","version":3,"id":"pi-test","timestamp":"2026-09-01T10:00:00.000Z","cwd":"/work"}`,
		`{"type":"message","id":"u1","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"do it","timestamp":1788320000000}}`,
		`{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"echo hi"}}],"provider":"x","model":"m","stopReason":"toolUse","timestamp":1788320001000}}`,
		`{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-09-01T10:00:03.000Z","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"hi"}],"isError":false,"timestamp":1788320002000}}`,
		`{"type":"message","id":"a2","parentId":"r1","timestamp":"2026-09-01T10:00:04.000Z","message":{"role":"assistant","content":[{"type":"text","text":"all done"}],"provider":"x","model":"m","stopReason":"stop","timestamp":1788320003000}}`,
	}
	writeReadLines(t, path, lines...)

	var turns []api.AgentTurn
	watcher := Start("sess-1", "pi", path, nil, nil, func(observed []api.AgentTurn, replay bool) {
		turns = append(turns, observed...)
	})
	defer watcher.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := watcher.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	status := watcher.parser.Status()
	if status.Activity != api.AgentActivityReady {
		t.Fatalf("status = %v, want ready", status.Activity)
	}
	if len(turns) == 0 {
		t.Fatalf("no turns observed")
	}
	last := turns[len(turns)-1]
	if last.Status != api.AgentTurnCompleted {
		t.Fatalf("last turn = %#v, want completed", last)
	}
	snapshot := watcher.Snapshot()
	types := eventTypes(snapshot)
	if types != "user,tool_call,tool_output,assistant" {
		t.Fatalf("snapshot types = %q, want user,tool_call,tool_output,assistant", types)
	}
}
