package agent

import (
	"encoding/json"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func enrichToolSemantics(event *api.AgentEvent) {
	if event == nil || !isToolEventType(event.Type) {
		return
	}
	if strings.TrimSpace(event.ToolKind) == "" {
		switch canonicalToolName(event.Provider, event.ToolName) {
		case "shell":
			event.ToolKind = "ran"
		case "glob":
			event.ToolKind = "glob"
		case "grep":
			event.ToolKind = "grep"
		case "read":
			event.ToolKind = "read"
		case "edit", "apply_patch":
			event.ToolKind = "edit"
		case "write":
			event.ToolKind = "write"
		case "fetch":
			event.ToolKind = "fetch"
		case "web_search":
			event.ToolKind = "search"
		case "subagent":
			event.ToolKind = "subagent"
		case "ask_user_question":
			event.ToolKind = "ask"
		case "permission_request":
			event.ToolKind = "permission"
		default:
			if event.ToolName != "" {
				event.ToolKind = strings.ToLower(strings.TrimSpace(event.ToolName))
			} else {
				event.ToolKind = "tool"
			}
		}
	}
	if strings.TrimSpace(event.ToolDetail) == "" {
		event.ToolDetail = toolInputDetail(event.ToolInput)
	}
}

func toolInputDetail(input any) string {
	var detail string
	switch value := input.(type) {
	case string:
		detail = strings.TrimSpace(value)
	case map[string]any:
		for _, key := range []string{"command", "cmd", "CommandLine", "code", "script", "path", "file_path", "filePath", "filepath", "AbsolutePath", "TargetFile", "file", "filename", "target", "query", "pattern", "url", "Url", "prompt", "instruction"} {
			if candidate, ok := value[key].(string); ok && strings.TrimSpace(candidate) != "" {
				detail = strings.TrimSpace(candidate)
				break
			}
		}
		if detail == "" {
			for _, key := range []string{"args", "argv"} {
				if values, ok := toolStringSlice(value[key]); ok {
					detail = strings.Join(values, " ")
					if detail != "" {
						break
					}
				}
			}
		}
	case []string:
		detail = strings.Join(value, " ")
	case []any:
		if values, ok := toolStringSlice(value); ok {
			detail = strings.Join(values, " ")
		}
	case json.RawMessage:
		var decoded any
		if json.Unmarshal(value, &decoded) == nil {
			return toolInputDetail(decoded)
		}
	}
	if len(detail) > 512 {
		return detail[:512] + "…"
	}
	return detail
}

func isToolEventType(value string) bool {
	normalized := strings.ToLower(strings.TrimSpace(strings.NewReplacer("-", "_", ".", "_").Replace(value)))
	switch normalized {
	case "tool_call", "tool_use", "tool", "tool_output", "tool_result",
		"tool_started", "tool_updated", "tool_completed", "tool_failed":
		return true
	default:
		return false
	}
}

func toolStringSlice(value any) ([]string, bool) {
	switch values := value.(type) {
	case []string:
		result := make([]string, 0, len(values))
		for _, value := range values {
			if text := strings.TrimSpace(value); text != "" {
				result = append(result, text)
			}
		}
		return result, true
	case []any:
		result := make([]string, 0, len(values))
		for _, value := range values {
			text, ok := value.(string)
			if !ok {
				return nil, false
			}
			if text = strings.TrimSpace(text); text != "" {
				result = append(result, text)
			}
		}
		return result, true
	default:
		return nil, false
	}
}

// canonicalToolName maps a provider-native tool name to a provider-neutral
// canonical name the UI can render directly. Unknown names are returned
// lowercased (and trimmed) so the UI sees a stable shape even for tools we
// have never seen. The closed set of canonical values is the single
// vocabulary the Web and iOS displayToolName label maps are keyed on.
//
// The three providers each use a different vocabulary for the same conceptual
// action (claude's `Bash` is codex's `local_shell_call` is opencode's `bash`).
// Funneling all three through this function lets iOS and Web keep their tool
// label maps keyed on canonical names only, with no provider branches.
func canonicalToolName(provider, raw string) string {
	name := strings.ToLower(strings.TrimSpace(strings.ReplaceAll(raw, "-", "_")))
	if name == "" {
		return ""
	}
	switch name {
	// shell
	case "bash", "shell", "local_shell_call", "exec_command", "bash_cmd", "run_command", "exec", "execute", "shell_command":
		return "shell"
	// edit
	case "edit", "edit_file", "str_replace_editor", "edit_file_v2", "replace_file_content":
		return "edit"
	// write
	case "write", "write_file", "create_file", "write_to_file":
		return "write"
	// read
	case "read", "read_file", "view", "view_file":
		return "read"
	// grep
	case "grep", "ripgrep", "rg", "search_content", "grep_search":
		return "grep"
	// glob
	case "glob", "find_files", "list_files", "find_by_name", "list_dir":
		return "glob"
	// web search
	case "websearch", "web_search", "web_search_call", "search_web":
		return "web_search"
	// web fetch
	case "webfetch", "web_fetch", "fetch_url", "read_url_content":
		return "fetch"
	// subagent
	case "task", "subagent", "agent", "delegate", "invoke_subagent", "define_subagent", "spawn_agent", "call_omo_agent":
		return "subagent"
	// claude and antigravity structured tool calls — these project to RFC 0010 events and
	// also surface as tool_call for clients that haven't learned the
	// structured type yet.
	case "askuserquestion", "ask_user_question", "ask_question", "request_user_input", "request_user_input_async", "question":
		return "ask_user_question"
	case "permissionrequest", "permission_request":
		return "permission_request"
	case "update_plan", "updateplan", "plan_update", "planupdate":
		return "update_plan"
	case "todowrite", "todo_write", "write_todos", "update_todos":
		return "todowrite"
	}
	if name == "apply_patch" {
		return "apply_patch"
	}
	return name
}

// canonicalToolStatus normalizes raw tool statuses across all providers into
// the canonical set: "running", "success", "error", "interrupted".
func canonicalToolStatus(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "completed", "success", "done", "ok":
		return "success"
	case "failed", "error":
		return "error"
	case "interrupted", "cancelled", "canceled", "aborted":
		return "interrupted"
	case "in_progress", "running", "pending", "working":
		return "running"
	default:
		if raw == "" {
			return ""
		}
		return "success"
	}
}

// eventIsRenderable reports whether the event carries enough payload to be
// drawn. The provider parsers already drop most noise, but a defensive final
// check at the parse entry keeps the UI from ever seeing an empty card. This
// is the single source of truth for what an event needs to qualify as
// "renderable" by any client.
func eventIsRenderable(e api.AgentEvent) bool {
	if strings.TrimSpace(e.Content) != "" {
		return true
	}
	if strings.TrimSpace(e.Output) != "" {
		return true
	}
	if strings.TrimSpace(e.Error) != "" {
		return true
	}
	if e.Usage != nil {
		return true
	}
	if e.ToolInput != nil {
		return true
	}
	switch e.Type {
	case "tool_call", "tool_output", "tool_use", "tool_result",
		"tool_started", "tool_updated", "tool_completed", "tool_failed",
		"question", "permission", "plan", "todo", "goal",
		"activity", "plugin", "subagent", "compaction", "config", "diff", "diagnostics", "queue":
		return true
	}
	return false
}

// isCompactionContext reports whether content represents an agent history compaction or checkpoint.
func isCompactionContext(content string) bool {
	trimmed := strings.TrimSpace(strings.TrimPrefix(content, "\ufeff"))
	lower := strings.ToLower(trimmed)
	if strings.HasPrefix(lower, "# resuming from a compaction") {
		return true
	}
	if strings.HasPrefix(lower, "{{ checkpoint") || strings.Contains(lower, "the earlier parts of this conversation have been truncated") {
		return true
	}
	if strings.HasPrefix(lower, "<summary>") || strings.HasPrefix(lower, "<compact>") || strings.HasPrefix(lower, "<compaction>") {
		return true
	}
	if strings.HasPrefix(lower, "<context_summary>") {
		return true
	}
	return false
}

// isInterruptionContext reports provider sentinel text that marks a turn as
// aborted. It is deliberately separate from system-injected context because
// the mobile timeline should show a small interruption marker rather than hide
// the row as generic instructions.
func isInterruptionContext(content string) bool {
	trimmed := strings.TrimSpace(strings.TrimPrefix(content, "\ufeff"))
	lower := strings.ToLower(trimmed)
	return strings.HasPrefix(lower, "[request interrupted") || strings.Contains(lower, "<turn_aborted>")
}

// compactionSummaryText removes provider wrapper tags while preserving the
// actual context text. The wrapper is transport markup, not useful content for
// a collapsed summary card.
func compactionSummaryText(content string) string {
	value := strings.TrimSpace(strings.TrimPrefix(content, "\ufeff"))
	lower := strings.ToLower(value)
	for _, tag := range []string{"context_summary", "summary", "compact", "compaction"} {
		open := "<" + tag + ">"
		close := "</" + tag + ">"
		if !strings.HasPrefix(lower, open) {
			continue
		}
		if end := strings.Index(lower, close); end >= len(open) {
			if inner := strings.TrimSpace(value[len(open):end]); inner != "" {
				return inner
			}
		}
	}
	// Antigravity can put the context summary before a user request in one
	// envelope. Prefer that bounded section over the following prompt.
	if start := strings.Index(lower, "<context_summary>"); start >= 0 {
		start += len("<context_summary>")
		if end := strings.Index(lower[start:], "</context_summary>"); end >= 0 {
			if inner := strings.TrimSpace(value[start : start+end]); inner != "" {
				return inner
			}
		}
	}
	return value
}

// isSystemInjectedUserContext reports whether a message marked with user role
// was actually injected by the CLI, environment, or system rather than authored by the user.
func isSystemInjectedUserContext(content string) bool {
	trimmed := strings.TrimSpace(strings.TrimPrefix(content, "\ufeff"))
	lower := strings.ToLower(trimmed)
	if isCompactionContext(trimmed) {
		return true
	}
	if strings.HasPrefix(lower, "<environment_context>") || strings.HasPrefix(lower, "<environment_context") {
		return true
	}
	if strings.HasPrefix(lower, "# agents.md") || strings.HasPrefix(lower, "<rule[") {
		return true
	}
	if strings.HasPrefix(lower, "<collaboration_mode>") || strings.HasPrefix(lower, "<collaboration_mode") {
		return true
	}
	if strings.Contains(lower, "<permissions instructions>") || strings.Contains(lower, "<permissions_instructions>") {
		return true
	}
	if strings.HasPrefix(lower, "<skill>") || strings.HasPrefix(lower, "<skill ") || strings.HasPrefix(lower, "<skills>") || strings.HasPrefix(lower, "<skills_instructions>") {
		return true
	}
	if isInterruptionContext(trimmed) {
		return true
	}
	if strings.HasPrefix(lower, "<user_instructions>") || strings.HasPrefix(lower, "<system_instructions>") || strings.HasPrefix(lower, "<system_message>") {
		return true
	}
	if strings.HasPrefix(lower, "<identity>") || strings.HasPrefix(lower, "<user_information>") || strings.HasPrefix(lower, "<user_rules>") {
		return true
	}
	if strings.HasPrefix(lower, "the following is a <system_message>") {
		return true
	}
	if strings.HasPrefix(lower, "[request interrupted") {
		return true
	}
	// Claude Code records several provider-generated command and reminder
	// envelopes as user-role text. They are protocol metadata, not authored
	// conversation, and must not become a mobile user bubble.
	for _, prefix := range []string{
		"<local-command-",
		"<command-name>",
		"<command-message>",
		"<command-stdout>",
		"<system-reminder",
		"<task-notification",
		"<ide_",
	} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	if strings.HasPrefix(lower, "<user_request>") || strings.Contains(lower, "<additional_metadata>") {
		return true
	}
	return false
}

// canonicalizeAgentEvent normalizes events to preserve proper role and semantic boundaries.
func canonicalizeAgentEvent(e *api.AgentEvent) {
	if e == nil {
		return
	}
	if isInterruptionContext(e.Content) {
		e.Type = "system"
		e.Role = "system"
		e.StopReason = "interrupted"
		return
	}
	if e.Type == "user" {
		if isCompactionContext(e.Content) {
			summary := compactionSummaryText(e.Content)
			if summary == "" {
				summary = "History compacted"
			}
			e.Type = "compaction"
			e.Role = "system"
			e.Content = "History compacted"
			if e.Payload == nil {
				e.Payload = make(map[string]any)
			}
			if _, ok := e.Payload["compactionId"]; !ok {
				e.Payload["compactionId"] = firstNonEmpty(e.ID, "compaction")
			}
			if raw, ok := e.Payload["summary"].(string); !ok || strings.TrimSpace(raw) == "" || strings.EqualFold(strings.TrimSpace(raw), "History compacted") {
				e.Payload["summary"] = summary
			}
		} else if isSystemInjectedUserContext(e.Content) {
			e.Type = "system_instructions"
			e.Role = "system"
		}
	}
}

// compactRenderable returns the events that qualify as renderable,
// preserving order. The non-renderable events are dropped before the
// activity tracker observes them so they cannot influence lifecycle.
func compactRenderable(events []api.AgentEvent) []api.AgentEvent {
	out := events[:0]
	for _, e := range events {
		if eventIsRenderable(e) {
			out = append(out, e)
		}
	}
	return out
}
