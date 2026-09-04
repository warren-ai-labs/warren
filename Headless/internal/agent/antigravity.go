package agent

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/ncruces/go-sqlite3/driver"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const antigravityProvider = "antigravity"

var antigravitySessionReuseFlags = map[string]bool{
	"--conversation": true,
	"--continue":     true,
	"-c":             true,
}

var antigravityNonInteractiveFlags = map[string]bool{
	"-p":              true,
	"--print":         true,
	"--prompt":        true,
	"--input-format":  true,
	"--output-format": true,
}

// ValidateAntigravityCommand ensures commands for Antigravity start an interactive session
// and reject resume or print/non-interactive flags.
func ValidateAntigravityCommand(command string) error {
	if err := validateAntigravityShellSyntax(command); err != nil {
		return err
	}
	tokens, err := splitAntigravityCommandWords(command)
	if err != nil {
		return fmt.Errorf("invalid Antigravity command: %w", err)
	}
	if len(tokens) == 0 {
		return errors.New("Antigravity command must not be empty")
	}
	hasInteractivePrompt := false
	for index := 1; index < len(tokens); index++ {
		flag := tokens[index]
		if equal := strings.IndexByte(flag, '='); equal >= 0 {
			flag = flag[:equal]
		}
		if flag == "-i" || flag == "--prompt-interactive" {
			hasInteractivePrompt = true
		}
		if antigravitySessionReuseFlags[flag] {
			return errors.New("Antigravity command must start a new session; session resume flags are not supported")
		}
		if antigravityNonInteractiveFlags[flag] && !hasInteractivePrompt {
			hasInteractive := false
			for _, t := range tokens[1:] {
				if t == "-i" || t == "--prompt-interactive" || strings.HasPrefix(t, "-i=") || strings.HasPrefix(t, "--prompt-interactive=") {
					hasInteractive = true
					break
				}
			}
			if !hasInteractive {
				return errors.New("Antigravity command must use interactive mode; print and non-interactive flags are not supported")
			}
		}
	}
	return nil
}

func validateAntigravityShellSyntax(command string) error {
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
				return errors.New("Antigravity command must not contain shell operators or substitutions")
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
			return errors.New("Antigravity command must be an executable with options; shell operators and substitutions are not supported")
		}
	}
	if escaped {
		return errors.New("Antigravity command has a trailing escape")
	}
	if inSingle || inDouble {
		return errors.New("Antigravity command has an unterminated quote")
	}
	return nil
}

func splitAntigravityCommandWords(command string) ([]string, error) {
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
		case char == '\'':
			inSingle = true
			started = true
		case char == '"':
			inDouble = true
			started = true
		case char == '\\':
			escaped = true
			started = true
		case char == ' ' || char == '\t':
			flush()
		default:
			current.WriteRune(char)
			started = true
		}
	}
	if escaped {
		return nil, errors.New("Antigravity command has a trailing escape")
	}
	if inSingle || inDouble {
		return nil, errors.New("Antigravity command has an unterminated quote")
	}
	flush()
	return words, nil
}

// AntigravityHome returns the application data root directory for Antigravity CLI.
func AntigravityHome() string {
	if value := os.Getenv("ANTIGRAVITY_HOME"); value != "" {
		return filepath.Clean(value)
	}
	if value := os.Getenv("GEMINI_HOME"); value != "" {
		return filepath.Clean(value)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.Join(".gemini", "antigravity-cli")
	}
	return filepath.Join(home, ".gemini", "antigravity-cli")
}

// AntigravityConfigDir returns the configuration directory where hooks.json resides.
func AntigravityConfigDir() string {
	if value := os.Getenv("ANTIGRAVITY_CONFIG_DIR"); value != "" {
		return filepath.Clean(value)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return filepath.Join(".gemini", "config")
	}
	return filepath.Join(home, ".gemini", "config")
}

// FindAntigravityTranscript locates the transcript.jsonl file for an Antigravity conversation.
func FindAntigravityTranscript(sessionID, workspacePath string) string {
	home := AntigravityHome()
	if strings.TrimSpace(sessionID) != "" {
		path := filepath.Join(home, "brain", sessionID, ".system_generated", "logs", "transcript.jsonl")
		if regularFileExists(path) {
			return path
		}
		return ""
	}
	if strings.TrimSpace(workspacePath) != "" {
		dbPath := filepath.Join(home, "conversation_summaries.db")
		if regularFileExists(dbPath) {
			if found := findAntigravityFromDB(dbPath, workspacePath); found != "" {
				return found
			}
		}
	}
	return ""
}

func findAntigravityFromDB(dbPath, workspacePath string) string {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return ""
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var conversationID string
	query := `SELECT conversation_id FROM conversation_summaries WHERE workspace_uris LIKE ? ORDER BY last_modified_time DESC LIMIT 1`
	if err := db.QueryRowContext(ctx, query, "%"+workspacePath+"%").Scan(&conversationID); err != nil {
		return ""
	}
	if conversationID != "" {
		path := filepath.Join(filepath.Dir(dbPath), "brain", conversationID, ".system_generated", "logs", "transcript.jsonl")
		if regularFileExists(path) {
			return path
		}
	}
	return ""
}

func regularFileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// EnsureAntigravityBindHook installs Warren's PreInvocation and Stop lifecycle hooks into
// Antigravity's hooks.json, preserving any existing hooks.
func EnsureAntigravityBindHook(configDir string) (changed bool, err error) {
	scriptPath := filepath.Join(configDir, "hooks", "agent-bind.sh")
	if err := os.MkdirAll(filepath.Dir(scriptPath), 0o700); err != nil {
		return false, fmt.Errorf("create hooks directory: %w", err)
	}
	if err := os.WriteFile(scriptPath, []byte(agentBindHookScript), 0o700); err != nil {
		return false, fmt.Errorf("write bind hook script: %w", err)
	}

	hooksPath := filepath.Join(configDir, "hooks.json")
	document := map[string]any{}
	if data, err := os.ReadFile(hooksPath); err == nil {
		if err := json.Unmarshal(data, &document); err != nil {
			return false, fmt.Errorf("parse existing hooks file %s: %w", hooksPath, err)
		}
	}
	warrenHook, _ := document["warren-bind"].(map[string]any)
	if warrenHook == nil {
		warrenHook = map[string]any{}
		document["warren-bind"] = warrenHook
	}

	events := []struct {
		event   string
		command string
	}{
		{"PreInvocation", "bash '" + scriptPath + "' " + hookCommandMarker + " antigravity PreInvocation"},
		{"Stop", "bash '" + scriptPath + "' " + hookCommandMarker + " antigravity Stop"},
	}

	for _, item := range events {
		entries, _ := warrenHook[item.event].([]any)
		found := false
		for i, entry := range entries {
			hookMap, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			cmd, _ := hookMap["command"].(string)
			if strings.Contains(cmd, hookCommandMarker) {
				found = true
				if cmd != item.command {
					hookMap["command"] = item.command
					entries[i] = hookMap
					changed = true
				}
				break
			}
		}
		if !found {
			entries = append(entries, map[string]any{
				"type":    "command",
				"command": item.command,
			})
			warrenHook[item.event] = entries
			changed = true
		}
	}

	if !changed {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(hooksPath), 0o700); err != nil {
		return false, fmt.Errorf("create config directory: %w", err)
	}
	return true, writeHooksJSON(hooksPath, document)
}

func cleanAntigravityUserContent(content string) string {
	startTag := "<USER_REQUEST>"
	endTag := "</USER_REQUEST>"
	startIndex := strings.Index(content, startTag)
	if startIndex != -1 {
		contentAfter := content[startIndex+len(startTag):]
		endIndex := strings.Index(contentAfter, endTag)
		if endIndex != -1 {
			return strings.TrimSpace(contentAfter[:endIndex])
		}
	}
	return strings.TrimSpace(content)
}

func antigravityQuestionPayload(requestID string, rawArgs json.RawMessage) map[string]any {
	var params struct {
		Questions []struct {
			Question      string `json:"question"`
			IsMultiSelect bool   `json:"is_multi_select"`
			Options       any    `json:"options"`
		} `json:"questions"`
	}
	_ = json.Unmarshal(rawArgs, &params)
	questions := make([]any, 0)
	for index, item := range params.Questions {
		prompt := item.Question
		if prompt == "" {
			prompt = "Question"
		}
		selection := "single"
		if item.IsMultiSelect {
			selection = "multiple"
		}
		options := make([]any, 0)
		if rawOpts, ok := item.Options.([]any); ok {
			for optIdx, optItem := range rawOpts {
				if optStr, ok := optItem.(string); ok {
					options = append(options, map[string]any{
						"id":    optStr,
						"label": optStr,
					})
				} else if optMap, ok := optItem.(map[string]any); ok {
					label := stringValue(optMap["label"])
					if label == "" {
						label = stringValue(optMap["text"])
					}
					entry := map[string]any{
						"id":    firstNonEmpty(label, fmt.Sprintf("opt-%d", optIdx)),
						"label": label,
					}
					if desc := stringValue(optMap["description"]); desc != "" {
						entry["description"] = desc
					}
					options = append(options, entry)
				}
			}
		}
		questions = append(questions, map[string]any{
			"id":          fmt.Sprintf("q%d", index),
			"prompt":      prompt,
			"selection":   selection,
			"required":    true,
			"allowCustom": false,
			"options":     options,
		})
	}
	return map[string]any{
		"requestId": requestID,
		"title":     "Question",
		"questions": questions,
		"state":     "pending",
	}
}

type antigravityRecord struct {
	StepIndex int                   `json:"step_index"`
	Source    string                `json:"source"`
	Type      string                `json:"type"`
	Status    string                `json:"status"`
	CreatedAt string                `json:"created_at"`
	Content   string                `json:"content"`
	Thinking  string                `json:"thinking"`
	ToolCalls []antigravityToolCall `json:"tool_calls"`
}

type antigravityToolCall struct {
	Name string          `json:"name"`
	Args json.RawMessage `json:"args"`
}

type antigravityParser struct {
	baseParser
	antigravityCallTool     map[string]string
	antigravityPendingCalls []string
	antigravityInteractions map[string]string
}

func newAntigravityParser(contentLimit int) *antigravityParser {
	return &antigravityParser{
		baseParser:              newBaseParser(contentLimit),
		antigravityCallTool:     make(map[string]string),
		antigravityInteractions: make(map[string]string),
	}
}

func (p *antigravityParser) Parse(line []byte) []api.AgentEvent {
	return p.observe(p.parseAntigravity(line))
}

func (p *antigravityParser) parse(line []byte) []api.AgentEvent {
	return p.Parse(line)
}

func (p *antigravityParser) parseAntigravity(line []byte) []api.AgentEvent {
	var record antigravityRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	timestamp := parseTimestamp(record.CreatedAt)
	switch record.Type {
	case "USER_INPUT":
		cleaned := cleanAntigravityUserContent(record.Content)
		if cleaned == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  antigravityProvider,
			Type:      "user",
			Role:      "user",
			Content:   p.clip(cleaned),
			Timestamp: timestamp,
			ID:        fmt.Sprintf("step_%d", record.StepIndex),
		}}

	case "PLANNER_RESPONSE":
		var events []api.AgentEvent
		if strings.TrimSpace(record.Thinking) != "" {
			events = append(events, api.AgentEvent{
				Provider:  antigravityProvider,
				Type:      "reasoning",
				Content:   p.clip(record.Thinking),
				Timestamp: timestamp,
			})
		}
		for i, tc := range record.ToolCalls {
			callID := fmt.Sprintf("%d_%d", record.StepIndex, i)
			p.antigravityCallTool[callID] = tc.Name
			p.antigravityPendingCalls = append(p.antigravityPendingCalls, callID)

			if tc.Name == "ask_question" {
				p.antigravityInteractions[callID] = "question"
				payload := antigravityQuestionPayload(callID, tc.Args)
				p.tracker.MarkAttention(api.AgentAttentionInput, "question", callID, timestamp)
				events = append(events, api.AgentEvent{
					Provider:  antigravityProvider,
					Type:      "question",
					CallID:    callID,
					ToolName:  tc.Name,
					Payload:   payload,
					Timestamp: timestamp,
				})
			} else {
				var parsedArgs any
				if len(tc.Args) > 0 {
					_ = json.Unmarshal(tc.Args, &parsedArgs)
				}
				events = append(events, api.AgentEvent{
					Provider:  antigravityProvider,
					Type:      "tool_call",
					CallID:    callID,
					ToolName:  tc.Name,
					ToolInput: parsedArgs,
					Files:     antigravityFiles(tc.Name, parsedArgs),
					Timestamp: timestamp,
				})
			}
		}
		if strings.TrimSpace(record.Content) != "" {
			events = append(events, api.AgentEvent{
				Provider:   antigravityProvider,
				Type:       "assistant",
				Role:       "assistant",
				Content:    p.clip(record.Content),
				StopReason: "stop",
				Timestamp:  timestamp,
			})
		}
		return events

	case "GENERIC":
		if len(p.antigravityPendingCalls) == 0 {
			return nil
		}
		callID := p.antigravityPendingCalls[0]
		p.antigravityPendingCalls = p.antigravityPendingCalls[1:]
		toolName := p.antigravityCallTool[callID]

		toolStatus := "completed"
		if record.Status == "ERROR" {
			toolStatus = "error"
		}
		if p.antigravityInteractions[callID] == "question" {
			p.tracker.MarkAttention("", "", "", time.Time{})
		}
		event := api.AgentEvent{
			Provider:   antigravityProvider,
			Type:       "tool_output",
			CallID:     callID,
			ToolName:   toolName,
			Output:     p.clip(record.Content),
			ToolStatus: toolStatus,
			Timestamp:  timestamp,
		}
		if toolStatus == "error" {
			event.Error = p.clip(record.Content)
		}
		return []api.AgentEvent{event}

	default:
		return nil
	}
}

func antigravityFiles(toolName string, args any) []string {
	m, ok := args.(map[string]any)
	if !ok {
		return nil
	}
	for _, key := range []string{"TargetFile", "AbsolutePath", "file_path", "path", "file"} {
		if val, ok := m[key].(string); ok {
			clean := strings.Trim(strings.TrimSpace(val), `"'`)
			if clean != "" {
				return []string{clean}
			}
		}
	}
	return nil
}
