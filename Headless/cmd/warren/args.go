package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

var globalFlagNames = map[string]bool{
	"json":     true,
	"quiet":    true,
	"q":        true,
	"endpoint": true,
	"server":   true,
	"token":    true,
	"config":   true,
}

// hoistGlobalFlags moves global flags (--json, --quiet, -q, --endpoint, --server,
// --token, --config) to the front so they work before or after the subcommand.
// Go's flag package stops parsing at the first positional argument, which would
// otherwise silently ignore flags such as `warren session list --json`.
func hoistGlobalFlags(arguments []string) []string {
	extracted := make([]string, 0, len(arguments))
	rest := make([]string, 0, len(arguments))
	endpointAdd := isEndpointAdd(arguments)
	relayCommandSeen := false
	for index := 0; index < len(arguments); index++ {
		item := arguments[index]
		name, _, hasValue := splitFlag(item)
		if !globalFlagNames[name] {
			rest = append(rest, item)
			if item == "relay" && !relayCommandSeen {
				relayCommandSeen = true
			}
			continue
		}
		// endpoint add accepts its own --token; keep it local so the
		// subcommand receives it instead of treating it as the server token.
		// Relay subcommands likewise own --token: it may be an explicit
		// access capability or the compatibility spelling for a management
		// credential. A --token before `relay` remains a global flag.
		if name == "token" && (endpointAdd || relayCommandSeen) {
			rest = append(rest, item)
			continue
		}
		if hasValue || name == "json" || name == "quiet" || name == "q" {
			extracted = append(extracted, item)
			continue
		}
		if index+1 < len(arguments) && !strings.HasPrefix(arguments[index+1], "-") {
			extracted = append(extracted, item, arguments[index+1])
			index++
			continue
		}
		// Missing value: leave it for flag.Parse to report.
		rest = append(rest, item)
	}
	return append(extracted, rest...)
}

// isEndpointAdd reports whether the arguments target `endpoint add` (or its
// `server add` alias), where --token is a subcommand flag rather than a global
// server token.
func isEndpointAdd(arguments []string) bool {
	position := 0
	for index := 0; index < len(arguments); index++ {
		item := arguments[index]
		name, _, hasValue := splitFlag(item)
		if globalFlagNames[name] {
			if hasValue || name == "json" || name == "quiet" || name == "q" {
				continue
			}
			if index+1 < len(arguments) && !strings.HasPrefix(arguments[index+1], "-") {
				index++
			}
			continue
		}
		position++
		switch position {
		case 1:
			if item != "endpoint" && item != "server" {
				return false
			}
		case 2:
			return item == "add"
		default:
			return false
		}
	}
	return false
}

func splitFlag(item string) (name, value string, hasValue bool) {
	if item == "-q" {
		return "q", "", false
	}
	if !strings.HasPrefix(item, "--") {
		return "", "", false
	}
	trimmed := strings.TrimPrefix(item, "--")
	if split := strings.SplitN(trimmed, "=", 2); len(split) == 2 {
		return split[0], split[1], true
	}
	return trimmed, "", false
}

func canonicalResource(name string) string {
	if name == "worktree" {
		return "workspace"
	}
	if name == "group" {
		return "terminal-group"
	}
	return name
}

func isHelpArgument(argument string) bool {
	return argument == "-h" || argument == "--help"
}

var resourceActions = map[string]map[string]bool{
	"task": {
		"list": true, "create": true, "add": true, "remove": true, "delete": true,
		"rename": true, "pin": true, "move": true, "attach": true, "detach": true,
	},
	"project": {
		"list": true, "add": true, "remove": true, "delete": true,
		"rename": true, "pin": true, "move": true,
	},
	"workspace": {
		"list": true, "create": true, "add": true, "remove": true, "delete": true,
		"rename": true, "pin": true, "move": true,
	},
	"terminal-group": {
		"list": true, "create": true, "add": true, "remove": true, "delete": true,
		"rename": true, "home": true, "move": true,
	},
	"session": {
		"list": true, "create": true, "add": true, "remove": true, "delete": true,
		"kill": true, "rename": true, "pin": true, "move": true, "send": true, "read": true,
		"current": true, "panes": true, "undo": true,
	},
	"pane": {
		"list": true, "create": true, "split": true, "close": true,
		"rename": true, "move": true, "remove": true, "delete": true,
	},
	"browser": {
		"list": true, "create": true, "get": true, "action": true,
		"close": true, "remove": true, "delete": true,
	},
}

func knownResourceAction(resource, action string) bool {
	return resourceActions[resource][action]
}

func requiredPositionals(resource, action string) []string {
	switch resource + "." + action {
	case "task.remove", "task.delete", "task.rename", "task.pin", "task.move":
		return []string{"TASK_ID"}
	case "task.attach", "task.detach":
		return []string{"TASK_ID", "WORKSPACE_ID"}
	case "project.add":
		return []string{"PATH"}
	case "project.remove", "project.delete", "project.rename", "project.pin", "project.move":
		return []string{"PROJECT_ID"}
	case "workspace.create", "workspace.add":
		return []string{"PROJECT_ID"}
	case "workspace.remove", "workspace.delete", "workspace.rename", "workspace.pin", "workspace.move":
		return []string{"WORKSPACE_ID"}
	case "terminal-group.remove", "terminal-group.delete", "terminal-group.rename", "terminal-group.home", "terminal-group.move":
		return []string{"GROUP_ID"}
	case "session.remove", "session.delete", "session.kill", "session.rename", "session.pin", "session.move",
		"session.send", "session.read":
		return []string{"SESSION_ID"}
	case "pane.rename", "pane.move", "pane.remove", "pane.delete":
		return []string{"PANE_GROUP_ID"}
	case "session.undo":
		return []string{"OPERATION_ID"}
	case "browser.get", "browser.close", "browser.remove", "browser.delete":
		return []string{"SESSION_ID"}
	case "browser.action":
		return []string{"SESSION_ID", "ACTION"}
	}
	return nil
}

func missingPositional(params map[string]any, labels []string) string {
	items := positionals(params)
	for index, label := range labels {
		if len(items) <= index || strings.TrimSpace(items[index]) == "" {
			return label
		}
	}
	return ""
}

func sessionTargetAction(action string) bool {
	switch action {
	case "remove", "delete", "kill", "rename", "pin", "move", "send", "read", "attach":
		return true
	default:
		return false
	}
}

func missingRequiredFlag(resource, action string, params map[string]any) string {
	switch resource + "." + action {
	case "task.create", "task.add", "task.rename", "project.rename", "workspace.rename", "terminal-group.rename":
		if stringValue(params, "name") == "" {
			return "--name NAME"
		}
	case "session.rename":
		if stringValue(params, "title") == "" {
			return "--title TITLE"
		}
	case "workspace.create", "workspace.add":
		if stringValue(params, "branch") == "" {
			return "--branch BRANCH"
		}
	case "terminal-group.home":
		if stringValue(params, "path") == "" {
			return "--path PATH"
		}
	case "pane.rename":
		if stringValue(params, "name") == "" {
			return "--name NAME"
		}
	case "pane.create":
		if stringValue(params, "workspace") == "" && stringValue(params, "group") == "" {
			return "--workspace WORKSPACE_ID or --group GROUP_ID"
		}
		if stringValue(params, "session") == "" {
			return "--session SESSION_ID"
		}
	case "pane.split":
		if stringValue(params, "pane") == "" {
			return "--pane PANE_ID"
		}
		if stringValue(params, "session") == "" {
			return "--session SESSION_ID"
		}
	case "pane.close":
		if stringValue(params, "pane") == "" {
			return "--pane PANE_ID"
		}
	}
	return ""
}

// browserActionValueFlags names the browser action flags that take a value.
//
// parseFlags decides whether a flag consumes the next argument from one global
// set of bare booleans, and `--text` is in that set for the transcript readers
// (`agent read --text`). For a browser action `--text "Sign in"` means click the
// element whose text is "Sign in", so the flag is told it takes a value here
// instead of leaving the string to land in the positionals. Every browser flag
// that is not a value flag is a boolean, which is what keeps `--clear` and
// `--interactive` from swallowing the token after them.
var browserActionValueFlags = map[string]bool{
	"url": true, "wait-until": true, "selector": true, "text": true, "value": true,
	"values": true, "path": true, "state": true, "level": true, "tab": true,
	"expression": true, "delay": true, "quality": true, "max-nodes": true,
	"timeout": true, "dx": true, "dy": true, "limit": true, "width": true,
	"height": true, "format": true,
}

func parseFlags(args []string, valueFlags ...map[string]bool) map[string]any {
	value := map[string]any{"_": []string{}}
	takesValue := func(key string) bool {
		if len(valueFlags) > 0 && valueFlags[0][key] {
			return true
		}
		return !bareBooleanFlags[key]
	}
	for index := 0; index < len(args); index++ {
		item := args[index]
		if !strings.HasPrefix(item, "--") {
			value["_"] = append(value["_"].([]string), item)
			continue
		}
		key := strings.TrimPrefix(item, "--")
		if split := strings.SplitN(key, "=", 2); len(split) == 2 {
			value[split[0]] = split[1]
			continue
		}
		// Bare boolean flags must not consume the next positional as their
		// value. `--raw "text"` therefore sets raw=true and keeps "text" as a
		// positional, while `--pinned true` still consumes "true" as its value.
		if index+1 < len(args) && !strings.HasPrefix(args[index+1], "--") && takesValue(key) {
			value[key] = args[index+1]
			index++
		} else {
			value[key] = true
		}
	}
	return value
}

var bareBooleanFlags = map[string]bool{
	"all":                   true,
	"available":             true,
	"ended":                 true,
	"force":                 true,
	"full":                  true,
	"full-content":          true,
	"help":                  true,
	"keep-worktree":         true,
	"auto-import-worktrees": true,
	"current":               true,
	"confirm":               true,
	"dry-run":               true,
	"preflight":             true,
	"yes":                   true,
	"no-truncate":           true,
	"no-prompt":             true,
	"raw":                   true,
	"share":                 true,
	"open":                  true,
	"terminal":              true,
	"text":                  true,
	"text-only":             true,
	"plain":                 true,
	"wait":                  true,
	"use":                   true,
	"quiet":                 true,
	"q":                     true,
	"merged":                true,
	"unmerged":              true,
	"unattached":            true,
	"no-task":               true,
	"no-workspaces":         true,
	"has-workspaces":        true,
	"has-sessions":          true,
	"active":                true,
}

func normalizedParams(values map[string]any, resource, action string) map[string]any {
	result := map[string]any{}
	for key, value := range values {
		if key != "_" {
			result[key] = value
		}
	}
	if action == "create" && resource == "session" {
		// The daemon reads runtimeKind; the CLI flag uses kebab-case.
		if value, ok := result["runtime-kind"]; ok {
			result["runtimeKind"] = value
			delete(result, "runtime-kind")
		}
		if value, ok := result["agent-handler"]; ok {
			result["agentHandler"] = value
			delete(result, "agent-handler")
		}
	}
	if (action == "create" || action == "add") && resource == "task" {
		if value, ok := result["external-id"]; ok {
			result["externalID"] = value
			delete(result, "external-id")
		}
	}
	if resource == "session" && action == "move" {
		for _, key := range []string{"expected-workspace", "expected-workspace-id"} {
			if value, ok := result[key]; ok {
				result["expectedWorkspace"] = value
				delete(result, key)
			}
		}
		for _, key := range []string{"expected-agent-session", "expected-agent-session-id"} {
			if value, ok := result[key]; ok {
				result["expectedAgentSession"] = value
				delete(result, key)
			}
		}
	}
	if action == "add" && resource == "project" {
		// Project worktree policy is project-scoped. Keep the CLI spelling
		// readable while matching the WebSocket API field name.
		if value, ok := result["auto-import-worktrees"]; ok {
			result["autoImportGitWorktrees"] = value
			delete(result, "auto-import-worktrees")
		}
	}
	positions := positionals(values)
	if len(positions) > 0 {
		if (action == "create" || action == "add") && resource == "task" {
			// Task creation is flag-only; positional values are never accepted.
		} else if action == "add" && resource == "project" {
			result["path"] = positions[0]
		} else if action == "create" && resource == "workspace" {
			result["project"] = positions[0]
		} else if action == "create" && resource == "session" {
			result["workspace"] = positions[0]
		} else if action == "undo" && resource == "session" {
			result["operation"] = positions[0]
		} else {
			result["id"] = positions[0]
		}
		if resource == "task" && (action == "attach" || action == "detach") && len(positions) > 1 {
			result["workspace"] = positions[1]
		}
	}
	return result
}
func positionals(value map[string]any) []string { result, _ := value["_"].([]string); return result }
func positional(value map[string]any, index int, _ string) string {
	items := positionals(value)
	if len(items) <= index {
		return ""
	}
	return items[index]
}
func stringValue(value map[string]any, key string) string {
	result, _ := value[key].(string)
	return result
}
func stringValueDefault(value map[string]any, key, fallback string) string {
	if result := stringValue(value, key); result != "" {
		return result
	}
	return fallback
}
func boolValue(value map[string]any, key string) bool {
	switch result := value[key].(type) {
	case bool:
		return result
	case string:
		parsed, err := strconv.ParseBool(result)
		return err == nil && parsed
	default:
		return false
	}
}
func durationValue(value map[string]any, key string, fallback time.Duration) time.Duration {
	result, err := time.ParseDuration(stringValue(value, key))
	if err == nil {
		return result
	}
	if seconds, err := strconv.Atoi(stringValue(value, key)); err == nil {
		return time.Duration(seconds) * time.Second
	}
	return fallback
}

const defaultListLimit = 10

// listLimit keeps roster-heavy commands bounded for agent callers. A caller
// that needs to search the complete roster must opt into --all and can then
// pipe the result through rg without placing every row in the context window.
func listLimit(params map[string]any) (int, error) {
	if boolValue(params, "all") {
		if _, specified := params["limit"]; specified {
			return 0, errors.New("--all cannot be combined with --limit")
		}
		return 0, nil
	}
	if value, specified := params["limit"]; specified {
		parsed, err := strconv.Atoi(fmt.Sprint(value))
		if err != nil || parsed <= 0 {
			return 0, errors.New("--limit must be a positive integer")
		}
		return parsed, nil
	}
	return defaultListLimit, nil
}

func limitListRows[T any](rows []T, limit int) []T {
	if limit <= 0 || len(rows) <= limit {
		return rows
	}
	return rows[:limit]
}
