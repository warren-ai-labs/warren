package agent

import (
	"encoding/json"
	"fmt"
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
		canonicalizeAgentEvent(&events[index])
		enrichToolSemantics(&events[index])
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
	case "antigravity":
		return newAntigravityParser(contentLimit)
	default:
		return newFallbackParser(provider, contentLimit)
	}
}

var structuredAgentEventTypes = map[string]struct{}{
	"question": {}, "permission": {}, "plan": {}, "todo": {}, "goal": {},
	"activity": {}, "plugin": {}, "subagent": {}, "attachment": {}, "config": {}, "compaction": {},
	"diff": {}, "diagnostics": {}, "queue": {},
}

func structuredAgentEventType(source string) string {
	normalized := strings.ToLower(strings.TrimSpace(strings.NewReplacer("-", "_", ".", "_").Replace(source)))
	// Claude records permission-mode changes (for example
	// `bypassPermissions`) as control-plane rows. They are not permission
	// interactions; treating the generic `permission_` prefix as one creates a
	// phantom approval card in clients.
	if normalized == "permission_mode" {
		return ""
	}
	if normalized == "task" || normalized == "tasks" || normalized == "task_list" || normalized == "tasklist" || normalized == "task_updated" || normalized == "tasks_updated" || normalized == "task_list_updated" || normalized == "tasklist_updated" || normalized == "todo_list_updated" || normalized == "checklist" || normalized == "checklists" || strings.HasPrefix(normalized, "checklist_") {
		return "todo"
	}
	for _, candidate := range []string{"question", "permission", "plan", "todo", "goal", "activity", "plugin", "subagent", "attachment", "config", "compaction", "diff", "diagnostics", "queue"} {
		if normalized == candidate || strings.HasPrefix(normalized, candidate+"_") {
			return candidate
		}
	}
	return ""
}

// structuredEventSummary extracts display text without exposing provider
// content blocks or raw JSON to clients. Plan/Todo records commonly use a
// string, an OpenAI-style text block array, or a nested content object.
func structuredEventSummary(source map[string]any, limit int) string {
	for _, key := range []string{"summary", "description", "objective", "content", "text", "detail", "body", "message"} {
		if value, ok := source[key]; ok {
			if text := structuredTextValue(value, limit); text != "" {
				return text
			}
		}
	}
	return ""
}

func structuredEventSummaryMap(value any, limit int) string {
	object, ok := value.(map[string]any)
	if !ok {
		return ""
	}
	return structuredEventSummary(object, limit)
}

func structuredTextValue(value any, limit int) string {
	switch typed := value.(type) {
	case string:
		return truncate(strings.TrimSpace(typed), limit)
	case []any:
		parts := make([]string, 0, len(typed))
		for _, item := range typed {
			if text := structuredTextValue(item, limit); text != "" {
				parts = append(parts, text)
			}
		}
		return truncate(strings.Join(parts, "\n"), limit)
	case []string:
		parts := make([]string, 0, len(typed))
		for _, item := range typed {
			if text := strings.TrimSpace(item); text != "" {
				parts = append(parts, text)
			}
		}
		return truncate(strings.Join(parts, "\n"), limit)
	case map[string]any:
		for _, key := range []string{"text", "output_text", "input_text", "value", "content", "summary", "description", "body", "message", "parts", "blocks", "children", "title"} {
			if nested, ok := typed[key]; ok {
				if text := structuredTextValue(nested, limit); text != "" {
					return text
				}
			}
		}
	}
	return ""
}

func structuredObjectID(value any) string {
	object, ok := value.(map[string]any)
	if !ok {
		return ""
	}
	return firstNonEmpty(
		stringValue(object["planId"]),
		stringValue(object["plan_id"]),
		stringValue(object["todoId"]),
		stringValue(object["todo_id"]),
		stringValue(object["taskListId"]),
		stringValue(object["task_list_id"]),
		stringValue(object["id"]),
	)
}

func structuredNestedString(value any, keys ...string) string {
	object, ok := value.(map[string]any)
	if !ok {
		return ""
	}
	for _, key := range keys {
		if text := stringValue(object[key]); text != "" {
			return text
		}
	}
	return ""
}

func structuredItemsFromFields(source map[string]any, limit int, fields ...string) []map[string]any {
	for _, field := range fields {
		if value, ok := source[field]; ok {
			if items := structuredItemsFromValue(value, limit); len(items) > 0 {
				return items
			}
		}
	}
	return nil
}

func structuredItemsFromValue(value any, limit int) []map[string]any {
	switch typed := value.(type) {
	case []any:
		items := make([]map[string]any, 0, len(typed))
		for index, item := range typed {
			if normalized := normalizeStructuredItem(item, index, limit); normalized != nil {
				items = append(items, normalized)
			}
		}
		return items
	case []map[string]any:
		items := make([]map[string]any, 0, len(typed))
		for index, item := range typed {
			if normalized := normalizeStructuredItem(item, index, limit); normalized != nil {
				items = append(items, normalized)
			}
		}
		return items
	case []string:
		items := make([]map[string]any, 0, len(typed))
		for index, item := range typed {
			if normalized := normalizeStructuredItem(item, index, limit); normalized != nil {
				items = append(items, normalized)
			}
		}
		return items
	case map[string]any:
		for _, field := range []string{"items", "steps", "plan", "todos", "tasks", "entries"} {
			if nested, ok := typed[field]; ok {
				if items := structuredItemsFromValue(nested, limit); len(items) > 0 {
					return items
				}
			}
		}
		if item := normalizeStructuredItem(typed, 0, limit); item != nil {
			return []map[string]any{item}
		}
	}
	return nil
}

func normalizeStructuredItem(value any, index, limit int) map[string]any {
	object, isObject := value.(map[string]any)
	label := ""
	state := ""
	id := ""
	if isObject {
		label = firstNonEmpty(
			structuredTextValue(object["label"], limit),
			structuredTextValue(object["title"], limit),
			structuredTextValue(object["step"], limit),
			structuredTextValue(object["task"], limit),
			structuredTextValue(object["todo"], limit),
			structuredTextValue(object["content"], limit),
			structuredTextValue(object["text"], limit),
			structuredTextValue(object["prompt"], limit),
			structuredTextValue(object["description"], limit),
			structuredTextValue(object["summary"], limit),
			structuredTextValue(object["activeForm"], limit),
			structuredTextValue(object["active_form"], limit),
			structuredTextValue(object["name"], limit),
		)
		id = firstNonEmpty(
			stringValue(object["id"]),
			stringValue(object["itemId"]),
			stringValue(object["item_id"]),
			stringValue(object["stepId"]),
			stringValue(object["step_id"]),
			stringValue(object["todoId"]),
			stringValue(object["todo_id"]),
			stringValue(object["taskId"]),
			stringValue(object["task_id"]),
			stringValue(object["taskID"]),
			stringValue(object["todoID"]),
		)
		state = firstNonEmpty(stringValue(object["state"]), stringValue(object["status"]))
		if state == "" {
			completed := asBool(object["completed"]) || asBool(object["isCompleted"]) || asBool(object["done"]) || asBool(object["checked"])
			if _, present := object["completed"]; present || object["isCompleted"] != nil || object["done"] != nil || object["checked"] != nil {
				if completed {
					state = "completed"
				} else {
					state = "pending"
				}
			}
		}
	} else if text, ok := value.(string); ok {
		label = strings.TrimSpace(text)
	}
	if label == "" {
		return nil
	}
	if id == "" {
		id = fmt.Sprintf("item-%d", index)
	}
	return map[string]any{
		"id":    id,
		"title": label,
		"label": label,
		"state": canonicalStepStatus(state),
	}
}

func normalizeStructuredPlanPayload(source map[string]any, fallbackID string, limit int) map[string]any {
	planObject := source["plan"]
	payload := map[string]any{
		"planId": firstNonEmpty(
			stringValue(source["planId"]),
			stringValue(source["plan_id"]),
			structuredObjectID(source["plan"]),
			stringValue(source["id"]),
			fallbackID,
			"plan",
		),
		"title": truncate(firstNonEmpty(stringValue(source["title"]), structuredNestedString(planObject, "title", "name"), "Plan"), limit),
	}
	items := structuredItemsFromFields(source, limit, "items", "steps", "plan", "tasks", "todos")
	if items == nil {
		items = []map[string]any{}
	}
	payload["items"] = items
	if summary := firstNonEmpty(structuredEventSummary(source, limit), structuredEventSummaryMap(planObject, limit)); summary != "" {
		payload["summary"] = summary
	}
	state := firstNonEmpty(stringValue(source["state"]), stringValue(source["status"]), structuredNestedString(planObject, "state", "status"))
	if state == "" {
		if items, ok := payload["items"].([]map[string]any); ok && len(items) > 0 {
			state = calculatePlanState(items)
		} else {
			state = "in_progress"
		}
	}
	payload["state"] = canonicalStepStatus(state)
	return payload
}

func normalizeStructuredTodoPayload(source map[string]any, fallbackID string, limit int) map[string]any {
	todoObject := source["todo"]
	payload := map[string]any{
		"todoId": firstNonEmpty(
			stringValue(source["todoId"]),
			stringValue(source["todo_id"]),
			stringValue(source["taskListId"]),
			stringValue(source["task_list_id"]),
			structuredObjectID(source["todo"]),
			stringValue(source["id"]),
			fallbackID,
			"todos",
		),
		"title": truncate(firstNonEmpty(stringValue(source["title"]), structuredNestedString(todoObject, "title", "name"), "Todos"), limit),
	}
	items := structuredItemsFromFields(source, limit, "items", "todos", "tasks", "steps", "plan")
	if items == nil {
		items = []map[string]any{}
	}
	payload["items"] = items
	if summary := firstNonEmpty(structuredEventSummary(source, limit), structuredEventSummaryMap(todoObject, limit)); summary != "" {
		payload["summary"] = summary
	}
	state := firstNonEmpty(stringValue(source["state"]), stringValue(source["status"]), structuredNestedString(todoObject, "state", "status"))
	if state == "" {
		if items, ok := payload["items"].([]map[string]any); ok && len(items) > 0 {
			state = calculatePlanState(items)
		} else {
			// An empty TodoWrite list is the provider's explicit clear operation.
			state = "completed"
		}
	}
	payload["state"] = canonicalStepStatus(state)
	return payload
}

func mergeStructuredSource(primary, nested map[string]any) map[string]any {
	merged := make(map[string]any, len(primary)+len(nested))
	for key, value := range primary {
		merged[key] = value
	}
	for key, value := range nested {
		merged[key] = value
	}
	return merged
}

// projectStructuredAgentEvent turns provider-native structured records into
// the small, provider-neutral payload understood by Agent View.
func projectStructuredAgentEvent(provider string, fallbackType string, raw json.RawMessage, timestamp time.Time) *api.AgentEvent {
	return projectStructuredAgentEventWithLimit(provider, fallbackType, raw, timestamp, maxEventContent)
}

func projectStructuredAgentEventWithLimit(provider string, fallbackType string, raw json.RawMessage, timestamp time.Time, contentLimit int) *api.AgentEvent {
	var object map[string]any
	if len(raw) == 0 || json.Unmarshal(raw, &object) != nil {
		return nil
	}
	outerType := firstStringValue(object["type"], object["eventType"], object["customType"], fallbackType)
	outerID := firstStringValue(object["id"], object["eventId"], object["event_id"], object["uuid"])
	source := object
	if nested, ok := object["payload"].(map[string]any); ok {
		source = nested
	}
	// Pi extensions and a few provider bridges put the structured record under
	// data/event rather than payload. Preserve the outer discriminator while
	// merging nested fields, because nested objects often omit their own type.
	for _, key := range []string{"data", "event"} {
		if nested, ok := source[key].(map[string]any); ok {
			candidate := firstStringValue(nested["type"], nested["eventType"], nested["kind"], nested["customType"])
			currentType := firstStringValue(source["type"], source["eventType"], source["customType"], source["kind"], outerType)
			if structuredAgentEventType(candidate) != "" || structuredAgentEventType(currentType) != "" {
				if structuredAgentEventType(candidate) == "" {
					// A structured outer envelope can wrap an ordinary provider
					// record in data. Keep the outer plan/todo discriminator.
					fields := make(map[string]any, len(nested))
					for nestedKey, nestedValue := range nested {
						if nestedKey != "type" && nestedKey != "eventType" && nestedKey != "customType" && nestedKey != "kind" {
							fields[nestedKey] = nestedValue
						}
					}
					source = mergeStructuredSource(source, fields)
				} else {
					source = mergeStructuredSource(source, nested)
				}
				if candidate != "" {
					outerType = candidate
				}
			}
		}
	}
	rawType := firstStringValue(source["type"], source["eventType"], outerType)
	if structuredAgentEventType(rawType) == "" {
		// A custom record may use `customType` as its discriminator while the
		// top-level type remains `custom` or `custom_message`.
		customType := firstStringValue(source["customType"], source["kind"], object["customType"], object["kind"])
		if structuredAgentEventType(customType) != "" {
			rawType = customType
			if nested, ok := object["data"].(map[string]any); ok {
				source = mergeStructuredSource(source, nested)
			}
		} else {
			rawType = firstNonEmpty(customType, rawType)
		}
	}
	normalized := strings.ToLower(strings.NewReplacer("-", "_", ".", "_").Replace(strings.TrimSpace(rawType)))
	kind := structuredAgentEventType(normalized)
	if _, ok := structuredAgentEventTypes[kind]; !ok {
		return nil
	}
	payload := make(map[string]any)
	copyStructuredField(payload, source, "requestId", "requestId", "request_id")
	copyStructuredField(payload, source, "title", "title")
	copyStructuredField(payload, source, "description", "description")
	copyStructuredField(payload, source, "questions", "questions")
	copyStructuredField(payload, source, "action", "action")
	if kind == "queue" {
		copyStructuredField(payload, source, "action", "action", "operation")
		copyStructuredField(payload, source, "content", "content", "prompt", "text")
		copyStructuredField(payload, source, "queueId", "queueId", "queue_id")
		copyStructuredField(payload, source, "order", "order", "queue_order")
	}
	copyStructuredField(payload, source, "options", "options")
	copyStructuredField(payload, source, "planId", "planId", "plan_id")
	copyStructuredField(payload, source, "todoId", "todoId", "todo_id", "taskListId", "task_list_id")
	copyStructuredField(payload, source, "goalId", "goalId", "goal_id")
	copyStructuredField(payload, source, "objective", "objective")
	copyStructuredField(payload, source, "steps", "steps")
	copyStructuredField(payload, source, "activityId", "activityId", "activity_id")
	copyStructuredField(payload, source, "pluginId", "pluginId", "plugin_id")
	copyStructuredField(payload, source, "subagentId", "subagentId", "subagent_id")
	copyStructuredField(payload, source, "attachmentId", "attachmentId", "attachment_id")
	copyStructuredField(payload, source, "sessionId", "sessionId", "session_id", "threadId", "thread_id")
	copyStructuredField(payload, source, "items", "items")
	copyStructuredField(payload, source, "label", "label")
	copyStructuredField(payload, source, "name", "name")
	copyStructuredField(payload, source, "summary", "summary")
	copyStructuredField(payload, source, "detail", "detail")
	copyStructuredField(payload, source, "mime", "mime", "MIME")
	copyStructuredField(payload, source, "size", "size")
	copyStructuredField(payload, source, "file", "file", "filePath", "file_path")
	copyStructuredField(payload, source, "files", "files")
	copyStructuredField(payload, source, "additions", "additions")
	copyStructuredField(payload, source, "deletions", "deletions")
	copyStructuredField(payload, source, "diff", "diff", "patch")
	copyStructuredField(payload, source, "diagnostics", "diagnostics")
	copyStructuredField(payload, source, "state", "state", "status")
	if st, ok := payload["state"].(string); ok && st != "" {
		payload["state"] = canonicalStepStatus(st)
	}
	copyStructuredField(payload, source, "model", "model")
	copyStructuredField(payload, source, "reasoningEffort", "reasoningEffort", "reasoning_effort", "effort")

	var content string
	switch kind {
	case "plan":
		planObject := source["plan"]
		if title := stringValue(payload["title"]); title != "" {
			payload["title"] = truncate(title, contentLimit)
		}
		planID := firstNonEmpty(
			stringValue(payload["planId"]),
			stringValue(source["planId"]),
			stringValue(source["plan_id"]),
			structuredObjectID(source["plan"]),
			stringValue(source["id"]),
			outerID,
			"plan",
		)
		payload["planId"] = planID
		if stringValue(payload["title"]) == "" {
			payload["title"] = truncate(firstNonEmpty(stringValue(source["title"]), structuredNestedString(planObject, "title", "name"), "Plan"), contentLimit)
		}
		items := structuredItemsFromFields(source, contentLimit, "items", "steps", "plan", "tasks", "todos")
		if items == nil {
			items = []map[string]any{}
		}
		payload["items"] = items
		content = firstNonEmpty(structuredEventSummary(source, contentLimit), structuredEventSummaryMap(planObject, contentLimit))
		if content != "" {
			payload["summary"] = content
		}
		if _, ok := payload["state"]; !ok {
			if items, ok := payload["items"].([]map[string]any); ok && len(items) > 0 {
				payload["state"] = calculatePlanState(items)
			} else {
				payload["state"] = "in_progress"
			}
		}
	case "todo":
		todoObject := source["todo"]
		if title := stringValue(payload["title"]); title != "" {
			payload["title"] = truncate(title, contentLimit)
		}
		todoID := firstNonEmpty(
			stringValue(payload["todoId"]),
			stringValue(source["todoId"]),
			stringValue(source["todo_id"]),
			stringValue(source["taskListId"]),
			stringValue(source["task_list_id"]),
			structuredObjectID(source["todo"]),
			stringValue(source["id"]),
			outerID,
			"todos",
		)
		payload["todoId"] = todoID
		if stringValue(payload["title"]) == "" {
			payload["title"] = truncate(firstNonEmpty(stringValue(source["title"]), structuredNestedString(todoObject, "title", "name"), "Todos"), contentLimit)
		}
		items := structuredItemsFromFields(source, contentLimit, "items", "todos", "tasks", "steps", "plan")
		if items == nil {
			items = []map[string]any{}
		}
		payload["items"] = items
		content = firstNonEmpty(structuredEventSummary(source, contentLimit), structuredEventSummaryMap(todoObject, contentLimit))
		if content != "" {
			payload["summary"] = content
		}
		if _, ok := payload["state"]; !ok {
			if items, ok := payload["items"].([]map[string]any); ok && len(items) > 0 {
				payload["state"] = calculatePlanState(items)
			} else {
				payload["state"] = "completed"
			}
		}
	}
	if len(payload) == 0 {
		return nil
	}
	if _, ok := payload["state"]; !ok {
		switch {
		case strings.HasSuffix(normalized, "_asked") || strings.HasSuffix(normalized, "_requested"):
			payload["state"] = "pending"
		case strings.HasSuffix(normalized, "_resolved") || strings.HasSuffix(normalized, "_replied") || strings.HasSuffix(normalized, "_rejected"):
			payload["state"] = "resolved"
		case kind == "queue":
			action := strings.ToLower(stringValue(payload["action"]))
			switch action {
			case "dequeue":
				payload["state"] = "dequeued"
			case "remove":
				payload["state"] = "cancelled"
			default:
				payload["state"] = "queued"
			}
		}
	}
	requestID := stringValue(payload["requestId"])
	id := firstStringValue(source["id"], source["eventId"], source["event_id"], outerID)
	// Plan/Todo updates are snapshots. Their provider event id can differ
	// from the stable object identity, so prefer the normalized payload key
	// whenever one is present. This keeps timeline coalescing stable across
	// providers that emit a fresh envelope id for every update.
	switch kind {
	case "plan":
		id = firstNonEmpty(stringValue(payload["planId"]), id)
	case "todo":
		id = firstNonEmpty(stringValue(payload["todoId"]), id)
	}
	if id == "" {
		switch kind {
		case "question", "permission":
			id = requestID
		case "plan":
			id = stringValue(payload["planId"])
		case "todo":
			id = stringValue(payload["todoId"])
		case "goal":
			id = firstNonEmpty(stringValue(payload["goalId"]), stringValue(payload["threadId"]), stringValue(payload["sessionId"]))
		case "activity":
			id = stringValue(payload["activityId"])
		case "plugin":
			id = stringValue(payload["pluginId"])
		case "subagent":
			id = stringValue(payload["subagentId"])
		case "attachment":
			id = stringValue(payload["attachmentId"])
		case "config":
			id = "config"
		case "compaction":
			id = "compaction"
		case "diff":
			id = firstNonEmpty(stringValue(payload["file"]), stringValue(payload["diffId"]), "diff")
		case "diagnostics":
			id = firstNonEmpty(stringValue(payload["file"]), "diagnostics")
		case "queue":
			id = firstNonEmpty(stringValue(payload["queueId"]), stringValue(payload["requestId"]), stringValue(source["uuid"]))
			if id == "" {
				action := firstNonEmpty(stringValue(payload["action"]), "item")
				if !timestamp.IsZero() {
					id = fmt.Sprintf("queue-%s-%d", action, timestamp.UnixNano())
				} else {
					id = fmt.Sprintf("queue-%s", action)
				}
			}
		}
	}
	if (kind == "plan" || kind == "todo") && content != "" {
		return &api.AgentEvent{Provider: provider, ID: id, Type: kind, Content: content, Payload: payload, Timestamp: timestamp}
	}
	return &api.AgentEvent{Provider: provider, ID: id, Type: kind, Payload: payload, Timestamp: timestamp}
}

func canonicalStepStatus(raw string) string {
	normalized := strings.ToLower(strings.TrimSpace(strings.NewReplacer("-", "_", " ", "_").Replace(raw)))
	switch normalized {
	case "completed", "complete", "done", "finished", "success":
		return "completed"
	case "in_progress", "inprogress", "running", "working", "active", "started":
		return "in_progress"
	case "failed", "error", "cancelled", "canceled", "aborted":
		return "cancelled"
	case "pending", "todo", "not_started", "notstarted":
		return "pending"
	default:
		if normalized == "" {
			return "pending"
		}
		return normalized
	}
}

func calculatePlanState(items []map[string]any) string {
	if len(items) == 0 {
		return "in_progress"
	}
	overall := "completed"
	for _, item := range items {
		state := stringValue(item["state"])
		if state != "completed" && state != "cancelled" {
			overall = "in_progress"
			break
		}
	}
	return overall
}

func intValue(value any) int {
	switch v := value.(type) {
	case int:
		return v
	case int64:
		return int(v)
	case float64:
		return int(v)
	case string:
		var i int
		fmt.Sscanf(v, "%d", &i)
		return i
	default:
		return 0
	}
}

// parseUnifiedDiffStats counts addition and deletion lines in a unified diff.
func parseUnifiedDiffStats(diff string) (additions, deletions int) {
	for _, line := range strings.Split(diff, "\n") {
		if strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---") {
			continue
		}
		if strings.HasPrefix(line, "+") {
			additions++
		} else if strings.HasPrefix(line, "-") {
			deletions++
		}
	}
	return
}

// parseStructuredPatchChunks extracts additions, deletions, and reconstructed diff from structuredPatch chunks.
func parseStructuredPatchChunks(raw any) (additions, deletions int, diff string) {
	chunks, ok := raw.([]any)
	if !ok {
		return
	}
	var diffLines []string
	for _, chunk := range chunks {
		cm, ok := chunk.(map[string]any)
		if !ok {
			continue
		}
		lines, ok := cm["lines"].([]any)
		if !ok {
			continue
		}
		for _, lineItem := range lines {
			l := stringValue(lineItem)
			diffLines = append(diffLines, l)
			if strings.HasPrefix(l, "+") {
				additions++
			} else if strings.HasPrefix(l, "-") {
				deletions++
			}
		}
	}
	if len(diffLines) > 0 {
		diff = strings.Join(diffLines, "\n")
	}
	return
}

// parseClaudeDiagnostics parses raw diagnostics into normalized api.AgentDiagnostic items.
func parseClaudeDiagnostics(raw any) []api.AgentDiagnostic {
	var results []api.AgentDiagnostic
	diagMap, ok := raw.(map[string]any)
	if !ok {
		return nil
	}
	for filePath, fileDiags := range diagMap {
		items, ok := fileDiags.([]any)
		if !ok {
			continue
		}
		for _, item := range items {
			dm, ok := item.(map[string]any)
			if !ok {
				continue
			}
			diag := api.AgentDiagnostic{
				File:    filePath,
				Message: stringValue(dm["message"]),
				Source:  stringValue(dm["source"]),
				Code:    stringValue(dm["code"]),
			}
			switch intValue(dm["severity"]) {
			case 1:
				diag.Severity = "error"
			case 2:
				diag.Severity = "warning"
			case 3:
				diag.Severity = "info"
			case 4:
				diag.Severity = "hint"
			default:
				diag.Severity = firstNonEmpty(stringValue(dm["severity"]), "error")
			}
			if rng, ok := dm["range"].(map[string]any); ok {
				if start, ok := rng["start"].(map[string]any); ok {
					diag.Line = intValue(start["line"])
					diag.Column = intValue(start["character"])
				}
				if end, ok := rng["end"].(map[string]any); ok {
					diag.EndLine = intValue(end["line"])
					diag.EndColumn = intValue(end["character"])
				}
			}
			results = append(results, diag)
		}
	}
	return results
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

func parseQuestionOptions(rawOpts any) []any {
	options := make([]any, 0)
	if rawOpts == nil {
		return options
	}
	switch opts := rawOpts.(type) {
	case []any:
		for optIdx, optItem := range opts {
			if optStr, ok := optItem.(string); ok {
				options = append(options, map[string]any{
					"id":    optStr,
					"label": optStr,
				})
			} else if optMap, ok := optItem.(map[string]any); ok {
				label := firstNonEmpty(stringValue(optMap["label"]), stringValue(optMap["text"]), stringValue(optMap["title"]), stringValue(optMap["value"]))
				id := firstNonEmpty(stringValue(optMap["id"]), label, fmt.Sprintf("opt-%d", optIdx))
				entry := map[string]any{
					"id":    id,
					"label": label,
				}
				if desc := stringValue(optMap["description"]); desc != "" {
					entry["description"] = desc
				}
				options = append(options, entry)
			}
		}
	case []string:
		for _, optStr := range opts {
			options = append(options, map[string]any{
				"id":    optStr,
				"label": optStr,
			})
		}
	}
	return options
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

func parseTimestamp(value any) time.Time {
	switch v := value.(type) {
	case string:
		for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
			if parsed, err := time.Parse(layout, v); err == nil {
				return parsed
			}
		}
	case float64:
		if v > 1e11 {
			return time.UnixMilli(int64(v))
		}
		return time.Unix(int64(v), 0)
	case int64:
		if v > 1e11 {
			return time.UnixMilli(v)
		}
		return time.Unix(v, 0)
	case json.Number:
		if n, err := v.Int64(); err == nil {
			if n > 1e11 {
				return time.UnixMilli(n)
			}
			return time.Unix(n, 0)
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
