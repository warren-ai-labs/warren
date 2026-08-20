package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/client"
	"github.com/abcdlsj/warren/Headless/internal/config"
)

var version = "dev"
var outputJSON bool
var endpointName string
var endpointURL string
var endpointToken string
var configPath string

func main() {
	if err := run(os.Args[1:]); err != nil {
		var usageErr *usageError
		if errors.As(err, &usageErr) {
			fmt.Fprintln(os.Stderr, "warren:", usageErr.message)
			if usageErr.text != "" {
				fmt.Fprintln(os.Stderr)
				fmt.Fprint(os.Stderr, usageErr.text)
			}
			os.Exit(2)
		}
		fmt.Fprintln(os.Stderr, "warren:", err)
		os.Exit(1)
	}
}

type usageError struct {
	message string
	text    string
}

func (e *usageError) Error() string { return e.message }

func newUsageError(message, text string) error {
	return &usageError{message: message, text: text}
}

func run(arguments []string) error {
	global := flag.NewFlagSet("warren", flag.ContinueOnError)
	global.SetOutput(io.Discard)
	global.BoolVar(&outputJSON, "json", false, "JSON output")
	global.StringVar(&endpointName, "endpoint", env("WARREN_ENDPOINT", ""), "endpoint name")
	global.StringVar(&endpointURL, "server", env("WARREN_SERVER", ""), "server URL")
	global.StringVar(&endpointToken, "token", env("WARREN_TOKEN", ""), "server token")
	global.StringVar(&configPath, "config", config.DefaultPath(), "config path")
	arguments = hoistGlobalFlags(arguments)
	if err := global.Parse(arguments); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			usage()
			return nil
		}
		return newUsageError(err.Error(), usageText())
	}
	args := global.Args()
	if len(args) == 0 {
		usage()
		return nil
	}
	switch args[0] {
	case "version":
		fmt.Println(version)
		return nil
	case "endpoint", "server":
		return endpointCommand(args[1:])
	case "ssh":
		return sshCommand(args[1:])
	case "agent":
		return agentCommand(args[1:])
	case "project", "workspace", "worktree", "terminal-group", "group", "session":
		return resourceCommand(args)
	case "headless":
		return headlessCommand(args[1:])
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		return newUsageError(fmt.Sprintf("unknown command %q; run 'warren help'", args[0]), usageText())
	}
}

var globalFlagNames = map[string]bool{
	"json":     true,
	"endpoint": true,
	"server":   true,
	"token":    true,
	"config":   true,
}

// hoistGlobalFlags moves global flags (--json, --endpoint, --server, --token,
// --config) to the front so they work before or after the subcommand. Go's
// flag package stops parsing at the first positional argument, which would
// otherwise silently ignore flags such as `warren session list --json`.
func hoistGlobalFlags(arguments []string) []string {
	extracted := make([]string, 0, len(arguments))
	rest := make([]string, 0, len(arguments))
	endpointAdd := isEndpointAdd(arguments)
	for index := 0; index < len(arguments); index++ {
		item := arguments[index]
		name, _, hasValue := splitFlag(item)
		if !globalFlagNames[name] {
			rest = append(rest, item)
			continue
		}
		// endpoint add accepts its own --token; keep it local so the
		// subcommand receives it instead of treating it as the server token.
		if endpointAdd && name == "token" {
			rest = append(rest, item)
			continue
		}
		if hasValue || name == "json" {
			extracted = append(extracted, item)
			continue
		}
		if index+1 < len(arguments) && !strings.HasPrefix(arguments[index+1], "--") {
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
			if hasValue || name == "json" {
				continue
			}
			if index+1 < len(arguments) && !strings.HasPrefix(arguments[index+1], "--") {
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
		"attach": true, "current": true, "undo": true,
	},
}

func knownResourceAction(resource, action string) bool {
	return resourceActions[resource][action]
}

func requiredPositionals(resource, action string) []string {
	switch resource + "." + action {
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
		"session.send", "session.read", "session.attach":
		return []string{"SESSION_ID"}
	case "session.undo":
		return []string{"OPERATION_ID"}
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
	case "project.rename", "workspace.rename", "terminal-group.rename":
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
	}
	return ""
}

func connect() (context.Context, *client.Client, error) {
	dialContext, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	url, token := endpointURL, endpointToken
	if url == "" {
		settings, err := config.Load(configPath)
		if err != nil {
			return nil, nil, err
		}
		value, err := settings.Resolve(endpointName)
		if err != nil {
			return nil, nil, fmt.Errorf("%w; add one with 'warren endpoint add' or pass --server and --token", err)
		}
		url, token = value.URL, value.Token
	}
	if token == "" {
		return nil, nil, errors.New("endpoint token is required")
	}
	value, err := client.Dial(dialContext, url, token)
	return context.Background(), value, err
}

func resourceCommand(args []string) error {
	commandName := args[0]
	resource := canonicalResource(commandName)
	if len(args) < 2 {
		return newUsageError(fmt.Sprintf("%s command is required", commandName), resourceUsageText(commandName))
	}
	if isHelpArgument(args[1]) {
		fmt.Print(resourceUsageText(commandName))
		return nil
	}
	action := args[1]
	if !knownResourceAction(resource, action) {
		return newUsageError(fmt.Sprintf("unsupported command: %s %s", commandName, action), resourceUsageText(commandName))
	}
	params := parseFlags(args[2:])
	if boolValue(params, "help") || boolValue(params, "h") {
		fmt.Print(actionUsageText(commandName, action))
		return nil
	}
	if resource == "session" && sessionTargetAction(action) && boolValue(params, "current") && action != "send" && len(positionals(params)) > 0 {
		return newUsageError("--current cannot be combined with SESSION_ID", actionUsageText(commandName, action))
	}
	positionLabels := requiredPositionals(resource, action)
	if resource == "session" && sessionTargetAction(action) && boolValue(params, "current") {
		positionLabels = nil
	}
	if label := missingPositional(params, positionLabels); label != "" {
		return newUsageError("missing "+label, actionUsageText(commandName, action))
	}
	if resource == "session" && (action == "create" || action == "add") && len(positionals(params)) > 1 {
		return newUsageError("session create accepts at most one context ID", actionUsageText(commandName, action))
	}
	if resource == "session" && (action == "create" || action == "add") &&
		(len(positionals(params)) > 0 || stringValue(params, "workspace") != "") &&
		stringValue(params, "group") != "" {
		return newUsageError("workspace and --group are mutually exclusive", actionUsageText(commandName, action))
	}
	if resource == "session" && action == "move" {
		workspaceID := stringValue(params, "workspace")
		groupID := stringValue(params, "group")
		if workspaceID != "" && groupID != "" {
			return newUsageError("--workspace and --group are mutually exclusive", actionUsageText(commandName, action))
		}
		if workspaceID == "" && groupID == "" {
			return newUsageError("missing --workspace WORKSPACE_ID or --group GROUP_ID", actionUsageText(commandName, action))
		}
		_, expectedWorkspaceSpecified := params["expected-workspace"]
		if !expectedWorkspaceSpecified {
			_, expectedWorkspaceSpecified = params["expected-workspace-id"]
		}
		if !expectedWorkspaceSpecified {
			_, expectedWorkspaceSpecified = params["expectedWorkspace"]
		}
		_, expectedAgentSpecified := params["expected-agent-session"]
		if !expectedAgentSpecified {
			_, expectedAgentSpecified = params["expected-agent-session-id"]
		}
		if !expectedAgentSpecified {
			_, expectedAgentSpecified = params["expectedAgentSession"]
		}
		if !boolValue(params, "current") && !boolValue(params, "dry-run") && !boolValue(params, "preflight") &&
			!boolValue(params, "confirm") && !boolValue(params, "yes") &&
			!expectedWorkspaceSpecified && !expectedAgentSpecified {
			return newUsageError("explicit session move requires --confirm, --dry-run, or an expected source context", actionUsageText(commandName, action))
		}
	}
	if resource == "session" && action == "current" && len(positionals(params)) > 0 {
		return newUsageError("session current does not accept SESSION_ID; it uses WARREN_SESSION_ID", actionUsageText(commandName, action))
	}
	if label := missingRequiredFlag(resource, action, params); label != "" {
		return newUsageError("missing "+label, actionUsageText(commandName, action))
	}
	if resource == "session" && action == "list" && boolValue(params, "all") && boolValue(params, "ended") {
		return newUsageError("--all and --ended are mutually exclusive", actionUsageText(commandName, action))
	}
	if resource == "session" && action == "send" && stringValue(params, "timeout") != "" && !boolValue(params, "wait") {
		return newUsageError("--timeout requires --wait", actionUsageText(commandName, action))
	}
	if resource == "session" && action == "send" && boolValue(params, "wait") {
		if _, err := agentWaitTimeout(params); err != nil {
			return newUsageError(err.Error(), actionUsageText(commandName, action))
		}
	}
	var resolvedCurrentID string
	if resource == "session" && (sessionTargetAction(action) || action == "current") && boolValue(params, "current") {
		var err error
		resolvedCurrentID, err = currentSessionID()
		if err != nil {
			return err
		}
		if action == "send" {
			params["_"] = append([]string{resolvedCurrentID}, positionals(params)...)
		} else {
			params["_"] = []string{resolvedCurrentID}
		}
	}
	if resource == "session" && action == "current" {
		var err error
		resolvedCurrentID, err = currentSessionID()
		if err != nil {
			return err
		}
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	if resource == "session" && action == "current" {
		var session api.Session
		if err := c.Request(ctx, "session.current", map[string]any{"id": resolvedCurrentID}, &session); err != nil {
			return err
		}
		return printValue(currentSessionValue{Session: session, WarrenSessionID: session.ID, AgentThreadID: session.AgentSessionID, Current: true})
	}
	if action == "list" {
		state, err := c.Roster(ctx)
		if err != nil {
			return err
		}
		switch resource {
		case "project":
			return printValue(projectRows(state))
		case "workspace":
			return printValue(workspaceRows(state))
		case "terminal-group":
			return printValue(state.TerminalGroups)
		case "session":
			return printValue(sessionRowsForCurrent(state, boolValue(params, "all"), boolValue(params, "ended"), strings.TrimSpace(os.Getenv(agent.BindEnvSession))))
		}
	}
	method := ""
	var result any
	switch resource + "." + action {
	case "project.add":
		method = "project.add"
		result = &api.Project{}
	case "project.remove", "project.delete":
		method = "project.remove"
		result = &map[string]any{}
	case "project.rename":
		method = "project.rename"
		result = &map[string]any{}
	case "project.pin":
		method = "project.pin"
		result = &map[string]any{}
	case "project.move":
		method = "project.move"
		result = &map[string]any{}
	case "workspace.create", "workspace.add":
		method = "workspace.create"
		result = &api.WorkspaceCreateResult{}
	case "workspace.remove", "workspace.delete":
		method = "workspace.remove"
		result = &map[string]any{}
		// The interactive UI sends an explicit boolean. The CLI keeps the
		// historical behavior unless the caller opts out with --keep-worktree.
		if boolValue(params, "keep-worktree") || boolValue(params, "keep_worktree") {
			params["remove_worktree"] = false
		}
		delete(params, "keep-worktree")
		delete(params, "keep_worktree")
	case "workspace.rename":
		method = "workspace.rename"
		result = &map[string]any{}
	case "workspace.pin":
		method = "workspace.pin"
		result = &map[string]any{}
	case "workspace.move":
		method = "workspace.move"
		result = &map[string]any{}
	case "terminal-group.create", "terminal-group.add":
		method = "terminal-group.create"
		result = &api.TerminalGroup{}
	case "terminal-group.remove", "terminal-group.delete":
		method = "terminal-group.remove"
		result = &map[string]any{}
	case "terminal-group.rename":
		method = "terminal-group.rename"
		result = &map[string]any{}
	case "terminal-group.home":
		method = "terminal-group.home"
		result = &map[string]any{}
	case "terminal-group.move":
		method = "terminal-group.move"
		result = &map[string]any{}
	case "session.create", "session.add":
		method = "session.create"
		result = &api.Session{}
	case "session.remove", "session.delete", "session.kill":
		method = "session.delete"
		result = &map[string]any{}
	case "session.rename":
		method = "session.rename"
		result = &map[string]any{}
	case "session.pin":
		method = "session.pin"
		result = &map[string]any{}
	case "session.move":
		method = "session.move"
		result = &api.Session{}
	case "session.undo":
		method = "session.undo"
		result = &api.Session{}
	case "session.send":
		id := positional(params, 0, "session id")
		text := strings.Join(positionals(params)[1:], " ")
		if text == "" {
			data, _ := io.ReadAll(os.Stdin)
			text = string(data)
		}
		session, err := c.Attach(ctx, id)
		if err != nil {
			return err
		}
		var snapshot api.AgentSnapshotResult
		if boolValue(params, "wait") {
			if session.Kind != "codex" && session.Kind != "claude" && session.AgentSessionID == "" {
				return fmt.Errorf("session is not bound to an agent: %s", session.ID)
			}
			snapshot, err = c.AgentSnapshot(ctx, id)
			if err != nil {
				return err
			}
			if err := validateAgentSendWait(snapshot); err != nil {
				return err
			}
		}
		if !strings.HasSuffix(text, "\n") && !boolValue(params, "raw") {
			text += "\r"
		}
		if err := c.Input(ctx, []byte(text)); err != nil {
			return err
		}
		if boolValue(params, "wait") {
			timeout, err := agentWaitTimeout(params)
			if err != nil {
				return newUsageError(err.Error(), actionUsageText(commandName, action))
			}
			return waitAndPrintAgentTurn(c, id, snapshot, snapshot.Turn.ID, 0, timeout)
		}
		return printValue(map[string]any{"sent": true})
	case "session.read", "session.attach":
		return sessionRead(ctx, c, params, action == "attach")
	default:
		return fmt.Errorf("unsupported command: %s %s", resource, action)
	}
	request := normalizedParams(params, resource, action)
	if resource == "session" && action == "undo" {
		request["operation"] = positional(params, 0, "operation ID")
	}
	if resource == "session" && action == "move" {
		if boolValue(params, "current") {
			state, err := c.Roster(ctx)
			if err != nil {
				return err
			}
			id := positional(params, 0, "session id")
			var observed *api.Session
			for index := range state.Sessions {
				if state.Sessions[index].ID == id {
					observed = &state.Sessions[index]
					break
				}
			}
			if observed == nil {
				return fmt.Errorf("current session not found: %s", id)
			}
			// Guard both ownership and the agent conversation binding. Empty
			// values are intentional expectations, not omitted fields.
			request["expectedWorkspace"] = observed.WorkspaceID
			request["expectedAgentSession"] = observed.AgentSessionID
		}
		if boolValue(params, "dry-run") || boolValue(params, "preflight") {
			var value api.SessionMovePreflight
			if err := c.Request(ctx, "session.move.preflight", request, &value); err != nil {
				return err
			}
			return printValue(value)
		}
	}
	if resource == "session" && (action == "remove" || action == "delete" || action == "kill") && boolValue(params, "dry-run") {
		var value map[string]any
		if err := c.Request(ctx, "session.delete.preflight", request, &value); err != nil {
			return err
		}
		return printValue(value)
	}
	if err := c.Request(ctx, method, request, result); err != nil {
		return err
	}
	return printValue(result)
}

func sessionRead(ctx context.Context, c *client.Client, params map[string]any, follow bool) error {
	id := positional(params, 0, "session id")
	if _, err := c.Attach(ctx, id); err != nil {
		return err
	}
	timeout := durationValue(params, "timeout", 8*time.Second)
	needle := stringValue(params, "contains")
	if follow {
		ctx, _ = signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	} else {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.Background(), timeout)
		defer cancel()
	}
	err := c.ReadOutput(ctx, func(data []byte) bool {
		_, _ = os.Stdout.Write(data)
		return !follow && needle != "" && strings.Contains(string(data), needle)
	})
	if errors.Is(err, context.Canceled) && follow {
		return nil
	}
	if errors.Is(err, context.DeadlineExceeded) {
		if needle == "" {
			return nil
		}
		return fmt.Errorf("expected text not found before timeout: %s", needle)
	}
	return err
}

func agentCommand(args []string) error {
	if len(args) == 0 || isHelpArgument(args[0]) {
		fmt.Print(agentUsageText())
		return nil
	}
	if args[0] == "wait" {
		return agentWaitCommand(args[1:])
	}
	if args[0] != "read" {
		return newUsageError(fmt.Sprintf("unknown agent command: %s", args[0]), agentUsageText())
	}
	help, err := validateAgentReadArgs(args[1:])
	if err != nil {
		return newUsageError(err.Error(), agentReadUsageText())
	}
	if help {
		fmt.Print(agentReadUsageText())
		return nil
	}
	params := parseFlags(args[1:])
	if boolValue(params, "help") || boolValue(params, "h") {
		fmt.Print(agentReadUsageText())
		return nil
	}
	positions := positionals(params)
	if len(positions) == 0 {
		return newUsageError("missing PROVIDER", agentReadUsageText())
	}
	if len(positions) > 2 {
		return newUsageError("agent read accepts at most one transcript path", agentReadUsageText())
	}
	provider := strings.ToLower(strings.TrimSpace(positions[0]))
	if provider != "codex" && provider != "claude" {
		return newUsageError("PROVIDER must be codex or claude", agentReadUsageText())
	}
	path := stringValue(params, "path")
	if path == "" {
		path = stringValue(params, "file")
	}
	if len(positions) == 2 {
		if path != "" {
			return newUsageError("transcript path was provided twice", agentReadUsageText())
		}
		path = positions[1]
	}

	recent := agent.DefaultReadRecent
	if boolValue(params, "all") {
		recent = 0
	}
	if value := firstFlagValue(params, "recent", "limit", "count"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			return newUsageError("--recent must be a non-negative integer", agentReadUsageText())
		}
		recent = parsed
	}
	contentLimit := agent.DefaultReadContentLimit
	if value := firstFlagValue(params, "chars", "max-chars", "head"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			return newUsageError("--chars must be a non-negative integer", agentReadUsageText())
		}
		contentLimit = parsed
	}
	full := boolValue(params, "full") || boolValue(params, "full-content") || boolValue(params, "no-truncate")
	if full {
		contentLimit = 0
	}
	include := collectAgentTypeFlags(args[1:], "include", "types")
	exclude := collectAgentTypeFlags(args[1:], "filter", "exclude")
	// `collectAgentTypeFlags` preserves repeated flags. The map parser above is
	// still used for the common single-flag case and for validation.
	if len(include) == 0 {
		include = splitTypeFlag(firstFlagValue(params, "include", "types"))
	}
	if len(exclude) == 0 {
		exclude = append(splitTypeFlag(stringValue(params, "filter")), splitTypeFlag(stringValue(params, "exclude"))...)
	}

	if path == "" {
		workspace := stringValue(params, "workspace")
		if workspace == "" {
			var err error
			workspace, err = os.Getwd()
			if err != nil {
				return fmt.Errorf("resolve current workspace: %w", err)
			}
		}
		var err error
		path, err = (agent.DefaultFinder{}).Find(context.Background(), provider, workspace, time.Time{})
		if err != nil {
			return err
		}
		if path == "" {
			return fmt.Errorf("no %s transcript found for workspace %s; pass a JSONL path", provider, workspace)
		}
	} else {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return fmt.Errorf("resolve transcript path: %w", err)
		}
		path = absolute
	}

	events, err := agent.ReadTranscript(context.Background(), provider, path, agent.ReadOptions{
		Recent:       recent,
		ContentLimit: contentLimit,
		Full:         full,
		IncludeTypes: include,
		ExcludeTypes: exclude,
	})
	if err != nil {
		return fmt.Errorf("read %s transcript %s: %w", provider, path, err)
	}
	return printValue(events)
}

const defaultAgentWaitTimeout = 30 * time.Minute

func agentWaitCommand(args []string) error {
	help, err := validateAgentWaitArgs(args)
	if err != nil {
		return newUsageError(err.Error(), agentWaitUsageText())
	}
	if help {
		fmt.Print(agentWaitUsageText())
		return nil
	}
	params := parseFlags(args)
	positions := positionals(params)
	if boolValue(params, "current") {
		if len(positions) > 0 {
			return newUsageError("--current cannot be combined with SESSION_ID", agentWaitUsageText())
		}
		id, err := currentSessionID()
		if err != nil {
			return err
		}
		positions = []string{id}
	}
	if len(positions) == 0 {
		return newUsageError("missing SESSION_ID", agentWaitUsageText())
	}
	if len(positions) > 1 {
		return newUsageError("agent wait accepts exactly one session ID", agentWaitUsageText())
	}
	timeout, err := agentWaitTimeout(params)
	if err != nil {
		return newUsageError(err.Error(), agentWaitUsageText())
	}

	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	subscription, err := c.SubscribeAgent(ctx, positions[0])
	if err != nil {
		return err
	}
	session := subscription.Session
	if session.Kind != "codex" && session.Kind != "claude" && session.AgentSessionID == "" {
		return fmt.Errorf("session is not bound to an agent: %s", session.ID)
	}
	snapshot := subscription.Snapshot
	after, current := agentWaitCursor(snapshot)
	return waitAndPrintAgentTurn(c, session.ID, snapshot, after, current, timeout)
}

func agentWaitCursor(snapshot api.AgentSnapshotResult) (after, current uint64) {
	after = snapshot.Turn.ID
	if snapshot.Turn.Status == api.AgentTurnStarted {
		return after, snapshot.Turn.ID
	}
	if after > 0 {
		// A turn may complete after the read-only subscription is registered
		// but before this snapshot arrives. Its live terminal message is queued;
		// allow exactly that latest turn while historical replay stays silent.
		after--
	}
	return after, 0
}

func validateAgentWaitArgs(args []string) (bool, error) {
	help := false
	for index := 0; index < len(args); index++ {
		item := args[index]
		if item == "-h" || item == "--help" {
			help = true
			continue
		}
		if !strings.HasPrefix(item, "-") {
			continue
		}
		if item == "--current" {
			continue
		}
		if item == "--timeout" {
			if index+1 >= len(args) || strings.HasPrefix(args[index+1], "--") {
				return false, errors.New("--timeout requires a value")
			}
			index++
			continue
		}
		if strings.HasPrefix(item, "--timeout=") && strings.TrimPrefix(item, "--timeout=") != "" {
			continue
		}
		return false, fmt.Errorf("unknown flag %q", item)
	}
	return help, nil
}

func agentWaitTimeout(params map[string]any) (time.Duration, error) {
	value := stringValue(params, "timeout")
	if value == "" {
		if _, present := params["timeout"]; present {
			return 0, errors.New("--timeout requires a value")
		}
		return defaultAgentWaitTimeout, nil
	}
	timeout, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("invalid --timeout %q", value)
	}
	if timeout <= 0 {
		return 0, errors.New("--timeout must be greater than zero")
	}
	return timeout, nil
}

func validateAgentSendWait(snapshot api.AgentSnapshotResult) error {
	if snapshot.Turn.Status == api.AgentTurnStarted {
		return errors.New("agent already has a running turn; wait for it before using session send --wait")
	}
	return nil
}

func waitAndPrintAgentTurn(
	c *client.Client,
	sessionID string,
	snapshot api.AgentSnapshotResult,
	after uint64,
	current uint64,
	timeout time.Duration,
) error {
	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	waitContext, cancel := context.WithTimeout(signalContext, timeout)
	defer cancel()
	turn, err := c.WaitAgentTurn(waitContext, sessionID, snapshot.Epoch, after, current)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return fmt.Errorf("agent turn did not complete before timeout %s", timeout)
		}
		return err
	}
	fetchContext, fetchCancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer fetchCancel()
	events, err := c.AgentTurnEvents(fetchContext, sessionID, turn.ID)
	if err != nil {
		return fmt.Errorf("read completed agent turn %d: %w", turn.ID, err)
	}
	result := api.AgentWaitResult{
		Session: sessionID,
		Epoch:   snapshot.Epoch,
		Turn:    turn.ID,
		Status:  turn.Status,
		Events:  events,
	}
	if err := printValue(result); err != nil {
		return err
	}
	if turn.Status != api.AgentTurnCompleted {
		return fmt.Errorf("agent turn %d ended with status %s", turn.ID, turn.Status)
	}
	return nil
}

var agentReadValueFlags = map[string]bool{
	"path": true, "file": true, "workspace": true,
	"recent": true, "limit": true, "count": true,
	"chars": true, "max-chars": true, "head": true,
	"include": true, "types": true, "filter": true, "exclude": true,
}

var agentReadBooleanFlags = map[string]bool{
	"all": true, "full": true, "full-content": true,
	"no-truncate": true, "help": true,
}

// validateAgentReadArgs gives the transcript reader a strict flag schema.
// parseFlags is intentionally permissive because the other resource commands
// accept arbitrary daemon parameters; using it directly here would silently
// ignore typos and malformed flag invocations.
func validateAgentReadArgs(args []string) (bool, error) {
	present := make(map[string]bool)
	help := false
	for index := 0; index < len(args); index++ {
		item := args[index]
		if item == "-h" {
			help = true
			continue
		}
		if !strings.HasPrefix(item, "-") {
			continue
		}
		if !strings.HasPrefix(item, "--") {
			return false, fmt.Errorf("unknown flag %q", item)
		}
		name, value, hasValue := splitFlag(item)
		if agentReadBooleanFlags[name] {
			if hasValue {
				return false, fmt.Errorf("--%s does not take a value", name)
			}
			present[name] = true
			if name == "help" {
				help = true
			}
			continue
		}
		if !agentReadValueFlags[name] {
			return false, fmt.Errorf("unknown flag %q", item)
		}
		if !hasValue {
			if index+1 >= len(args) || args[index+1] == "-h" || strings.HasPrefix(args[index+1], "--") {
				return false, fmt.Errorf("--%s requires a value", name)
			}
			index++
		} else if value == "" {
			return false, fmt.Errorf("--%s requires a non-empty value", name)
		}
		present[name] = true
	}

	recentFlag := present["recent"] || present["limit"] || present["count"]
	if present["all"] && recentFlag {
		return false, errors.New("--all cannot be combined with --recent, --limit, or --count")
	}
	contentFlag := present["chars"] || present["max-chars"] || present["head"]
	if (present["full"] || present["full-content"] || present["no-truncate"]) && contentFlag {
		return false, errors.New("--full cannot be combined with --chars, --max-chars, or --head")
	}
	return help, nil
}

func firstFlagValue(params map[string]any, keys ...string) string {
	for _, key := range keys {
		if value := stringValue(params, key); value != "" {
			return value
		}
	}
	return ""
}

func splitTypeFlag(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return strings.Split(value, ",")
}

func collectAgentTypeFlags(args []string, names ...string) []string {
	wanted := make(map[string]bool, len(names))
	for _, name := range names {
		wanted[name] = true
	}
	var values []string
	for index := 0; index < len(args); index++ {
		item := args[index]
		if !strings.HasPrefix(item, "--") {
			continue
		}
		key := strings.TrimPrefix(item, "--")
		if split := strings.SplitN(key, "=", 2); len(split) == 2 {
			if wanted[split[0]] {
				values = append(values, split[1])
			}
			continue
		}
		if !wanted[key] || index+1 >= len(args) || strings.HasPrefix(args[index+1], "--") {
			continue
		}
		values = append(values, args[index+1])
		index++
	}
	return values
}

func endpointCommand(args []string) error {
	settings, err := config.Load(configPath)
	if err != nil {
		return err
	}
	if len(args) == 0 || args[0] == "list" {
		if outputJSON {
			return printValue(settings)
		}
		rows := make([][]string, 0, len(settings.Endpoints))
		for _, name := range settings.Names() {
			value := settings.Endpoints[name]
			marker := ""
			if name == settings.Current {
				marker = "*"
			}
			rows = append(rows, []string{marker, name, value.URL, displayValue(value.SSH)})
		}
		printTable([]string{"CURRENT", "NAME", "URL", "SSH"}, rows...)
		return nil
	}
	if isHelpArgument(args[0]) || (len(args) >= 2 && isHelpArgument(args[1])) {
		fmt.Print(endpointUsageText())
		return nil
	}
	switch args[0] {
	case "add":
		flags := parseFlags(args[1:])
		if boolValue(flags, "help") || boolValue(flags, "h") {
			fmt.Print(endpointUsageText())
			return nil
		}
		if label := missingPositional(flags, []string{"ENDPOINT_NAME"}); label != "" {
			return newUsageError("missing "+label, endpointUsageText())
		}
		name := positional(flags, 0, "endpoint name")
		url := stringValue(flags, "url")
		token := stringValue(flags, "token")
		if url == "" || token == "" {
			return newUsageError("--url and --token are required", endpointUsageText())
		}
		settings.Endpoints[name] = config.Endpoint{Name: name, URL: url, Token: token, SSH: stringValue(flags, "ssh")}
		if settings.Current == "" || boolValue(flags, "use") {
			settings.Current = name
		}
		if err := config.Save(configPath, settings); err != nil {
			return err
		}
		return printValue(map[string]any{"added": true, "name": name})
	case "use":
		if len(args) < 2 {
			return newUsageError("missing ENDPOINT_NAME", endpointUsageText())
		}
		if _, ok := settings.Endpoints[args[1]]; !ok {
			return fmt.Errorf("endpoint not found: %s", args[1])
		}
		settings.Current = args[1]
		if err := config.Save(configPath, settings); err != nil {
			return err
		}
		return printValue(map[string]any{"current": args[1]})
	case "remove":
		if len(args) < 2 {
			return newUsageError("missing ENDPOINT_NAME", endpointUsageText())
		}
		delete(settings.Endpoints, args[1])
		if settings.Current == args[1] {
			settings.Current = ""
		}
		if err := config.Save(configPath, settings); err != nil {
			return err
		}
		return printValue(map[string]any{"removed": true, "name": args[1]})
	case "current":
		value, err := settings.Resolve("")
		if err != nil {
			return err
		}
		return printValue(value)
	default:
		return newUsageError(fmt.Sprintf("unknown endpoint command: %s", args[0]), endpointUsageText())
	}
}

func sshCommand(args []string) error {
	if len(args) >= 1 && isHelpArgument(args[0]) {
		fmt.Print(sshUsageText())
		return nil
	}
	flags := parseFlags(args)
	if boolValue(flags, "help") || boolValue(flags, "h") {
		fmt.Print(sshUsageText())
		return nil
	}
	if label := missingPositional(flags, []string{"SSH_TARGET"}); label != "" {
		return newUsageError("missing "+label, sshUsageText())
	}
	target := positional(flags, 0, "SSH target")
	localPort := stringValueDefault(flags, "local-port", "8789")
	remotePort := stringValueDefault(flags, "remote-port", "8789")
	name := stringValueDefault(flags, "name", strings.NewReplacer("@", "-", ":", "-").Replace(target))
	remoteStart := "command -v warren-headless >/dev/null || { echo 'warren-headless is not installed' >&2; exit 127; }; mkdir -p ~/.warren; test -s ~/.warren/token || (umask 077; openssl rand -base64 32 | tr -d '\\n' > ~/.warren/token); (curl -fsS http://127.0.0.1:" + remotePort + "/healthz >/dev/null 2>&1 || nohup warren-headless --listen 127.0.0.1:" + remotePort + " > ~/.warren/headless.log 2>&1 &); cat ~/.warren/token"
	output, err := exec.Command("ssh", target, remoteStart).CombinedOutput()
	if err != nil {
		return fmt.Errorf("start remote headless: %s: %w", strings.TrimSpace(string(output)), err)
	}
	token := strings.TrimSpace(string(output))
	if token == "" {
		return errors.New("remote headless returned an empty token")
	}
	settings, err := config.Load(configPath)
	if err != nil {
		return err
	}
	settings.Endpoints[name] = config.Endpoint{Name: name, URL: "http://127.0.0.1:" + localPort, Token: token, SSH: target}
	settings.Current = name
	if err := config.Save(configPath, settings); err != nil {
		return err
	}
	command := exec.Command("ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-L", localPort+":127.0.0.1:"+remotePort, target)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	fmt.Fprintf(os.Stderr, "Warren endpoint %q active at http://127.0.0.1:%s; keep this process running.\n", name, localPort)
	return command.Run()
}

func headlessCommand(args []string) error {
	binary, err := exec.LookPath("warren-headless")
	if err != nil {
		return errors.New("warren-headless is not installed")
	}
	command := exec.Command(binary, args...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}

func parseFlags(args []string) map[string]any {
	value := map[string]any{"_": []string{}}
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
		if index+1 < len(args) && !strings.HasPrefix(args[index+1], "--") && !bareBooleanFlags[key] {
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
	"raw":                   true,
	"wait":                  true,
	"use":                   true,
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
		if action == "add" && resource == "project" {
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

// SessionRow joins a session with its workspace and project so the CLI can
// display context the roster already carries. The embedded Session keeps the
// JSON payload backward compatible while adding the resolved names/paths.
type SessionRow struct {
	api.Session
	WarrenSessionID   string `json:"warrenSessionId"`
	AgentThreadID     string `json:"agentThreadId,omitempty"`
	ProjectID         string `json:"projectId,omitempty"`
	ProjectName       string `json:"projectName,omitempty"`
	WorkspaceName     string `json:"workspaceName,omitempty"`
	TerminalGroupName string `json:"terminalGroupName,omitempty"`
	Branch            string `json:"branch,omitempty"`
	Path              string `json:"path,omitempty"`
	Current           bool   `json:"current"`
}

func sessionRows(state api.State, includeEnded, onlyEnded bool) []SessionRow {
	return sessionRowsForCurrent(state, includeEnded, onlyEnded, strings.TrimSpace(os.Getenv(agent.BindEnvSession)))
}

func sessionRowsForCurrent(state api.State, includeEnded, onlyEnded bool, currentID string) []SessionRow {
	workspaces := make(map[string]api.Workspace, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		workspaces[workspace.ID] = workspace
	}
	projects := make(map[string]api.Project, len(state.Projects))
	for _, project := range state.Projects {
		projects[project.ID] = project
	}
	rows := make([]SessionRow, 0, len(state.Sessions))
	for _, session := range state.Sessions {
		if onlyEnded && session.Lifecycle == "running" {
			continue
		}
		if !onlyEnded && !includeEnded && session.Lifecycle != "running" {
			continue
		}
		row := SessionRow{
			Session:         session,
			WarrenSessionID: session.ID,
			AgentThreadID:   session.AgentSessionID,
			Current:         currentID != "" && currentID == session.ID,
		}
		if workspace, ok := workspaces[session.WorkspaceID]; ok {
			row.WorkspaceName = workspace.Name
			row.Branch = workspace.Branch
			row.Path = workspace.Path
			if project, ok := projects[workspace.ProjectID]; ok {
				row.ProjectID = project.ID
				row.ProjectName = project.Name
			}
		}
		for _, group := range state.TerminalGroups {
			if group.ID == session.TerminalGroupID {
				row.TerminalGroupName = group.Name
				if row.Path == "" {
					row.Path = group.Home
				}
				break
			}
		}
		rows = append(rows, row)
	}
	return rows
}

// currentSessionID resolves only the Warren-owned binding environment. It
// deliberately does not inspect cwd, timestamps, names, or transcripts.
func currentSessionID() (string, error) {
	value := strings.TrimSpace(os.Getenv(agent.BindEnvSession))
	if value == "" {
		return "", errors.New("WARREN_SESSION_ID is not set; run this command from a Warren-managed session or pass an explicit SESSION_ID")
	}
	return value, nil
}

type currentSessionValue struct {
	api.Session
	WarrenSessionID string `json:"warrenSessionId"`
	AgentThreadID   string `json:"agentThreadId,omitempty"`
	Current         bool   `json:"current"`
}

// effectiveSessionTitle is the single display-name rule used everywhere a
// session name is rendered: a user-set CustomTitle wins, otherwise the
// generated default Title is shown.
func effectiveSessionTitle(session api.Session) string {
	if title := strings.TrimSpace(session.CustomTitle); title != "" {
		return title
	}
	return session.Title
}

// ProjectRow adds roster-derived context (workspace count) to a project while
// keeping the original JSON fields intact.
type ProjectRow struct {
	api.Project
	Workspaces int `json:"workspaces,omitempty"`
}

func projectRows(state api.State) []ProjectRow {
	byProject := make(map[string]int)
	for _, workspace := range state.Workspaces {
		byProject[workspace.ProjectID]++
	}
	rows := make([]ProjectRow, 0, len(state.Projects))
	for _, project := range state.Projects {
		rows = append(rows, ProjectRow{Project: project, Workspaces: byProject[project.ID]})
	}
	return rows
}

// WorkspaceRow joins a workspace with its project and adds a running session
// count while keeping the original JSON fields intact.
type WorkspaceRow struct {
	api.Workspace
	ProjectName string `json:"projectName,omitempty"`
	Sessions    int    `json:"sessions,omitempty"`
}

func workspaceRows(state api.State) []WorkspaceRow {
	projects := make(map[string]api.Project, len(state.Projects))
	for _, project := range state.Projects {
		projects[project.ID] = project
	}
	runningByWorkspace := make(map[string]int)
	for _, session := range state.Sessions {
		if session.Lifecycle == "running" {
			runningByWorkspace[session.WorkspaceID]++
		}
	}
	rows := make([]WorkspaceRow, 0, len(state.Workspaces))
	for _, workspace := range state.Workspaces {
		row := WorkspaceRow{Workspace: workspace, Sessions: runningByWorkspace[workspace.ID]}
		if project, ok := projects[workspace.ProjectID]; ok {
			row.ProjectName = project.Name
		}
		rows = append(rows, row)
	}
	return rows
}

func printValue(value any) error {
	if outputJSON {
		data, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}
	switch items := value.(type) {
	case []ProjectRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, projectRowCells(item))
		}
		printTable([]string{"ID", "NAME", "PATH", "WORKSPACES", "PINNED", "CREATED"}, rows...)
	case []WorkspaceRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, workspaceRowCells(item))
		}
		printTable([]string{"ID", "PROJECT", "NAME", "BRANCH", "MERGED", "PATH", "KIND", "SESSIONS", "PINNED", "CREATED"}, rows...)
	case []api.TerminalGroup:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, terminalGroupRowCells(item))
		}
		printTable([]string{"ID", "NAME", "HOME", "ORDER", "CREATED"}, rows...)
	case []SessionRow:
		rows := make([][]string, 0, len(items))
		for _, item := range items {
			rows = append(rows, sessionRowCells(item))
		}
		printTable([]string{"WARREN SESSION ID", "PROJECT", "WORKSPACE", "GROUP", "BRANCH", "TITLE", "CURRENT", "KIND", "COMMAND", "AGENT/THREAD ID", "TRANSCRIPT PATH", "LIFECYCLE", "ACTIVITY", "ENDED AT", "PINNED", "CREATED"}, rows...)
	case api.WorkspaceCreateResult:
		printKVTable(workspaceCreateResultPairs(items))
	case *api.WorkspaceCreateResult:
		printKVTable(workspaceCreateResultPairs(*items))
	case api.Workspace:
		printKVTable(workspaceCreateResultPairs(api.WorkspaceCreateResult{Workspace: items, Created: true}))
	case *api.Workspace:
		printKVTable(workspaceCreateResultPairs(api.WorkspaceCreateResult{Workspace: *items, Created: true}))
	case api.Project:
		printKVTable(projectPairs(items))
	case *api.Project:
		printKVTable(projectPairs(*items))
	case api.TerminalGroup:
		printKVTable(terminalGroupPairs(items))
	case *api.TerminalGroup:
		printKVTable(terminalGroupPairs(*items))
	case api.Session:
		printKVTable(sessionPairs(items))
	case *api.Session:
		printKVTable(sessionPairs(*items))
	case currentSessionValue:
		printKVTable(currentSessionPairs(items))
	case *currentSessionValue:
		printKVTable(currentSessionPairs(*items))
	case api.SessionMovePreflight:
		printKVTable(sessionMovePreflightPairs(items))
	case *api.SessionMovePreflight:
		printKVTable(sessionMovePreflightPairs(*items))
	case config.Endpoint:
		printKVTable([][2]string{
			{"NAME", items.Name},
			{"URL", items.URL},
			{"SSH", displayValue(items.SSH)},
		})
	case *config.Endpoint:
		printKVTable([][2]string{
			{"NAME", items.Name},
			{"URL", items.URL},
			{"SSH", displayValue(items.SSH)},
		})
	case map[string]bool:
		printKVTable(boolMapPairs(items))
	case *map[string]bool:
		printKVTable(boolMapPairs(*items))
	case map[string]any:
		printKVTable(anyMapPairs(items))
	case *map[string]any:
		printKVTable(anyMapPairs(*items))
	default:
		data, _ := json.MarshalIndent(value, "", "  ")
		fmt.Println(string(data))
	}
	return nil
}

func projectRowCells(item ProjectRow) []string {
	return []string{
		item.ID,
		item.Name,
		item.Path,
		strconv.Itoa(item.Workspaces),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func workspaceRowCells(item WorkspaceRow) []string {
	return []string{
		item.ID,
		displayValue(item.ProjectName),
		item.Name,
		displayValue(item.Branch),
		displayMergeState(item.MergeState),
		item.Path,
		item.Kind,
		strconv.Itoa(item.Sessions),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func displayMergeState(value api.MergeState) string {
	if value == api.MergeStateMerged {
		return "merged"
	}
	return ""
}

func terminalGroupRowCells(item api.TerminalGroup) []string {
	return []string{
		item.ID,
		item.Name,
		displayValue(item.Home),
		strconv.Itoa(item.Order),
		formatTime(item.CreatedAt),
	}
}

func sessionRowCells(item SessionRow) []string {
	return []string{
		item.ID,
		displayValue(item.ProjectName),
		displayValue(item.WorkspaceName),
		displayValue(item.TerminalGroupName),
		displayValue(item.Branch),
		effectiveSessionTitle(item.Session),
		displayBool(item.Current),
		item.Kind,
		displayValue(item.Command),
		displayValue(item.AgentSessionID),
		displayValue(item.TranscriptPath),
		item.Lifecycle,
		displayValue(string(item.AgentActivity)),
		formatOptionalTime(item.EndedAt),
		displayBool(item.Pinned),
		formatTime(item.CreatedAt),
	}
}

func workspaceCreateResultPairs(value api.WorkspaceCreateResult) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"PROJECT", value.ProjectID},
		{"NAME", value.Name},
		{"BRANCH", displayValue(value.Branch)},
		{"PATH", value.Path},
		{"KIND", value.Kind},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
		{"CREATED", displayBool(value.Created)},
		{"GIT WORKTREE", displayBool(value.GitWorktree)},
	}
}

func projectPairs(value api.Project) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"NAME", value.Name},
		{"PATH", value.Path},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
	}
}

func terminalGroupPairs(value api.TerminalGroup) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"NAME", value.Name},
		{"HOME", displayValue(value.Home)},
		{"ORDER", strconv.Itoa(value.Order)},
		{"CREATED AT", formatTime(value.CreatedAt)},
	}
}

func sessionPairs(value api.Session) [][2]string {
	return [][2]string{
		{"ID", value.ID},
		{"SCOPE", value.ScopeKind()},
		{"WORKSPACE", value.WorkspaceID},
		{"TERMINAL GROUP", value.TerminalGroupID},
		{"TITLE", effectiveSessionTitle(value)},
		{"KIND", value.Kind},
		{"COMMAND", displayValue(value.Command)},
		{"RUNTIME", value.Runtime},
		{"RUNTIME KIND", displayValue(value.RuntimeKind)},
		{"LIFECYCLE", value.Lifecycle},
		{"ACTIVITY", displayValue(string(value.AgentActivity))},
		{"AGENT SESSION", displayValue(value.AgentSessionID)},
		{"OPERATION ID", displayValue(value.OperationID)},
		{"TRANSCRIPT", displayValue(value.TranscriptPath)},
		{"PINNED", displayBool(value.Pinned)},
		{"CREATED AT", formatTime(value.CreatedAt)},
		{"ENDED AT", formatOptionalTime(value.EndedAt)},
	}
}

func currentSessionPairs(value currentSessionValue) [][2]string {
	pairs := sessionPairs(value.Session)
	pairs = append([][2]string{{"CURRENT", displayBool(value.Current)}, {"WARREN SESSION ID", value.WarrenSessionID}, {"AGENT/THREAD ID", displayValue(value.AgentThreadID)}}, pairs...)
	return pairs
}

func sessionMovePreflightPairs(value api.SessionMovePreflight) [][2]string {
	return [][2]string{
		{"ALLOWED", displayBool(value.Allowed)},
		{"WARREN SESSION ID", value.Session.ID},
		{"SOURCE WORKSPACE", displayValue(value.SourceWorkspaceID)},
		{"SOURCE GROUP", displayValue(value.SourceTerminalGroupID)},
		{"DESTINATION WORKSPACE", displayValue(value.DestinationWorkspaceID)},
		{"DESTINATION GROUP", displayValue(value.DestinationTerminalGroupID)},
		{"AGENT/THREAD ID", displayValue(value.Session.AgentSessionID)},
		{"TRANSCRIPT PATH", displayValue(value.Session.TranscriptPath)},
	}
}

func boolMapPairs(value map[string]bool) [][2]string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([][2]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, [2]string{strings.ToUpper(key), displayBool(value[key])})
	}
	return pairs
}

func anyMapPairs(value map[string]any) [][2]string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([][2]string, 0, len(keys))
	for _, key := range keys {
		pairs = append(pairs, [2]string{strings.ToUpper(key), displayAny(value[key])})
	}
	return pairs
}

func displayAny(value any) string {
	switch item := value.(type) {
	case bool:
		return displayBool(item)
	case string:
		return displayValue(item)
	case float64:
		return strconv.FormatFloat(item, 'f', -1, 64)
	default:
		data, _ := json.Marshal(item)
		return string(data)
	}
}

func printTable(headers []string, rows ...[]string) {
	widths := make([]int, len(headers))
	for index, header := range headers {
		widths[index] = len(header)
	}
	for _, row := range rows {
		for index, cell := range row {
			if index < len(widths) && len(cell) > widths[index] {
				widths[index] = len(cell)
			}
		}
	}
	printTableRow(headers, widths)
	for _, row := range rows {
		printTableRow(row, widths)
	}
}

func printTableRow(cells []string, widths []int) {
	var line strings.Builder
	for index, cell := range cells {
		if index > 0 {
			line.WriteString("  ")
		}
		if index < len(widths) {
			fmt.Fprintf(&line, "%-*s", widths[index], cell)
		} else {
			line.WriteString(cell)
		}
	}
	fmt.Println(strings.TrimRight(line.String(), " "))
}

func printKVTable(pairs [][2]string) {
	width := 0
	for _, pair := range pairs {
		if len(pair[0]) > width {
			width = len(pair[0])
		}
	}
	for _, pair := range pairs {
		fmt.Printf("%-*s  %s\n", width, pair[0], pair[1])
	}
}

func displayValue(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func displayBool(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func formatTime(value time.Time) string {
	if value.IsZero() {
		return "-"
	}
	return value.Local().Format("2006-01-02 15:04")
}

func formatOptionalTime(value *time.Time) string {
	if value == nil {
		return "-"
	}
	return formatTime(*value)
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func usage() { fmt.Print(usageText()) }

func usageText() string {
	return `Warren CLI

Usage:
  warren [--endpoint NAME | --server URL --token TOKEN] [--json] <command>

Commands:
  agent read codex|claude [SESSION_FILE]
  agent wait SESSION_ID [--timeout DURATION]
  endpoint list|add|use|remove|current
  project list|add|remove|rename|pin|move
  workspace list|create|remove|rename|pin|move  (alias: worktree)
  terminal-group list|create|remove|rename|home|move  (alias: group)
  session list|current|create|delete|rename|pin|move|send|read|attach|undo
  ssh USER@HOST                     start daemon, save endpoint, keep SSH tunnel
  headless [FLAGS]                  run the installed daemon

Global flags:
  --json                            machine-readable JSON output
  --endpoint NAME                   endpoint name from the local config
  --server URL --token TOKEN        connect directly to a server
  --config PATH                     config file (default ~/.warren/config.json)

Run 'warren <command> --help' for command-specific help.

Examples:
  warren agent read codex --recent 10 --include user,assistant
  warren agent read claude ~/.claude/projects/-work-demo/session.jsonl --full
  warren agent wait SESSION_ID --timeout 30m
  warren endpoint add vps --url http://127.0.0.1:8789 --token TOKEN --use
  warren project add /srv/my-repo
  warren project move PROJECT_ID --before OTHER_PROJECT_ID
  warren workspace create PROJECT_ID --branch release/feature
    --path is optional; omit it to create under ~/.warren/worktrees/
    (pass --path only when the worktree must live somewhere specific)
  warren workspace remove WORKSPACE_ID --force
    --keep-worktree keeps the local Git worktree on disk
  warren workspace move WORKSPACE_ID --before OTHER_WORKSPACE_ID
  warren terminal-group create --name NAME [--home PATH]
  warren terminal-group move GROUP_ID --before OTHER_GROUP_ID
  warren terminal-group remove GROUP_ID --force
  warren session create WORKSPACE_ID --kind codex --command codex
  warren session create --group GROUP_ID
  warren session create
  warren session current
  warren session move SESSION_ID --workspace WORKSPACE_ID [--confirm] [--expected-workspace ID] [--expected-agent-session ID]
  warren session move --current --workspace WORKSPACE_ID [--dry-run]
  warren session move SESSION_ID --group GROUP_ID [--confirm] [--dry-run]
  warren session undo OPERATION_ID
  warren session attach SESSION_ID [--current]
`
}

func agentUsageText() string {
	return `Usage:
  warren agent read codex|claude [SESSION_FILE] [FLAGS]
  warren agent wait SESSION_ID [--timeout DURATION] [--current]

Run 'warren agent read --help' or 'warren agent wait --help' for options.
`
}

func agentReadUsageText() string {
	return `Usage:
  warren agent read PROVIDER [SESSION_FILE]
      [--workspace PATH] [--recent N | --all]
      [--include TYPE,...] [--filter TYPE,...]
      [--chars N | --full]

PROVIDER is codex or claude. Without SESSION_FILE, Warren finds the newest
transcript for the current workspace (or --workspace PATH).

By default, only the newest 20 useful activities are returned and text fields
are limited to 2000 characters. --full disables text truncation; --all returns
all matching activities (up to 100000). Low-value usage, attachment, and
system instruction events are omitted unless selected explicitly with
--include.
`
}

func agentWaitUsageText() string {
	return `Usage:
  warren agent wait SESSION_ID [--timeout DURATION]
  warren agent wait --current [--timeout DURATION]

Wait for the running turn, or the next turn when the agent is idle. The
default timeout is 30 minutes. On completion, Warren prints the normalized
events belonging to that turn.
`
}

func resourceUsageText(commandName string) string {
	aliasNote := ""
	switch commandName {
	case "worktree":
		aliasNote = "\nworktree is an alias for workspace; use either name.\n"
	case "workspace":
		aliasNote = "\nworkspace has alias: worktree.\n"
	case "group":
		aliasNote = "\ngroup is an alias for terminal-group; use either name.\n"
	}
	switch canonicalResource(commandName) {
	case "project":
		return `Usage:
  warren project list
  warren project add PATH [--name NAME] [--auto-import-worktrees]
  warren project remove PROJECT_ID [--force]
  warren project rename PROJECT_ID --name NAME
  warren project pin PROJECT_ID --pinned BOOL
  warren project move PROJECT_ID [--before OTHER_PROJECT_ID]
`
	case "workspace":
		return fmt.Sprintf(`Usage:
  warren %s list
  warren %s create PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]
  warren %s remove WORKSPACE_ID [--force] [--keep-worktree]
  warren %s rename WORKSPACE_ID --name NAME
  warren %s pin WORKSPACE_ID --pinned BOOL
  warren %s move WORKSPACE_ID [--before OTHER_WORKSPACE_ID]
%s`, commandName, commandName, commandName, commandName, commandName, commandName, aliasNote)
	case "terminal-group":
		return fmt.Sprintf(`Usage:
  warren %s list
  warren %s create [--name NAME] [--home PATH]
  warren %s remove GROUP_ID [--force]
  warren %s rename GROUP_ID --name NAME
  warren %s home GROUP_ID --path PATH
  warren %s move GROUP_ID [--before OTHER_GROUP_ID]
%s`, commandName, commandName, commandName, commandName, commandName, commandName, aliasNote)
	case "session":
		return `Usage:
  warren session list [--all | --ended]
  warren session current
  warren session create [WORKSPACE_ID] [--group GROUP_ID] [--kind KIND] [--command CMD] [--title TITLE]
  warren session remove SESSION_ID [--force] [--current] [--dry-run]
  warren session rename SESSION_ID --title TITLE [--current]
  warren session pin SESSION_ID --pinned BOOL [--current]
  warren session move SESSION_ID --workspace WORKSPACE_ID [--confirm] [--expected-workspace ID] [--expected-agent-session ID] [--dry-run]
  warren session move --current --workspace WORKSPACE_ID [--dry-run]
  warren session move SESSION_ID --group GROUP_ID [--confirm] [--dry-run]
  warren session send SESSION_ID [TEXT...] [--current] [--wait] [--timeout DURATION]
  warren session read SESSION_ID [--timeout DURATION] [--contains TEXT] [--current]
  warren session attach SESSION_ID [--current]
  warren session undo OPERATION_ID
`
	}
	return ""
}

func actionUsageText(commandName, action string) string {
	name := commandName
	switch canonicalResource(commandName) + "." + action {
	case "project.list", "workspace.list", "session.list":
		if canonicalResource(commandName) == "session" {
			return fmt.Sprintf("Usage:\n  warren %s %s [--all | --ended]\n", name, action)
		}
		return fmt.Sprintf("Usage:\n  warren %s %s\n", name, action)
	case "project.add":
		return fmt.Sprintf("Usage:\n  warren %s add PATH [--name NAME] [--auto-import-worktrees]\n", name)
	case "project.remove", "project.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove PROJECT_ID [--force]\n", name)
	case "project.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename PROJECT_ID --name NAME\n", name)
	case "project.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin PROJECT_ID --pinned BOOL\n", name)
	case "project.move":
		return fmt.Sprintf("Usage:\n  warren %s move PROJECT_ID [--before OTHER_PROJECT_ID]\n", name)
	case "workspace.create", "workspace.add":
		return fmt.Sprintf("Usage:\n  warren %s create PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]\n", name)
	case "workspace.remove", "workspace.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove WORKSPACE_ID [--force] [--keep-worktree]\n", name)
	case "workspace.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename WORKSPACE_ID --name NAME\n", name)
	case "workspace.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin WORKSPACE_ID --pinned BOOL\n", name)
	case "workspace.move":
		return fmt.Sprintf("Usage:\n  warren %s move WORKSPACE_ID [--before OTHER_WORKSPACE_ID]\n", name)
	case "terminal-group.create", "terminal-group.add":
		return fmt.Sprintf("Usage:\n  warren %s create [--name NAME] [--home PATH]\n", name)
	case "terminal-group.remove", "terminal-group.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove GROUP_ID [--force]\n", name)
	case "terminal-group.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename GROUP_ID --name NAME\n", name)
	case "terminal-group.home":
		return fmt.Sprintf("Usage:\n  warren %s home GROUP_ID --path PATH\n", name)
	case "terminal-group.move":
		return fmt.Sprintf("Usage:\n  warren %s move GROUP_ID [--before OTHER_GROUP_ID]\n", name)
	case "session.create", "session.add":
		return fmt.Sprintf("Usage:\n  warren %s create [WORKSPACE_ID] [--group GROUP_ID] [--kind KIND] [--command CMD] [--title TITLE]\n", name)
	case "session.remove", "session.delete", "session.kill":
		return fmt.Sprintf("Usage:\n  warren %s remove SESSION_ID [--force] [--current] [--dry-run]\n", name)
	case "session.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename SESSION_ID --title TITLE [--current]\n", name)
	case "session.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin SESSION_ID --pinned BOOL [--current]\n", name)
	case "session.move":
		return fmt.Sprintf("Usage:\n  warren %s move SESSION_ID --workspace WORKSPACE_ID [--confirm] [--expected-workspace ID] [--expected-agent-session ID] [--dry-run]\n  warren %s move --current --workspace WORKSPACE_ID [--dry-run]\n  warren %s move SESSION_ID --group GROUP_ID [--confirm] [--dry-run]\n", name, name, name)
	case "session.send":
		return fmt.Sprintf("Usage:\n  warren %s send SESSION_ID [TEXT...] [--current] [--wait] [--timeout DURATION]\n", name)
	case "session.read":
		return fmt.Sprintf("Usage:\n  warren %s read SESSION_ID [--timeout DURATION] [--contains TEXT] [--current]\n", name)
	case "session.attach":
		return fmt.Sprintf("Usage:\n  warren %s attach SESSION_ID [--current]\n", name)
	case "session.current":
		return fmt.Sprintf("Usage:\n  warren %s current\n", name)
	case "session.undo":
		return fmt.Sprintf("Usage:\n  warren %s undo OPERATION_ID\n", name)
	}
	return resourceUsageText(commandName)
}

func endpointUsageText() string {
	return `Usage:
  warren endpoint list
  warren endpoint add NAME --url URL --token TOKEN [--ssh SSH] [--use]
  warren endpoint use NAME
  warren endpoint remove NAME
  warren endpoint current
`
}

func sshUsageText() string {
	return `Usage:
  warren ssh USER@HOST [--local-port PORT] [--remote-port PORT] [--name NAME]
`
}
