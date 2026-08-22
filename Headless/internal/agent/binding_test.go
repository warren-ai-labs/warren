package agent

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestClaudeTranscriptPathSanitizesWorkspace(t *testing.T) {
	got := ClaudeTranscriptPath("/Users/me/.claude/projects", "/Users/me/Workspace/demo", "abc-123")
	want := "/Users/me/.claude/projects/-Users-me-Workspace-demo/abc-123.jsonl"
	if got != want {
		t.Fatalf("ClaudeTranscriptPath = %q, want %q", got, want)
	}
}

func TestInjectClaudeSessionID(t *testing.T) {
	const id = "11111111-2222-4333-8444-555555555555"
	cases := []struct {
		name    string
		command string
		want    string
	}{
		{"plain", "claude", "claude --session-id " + id},
		{"with flags", "claude --model sonnet", "claude --session-id " + id + " --model sonnet"},
		{"keeps resume", "claude -r old-id", "claude -r old-id"},
		{"keeps explicit session", "claude --session-id old-id", "claude --session-id old-id"},
		{"not claude", "codex --dangerously-bypass-hook-trust", "codex --dangerously-bypass-hook-trust"},
		{"empty", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := InjectClaudeSessionID(tc.command, id); got != tc.want {
				t.Fatalf("InjectClaudeSessionID(%q) = %q, want %q", tc.command, got, tc.want)
			}
		})
	}
}

func TestBindingRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bind.json")
	binding := Binding{
		Provider:       "codex",
		SessionID:      "thread-1",
		TranscriptPath: "/Users/me/.codex/sessions/rollout.jsonl",
		Cwd:            "/Users/me/Work",
	}
	if err := WriteBinding(path, binding); err != nil {
		t.Fatal(err)
	}
	got, err := ReadBinding(path)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.SessionID != "thread-1" || got.TranscriptPath != binding.TranscriptPath {
		t.Fatalf("ReadBinding = %#v", got)
	}
	if binding, err := ReadBinding(filepath.Join(t.TempDir(), "missing.json")); err != nil || binding != nil {
		t.Fatalf("missing binding = %#v, %v; want nil, nil", binding, err)
	}
	if err := WriteBinding(path, Binding{Provider: "codex"}); err == nil {
		t.Fatal("WriteBinding accepted an incomplete binding")
	}
}

func TestEnsureCodexBindHookMergesIdempotently(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	codexHome := t.TempDir()
	hooksPath := filepath.Join(codexHome, "hooks.json")
	if err := os.WriteFile(hooksPath, []byte(`{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "echo user-hook"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo stop-hook"}]}
    ]
  }
}`), 0o600); err != nil {
		t.Fatal(err)
	}
	changed, err := EnsureCodexBindHook(codexHome)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("first install must report changed")
	}
	var document map[string]any
	data, err := os.ReadFile(hooksPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	hooks := document["hooks"].(map[string]any)
	start := hooks["SessionStart"].([]any)
	if len(start) != 2 {
		t.Fatalf("SessionStart entries = %d, want 2 (user + warren)", len(start))
	}
	warren := start[1].(map[string]any)["hooks"].([]any)[0].(map[string]any)["command"].(string)
	if !strings.Contains(warren, hookCommandMarker) {
		t.Fatalf("warren hook command = %q", warren)
	}
	if !strings.Contains(warren, filepath.Join(configDir(), "hooks", "agent-bind.sh")) {
		t.Fatalf("warren hook command = %q, want script path", warren)
	}
	end := hooks["SessionEnd"].([]any)
	if len(end) != 1 {
		t.Fatalf("SessionEnd entries = %d, want 1 (warren)", len(end))
	}
	warrenEnd := end[0].(map[string]any)["hooks"].([]any)[0].(map[string]any)["command"].(string)
	if !strings.Contains(warrenEnd, hookCommandMarker) {
		t.Fatalf("SessionEnd hook command = %q", warrenEnd)
	}
	stop := hooks["Stop"].([]any)
	if len(stop) != 1 {
		t.Fatalf("Stop entries = %d, want 1 preserved", len(stop))
	}

	changed, err = EnsureCodexBindHook(codexHome)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("second install must be a no-op")
	}
	dataAfter, err := os.ReadFile(hooksPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(dataAfter) != string(data) {
		t.Fatal("second install rewrote the hooks file")
	}
}

func TestBindEnvironment(t *testing.T) {
	entries := BindEnvironment("warren-1", "codex")
	joined := strings.Join(entries, "\n")
	if !strings.Contains(joined, BindEnvSession+"=warren-1") ||
		!strings.Contains(joined, BindEnvKind+"=codex") ||
		!strings.Contains(joined, BindEnvFile+"="+BindPath("warren-1")) ||
		!strings.Contains(joined, BindEnvState+"="+StatePath("warren-1")) ||
		!strings.Contains(joined, BindEnvCodexSessionID+"=") ||
		!strings.Contains(joined, BindEnvCodexThreadID+"=") {
		t.Fatalf("BindEnvironment = %#v", entries)
	}

	shellEntries := BindEnvironment("warren-1", "shell")
	shellJoined := strings.Join(shellEntries, "\n")
	if !strings.Contains(shellJoined, BindEnvSession+"=warren-1") ||
		!strings.Contains(shellJoined, BindEnvFile+"="+BindPath("warren-1")) ||
		!strings.Contains(shellJoined, BindEnvState+"="+StatePath("warren-1")) ||
		!strings.Contains(shellJoined, BindEnvCodexSessionID+"=") ||
		!strings.Contains(shellJoined, BindEnvCodexThreadID+"=") {
		t.Fatalf("shell BindEnvironment = %#v", shellEntries)
	}
	if strings.Contains(shellJoined, BindEnvKind+"=") {
		t.Fatalf("shell BindEnvironment must not pin an agent kind: %#v", shellEntries)
	}
}

func TestCodexBindHookScriptWritesBinding(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	codexHome := t.TempDir()
	if _, err := EnsureCodexBindHook(codexHome); err != nil {
		t.Fatal(err)
	}
	scriptPath := filepath.Join(configDir(), "hooks", "agent-bind.sh")
	bindPath := filepath.Join(t.TempDir(), "bind.json")
	statePath := filepath.Join(t.TempDir(), "bind.state")
	command := exec.Command("bash", scriptPath)
	command.Stdin = strings.NewReader(`{"session_id":"thread-9","transcript_path":"/work/rollout-9.jsonl","cwd":"/work","hook_event_name":"SessionStart"}`)
	command.Env = append(os.Environ(),
		"WARREN_BIND_FILE="+bindPath,
		"WARREN_STATE_FILE="+statePath,
		"WARREN_AGENT_KIND=codex",
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("bind hook failed: %v: %s", err, output)
	}
	binding, err := ReadBinding(bindPath)
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.SessionID != "thread-9" || binding.TranscriptPath != "/work/rollout-9.jsonl" || binding.Provider != "codex" {
		t.Fatalf("hook binding = %#v", binding)
	}
	state, err := ReadAgentStatus(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if state.Activity != api.AgentActivityReady || state.Attention != nil {
		t.Fatalf("hook state = %#v, want ready", state)
	}
}

func TestHookScriptInfersProviderFromHookCommand(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	claudeDir := t.TempDir()
	if _, err := EnsureClaudeBindHook(claudeDir); err != nil {
		t.Fatal(err)
	}
	scriptPath := filepath.Join(configDir(), "hooks", "agent-bind.sh")
	bindPath := filepath.Join(t.TempDir(), "bind.json")
	statePath := filepath.Join(t.TempDir(), "bind.state")
	command := exec.Command("bash", scriptPath, hookCommandMarker, "claude")
	command.Stdin = strings.NewReader(`{"session_id":"thread-9","transcript_path":"/work/claude.jsonl","cwd":"/work","hook_event_name":"SessionStart"}`)
	command.Env = append(os.Environ(),
		"WARREN_BIND_FILE="+bindPath,
		"WARREN_STATE_FILE="+statePath,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("hook failed: %v: %s", err, output)
	}
	binding, err := ReadBinding(bindPath)
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.SessionID != "thread-9" || binding.Provider != "claude" {
		t.Fatalf("hook binding = %#v, want claude provider", binding)
	}
	state, err := ReadAgentStatus(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if state.Activity != api.AgentActivityReady || state.Attention != nil {
		t.Fatalf("hook state = %#v, want ready", state)
	}
}

func TestHookCommandPassesProviderThroughShell(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	claudeDir := t.TempDir()
	if _, err := EnsureClaudeBindHook(claudeDir); err != nil {
		t.Fatal(err)
	}
	settingsPath := filepath.Join(claudeDir, "settings.json")
	data, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	hooks := document["hooks"].(map[string]any)
	start := hooks["SessionStart"].([]any)
	command := ""
	for _, entry := range start {
		item, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		for _, hook := range item["hooks"].([]any) {
			config, ok := hook.(map[string]any)
			if !ok {
				continue
			}
			text, _ := config["command"].(string)
			if strings.Contains(text, hookCommandMarker) {
				command = text
			}
		}
	}
	if command == "" {
		t.Fatal("Warren SessionStart hook command not found in Claude settings")
	}

	bindPath := filepath.Join(t.TempDir(), "bind.json")
	statePath := filepath.Join(t.TempDir(), "bind.state")
	run := exec.Command("bash", "-c", command)
	run.Stdin = strings.NewReader(`{"session_id":"thread-9","transcript_path":"/work/claude.jsonl","cwd":"/work","hook_event_name":"SessionStart"}`)
	run.Env = append(os.Environ(),
		"WARREN_BIND_FILE="+bindPath,
		"WARREN_STATE_FILE="+statePath,
	)
	if output, err := run.CombinedOutput(); err != nil {
		t.Fatalf("hook via installed command failed: %v: %s", err, output)
	}
	binding, err := ReadBinding(bindPath)
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.Provider != "claude" {
		t.Fatalf("binding = %#v, want claude provider", binding)
	}
}

func TestAgentBindHookScriptMarksSessionEnd(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	codexHome := t.TempDir()
	if _, err := EnsureCodexBindHook(codexHome); err != nil {
		t.Fatal(err)
	}
	scriptPath := filepath.Join(configDir(), "hooks", "agent-bind.sh")
	statePath := filepath.Join(t.TempDir(), "bind.state")
	command := exec.Command("bash", scriptPath)
	command.Stdin = strings.NewReader(`{"session_id":"thread-9","hook_event_name":"SessionEnd"}`)
	command.Env = append(os.Environ(),
		"WARREN_STATE_FILE="+statePath,
		"WARREN_AGENT_KIND=codex",
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("end hook failed: %v: %s", err, output)
	}
	state, err := ReadAgentStatus(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if state.Activity != api.AgentActivityExited || state.Attention != nil {
		t.Fatalf("hook state = %#v, want exited", state)
	}
}

func TestAgentBindHookScriptMarksSessionEndWithoutSessionID(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	codexHome := t.TempDir()
	if _, err := EnsureCodexBindHook(codexHome); err != nil {
		t.Fatal(err)
	}
	scriptPath := filepath.Join(configDir(), "hooks", "agent-bind.sh")
	statePath := filepath.Join(t.TempDir(), "bind.state")
	command := exec.Command("bash", scriptPath)
	command.Stdin = strings.NewReader(`{"hook_event_name":"SessionEnd"}`)
	command.Env = append(os.Environ(),
		"WARREN_STATE_FILE="+statePath,
		"WARREN_AGENT_KIND=codex",
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("end hook without session id failed: %v: %s", err, output)
	}
	state, err := ReadAgentStatus(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if state.Activity != api.AgentActivityExited || state.Attention != nil {
		t.Fatalf("hook state = %#v, want exited", state)
	}
}

func TestEnsureClaudeBindHookMergesIdempotently(t *testing.T) {
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	claudeDir := t.TempDir()
	settingsPath := filepath.Join(claudeDir, "settings.json")
	if err := os.WriteFile(settingsPath, []byte(`{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "echo user-hook"}]}
    ]
  }
}`), 0o600); err != nil {
		t.Fatal(err)
	}
	changed, err := EnsureClaudeBindHook(claudeDir)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("first install must report changed")
	}
	data, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	hooks := document["hooks"].(map[string]any)
	start := hooks["SessionStart"].([]any)
	if len(start) != 2 {
		t.Fatalf("SessionStart entries = %d, want 2 (user + warren)", len(start))
	}
	end := hooks["SessionEnd"].([]any)
	if len(end) != 1 {
		t.Fatalf("SessionEnd entries = %d, want 1", len(end))
	}
	changed, err = EnsureClaudeBindHook(claudeDir)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("second install must be a no-op")
	}
}
