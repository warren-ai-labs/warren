package agent

// Qoder integration. Qoder stores conversations in a JSONL format under
// ~/.qoder (honoring QODER_HOME). Warren launches qoder without injecting a
// session id: the Warren-managed extension reports the conversation on session
// creation, and the daemon tails the resolved JSONL with the ordinary watcher.
// There is no SQLite store; the provider's own JSONL is already the normalized
// append-only transcript.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const qoderProvider = "qoder"

// qoderSessionReuseFlags are Qoder options that reuse an existing conversation.
// Warren binds the session qoder creates on session_start, so a user command
// that resumes or selects an existing session would detach the Agent tab from
// that conversation.
var qoderSessionReuseFlags = map[string]bool{
	"--continue":   true,
	"-c":           true,
	"--resume":     true,
	"-r":           true,
	"--session":    true,
	"--session-id": true,
	"--fork":       true,
	"--no-session": true,
}

// ValidateQoderCommand keeps every session.create caller from selecting a Qoder
// conversation that Warren did not create. The CLI performs the same
// validation for agent create, but Desktop and Web launch presets call
// session.create directly and must receive the invariant at the Host boundary.
func ValidateQoderCommand(command string) error {
	if err := validateQoderShellSyntax(command); err != nil {
		return err
	}
	tokens, err := splitQoderCommandWords(command)
	if err != nil {
		return fmt.Errorf("invalid Qoder command: %w", err)
	}
	if len(tokens) == 0 {
		return errors.New("Qoder command must not be empty")
	}
	for index := 1; index < len(tokens); index++ {
		flag := tokens[index]
		if equal := strings.IndexByte(flag, '='); equal >= 0 {
			flag = flag[:equal]
		}
		if qoderSessionReuseFlags[flag] {
			return errors.New("Qoder command must start a new session; session resume or fork flags are not supported")
		}
	}
	return nil
}

// validateQoderShellSyntax rejects shell operators and substitutions so a Qoder
// command stays a plain executable with options that the terminal runtime can
// evaluate safely.
func validateQoderShellSyntax(command string) error {
	inSingle, inDouble, escaped := false, false, false
	for _, char := range command {
		if escaped {
			escaped = false
			continue
		}
		if inSingle {
			if char == '\'' {
				inSingle = false
			}
			continue
		}
		if inDouble {
			switch char {
			case '\\':
				escaped = true
			case '"':
				inDouble = false
			case '`', '$':
				return errors.New("Qoder command must not contain shell operators or substitutions")
			}
			continue
		}
		switch char {
		case '\\':
			escaped = true
		case '\'':
			inSingle = true
		case '"':
			inDouble = true
		case ';', '&', '|', '>', '<', '`', '(', ')', '\n', '$':
			return errors.New("Qoder command must be an executable with options; shell operators and substitutions are not supported")
		}
	}
	if escaped {
		return errors.New("Qoder command has a trailing escape")
	}
	if inSingle || inDouble {
		return errors.New("Qoder command has an unterminated quote")
	}
	return nil
}

// splitQoderCommandWords splits a Qoder command into shell words without evaluating
// expansions. It mirrors the OpenCode/Pi word splitting so validation and
// the terminal runtime agree on what is a flag and what is a value.
func splitQoderCommandWords(command string) ([]string, error) {
	var words []string
	var current strings.Builder
	inSingle, inDouble, escaped, started := false, false, false, false
	flush := func() {
		if started {
			words = append(words, current.String())
			current.Reset()
			started = false
		}
	}
	for _, char := range command {
		switch {
		case escaped:
			current.WriteRune(char)
			escaped = false
			started = true
		case inSingle:
			if char == '\'' {
				inSingle = false
			} else {
				current.WriteRune(char)
			}
			started = true
		case inDouble:
			switch char {
			case '"':
				inDouble = false
			case '\\':
				escaped = true
			default:
				current.WriteRune(char)
			}
			started = true
		default:
			switch {
			case char == '\\':
				escaped = true
				started = true
			case char == '\'':
				inSingle = true
				started = true
			case char == '"':
				inDouble = true
				started = true
			case char == ' ' || char == '\t' || char == '\r' || char == '\n':
				flush()
			default:
				current.WriteRune(char)
				started = true
			}
		}
	}
	if escaped {
		return nil, errors.New("trailing escape")
	}
	if inSingle || inDouble {
		return nil, errors.New("unterminated quote")
	}
	flush()
	return words, nil
}

// QoderHome returns the Qoder configuration directory, honoring QODER_HOME just
// like the CLI itself.
func QoderHome() string {
	if value := os.Getenv("QODER_HOME"); value != "" {
		return filepath.Clean(value)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".qoder"
	}
	return filepath.Join(home, ".qoder")
}

// QoderConfigDir returns the directory Qoder reads settings from, honoring
// QODER_CONFIG_DIR just like the CLI itself.
func QoderConfigDir() string {
	if value := os.Getenv("QODER_CONFIG_DIR"); value != "" {
		return filepath.Clean(value)
	}
	return QoderHome()
}

// QoderSessionsRoot returns the directory Qoder stores session files in,
// honoring QODER_SESSION_DIR if set.
func QoderSessionsRoot() string {
	if value := os.Getenv("QODER_SESSION_DIR"); value != "" {
		return filepath.Clean(value)
	}
	return filepath.Join(QoderHome(), "sessions")
}

// QoderSessionFileName returns the deterministic suffix Qoder's session files end
// with: Qoder writes <timestamp>_<session-id>.jsonl.
func QoderSessionFileName(sessionID string) string {
	return "_" + sessionID + ".jsonl"
}

// FindQoderTranscript locates the JSONL transcript for a Warren session by its
// injected Qoder session id. The scan is scoped to the exact filename suffix so
// a stale or manually-created Qoder session can never be adopted. The header is
// verified as a second guard so a future Qoder layout change degrades to a
// retry instead of tailing the wrong conversation.
func FindQoderTranscript(sessionID string) string {
	root := QoderSessionsRoot()
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() {
		return ""
	}
	suffix := QoderSessionFileName(sessionID)
	var newest string
	var newestMod time.Time
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if !strings.HasSuffix(entry.Name(), suffix) {
			return nil
		}
		fileInfo, err := entry.Info()
		if err != nil || !fileInfo.Mode().IsRegular() {
			return nil
		}
		if !qoderTranscriptHeaderMatches(path, sessionID) {
			return nil
		}
		if newest == "" || fileInfo.ModTime().After(newestMod) {
			newest = path
			newestMod = fileInfo.ModTime()
		}
		return nil
	})
	return newest
}

// qoderTranscriptHeaderMatches checks the session header line id field. A
// missing or malformed header is treated as no match so the finder never
// binds Warren to a file that Qoder cannot be reading itself.
func qoderTranscriptHeaderMatches(path, sessionID string) bool {
	file, err := openRegularFile(path)
	if err != nil {
		return false
	}
	defer file.Close()
	line, err := readBoundedLine(bufio.NewReader(file), 1024*1024)
	if err != nil && len(line) == 0 {
		return false
	}
	var header struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(bytes.TrimSpace(line), &header) != nil || header.ID == "" {
		return false
	}
	return header.ID == sessionID
}

// InjectQoderSessionID makes Qoder's transcript path deterministic for a
// Warren session. Existing resume/session flags are left untouched so a user
// who explicitly resumes an older conversation keeps their intent.
func InjectQoderSessionID(command, warrenSessionID string) string {
	fields := strings.Fields(command)
	if len(fields) == 0 || !strings.HasPrefix(fields[0], "qoder") {
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

// EnsureQoderBindHook installs the Warren binding hook into Qoder's hooks
// configuration. On session.start the hook writes the binding file so the daemon
// can resolve the Warren session ID and transcript location without guessing.
func EnsureQoderBindHook(qoderConfigDir string) (changed bool, err error) {
	return ensureQoderHooks(filepath.Join(qoderConfigDir, "hooks.json"), "qoder")
}

// ensureQoderHooks merges the Warren-managed hook command into Qoder's hooks
// configuration. The marker in the command makes repeated installs idempotent.
func ensureQoderHooks(hooksPath, provider string) (changed bool, err error) {
	scriptPath := filepath.Join(configDir(), "hooks", "qoder-bind.sh")
	if err := os.MkdirAll(filepath.Dir(scriptPath), 0o700); err != nil {
		return false, fmt.Errorf("create hooks directory: %w", err)
	}
	if err := os.WriteFile(scriptPath, []byte(qoderBindHookScript), 0o700); err != nil {
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
	events := []string{"SessionStart", "SessionEnd"}
	for _, event := range events {
		if ensureHookEvent(hooks, event, command) {
			changed = true
		}
	}
	if !changed {
		return false, nil
	}
	return true, writeHooksJSON(hooksPath, document)
}

// Record one JSONL line emitted by Qoder.
type qoderRecord struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	ParentID  string          `json:"parentId,omitempty"`
	Timestamp string          `json:"timestamp"`
	Message   json.RawMessage `json:"message,omitempty"`
	Content   json.RawMessage `json:"content,omitempty"`
	CustomType string         `json:"customType,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
}

type qoderMessage struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content,omitempty"`
	Provider   string          `json:"provider,omitempty"`
	Model      string          `json:"model,omitempty"`
	StopReason string          `json:"stopReason,omitempty"`
	ErrorMessage string        `json:"errorMessage,omitempty"`
	ToolCallID string          `json:"toolCallId,omitempty"`
	ToolName   string          `json:"toolName,omitempty"`
	IsError    bool            `json:"isError,omitempty"`
	Command    string          `json:"command,omitempty"`
	Output     string          `json:"output,omitempty"`
	ExitCode   int             `json:"exitCode,omitempty"`
}

// parseQoder projects one Qoder record onto the normalized agent event stream
// understood by the transcription tracker.
func (p *parser) parseQoder(line []byte) []api.AgentEvent {
	var record qoderRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	timestamp := parseTimestamp(record.Timestamp)
	provider := qoderProvider

	switch record.Type {
	case "session", "model_change", "thinking_level_change":
		return nil
	}

	var message qoderMessage
	if json.Unmarshal(record.Content, &message) != nil {
		return nil
	}

	switch message.Role {
	case "user":
		content := p.content(message.Content)
		if content == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  provider,
			ID:        record.ID,
			Type:      "user",
			Content:   p.clip(content),
			Timestamp: timestamp,
		}}
	case "assistant":
		return p.parseQoderAssistant(record, message, timestamp)
	case "toolResult":
		return p.parseQoderToolResult(record, message, timestamp)
	default:
		return nil
	}
}

func (p *parser) parseQoderAssistant(record qoderRecord, message qoderMessage, timestamp time.Time) []api.AgentEvent {
	content := p.content(message.Content)
	if content == "" {
		return nil
	}
	events := []api.AgentEvent{{
		Provider:   qoderProvider,
		ID:         record.ID,
		Type:       "assistant",
		Content:    content,
		StopReason: qoderStopReason(message.StopReason),
		Timestamp:  timestamp,
	}}
	if message.StopReason == "error" && message.ErrorMessage != "" {
		events = append(events, api.AgentEvent{
			Provider:  qoderProvider,
			ID:        record.ID,
			Type:      "error",
			Content:   p.clip(message.ErrorMessage),
			Error:     p.clip(message.ErrorMessage),
			Timestamp: timestamp,
		})
	}
	return events
}

func (p *parser) parseQoderToolResult(record qoderRecord, message qoderMessage, timestamp time.Time) []api.AgentEvent {
	output := strings.TrimSpace(message.Output)
	if output == "" {
		return nil
	}
	status := "success"
	if message.IsError || message.ExitCode != 0 {
		status = "error"
	}
	event := api.AgentEvent{
		Provider:   qoderProvider,
		ID:         record.ID,
		Type:       "tool_output",
		CallID:     message.ToolCallID,
		ToolName:   message.ToolName,
		ToolStatus: status,
		Output:     output,
		Timestamp:  timestamp,
	}
	if status == "error" {
		event.Error = output
	}
	return []api.AgentEvent{event}
}

func qoderStopReason(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "stop", "length", "max_tokens", "error", "content_filter":
		return strings.ToLower(strings.TrimSpace(value))
	default:
		return ""
	}
}

// qoderBindHookScript reads the hook event JSON from stdin. SessionStart writes
// the transcript binding; SessionEnd marks the surrounding shell exited.
const qoderBindHookScript = `#!/bin/sh
# warren-agent-bind-v1
[ -n "$WARREN_BIND_FILE" ] || [ -n "$WARREN_STATE_FILE" ] || exit 0
input=$(cat)
hook_event=$(printf '%s' "$input" | sed -nE 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
session_id=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
transcript_path=$(printf '%s' "$input" | sed -nE 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
cwd=$(printf '%s' "$input" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
[ -n "$session_id" ] || exit 0

write_status() {
  [ -n "$WARREN_STATE_FILE" ] || return 0
  activity=$1
  dir=$(dirname "$WARREN_STATE_FILE")
  mkdir -p "$dir" 2>/dev/null || return 0
  temporary="$WARREN_STATE_FILE.tmp.$$"
  if [ -n "$session_id" ]; then
    printf '{"sessionId":"%s","status":{"activity":"%s","attention":null}}\n' \
      "$session_id" "$activity" > "$temporary" 2>/dev/null || return 0
  else
    printf '{"status":{"activity":"%s","attention":null}}\n' "$activity" > "$temporary" 2>/dev/null || return 0
  fi
  mv -f "$temporary" "$WARREN_STATE_FILE" 2>/dev/null || return 0
}

if [ "$hook_event" = "SessionEnd" ]; then
  write_status "exited"
  printf '%s\n' '{"continue":true}'
  exit 0
fi

case "$hook_event" in
  SessionStart)
    write_status "ready"
    ;;
  *)
    write_status "working"
    ;;
esac

[ -n "$WARREN_BIND_FILE" ] || exit 0
[ -n "$transcript_path" ] || exit 0
dir=$(dirname "$WARREN_BIND_FILE")
mkdir -p "$dir" 2>/dev/null || exit 0
temporary="$WARREN_BIND_FILE.tmp.$$"
provider=${2:-${WARREN_AGENT_KIND:-qoder}}
{
  printf '{"provider":"%s","sessionId":"%s","transcriptPath":"%s","cwd":"%s","updatedAt":"%s"}\n' \
    "$provider" "$session_id" "$transcript_path" "$cwd" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$temporary" 2>/dev/null || exit 0
mv -f "$temporary" "$WARREN_BIND_FILE" 2>/dev/null || exit 0
exit 0
`
