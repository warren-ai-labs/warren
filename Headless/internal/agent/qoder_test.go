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

func TestValidateQoderCommand(t *testing.T) {
	tests := []struct {
		name    string
		command string
		wantErr bool
		errMsg  string
	}{
		{
			name:    "valid basic command",
			command: "qoder --new-session",
			wantErr: false,
		},
		{
			name:    "valid with workspace",
			command: "qoder --workspace /path/to/workspace",
			wantErr: false,
		},
		{
			name:    "valid with model",
			command: "qoder --model efficient",
			wantErr: false,
		},
		{
			name:    "rejects resume flag",
			command: "qoder --resume abc123",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects fork flag",
			command: "qoder --fork def456",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects fork-session flag",
			command: "qoder --fork-session abc",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects session reuse",
			command: "qoder -c existing-session",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects session-id injection by user",
			command: "qoder --session-id abc123",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects no-session-persistence",
			command: "qoder -p hi --no-session-persistence",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects shell operators",
			command: "qoder; ls",
			wantErr: true,
			errMsg:  "shell operators and substitutions are not supported",
		},
		{
			name:    "rejects command substitution",
			command: "qoder $(whoami)",
			wantErr: true,
			errMsg:  "shell operators and substitutions are not supported",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateQoderCommand(tt.command)
			if tt.wantErr {
				if err == nil {
					t.Errorf("expected error, got nil")
				} else if tt.errMsg != "" {
					if !strings.Contains(err.Error(), tt.errMsg) {
						t.Errorf("expected error containing %q, got %q", tt.errMsg, err.Error())
					}
				}
			} else {
				if err != nil {
					t.Errorf("expected no error, got %v", err)
				}
			}
		})
	}
}

func TestSplitQoderCommandWords(t *testing.T) {
	tests := []struct {
		name    string
		command string
		want    []string
		wantErr bool
	}{
		{
			name:    "simple command",
			command: "qoder new-session",
			want:    []string{"qoder", "new-session"},
			wantErr: false,
		},
		{
			name:    "with quotes",
			command: `qoder --name "my session"`,
			want:    []string{"qoder", "--name", "my session"},
			wantErr: false,
		},
		{
			name:    "nested single quotes",
			command: "qoder 'single' \"double\"",
			want:    []string{"qoder", "single", "double"},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := splitQoderCommandWords(tt.command)
			if (err != nil) != tt.wantErr {
				t.Fatalf("splitQoderCommandWords() error = %v, wantErr %v", err, tt.wantErr)
			}
			if !equals(got, tt.want) {
				t.Errorf("splitQoderCommandWords() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestInjectQoderSessionID(t *testing.T) {
	tests := []struct {
		name      string
		command   string
		sessionID string
		expected  string
	}{
		{
			name:      "basic injection",
			command:   "qoder",
			sessionID: "test-123",
			expected:  "qoder --session-id test-123",
		},
		{
			name:      "existing flags preserved",
			command:   "qoder --workspace /path",
			sessionID: "abc-456",
			expected:  "qoder --session-id abc-456 --workspace /path",
		},
		{
			name:      "prompt positional preserved after flag",
			command:   "qoder fix the button",
			sessionID: "abc-456",
			expected:  "qoder --session-id abc-456 fix the button",
		},
		{
			name:      "skip if already has session id",
			command:   "qoder --session-id existing",
			sessionID: "new-id",
			expected:  "qoder --session-id existing",
		},
		{
			name:      "skip if resume",
			command:   "qoder --resume old",
			sessionID: "new-id",
			expected:  "qoder --resume old",
		},
		{
			name:      "non-qoder command unchanged",
			command:   "other-command",
			sessionID: "any-id",
			expected:  "other-command",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := InjectQoderSessionID(tt.command, tt.sessionID)
			if result != tt.expected {
				t.Errorf("InjectQoderSessionID() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestQoderCwdSlugAndTranscriptPath(t *testing.T) {
	t.Setenv("QODER_SESSION_DIR", "/tmp/qhome/projects")
	if got := qoderCwdSlug("/Users/me/my project"); got != "-Users-me-my project" {
		t.Fatalf("qoderCwdSlug = %q, want -Users-me-my project", got)
	}
	path := QoderTranscriptPath("/Users/me/my project", "sess-1")
	want := filepath.Join("/tmp/qhome/projects", "-Users-me-my project", "sess-1.jsonl")
	if path != want {
		t.Fatalf("QoderTranscriptPath = %q, want %q", path, want)
	}
}

func TestFindQoderTranscriptByInjectedSessionID(t *testing.T) {
	root := t.TempDir()
	t.Setenv("QODER_SESSION_DIR", root)
	// Qoder writes ~/.qoder/projects/<cwd-slug>/<session-id>.jsonl.
	slugDir := filepath.Join(root, "projects", "-Users-me-work")
	if err := os.MkdirAll(slugDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeQoderSessionFile(t, filepath.Join(slugDir, "warren-qoder-1.jsonl"), "warren-qoder-1", "/Users/me/work")

	// Exact cwd resolves without a directory walk.
	if got := FindQoderTranscript("warren-qoder-1", "/Users/me/work"); !strings.HasSuffix(got, "warren-qoder-1.jsonl") {
		t.Fatalf("FindQoderTranscript(cwd) = %q, want suffix warren-qoder-1.jsonl", got)
	}
	// Unknown cwd still finds the file by session id across project buckets.
	if got := FindQoderTranscript("warren-qoder-1", ""); !strings.HasSuffix(got, "warren-qoder-1.jsonl") {
		t.Fatalf("FindQoderTranscript(scan) = %q, want suffix warren-qoder-1.jsonl", got)
	}
	// Unknown session id is not adopted.
	if got := FindQoderTranscript("missing-id", ""); got != "" {
		t.Fatalf("FindQoderTranscript(missing-id) = %q, want empty", got)
	}
}

func TestFindQoderTranscriptHeaderGuard(t *testing.T) {
	root := t.TempDir()
	t.Setenv("QODER_SESSION_DIR", root)
	dir := filepath.Join(root, "projects", "-Users-me-work")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// A file whose records never mention the requested session id must not be
	// adopted even though its name matches the injected id.
	path := filepath.Join(dir, "warren-qoder-x.jsonl")
	content := `{"type":"user","uuid":"u1","timestamp":"2026-09-02T11:00:00.000Z","message":{"role":"user","content":"hi"},"cwd":"/Users/me/work","sessionId":"some-other-session"}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := FindQoderTranscript("warren-qoder-x", "/Users/me/work"); got != "" {
		t.Fatalf("FindQoderTranscript(header mismatch) = %q, want empty", got)
	}
}

func writeQoderSessionFile(t *testing.T, path, sessionID, cwd string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	lines := []string{
		`{"type":"workspace-directories","sessionId":"` + sessionID + `","directories":["` + cwd + `"]}`,
		`{"type":"user","uuid":"u1","timestamp":"2026-09-02T11:00:00.000Z","message":{"role":"user","content":"hi"},"cwd":"` + cwd + `","sessionId":"` + sessionID + `"}`,
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureQoderBindHookInstallsIntoSettings(t *testing.T) {
	configDir := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	// Pre-existing user settings with unrelated keys and a user hook entry.
	settings := `{
  "model": {"name": "efficient"},
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "echo user-hook"}]}]
  }
}`
	if err := os.WriteFile(filepath.Join(configDir, "settings.json"), []byte(settings), 0o600); err != nil {
		t.Fatal(err)
	}

	changed, err := EnsureQoderBindHook(configDir)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("first install should report changed")
	}
	data, err := os.ReadFile(filepath.Join(configDir, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if !strings.Contains(text, "warren-agent-bind-v1") {
		t.Fatalf("installed settings do not contain marker:\n%s", text)
	}
	// The user's model key and Stop hook survive the merge.
	if !strings.Contains(text, `"model"`) || !strings.Contains(text, "echo user-hook") {
		t.Fatalf("settings merge dropped user entries:\n%s", text)
	}
	// Warren hooks land on SessionStart/SessionEnd.
	for _, event := range []string{"SessionStart", "SessionEnd"} {
		if !strings.Contains(text, event) {
			t.Fatalf("settings missing %s hook:\n%s", event, text)
		}
	}

	// A standalone hooks.json is not where Qoder reads user hooks from; the
	// installer must not create one.
	if _, err := os.Stat(filepath.Join(configDir, "hooks.json")); err == nil {
		t.Fatal("installer must not create a standalone hooks.json")
	}

	changed, err = EnsureQoderBindHook(configDir)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("second install should report unchanged")
	}
}

func TestReadQoderTranscriptProjectsConversation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qoder-session.jsonl")
	writeReadLines(t, path,
		`{"type":"workspace-directories","sessionId":"qoder-1","directories":["/work"]}`,
		`{"type":"user","uuid":"u1","timestamp":"2026-09-02T10:00:01.000Z","message":{"role":"user","content":"hello"},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-09-02T10:00:02.000Z","message":{"id":"m1","type":"message","role":"assistant","model":"efficient","stop_reason":null,"content":[{"type":"thinking","thinking":"let me reason"}]},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"assistant","uuid":"a2","timestamp":"2026-09-02T10:00:03.000Z","message":{"id":"m2","type":"message","role":"assistant","model":"efficient","stop_reason":null,"content":[{"type":"text","text":"let me look"}]},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"assistant","uuid":"a3","timestamp":"2026-09-02T10:00:04.000Z","message":{"id":"m3","type":"message","role":"assistant","model":"efficient","stop_reason":"tool_use","content":[{"type":"tool_use","id":"call_1","name":"Read","input":{"file_path":"/work/a.go"}}]},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"user","uuid":"u2","timestamp":"2026-09-02T10:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"package a\n","is_error":false}]},"sourceToolAssistantUUID":"a3","cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"assistant","uuid":"a4","timestamp":"2026-09-02T10:00:06.000Z","message":{"id":"m4","type":"message","role":"assistant","model":"efficient","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]},"cwd":"/work","sessionId":"qoder-1"}`,
	)

	events, err := ReadTranscript(context.Background(), "qoder", path, ReadOptions{IncludeTypes: []string{"user", "assistant", "reasoning", "tool_call", "tool_output"}})
	if err != nil {
		t.Fatal(err)
	}
	got := eventTypes(events)
	if got != "user,reasoning,assistant,tool_call,tool_output,assistant" {
		t.Fatalf("event types = %q, want user,reasoning,assistant,tool_call,tool_output,assistant", got)
	}
	if events[0].Type != "user" || events[0].Content != "hello" {
		t.Errorf("user event = %#v", events[0])
	}
	if events[1].Type != "reasoning" || events[1].Content != "let me reason" {
		t.Errorf("reasoning event = %#v", events[1])
	}
	toolCall := events[3]
	if toolCall.ToolName != "read" || toolCall.CallID != "call_1" || toolCall.ToolStatus != "" {
		t.Errorf("tool_call event = %#v", toolCall)
	}
	if len(toolCall.Files) != 1 || toolCall.Files[0] != "/work/a.go" {
		t.Errorf("tool_call files = %v", toolCall.Files)
	}
	toolOutput := events[4]
	if toolOutput.ToolName != "read" || toolOutput.CallID != "call_1" || toolOutput.ToolStatus != "success" || strings.TrimSpace(toolOutput.Output) != "package a" {
		t.Errorf("tool_output event = %#v", toolOutput)
	}
	if events[5].Content != "done" || events[5].StopReason != "end_turn" {
		t.Errorf("final assistant event = %#v", events[5])
	}
}

func TestReadQoderTranscriptErrorToolResult(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qoder-session.jsonl")
	writeReadLines(t, path,
		`{"type":"user","uuid":"u0","timestamp":"2026-09-02T10:00:00.000Z","message":{"role":"user","content":"fix it"},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-09-02T10:00:01.000Z","message":{"id":"m1","type":"message","role":"assistant","model":"efficient","stop_reason":"tool_use","content":[{"type":"tool_use","id":"call_x","name":"Edit","input":{"file_path":"/work/a.go"}}]},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"user","uuid":"u1","timestamp":"2026-09-02T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_x","content":"Error: no match found","is_error":true}]},"sourceToolAssistantUUID":"a1","cwd":"/work","sessionId":"qoder-1"}`,
	)
	events, err := ReadTranscript(context.Background(), "qoder", path, ReadOptions{IncludeTypes: []string{"tool_call", "tool_output"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := eventTypes(events); got != "tool_call,tool_output" {
		t.Fatalf("event types = %q", got)
	}
	out := events[1]
	if out.ToolStatus != "error" || out.Error != "Error: no match found" || out.ToolName != "edit" {
		t.Errorf("failed tool_output = %#v", out)
	}
}

func TestReadQoderTranscriptAPIErrorRecord(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qoder-session.jsonl")
	writeReadLines(t, path,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-09-02T10:00:01.000Z","message":{"id":"m1","type":"message","role":"assistant","model":"<synthetic>","stop_reason":"stop_sequence","stop_sequence":"","content":[{"type":"text","text":"We hit a problem"}]},"isApiErrorMessage":true,"error":"authentication_failed","cwd":"/work","sessionId":"qoder-1"}`,
	)
	events, err := ReadTranscript(context.Background(), "qoder", path, ReadOptions{IncludeTypes: []string{"assistant", "error"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	if events[0].Type != "error" || !strings.Contains(events[0].Error, "problem") {
		t.Errorf("API error event = %#v", events[0])
	}
}

func TestReadQoderTranscriptSkipsMetadataAndSidechain(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qoder-session.jsonl")
	writeReadLines(t, path,
		`{"type":"workspace-directories","sessionId":"qoder-1","directories":["/work"]}`,
		`{"type":"ai-title","sessionId":"qoder-1","aiTitle":"Fix button"}`,
		`{"type":"attachment","uuid":"att1","timestamp":"2026-09-02T10:00:00.000Z","attachment":{"type":"skill_listing","content":"- simplify: ..."},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"user","uuid":"u1","timestamp":"2026-09-02T10:00:01.000Z","message":{"role":"user","content":"hello"},"cwd":"/work","sessionId":"qoder-1"}`,
	)
	events, err := ReadTranscript(context.Background(), "qoder", path, ReadOptions{IncludeTypes: []string{"user", "assistant", "reasoning", "tool_call", "tool_output", "error"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := eventTypes(events); got != "user" {
		t.Fatalf("event types = %q, want user only (metadata/attachment skipped)", got)
	}
}

func TestQoderStopReasonMapsTerminalValues(t *testing.T) {
	cases := map[string]string{
		"end_turn":      "end_turn",
		"stop":          "stop",
		"stop_sequence": "stop_sequence",
		"tool_use":      "",
		"":              "",
	}
	for in, want := range cases {
		if got := qoderStopReason(in); got != want {
			t.Errorf("qoderStopReason(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestWatchQoderTranscriptTracksActivity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "qoder-session.jsonl")
	writeReadLines(t, path,
		`{"type":"user","uuid":"u1","timestamp":"2026-09-02T10:00:01.000Z","message":{"role":"user","content":"hello"},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-09-02T10:00:02.000Z","message":{"id":"m1","type":"message","role":"assistant","model":"efficient","stop_reason":"tool_use","content":[{"type":"tool_use","id":"call_1","name":"Read","input":{"file_path":"/work/a.go"}}]},"cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"user","uuid":"u2","timestamp":"2026-09-02T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"ok","is_error":false}]},"sourceToolAssistantUUID":"a1","cwd":"/work","sessionId":"qoder-1"}`,
		`{"type":"assistant","uuid":"a2","timestamp":"2026-09-02T10:00:04.000Z","message":{"id":"m2","type":"message","role":"assistant","model":"efficient","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]},"cwd":"/work","sessionId":"qoder-1"}`,
	)
	watcher := Start("sess", "qoder", path, func([]api.AgentEvent, api.AgentStatus) {}, func(api.AgentStatus) {}, func([]api.AgentTurn, bool) {})
	defer watcher.Close()
	if err := watcher.WaitReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	// Give the watcher one poll after the initial replay so the tracker sees
	// the terminal end_turn recorded on the last line.
	deadline := time.Now().Add(2 * time.Second)
	for {
		status := watcher.parser.Status()
		if status.Activity == api.AgentActivityReady {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("status did not return to ready; last = %+v", status)
		}
		time.Sleep(50 * time.Millisecond)
	}
	events := watcher.Snapshot()
	if got := eventTypes(events); got != "user,tool_call,tool_output,assistant" {
		t.Fatalf("watcher event types = %q", got)
	}
}

func TestQoderHomeEnvOverrides(t *testing.T) {
	t.Setenv("QODER_HOME", "/custom/qoder")
	if got := QoderHome(); got != "/custom/qoder" {
		t.Fatalf("QoderHome = %q, want /custom/qoder", got)
	}
	t.Setenv("QODER_HOME", "")
	t.Setenv("QODER_CONFIG_DIR", "/custom/config")
	if got := QoderConfigDir(); got != "/custom/config" {
		t.Fatalf("QoderConfigDir = %q, want /custom/config", got)
	}
}

func equals(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestReadQoderFixtureFromTestdata(t *testing.T) {
	path := filepath.Join("testdata", "qoder-v1.jsonl")
	if _, err := os.Stat(path); err != nil {
		t.Skip("fixture missing")
	}
	events, err := ReadTranscript(context.Background(), "qoder", path, ReadOptions{IncludeTypes: []string{"user", "assistant", "reasoning", "tool_call", "tool_output", "error"}})
	if err != nil {
		t.Fatal(err)
	}
	// The synthetic fixture mirrors a real Qoder session: 1 user text turn,
	// 1 reasoning, 2 assistant texts, 3 tool_use, 3 tool_result (one error),
	// and an API error record projected as an error event.
	counts := map[string]int{}
	for _, e := range events {
		counts[e.Type]++
	}
	want := map[string]int{"user": 1, "reasoning": 1, "assistant": 2, "tool_call": 3, "tool_output": 3, "error": 1}
	for kind, n := range want {
		if counts[kind] != n {
			t.Errorf("count[%s] = %d, want %d (events=%d)", kind, counts[kind], n, len(events))
		}
	}
	// The API-error record must surface as an error, not an assistant text.
	last := events[len(events)-1]
	if last.Type != "error" {
		t.Fatalf("last event = %s, want error", last.Type)
	}
	// Tool outputs resolve their tool names through the assistant tool_use map.
	for _, e := range events {
		if e.Type == "tool_output" {
			if e.ToolName == "" {
				t.Errorf("tool_output %s has no tool name", e.CallID)
			}
			if e.ToolStatus == "error" && e.Error == "" {
				t.Errorf("failed tool_output %s has no error text", e.CallID)
			}
		}
	}
}

// TestReadQoderLocalRealTranscriptSelfCheck validates the parser against a
// real Qoder transcript when one is available on this machine. It is skipped
// on CI and is purely a local correctness check that the fixture shapes still
// match the provider's current JSONL.
func TestReadQoderLocalRealTranscriptSelfCheck(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	root := filepath.Join(home, ".qoder", "projects")
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		t.Skip("no real qoder transcripts on this machine")
	}
	var sample string
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || sample != "" {
			return nil
		}
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".jsonl") {
			return nil
		}
		sample = path
		return nil
	})
	if sample == "" {
		t.Skip("no real qoder transcript file found")
	}
	events, err := ReadTranscript(context.Background(), "qoder", sample, ReadOptions{IncludeTypes: []string{"user", "assistant", "reasoning", "tool_call", "tool_output", "error"}})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("parsed %d events from %s", len(events), sample)
	if len(events) == 0 {
		t.Fatalf("real transcript produced no events")
	}
	seen := map[string]bool{}
	for _, e := range events {
		seen[e.Type] = true
	}
	// A real multi-turn transcript must contain at least one conversation
	// anchor (user or assistant) plus tools when tools were used.
	if !seen["user"] && !seen["assistant"] {
		t.Fatalf("real transcript produced no conversation events: %v", seen)
	}
	// Replay through the live watcher so the activity tracker settles on a
	// terminal status for the sampled conversation.
	watcher := Start("sess", "qoder", sample, func([]api.AgentEvent, api.AgentStatus) {}, func(api.AgentStatus) {}, func([]api.AgentTurn, bool) {})
	defer watcher.Close()
	if err := watcher.WaitReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	t.Logf("final activity after real transcript replay: %s", watcher.parser.Status().Activity)
}
