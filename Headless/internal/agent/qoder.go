package agent

// Qoder integration. Qoder stores each conversation as a plain JSONL file
// under <config>/projects/<cwd-slug>/<session-id>.jsonl (config honoring
// QODER_HOME and QODER_CONFIG_DIR just like the CLI itself). Warren launches
// qoder with an injected --session-id and the Warren-managed hook reports the
// transcript path on SessionStart, so the daemon tails the resolved JSONL with
// the ordinary watcher. There is no SQLite store and no private cache: the
// provider's own JSONL is already the normalized append-only transcript.

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

// qoderSessionReuseFlags are Qoder options that reuse an existing conversation
// or otherwise detach the transcript Warren tails. Warren binds the session
// qoder creates on session_start, so a user command that resumes, forks, or
// selects an existing session would detach the Agent tab from that
// conversation; --no-session-persistence leaves no transcript to tail.
var qoderSessionReuseFlags = map[string]bool{
	"--continue":               true,
	"-c":                       true,
	"--resume":                 true,
	"-r":                       true,
	"--session":                true,
	"--session-id":             true,
	"--fork":                   true,
	"--fork-session":           true,
	"--no-session":             true,
	"--no-session-persistence": true,
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

// QoderProjectsRoot returns the directory Qoder stores project transcripts
// under: <root>/projects/<cwd-slug>/<session-id>.jsonl. The projects root is
// always the real-home ~/.qoder/projects: Qoder keeps the settings file under
// the config dir (honoring QODER_HOME/QODER_CONFIG_DIR) but writes session
// transcripts under the user's actual .qoder directory regardless of those
// overrides. QODER_SESSION_DIR is honored only as a test/override seam and is
// not read by the CLI itself.
func QoderProjectsRoot() string {
	if value := os.Getenv("QODER_SESSION_DIR"); value != "" {
		return filepath.Clean(value)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.Join(".qoder", "projects")
	}
	return filepath.Join(home, ".qoder", "projects")
}

// qoderCwdSlug mirrors Qoder's project bucket naming: the absolute working
// directory with every path separator replaced by a dash (including the
// leading one), e.g. /Users/me/proj -> -Users-me-proj.
func qoderCwdSlug(cwd string) string {
	absolute, err := filepath.Abs(cwd)
	if err != nil {
		absolute = cwd
	}
	return strings.ReplaceAll(filepath.Clean(absolute), string(filepath.Separator), "-")
}

// QoderTranscriptPath returns the deterministic transcript path Qoder writes
// for a session id started in cwd. The session-id flag is the primary anchor,
// so the path is only valid when the caller injected it at launch.
func QoderTranscriptPath(cwd, sessionID string) string {
	return filepath.Join(QoderProjectsRoot(), qoderCwdSlug(cwd), sessionID+".jsonl")
}

// FindQoderTranscript locates the JSONL transcript for a Warren session by its
// injected Qoder session id. When the working directory is known the exact
// bucket is checked first (Qoder writes there deterministically); when it is
// empty, or the file is not there yet, a scan over every project bucket finds
// <session-id>.jsonl regardless of where the CLI actually started. The
// filename alone is scoped to the injected id, and the transcript is verified
// to mention that session id so a stale or manually-created file is never
// adopted.
func FindQoderTranscript(sessionID, cwd string) string {
	root := QoderProjectsRoot()
	if strings.TrimSpace(sessionID) == "" {
		return ""
	}
	if cwd != "" {
		if path := QoderTranscriptPath(cwd, sessionID); qoderTranscriptMatches(path, sessionID) {
			return path
		}
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() {
		return ""
	}
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
		if entry.Name() != sessionID+".jsonl" {
			return nil
		}
		if !qoderTranscriptMatches(path, sessionID) {
			return nil
		}
		fileInfo, err := entry.Info()
		if err != nil || !fileInfo.Mode().IsRegular() {
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

// qoderTranscriptMatches verifies the transcript really belongs to sessionID.
// Qoder writes the session id on the first metadata records as well as on
// every message record, so the check scans the first bounded chunk instead of
// assuming a fixed header shape. A missing or malformed file is no match so
// the finder never binds Warren to a file Qoder cannot be reading itself.
func qoderTranscriptMatches(path, sessionID string) bool {
	file, err := openRegularFile(path)
	if err != nil {
		return false
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	needle := []byte(`"sessionId":"` + sessionID + `"`)
	for lines := 0; lines < 64; lines++ {
		line, readErr := readBoundedLine(reader, 1024*1024)
		if len(line) == 0 {
			break
		}
		if bytes.Contains(line, needle) {
			return true
		}
		if readErr != nil {
			break
		}
	}
	return false
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

// EnsureQoderBindHook installs the Warren binding hook into Qoder's user
// settings file (<configDir>/settings.json), preserving every existing key and
// hook entry. Qoder loads user-level hooks from the `hooks` object of its
// settings.json (SessionStart/SessionEnd events with a `command` hook), so a
// standalone hooks.json next to the config directory is never executed. On
// SessionStart the hook writes the binding file so the daemon can resolve the
// Warren session ID and transcript location without guessing.
func EnsureQoderBindHook(qoderConfigDir string) (changed bool, err error) {
	return ensureQoderSettingsHook(filepath.Join(qoderConfigDir, "settings.json"), "qoder")
}

// ensureQoderSettingsHook merges the Warren-managed hook command into the
// `hooks` object of Qoder's settings.json. The marker in the command makes
// repeated installs idempotent; user entries are never touched.
func ensureQoderSettingsHook(settingsPath, provider string) (changed bool, err error) {
	scriptPath := filepath.Join(configDir(), "hooks", "qoder-bind.sh")
	if err := os.MkdirAll(filepath.Dir(scriptPath), 0o700); err != nil {
		return false, fmt.Errorf("create hooks directory: %w", err)
	}
	if err := os.WriteFile(scriptPath, []byte(qoderBindHookScript), 0o700); err != nil {
		return false, fmt.Errorf("write bind hook script: %w", err)
	}

	document := map[string]any{}
	if data, err := os.ReadFile(settingsPath); err == nil {
		if err := json.Unmarshal(data, &document); err != nil {
			return false, fmt.Errorf("parse existing settings file %s: %w", settingsPath, err)
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
	return true, writeHooksJSON(settingsPath, document)
}

// qoderRecord is one JSONL line in a Qoder session file.
type qoderRecord struct {
	Type              string          `json:"type"`
	UUID              string          `json:"uuid"`
	ParentID          string          `json:"parentUuid"`
	Timestamp         any             `json:"timestamp"`
	SessionID         string          `json:"sessionId"`
	Cwd               string          `json:"cwd"`
	Model             string          `json:"model"`
	ReasoningEffort   any             `json:"reasoningEffort"`
	Attachment        json.RawMessage `json:"attachment"`
	IsSidechain       bool            `json:"isSidechain"`
	Message           json.RawMessage `json:"message"`
	ToolUseResult     json.RawMessage `json:"toolUseResult"`
	// Error records carry the failure at the record level (the message
	// content is the human-readable fallback text).
	IsAPIErrorMessage bool   `json:"isApiErrorMessage"`
	Error             string `json:"error"`
}

// qoderMessage is the message payload of a user/assistant record.
type qoderMessage struct {
	ID         string          `json:"id"`
	Type       string          `json:"type"`
	Role       string          `json:"role"`
	Model      string          `json:"model"`
	StopReason string          `json:"stop_reason"`
	Content    json.RawMessage `json:"content"`
}

// qoderContentBlock is one element of a Qoder message content array.
type qoderContentBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
	Content   json.RawMessage `json:"content"`
}

type qoderParser struct {
	baseParser
	qoderModel        string
	qoderEffort       string
	qoderCallTool     map[string]string
	qoderInteractions map[string]string
}

func newQoderParser(contentLimit int) *qoderParser {
	return &qoderParser{
		baseParser:        newBaseParser(contentLimit),
		qoderCallTool:     make(map[string]string),
		qoderInteractions: make(map[string]string),
	}
}

func (p *qoderParser) Parse(line []byte) []api.AgentEvent {
	return p.observe(p.parseQoder(line))
}

func (p *qoderParser) parse(line []byte) []api.AgentEvent {
	return p.Parse(line)
}

// parseQoder projects one Qoder record onto the normalized agent event stream
// understood by the transcription tracker.
func (p *qoderParser) parseQoder(line []byte) []api.AgentEvent {
	var record qoderRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	timestamp := parseTimestamp(record.Timestamp)
	if structured := projectStructuredAgentEvent(qoderProvider, record.Type, line, timestamp); structured != nil {
		if structured.ID == "" {
			structured.ID = record.UUID
		}
		return []api.AgentEvent{*structured}
	}
	switch record.Type {
	case "workspace-directories", "active-leaf", "ai-title",
		"last-prompt", "file-history-snapshot":
		// Metadata records do not participate in the visible conversation.
		return nil
	case "runtime-config", "model_change", "thinking_level_change":
		effort := stringValue(record.ReasoningEffort)
		if record.Model != "" || effort != "" {
			if record.Model != p.qoderModel || effort != p.qoderEffort {
				p.qoderModel = record.Model
				p.qoderEffort = effort
				return []api.AgentEvent{{
					Provider:  qoderProvider,
					ID:        "config",
					Type:      "config",
					Payload: map[string]any{
						"model":           record.Model,
						"reasoningEffort": effort,
					},
					Timestamp: timestamp,
				}}
			}
		}
		return nil
	case "attachment":
		var att struct {
			Type         string `json:"type"`
			PlanFilePath string `json:"planFilePath"`
			Content      string `json:"content"`
		}
		if json.Unmarshal(record.Attachment, &att) == nil && (att.PlanFilePath != "" || att.Type == "plan") {
			return []api.AgentEvent{{
				Provider: qoderProvider,
				ID:       firstNonEmpty(record.UUID, "qoder-plan"),
				Type:     "plan",
				Payload: map[string]any{
					"planId": firstNonEmpty(record.UUID, "qoder-plan"),
					"title":  "Plan",
					"file":   att.PlanFilePath,
					"state":  "in_progress",
				},
				Timestamp: timestamp,
			}}
		}
		return nil
	}

	var message qoderMessage
	if json.Unmarshal(record.Message, &message) != nil {
		return nil
	}
	switch message.Role {
	case "user":
		return p.parseQoderUser(record, message, timestamp)
	case "assistant":
		return p.parseQoderAssistant(record, message, timestamp)
	default:
		return nil
	}
}

// parseQoderUser projects a user-role record. Plain-text content is a real
// user turn; a content array of tool_result blocks carries tool outputs whose
// originating tool call was recorded by the matching assistant record.
func (p *qoderParser) parseQoderUser(record qoderRecord, message qoderMessage, timestamp time.Time) []api.AgentEvent {
	var blocks []qoderContentBlock
	if json.Unmarshal(message.Content, &blocks) == nil && len(blocks) > 0 {
		return p.parseQoderToolResults(record, blocks, timestamp)
	}
	content := p.content(message.Content)
	if content == "" {
		return nil
	}
	return []api.AgentEvent{{
		Provider:  qoderProvider,
		ID:        record.UUID,
		Type:      "user",
		Content:   p.clip(content),
		Sidechain: record.IsSidechain,
		Timestamp: timestamp,
	}}
}

// parseQoderToolResults projects each tool_result block in a user message
// content array. Qoder writes tool results as an array with one element per
// finished tool call.
func (p *qoderParser) parseQoderToolResults(record qoderRecord, blocks []qoderContentBlock, timestamp time.Time) []api.AgentEvent {
	events := make([]api.AgentEvent, 0, len(blocks))
	for _, block := range blocks {
		if block.Type != "tool_result" {
			continue
		}
		if kind := p.qoderInteractions[block.ToolUseID]; kind != "" {
			delete(p.qoderInteractions, block.ToolUseID)
			p.tracker.MarkAttention("", "", "", time.Time{})
			title := "Question"
			if kind == "permission" {
				title = "Permission"
			}
			state := "resolved"
			if block.IsError {
				state = "cancelled"
			}
			events = append(events, api.AgentEvent{
				Provider:  qoderProvider,
				ID:        block.ToolUseID,
				Type:      kind,
				Payload:   map[string]any{"requestId": block.ToolUseID, "title": title, "state": state},
				Timestamp: timestamp,
			})
			continue
		}
		output := p.content(block.Content)
		if strings.TrimSpace(output) == "" {
			continue
		}
		status := "success"
		if block.IsError {
			status = "error"
		}
		event := api.AgentEvent{
			Provider:   qoderProvider,
			ID:         record.UUID,
			Type:       "tool_output",
			CallID:     block.ToolUseID,
			ToolName:   p.qoderCallTool[block.ToolUseID],
			ToolStatus: status,
			Output:     output,
			Sidechain:  record.IsSidechain,
			Timestamp:  timestamp,
		}
		if status == "error" {
			event.Error = output
		}
		if len(record.ToolUseResult) > 0 {
			var tr struct {
				FilePath        string `json:"filePath"`
				StructuredPatch any    `json:"structuredPatch"`
			}
			if json.Unmarshal(record.ToolUseResult, &tr) == nil && tr.StructuredPatch != nil {
				adds, dels, diffText := parseStructuredPatchChunks(tr.StructuredPatch)
				if adds > 0 || dels > 0 || diffText != "" {
					diffPayload := map[string]any{
						"file":      tr.FilePath,
						"files":     []string{tr.FilePath},
						"additions": adds,
						"deletions": dels,
						"diff":      diffText,
						"callId":    block.ToolUseID,
					}
					if event.Payload == nil {
						event.Payload = make(map[string]any)
					}
					event.Payload["diff"] = diffPayload
					events = append(events, api.AgentEvent{
						Provider:  qoderProvider,
						ID:        record.UUID,
						Type:      "diff",
						Payload:   diffPayload,
						Timestamp: timestamp,
					})
				}
			}
		}
		events = append(events, event)
	}
	return events
}

// parseQoderAssistant projects an assistant record. Qoder writes each content
// block (thinking / text / tool_use) as its own record, so every record maps
// to at most one normalized event. The stop reason on the final record of a
// turn (end_turn, stop, length, ...) marks the boundary; tool_use is not
// terminal.
func (p *qoderParser) parseQoderAssistant(record qoderRecord, message qoderMessage, timestamp time.Time) []api.AgentEvent {
	var blocks []qoderContentBlock
	if json.Unmarshal(message.Content, &blocks) != nil || len(blocks) == 0 {
		return nil
	}
	stopReason := qoderStopReason(message.StopReason)
	// An API error assistant record carries the failure details at the record
	// level; project it as an error event so the UI shows the failure instead
	// of a bare text bubble.
	if record.IsAPIErrorMessage {
		content := p.clip(firstNonEmpty(messageText(blocks), record.Error, p.content(message.Content)))
		if content == "" {
			return nil
		}
		event := api.AgentEvent{
			Provider:  qoderProvider,
			ID:        record.UUID,
			Type:      "error",
			Content:   content,
			Error:     content,
			Sidechain: record.IsSidechain,
			Timestamp: timestamp,
		}
		if stopReason != "" {
			event.StopReason = stopReason
		}
		return []api.AgentEvent{event}
	}
	event := api.AgentEvent{
		Provider:   qoderProvider,
		ID:         record.UUID,
		Model:      message.Model,
		StopReason: stopReason,
		Sidechain:  record.IsSidechain,
		Timestamp:  timestamp,
	}
	switch blocks[0].Type {
	case "text":
		text := p.clip(blocks[0].Text)
		if text == "" {
			return nil
		}
		if record.IsSidechain {
			event.Type = "subagent"
			event.Payload = map[string]any{
				"subagentId": record.UUID,
				"title":      "Subagent",
				"label":      "Subagent",
				"state":      "completed",
				"summary":    text,
			}
		} else {
			event.Type = "assistant"
			event.Content = text
		}
	case "thinking":
		thinking := p.clip(blocks[0].Thinking)
		if thinking == "" {
			return nil
		}
		event.Type = "reasoning"
		event.Content = thinking
	case "tool_use":
		toolName := canonicalToolName(qoderProvider, blocks[0].Name)
		callID := blocks[0].ID
		if callID == "" {
			callID = record.UUID
		}
		if toolName == "ask_user_question" {
			input, _ := rawToAny(blocks[0].Input, p.contentLimit).(map[string]any)
			event.Type = "question"
			event.ID = callID
			event.Payload = claudeQuestionPayload(callID, input)
			if callID != "" {
				p.qoderInteractions[callID] = "question"
			}
			p.tracker.MarkAttention(api.AgentAttentionInput, "question", callID, timestamp)
			return []api.AgentEvent{event}
		}
		if toolName == "permission_request" {
			input, _ := rawToAny(blocks[0].Input, p.contentLimit).(map[string]any)
			event.Type = "permission"
			event.ID = callID
			event.Payload = claudePermissionPayload(callID, input)
			if callID != "" {
				p.qoderInteractions[callID] = "permission"
			}
			p.tracker.MarkAttention(api.AgentAttentionApproval, "permission", callID, timestamp)
			return []api.AgentEvent{event}
		}
		if toolName == "todowrite" {
			input, _ := rawToAny(blocks[0].Input, p.contentLimit).(map[string]any)
			event.Type = "todo"
			event.ID = "qoder-todos"
			event.Payload = claudeTodoPayload(input)
			return []api.AgentEvent{event}
		}
		if toolName == "" {
			toolName = "tool"
		}
		event.Type = "tool_call"
		event.ToolName = toolName
		event.CallID = callID
		event.ToolInput = rawToAny(blocks[0].Input, p.contentLimit)
		if callID != "" {
			p.qoderCallTool[callID] = toolName
		}
		if input, ok := event.ToolInput.(map[string]any); ok {
			if path, ok := input["path"].(string); ok && path != "" {
				event.Files = []string{path}
			}
			if path, ok := input["file_path"].(string); ok && path != "" {
				event.Files = []string{path}
			}
			if patch, ok := input["patch"].(string); ok && toolName == "apply_patch" {
				event.Files = patchFiles(patch)
			}
		}
	default:
		// Unknown block: keep whatever text it carries so the UI never drops
		// a rendered part silently.
		content := p.clip(firstNonEmpty(blocks[0].Text, blocks[0].Thinking, p.content(blocks[0].Content)))
		if content == "" {
			return nil
		}
		event.Type = "unknown"
		event.Content = content
	}
	return []api.AgentEvent{event}
}

func messageText(blocks []qoderContentBlock) string {
	for _, block := range blocks {
		if block.Type == "text" && strings.TrimSpace(block.Text) != "" {
			return block.Text
		}
	}
	return ""
}

func qoderStopReason(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "end_turn", "stop", "length", "max_tokens", "stop_sequence", "content_filter", "error":
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
