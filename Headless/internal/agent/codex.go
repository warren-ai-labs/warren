package agent

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type codexParser struct {
	baseParser
	codexModel           string
	codexEffort          string
	codexCallTool        map[string]string
	codexGoalCalls       map[string]string
	codexInteractions    map[string]string
	codexTurnFailed      bool
	lastUserContent      string
	lastAssistantContent string
	lastReasoningContent string
	lastEventType        string

	threadID               string
	queueDBPath            string
	lastQueuedItemIDs      map[string]struct{}
	lastQueuedFingerprints map[string]string
}

func newCodexParser(contentLimit int) *codexParser {
	return &codexParser{
		baseParser:             newBaseParser(contentLimit),
		codexCallTool:          make(map[string]string),
		codexGoalCalls:         make(map[string]string),
		codexInteractions:      make(map[string]string),
		lastQueuedItemIDs:      make(map[string]struct{}),
		lastQueuedFingerprints: make(map[string]string),
	}
}

func (p *codexParser) SetThreadID(id string) {
	p.threadID = id
}

func (p *codexParser) SetQueueDBPath(path string) {
	p.queueDBPath = path
}

func (p *codexParser) PollEvents() []api.AgentEvent {
	if p.threadID == "" {
		return nil
	}
	items, err := readCodexQueuedItems(p.queueDBPath, p.threadID)
	if err != nil {
		return nil
	}
	if len(items) == 0 && len(p.lastQueuedItemIDs) == 0 {
		return nil
	}
	currentIDs := make(map[string]struct{}, len(items))
	currentFingerprints := make(map[string]string, len(items))
	var events []api.AgentEvent
	for _, item := range items {
		timestamp := item.CreatedAt
		currentIDs[item.ID] = struct{}{}
		fingerprint := queuedItemFingerprint(item)
		currentFingerprints[item.ID] = fingerprint
		previousFingerprint, exists := p.lastQueuedFingerprints[item.ID]
		if !exists {
			payload := map[string]any{
				"action":    "enqueue",
				"queueId":   item.ID,
				"content":   item.Content,
				"prompt":    item.Prompt,
				"order":     item.Order,
				"state":     "queued",
				"sessionId": item.SessionID,
			}
			if len(item.Attachments) > 0 {
				payload["attachments"] = item.Attachments
			}
			events = append(events, api.AgentEvent{
				Provider:  "codex",
				ID:        item.ID,
				Type:      "queue",
				Timestamp: timestamp,
				Payload:   payload,
			})
		} else if previousFingerprint != fingerprint {
			payload := map[string]any{
				"action":    "enqueue",
				"queueId":   item.ID,
				"content":   item.Content,
				"prompt":    item.Prompt,
				"order":     item.Order,
				"state":     "queued",
				"sessionId": item.SessionID,
				"updated":   true,
			}
			if len(item.Attachments) > 0 {
				payload["attachments"] = item.Attachments
			}
			events = append(events, api.AgentEvent{
				Provider:  "codex",
				ID:        item.ID,
				Type:      "queue",
				Timestamp: timestamp,
				Payload:   payload,
			})
		}
	}
	removedIDs := make([]string, 0)
	for oldID := range p.lastQueuedItemIDs {
		if _, exists := currentIDs[oldID]; !exists {
			removedIDs = append(removedIDs, oldID)
		}
	}
	sort.Strings(removedIDs)
	for _, oldID := range removedIDs {
		events = append(events, api.AgentEvent{
			Provider:  "codex",
			ID:        oldID,
			Type:      "queue",
			Timestamp: time.Now(),
			Payload: map[string]any{
				"action":    "dequeue",
				"queueId":   oldID,
				"state":     "dequeued",
				"sessionId": p.threadID,
			},
		})
	}
	p.lastQueuedItemIDs = currentIDs
	p.lastQueuedFingerprints = currentFingerprints
	return p.observe(events)
}

func queuedItemFingerprint(item api.AgentQueueItem) string {
	value := struct {
		Content     string                   `json:"content"`
		Prompt      string                   `json:"prompt"`
		Order       int                      `json:"order"`
		Attachments []api.AgentAttachmentRef `json:"attachments,omitempty"`
	}{item.Content, item.Prompt, item.Order, item.Attachments}
	encoded, _ := json.Marshal(value)
	return string(encoded)
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
	Plan []struct {
		Step   string `json:"step"`
		Status string `json:"status"`
	} `json:"plan"`
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
		var meta struct {
			ID        string `json:"id"`
			SessionID string `json:"session_id"`
			ThreadID  string `json:"thread_id"`
		}
		if json.Unmarshal(record.Payload, &meta) == nil {
			if threadID := firstNonEmpty(meta.ID, meta.SessionID, meta.ThreadID); threadID != "" {
				p.threadID = threadID
			}
		}
		return nil
	case "turn_context":
		var payload struct {
			Model  string `json:"model"`
			Effort string `json:"effort"`
		}
		if json.Unmarshal(record.Payload, &payload) != nil {
			return nil
		}
		changed := false
		if payload.Model != "" && payload.Model != p.codexModel {
			p.codexModel = payload.Model
			changed = true
		}
		if payload.Effort != "" && payload.Effort != p.codexEffort {
			p.codexEffort = payload.Effort
			changed = true
		}
		if changed {
			event.Type = "config"
			event.Payload = map[string]any{
				"model":           p.codexModel,
				"reasoningEffort": p.codexEffort,
			}
			return []api.AgentEvent{event}
		}
		return nil
	case "compacted":
		event.Type = "compaction"
		event.Role = "system"
		event.Content = "History compacted"
		if event.Payload == nil {
			event.Payload = map[string]any{
				"compactionId": firstNonEmpty(event.ID, "codex-compaction"),
				"summary":      "History compacted",
			}
		}
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
				if isCompactionContext(event.Content) {
					event.Type = "compaction"
					event.Role = "system"
					event.Content = "History compacted"
					if event.Payload == nil {
						event.Payload = map[string]any{
							"compactionId": firstNonEmpty(event.ID, "codex-compaction"),
							"summary":      "History compacted",
						}
					}
				} else if isSystemInjectedUserContext(event.Content) {
					event.Type = "system_instructions"
					event.Role = "system"
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
			canonical := canonicalToolName("codex", payload.Name)
			if canonical == "ask_user_question" {
				callID := firstNonEmpty(payload.CallID, payload.ID)
				event.ID = callID
				event.Type = "question"
				event.Payload = codexQuestionPayload(callID, payload.Arguments, p.contentLimit)
				if callID != "" {
					p.codexInteractions[callID] = "question"
				}
				p.tracker.MarkAttention(api.AgentAttentionInput, "question", callID, event.Timestamp)
				return []api.AgentEvent{event}
			}
			if payload.Name == "exec_approval_request" || payload.Name == "apply_patch_approval_request" || payload.Name == "approval_request" {
				callID := firstNonEmpty(payload.CallID, payload.ID)
				event.ID = callID
				event.Type = "permission"
				event.Payload = map[string]any{
					"requestId":   callID,
					"title":       "Permission",
					"action":      payload.Name,
					"description": "Codex requests permission to proceed",
					"options": []any{
						map[string]any{"id": "allow", "label": "Allow"},
						map[string]any{"id": "deny", "label": "Deny"},
					},
					"state": "pending",
				}
				if callID != "" {
					p.codexInteractions[callID] = "permission"
				}
				p.tracker.MarkAttention(api.AgentAttentionApproval, "permission", callID, event.Timestamp)
				return []api.AgentEvent{event}
			}
			if payload.Name == "update_plan" {
				var planArgs struct {
					Plan []struct {
						Step   string `json:"step"`
						Status string `json:"status"`
					} `json:"plan"`
				}
				if json.Unmarshal([]byte(payload.Arguments), &planArgs) == nil && len(planArgs.Plan) > 0 {
					items := make([]map[string]any, len(planArgs.Plan))
					for i, item := range planArgs.Plan {
						items[i] = map[string]any{
							"id":    fmt.Sprintf("step-%d", i),
							"title": item.Step,
							"label": item.Step,
							"state": canonicalStepStatus(item.Status),
						}
					}
					event.ID = "codex-plan"
					event.Type = "plan"
					event.Payload = map[string]any{
						"planId": "codex-plan",
						"title":  "Plan",
						"state":  calculatePlanState(items),
						"items":  items,
					}
					return []api.AgentEvent{event}
				}
			}
			if payload.Name == "spawn_agent" {
				var spawnArgs struct {
					AgentType string `json:"agent_type"`
					Prompt    string `json:"prompt"`
					Message   string `json:"message"`
				}
				_ = json.Unmarshal([]byte(payload.Arguments), &spawnArgs)
				label := spawnArgs.AgentType
				if label == "" {
					label = "Subagent"
				}
				summary := spawnArgs.Prompt
				if summary == "" {
					summary = spawnArgs.Message
				}
				event.ID = firstNonEmpty(payload.CallID, payload.ID)
				event.Type = "subagent"
				event.Payload = map[string]any{
					"subagentId": event.ID,
					"title":      label,
					"label":      label,
					"state":      "running",
					"summary":    p.clip(summary),
				}
				return []api.AgentEvent{event}
			}
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = canonical
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
				if operation := codexGoalOperation(payload.Name, payload.Arguments, nil); operation != "" {
					p.codexGoalCalls[event.CallID] = operation
				}
			}
			p.lastEventType = "tool_call"
			return []api.AgentEvent{event}
		case "function_call_output", "custom_tool_call_output":
			if kind := p.codexInteractions[payload.CallID]; kind != "" {
				output, _, outputError := codexOutputDetails(payload.Output, p.contentLimit)
				if kind == "question" && codexUnavailableUserInput(output, outputError) {
					// The CLI can record a request_user_input call even when this
					// execution mode has no request_user_input tool. Do not turn the
					// resulting diagnostic into a false “Question · Answered” card.
					delete(p.codexInteractions, payload.CallID)
					p.tracker.MarkAttention("", "", "", time.Time{})
					event.ID = payload.ID
					event.Type = "tool_output"
					event.CallID = payload.CallID
					event.ToolName = "ask_user_question"
					event.Output = p.clip(output)
					event.Error = p.clip(firstNonEmpty(outputError, output))
					event.ToolStatus = "error"
					if event.Output == "" && event.Error == "" {
						return nil
					}
					return []api.AgentEvent{event}
				}
				delete(p.codexInteractions, payload.CallID)
				p.tracker.MarkAttention("", "", "", time.Time{})
				title := "Question"
				if kind == "permission" {
					title = "Permission"
				}
				event.ID = payload.CallID
				event.Type = kind
				event.Payload = map[string]any{
					"requestId": payload.CallID,
					"title":     title,
					"state":     "resolved",
				}
				if kind == "question" {
					if response := codexQuestionResponse(output, p.contentLimit); response != nil {
						event.Payload["response"] = response
					}
				}
				return []api.AgentEvent{event}
			}
			if codexGoalToolName(p.codexCallTool[payload.CallID]) || p.codexGoalCalls[payload.CallID] != "" {
				if goal := parseCodexGoalOutput(payload.Output, event, p.threadID, p.contentLimit); goal != nil {
					delete(p.codexGoalCalls, payload.CallID)
					return []api.AgentEvent{*goal}
				}
				delete(p.codexGoalCalls, payload.CallID)
			}
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
			canonical := canonicalToolName("codex", payload.Name)
			if canonical == "ask_user_question" {
				callID := firstNonEmpty(payload.CallID, payload.ID)
				event.ID = callID
				event.Type = "question"
				var rawArgs string
				if len(payload.Input) > 0 {
					rawArgs = string(payload.Input)
				}
				event.Payload = codexQuestionPayload(callID, rawArgs, p.contentLimit)
				if callID != "" {
					p.codexInteractions[callID] = "question"
				}
				p.tracker.MarkAttention(api.AgentAttentionInput, "question", callID, event.Timestamp)
				return []api.AgentEvent{event}
			}
			event.ID = payload.ID
			event.Type = "tool_call"
			event.ToolName = canonical
			if event.ToolName == "" {
				event.ToolName = "custom_tool"
			}
			event.CallID = payload.CallID
			event.ToolStatus = normalizeToolStatus(payload.Status)
			event.ToolInput = codexCustomToolInput(payload.Input, event.ToolName, p.contentLimit)
			event.Files = codexFilesFromRaw(payload.Input, event.ToolName)
			if event.CallID != "" {
				p.codexCallTool[event.CallID] = event.ToolName
				if operation := codexGoalOperation(payload.Name, "", payload.Input); operation != "" {
					p.codexGoalCalls[event.CallID] = operation
				}
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
		if len(payload.Plan) > 0 {
			items := make([]map[string]any, len(payload.Plan))
			for i, item := range payload.Plan {
				items[i] = map[string]any{
					"id":    fmt.Sprintf("step-%d", i),
					"title": item.Step,
					"label": item.Step,
					"state": canonicalStepStatus(item.Status),
				}
			}
			event.ID = "codex-plan"
			event.Type = "plan"
			event.Payload = map[string]any{
				"planId": "codex-plan",
				"title":  "Plan",
				"state":  calculatePlanState(items),
				"items":  items,
			}
			return []api.AgentEvent{event}
		}
		switch payload.Type {
		case "thread_goal_updated":
			return p.parseCodexGoalUpdated(record.Payload, event)
		case "thread_goal_cleared":
			var cleared struct {
				ThreadID      string `json:"thread_id"`
				ThreadIDCamel string `json:"threadId"`
			}
			if json.Unmarshal(record.Payload, &cleared) != nil {
				return nil
			}
			threadID := firstNonEmpty(cleared.ThreadID, cleared.ThreadIDCamel, p.threadID)
			if threadID == "" {
				return nil
			}
			event.ID = threadID
			event.Type = "goal"
			event.Payload = map[string]any{
				"goalId":   threadID,
				"threadId": threadID,
				"state":    "cleared",
			}
			return []api.AgentEvent{event}
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
		case "patch_apply_end":
			var data struct {
				CallID  string `json:"call_id"`
				TurnID  string `json:"turn_id"`
				Stdout  string `json:"stdout"`
				Success bool   `json:"success"`
				Changes map[string]struct {
					Type        string `json:"type"`
					UnifiedDiff string `json:"unified_diff"`
				} `json:"changes"`
			}
			if json.Unmarshal(record.Payload, &data) == nil && len(data.Changes) > 0 {
				var files []string
				var totalAdds, totalDels int
				var firstFile, firstDiff string
				for f, change := range data.Changes {
					files = append(files, f)
					if firstFile == "" {
						firstFile = f
						firstDiff = change.UnifiedDiff
					}
					adds, dels := parseUnifiedDiffStats(change.UnifiedDiff)
					totalAdds += adds
					totalDels += dels
				}
				event.Type = "diff"
				event.Files = files
				event.Payload = map[string]any{
					"file":      firstFile,
					"files":     files,
					"additions": totalAdds,
					"deletions": totalDels,
					"diff":      firstDiff,
					"callId":    data.CallID,
				}
				return []api.AgentEvent{event}
			}
			return nil
		case "turn_aborted":
			p.tracker.TurnInterrupted()
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
				if isCompactionContext(content) {
					event.Type = "compaction"
					event.Role = "system"
					event.Content = "History compacted"
					event.Payload = map[string]any{
						"compactionId": firstNonEmpty(event.ID, "codex-compaction"),
						"summary":      "History compacted",
					}
					p.lastEventType = "compaction"
					return []api.AgentEvent{event}
				}
				if isSystemInjectedUserContext(content) {
					event.Type = "system_instructions"
					event.Role = "system"
					event.Content = content
					p.lastEventType = "system_instructions"
					return []api.AgentEvent{event}
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

func (p *codexParser) parseCodexGoalUpdated(raw json.RawMessage, event api.AgentEvent) []api.AgentEvent {
	var value codexGoalEnvelope
	if json.Unmarshal(raw, &value) != nil {
		return nil
	}
	goal := codexGoalValuesFromEnvelope(value)
	threadID := firstNonEmpty(goal.threadID, p.threadID)
	if threadID == "" || strings.TrimSpace(goal.objective) == "" {
		return nil
	}
	status := normalizeCodexGoalStatus(goal.status)
	if status == "" {
		status = "active"
	}
	event.ID = threadID
	event.Type = "goal"
	event.Content = p.clip(goal.objective)
	event.Payload = map[string]any{
		"goalId":          threadID,
		"threadId":        threadID,
		"objective":       p.clip(goal.objective),
		"state":           status,
		"status":          status,
		"tokensUsed":      goal.tokensUsed,
		"timeUsedSeconds": goal.timeUsedSeconds,
	}
	if tokenBudget := goal.tokenBudget; tokenBudget != nil {
		event.Payload["tokenBudget"] = *tokenBudget
	}
	if goal.createdAt != 0 {
		event.Payload["createdAt"] = goal.createdAt
	}
	if goal.updatedAt != 0 {
		event.Payload["updatedAt"] = goal.updatedAt
	}
	if value.turnID() != "" {
		event.Payload["turnId"] = value.turnID()
	}
	return []api.AgentEvent{event}
}

// codexGoalEnvelope accepts both the rollout event shape (`goal: {...}`) and
// the compact object returned by a tool/controller (`{objective, status, ...}`)
// so the same projection works across Codex TUI and app-server generations.
type codexGoalEnvelope struct {
	ThreadID      string             `json:"thread_id"`
	ThreadIDCamel string             `json:"threadId"`
	TurnID        string             `json:"turn_id"`
	TurnIDCamel   string             `json:"turnId"`
	Objective     string             `json:"objective"`
	Status        string             `json:"status"`
	TokenBudget   *int64             `json:"token_budget"`
	TokenBudgetC  *int64             `json:"tokenBudget"`
	TokensUsed    int64              `json:"tokens_used"`
	TokensUsedC   int64              `json:"tokensUsed"`
	TimeUsed      int64              `json:"time_used_seconds"`
	TimeUsedC     int64              `json:"timeUsedSeconds"`
	CreatedAt     int64              `json:"created_at"`
	CreatedAtC    int64              `json:"createdAt"`
	UpdatedAt     int64              `json:"updated_at"`
	UpdatedAtC    int64              `json:"updatedAt"`
	Goal          *codexGoalEnvelope `json:"goal"`
}

type codexGoalValues struct {
	threadID        string
	objective       string
	status          string
	tokenBudget     *int64
	tokensUsed      int64
	timeUsedSeconds int64
	createdAt       int64
	updatedAt       int64
}

func codexGoalValuesFromEnvelope(value codexGoalEnvelope) codexGoalValues {
	if value.Goal != nil {
		goal := codexGoalValuesFromEnvelope(*value.Goal)
		if goal.threadID == "" {
			goal.threadID = firstNonEmpty(value.ThreadID, value.ThreadIDCamel)
		}
		if goal.objective == "" {
			goal.objective = value.Objective
		}
		if goal.status == "" {
			goal.status = value.Status
		}
		if goal.tokenBudget == nil {
			goal.tokenBudget = firstNonNilInt64(value.TokenBudgetC, value.TokenBudget)
		}
		if goal.tokensUsed == 0 {
			goal.tokensUsed = firstNonZeroInt64(value.TokensUsedC, value.TokensUsed)
		}
		if goal.timeUsedSeconds == 0 {
			goal.timeUsedSeconds = firstNonZeroInt64(value.TimeUsedC, value.TimeUsed)
		}
		if goal.createdAt == 0 {
			goal.createdAt = firstNonZeroInt64(value.CreatedAtC, value.CreatedAt)
		}
		if goal.updatedAt == 0 {
			goal.updatedAt = firstNonZeroInt64(value.UpdatedAtC, value.UpdatedAt)
		}
		return goal
	}
	return codexGoalValues{
		threadID:        firstNonEmpty(value.ThreadIDCamel, value.ThreadID),
		objective:       strings.TrimSpace(value.Objective),
		status:          value.Status,
		tokenBudget:     firstNonNilInt64(value.TokenBudgetC, value.TokenBudget),
		tokensUsed:      firstNonZeroInt64(value.TokensUsedC, value.TokensUsed),
		timeUsedSeconds: firstNonZeroInt64(value.TimeUsedC, value.TimeUsed),
		createdAt:       firstNonZeroInt64(value.CreatedAtC, value.CreatedAt),
		updatedAt:       firstNonZeroInt64(value.UpdatedAtC, value.UpdatedAt),
	}
}

func (value codexGoalEnvelope) turnID() string {
	return firstNonEmpty(value.TurnIDCamel, value.TurnID)
}

func normalizeCodexGoalStatus(value string) string {
	normalized := strings.ToLower(strings.TrimSpace(value))
	normalized = strings.NewReplacer("-", "_", " ", "_").Replace(normalized)
	switch normalized {
	case "usagelimited", "usage_limited":
		return "usage_limited"
	case "budgetlimited", "budget_limited":
		return "budget_limited"
	case "inprogress", "in_progress":
		return "in_progress"
	case "completed":
		return "complete"
	default:
		return normalized
	}
}

func parseCodexGoalOutput(raw json.RawMessage, event api.AgentEvent, fallbackThreadID string, limit int) *api.AgentEvent {
	output, _, _ := codexOutputDetails(raw, limit)
	if strings.TrimSpace(output) == "" {
		return nil
	}
	for offset := 0; offset < len(output); {
		index := strings.IndexByte(output[offset:], '{')
		if index < 0 {
			break
		}
		index += offset
		var envelope codexGoalEnvelope
		decoder := json.NewDecoder(strings.NewReader(output[index:]))
		if err := decoder.Decode(&envelope); err != nil {
			offset = index + 1
			continue
		}
		goal := codexGoalValuesFromEnvelope(envelope)
		threadID := firstNonEmpty(goal.threadID, fallbackThreadID)
		if threadID == "" || goal.objective == "" {
			offset = index + 1
			continue
		}
		status := normalizeCodexGoalStatus(goal.status)
		if status == "" {
			status = "active"
		}
		projected := event
		projected.ID = threadID
		projected.Type = "goal"
		projected.Content = truncate(goal.objective, limit)
		projected.Payload = map[string]any{
			"goalId":          threadID,
			"threadId":        threadID,
			"objective":       truncate(goal.objective, limit),
			"state":           status,
			"status":          status,
			"tokensUsed":      goal.tokensUsed,
			"timeUsedSeconds": goal.timeUsedSeconds,
		}
		if goal.tokenBudget != nil {
			projected.Payload["tokenBudget"] = *goal.tokenBudget
		}
		if goal.createdAt != 0 {
			projected.Payload["createdAt"] = goal.createdAt
		}
		if goal.updatedAt != 0 {
			projected.Payload["updatedAt"] = goal.updatedAt
		}
		return &projected
	}
	return nil
}

func firstNonZeroInt64(values ...int64) int64 {
	for _, value := range values {
		if value != 0 {
			return value
		}
	}
	return 0
}

func firstNonNilInt64(values ...*int64) *int64 {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func codexUnavailableUserInput(output, outputError string) bool {
	value := strings.ToLower(strings.TrimSpace(firstNonEmpty(outputError, output)))
	return strings.Contains(value, "request_user_input is unavailable")
}

func codexGoalToolName(value string) bool {
	normalized := strings.ToLower(strings.TrimSpace(strings.ReplaceAll(value, "-", "_")))
	switch normalized {
	case "create_goal", "get_goal", "update_goal", "set_goal", "goal",
		"thread_goal_get", "thread_goal_set", "thread_goal_clear":
		return true
	default:
		return false
	}
}

// Codex's local TUI exposes Goal operations as ordinary `exec` custom tool
// calls that invoke the host-side tools.get_goal/create_goal/update_goal
// helpers. Track that intent from the call input so the structured Goal JSON
// returned by the wrapper is projected instead of being shown as raw tool
// output. The check is deliberately limited to an explicit tools.<operation>
// invocation; arbitrary shell JSON is not enough to become a Goal card.
func codexGoalOperation(toolName, arguments string, input json.RawMessage) string {
	normalized := strings.ToLower(strings.TrimSpace(strings.ReplaceAll(toolName, "-", "_")))
	if codexGoalToolName(normalized) {
		return normalized
	}
	if normalized != "exec" && normalized != "shell" && normalized != "local_shell_call" {
		return ""
	}
	var inputText string
	if len(input) > 0 {
		if json.Unmarshal(input, &inputText) != nil {
			inputText = string(input)
		}
	}
	text := strings.ToLower(arguments + "\n" + inputText)
	for _, operation := range []string{"create_goal", "get_goal", "update_goal", "set_goal"} {
		if strings.Contains(text, "tools."+operation+"(") {
			return operation
		}
	}
	return ""
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
	return canonicalToolStatus(status)
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

func codexQuestionPayload(requestID string, rawArgs string, limit int) map[string]any {
	var parsed struct {
		Questions []struct {
			ID            string `json:"id"`
			Header        string `json:"header"`
			Question      string `json:"question"`
			Prompt        string `json:"prompt"`
			IsMultiSelect *bool  `json:"is_multi_select"`
			MultiSelect   *bool  `json:"multiSelect"`
			Options       any    `json:"options"`
		} `json:"questions"`
		Question      string `json:"question"`
		Prompt        string `json:"prompt"`
		Header        string `json:"header"`
		IsMultiSelect *bool  `json:"is_multi_select"`
		MultiSelect   *bool  `json:"multiSelect"`
		Options       any    `json:"options"`
	}
	_ = json.Unmarshal([]byte(rawArgs), &parsed)

	questions := make([]any, 0)
	if len(parsed.Questions) > 0 {
		for index, item := range parsed.Questions {
			prompt := firstNonEmpty(item.Question, item.Header, item.Prompt, "Question")
			selection := "single"
			if (item.IsMultiSelect != nil && *item.IsMultiSelect) || (item.MultiSelect != nil && *item.MultiSelect) {
				selection = "multiple"
			}
			options := parseQuestionOptions(item.Options)
			qID := item.ID
			if qID == "" {
				qID = fmt.Sprintf("q%d", index)
			}
			questions = append(questions, map[string]any{
				"id":        qID,
				"prompt":    prompt,
				"selection": selection,
				"required":  true,
				// Codex's request_user_input overlay accepts an optional note in
				// addition to the selected option. Expose that field to clients so
				// mobile answers can carry the same free-form context.
				"allowCustom": true,
				"options":     options,
			})
		}
	} else if parsed.Question != "" || parsed.Prompt != "" || parsed.Header != "" || parsed.Options != nil {
		prompt := firstNonEmpty(parsed.Question, parsed.Header, parsed.Prompt, "Question")
		selection := "single"
		if (parsed.IsMultiSelect != nil && *parsed.IsMultiSelect) || (parsed.MultiSelect != nil && *parsed.MultiSelect) {
			selection = "multiple"
		}
		options := parseQuestionOptions(parsed.Options)
		questions = append(questions, map[string]any{
			"id":        "q0",
			"prompt":    prompt,
			"selection": selection,
			"required":  true,
			// Codex's request_user_input overlay accepts an optional note in
			// addition to the selected option. Expose that field to clients so
			// mobile answers can carry the same free-form context.
			"allowCustom": true,
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

// codexQuestionResponse decodes the JSON returned by request_user_input. The
// Codex TUI stores an optional note as a synthetic "user_note: ..." answer;
// split it into the provider-neutral customAnswers field while retaining the
// visible option labels for clients that need to render a completed card.
func codexQuestionResponse(raw string, limit int) map[string]any {
	var envelope struct {
		Answers map[string]json.RawMessage `json:"answers"`
	}
	if strings.TrimSpace(raw) == "" || json.Unmarshal([]byte(raw), &envelope) != nil || len(envelope.Answers) == 0 {
		return nil
	}
	answers := make(map[string]any)
	answerLabels := make(map[string]any)
	customAnswers := make(map[string]any)
	for questionID, encoded := range envelope.Answers {
		var wrapper struct {
			Answers []string `json:"answers"`
		}
		values := []string(nil)
		if json.Unmarshal(encoded, &wrapper) == nil && wrapper.Answers != nil {
			values = wrapper.Answers
		} else if json.Unmarshal(encoded, &values) != nil {
			var value string
			if json.Unmarshal(encoded, &value) == nil {
				values = []string{value}
			}
		}
		for _, value := range values {
			value = strings.TrimSpace(value)
			if value == "" {
				continue
			}
			if strings.HasPrefix(value, "user_note: ") {
				note := strings.TrimSpace(strings.TrimPrefix(value, "user_note: "))
				if note != "" {
					customAnswers[questionID] = truncate(note, limit)
				}
				continue
			}
			value = truncate(value, limit)
			answersForQuestion, _ := answers[questionID].([]any)
			answersForQuestion = append(answersForQuestion, value)
			answers[questionID] = answersForQuestion
			labelsForQuestion, _ := answerLabels[questionID].([]any)
			labelsForQuestion = append(labelsForQuestion, value)
			answerLabels[questionID] = labelsForQuestion
		}
	}
	response := make(map[string]any)
	if len(answers) > 0 {
		response["answers"] = answers
		response["answerLabels"] = answerLabels
	}
	if len(customAnswers) > 0 {
		response["customAnswers"] = customAnswers
	}
	if len(response) == 0 {
		return nil
	}
	return response
}
