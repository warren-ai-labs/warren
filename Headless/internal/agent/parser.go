package agent

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Parser converts raw transcript lines from a specific provider into normalized
// AgentEvents, tracking activity state and lifecycle turn transitions.
type Parser interface {
	Parse(line []byte) []api.AgentEvent
	parse(line []byte) []api.AgentEvent
	Status() api.AgentStatus
	Activity() api.AgentActivity
	DrainTurns() []api.AgentTurn
	Tick(now time.Time)
}

// baseParser provides common event observing and activity tracking functionality
// across all provider-specific parser implementations.
type baseParser struct {
	contentLimit int
	tracker      ActivityTracker
}

func newBaseParser(contentLimit int) baseParser {
	return baseParser{
		contentLimit: contentLimit,
		tracker:      *NewActivityTracker(),
	}
}

func (b *baseParser) Status() api.AgentStatus {
	return b.tracker.Status()
}

func (b *baseParser) Activity() api.AgentActivity {
	return b.tracker.Activity()
}

func (b *baseParser) DrainTurns() []api.AgentTurn {
	return b.tracker.DrainTurns()
}

func (b *baseParser) Tick(now time.Time) {
	b.tracker.Tick(now)
}

func (b *baseParser) content(value json.RawMessage) string {
	return contentStringLimit(value, b.contentLimit)
}

func (b *baseParser) clip(value string) string {
	return truncate(value, b.contentLimit)
}

func (b *baseParser) observe(events []api.AgentEvent) []api.AgentEvent {
	events = compactRenderable(events)
	for index := range events {
		b.tracker.Observe(events[index])
		if !events[index].Sidechain {
			events[index].Turn = b.tracker.Turn()
		}
	}
	return events
}

// fallbackParser is used when an unknown or unsupported provider is requested.
type fallbackParser struct {
	baseParser
	provider string
}

func newFallbackParser(provider string, contentLimit int) *fallbackParser {
	return &fallbackParser{
		baseParser: newBaseParser(contentLimit),
		provider:   provider,
	}
}

func (p *fallbackParser) Parse(line []byte) []api.AgentEvent {
	return nil
}

func (p *fallbackParser) parse(line []byte) []api.AgentEvent {
	return p.Parse(line)
}

// newParser constructs a Parser for the specified provider with the default safety cap.
func newParser(provider string) Parser {
	return newParserWithContentLimit(provider, maxEventContent)
}

// newParserWithContentLimit constructs a Parser with an explicit content clipping limit.
func newParserWithContentLimit(provider string, contentLimit int) Parser {
	switch strings.ToLower(strings.TrimSpace(provider)) {
	case "codex":
		return newCodexParser(contentLimit)
	case "claude":
		return newClaudeParser(contentLimit)
	case "opencode":
		return newOpenCodeParser(contentLimit)
	case "pi":
		return newPiParser(contentLimit)
	case "qoder":
		return newQoderParser(contentLimit)
	default:
		return newFallbackParser(provider, contentLimit)
	}
}

var structuredAgentEventTypes = map[string]struct{}{
	"question": {}, "permission": {}, "plan": {}, "todo": {},
	"activity": {}, "plugin": {}, "subagent": {}, "attachment": {},
}

// projectStructuredAgentEvent turns provider-native structured records into
// the small, provider-neutral payload understood by Agent View.
func projectStructuredAgentEvent(provider string, fallbackType string, raw json.RawMessage, timestamp time.Time) *api.AgentEvent {
	var object map[string]any
	if len(raw) == 0 || json.Unmarshal(raw, &object) != nil {
		return nil
	}
	outerType := firstStringValue(object["type"], object["eventType"], fallbackType)
	source := object
	if nested, ok := object["payload"].(map[string]any); ok {
		source = nested
	}
	rawType := firstStringValue(source["type"], source["eventType"], outerType)
	normalized := strings.ToLower(strings.NewReplacer("-", "_", ".", "_").Replace(strings.TrimSpace(rawType)))
	kind := normalized
	for _, candidate := range []string{"question", "permission", "plan", "todo", "activity", "plugin", "subagent", "attachment"} {
		if normalized == candidate || strings.HasPrefix(normalized, candidate+"_") {
			kind = candidate
			break
		}
	}
	if _, ok := structuredAgentEventTypes[kind]; !ok {
		return nil
	}
	payload := make(map[string]any)
	copyStructuredField(payload, source, "requestId", "requestId", "request_id")
	copyStructuredField(payload, source, "title", "title")
	copyStructuredField(payload, source, "description", "description")
	copyStructuredField(payload, source, "questions", "questions")
	copyStructuredField(payload, source, "action", "action")
	copyStructuredField(payload, source, "options", "options")
	copyStructuredField(payload, source, "planId", "planId", "plan_id")
	copyStructuredField(payload, source, "todoId", "todoId", "todo_id")
	copyStructuredField(payload, source, "activityId", "activityId", "activity_id")
	copyStructuredField(payload, source, "pluginId", "pluginId", "plugin_id")
	copyStructuredField(payload, source, "subagentId", "subagentId", "subagent_id")
	copyStructuredField(payload, source, "attachmentId", "attachmentId", "attachment_id")
	copyStructuredField(payload, source, "items", "items")
	copyStructuredField(payload, source, "label", "label")
	copyStructuredField(payload, source, "name", "name")
	copyStructuredField(payload, source, "summary", "summary")
	copyStructuredField(payload, source, "detail", "detail")
	copyStructuredField(payload, source, "mime", "mime", "MIME")
	copyStructuredField(payload, source, "size", "size")
	copyStructuredField(payload, source, "state", "state", "status")
	if len(payload) == 0 {
		return nil
	}
	if _, ok := payload["state"]; !ok {
		switch {
		case strings.HasSuffix(normalized, "_asked") || strings.HasSuffix(normalized, "_requested"):
			payload["state"] = "pending"
		case strings.HasSuffix(normalized, "_resolved") || strings.HasSuffix(normalized, "_replied") || strings.HasSuffix(normalized, "_rejected"):
			payload["state"] = "resolved"
		}
	}
	requestID := stringValue(payload["requestId"])
	id := firstStringValue(source["id"], source["eventId"], source["event_id"])
	if id == "" {
		switch kind {
		case "question", "permission":
			id = requestID
		case "plan":
			id = stringValue(payload["planId"])
		case "todo":
			id = stringValue(payload["todoId"])
		case "activity":
			id = stringValue(payload["activityId"])
		case "plugin":
			id = stringValue(payload["pluginId"])
		case "subagent":
			id = stringValue(payload["subagentId"])
		case "attachment":
			id = stringValue(payload["attachmentId"])
		}
	}
	return &api.AgentEvent{Provider: provider, ID: id, Type: kind, Payload: payload, Timestamp: timestamp}
}

func copyStructuredField(destination, source map[string]any, name string, aliases ...string) {
	for _, alias := range aliases {
		if value, ok := source[alias]; ok && value != nil {
			destination[name] = value
			return
		}
	}
}

func firstStringValue(values ...any) string {
	for _, value := range values {
		if text, ok := value.(string); ok && strings.TrimSpace(text) != "" {
			return strings.TrimSpace(text)
		}
	}
	return ""
}

func stringValue(value any) string {
	text, _ := value.(string)
	return strings.TrimSpace(text)
}

func parseUsage(raw json.RawMessage) *api.AgentUsage {
	var value struct {
		InputTokens              int64 `json:"input_tokens"`
		CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
		CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
		CachedInputTokens        int64 `json:"cached_input_tokens"`
		OutputTokens             int64 `json:"output_tokens"`
		ReasoningOutputTokens    int64 `json:"reasoning_output_tokens"`
		TotalTokens              int64 `json:"total_tokens"`
	}
	if json.Unmarshal(raw, &value) != nil {
		return nil
	}
	if value.InputTokens == 0 && value.OutputTokens == 0 && value.TotalTokens == 0 {
		return nil
	}
	if value.CacheReadInputTokens == 0 {
		value.CacheReadInputTokens = value.CachedInputTokens
	}
	return &api.AgentUsage{
		InputTokens:              value.InputTokens,
		CacheCreationInputTokens: value.CacheCreationInputTokens,
		CacheReadInputTokens:     value.CacheReadInputTokens,
		OutputTokens:             value.OutputTokens,
		ReasoningOutputTokens:    value.ReasoningOutputTokens,
		TotalTokens:              value.TotalTokens,
	}
}

func contentString(value json.RawMessage) string {
	return contentStringLimit(value, maxEventContent)
}

func contentStringLimit(value json.RawMessage, limit int) string {
	var text string
	if json.Unmarshal(value, &text) == nil {
		return truncate(text, limit)
	}
	var blocks []struct {
		Type    string          `json:"type"`
		Text    string          `json:"text"`
		Content json.RawMessage `json:"content"`
	}
	if json.Unmarshal(value, &blocks) == nil {
		if limit <= 0 {
			parts := make([]string, 0, len(blocks))
			for _, block := range blocks {
				switch {
				case block.Text != "":
					parts = append(parts, block.Text)
				case block.Type == "image":
					parts = append(parts, "[image]")
				case len(block.Content) > 0:
					parts = append(parts, contentStringLimit(block.Content, 0))
				}
			}
			return strings.Join(parts, "\n")
		}

		var content strings.Builder
		remaining := limit
		hasPart := false
		for _, block := range blocks {
			if block.Text == "" && block.Type != "image" && len(block.Content) == 0 {
				continue
			}
			if hasPart && appendStringPrefix(&content, "\n", &remaining) {
				return content.String() + "…"
			}

			var part string
			switch {
			case block.Text != "":
				part = block.Text
			case block.Type == "image":
				part = "[image]"
			default:
				nestedLimit := remaining
				if nestedLimit == 0 {
					nestedLimit = 1
				}
				part = contentStringLimit(block.Content, nestedLimit)
			}
			hasPart = true
			if appendStringPrefix(&content, part, &remaining) {
				return content.String() + "…"
			}
		}
		return content.String()
	}
	return truncate(string(value), limit)
}

func appendStringPrefix(builder *strings.Builder, value string, remaining *int) bool {
	if value == "" {
		return false
	}
	if *remaining <= 0 {
		return true
	}

	count := 0
	for index := range value {
		if count == *remaining {
			builder.WriteString(value[:index])
			*remaining = 0
			return true
		}
		count++
	}
	builder.WriteString(value)
	*remaining -= count
	return false
}

func rawToAny(value json.RawMessage, contentLimit int) any {
	var parsed any
	if json.Unmarshal(value, &parsed) == nil {
		return parsed
	}
	return map[string]any{"raw": truncate(string(value), rawToolInputLimit(contentLimit))}
}

func rawToolInputLimit(contentLimit int) int {
	if contentLimit == 0 {
		return 0
	}
	return 64 * 1024
}

func parseTimestamp(value string) time.Time {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

func truncate(value string, limit int) string {
	if limit <= 0 || len(value) <= limit {
		return value
	}
	count := 0
	for index := range value {
		if count == limit {
			return value[:index] + "…"
		}
		count++
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]bool, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

func asBool(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		return typed == "true" || typed == "1"
	default:
		return false
	}
}
