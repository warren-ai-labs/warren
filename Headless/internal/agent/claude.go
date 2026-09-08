package agent

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type claudeParser struct {
	baseParser
	claudeCallTool     map[string]string
	claudeInteractions map[string]string
}

func newClaudeParser(contentLimit int) *claudeParser {
	return &claudeParser{
		baseParser:         newBaseParser(contentLimit),
		claudeCallTool:     make(map[string]string),
		claudeInteractions: make(map[string]string),
	}
}

func (p *claudeParser) Parse(line []byte) []api.AgentEvent {
	return p.observe(p.parseClaude(line))
}

func (p *claudeParser) parse(line []byte) []api.AgentEvent {
	return p.Parse(line)
}

type claudeRecord struct {
	Type             string          `json:"type"`
	Subtype          string          `json:"subtype"`
	Timestamp        string          `json:"timestamp"`
	UUID             string          `json:"uuid"`
	SessionID        string          `json:"sessionId"`
	DurationMs       int64           `json:"durationMs"`
	IsSidechain      bool            `json:"isSidechain"`
	IsMeta           bool            `json:"isMeta"`
	IsCompactSummary bool            `json:"isCompactSummary"`
	Content          json.RawMessage `json:"content"`
	Message          struct {
		ID         string          `json:"id"`
		Role       string          `json:"role"`
		Model      string          `json:"model"`
		StopReason string          `json:"stop_reason"`
		Content    json.RawMessage `json:"content"`
		Usage      json.RawMessage `json:"usage"`
	} `json:"message"`
	ToolUseResult struct {
		FilePath        string          `json:"filePath"`
		StructuredPatch json.RawMessage `json:"structuredPatch"`
		Interrupted     bool            `json:"interrupted"`
	} `json:"toolUseResult"`
	ToolName   string          `json:"tool_name"`
	ToolInput  json.RawMessage `json:"tool_input"`
	ToolOutput json.RawMessage `json:"tool_output"`
	Attachment struct {
		Type      string          `json:"type"`
		HookName  string          `json:"hookName"`
		HookEvent string          `json:"hookEvent"`
		Prompt    string          `json:"prompt"`
		Content   json.RawMessage `json:"content"`
		ExitCode  int             `json:"exitCode"`
	} `json:"attachment"`
}

type claudeBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	Name      string          `json:"name"`
	ID        string          `json:"id"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

func (p *claudeParser) parseClaude(line []byte) []api.AgentEvent {
	var record claudeRecord
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	timestamp := parseTimestamp(record.Timestamp)
	if structured := projectStructuredAgentEvent("claude", record.Type, line, timestamp); structured != nil {
		if structured.ID == "" {
			structured.ID = record.UUID
		}
		return []api.AgentEvent{*structured}
	}
	switch record.Type {
	case "summary", "last-prompt", "ai-title", "pr-link", "queue-operation",
		"permission-mode", "mode", "file-history-snapshot":
		return nil
	case "user":
		var blocks []claudeBlock
		if json.Unmarshal(record.Message.Content, &blocks) == nil {
			var events []api.AgentEvent
			sawToolResult := false
			for _, block := range blocks {
				if block.Type != "tool_result" {
					continue
				}
				sawToolResult = true
				if kind := p.claudeInteractions[block.ToolUseID]; kind != "" {
					delete(p.claudeInteractions, block.ToolUseID)
					if kind == "question" || kind == "permission" {
						p.tracker.MarkAttention("", "", "", time.Time{})
						state := "resolved"
						if block.IsError {
							state = "cancelled"
						}
						title := "Question"
						if kind == "permission" {
							title = "Permission"
						}
						events = append(events, api.AgentEvent{
							Provider:  "claude",
							ID:        block.ToolUseID,
							Type:      kind,
							Payload:   map[string]any{"requestId": block.ToolUseID, "title": title, "state": state},
							Timestamp: timestamp,
						})
					}
					continue
				}
				output := p.content(block.Content)
				event := api.AgentEvent{
					Provider:  "claude",
					ID:        record.UUID,
					CallID:    block.ToolUseID,
					Type:      "tool_output",
					ToolName:  p.claudeCallTool[block.ToolUseID],
					Output:    output,
					Timestamp: timestamp,
				}
				if record.ToolUseResult.FilePath != "" {
					event.Files = []string{record.ToolUseResult.FilePath}
				}
				if record.ToolUseResult.Interrupted {
					event.ToolStatus = "interrupted"
				} else if block.IsError {
					event.ToolStatus = "error"
					event.Error = output
				} else {
					event.ToolStatus = "success"
				}
				if len(record.ToolUseResult.StructuredPatch) > 0 {
					var rawPatch any
					_ = json.Unmarshal(record.ToolUseResult.StructuredPatch, &rawPatch)
					var adds, dels int
					var patchText string
					if str, ok := rawPatch.(string); ok {
						patchText = str
						adds, dels = parseUnifiedDiffStats(str)
					} else {
						adds, dels, patchText = parseStructuredPatchChunks(rawPatch)
					}
					if adds > 0 || dels > 0 || patchText != "" {
						diffPayload := map[string]any{
							"file":      record.ToolUseResult.FilePath,
							"files":     []string{record.ToolUseResult.FilePath},
							"additions": adds,
							"deletions": dels,
							"diff":      patchText,
							"callId":    block.ToolUseID,
						}
						if event.Payload == nil {
							event.Payload = make(map[string]any)
						}
						event.Payload["diff"] = diffPayload
						events = append(events, api.AgentEvent{
							Provider:  "claude",
							ID:        record.UUID,
							Type:      "diff",
							Payload:   diffPayload,
							Timestamp: timestamp,
						})
					}
				}
				events = append(events, event)
			}
			if sawToolResult {
				return events
			}
		}
		content := p.content(record.Message.Content)
		if content == "" {
			return nil
		}
		if strings.HasPrefix(strings.TrimSpace(content), "[Request interrupted") {
			p.tracker.TurnInterrupted()
			return []api.AgentEvent{{
				Provider:   "claude",
				ID:         record.UUID,
				Type:       "system",
				Content:    p.clip(content),
				StopReason: "interrupted",
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}}
		}
		if record.IsCompactSummary || isCompactionContext(content) {
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "compaction",
				Role:      "system",
				Content:   p.clip(content),
				Payload: map[string]any{
					"compactionId": record.UUID,
					"summary":      "History compacted",
				},
				Timestamp: timestamp,
			}}
		}
		if record.IsMeta || strings.HasPrefix(strings.TrimSpace(content), "<") || isSystemInjectedUserContext(content) {
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "system",
				Role:      "system",
				Content:   p.clip(content),
				Timestamp: timestamp,
			}}
		}
		return []api.AgentEvent{{
			Provider:  "claude",
			ID:        record.UUID,
			Type:      "user",
			Role:      "user",
			Content:   p.clip(content),
			Sidechain: record.IsSidechain,
			Timestamp: timestamp,
		}}
	case "assistant":
		var blocks []claudeBlock
		if json.Unmarshal(record.Message.Content, &blocks) != nil {
			content := p.content(record.Message.Content)
			if content == "" {
				return nil
			}
			return []api.AgentEvent{{
				Provider:   "claude",
				ID:         record.UUID,
				Type:       "assistant",
				Content:    p.clip(content),
				Model:      record.Message.Model,
				StopReason: record.Message.StopReason,
				Usage:      parseUsage(record.Message.Usage),
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}}
		}
		var events []api.AgentEvent
		for _, block := range blocks {
			event := api.AgentEvent{
				Provider:   "claude",
				ID:         firstNonEmpty(block.ID, record.UUID),
				Model:      record.Message.Model,
				StopReason: record.Message.StopReason,
				Usage:      parseUsage(record.Message.Usage),
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}
			switch block.Type {
			case "text":
				if record.IsSidechain {
					event.Type = "subagent"
					event.Payload = map[string]any{
						"subagentId": record.UUID,
						"label":      "Subagent",
						"state":      "completed",
						"summary":    p.clip(block.Text),
					}
				} else {
					event.Type = "assistant"
					event.Content = p.clip(block.Text)
				}
			case "thinking", "redacted_thinking":
				event.Type = "reasoning"
				event.Content = p.clip(firstNonEmpty(block.Thinking, "…"))
			case "tool_use":
				canonicalName := canonicalToolName("claude", block.Name)
				switch canonicalName {
				case "ask_user_question":
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					event.Type = "question"
					event.Payload = claudeQuestionPayload(block.ID, input)
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "question"
						p.tracker.MarkAttention(api.AgentAttentionInput, "question", block.ID, event.Timestamp)
					}
				case "permission_request":
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					event.Type = "permission"
					event.Payload = claudePermissionPayload(block.ID, input)
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "permission"
						p.tracker.MarkAttention(api.AgentAttentionApproval, "permission", block.ID, event.Timestamp)
					}
				case "todowrite":
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					event.Type = "todo"
					event.ID = "claude-todos"
					event.Payload = claudeTodoPayload(input)
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "todo"
					}
				default:
					event.Type = "tool_call"
					event.ToolName = canonicalName
					event.CallID = block.ID
					event.ToolInput = rawToAny(block.Input, p.contentLimit)
					if event.ToolName != "" && event.CallID != "" {
						p.claudeCallTool[event.CallID] = event.ToolName
					}
					if input, ok := event.ToolInput.(map[string]any); ok {
						if path, ok := input["file_path"].(string); ok && path != "" {
							event.Files = []string{path}
						}
					}
				}
			default:
				event.Type = "unknown"
				event.Content = p.clip(firstNonEmpty(block.Text, block.Thinking, p.content(block.Content), string(record.Message.Content)))
			}
			if event.Content != "" || event.ToolName != "" || event.Payload != nil {
				events = append(events, event)
			}
		}
		return events
	case "system":
		content := p.content(record.Content)
		if content == "" {
			return nil
		}
		if record.Subtype == "api_error" {
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "error",
				Content:   p.clip(content),
				Error:     p.clip(content),
				Timestamp: timestamp,
			}}
		}
		return []api.AgentEvent{{
			Provider:   "claude",
			ID:         record.UUID,
			Type:       "system",
			Content:    p.clip(content),
			DurationMs: record.DurationMs,
			Timestamp:  timestamp,
		}}
	case "attachment":
		kind := record.Attachment.Type
		if kind == "" {
			kind = "attachment"
		}
		if strings.HasPrefix(kind, "hook_") {
			return nil
		}
		if kind == "queued_command" {
			prompt := firstNonEmpty(record.Attachment.Prompt, p.content(record.Attachment.Content), p.content(record.Content))
			payload := map[string]any{
				"action":  "enqueue",
				"content": prompt,
				"prompt":  prompt,
				"state":   "queued",
			}
			if record.SessionID != "" {
				payload["sessionId"] = record.SessionID
			}
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "queue",
				Payload:   payload,
				Timestamp: timestamp,
			}}
		}
		if kind == "agent_listing_delta" || kind == "skill_listing" {
			content := p.content(record.Attachment.Content)
			if content == "" {
				return nil
			}
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "system_instructions",
				Content:   content,
				Timestamp: timestamp,
			}}
		}
		content := p.clip(firstNonEmpty(p.content(record.Attachment.Content), p.content(record.Content)))
		if content == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  "claude",
			ID:        record.UUID,
			Type:      "attachment",
			Content:   content,
			Timestamp: timestamp,
		}}
	case "tool_use":
		canonicalName := canonicalToolName("claude", record.ToolName)
		input, _ := rawToAny(record.ToolInput, p.contentLimit).(map[string]any)
		event := api.AgentEvent{
			Provider:   "claude",
			ID:         record.UUID,
			Type:       "tool_call",
			ToolName:   canonicalName,
			ToolInput:  input,
			ToolStatus: "running",
			Timestamp:  timestamp,
		}
		if input != nil {
			if fp := stringValue(input["filePath"]); fp != "" {
				event.Files = []string{fp}
			}
		}
		return []api.AgentEvent{event}
	case "tool_result":
		var to map[string]any
		_ = json.Unmarshal(record.ToolOutput, &to)
		canonicalName := canonicalToolName("claude", record.ToolName)
		output := stringValue(to["output"])
		if output == "" {
			output = p.content(record.ToolOutput)
		}
		event := api.AgentEvent{
			Provider:   "claude",
			ID:         record.UUID,
			Type:       "tool_output",
			ToolName:   canonicalName,
			Output:     p.clip(output),
			ToolStatus: "success",
			Timestamp:  timestamp,
		}
		if to != nil {
			if fp := stringValue(to["filepath"]); fp != "" {
				event.Files = []string{fp}
			}
			if asBool(to["is_error"]) {
				event.ToolStatus = "error"
				event.Error = event.Output
			}
		}
		var events []api.AgentEvent
		events = append(events, event)

		if to != nil {
			diffStr := stringValue(to["diff"])
			fd, _ := to["filediff"].(map[string]any)
			var adds, dels int
			var targetFile string
			if fd != nil {
				targetFile = stringValue(fd["file"])
				adds = intValue(fd["additions"])
				dels = intValue(fd["deletions"])
			}
			if targetFile == "" && len(event.Files) > 0 {
				targetFile = event.Files[0]
			}
			if diffStr != "" && adds == 0 && dels == 0 {
				adds, dels = parseUnifiedDiffStats(diffStr)
			}
			if diffStr != "" || adds > 0 || dels > 0 {
				diffPayload := map[string]any{
					"file":      targetFile,
					"files":     []string{targetFile},
					"additions": adds,
					"deletions": dels,
					"diff":      diffStr,
				}
				if event.Payload == nil {
					event.Payload = make(map[string]any)
				}
				event.Payload["diff"] = diffPayload
				events = append(events, api.AgentEvent{
					Provider:  "claude",
					ID:        record.UUID,
					Type:      "diff",
					Payload:   diffPayload,
					Timestamp: timestamp,
				})
			}

			if rawDiag := to["diagnostics"]; rawDiag != nil {
				diags := parseClaudeDiagnostics(rawDiag)
				if len(diags) > 0 {
					diagPayload := map[string]any{
						"diagnostics": diags,
					}
					if len(event.Files) > 0 {
						diagPayload["file"] = event.Files[0]
					}
					if event.Payload == nil {
						event.Payload = make(map[string]any)
					}
					event.Payload["diagnostics"] = diagPayload
					events = append(events, api.AgentEvent{
						Provider:  "claude",
						ID:        record.UUID,
						Type:      "diagnostics",
						Payload:   diagPayload,
						Timestamp: timestamp,
					})
				}
			}
		}
		return events
	default:
		return nil
	}
}

func claudeQuestionPayload(requestID string, input map[string]any) map[string]any {
	questions := make([]any, 0)
	if raw, ok := input["questions"].([]any); ok {
		for index, item := range raw {
			question, ok := item.(map[string]any)
			if !ok {
				continue
			}
			prompt := firstNonEmpty(stringValue(question["question"]), stringValue(question["header"]), "Question")
			selection := "single"
			if asBool(question["multiSelect"]) {
				selection = "multiple"
			}
			options := make([]any, 0)
			if rawOptions, ok := question["options"].([]any); ok {
				for optionIndex, optionItem := range rawOptions {
					option, ok := optionItem.(map[string]any)
					if !ok {
						continue
					}
					entry := map[string]any{
						"id":    firstNonEmpty(stringValue(option["label"]), fmt.Sprintf("option-%d", optionIndex)),
						"label": stringValue(option["label"]),
					}
					if description := stringValue(option["description"]); description != "" {
						entry["description"] = description
					}
					options = append(options, entry)
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
	}
	return map[string]any{
		"requestId": requestID,
		"title":     "Question",
		"questions": questions,
		"state":     "pending",
	}
}

func claudePermissionPayload(requestID string, input map[string]any) map[string]any {
	action := stringValue(input["tool"])
	if action == "" {
		action = "tool"
	}
	return map[string]any{
		"requestId":   requestID,
		"title":       "Permission",
		"action":      action,
		"description": "Claude requests permission to run " + action,
		"options": []any{
			map[string]any{"id": "allow", "label": "Allow"},
			map[string]any{"id": "deny", "label": "Deny"},
			map[string]any{"id": "allow_always", "label": "Always allow"},
			map[string]any{"id": "deny_always", "label": "Always deny"},
		},
		"state": "pending",
	}
}

func claudeTodoPayload(input map[string]any) map[string]any {
	items := make([]any, 0)
	if raw, ok := input["todos"].([]any); ok {
		for _, item := range raw {
			todo, ok := item.(map[string]any)
			if !ok {
				continue
			}
			state := strings.ToLower(firstNonEmpty(stringValue(todo["status"]), "pending"))
			items = append(items, map[string]any{
				"label": stringValue(todo["content"]),
				"state": state,
			})
		}
	}
	overall := "completed"
	for _, item := range items {
		if todo, ok := item.(map[string]any); ok {
			if state := stringValue(todo["state"]); state != "completed" && state != "cancelled" {
				overall = "in_progress"
				break
			}
		}
	}
	return map[string]any{
		"todoId": "claude-todos",
		"title":  "Todos",
		"items":  items,
		"state":  overall,
	}
}
