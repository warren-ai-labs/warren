package agent

// Pi integration. Pi stores each conversation as a plain JSONL file under
// ~/.pi/agent/sessions (honoring PI_CODING_AGENT_DIR and
// PI_CODING_AGENT_SESSION_DIR like the CLI itself). Warren launches pi
// without injecting a session id: the Warren-managed extension reports the
// conversation pi creates on session_start, and the daemon tails the
// resolved JSONL with the ordinary watcher. There is no SQLite store and no
// private cache: the provider's own JSONL is already the normalized
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

const piProvider = "pi"

// piSessionReuseFlags are Pi options that reuse an existing conversation.
// Warren binds the session pi creates on session_start, so a user command
// that resumes, forks, or selects an existing session would detach the Agent
// tab from that conversation (and --no-session leaves no transcript to tail).
var piSessionReuseFlags = map[string]bool{
	"--continue": true,
	"-c":         true,
	"--resume":   true,
	"-r":         true,
	"--session":  true,
	"--session-id": true,
	"--fork":     true,
	"--no-session": true,
}

// piNonInteractiveFlags are Pi options that switch the CLI out of its
// interactive TUI. Warren's Agent view drives the TUI, so these modes cannot
// be bound the same way.
var piNonInteractiveFlags = map[string]bool{
	"-p":      true,
	"--print": true,
	"--mode":  true,
}

// ValidatePiCommand keeps every session.create caller from selecting a Pi
// conversation that Warren did not create. The CLI performs the same
// validation for agent create, but Desktop and Web launch presets call
// session.create directly and must receive the invariant at the Host
// boundary.
func ValidatePiCommand(command string) error {
	if err := validatePiShellSyntax(command); err != nil {
		return err
	}
	tokens, err := splitPiCommandWords(command)
	if err != nil {
		return fmt.Errorf("invalid Pi command: %w", err)
	}
	if len(tokens) == 0 {
		return errors.New("Pi command must not be empty")
	}
	for index := 1; index < len(tokens); index++ {
		flag := tokens[index]
		if equal := strings.IndexByte(flag, '='); equal >= 0 {
			flag = flag[:equal]
		}
		if piSessionReuseFlags[flag] {
			return errors.New("Pi command must start a new session; session resume or fork flags are not supported")
		}
		if piNonInteractiveFlags[flag] {
			return errors.New("Pi command must use interactive mode; non-interactive print and mode flags are not supported")
		}
	}
	return nil
}

// validatePiShellSyntax rejects shell operators and substitutions so a Pi
// command stays a plain executable with options that the terminal runtime can
// evaluate safely.
func validatePiShellSyntax(command string) error {
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
				return errors.New("Pi command must not contain shell operators or substitutions")
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
			return errors.New("Pi command must be an executable with options; shell operators and substitutions are not supported")
		}
	}
	if escaped {
		return errors.New("Pi command has a trailing escape")
	}
	if inSingle || inDouble {
		return errors.New("Pi command has an unterminated quote")
	}
	return nil
}

// splitPiCommandWords splits a Pi command into shell words without evaluating
// expansions. It mirrors the OpenCode/CLI word splitting so validation and
// the terminal runtime agree on what is a flag and what is a value.
func splitPiCommandWords(command string) ([]string, error) {
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

// PiSessionsRoot returns the directory Pi stores session files in, honoring
// the same overrides as the CLI: --session-dir / PI_CODING_AGENT_SESSION_DIR
// win over the default under PI_CODING_AGENT_DIR (or ~/.pi/agent).
func PiSessionsRoot() string {
	if value := strings.TrimSpace(os.Getenv("PI_CODING_AGENT_SESSION_DIR")); value != "" {
		return filepath.Clean(value)
	}
	if value := strings.TrimSpace(os.Getenv("PI_CODING_AGENT_DIR")); value != "" {
		return filepath.Join(value, "sessions")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.Join(".pi", "agent", "sessions")
	}
	return filepath.Join(home, ".pi", "agent", "sessions")
}

// PiSessionFileName returns the deterministic suffix pi's session files end
// with: pi writes <timestamp>_<session-id>.jsonl.
func PiSessionFileName(sessionID string) string {
	return "_" + sessionID + ".jsonl"
}

// FindPiTranscript locates the JSONL transcript for a Warren session by its
// injected Pi session id. The scan is scoped to the exact filename suffix so
// a stale or manually-created Pi session can never be adopted. The header is
// verified as a second guard so a future Pi layout change degrades to a
// retry instead of tailing the wrong conversation. The cwd is deliberately
// not part of the match: a Session moved between Workspaces keeps its
// original transcript, so only the unique injected id is authoritative.
func FindPiTranscript(sessionID string) string {
	root := PiSessionsRoot()
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() {
		return ""
	}
	suffix := PiSessionFileName(sessionID)
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
		if !piTranscriptHeaderMatches(path, sessionID) {
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

// piTranscriptHeaderMatches checks the session header line id field. A
// missing or malformed header is treated as no match so the finder never
// binds Warren to a file that Pi cannot be reading itself.
func piTranscriptHeaderMatches(path, sessionID string) bool {
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

// piRecord is one JSONL line in a pi session file.
type piRecord struct {
	Type          string          `json:"type"`
	ID            string          `json:"id"`
	ParentID      string          `json:"parentId"`
	Timestamp     any             `json:"timestamp"`
	Provider      string          `json:"provider"`
	ModelID       string          `json:"modelId"`
	ThinkingLevel string          `json:"thinkingLevel"`
	Message       json.RawMessage `json:"message"`
	// Compaction and branch summaries are provider bookkeeping. Their
	// summaries are projected as compact system events so a long-running
	// conversation still reads as a coherent transcript.
	Summary    string          `json:"summary"`
	CustomType string          `json:"customType"`
	Content    json.RawMessage `json:"content"`
	Display    bool            `json:"display"`
	Data       json.RawMessage `json:"data"`
	Name       string          `json:"name"`
	TargetID   string          `json:"targetId"`
}

// piMessage is the message payload of a pi `message` entry.
type piMessage struct {
	Role         string          `json:"role"`
	Content      json.RawMessage `json:"content"`
	Provider     string          `json:"provider"`
	Model        string          `json:"model"`
	Usage        json.RawMessage `json:"usage"`
	StopReason   string          `json:"stopReason"`
	ErrorMessage string          `json:"errorMessage"`
	// toolResult fields.
	ToolCallID string `json:"toolCallId"`
	ToolName   string `json:"toolName"`
	IsError    bool   `json:"isError"`
	// bashExecution fields.
	Command   string `json:"command"`
	Output    string `json:"output"`
	ExitCode  int    `json:"exitCode"`
	Cancelled bool   `json:"cancelled"`
	Truncated bool   `json:"truncated"`
	Details   struct {
		Diff             string `json:"diff"`
		Patch            string `json:"patch"`
		FirstChangedLine int    `json:"firstChangedLine"`
	} `json:"details"`
	// custom message fields.
	CustomType string `json:"customType"`
	Display    bool   `json:"display"`
}

// piContentBlock is one element of a pi message content array.
type piContentBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// piUsage mirrors pi's assistant usage object.
type piUsage struct {
	Input       int64 `json:"input"`
	Output      int64 `json:"output"`
	CacheRead   int64 `json:"cacheRead"`
	CacheWrite  int64 `json:"cacheWrite"`
	Reasoning   int64 `json:"reasoning"`
	TotalTokens int64 `json:"totalTokens"`
}

type piParser struct {
	baseParser
	piModel  string
	piEffort string
}

func newPiParser(contentLimit int) *piParser {
	return &piParser{
		baseParser: newBaseParser(contentLimit),
	}
}

func (p *piParser) Parse(line []byte) []api.AgentEvent {
	return p.observe(p.parsePi(line))
}

func (p *piParser) parse(line []byte) []api.AgentEvent {
	return p.Parse(line)
}

func (p *piParser) parsePi(line []byte) []api.AgentEvent {
	var record piRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	timestamp := parseTimestamp(record.Timestamp)
	provider := piProvider
	model := ""
	if structured := projectStructuredAgentEvent(provider, record.Type, line, timestamp); structured != nil {
		if structured.ID == "" {
			structured.ID = record.ID
		}
		return []api.AgentEvent{*structured}
	}
	switch record.Type {
	case "session", "label", "session_info", "custom":
		// Metadata entries do not participate in the visible conversation.
		return nil
	case "model_change":
		newModel := piDisplayModel(record.Provider, record.ModelID)
		if newModel != "" && newModel != p.piModel {
			p.piModel = newModel
			return []api.AgentEvent{{
				Provider:  provider,
				ID:        firstNonEmpty(record.ID, "config"),
				Type:      "config",
				Payload: map[string]any{
					"model":           newModel,
					"reasoningEffort": p.piEffort,
				},
				Timestamp: timestamp,
			}}
		}
		return nil
	case "thinking_level_change":
		newEffort := strings.TrimSpace(record.ThinkingLevel)
		if newEffort != "" && newEffort != p.piEffort {
			p.piEffort = newEffort
			return []api.AgentEvent{{
				Provider:  provider,
				ID:        firstNonEmpty(record.ID, "config"),
				Type:      "config",
				Payload: map[string]any{
					"model":           p.piModel,
					"reasoningEffort": newEffort,
				},
				Timestamp: timestamp,
			}}
		}
		return nil
	case "compaction":
		return []api.AgentEvent{{
			Provider:  provider,
			ID:        firstNonEmpty(record.ID, "compaction"),
			Type:      "compaction",
			Content:   "History compacted",
			Payload: map[string]any{
				"summary": "History compacted",
			},
			Timestamp: timestamp,
		}}
	case "branch_summary":
		content := strings.TrimSpace(record.Summary)
		if content == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  provider,
			ID:        record.ID,
			Type:      "system",
			Content:   p.clip("Branch summary: " + content),
			Timestamp: timestamp,
		}}
	case "custom_message":
		content := p.content(record.Content)
		if !record.Display || content == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  provider,
			ID:        record.ID,
			Type:      "system",
			Content:   p.clip(content),
			Timestamp: timestamp,
		}}
	case "message":
		// handled below
	default:
		return nil
	}

	var message piMessage
	if json.Unmarshal(record.Message, &message) != nil {
		return nil
	}
	model = piDisplayModel(message.Provider, message.Model)
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
		return p.parsePiAssistant(record, message, model, timestamp)
	case "toolResult":
		return p.parsePiToolResult(record, message, model, timestamp)
	case "bashExecution":
		return p.parsePiBash(record, message, timestamp)
	case "custom":
		content := p.content(message.Content)
		if !message.Display || content == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  provider,
			ID:        record.ID,
			Type:      "system",
			Content:   p.clip(content),
			Timestamp: timestamp,
		}}
	default:
		return nil
	}
}

func (p *piParser) parsePiAssistant(record piRecord, message piMessage, model string, timestamp time.Time) []api.AgentEvent {
	var blocks []piContentBlock
	if json.Unmarshal(message.Content, &blocks) != nil {
		content := p.content(message.Content)
		if content == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:   piProvider,
			ID:         record.ID,
			Type:       "assistant",
			Content:    p.clip(content),
			Model:      model,
			StopReason: piStopReason(message.StopReason),
			Usage:      parsePiUsage(message.Usage),
			Timestamp:  timestamp,
		}}
	}
	var events []api.AgentEvent
	textIndex := -1
	for _, block := range blocks {
		event := api.AgentEvent{
			Provider:  piProvider,
			ID:        record.ID,
			Model:     model,
			Usage:     parsePiUsage(message.Usage),
			Timestamp: timestamp,
		}
		switch block.Type {
		case "text":
			text := p.clip(block.Text)
			if text == "" {
				continue
			}
			event.Type = "assistant"
			event.Content = text
			textIndex = len(events)
			events = append(events, event)
		case "thinking":
			thinking := p.clip(block.Thinking)
			if thinking == "" {
				continue
			}
			event.Type = "reasoning"
			event.Content = thinking
			events = append(events, event)
		case "toolCall":
			toolName := block.Name
			if toolName == "" {
				toolName = "tool"
			}
			callID := block.ID
			if callID == "" {
				callID = record.ID
			}
			event.Type = "tool_call"
			event.ToolName = toolName
			event.CallID = callID
			event.ToolInput = rawToAny(block.Arguments, p.contentLimit)
			if input, ok := event.ToolInput.(map[string]any); ok {
				if path, ok := input["path"].(string); ok && path != "" && toolName == "read" {
					event.Files = []string{path}
				}
				if path, ok := input["file_path"].(string); ok && path != "" {
					event.Files = []string{path}
				}
			}
			events = append(events, event)
		case "image":
			// Binary images are not projected as text; the terminal view
			// remains the source of truth for them.
			continue
		default:
			content := p.clip(firstNonEmpty(block.Text, block.Thinking, p.content(block.Arguments)))
			if content == "" {
				continue
			}
			event.Type = "unknown"
			event.Content = content
			events = append(events, event)
		}
	}
	if len(events) == 0 {
		return nil
	}
	// The stop reason belongs on the assistant text boundary. When a turn
	// ends with tool calls only, the tracker keeps the turn open until the
	// next assistant text or tool output resolves it.
	if textIndex >= 0 {
		events[textIndex].StopReason = piStopReason(message.StopReason)
	}
	if message.StopReason == "error" && message.ErrorMessage != "" {
		events = append(events, api.AgentEvent{
			Provider:  piProvider,
			ID:        record.ID,
			Type:      "error",
			Content:   p.clip(message.ErrorMessage),
			Error:     p.clip(message.ErrorMessage),
			Model:     model,
			Timestamp: timestamp,
		})
	} else if message.StopReason == "aborted" {
		// An interrupted turn is an intentional return to idle, matching the
		// explicit abort Codex emits through its own event stream.
		p.tracker.TurnInterrupted()
	}
	return events
}

func (p *piParser) parsePiToolResult(record piRecord, message piMessage, model string, timestamp time.Time) []api.AgentEvent {
	callID := message.ToolCallID
	if callID == "" {
		callID = record.ID
	}
	output := p.content(message.Content)
	if output == "" {
		return nil
	}
	status := "success"
	if message.IsError {
		status = "error"
	}
	event := api.AgentEvent{
		Provider:   piProvider,
		ID:         record.ID,
		Type:       "tool_output",
		CallID:     callID,
		ToolName:   message.ToolName,
		ToolStatus: status,
		Output:     output,
		Model:      model,
		Timestamp:  timestamp,
	}
	diffText := firstNonEmpty(message.Details.Diff, message.Details.Patch)
	if diffText != "" {
		adds, dels := parseUnifiedDiffStats(diffText)
		diffPayload := map[string]any{
			"additions": adds,
			"deletions": dels,
			"diff":      diffText,
			"callId":    callID,
		}
		event.Payload = map[string]any{"diff": diffPayload}
		return []api.AgentEvent{
			event,
			{
				Provider:  piProvider,
				ID:        record.ID,
				Type:      "diff",
				Payload:   diffPayload,
				Timestamp: timestamp,
			},
		}
	}
	return []api.AgentEvent{event}
}

// parsePiBash projects pi's user-invoked `!`/`!!` shell execution record as a
// compact tool card. The command is the input and the captured output the
// result; exitCode drives the status like any other tool result.
func (p *piParser) parsePiBash(record piRecord, message piMessage, timestamp time.Time) []api.AgentEvent {
	callID := record.ID
	command := message.Command
	output := p.clip(message.Output)
	status := "success"
	if message.ExitCode != 0 {
		status = "error"
	}
	if message.Cancelled {
		status = "interrupted"
	}
	call := api.AgentEvent{
		Provider:  piProvider,
		ID:        record.ID,
		Type:      "tool_call",
		CallID:    callID,
		ToolName:  "bash",
		ToolInput: map[string]any{"command": command},
		Timestamp: timestamp,
	}
	result := api.AgentEvent{
		Provider:   piProvider,
		ID:         record.ID,
		Type:       "tool_output",
		CallID:     callID,
		ToolName:   "bash",
		ToolStatus: status,
		Output:     output,
		Timestamp:  timestamp,
	}
	if status == "error" {
		result.Error = output
	}
	return []api.AgentEvent{call, result}
}

// piDisplayModel mirrors the "provider/model" convention OpenCode uses so
// clients format one compact model string. Pi's own model field can already
// contain a slash (router names), so that value wins as-is.
func piDisplayModel(provider, model string) string {
	model = strings.TrimSpace(model)
	provider = strings.TrimSpace(provider)
	if model == "" {
		return ""
	}
	if provider == "" || strings.Contains(model, "/") {
		return model
	}
	return provider + "/" + model
}

// piStopReason maps pi's terminal stop reasons onto the normalized values the
// tracker understands. Non-terminal values (toolUse, pending) stay empty so
// the turn remains open.
func piStopReason(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "stop", "length", "max_tokens", "error", "content_filter", "content-filter":
		return strings.ToLower(strings.TrimSpace(value))
	case "aborted":
		return "aborted"
	default:
		return ""
	}
}

func parsePiUsage(raw json.RawMessage) *api.AgentUsage {
	if len(raw) == 0 {
		return nil
	}
	var value piUsage
	if json.Unmarshal(raw, &value) != nil {
		return nil
	}
	if value.Input == 0 && value.Output == 0 && value.TotalTokens == 0 &&
		value.CacheRead == 0 && value.CacheWrite == 0 && value.Reasoning == 0 {
		return nil
	}
	return &api.AgentUsage{
		InputTokens:              value.Input,
		OutputTokens:             value.Output,
		CacheReadInputTokens:     value.CacheRead,
		CacheCreationInputTokens: value.CacheWrite,
		ReasoningOutputTokens:    value.Reasoning,
		TotalTokens:              value.TotalTokens,
	}
}
