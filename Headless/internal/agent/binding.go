package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Binding records which Codex/Claude conversation belongs to one Warren
// session. It is written by the Warren-managed SessionStart hook (Codex) or
// derived from the deterministic `--session-id` flag (Claude), and read by
// the daemon so transcript discovery is keyed by the CLI's own session ID
// instead of guessing by cwd and mtime.
type Binding struct {
	Provider       string    `json:"provider"`
	SessionID      string    `json:"sessionId"`
	TranscriptPath string    `json:"transcriptPath"`
	Cwd            string    `json:"cwd,omitempty"`
	UpdatedAt      time.Time `json:"updatedAt"`
}

const (
	// BindEnvSession marks the Warren session owning the CLI process. Hooks
	// and tool subprocesses see it, but only the managed hook uses it.
	BindEnvSession = "WARREN_SESSION_ID"
	// BindEnvFile points the managed hook at the file it must write with the
	// CLI session ID and transcript path.
	BindEnvFile = "WARREN_BIND_FILE"
	// BindEnvKind names the agent kind (codex or claude) for the hook.
	BindEnvKind = "WARREN_AGENT_KIND"
	// BindEnvState points the managed hook at the file it must update when
	// the CLI session ends, so the daemon can switch the status light from
	// agent activity back to the surrounding shell.
	BindEnvState = "WARREN_STATE_FILE"
	// CodexSessionID and CodexThreadID are launcher-provided identity hints.
	// An interactive shell can inherit them from its parent Codex process; an
	// independently-created Warren session must not reuse that conversation.
	BindEnvCodexSessionID = "CODEX_SESSION_ID"
	BindEnvCodexThreadID  = "CODEX_THREAD_ID"
	// hookCommandMarker identifies the Warren-managed hook entry so repeated
	// daemon starts can merge idempotently. It is also the first argument to
	// the hook script; the provider follows it as a real shell argument (the
	// old form used a `#` comment, which swallowed the provider for manual
	// shell overlays).
	hookCommandMarker = "warren-agent-bind-v1"
)

// BindEnvironment returns the runtime environment entries a session needs so
// the managed hook can report an agent CLI's own session ID to Warren.
func BindEnvironment(warrenSessionID, kind string) []string {
	entries := []string{
		BindEnvSession + "=" + warrenSessionID,
		BindEnvFile + "=" + BindPath(warrenSessionID),
		BindEnvState + "=" + StatePath(warrenSessionID),
		// Empty overrides intentionally shadow inherited values. Ghostline
		// merges these entries into the child environment, and Codex treats an
		// empty identity as unset, so each Warren session starts a new thread.
		BindEnvCodexSessionID + "=",
		BindEnvCodexThreadID + "=",
	}
	// Dedicated agent sessions know their provider up front. Plain shell and
	// custom sessions must not pin a provider: whichever agent CLI the user
	// starts inside them is reported by the hook command itself.
	if kind == "codex" || kind == "claude" {
		entries = append(entries, BindEnvKind+"="+kind)
	}
	return entries
}

// BindPath is the per-session file the managed hook writes.
func BindPath(warrenSessionID string) string {
	return filepath.Join(BindDir(), warrenSessionID+".json")
}

// StatePath is the per-session file the managed hook uses to report that the
// agent CLI has exited and the shell is back.
func StatePath(warrenSessionID string) string {
	return filepath.Join(BindDir(), warrenSessionID+".state")
}

// BindDir is the directory holding per-session bindings.
func BindDir() string {
	return filepath.Join(configDir(), "agent-bind")
}

// configDir is the Warren data directory. Kept behind a function so tests can
// redirect it without touching the user's real home directory.
func configDir() string {
	if value := os.Getenv("WARREN_DATA_DIR"); value != "" {
		return value
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren")
}

// WriteBinding persists the binding reported by a hook. It is safe for the
// hook and the daemon to race: both write the same structured JSON and the
// daemon only starts a watcher for a path that exists on disk.
func WriteBinding(path string, binding Binding) error {
	if binding.Provider == "" || binding.SessionID == "" || binding.TranscriptPath == "" {
		return errors.New("binding needs provider, session id and transcript path")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create binding directory: %w", err)
	}
	data, err := json.Marshal(binding)
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	return nil
}

// ReadBinding returns nil when the file does not exist or is malformed; a
// malformed file is transient while a hook is mid-write, so callers retry.
func ReadBinding(path string) (*Binding, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var binding Binding
	if err := json.Unmarshal(data, &binding); err != nil {
		return nil, nil
	}
	if binding.SessionID == "" || binding.TranscriptPath == "" {
		return nil, nil
	}
	return &binding, nil
}

// RemoveBinding cleans up the per-session file when the session is deleted.
func RemoveBinding(warrenSessionID string) {
	_ = os.Remove(BindPath(warrenSessionID))
	_ = os.Remove(StatePath(warrenSessionID))
}

// ReadAgentState returns the state recorded by the managed hook, or "" when
// the file is missing or malformed.
func ReadAgentState(path string) (api.AgentActivity, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	var state struct {
		State api.AgentActivity `json:"state"`
	}
	if err := json.Unmarshal(data, &state); err != nil {
		return "", nil
	}
	return state.State, nil
}

// WriteAgentState persists a state reported by a hook. The write is atomic so
// the daemon never reads a half-written file.
func WriteAgentState(path string, state api.AgentActivity) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	data, err := json.Marshal(struct {
		State api.AgentActivity `json:"state"`
	}{State: state})
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

// InjectClaudeSessionID makes Claude's transcript path deterministic for a
// Warren session. Existing resume/session flags are left untouched so a user
// who explicitly resumes an older conversation keeps their intent.
func InjectClaudeSessionID(command, warrenSessionID string) string {
	fields := strings.Fields(command)
	if len(fields) == 0 || !strings.HasPrefix(fields[0], "claude") {
		return command
	}
	for _, field := range fields[1:] {
		if field == "--session-id" || field == "--resume" || field == "-r" ||
			strings.HasPrefix(field, "--session-id=") || strings.HasPrefix(field, "--resume=") {
			return command
		}
	}
	rest := strings.TrimSpace(strings.TrimPrefix(command, fields[0]))
	result := fields[0] + " --session-id " + warrenSessionID
	if rest != "" {
		result += " " + rest
	}
	return result
}

// ClaudeTranscriptPath computes the transcript file Claude writes for a
// given session ID in a given working directory.
func ClaudeTranscriptPath(claudeRoot, workspacePath, sessionID string) string {
	absolute, err := filepath.Abs(workspacePath)
	if err != nil {
		absolute = workspacePath
	}
	// Claude names the project folder by replacing every path separator in
	// the absolute cwd with "-", including the leading one.
	project := strings.ReplaceAll(filepath.Clean(absolute), string(filepath.Separator), "-")
	return filepath.Join(claudeRoot, project, sessionID+".jsonl")
}

// CodexHome returns the Codex configuration directory the daemon's children
// inherit, honoring CODEX_HOME just like the CLI itself.
func CodexHome() string {
	return filepath.Dir(defaultCodexSessionsRoot())
}

// ClaudeProjectsRoot returns the directory Claude writes transcripts into,
// honoring CLAUDE_CONFIG_DIR just like the CLI itself.
func ClaudeProjectsRoot() string {
	return defaultClaudeProjectsRoot()
}

// ClaudeConfigDir returns the directory Claude reads settings from, honoring
// CLAUDE_CONFIG_DIR just like the CLI itself.
func ClaudeConfigDir() string {
	return filepath.Dir(defaultClaudeProjectsRoot())
}

// EnsureCodexBindHook installs the Warren SessionStart and SessionEnd hooks
// into Codex's user hooks file, preserving every existing entry.
func EnsureCodexBindHook(codexHome string) (changed bool, err error) {
	return ensureAgentHooks(filepath.Join(codexHome, "hooks.json"), "codex")
}

// EnsureClaudeBindHook installs the same two hooks into Claude's user
// settings file, preserving every existing entry.
func EnsureClaudeBindHook(claudeConfigDir string) (changed bool, err error) {
	return ensureAgentHooks(filepath.Join(claudeConfigDir, "settings.json"), "claude")
}

// ensureAgentHooks merges the Warren-managed hook command into the
// SessionStart and SessionEnd arrays of either Codex hooks.json or Claude
// settings.json. The marker in the command makes repeated installs
// idempotent; user entries are never touched.
func ensureAgentHooks(hooksPath, provider string) (changed bool, err error) {
	scriptPath := filepath.Join(configDir(), "hooks", "agent-bind.sh")
	if err := os.MkdirAll(filepath.Dir(scriptPath), 0o700); err != nil {
		return false, fmt.Errorf("create hooks directory: %w", err)
	}
	if err := os.WriteFile(scriptPath, []byte(agentBindHookScript), 0o700); err != nil {
		return false, fmt.Errorf("write bind hook script: %w", err)
	}

	document := map[string]any{}
	if data, err := os.ReadFile(hooksPath); err == nil {
		if err := json.Unmarshal(data, &document); err != nil {
			return false, fmt.Errorf("parse existing hooks file %s: %w", hooksPath, err)
		}
	}
	hooks, _ := document["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
		document["hooks"] = hooks
	}
	command := "bash '" + scriptPath + "' " + hookCommandMarker + " " + provider
	for _, event := range []string{"SessionStart", "SessionEnd"} {
		if ensureHookEvent(hooks, event, command) {
			changed = true
		}
	}
	if !changed {
		return false, nil
	}
	return true, writeHooksJSON(hooksPath, document)
}

func ensureHookEvent(hooks map[string]any, event, command string) bool {
	entries, _ := hooks[event].([]any)
	for _, entry := range entries {
		item, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		inner, _ := item["hooks"].([]any)
		for _, hook := range inner {
			config, ok := hook.(map[string]any)
			if !ok {
				continue
			}
			if text, _ := config["command"].(string); strings.Contains(text, hookCommandMarker) {
				if text == command {
					return false
				}
				config["command"] = command
				return true
			}
		}
	}
	hooks[event] = append(entries, map[string]any{
		"hooks": []any{
			map[string]any{"type": "command", "command": command},
		},
	})
	return true
}

func writeHooksJSON(path string, document map[string]any) error {
	data, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

// agentBindHookScript reads the hook event JSON from stdin. SessionStart
// writes the transcript binding and resets the state file; SessionEnd marks
// the state file exited so the daemon can switch the status light back to
// the surrounding shell. The marker string appears in the command so the
// daemon can find and update its own entry idempotently.
const agentBindHookScript = `#!/bin/sh
# warren-agent-bind-v1
[ -n "$WARREN_BIND_FILE" ] || [ -n "$WARREN_STATE_FILE" ] || exit 0
input=$(cat)
hook_event=$(printf '%s' "$input" | sed -nE 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
if [ "$hook_event" = "SessionEnd" ]; then
  [ -n "$WARREN_STATE_FILE" ] || exit 0
  dir=$(dirname "$WARREN_STATE_FILE")
  mkdir -p "$dir" 2>/dev/null || exit 0
  temporary="$WARREN_STATE_FILE.tmp.$$"
  printf '%s\n' '{"state":"exited"}' > "$temporary" 2>/dev/null || exit 0
  mv -f "$temporary" "$WARREN_STATE_FILE" 2>/dev/null || exit 0
  printf '%s\n' '{"continue":true}'
  exit 0
fi
session_id=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
transcript_path=$(printf '%s' "$input" | sed -nE 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
cwd=$(printf '%s' "$input" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
[ -n "$session_id" ] || session_id=$(printf '%s' "$input" | sed -nE 's/.*"thread_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
[ -n "$session_id" ] || exit 0
provider=${2:-${WARREN_AGENT_KIND:-codex}}
[ -n "$WARREN_BIND_FILE" ] || exit 0
[ -n "$transcript_path" ] || exit 0
dir=$(dirname "$WARREN_BIND_FILE")
mkdir -p "$dir" 2>/dev/null || exit 0
temporary="$WARREN_BIND_FILE.tmp.$$"
{
  printf '{"provider":"%s","sessionId":"%s","transcriptPath":"%s","cwd":"%s","updatedAt":"%s"}\n' \
    "$provider" "$session_id" "$transcript_path" "$cwd" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$temporary" 2>/dev/null || exit 0
mv -f "$temporary" "$WARREN_BIND_FILE" 2>/dev/null || exit 0
if [ -n "$WARREN_STATE_FILE" ]; then
  state_dir=$(dirname "$WARREN_STATE_FILE")
  mkdir -p "$state_dir" 2>/dev/null || exit 0
  state_tmp="$WARREN_STATE_FILE.tmp.$$"
  printf '%s\n' '{"state":"ready"}' > "$state_tmp" 2>/dev/null || exit 0
  mv -f "$state_tmp" "$WARREN_STATE_FILE" 2>/dev/null || exit 0
fi
printf '%s\n' '{"continue":true}'
exit 0
`
