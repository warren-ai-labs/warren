package agent

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type claudeParser struct {
	baseParser
	claudeCallTool     map[string]string
	claudeInteractions map[string]string
	// claudeCountedUsage remembers which assistant message IDs have already
	// contributed their token usage. Claude splits one API response across
	// several transcript lines -- one per content block, so a reply that thinks
	// and then calls a tool is two lines -- and repeats the complete, identical
	// usage object on each. Attaching it every time is correct for rendering but
	// counts the same billable call repeatedly; across local transcripts 1168 of
	// 2623 usage rows were such repeats, inflating totals by 1.765x.
	claudeCountedUsage map[string]struct{}
	// claudeTasks is the session task list rebuilt from TaskCreate/TaskUpdate.
	// Unlike TodoWrite, those tools send one change at a time and TaskCreate's
	// id exists only in its result, so the parser keeps the list and applies
	// each change once the result confirms it.
	claudeTasks     []claudeTask
	claudeTaskCalls map[string]claudeTaskCall
	// claudeProposals holds each ExitPlanMode card until its result says
	// whether the user approved or rejected the plan.
	claudeProposals map[string]api.AgentEvent
	// claudeQueue mirrors Claude's pending prompt queue from its
	// queue-operation rows. Those rows carry no item identity and a dequeue
	// carries no content either, so the parser numbers each enqueue and
	// resolves dequeue/remove against this FIFO to give clients a stable
	// queueId to remove.
	claudeQueue      []claudeQueuedPrompt
	claudeQueueCount int
	// claudeTitle is the conversation name Claude generated for itself. It is
	// consumed once by TakeTitle and never enters the visible transcript.
	claudeTitle string
	// claudeSubagentCalls holds a spawned Agent/Task call until its result names
	// the child agent, because the spawn row carries only presentation metadata.
	claudeSubagentCalls map[string]claudeSubagentCall
	// subagentsDir is where Claude Code stores child transcripts for this
	// session. It is empty for a parser that never emits subagent rows.
	subagentsDir string
	// childTranscript marks a parser reading a subagent's own transcript. Every
	// record there is sidechain, so its messages must project as the child's
	// activity rather than re-emit a second subagent row for the child itself.
	childTranscript bool
}

type claudeQueuedPrompt struct {
	ID      string
	Content string
}

type claudeTask struct {
	ID         string
	Subject    string
	ActiveForm string
	Status     string
}

type claudeTaskCall struct {
	Name  string
	Input map[string]any
}

func newClaudeParser(contentLimit int) *claudeParser {
	return &claudeParser{
		baseParser:          newBaseParser(contentLimit),
		claudeCallTool:      make(map[string]string),
		claudeInteractions:  make(map[string]string),
		claudeCountedUsage:  make(map[string]struct{}),
		claudeTaskCalls:     make(map[string]claudeTaskCall),
		claudeProposals:     make(map[string]api.AgentEvent),
		claudeSubagentCalls: make(map[string]claudeSubagentCall),
	}
}

// SetSubagentsDir tells the parser where Claude Code stores this session's child
// transcripts. The Watcher sets it from the main transcript path so a spawn can
// be matched to the child's own transcript by tool_use id.
func (p *claudeParser) SetSubagentsDir(dir string) {
	p.subagentsDir = dir
}

// SetChildTranscript marks a parser that reads one subagent's own transcript.
func (p *claudeParser) SetChildTranscript(child bool) {
	p.childTranscript = child
}

// claudeUsageOnce returns the usage for an assistant message the first time that
// message is seen and nil afterwards, so exactly one canonical event per
// billable call carries a token count.
//
// Claiming on the first non-nil observation is safe because parseUsage already
// discards all-zero objects: Claude emits placeholder zero rows before the real
// counts, and those never reach here. Verified equivalent to keeping the largest
// observation per message across every local transcript.
//
// A message without an ID cannot be correlated, so it is counted as its own call
// rather than dropped -- under-reporting real spend is worse than the small risk
// of double counting a malformed record.
func (p *claudeParser) claudeUsageOnce(messageID string, raw json.RawMessage) *api.AgentUsage {
	value := parseUsage(raw)
	if value == nil {
		return nil
	}
	messageID = strings.TrimSpace(messageID)
	if messageID == "" {
		return value
	}
	// The assistant message id is Claude's own identity for one API response and
	// is globally unique, so it needs no session qualifier. Carrying it makes the
	// call countable exactly once even when a resumed conversation copies this
	// message into another transcript file.
	value.CallKey = messageID
	if _, counted := p.claudeCountedUsage[messageID]; counted {
		return nil
	}
	p.claudeCountedUsage[messageID] = struct{}{}
	return value
}

func (p *claudeParser) Parse(line []byte) []api.AgentEvent {
	return p.observe(p.parseClaude(line))
}

func (p *claudeParser) parse(line []byte) []api.AgentEvent {
	return p.Parse(line)
}

// TakeTitle returns the name Claude generated for this conversation, once.
// Claude writes it as its own transcript record, so Warren reports it instead
// of spending a second model call on the same conversation.
func (p *claudeParser) TakeTitle() string {
	title := p.claudeTitle
	p.claudeTitle = ""
	return title
}

type claudeToolUseResult struct {
	FilePath        string          `json:"filePath"`
	StructuredPatch json.RawMessage `json:"structuredPatch"`
	Interrupted     bool            `json:"interrupted"`
	Task            struct {
		ID string `json:"id"`
	} `json:"task"`
}

// UnmarshalJSON accepts the tool metadata Claude attaches to a tool_result.
// Healthy results use an object, but a denied interaction (or any tool error)
// serializes `toolUseResult` as a string. Decoding that string into the object
// shape would fail the whole record, dropping the tool_result that resolves a
// Question and leaving a permanently pending card in every client. Non-object
// values are valid provider metadata we do not consume, so they decode to the
// zero value instead.
func (r *claudeToolUseResult) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return nil
	}
	type plain claudeToolUseResult
	var decoded plain
	if err := json.Unmarshal(trimmed, &decoded); err != nil {
		return err
	}
	*r = claudeToolUseResult(decoded)
	return nil
}

type claudeRecord struct {
	Type        string `json:"type"`
	Subtype     string `json:"subtype"`
	Timestamp   string `json:"timestamp"`
	UUID        string `json:"uuid"`
	SessionID   string `json:"sessionId"`
	DurationMs  int64  `json:"durationMs"`
	IsSidechain bool   `json:"isSidechain"`
	// AgentID is Claude's stable identity for the subagent that wrote a sidechain
	// record. Modern Claude Code writes child transcripts to their own files, and
	// every record there carries it; the value is empty on the main conversation.
	AgentID          string          `json:"agentId"`
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
	ToolUseResult claudeToolUseResult `json:"toolUseResult"`
	ToolName      string              `json:"tool_name"`
	ToolInput     json.RawMessage     `json:"tool_input"`
	ToolOutput    json.RawMessage     `json:"tool_output"`
	ToolUseID     string              `json:"tool_use_id"`
	CallID        string              `json:"call_id"`
	// AITitle carries the conversation name Claude generated for itself. It is
	// metadata about the session, not a conversation turn.
	AITitle    string `json:"aiTitle"`
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
	if record.Type == "queue-operation" {
		return p.claudeQueueOperation(line, timestamp)
	}
	if structured := projectStructuredAgentEventWithLimit("claude", record.Type, line, timestamp, p.contentLimit); structured != nil {
		if structured.ID == "" {
			structured.ID = record.UUID
		}
		return []api.AgentEvent{*structured}
	}
	switch record.Type {
	case "ai-title":
		// Claude names its own conversation; the name is the session's title,
		// not a transcript row.
		if title := strings.TrimSpace(record.AITitle); title != "" {
			p.claudeTitle = title
		}
		return nil
	case "summary", "last-prompt", "pr-link",
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
					if kind == "proposal" {
						if proposal, ok := p.resolveClaudeProposal(block, record.ToolUseResult.Interrupted, timestamp); ok {
							events = append(events, proposal)
						}
						continue
					}
					if kind == "task" {
						if todo, ok := p.applyClaudeTaskResult(block, record.ToolUseResult.Task.ID, timestamp); ok {
							events = append(events, todo)
						}
						continue
					}
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
				if call, ok := p.claudeSubagentCalls[block.ToolUseID]; ok {
					delete(p.claudeSubagentCalls, block.ToolUseID)
					if subagent, ok := p.claudeSubagentEvent(block, call, timestamp); ok {
						events = append(events, subagent)
						continue
					}
					// A synchronous Task result names no child agent; keep the normal
					// tool_output so an older transcript still shows its answer.
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
				Provider: "claude",
				ID:       record.UUID,
				Type:     "compaction",
				Role:     "system",
				Content:  p.clip(content),
				Payload: map[string]any{
					"compactionId": record.UUID,
					"summary":      compactionSummaryText(p.clip(content)),
				},
				Timestamp: timestamp,
			}}
		}
		if command, ok := parseClaudeLocalCommand(content); ok {
			return p.claudeLocalCommandEvents(record.UUID, content, command, timestamp)
		}
		if record.IsMeta || isSystemInjectedUserContext(content) {
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        record.UUID,
				Type:      "system_instructions",
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
				Usage:      p.claudeUsageOnce(record.Message.ID, record.Message.Usage),
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}}
		}
		// One line's blocks all belong to the same API response, so its usage is
		// claimed once and then attached to the first block that actually
		// survives the emit filter below. Attaching it before that filter would
		// discard the count whenever the leading block carries no renderable
		// content.
		messageUsage := p.claudeUsageOnce(record.Message.ID, record.Message.Usage)
		var events []api.AgentEvent
		for _, block := range blocks {
			event := api.AgentEvent{
				Provider:   "claude",
				ID:         firstNonEmpty(block.ID, record.UUID),
				Model:      record.Message.Model,
				StopReason: record.Message.StopReason,
				Sidechain:  record.IsSidechain,
				Timestamp:  timestamp,
			}
			switch block.Type {
			case "text":
				if record.IsSidechain && !p.childTranscript {
					subagentID := firstNonEmpty(record.AgentID, record.UUID)
					event.ID = subagentID
					event.Type = "subagent"
					event.Payload = map[string]any{
						"subagentId": subagentID,
						"label":      "Subagent",
						"state":      "completed",
						"summary":    p.clip(block.Text),
					}
				} else {
					event.Type = "assistant"
					event.Content = p.clip(block.Text)
				}
			case "thinking", "redacted_thinking":
				// Claude Code persists thinking as a signature with no text. An
				// empty block has nothing to show, so it is dropped by the emit
				// filter below like every other provider's empty thinking.
				event.Type = "reasoning"
				event.Content = p.clip(block.Thinking)
			case "tool_use":
				canonicalName := canonicalToolName("claude", block.Name)
				if canonicalName == "exitplanmode" {
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					if proposal, ok := proposedPlanEvent(event, "claude", stringValue(input["plan"])); ok {
						event = proposal
						if block.ID != "" {
							p.claudeProposals[block.ID] = proposal
							p.claudeInteractions[block.ID] = "proposal"
						}
						break
					}
				}
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
					event.Payload = claudeTodoPayloadWithLimit(input, p.contentLimit)
					event.Content = stringValue(event.Payload["summary"])
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "todo"
					}
				case "taskcreate", "taskupdate":
					// Recorded now, projected when the result arrives. The call
					// row itself is bookkeeping, like TodoWrite's.
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					if block.ID != "" {
						p.claudeTaskCalls[block.ID] = claudeTaskCall{Name: canonicalName, Input: input}
						p.claudeInteractions[block.ID] = "task"
					}
				case "update_plan", "plan":
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					event.Type = "plan"
					event.Payload = normalizeStructuredPlanPayload(input, "claude-plan", p.contentLimit)
					event.ID = stringValue(event.Payload["planId"])
					event.Content = stringValue(event.Payload["summary"])
					if block.ID != "" {
						p.claudeInteractions[block.ID] = "plan"
					}
				case "subagent":
					// The row is emitted from the result, which carries the child's
					// identity; this call only records the presentation metadata.
					input, _ := rawToAny(block.Input, p.contentLimit).(map[string]any)
					if block.ID != "" {
						p.claudeSubagentCalls[block.ID] = claudeSubagentCall{
							Label:   firstNonEmpty(stringValue(input["subagent_type"]), stringValue(input["agent_type"]), "Subagent"),
							Summary: firstNonEmpty(stringValue(input["description"]), stringValue(input["prompt"])),
						}
					}
					event.Type = "tool_call"
					event.ToolName = canonicalName
					event.CallID = block.ID
					event.ToolInput = input
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
				if messageUsage != nil {
					event.Usage = messageUsage
					messageUsage = nil
				}
				events = append(events, event)
			}
		}
		// Every block was filtered out. The call still consumed tokens, so the
		// count is returned to the pool rather than silently dropped: the next
		// line for this message claims it instead.
		if messageUsage != nil {
			delete(p.claudeCountedUsage, strings.TrimSpace(record.Message.ID))
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
		if command, ok := parseClaudeLocalCommand(content); ok {
			return p.claudeLocalCommandEvents(record.UUID, content, command, timestamp)
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
			// Claude writes this when a queued prompt is delivered to the
			// model, after the matching dequeue/remove row. It is not a
			// pending item; projecting it as one left a queue entry that no
			// later row ever cleared.
			return nil
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
		if canonicalName == "todowrite" {
			payload := claudeTodoPayloadWithLimit(input, p.contentLimit)
			callID := firstNonEmpty(record.ToolUseID, record.CallID, record.UUID)
			if callID != "" {
				p.claudeInteractions[callID] = "todo"
			}
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        "claude-todos",
				Type:      "todo",
				Content:   stringValue(payload["summary"]),
				Payload:   payload,
				Timestamp: timestamp,
			}}
		}
		if canonicalName == "update_plan" || canonicalName == "plan" {
			payload := normalizeStructuredPlanPayload(input, "claude-plan", p.contentLimit)
			callID := firstNonEmpty(record.ToolUseID, record.CallID, record.UUID)
			if callID != "" {
				p.claudeInteractions[callID] = "plan"
			}
			return []api.AgentEvent{{
				Provider:  "claude",
				ID:        stringValue(payload["planId"]),
				Type:      "plan",
				Content:   stringValue(payload["summary"]),
				Payload:   payload,
				Timestamp: timestamp,
			}}
		}
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
		callID := firstNonEmpty(record.ToolUseID, record.CallID)
		if kind := p.claudeInteractions[callID]; (kind == "todo" || kind == "plan") && callID != "" {
			delete(p.claudeInteractions, callID)
			return nil
		}
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

// claudeAgentIDPattern reads the child agent id from an async-launch result.
// The main transcript has no structured field for it, so the metadata line is
// the only fallback when the child's .meta.json is not readable yet.
var claudeAgentIDPattern = regexp.MustCompile(`(?i)agentId:\s*([A-Za-z0-9_-]+)`)

// claudeSubagentEvent projects a spawned Agent/Task result as a subagent row.
// The child's .meta.json is authoritative because it links the tool_use id to
// the child identity; text parsing is only a fallback.
func (p *claudeParser) claudeSubagentEvent(block claudeBlock, call claudeSubagentCall, timestamp time.Time) (api.AgentEvent, bool) {
	id, label, summary, ok := p.claudeSubagentMeta(block.ToolUseID)
	if !ok {
		id = claudeAgentIDFromOutput(p.content(block.Content))
		if id == "" {
			return api.AgentEvent{}, false
		}
		label, summary = call.Label, call.Summary
	}
	if label == "" {
		label = "Subagent"
	}
	return api.AgentEvent{
		Provider: "claude",
		ID:       id,
		CallID:   block.ToolUseID,
		Type:     "subagent",
		Payload: map[string]any{
			"subagentId":   id,
			"parentCallId": block.ToolUseID,
			"title":        label,
			"label":        label,
			"state":        "running",
			"summary":      p.clip(summary),
		},
		Timestamp: timestamp,
	}, true
}

// claudeSubagentMeta resolves a spawn call to its child transcript metadata by
// reading the .meta.json Claude Code writes beside it.
func (p *claudeParser) claudeSubagentMeta(toolUseID string) (id, label, summary string, ok bool) {
	toolUseID = strings.TrimSpace(toolUseID)
	if p.subagentsDir == "" || toolUseID == "" {
		return "", "", "", false
	}
	entries, err := os.ReadDir(p.subagentsDir)
	if err != nil {
		return "", "", "", false
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasPrefix(name, "agent-") || !strings.HasSuffix(name, ".meta.json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(p.subagentsDir, name))
		if err != nil {
			continue
		}
		var meta struct {
			AgentType   string `json:"agentType"`
			Description string `json:"description"`
			ToolUseID   string `json:"toolUseId"`
		}
		if json.Unmarshal(raw, &meta) != nil || meta.ToolUseID != toolUseID {
			continue
		}
		id = strings.TrimSuffix(strings.TrimPrefix(name, "agent-"), ".meta.json")
		return id, meta.AgentType, meta.Description, true
	}
	return "", "", "", false
}

// claudeAgentIDFromOutput extracts the async-launch agent id from result text.
func claudeAgentIDFromOutput(output string) string {
	match := claudeAgentIDPattern.FindStringSubmatch(output)
	if len(match) < 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

const claudePlanFeedbackMarker = "the user said:"

// resolveClaudeProposal settles an ExitPlanMode card from its result. Claude
// records approval as a plain result and rejection as an error whose text
// ends with the user's feedback; that feedback is the only place the user's
// reply to the plan exists, so it travels on the card.
func (p *claudeParser) resolveClaudeProposal(block claudeBlock, interrupted bool, timestamp time.Time) (api.AgentEvent, bool) {
	proposal, ok := p.claudeProposals[block.ToolUseID]
	delete(p.claudeProposals, block.ToolUseID)
	if !ok {
		return api.AgentEvent{}, false
	}
	payload := make(map[string]any, len(proposal.Payload)+1)
	for key, value := range proposal.Payload {
		payload[key] = value
	}
	switch {
	case interrupted:
		payload["state"] = "cancelled"
	case block.IsError:
		payload["state"] = "rejected"
		output := p.content(block.Content)
		if index := strings.Index(output, claudePlanFeedbackMarker); index >= 0 {
			if feedback := strings.TrimSpace(output[index+len(claudePlanFeedbackMarker):]); feedback != "" {
				payload["feedback"] = p.clip(feedback)
			}
		}
	default:
		payload["state"] = "approved"
	}
	proposal.Payload = payload
	proposal.Timestamp = timestamp
	return proposal, true
}

var claudeTaskCreatedPattern = regexp.MustCompile(`Task #(\S+) created`)

// applyClaudeTaskResult applies a confirmed TaskCreate/TaskUpdate to the
// session task list and returns the resulting Todo snapshot. Failed calls and
// updates to tasks this transcript never created leave the list unchanged.
func (p *claudeParser) applyClaudeTaskResult(block claudeBlock, createdID string, timestamp time.Time) (api.AgentEvent, bool) {
	call, ok := p.claudeTaskCalls[block.ToolUseID]
	delete(p.claudeTaskCalls, block.ToolUseID)
	if !ok || block.IsError {
		return api.AgentEvent{}, false
	}
	switch call.Name {
	case "taskcreate":
		id := strings.TrimSpace(createdID)
		if id == "" {
			if match := claudeTaskCreatedPattern.FindStringSubmatch(p.content(block.Content)); match != nil {
				id = match[1]
			}
		}
		subject := stringValue(call.Input["subject"])
		if id == "" || subject == "" {
			return api.AgentEvent{}, false
		}
		p.claudeTasks = append(p.claudeTasks, claudeTask{
			ID:         id,
			Subject:    subject,
			ActiveForm: stringValue(call.Input["activeForm"]),
			Status:     "pending",
		})
	case "taskupdate":
		id := stringValue(call.Input["taskId"])
		index := -1
		for candidate := range p.claudeTasks {
			if p.claudeTasks[candidate].ID == id {
				index = candidate
				break
			}
		}
		if index < 0 {
			return api.AgentEvent{}, false
		}
		status := stringValue(call.Input["status"])
		if status == "deleted" {
			p.claudeTasks = append(p.claudeTasks[:index], p.claudeTasks[index+1:]...)
			break
		}
		task := &p.claudeTasks[index]
		if status != "" {
			task.Status = status
		}
		if subject := stringValue(call.Input["subject"]); subject != "" {
			task.Subject = subject
		}
		if activeForm := stringValue(call.Input["activeForm"]); activeForm != "" {
			task.ActiveForm = activeForm
		}
	default:
		return api.AgentEvent{}, false
	}
	todos := make([]any, 0, len(p.claudeTasks))
	for _, task := range p.claudeTasks {
		todos = append(todos, map[string]any{
			"id":         task.ID,
			"content":    task.Subject,
			"activeForm": task.ActiveForm,
			"status":     task.Status,
		})
	}
	payload := claudeTodoPayloadWithLimit(map[string]any{"todos": todos}, p.contentLimit)
	return api.AgentEvent{
		Provider:  "claude",
		ID:        "claude-todos",
		Type:      "todo",
		Content:   stringValue(payload["summary"]),
		Payload:   payload,
		Timestamp: timestamp,
	}, true
}

func claudeTodoPayloadWithLimit(input map[string]any, limit int) map[string]any {
	payload := normalizeStructuredTodoPayload(input, "claude-todos", limit)
	// Keep the legacy []any shape for provider-local callers while ensuring
	// every item has the same id/title/label/state fields as Plan items.
	if normalized, ok := payload["items"].([]map[string]any); ok {
		items := make([]any, len(normalized))
		for index := range normalized {
			items[index] = normalized[index]
		}
		payload["items"] = items
	}
	return payload
}

// claudeQueueOperation projects one queue-operation row against the parser's
// FIFO. Claude dequeues from the front without naming the item and removes a
// prompt absorbed mid-turn by content, so both resolve to the queueId assigned
// at enqueue. A dequeue or remove with nothing pending is dropped rather than
// emitted as an unmatched row.
func (p *claudeParser) claudeQueueOperation(line []byte, timestamp time.Time) []api.AgentEvent {
	var record struct {
		Operation string          `json:"operation"`
		SessionID string          `json:"sessionId"`
		Content   json.RawMessage `json:"content"`
	}
	if json.Unmarshal(line, &record) != nil {
		return nil
	}
	content := p.content(record.Content)
	var item claudeQueuedPrompt
	var action, state string
	switch strings.ToLower(strings.TrimSpace(record.Operation)) {
	case "enqueue":
		p.claudeQueueCount++
		item = claudeQueuedPrompt{ID: fmt.Sprintf("claude-queue-%d", p.claudeQueueCount), Content: content}
		p.claudeQueue = append(p.claudeQueue, item)
		action, state = "enqueue", "queued"
	case "dequeue", "remove":
		if len(p.claudeQueue) == 0 {
			return nil
		}
		index := 0
		if content != "" {
			for candidate, queued := range p.claudeQueue {
				if queued.Content == content {
					index = candidate
					break
				}
			}
		}
		item = p.claudeQueue[index]
		p.claudeQueue = append(p.claudeQueue[:index], p.claudeQueue[index+1:]...)
		action, state = "dequeue", "dequeued"
	default:
		return nil
	}
	payload := map[string]any{
		"action":  action,
		"queueId": item.ID,
		"state":   state,
	}
	if item.Content != "" {
		payload["content"] = item.Content
	}
	if record.SessionID != "" {
		payload["sessionId"] = record.SessionID
	}
	return []api.AgentEvent{{
		Provider:  "claude",
		ID:        item.ID,
		Type:      "queue",
		Payload:   payload,
		Timestamp: timestamp,
	}}
}

// Claude Code records a local slash command and its output as transcript rows
// wrapped in provider markup:
//
//	<command-name>/resume</command-name>
//	<command-message>resume</command-message>
//	<command-args></command-args>
//	<local-command-stdout>Resume cancelled</local-command-stdout>
//
// The markup is transport detail, not conversation text: a client that showed
// it raw printed tags instead of the command a person ran. A row made only of
// these tags is unwrapped into a quiet system notice — the invocation as one
// command line, the output as muted text, and the caveat as nothing to read.
// Any other content keeps its text so an unknown envelope is never swallowed.
const (
	claudeLocalCommandInvocation = "command"
	claudeLocalCommandOutput     = "output"
	claudeLocalCommandCaveat     = "caveat"
)

type claudeLocalCommand struct {
	kind string
	name string
	args string
	text string
}

// claudeControlSequence matches the SGR/CSI and OSC escapes a slash command's
// TUI output carries (a /context dump is mostly cursor and color codes). A
// notice shows plain text, so they are removed before it is journaled.
var claudeControlSequence = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)")

func stripClaudeControlSequences(value string) string {
	return strings.TrimSpace(claudeControlSequence.ReplaceAllString(value, ""))
}

func parseClaudeLocalCommand(content string) (claudeLocalCommand, bool) {
	value := strings.TrimSpace(strings.TrimPrefix(content, "\ufeff"))
	if !strings.HasPrefix(value, "<") {
		return claudeLocalCommand{}, false
	}
	fields, ok := claudeTagFields(value)
	if !ok || len(fields) == 0 {
		return claudeLocalCommand{}, false
	}
	if stdout, ok := fields["local-command-stdout"]; ok {
		if !claudeFieldsWithin(fields, "local-command-stdout", "command-stdout", "local-command-caveat") {
			return claudeLocalCommand{}, false
		}
		text := strings.TrimSpace(stdout)
		if text == "" {
			text = strings.TrimSpace(fields["command-stdout"])
		}
		return claudeLocalCommand{kind: claudeLocalCommandOutput, text: stripClaudeControlSequences(text)}, true
	}
	if name, ok := fields["command-name"]; ok {
		if !claudeFieldsWithin(fields, "command-name", "command-message", "command-args", "local-command-caveat") {
			return claudeLocalCommand{}, false
		}
		name = strings.TrimSpace(name)
		if name == "" {
			return claudeLocalCommand{}, false
		}
		return claudeLocalCommand{
			kind: claudeLocalCommandInvocation,
			name: name,
			args: strings.TrimSpace(fields["command-args"]),
		}, true
	}
	if !claudeFieldsWithin(fields, "local-command-caveat") {
		return claudeLocalCommand{}, false
	}
	return claudeLocalCommand{kind: claudeLocalCommandCaveat}, true
}

// claudeTagFields splits a value made only of <tag>inner</tag> elements, in any
// order and separated by whitespace. It reports false as soon as something
// outside a tag appears, so a partially understood envelope is left as-is.
func claudeTagFields(value string) (map[string]string, bool) {
	fields := make(map[string]string)
	rest := value
	for {
		rest = strings.TrimSpace(rest)
		if rest == "" {
			return fields, true
		}
		if !strings.HasPrefix(rest, "<") {
			return nil, false
		}
		close := strings.IndexByte(rest, '>')
		if close < 0 {
			return nil, false
		}
		tag := rest[1:close]
		if tag == "" || strings.ContainsAny(tag, " \t\r\n/") {
			return nil, false
		}
		closing := "</" + tag + ">"
		inner := rest[close+1:]
		end := strings.Index(inner, closing)
		if end < 0 {
			return nil, false
		}
		fields[tag] = inner[:end]
		rest = inner[end+len(closing):]
	}
}

func claudeFieldsWithin(fields map[string]string, allowed ...string) bool {
	for key := range fields {
		known := false
		for _, candidate := range allowed {
			if key == candidate {
				known = true
				break
			}
		}
		if !known {
			return false
		}
	}
	return true
}

// claudeLocalCommandEvents projects a parsed envelope onto the canonical quiet
// notice rows. An empty output is dropped rather than journaled as an empty
// row, and an invocation carries its name and args so a client can draw the
// command in a mono face instead of parsing the text back out.
func (p *claudeParser) claudeLocalCommandEvents(id, raw string, command claudeLocalCommand, timestamp time.Time) []api.AgentEvent {
	switch command.kind {
	case claudeLocalCommandCaveat:
		return []api.AgentEvent{{
			Provider:  "claude",
			ID:        id,
			Type:      "system_instructions",
			Role:      "system",
			Content:   p.clip(raw),
			Timestamp: timestamp,
		}}
	case claudeLocalCommandOutput:
		if command.text == "" {
			return nil
		}
		return []api.AgentEvent{{
			Provider:  "claude",
			ID:        id,
			Type:      "system",
			Role:      "system",
			Content:   p.clip(command.text),
			Payload:   map[string]any{"localCommand": map[string]any{"kind": claudeLocalCommandOutput}},
			Timestamp: timestamp,
		}}
	default:
		line := command.name
		if command.args != "" {
			line += " " + command.args
		}
		return []api.AgentEvent{{
			Provider: "claude",
			ID:       id,
			Type:     "system",
			Role:     "system",
			Content:  p.clip(line),
			Payload: map[string]any{"localCommand": map[string]any{
				"kind": claudeLocalCommandInvocation,
				"name": command.name,
				"args": command.args,
			}},
			Timestamp: timestamp,
		}}
	}
}
