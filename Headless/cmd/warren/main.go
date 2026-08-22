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
	if resource == "session" && action == "send" && (boolValue(params, "wait") || stringValue(params, "timeout") != "") {
		return newUsageError("session send does not support Agent turn options; use agent send", actionUsageText(commandName, action))
	}
	if resource == "session" && action == "read" && sessionAgentReadFlag(params) {
		return newUsageError("session read only returns PTY output; use agent read for transcript data", actionUsageText(commandName, action))
	}
	if resource == "session" && (action == "create" || action == "add") {
		kind := strings.ToLower(strings.TrimSpace(stringValue(params, "kind")))
		if kind == "codex" || kind == "claude" {
			return newUsageError("session create cannot create Codex or Claude agents; use agent create", actionUsageText(commandName, action))
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
		_, err := c.Attach(ctx, id)
		if err != nil {
			return err
		}
		if err := sendTerminalText(ctx, c, text, boolValue(params, "raw")); err != nil {
			return err
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
	return sessionTerminalRead(ctx, c, params, follow)
}

func sessionAgentReadFlag(params map[string]any) bool {
	for _, key := range []string{"recent", "limit", "count", "all", "include", "filter", "exclude", "text-only", "text", "plain", "full", "full-content", "no-truncate", "chars", "max-chars", "head"} {
		if _, ok := params[key]; ok {
			return true
		}
	}
	return false
}

func sessionTerminalRead(ctx context.Context, c *client.Client, params map[string]any, follow bool) error {
	timeout := durationValue(params, "timeout", 8*time.Second)
	needle := stringValue(params, "contains")
	if follow {
		signalContext, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
		defer stop()
		ctx = signalContext
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

func agentReadSession(ctx context.Context, c *client.Client, session api.Session, params map[string]any) error {
	options, err := agentReadOptions(params)
	if err != nil {
		return err
	}
	events, err := readAgentHistory(ctx, c, session.ID, options)
	if err != nil {
		return err
	}
	events, err = agent.ProjectEvents(events, options)
	if err != nil {
		return err
	}
	if agentReadTextOnly(params) {
		return printAgentText(events)
	}
	return printValue(events)
}

func agentReadOptions(params map[string]any) (agent.ReadOptions, error) {
	recent := agent.DefaultReadRecent
	recentFlag := firstFlagValue(params, "recent", "limit", "count")
	if boolValue(params, "all") && recentFlag != "" {
		return agent.ReadOptions{}, newUsageError("--all cannot be combined with --recent, --limit, or --count", agentReadUsageText())
	}
	if boolValue(params, "all") {
		recent = 0
	}
	if recentFlag != "" {
		parsed, err := strconv.Atoi(recentFlag)
		if err != nil || parsed < 0 {
			return agent.ReadOptions{}, newUsageError("--recent must be a non-negative integer", agentReadUsageText())
		}
		recent = parsed
	}
	contentLimit := agent.DefaultReadContentLimit
	if value := firstFlagValue(params, "chars", "max-chars", "head"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			return agent.ReadOptions{}, newUsageError("--chars must be a non-negative integer", agentReadUsageText())
		}
		contentLimit = parsed
	}
	full := boolValue(params, "full") || boolValue(params, "full-content") || boolValue(params, "no-truncate")
	contentFlag := firstFlagValue(params, "chars", "max-chars", "head") != ""
	if full && contentFlag {
		return agent.ReadOptions{}, newUsageError("--full cannot be combined with --chars, --max-chars, or --head", agentReadUsageText())
	}
	return agent.ReadOptions{
		Recent:       recent,
		ContentLimit: contentLimit,
		Full:         full,
		IncludeTypes: splitTypeFlag(stringValue(params, "include")),
		ExcludeTypes: append(splitTypeFlag(stringValue(params, "filter")), splitTypeFlag(stringValue(params, "exclude"))...),
	}, nil
}

func readAgentHistory(ctx context.Context, c *client.Client, sessionID string, options agent.ReadOptions) ([]api.AgentEvent, error) {
	pageSize := 500
	var before uint64
	var pages []api.AgentEvent
	for {
		page, err := c.AgentHistory(ctx, sessionID, before, pageSize)
		if err != nil {
			return nil, err
		}
		if len(page.Events) > 0 {
			pages = append(page.Events, pages...)
		}
		if options.Recent > 0 {
			projected, projectErr := agent.ProjectEvents(pages, options)
			if projectErr != nil {
				return nil, projectErr
			}
			if len(projected) >= options.Recent || !page.HasMore || page.Cursor == 0 {
				break
			}
		} else if !page.HasMore || page.Cursor == 0 {
			break
		}
		before = page.Cursor
	}
	return pages, nil
}

func agentReadTextOnly(params map[string]any) bool {
	return boolValue(params, "text") || boolValue(params, "text-only") || boolValue(params, "plain")
}

func printAgentText(events []api.AgentEvent) error {
	lines := make([]string, 0, len(events))
	for _, event := range events {
		if event.Type != "user" && event.Type != "assistant" {
			continue
		}
		if event.Content == "" {
			continue
		}
		lines = append(lines, event.Content)
	}
	if outputJSON {
		return printValue(lines)
	}
	for _, line := range lines {
		fmt.Fprintln(os.Stdout, line)
	}
	return nil
}

func agentCommand(args []string) error {
	if len(args) == 0 || isHelpArgument(args[0]) {
		fmt.Print(agentUsageText())
		return nil
	}
	switch args[0] {
	case "create":
		return agentCreateCommand(args[1:])
	case "list":
		return agentListCommand(args[1:])
	case "current":
		return agentCurrentCommand(args[1:])
	case "send":
		return agentSendCommand(args[1:])
	case "read":
		return agentReadCommand(args[1:])
	case "wait":
		return agentWaitCommand(args[1:])
	case "attach":
		return agentAttachCommand(args[1:])
	case "remove", "delete", "rename", "pin", "move":
		return agentSessionMutationCommand(args[0], args[1:])
	default:
		return newUsageError(fmt.Sprintf("unknown agent command: %s", args[0]), agentUsageText())
	}
}

func agentCreateCommand(args []string) error {
	help, err := validateAgentCreateArgs(args)
	if err != nil {
		return newUsageError(err.Error(), agentCreateUsageText())
	}
	if help {
		fmt.Print(agentCreateUsageText())
		return nil
	}
	params := parseFlags(args)
	positions := positionals(params)
	if len(positions) > 1 {
		return newUsageError("agent create accepts at most one workspace ID", agentCreateUsageText())
	}
	if len(positions) > 0 && stringValue(params, "group") != "" {
		return newUsageError("workspace and --group are mutually exclusive", agentCreateUsageText())
	}
	provider := strings.ToLower(strings.TrimSpace(stringValue(params, "provider")))
	if provider != "codex" && provider != "claude" {
		return newUsageError("--provider must be codex or claude", agentCreateUsageText())
	}
	command := strings.TrimSpace(stringValue(params, "command"))
	if command == "" {
		command = provider
	}
	if err := validateAgentCommand(command, provider); err != nil {
		return newUsageError(err.Error(), agentCreateUsageText())
	}
	prompt := stringValue(params, "prompt")
	hasPrompt := prompt != ""
	noPrompt := boolValue(params, "no-prompt")
	if !hasPrompt && !noPrompt {
		return newUsageError("specify --prompt TEXT or --no-prompt", agentCreateUsageText())
	}
	if boolValue(params, "wait") && !hasPrompt {
		return newUsageError("--wait requires --prompt", agentCreateUsageText())
	}
	if stringValue(params, "timeout") != "" && !boolValue(params, "wait") {
		return newUsageError("--timeout requires --wait", agentCreateUsageText())
	}
	var waitTimeout time.Duration
	if boolValue(params, "wait") {
		waitTimeout, err = agentWaitTimeout(params)
		if err != nil {
			return newUsageError(err.Error(), agentCreateUsageText())
		}
	}

	request := normalizedParams(params, "session", "create")
	request["kind"] = provider
	if hasPrompt {
		// Codex and Claude both accept an initial prompt as the final
		// positional argument. Let the provider create its first turn so the
		// transcript exists before Warren starts waiting on it; subsequent
		// messages still use the interactive composer path below.
		command = appendAgentInitialPrompt(command, prompt)
	}
	request["command"] = command
	for _, key := range []string{"provider", "prompt", "no-prompt", "wait", "timeout", "help", "h"} {
		delete(request, key)
	}

	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	var session api.Session
	if err := c.Request(ctx, "session.create", request, &session); err != nil {
		return err
	}
	result := agentCreateResult{Session: session, PromptSent: hasPrompt}
	if hasPrompt && boolValue(params, "wait") {
		subscription, readyErr := waitForAgentSubscription(ctx, c, session.ID, agentStartupTimeout)
		if readyErr != nil {
			return fmt.Errorf("agent %s created with initial prompt but transcript was not ready: %w", session.ID, readyErr)
		}
		after, current := agentWaitCursor(subscription.Snapshot)
		waitResult, err := waitAgentTurnResultForInitialPrompt(c, session.ID, subscription.Snapshot, after, current, waitTimeout)
		if err != nil {
			return err
		}
		result.Wait = &waitResult
	}
	if err := printValue(result); err != nil {
		return err
	}
	if result.Wait != nil && result.Wait.Status != api.AgentTurnCompleted {
		return fmt.Errorf("agent turn %d ended with status %s", result.Wait.Turn, result.Wait.Status)
	}
	return nil
}

type agentCreateResult struct {
	Session    api.Session          `json:"session"`
	PromptSent bool                 `json:"promptSent"`
	Wait       *api.AgentWaitResult `json:"wait,omitempty"`
}

func agentListCommand(args []string) error {
	params := parseFlags(args)
	if boolValue(params, "help") || boolValue(params, "h") {
		fmt.Print(agentListUsageText())
		return nil
	}
	if len(positionals(params)) > 0 {
		return newUsageError("agent list does not accept an ID", agentListUsageText())
	}
	if boolValue(params, "all") && boolValue(params, "ended") {
		return newUsageError("--all and --ended are mutually exclusive", agentListUsageText())
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	state, err := c.Roster(ctx)
	if err != nil {
		return err
	}
	rows := sessionRowsForCurrent(state, boolValue(params, "all"), boolValue(params, "ended"), strings.TrimSpace(os.Getenv(agent.BindEnvSession)))
	filtered := rows[:0]
	for _, row := range rows {
		if isAgentSession(row.Session) {
			filtered = append(filtered, row)
		}
	}
	return printValue(filtered)
}

func agentCurrentCommand(args []string) error {
	params := parseFlags(args)
	if boolValue(params, "help") || boolValue(params, "h") {
		fmt.Print(agentCurrentUsageText())
		return nil
	}
	if len(positionals(params)) > 0 {
		return newUsageError("agent current does not accept an ID", agentCurrentUsageText())
	}
	id, err := currentSessionID()
	if err != nil {
		return err
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	var session api.Session
	if err := c.Request(ctx, "session.current", map[string]any{"id": id}, &session); err != nil {
		return err
	}
	if !isAgentSession(session) {
		return fmt.Errorf("current session is not a Codex or Claude agent: %s", session.ID)
	}
	return printValue(currentSessionValue{Session: session, WarrenSessionID: session.ID, AgentThreadID: session.AgentSessionID, Current: true})
}

func agentSendCommand(args []string) error {
	help, err := validateAgentSendArgs(args)
	if err != nil {
		return newUsageError(err.Error(), agentSendUsageText())
	}
	if help {
		fmt.Print(agentSendUsageText())
		return nil
	}
	params := parseFlags(args)
	if values := collectAgentTypeFlags(args, "include"); len(values) > 0 {
		params["include"] = strings.Join(values, ",")
	}
	if values := collectAgentTypeFlags(args, "filter", "exclude"); len(values) > 0 {
		params["exclude"] = strings.Join(values, ",")
		delete(params, "filter")
	}
	positions := positionals(params)
	var id string
	var text string
	if boolValue(params, "current") {
		id, err = currentSessionID()
		if err != nil {
			return err
		}
		text = strings.Join(positions, " ")
	} else {
		if len(positions) == 0 {
			return newUsageError("missing AGENT_ID", agentSendUsageText())
		}
		id = positions[0]
		text = strings.Join(positions[1:], " ")
	}
	if text == "" {
		data, readErr := io.ReadAll(os.Stdin)
		if readErr != nil {
			return readErr
		}
		text = string(data)
	}
	if text == "" {
		return newUsageError("missing TEXT or stdin input", agentSendUsageText())
	}
	var waitTimeout time.Duration
	if boolValue(params, "wait") {
		waitTimeout, err = agentWaitTimeout(params)
		if err != nil {
			return newUsageError(err.Error(), agentSendUsageText())
		}
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	session, err := c.Attach(ctx, id)
	if err != nil {
		return err
	}
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex or Claude agent: %s", session.ID)
	}
	subscription, err := waitForAgentSubscription(ctx, c, id, agentStartupTimeout)
	if err != nil {
		return err
	}
	if boolValue(params, "wait") {
		if err := validateAgentSendWait(subscription.Snapshot); err != nil {
			return err
		}
	}
	if err := sendAgentText(ctx, c, text); err != nil {
		return err
	}
	if !boolValue(params, "wait") {
		return printValue(map[string]any{"sent": true, "agent": id})
	}
	return waitAndPrintAgentTurn(c, id, subscription.Snapshot, subscription.Snapshot.Turn.ID, 0, waitTimeout)
}

func agentReadCommand(args []string) error {
	help, err := validateAgentReadArgs(args)
	if err != nil {
		return newUsageError(err.Error(), agentReadUsageText())
	}
	if help {
		fmt.Print(agentReadUsageText())
		return nil
	}
	params := parseFlags(args)
	if values := collectAgentTypeFlags(args, "include"); len(values) > 0 {
		params["include"] = strings.Join(values, ",")
	}
	if values := collectAgentTypeFlags(args, "filter", "exclude"); len(values) > 0 {
		params["exclude"] = strings.Join(values, ",")
	}
	positions := positionals(params)
	var id string
	if boolValue(params, "current") {
		if len(positions) > 0 {
			return newUsageError("--current cannot be combined with AGENT_ID", agentReadUsageText())
		}
		id, err = currentSessionID()
		if err != nil {
			return err
		}
	} else {
		if len(positions) == 0 {
			return newUsageError("missing AGENT_ID", agentReadUsageText())
		}
		if len(positions) > 1 {
			return newUsageError("agent read accepts exactly one AGENT_ID", agentReadUsageText())
		}
		id = positions[0]
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	subscription, err := waitForAgentSubscription(ctx, c, id, agentStartupTimeout)
	if err != nil {
		return err
	}
	session := subscription.Session
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex or Claude agent: %s", session.ID)
	}
	return agentReadSession(ctx, c, session, params)
}

func agentAttachCommand(args []string) error {
	params := parseFlags(args)
	if boolValue(params, "help") || boolValue(params, "h") {
		fmt.Print(agentAttachUsageText())
		return nil
	}
	positions := positionals(params)
	var id string
	var err error
	if boolValue(params, "current") {
		if len(positions) > 0 {
			return newUsageError("--current cannot be combined with AGENT_ID", agentAttachUsageText())
		}
		id, err = currentSessionID()
		if err != nil {
			return err
		}
	} else {
		if len(positions) == 0 {
			return newUsageError("missing AGENT_ID", agentAttachUsageText())
		}
		if len(positions) > 1 {
			return newUsageError("agent attach accepts exactly one AGENT_ID", agentAttachUsageText())
		}
		id = positions[0]
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	session, err := c.Attach(ctx, id)
	if err != nil {
		return err
	}
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex or Claude agent: %s", session.ID)
	}
	return sessionTerminalRead(ctx, c, map[string]any{"timeout": ""}, true)
}

func agentSessionMutationCommand(action string, args []string) error {
	params := parseFlags(args)
	if boolValue(params, "help") || boolValue(params, "h") {
		fmt.Print(agentActionUsageText(action))
		return nil
	}
	if sessionTargetAction(action) && boolValue(params, "current") && len(positionals(params)) > 0 {
		return newUsageError("--current cannot be combined with AGENT_ID", agentActionUsageText(action))
	}
	if !boolValue(params, "current") && len(positionals(params)) == 0 {
		return newUsageError("missing AGENT_ID", agentActionUsageText(action))
	}
	translated := append([]string{"session", action}, args...)
	return resourceCommand(translated)
}

const (
	defaultAgentWaitTimeout = 30 * time.Minute
	// Agent TUIs treat a literal carriage return as composer text. The web
	// client sends the message and a kitty-protocol Enter event separately so
	// the TUI submits it as a key press instead of leaving it in the input box.
	agentSubmitDelay = 80 * time.Millisecond
	agentSubmitEvent = "\x1b[13u"
	// Creating a terminal returns before the CLI has necessarily completed its
	// first-run setup and written a transcript binding. Give normal startup a
	// bounded window, while still failing clearly when setup is required.
	agentStartupTimeout = 10 * time.Second
)

func isAgentSession(session api.Session) bool {
	return session.Kind == "codex" || session.Kind == "claude" || session.AgentSessionID != ""
}

func waitForAgentSubscription(
	parent context.Context,
	c *client.Client,
	sessionID string,
	timeout time.Duration,
) (api.AgentSubscriptionResult, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	var lastErr error
	for {
		subscription, err := c.SubscribeAgent(ctx, sessionID)
		if err == nil {
			return subscription, nil
		}
		lastErr = err
		if !retryAgentSubscription(err) {
			return api.AgentSubscriptionResult{}, err
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) && lastErr != nil {
				return api.AgentSubscriptionResult{}, fmt.Errorf(
					"agent is not ready after %s; finish first-time setup in Terminal and retry: %w",
					timeout,
					lastErr,
				)
			}
			return api.AgentSubscriptionResult{}, ctx.Err()
		case <-timer.C:
		}
	}
}

func retryAgentSubscription(err error) bool {
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "still starting") ||
		strings.Contains(message, "not bound to an agent")
}

func sendTerminalText(ctx context.Context, c *client.Client, text string, raw bool) error {
	return sendTerminalTextWithInput(ctx, c.Input, text, raw)
}

func sendTerminalTextWithInput(
	ctx context.Context,
	input func(context.Context, []byte) error,
	text string,
	raw bool,
) error {
	if !strings.HasSuffix(text, "\n") && !raw {
		text += "\r"
	}
	return input(ctx, []byte(text))
}

func sendAgentText(ctx context.Context, c *client.Client, text string) error {
	return sendAgentTextWithInput(ctx, c.Input, text)
}

// validateAgentCommand keeps the command field focused on the executable and
// its options. A positional argument is the provider's startup prompt for
// both Codex and Claude, so accepting one alongside --prompt would create two
// competing initial turns.
func validateAgentCommand(command, provider string) error {
	if err := validateAgentCommandShellSyntax(command); err != nil {
		return err
	}
	tokens, err := splitShellWords(command)
	if err != nil {
		return fmt.Errorf("invalid --command: %w", err)
	}
	if len(tokens) == 0 {
		return errors.New("--command must not be empty")
	}
	for _, token := range tokens {
		if agentCommandShellOperator[token] {
			return errors.New("--command must be an executable with options; shell operators are not supported")
		}
	}
	valueFlags := agentCommandValueFlags[provider]
	for index := 1; index < len(tokens); index++ {
		token := tokens[index]
		if token == "--" {
			if index+1 < len(tokens) {
				return fmt.Errorf("--command for %s must not include a positional prompt; pass it with --prompt", provider)
			}
			continue
		}
		if strings.HasPrefix(token, "-") {
			flagName := token
			equal := strings.IndexByte(flagName, '=')
			if equal >= 0 {
				flagName = flagName[:equal]
			}
			if agentCommandPromptFlags[provider][flagName] {
				return fmt.Errorf("--command for %s must not provide a prompt; pass it with --prompt", provider)
			}
			if agentCommandNonInteractiveFlags[provider][flagName] {
				return fmt.Errorf("--command for %s must use interactive mode; remove %s and pass initial text with --prompt", provider, flagName)
			}
			if valueFlags[flagName] && equal < 0 {
				if index+1 >= len(tokens) || strings.HasPrefix(tokens[index+1], "-") {
					return fmt.Errorf("--command option %s requires a value", flagName)
				}
				index++
			}
			continue
		}
		return fmt.Errorf("--command for %s must not include a positional prompt; pass it with --prompt", provider)
	}
	return nil
}

func validateAgentCommandShellSyntax(command string) error {
	inSingle, inDouble, escaped := false, false, false
	for _, char := range command {
		if escaped {
			escaped = false
			continue
		}
		if inSingle {
			if char == '\'' {
				inSingle = false
			}
			continue
		}
		if inDouble {
			switch char {
			case '\\':
				escaped = true
			case '"':
				inDouble = false
			case '`', '$':
				return errors.New("--command must not contain shell operators or substitutions")
			}
			continue
		}
		switch char {
		case '\\':
			escaped = true
		case '\'':
			inSingle = true
		case '"':
			inDouble = true
		case ';', '&', '|', '>', '<', '`', '(', ')', '\n', '$':
			return errors.New("--command must be an executable with options; shell operators and substitutions are not supported")
		}
	}
	return nil
}

var agentCommandPromptFlags = map[string]map[string]bool{
	"codex":  {"--prompt": true},
	"claude": {"--prompt": true},
}

var agentCommandNonInteractiveFlags = map[string]map[string]bool{
	"claude": {"-p": true, "--print": true},
}

var agentCommandShellOperator = map[string]bool{
	";": true, "&&": true, "||": true, "|": true,
	"&": true, ">": true, ">>": true, "<": true, "<<": true,
}

// These options consume the following shell word. Unknown options are left
// conservative: a following non-option word is treated as a conflicting
// prompt instead of being silently appended after it.
var agentCommandValueFlags = map[string]map[string]bool{
	"codex": {
		"-c": true, "--config": true, "--enable": true, "--disable": true,
		"-i": true, "--image": true, "-m": true, "--model": true,
		"-p": true, "--profile": true, "-s": true, "--sandbox": true,
		"-a": true, "--ask-for-approval": true, "-C": true, "--cd": true,
		"--add-dir": true, "--local-provider": true, "--remote": true,
		"--remote-auth-token-env": true,
	},
	"claude": {
		"--add-dir": true, "--agent": true, "--agents": true,
		"--allowedTools": true, "--allowed-tools": true, "--append-system-prompt": true,
		"--append-system-prompt-file": true, "--betas": true, "-d": true,
		"--debug": true, "--debug-file": true, "--effort": true,
		"--fallback-model": true, "--file": true, "--from-pr": true,
		"--json-schema": true, "--max-budget-usd": true, "--mcp-config": true,
		"--model": true, "-n": true, "--name": true, "--output-format": true,
		"--permission-mode": true, "--plugin-dir": true, "--plugin-url": true,
		"--prompt-suggestions": true, "-r": true, "--resume": true,
		"--settings": true, "--setting-sources": true, "--system-prompt": true,
		"--system-prompt-file": true, "--tools": true, "--input-format": true,
		"--session-id": true, "--disallowedTools": true, "--disallowed-tools": true,
		"--remote-control-session-name-prefix": true,
	},
}

// splitShellWords handles the quoting needed by executable arguments without
// attempting to evaluate shell expansions. Commands containing operators are
// rejected by validateAgentCommand before they reach the runtime.
func splitShellWords(command string) ([]string, error) {
	var words []string
	var current strings.Builder
	inSingle, inDouble, escaped, started := false, false, false, false
	flush := func() {
		if started {
			words = append(words, current.String())
			current.Reset()
			started = false
		}
	}
	for _, char := range command {
		switch {
		case escaped:
			current.WriteRune(char)
			escaped = false
			started = true
		case inSingle:
			if char == '\'' {
				inSingle = false
			} else {
				current.WriteRune(char)
			}
			started = true
		case inDouble:
			switch char {
			case '"':
				inDouble = false
			case '\\':
				escaped = true
			default:
				current.WriteRune(char)
			}
			started = true
		default:
			switch {
			case char == '\\':
				escaped = true
				started = true
			case char == '\'':
				inSingle = true
				started = true
			case char == '"':
				inDouble = true
				started = true
			case char == ' ' || char == '\t' || char == '\r' || char == '\n':
				flush()
			default:
				current.WriteRune(char)
				started = true
			}
		}
	}
	if escaped {
		return nil, errors.New("trailing escape")
	}
	if inSingle || inDouble {
		return nil, errors.New("unterminated quote")
	}
	flush()
	return words, nil
}

// appendAgentInitialPrompt adds a provider CLI's positional startup prompt to
// an executable command that may already contain arbitrary arguments. The
// command is evaluated by a POSIX shell inside the terminal runtime, so quote
// the prompt as one shell word instead of interpolating it literally.
func appendAgentInitialPrompt(command, prompt string) string {
	return strings.TrimSpace(command) + " " + shellQuote(prompt)
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func sendAgentTextWithInput(
	ctx context.Context,
	input func(context.Context, []byte) error,
	text string,
) error {
	// Preserve deliberate line breaks as composer returns, then submit with
	// the same kitty Enter event used by the web Agent view. A CR in the
	// message itself is text; it is not the submit action.
	text = strings.ReplaceAll(text, "\n", "\r")
	if err := input(ctx, []byte(text)); err != nil {
		return err
	}
	if err := waitForInputDelay(ctx, agentSubmitDelay); err != nil {
		return err
	}
	return input(ctx, []byte(agentSubmitEvent))
}

func waitForInputDelay(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

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
			return newUsageError("--current cannot be combined with AGENT_ID", agentWaitUsageText())
		}
		id, err := currentSessionID()
		if err != nil {
			return err
		}
		positions = []string{id}
	}
	if len(positions) == 0 {
		return newUsageError("missing AGENT_ID", agentWaitUsageText())
	}
	if len(positions) > 1 {
		return newUsageError("agent wait accepts exactly one AGENT_ID", agentWaitUsageText())
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
	session, err := c.Attach(ctx, positions[0])
	if err != nil {
		return err
	}
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex or Claude agent: %s", session.ID)
	}
	subscription, err := waitForAgentSubscription(ctx, c, positions[0], agentStartupTimeout)
	if err != nil {
		return err
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
		return errors.New("agent already has a running turn; wait for it before using agent send --wait")
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
	result, err := waitAgentTurnResult(c, sessionID, snapshot, after, current, timeout)
	if err != nil {
		return err
	}
	if err := printValue(result); err != nil {
		return err
	}
	if result.Status != api.AgentTurnCompleted {
		return fmt.Errorf("agent turn %d ended with status %s", result.Turn, result.Status)
	}
	return nil
}

func waitAgentTurnResult(
	c *client.Client,
	sessionID string,
	snapshot api.AgentSnapshotResult,
	after uint64,
	current uint64,
	timeout time.Duration,
) (api.AgentWaitResult, error) {
	return waitAgentTurnResultMode(c, sessionID, snapshot, after, current, timeout, false)
}

func waitAgentTurnResultForInitialPrompt(
	c *client.Client,
	sessionID string,
	snapshot api.AgentSnapshotResult,
	after uint64,
	current uint64,
	timeout time.Duration,
) (api.AgentWaitResult, error) {
	return waitAgentTurnResultMode(c, sessionID, snapshot, after, current, timeout, true)
}

func waitAgentTurnResultMode(
	c *client.Client,
	sessionID string,
	snapshot api.AgentSnapshotResult,
	after uint64,
	current uint64,
	timeout time.Duration,
	acceptCompletedSnapshot bool,
) (api.AgentWaitResult, error) {
	// A subscription only broadcasts boundaries observed after it is
	// registered. The initial-prompt path may have completed before the
	// subscription was registered, so its terminal snapshot is a valid result.
	// Standalone `agent wait` deliberately continues to the next turn when the
	// Agent is idle; otherwise it would repeat the latest historical turn.
	if acceptCompletedSnapshot && current == 0 && snapshot.Turn.ID > after && terminalAgentTurnStatus(snapshot.Turn.Status) {
		return completedAgentTurnResult(c, sessionID, snapshot)
	}
	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	waitContext, cancel := context.WithTimeout(signalContext, timeout)
	defer cancel()
	turn, err := c.WaitAgentTurn(waitContext, sessionID, snapshot.Epoch, after, current)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return api.AgentWaitResult{}, fmt.Errorf("agent turn did not complete before timeout %s", timeout)
		}
		return api.AgentWaitResult{}, err
	}
	fetchContext, fetchCancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer fetchCancel()
	events, err := c.AgentTurnEvents(fetchContext, sessionID, turn.ID)
	if err != nil {
		return api.AgentWaitResult{}, fmt.Errorf("read completed agent turn %d: %w", turn.ID, err)
	}
	return api.AgentWaitResult{
		Session: sessionID,
		Epoch:   snapshot.Epoch,
		Turn:    turn.ID,
		Status:  turn.Status,
		Events:  events,
	}, nil
}

func terminalAgentTurnStatus(status api.AgentTurnStatus) bool {
	switch status {
	case api.AgentTurnCompleted, api.AgentTurnFailed, api.AgentTurnAborted:
		return true
	default:
		return false
	}
}

func completedAgentTurnResult(
	c *client.Client,
	sessionID string,
	snapshot api.AgentSnapshotResult,
) (api.AgentWaitResult, error) {
	fetchContext, fetchCancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer fetchCancel()
	events, err := c.AgentTurnEvents(fetchContext, sessionID, snapshot.Turn.ID)
	if err != nil {
		return api.AgentWaitResult{}, fmt.Errorf("read completed agent turn %d: %w", snapshot.Turn.ID, err)
	}
	return api.AgentWaitResult{
		Session: sessionID,
		Epoch:   snapshot.Epoch,
		Turn:    snapshot.Turn.ID,
		Status:  snapshot.Turn.Status,
		Events:  events,
	}, nil
}

var agentReadValueFlags = map[string]bool{
	"recent": true, "limit": true, "count": true,
	"chars": true, "max-chars": true, "head": true,
	"include": true, "filter": true, "exclude": true,
}

var agentReadBooleanFlags = map[string]bool{
	"all": true, "full": true, "full-content": true,
	"no-truncate": true, "text": true, "text-only": true, "plain": true,
	"current": true, "help": true,
}

var agentCreateValueFlags = map[string]bool{
	"provider": true, "command": true, "prompt": true, "title": true,
	"group": true, "runtime-kind": true, "timeout": true,
}

var agentCreateBooleanFlags = map[string]bool{
	"no-prompt": true, "wait": true, "help": true,
}

var agentSendValueFlags = map[string]bool{"timeout": true}

var agentSendBooleanFlags = map[string]bool{
	"current": true, "wait": true, "help": true,
}

// validateAgentReadArgs gives the remote transcript reader a strict flag schema.
// parseFlags is intentionally permissive because the other resource commands
// accept arbitrary daemon parameters; using it directly here would silently
// ignore typos and malformed flag invocations.
func validateAgentReadArgs(args []string) (bool, error) {
	help, present, err := validateStrictFlags(args, agentReadValueFlags, agentReadBooleanFlags)
	if err != nil || help {
		return help, err
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

func validateAgentCreateArgs(args []string) (bool, error) {
	help, present, err := validateStrictFlags(args, agentCreateValueFlags, agentCreateBooleanFlags)
	if err != nil || help {
		return help, err
	}
	if !present["provider"] {
		return false, errors.New("--provider is required")
	}
	if !present["prompt"] && !present["no-prompt"] {
		return false, errors.New("specify --prompt TEXT or --no-prompt")
	}
	if present["prompt"] && present["no-prompt"] {
		return false, errors.New("--prompt and --no-prompt are mutually exclusive")
	}
	if present["timeout"] && !present["wait"] {
		return false, errors.New("--timeout requires --wait")
	}
	return false, nil
}

func validateAgentSendArgs(args []string) (bool, error) {
	help, present, err := validateStrictFlags(args, agentSendValueFlags, agentSendBooleanFlags)
	if err != nil || help {
		return help, err
	}
	if present["timeout"] && !present["wait"] {
		return false, errors.New("--timeout requires --wait")
	}
	return false, nil
}

func validateStrictFlags(args []string, valueFlags, booleanFlags map[string]bool) (bool, map[string]bool, error) {
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
			return false, nil, fmt.Errorf("unknown flag %q", item)
		}
		name, value, hasValue := splitFlag(item)
		if booleanFlags[name] {
			if hasValue {
				return false, nil, fmt.Errorf("--%s does not take a value", name)
			}
			present[name] = true
			if name == "help" {
				help = true
			}
			continue
		}
		if !valueFlags[name] {
			return false, nil, fmt.Errorf("unknown flag %q", item)
		}
		if !hasValue {
			if index+1 >= len(args) || args[index+1] == "-h" || strings.HasPrefix(args[index+1], "--") {
				return false, nil, fmt.Errorf("--%s requires a value", name)
			}
			index++
		} else if value == "" {
			return false, nil, fmt.Errorf("--%s requires a non-empty value", name)
		}
		present[name] = true
	}
	return help, present, nil
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
		name, value, hasValue := splitFlag(item)
		if !wanted[name] {
			continue
		}
		if !hasValue && index+1 < len(args) {
			index++
			value = args[index]
		}
		if strings.TrimSpace(value) != "" {
			values = append(values, value)
		}
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
	remoteStart := "command -v warren-headless >/dev/null || { echo 'warren-headless is not installed' >&2; exit 127; }; mkdir -p ~/.warren; test -s ~/.warren/token || (umask 077; openssl rand -hex 32 > ~/.warren/token); (curl -fsS http://127.0.0.1:" + remotePort + "/healthz >/dev/null 2>&1 || nohup warren-headless --listen 127.0.0.1:" + remotePort + " > ~/.warren/headless.log 2>&1 &); cat ~/.warren/token"
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
	"no-prompt":             true,
	"raw":                   true,
	"terminal":              true,
	"text":                  true,
	"text-only":             true,
	"plain":                 true,
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
	case agentCreateResult:
		printKVTable(agentCreatePairs(items))
	case *agentCreateResult:
		printKVTable(agentCreatePairs(*items))
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

func agentCreatePairs(value agentCreateResult) [][2]string {
	pairs := [][2]string{
		{"AGENT ID", value.Session.ID},
		{"PROVIDER", value.Session.Kind},
		{"COMMAND", displayValue(value.Session.Command)},
		{"TITLE", effectiveSessionTitle(value.Session)},
		{"PROMPT SENT", displayBool(value.PromptSent)},
		{"LIFECYCLE", value.Session.Lifecycle},
	}
	if value.Wait != nil {
		pairs = append(pairs,
			[2]string{"TURN", strconv.FormatUint(value.Wait.Turn, 10)},
			[2]string{"TURN STATUS", string(value.Wait.Status)},
		)
	}
	return pairs
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
  agent create|list|current|send|read|wait|attach|remove|rename|pin|move
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
  warren agent create WORKSPACE_ID --provider codex --prompt "Run the tests"
  warren agent create WORKSPACE_ID --provider codex --command codex-alias --prompt "Fix the bug"
  warren agent list
  warren agent read AGENT_ID --text-only
  warren agent wait AGENT_ID --timeout 30m
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
  warren session create WORKSPACE_ID --kind shell --command bash
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
  warren agent create [WORKSPACE_ID] --provider codex|claude [--command CMD] [--prompt TEXT | --no-prompt]
  warren agent list [--all | --ended]
  warren agent current
  warren agent send AGENT_ID [TEXT...] [--current] [--wait] [--timeout DURATION]
  warren agent read AGENT_ID [--current] [--recent N | --all] [--include TYPE,...] [--filter TYPE,...] [--text-only] [--full]
  warren agent wait AGENT_ID [--timeout DURATION] [--current]
  warren agent attach AGENT_ID [--current]
  warren agent remove AGENT_ID [--force] [--current] [--dry-run]
  warren agent rename AGENT_ID --title TITLE [--current]
  warren agent pin AGENT_ID --pinned BOOL [--current]
  warren agent move AGENT_ID --workspace WORKSPACE_ID [--confirm] [--dry-run]

Run 'warren agent <command> --help' for command-specific help.
`
}

func agentCreateUsageText() string {
	return `Usage:
  warren agent create [WORKSPACE_ID]
      --provider codex|claude
      [--command CMD]
      [--prompt TEXT | --no-prompt]
      [--group GROUP_ID] [--title TITLE] [--wait] [--timeout DURATION]

Create an Agent backed by a Codex or Claude session. --prompt is appended as
the provider's initial positional prompt. Use --no-prompt to create an idle
Agent explicitly. --command defaults to the provider executable and may name
an alias or wrapper command with options, but must not include a positional
prompt; pass that through --prompt instead.
`
}

func agentListUsageText() string {
	return `Usage:
  warren agent list [--all | --ended]
`
}

func agentCurrentUsageText() string {
	return `Usage:
  warren agent current

Read the Agent bound to WARREN_SESSION_ID.
`
}

func agentSendUsageText() string {
	return `Usage:
  warren agent send AGENT_ID [TEXT...] [--current] [--wait] [--timeout DURATION]

If TEXT is omitted, Warren reads the prompt from stdin.
`
}

func agentReadUsageText() string {
	return `Usage:
  warren agent read AGENT_ID [--current]
      [--recent N | --all]
      [--include TYPE,...] [--filter TYPE,...]
      [--chars N | --full] [--text-only]

Read the normalized transcript for a Warren Agent. By default, only the
newest 20 useful activities are returned and text fields are limited to 2000
characters. --full disables text truncation; --all returns all matching
activities (up to 100000). --text-only prints user and assistant text.
`
}

func agentWaitUsageText() string {
	return `Usage:
  warren agent wait AGENT_ID [--timeout DURATION]
  warren agent wait --current [--timeout DURATION]

Wait for the running turn, or the next turn when the agent is idle. The
default timeout is 30 minutes. On completion, Warren prints the normalized
events belonging to that turn.
`
}

func agentAttachUsageText() string {
	return `Usage:
  warren agent attach AGENT_ID [--current]

Attach to the Agent's live terminal. Use agent read for transcript data.
`
}

func agentActionUsageText(action string) string {
	switch action {
	case "remove", "delete":
		return "Usage:\n  warren agent remove AGENT_ID [--force] [--current] [--dry-run]\n"
	case "rename":
		return "Usage:\n  warren agent rename AGENT_ID --title TITLE [--current]\n"
	case "pin":
		return "Usage:\n  warren agent pin AGENT_ID --pinned BOOL [--current]\n"
	case "move":
		return "Usage:\n  warren agent move AGENT_ID --workspace WORKSPACE_ID [--confirm] [--dry-run]\n"
	default:
		return agentUsageText()
	}
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
  warren session send SESSION_ID [TEXT...] [--current] [--raw]
  warren session read SESSION_ID [--timeout DURATION] [--contains TEXT] [--current]
  warren session attach SESSION_ID [--current]
  warren session undo OPERATION_ID

Session is a generic PTY resource. Use agent create for Codex or Claude.
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
		return fmt.Sprintf("Usage:\n  warren %s send SESSION_ID [TEXT...] [--current] [--raw]\n", name)
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
