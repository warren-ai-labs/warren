package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

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
	var actionValueFlags map[string]bool
	if resource == "browser" && action == "action" {
		actionValueFlags = browserActionValueFlags
	}
	params := parseFlags(args[2:], actionValueFlags)
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
	if resource == "session" && action == "panes" && len(positionals(params)) > 1 {
		return newUsageError("session panes accepts at most one SESSION_ID", actionUsageText(commandName, action))
	}
	if label := missingRequiredFlag(resource, action, params); label != "" {
		return newUsageError("missing "+label, actionUsageText(commandName, action))
	}
	if resource == "session" && action == "list" && boolValue(params, "all") && boolValue(params, "ended") {
		return newUsageError("--all and --ended are mutually exclusive", actionUsageText(commandName, action))
	}
	if action == "list" {
		if _, err := listLimit(params); err != nil {
			return newUsageError(err.Error(), actionUsageText(commandName, action))
		}
		if resource == "session" && len(positionals(params)) > 1 {
			return newUsageError("session list accepts at most one workspace ID", actionUsageText(commandName, action))
		}
		if resource == "workspace" && len(positionals(params)) > 1 {
			return newUsageError("workspace list accepts at most one project ID", actionUsageText(commandName, action))
		}
		if (resource == "task" || resource == "project" || resource == "terminal-group") && len(positionals(params)) > 0 {
			return newUsageError(fmt.Sprintf("%s list does not accept positional arguments", commandName), actionUsageText(commandName, action))
		}
	}
	if resource == "session" && action == "send" && (boolValue(params, "wait") || stringValue(params, "timeout") != "") {
		return newUsageError("session send does not support Agent turn options; use agent send", actionUsageText(commandName, action))
	}
	if resource == "session" && action == "read" && sessionAgentReadFlag(params) {
		return newUsageError("session read only returns PTY output; use agent read for transcript data", actionUsageText(commandName, action))
	}
	if resource == "session" && (action == "create" || action == "add") {
		kind := strings.ToLower(strings.TrimSpace(stringValue(params, "kind")))
		if kind == "codex" || kind == "claude" || kind == "opencode" || kind == "pi" || kind == "qoder" {
			return newUsageError("session create cannot create Codex, Claude, OpenCode, Pi, or Qoder agents; use agent create", actionUsageText(commandName, action))
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
	// `session panes` defaults to the Session it runs inside, so an agent can
	// ask what shares its screen without knowing its own ID.
	var resolvedPanesID string
	if resource == "session" && action == "panes" {
		if positions := positionals(params); len(positions) == 1 {
			resolvedPanesID = positions[0]
		} else {
			var err error
			resolvedPanesID, err = currentSessionID()
			if err != nil {
				return err
			}
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
	if resource == "session" && action == "panes" {
		// The arrangement is durable Host state, so the pane list comes from the
		// roster. Peer telemetry only adds which connected client is displaying
		// the Session right now.
		state, err := c.Roster(ctx)
		if err != nil {
			return err
		}
		var result api.ScreenPanesResult
		if err := c.Request(ctx, "screen.panes", map[string]any{"id": resolvedPanesID}, &result); err != nil {
			return err
		}
		return printValue(screenPaneRows(state, resolvedPanesID, result))
	}
	if action == "list" {
		state, err := c.Roster(ctx)
		if err != nil {
			return err
		}
		limit, _ := listLimit(params)
		switch resource {
		case "project":
			filtered, err := filterProjectRows(projectRows(state), params)
			if err != nil {
				return newUsageError(err.Error(), actionUsageText(commandName, action))
			}
			return printValue(limitListRows(filtered, limit))
		case "task":
			filtered, err := filterTaskRows(taskRows(state), params)
			if err != nil {
				return newUsageError(err.Error(), actionUsageText(commandName, action))
			}
			return printValue(limitListRows(filtered, limit))
		case "workspace":
			if len(positionals(params)) == 1 && stringValue(params, "project") == "" {
				params["project"] = positionals(params)[0]
			}
			filtered, err := filterWorkspaceRows(workspaceRows(state), params)
			if err != nil {
				return newUsageError(err.Error(), actionUsageText(commandName, action))
			}
			return printValue(limitListRows(filtered, limit))
		case "terminal-group":
			filtered, err := filterTerminalGroupRows(state.TerminalGroups, params)
			if err != nil {
				return newUsageError(err.Error(), actionUsageText(commandName, action))
			}
			return printValue(limitListRows(filtered, limit))
		case "pane":
			filtered, err := filterPaneGroupRows(state.PaneGroups, params)
			if err != nil {
				return newUsageError(err.Error(), actionUsageText(commandName, action))
			}
			return printValue(limitListRows(filtered, limit))
		case "session":
			if len(positionals(params)) == 1 && stringValue(params, "workspace") == "" {
				params["workspace"] = positionals(params)[0]
			}
			currentID := strings.TrimSpace(os.Getenv(agent.BindEnvSession))
			rows := sessionRowsForCurrent(state, true, false, currentID)
			filtered, err := filterSessionRows(rows, params, currentID)
			if err != nil {
				return newUsageError(err.Error(), actionUsageText(commandName, action))
			}
			return printValue(limitListRows(filtered, limit))
		case "browser":
			// A browser is a Session, so its roster already arrived with the
			// state snapshot. Asking the Host separately would race the snapshot
			// for no gain.
			rows := browserRows(state, params)
			return printValue(limitListRows(rows, limit))
		}
	}
	method := ""
	var result any
	switch resource + "." + action {
	case "task.create", "task.add":
		method = "task.create"
		result = &api.Task{}
	case "task.remove", "task.delete":
		method = "task.remove"
		result = &map[string]any{}
	case "task.rename":
		method = "task.rename"
		result = &map[string]any{}
	case "task.pin":
		method = "task.pin"
		result = &map[string]any{}
	case "task.move":
		method = "task.move"
		result = &map[string]any{}
	case "task.attach":
		method = "task.attach"
		result = &map[string]any{}
	case "task.detach":
		method = "task.detach"
		result = &map[string]any{}
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
	case "pane.create":
		method = "pane-group.create"
		result = &api.PaneGroup{}
	case "pane.rename":
		method = "pane-group.rename"
		result = &api.PaneGroup{}
	case "pane.move":
		method = "pane-group.move"
		result = &api.PaneGroup{}
	case "pane.remove", "pane.delete":
		method = "pane-group.remove"
		result = &map[string]any{}
	case "pane.split":
		return paneSplit(ctx, c, params)
	case "pane.close":
		return paneClose(ctx, c, params)
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
		_, err := subscribeTerminal(ctx, c, id)
		if err != nil {
			return err
		}
		if err := sendTerminalText(ctx, c, text, boolValue(params, "raw")); err != nil {
			return err
		}
		return printValue(map[string]any{"sent": true})
	case "session.read":
		return sessionRead(ctx, c, params, false)
	case "browser.create":
		viewport, err := browserViewportFromParams(params)
		if err != nil {
			return err
		}
		var value api.BrowserSession
		request := normalizedParams(params, resource, action)
		request["viewport"] = viewport
		if err := c.Request(ctx, "browser.session.create", request, &value); err != nil {
			return err
		}
		return printValue(value)
	case "browser.get":
		var value api.BrowserSession
		if err := c.Request(ctx, "browser.session.get", normalizedParams(params, resource, action), &value); err != nil {
			return err
		}
		return printValue(value)
	case "browser.close", "browser.remove", "browser.delete":
		var value map[string]any
		if err := c.Request(ctx, "browser.session.close", normalizedParams(params, resource, action), &value); err != nil {
			return err
		}
		return printValue(value)
	case "browser.action":
		var value api.BrowserActionResult
		request, err := browserActionParams(params)
		if err != nil {
			return err
		}
		if err := c.Request(ctx, "browser.action", request, &value); err != nil {
			return err
		}
		return printValue(value)
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

func taskWorkspaceCommand(args []string) error {
	if len(args) == 0 {
		return newUsageError("task workspace command is required", taskWorkspaceUsageText(""))
	}
	if isHelpArgument(args[0]) {
		fmt.Print(taskWorkspaceUsageText(""))
		return nil
	}
	action := args[0]
	if action != "list" && action != "attach" && action != "detach" && action != "create" {
		return newUsageError(fmt.Sprintf("unsupported command: task workspace %s", action), taskWorkspaceUsageText(""))
	}
	help, err := validateTaskWorkspaceArgs(action, args[1:])
	if err != nil {
		return newUsageError(err.Error(), taskWorkspaceUsageText(action))
	}
	if help {
		fmt.Print(taskWorkspaceUsageText(action))
		return nil
	}
	params := parseFlags(args[1:])
	expectedPositionals := 1
	if action != "list" {
		expectedPositionals = 2
	}
	positionalCount := len(positionals(params))
	if positionalCount > expectedPositionals {
		argumentLabel := "arguments"
		if expectedPositionals == 1 {
			argumentLabel = "argument"
		}
		return newUsageError(
			fmt.Sprintf("expected exactly %d positional %s, got %d", expectedPositionals, argumentLabel, positionalCount),
			taskWorkspaceUsageText(action),
		)
	}
	labels := []string{"TASK_ID"}
	if action == "attach" || action == "detach" {
		labels = append(labels, "WORKSPACE_ID")
	}
	if action == "create" {
		labels = append(labels, "PROJECT_ID")
	}
	if label := missingPositional(params, labels); label != "" {
		return newUsageError("missing "+label, taskWorkspaceUsageText(action))
	}
	if action == "create" && stringValue(params, "branch") == "" {
		return newUsageError("missing --branch BRANCH", taskWorkspaceUsageText(action))
	}
	if action == "list" {
		limit, err := listLimit(params)
		if err != nil {
			return newUsageError(err.Error(), taskWorkspaceUsageText(action))
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
		rows, err := taskWorkspaceRows(state, positional(params, 0, "task id"), boolValue(params, "available"))
		if err != nil {
			return err
		}
		return printValue(limitListRows(rows, limit))
	}

	resource, mutation, request, err := taskWorkspaceMutation(args)
	if err != nil {
		return err
	}
	ctx, c, err := connect()
	if err != nil {
		return err
	}
	defer c.Close()
	method := resource + "." + mutation
	if action == "create" {
		var result api.WorkspaceCreateResult
		if err := c.Request(ctx, method, request, &result); err != nil {
			return err
		}
		return printValue(result)
	}
	result := map[string]any{}
	if err := c.Request(ctx, method, request, &result); err != nil {
		return err
	}
	return printValue(result)
}

func validateTaskWorkspaceArgs(action string, args []string) (bool, error) {
	valueFlags := map[string]bool{}
	booleanFlags := map[string]bool{"help": true, "h": true}
	switch action {
	case "list":
		valueFlags["limit"] = true
		booleanFlags["available"] = true
		booleanFlags["all"] = true
	case "create":
		valueFlags["branch"] = true
		valueFlags["name"] = true
		valueFlags["path"] = true
	}
	help, present, err := validateStrictFlags(args, valueFlags, booleanFlags)
	if err != nil {
		return false, err
	}
	return help || present["h"], nil
}

func taskWorkspaceMutation(args []string) (string, string, map[string]any, error) {
	if len(args) == 0 {
		return "", "", nil, errors.New("task workspace command is required")
	}
	action := args[0]
	params := parseFlags(args[1:])
	positions := positionals(params)
	switch action {
	case "attach", "detach":
		if len(positions) < 2 {
			return "", "", nil, errors.New("task workspace membership requires TASK_ID and WORKSPACE_ID")
		}
		return "task", action, normalizedParams(params, "task", action), nil
	case "create":
		if len(positions) < 2 {
			return "", "", nil, errors.New("task workspace creation requires TASK_ID and PROJECT_ID")
		}
		request := normalizedParams(params, "workspace", "create")
		request["task"] = positions[0]
		request["project"] = positions[1]
		return "workspace", "create", request, nil
	default:
		return "", "", nil, fmt.Errorf("unsupported task workspace mutation: %s", action)
	}
}
