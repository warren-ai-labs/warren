package agent

import (
	"encoding/json"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type codexParser struct {
	baseParser
	codexModel           string
	codexCallTool        map[string]string
	codexTurnFailed      bool
	lastUserContent      string
	lastAssistantContent string
	lastReasoningContent string
	lastEventType        string
}

func newCodexParser(contentLimit int) *codexParser {
	return &codexParser{
		baseParser:    newBaseParser(contentLimit),
		codexCallTool: make(map[string]string),
	}
}

func (p *codexParser) Parse(line []byte) []api.AgentEvent {
	return p.observe(p.parseCodex(line))
}

func (p *codexParser) parse(line []byte) []api.AgentEvent {
	return p.Parse(line)
}

type codexRecord struct {
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

type codexPayload struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	Role      string          `json:"role"`
	Model     string          `json:"model"`
	Effort    string          `json:"effort"`
	Content   json.RawMessage `json:"content"`
	Name      string          `json:"name"`
	CallID    string          `json:"call_id"`
	Arguments string          `json:"arguments"`
	Input     json.RawMessage `json:"input"`
	Action    struct {
		Command string   `json:"command"`
		Type    string   `json:"type"`
		Queries []string `json:"queries"`
		URL     string   `json:"url"`
	} `json:"action"`
	Output  json.RawMessage `json:"output"`
	Summary json.RawMessage `json:"summary"`
	Text    string          `json:"text"`
	Message string          `json:"message"`
	Error   json.RawMessage `json:"error"`
	Status  string          `json:"status"`
	Item    struct {
		Type    string          `json:"type"`
		Content json.RawMessage `json:"content"`
	} `json:"item"`
	Info struct {
		Model           string          `json:"model"`
		LastTokenUsage  json.RawMessage `json:"last_token_usage"`
		TotalTokenUsage json.RawMessage `json:"total_token_usage"`
	} `json:"info"`
}

func (p *codexParser) parseCodex(line []byte) []api.AgentEvent {
	var record codexRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	event := api.AgentEvent{
		Provider:  "codex",
		Timestamp: parseTimestamp(record.Timestamp),
	}
	switch record.Type {
	case "session_meta":
		return nil
	case "turn_context":
		var payload codexPayload
		if json.Unmarshal(record.Payload, &payload) != nil || payload.Model == "" || payload.Model == p.codexModel {
			return nil
		}
		p.codexModel = payload.Model
		return nil
	case "compacted":
		event.Type = "compaction"
		return []api.AgentEvent{event}
	case "response_item":
		var payload codexPayload
		if json.Unmarshal(record.Payload, &payload) != nil {
			event.Type = "unknown"
			event.Content = p.clip(string(record.Payload))
			return []api.AgentEvent{event}
		}
		if structured := projectStructuredAgentEvent("codex", payload.Type, record.Payload, event.Timestamp); structured != nil {
			return []api.AgentEvent{*structured}
		}
		switch payload.Type {
		case "message":
			event.ID = payload.ID
			switch payload.Role {
			case "user":
				event.Type = "user"
			case "developer":
				event.Type = "system_instructions"
			default:
				event.Type = "assistant"
				event.Model = p.codexModel
			}
			event.Content = p.content(payload.Content)
			if event.Content == "" {
				return nil
			}
			if event.Type == "assistant" {
				if event.Content == p.lastAssistantContent {
					return nil
				}
				p.lastAssistantContent = event.Content
			}
			if event.Type == "user" {
				if isSystemInjectedUserContext(event.Content) {
					event.Type = "system_instructions"
				} else {
					p.lastUserContent = event.Content
				}
			}
			if event.Type == "system_instructions" && strings.HasPrefix(event.Content, "Approved command prefix saved") {
				return nil
			}
			p.lastEventType = event.Type
			return []api.AgentEvent{event}
		case "reasoning":
			event.ID = payload.ID
			event.Type = "reasoning"
			event.Content = codexReasoningContent(payload, p.contentLimit)
			if event.Content == "" {
				return nil
			}
			if event.Content == p.lastReasoningContent {
				return nil
			}
			p.lastReasoningContent = event.Content
			p.lastEventType = "reasoning"
			return []api.AgentEvent{event}
		case "function_call", "local_shell_call":
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = canonicalToolName("codex", payload.Name)
			event.CallID = payload.CallID
			if event.ToolName == "" && payload.Type == "local_shell_call" {
				event.ToolName = "shell"
			}
			if payload.Arguments != "" {
				event.ToolInput = parseArguments(payload.Arguments, p.contentLimit)
			} else if payload.Action.Command != "" {
				event.ToolInput = map[string]any{"command": payload.Action.Command}
			}
			event.Files = codexFiles(payload.Arguments, event.ToolName)
			if event.CallID != "" {
				p.codexCallTool[event.CallID] = event.ToolName
			}
			p.lastEventType = "tool_call"
			return []api.AgentEvent{event}
		case "function_call_output", "custom_tool_call_output":
			event.ID = payload.ID
			event.Type = "tool_output"
			event.CallID = payload.CallID
			event.ToolName = p.codexCallTool[event.CallID]
			event.Output, event.ToolStatus, event.Error = codexOutputDetails(payload.Output, p.contentLimit)
			if event.Output == "" {
				return nil
			}
			p.lastEventType = "tool_output"
			return []api.AgentEvent{event}
		case "web_search_call":
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = "web_search"
			event.CallID = payload.ID
			event.ToolStatus = normalizeToolStatus(payload.Status)
			input := map[string]any{"type": payload.Action.Type}
			if len(payload.Action.Queries) > 0 {
				input["queries"] = payload.Action.Queries
			}
			if payload.Action.URL != "" {
				input["url"] = payload.Action.URL
			}
			event.ToolInput = input
			p.lastEventType = "tool_call"
			return []api.AgentEvent{event}
		case "custom_tool_call":
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = canonicalToolName("codex", payload.Name)
			if event.ToolName == "" {
				event.ToolName = "custom_tool"
			}
			event.CallID = payload.CallID
			event.ToolStatus = normalizeToolStatus(payload.Status)
			event.ToolInput = codexCustomToolInput(payload.Input, event.ToolName, p.contentLimit)
			event.Files = codexFilesFromRaw(payload.Input, event.ToolName)
			if event.CallID != "" {
				p.codexCallTool[event.CallID] = event.ToolName
			}
			p.lastEventType = "tool_call"
			return []api.AgentEvent{event}
		default:
			event.Type = "unknown"
			event.ID = payload.ID
			event.Content = codexFallbackContent(payload, record.Payload, p.contentLimit)
			return []api.AgentEvent{event}
		}
	case "event_msg":
		var payload codexPayload
		if json.Unmarshal(record.Payload, &payload) != nil {
			return nil
		}
		if structured := projectStructuredAgentEvent("codex", payload.Type, record.Payload, event.Timestamp); structured != nil {
			return []api.AgentEvent{*structured}
		}
		switch payload.Type {
		case "token_count":
			event.Type = "usage"
			event.Model = payload.Info.Model
			if event.Model == "" {
				event.Model = p.codexModel
			}
			raw := payload.Info.LastTokenUsage
			if len(raw) == 0 {
				raw = payload.Info.TotalTokenUsage
			}
			event.Usage = parseUsage(raw)
			if event.Usage == nil {
				return nil
			}
			event.Content = "Token usage"
			return []api.AgentEvent{event}
		case "turn_aborted":
			p.tracker.TurnAborted()
			p.codexTurnFailed = false
			return nil
		case "error":
			message := codexErrorMessage(payload, p.contentLimit)
			if message == "" {
				return nil
			}
			p.tracker.TurnFailed()
			p.codexTurnFailed = true
			event.Type = "error"
			event.Content = p.clip(message)
			event.Error = event.Content
			return []api.AgentEvent{event}
		case "agent_message":
			content := p.clip(firstNonEmpty(payload.Message, p.content(payload.Content), payload.Text))
			if content == "" {
				return nil
			}
			if content == p.lastAssistantContent {
				return nil
			}
			p.lastAssistantContent = content
			event.Type = "assistant"
			event.Model = p.codexModel
			event.Content = content
			p.lastEventType = "assistant"
			return []api.AgentEvent{event}
		case "agent_reasoning":
			content := p.clip(firstNonEmpty(payload.Text, p.content(payload.Summary), p.content(payload.Content)))
			if content == "" {
				return nil
			}
			if content == p.lastReasoningContent {
				return nil
			}
			p.lastReasoningContent = content
			event.Type = "reasoning"
			event.Content = content
			p.lastEventType = "reasoning"
			return []api.AgentEvent{event}
		case "task_started":
			p.codexTurnFailed = false
			p.tracker.TurnStarted()
			return nil
		case "task_complete":
			if p.codexTurnFailed {
				p.codexTurnFailed = false
				p.tracker.TurnFailed()
				return nil
			}
			if message := codexErrorMessage(payload, p.contentLimit); message != "" {
				p.codexTurnFailed = true
				p.tracker.TurnFailed()
				event.Type = "error"
				event.Content = p.clip(message)
				event.Error = event.Content
				return []api.AgentEvent{event}
			}
			p.tracker.TurnComplete()
			return nil
		case "thread_settings_applied":
			return nil
		default:
			if payload.Type == "user_message" {
				content := p.content(payload.Content)
				if content == "" || content == p.lastUserContent {
					return nil
				}
				p.lastUserContent = content
				event.Type = "user"
				event.Content = content
				p.lastEventType = "user"
				return []api.AgentEvent{event}
			}
			return nil
		}
	default:
		return nil
	}
}

func codexErrorMessage(payload codexPayload, limit int) string {
	if payload.Message != "" {
		return payload.Message
	}
	if payload.Text != "" {
		return payload.Text
	}
	if content := contentStringLimit(payload.Content, limit); content != "" {
		return content
	}
	if len(payload.Error) == 0 {
		return ""
	}
	var text string
	if json.Unmarshal(payload.Error, &text) == nil && text != "" {
		return truncate(text, limit)
	}
	var wrapper struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(payload.Error, &wrapper) == nil && wrapper.Message != "" {
		return truncate(wrapper.Message, limit)
	}
	return truncate(string(payload.Error), limit)
}

func codexFallbackContent(payload codexPayload, raw json.RawMessage, limit int) string {
	for _, candidate := range []string{
		payload.Message,
		payload.Text,
		contentStringLimit(payload.Content, limit),
		contentStringLimit(payload.Summary, limit),
	} {
		if candidate != "" {
			return truncate(candidate, limit)
		}
	}
	return truncate(string(raw), limit)
}

func normalizeToolStatus(status string) string {
	switch status {
	case "completed":
		return "success"
	case "failed":
		return "error"
	case "interrupted", "cancelled":
		return "interrupted"
	default:
		return "running"
	}
}

func isSystemInjectedUserContext(content string) bool {
	return strings.HasPrefix(content, "<environment_context>") ||
		strings.HasPrefix(content, "# AGENTS.md") ||
		strings.HasPrefix(content, "<collaboration_mode>") ||
		strings.Contains(content, "<permissions instructions>")
}

func codexReasoningContent(payload codexPayload, limit int) string {
	if value := contentStringLimit(payload.Summary, limit); value != "" {
		return value
	}
	if value := contentStringLimit(payload.Content, limit); value != "" {
		return value
	}
	return truncate(payload.Text, limit)
}

func codexOutputString(value json.RawMessage, limit int) string {
	var text string
	if json.Unmarshal(value, &text) == nil {
		return truncate(text, limit)
	}
	if value := contentStringLimit(value, limit); value != "" {
		return value
	}
	return truncate(string(value), limit)
}

func codexOutputDetails(value json.RawMessage, limit int) (output, status, errorMessage string) {
	var text string
	if json.Unmarshal(value, &text) == nil {
		output, status, errorMessage = codexOutputDetails([]byte(text), limit)
		if status != "" || errorMessage != "" {
			return output, status, errorMessage
		}
		if output != "" {
			return truncate(text, limit), "success", ""
		}
		return truncate(text, limit), "success", ""
	}
	var wrapper struct {
		Output   string `json:"output"`
		Error    string `json:"error"`
		IsError  bool   `json:"is_error"`
		Metadata struct {
			ExitCode int    `json:"exit_code"`
			Error    string `json:"error"`
		} `json:"metadata"`
	}
	if json.Unmarshal(value, &wrapper) == nil {
		output = truncate(wrapper.Output, limit)
		if output == "" {
			output = contentStringLimit(value, limit)
		}
		switch {
		case wrapper.Error != "":
			errorMessage = wrapper.Error
			status = "error"
		case wrapper.IsError:
			status = "error"
		case wrapper.Metadata.ExitCode != 0:
			errorMessage = wrapper.Metadata.Error
			status = "error"
		default:
			status = "success"
		}
		return output, status, truncate(errorMessage, limit)
	}
	return contentStringLimit(value, limit), "success", ""
}

func parseArguments(value string, limit int) any {
	var parsed map[string]any
	if json.Unmarshal([]byte(value), &parsed) == nil {
		return parsed
	}
	return map[string]any{"raw": truncate(value, rawToolInputLimit(limit))}
}

func codexFiles(arguments, toolName string) []string {
	var files []string
	var parsed map[string]any
	if json.Unmarshal([]byte(arguments), &parsed) == nil {
		if path, ok := parsed["file_path"].(string); ok && path != "" {
			files = append(files, path)
		}
		if toolName == "apply_patch" {
			if patch, ok := parsed["patch"].(string); ok {
				files = append(files, patchFiles(patch)...)
			}
		}
	}
	return uniqueStrings(files)
}

func codexCustomToolInput(value json.RawMessage, toolName string, limit int) any {
	var parsed any
	if json.Unmarshal(value, &parsed) != nil {
		return map[string]any{"raw": truncate(string(value), rawToolInputLimit(limit))}
	}
	switch input := parsed.(type) {
	case string:
		if toolName == "apply_patch" {
			return map[string]any{"patch": truncate(input, rawToolInputLimit(limit))}
		}
		return map[string]any{"raw": truncate(input, rawToolInputLimit(limit))}
	default:
		return input
	}
}

func codexFilesFromRaw(value json.RawMessage, toolName string) []string {
	var parsed any
	if json.Unmarshal(value, &parsed) != nil {
		return nil
	}
	switch input := parsed.(type) {
	case string:
		if toolName == "apply_patch" {
			return patchFiles(input)
		}
	case map[string]any:
		if path, ok := input["file_path"].(string); ok && path != "" {
			return []string{path}
		}
		if toolName == "apply_patch" {
			if patch, ok := input["patch"].(string); ok {
				return patchFiles(patch)
			}
		}
	}
	return nil
}

func patchFiles(patch string) []string {
	var files []string
	for _, line := range strings.Split(patch, "\n") {
		for _, marker := range []string{"*** Add File: ", "*** Update File: ", "*** Delete File: "} {
			if strings.HasPrefix(line, marker) {
				if name := strings.TrimSpace(strings.TrimPrefix(line, marker)); name != "" {
					files = append(files, name)
				}
				break
			}
		}
	}
	return uniqueStrings(files)
}
