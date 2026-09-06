package agent

import (
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

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
	name := strings.ToLower(strings.TrimSpace(raw))
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
	case "update_plan":
		return "update_plan"
	case "todowrite":
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
	case "tool_call", "tool_output",
		"question", "permission", "plan", "todo",
		"activity", "plugin", "subagent", "compaction", "config", "diff", "diagnostics":
		return true
	}
	return false
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
