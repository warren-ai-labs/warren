package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/client"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

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
	if provider != "codex" && provider != "claude" && provider != "opencode" && provider != "pi" && provider != "qoder" && provider != "antigravity" {
		return newUsageError("--provider must be codex, claude, opencode, pi, qoder, or antigravity", agentCreateUsageText())
	}
	handler := strings.ToLower(strings.TrimSpace(stringValue(params, "agent-handler")))
	acpHandler := handler == "acp"
	if acpHandler && provider != "codex" && provider != "claude" && provider != "opencode" {
		return newUsageError("--agent-handler acp supports codex, claude, and opencode", agentCreateUsageText())
	}
	command := strings.TrimSpace(stringValue(params, "command"))
	if acpHandler {
		// The Host picks the provider's ACP server when no command is given
		// and validates an explicit one; the prompt is sent as a turn.
	} else {
		if command == "" {
			if provider == "antigravity" {
				command = "agy"
			} else {
				command = provider
			}
		}
		if err := validateAgentCommand(command, provider); err != nil {
			return newUsageError(err.Error(), agentCreateUsageText())
		}
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
	if handler := strings.TrimSpace(stringValue(params, "agent-handler")); handler != "" {
		request["agentHandler"] = handler
	}
	if hasPrompt && !acpHandler {
		// Codex and Claude accept an initial prompt as the final positional
		// argument. OpenCode exposes the same behavior through its --prompt
		// option, so keep the provider-specific launch syntax here rather than
		// silently passing a prompt that OpenCode treats as a project path.
		command = appendAgentInitialPromptForProvider(command, provider, prompt)
	}
	if command != "" {
		request["command"] = command
	}
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
	if acpHandler && hasPrompt {
		// An ACP agent has no launch-time prompt; the first prompt is a turn.
		subscription, readyErr := waitForAgentSubscription(ctx, c, session.ID, agentStartupTimeout)
		if readyErr != nil {
			return fmt.Errorf("agent %s created but its conversation was not ready: %w", session.ID, readyErr)
		}
		if _, err := c.StartAgentTurn(ctx, api.AgentTurnStartCommand{AgentCommand: api.AgentCommand{CommandID: store.NewID(), ExecutionID: subscription.Execution.ID}, Text: prompt}); err != nil {
			return fmt.Errorf("agent %s created but the prompt was not accepted: %w", session.ID, err)
		}
		if boolValue(params, "wait") {
			waitResult, err := waitAgentTurnResult(c, session.ID, subscription.Execution, executionTurn(subscription.Execution).ID, 0, waitTimeout)
			if err != nil {
				return err
			}
			result.Wait = &waitResult
		}
	} else if hasPrompt && boolValue(params, "wait") {
		subscription, readyErr := waitForAgentSubscription(ctx, c, session.ID, agentStartupTimeout)
		if readyErr != nil {
			return fmt.Errorf("agent %s created with initial prompt but transcript was not ready: %w", session.ID, readyErr)
		}
		after, current := agentWaitCursor(subscription.Execution)
		waitResult, err := waitAgentTurnResultForInitialPrompt(c, session.ID, subscription.Execution, after, current, waitTimeout)
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
	if len(positionals(params)) > 1 {
		return newUsageError("agent list accepts at most one workspace ID", agentListUsageText())
	}
	if len(positionals(params)) == 1 && stringValue(params, "workspace") == "" {
		params["workspace"] = positionals(params)[0]
	}
	if boolValue(params, "all") && boolValue(params, "ended") {
		return newUsageError("--all and --ended are mutually exclusive", agentListUsageText())
	}
	limit, err := listLimit(params)
	if err != nil {
		return newUsageError(err.Error(), agentListUsageText())
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
	currentID := strings.TrimSpace(os.Getenv(agent.BindEnvSession))
	rows := sessionRowsForCurrent(state, true, false, currentID)
	filtered := rows[:0]
	for _, row := range rows {
		if isAgentSession(row.Session) {
			filtered = append(filtered, row)
		}
	}
	filtered, err = filterSessionRows(filtered, params, currentID)
	if err != nil {
		return newUsageError(err.Error(), agentListUsageText())
	}
	return printValue(limitListRows(filtered, limit))
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
		return fmt.Errorf("current session is not a Codex, Claude, OpenCode, Pi, Qoder, or Antigravity agent: %s", session.ID)
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
	session, err := c.Subscribe(ctx, id)
	if err != nil {
		return err
	}
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex, Claude, OpenCode, Pi, Qoder, or Antigravity agent: %s", session.ID)
	}
	subscription, err := waitForAgentSubscription(ctx, c, id, agentStartupTimeout)
	if err != nil {
		return err
	}
	if boolValue(params, "wait") {
		if err := validateAgentSendWait(subscription.Execution); err != nil {
			return err
		}
	}
	if _, err := c.StartAgentTurn(ctx, api.AgentTurnStartCommand{AgentCommand: api.AgentCommand{CommandID: store.NewID(), ExecutionID: subscription.Execution.ID}, Text: text}); err != nil {
		return err
	}
	if !boolValue(params, "wait") {
		return printValue(map[string]any{"accepted": true, "agent": id})
	}
	return waitAndPrintAgentTurn(c, id, subscription.Execution, executionTurn(subscription.Execution).ID, 0, waitTimeout)
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
	if boolValue(params, "full") {
		var events []api.CanonicalAgentEvent
		var before uint64
		for {
			page, err := c.AgentEventsHistory(ctx, api.AgentEventsHistoryRequest{StreamID: subscription.Execution.StreamID, BeforeSequence: before, Limit: 500})
			if err != nil {
				return err
			}
			events = append(page.Events, events...)
			if !page.HasMore || len(page.Events) == 0 {
				break
			}
			before = page.Events[0].Sequence
		}
		return printValue(events)
	}
	session := subscription.Session
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex, Claude, OpenCode, Pi, Qoder, or Antigravity agent: %s", session.ID)
	}
	return agentReadSession(ctx, c, session, subscription.Execution.StreamID, params)
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
	session, err := subscribeTerminal(ctx, c, id)
	if err != nil {
		return err
	}
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex, Claude, OpenCode, Pi, Qoder, or Antigravity agent: %s", session.ID)
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
	// Creating a terminal returns before the CLI has necessarily completed its
	// first-run setup and written a transcript binding. Give normal startup a
	// bounded window, while still failing clearly when setup is required.
	agentStartupTimeout = 10 * time.Second
)

func isAgentSession(session api.Session) bool {
	switch strings.ToLower(strings.TrimSpace(session.Kind)) {
	case "codex", "claude", "opencode", "pi", "qoder", "antigravity":
		return true
	case "shell", "custom":
		// A shell overlay is Agent-capable only after Warren's managed hook
		// has supplied a binding. Trae has no transcript integration, so it
		// remains an ordinary PTY session until one is added.
		return session.AgentSessionID != ""
	default:
		return false
	}
}

type agentSubscription struct {
	Session   api.Session
	Execution api.AgentExecution
}

func executionTurn(execution api.AgentExecution) api.AgentTurn {
	if execution.ActiveTurn != nil {
		return *execution.ActiveTurn
	}
	return api.AgentTurn{}
}

func subscribeAgentExecution(ctx context.Context, c *client.Client, sessionID string) (agentSubscription, error) {
	var roster api.State
	if err := c.Request(ctx, "roster", nil, &roster); err != nil {
		return agentSubscription{}, err
	}
	for _, session := range roster.Sessions {
		if session.ID != sessionID {
			continue
		}
		if session.AgentExecutionID == "" {
			return agentSubscription{}, errors.New("agent is still starting")
		}
		execution, err := c.AgentExecution(ctx, session.AgentExecutionID)
		if err != nil {
			return agentSubscription{}, err
		}
		cursor, err := c.AgentContiguousThrough(execution.StreamID)
		if err != nil {
			return agentSubscription{}, err
		}
		subscription, err := c.SubscribeAgentEvents(ctx, api.AgentEventsSubscriptionRequest{StreamID: execution.StreamID, AfterSequence: cursor, Limit: 500})
		if err != nil {
			return agentSubscription{}, err
		}
		// The subscription checkpoint closes the execution.get/live race.
		if turnID, ok := subscription.Checkpoint.State["turnId"].(string); ok {
			id, err := strconv.ParseUint(turnID, 10, 64)
			if err != nil {
				return agentSubscription{}, err
			}
			status, _ := subscription.Checkpoint.State["turnStatus"].(string)
			execution.ActiveTurn = &api.AgentTurn{ID: id, Status: api.AgentTurnStatus(status)}
		}
		return agentSubscription{Session: session, Execution: execution}, nil
	}
	return agentSubscription{}, errors.New("agent session not found")
}

func waitForAgentSubscription(
	parent context.Context,
	c *client.Client,
	sessionID string,
	timeout time.Duration,
) (agentSubscription, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	var lastErr error
	for {
		subscription, err := subscribeAgentExecution(ctx, c, sessionID)
		if err == nil {
			return subscription, nil
		}
		lastErr = err
		if !retryAgentSubscription(err) {
			return agentSubscription{}, err
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) && lastErr != nil {
				return agentSubscription{}, fmt.Errorf(
					"agent is not ready after %s; finish first-time setup in Terminal and retry: %w",
					timeout,
					lastErr,
				)
			}
			return agentSubscription{}, ctx.Err()
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

// validateAgentCommand keeps the command field focused on the executable and
// its options. A positional argument is the provider's startup prompt for
// Codex and Claude (OpenCode uses --prompt), so accepting one alongside
// Warren's initial prompt would create two competing turns.
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
	// Validate provider-specific command constraints
	if provider == "qoder" {
		if err := agent.ValidateQoderCommand(command); err != nil {
			return err
		}
	}
	if provider == "antigravity" {
		if err := agent.ValidateAntigravityCommand(command); err != nil {
			return err
		}
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
			if agentCommandSessionReuseFlags[provider][flagName] {
				return fmt.Errorf("--command for %s must start a new session; session resume flags are not supported", provider)
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
	"codex":       {"--prompt": true},
	"claude":      {"--prompt": true},
	"opencode":    {"--prompt": true},
	"pi":          {},
	"qoder":       {},
	"antigravity": {"-i": true, "--prompt-interactive": true, "--prompt": true},
}

var agentCommandNonInteractiveFlags = map[string]map[string]bool{
	"claude":      {"-p": true, "--print": true},
	"opencode":    {},
	"pi":          {"-p": true, "--print": true, "--mode": true},
	"qoder":       {"-p": true, "--print": true},
	"antigravity": {"-p": true, "--print": true, "--input-format": true, "--output-format": true},
}

var agentCommandSessionReuseFlags = map[string]map[string]bool{
	"opencode":    {"--continue": true, "-c": true, "--session": true, "-s": true, "--fork": true},
	"pi":          {"--continue": true, "-c": true, "--resume": true, "-r": true, "--session": true, "--session-id": true, "--fork": true, "--no-session": true},
	"qoder":       {"--continue": true, "-c": true, "--resume": true, "-r": true, "--session": true, "--session-id": true, "--fork": true, "--fork-session": true, "--no-session": true, "--no-session-persistence": true},
	"antigravity": {"--conversation": true, "-c": true, "--continue": true},
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
	"opencode": {
		"-m": true, "--model": true, "-a": true, "--agent": true,
		"--config": true, "--cwd": true, "--port": true, "--hostname": true,
		"--log-level": true, "--file": true, "--prompt": true,
		"--replay-limit": true, "--mdns-domain": true, "--cors": true,
	},
	"pi": {
		"--provider": true, "--model": true, "--api-key": true,
		"--system-prompt": true, "--append-system-prompt": true,
		"--mode": true, "--session": true, "--session-id": true,
		"--session-dir": true, "--fork": true, "--name": true, "-n": true,
		"--models": true, "--tools": true, "-t": true, "--exclude-tools": true,
		"--thinking": true, "--extension": true, "-e": true, "--skill": true,
		"--prompt-template": true, "--theme": true, "--export": true,
		"--tui-mode": true,
	},
	"qoder": {
		"-m": true, "--model": true, "--reasoning-effort": true,
		"--thinking": true, "--thinking-budget": true,
		"--context-window": true, "--prompt-interactive": true,
		"-w": true, "--cwd": true, "--config-dir": true,
		"--permission-mode": true, "--allowed-mcp-server-names": true,
		"--tools": true, "--allowed-tools": true, "--disallowed-tools": true,
		"--attachment": true, "--plugin-dir": true, "--add-dir": true,
		"-n": true, "--name": true, "--remote": true, "--teleport": true,
		"--mcp-config": true, "--setting-sources": true, "--settings": true,
		"--output-style": true, "--max-output-tokens": true,
		"--max-model-request-retries": true, "--agent": true, "--agents": true,
		"--system-prompt": true, "--append-system-prompt": true,
		"--input-format": true, "--output-format": true,
	},
	"antigravity": {
		"--conversation": true, "--input-format": true, "--output-format": true,
		"--model": true, "--effort": true, "--mode": true, "--project": true,
		"--log-file": true, "--print-timeout": true, "--json-schema": true,
		"--agent": true, "--add-dir": true,
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

func appendAgentInitialPromptForProvider(command, provider, prompt string) string {
	command = strings.TrimSpace(command)
	if strings.EqualFold(strings.TrimSpace(provider), "opencode") {
		return command + " --prompt " + shellQuote(prompt)
	}
	if strings.EqualFold(strings.TrimSpace(provider), "antigravity") {
		return command + " -i " + shellQuote(prompt)
	}
	return appendAgentInitialPrompt(command, prompt)
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
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
	session, err := c.Subscribe(ctx, positions[0])
	if err != nil {
		return err
	}
	if !isAgentSession(session) {
		return fmt.Errorf("session is not a Codex, Claude, OpenCode, Pi, Qoder, or Antigravity agent: %s", session.ID)
	}
	subscription, err := waitForAgentSubscription(ctx, c, positions[0], agentStartupTimeout)
	if err != nil {
		return err
	}
	snapshot := subscription.Execution
	after, current := agentWaitCursor(snapshot)
	return waitAndPrintAgentTurn(c, session.ID, snapshot, after, current, timeout)
}

func agentWaitCursor(snapshot api.AgentExecution) (after, current uint64) {
	after = executionTurn(snapshot).ID
	if executionTurn(snapshot).Status == api.AgentTurnStarted {
		return after, executionTurn(snapshot).ID
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

func validateAgentSendWait(snapshot api.AgentExecution) error {
	if executionTurn(snapshot).Status == api.AgentTurnStarted {
		return errors.New("agent already has a running turn; wait for it before using agent send --wait")
	}
	return nil
}

func waitAndPrintAgentTurn(
	c *client.Client,
	sessionID string,
	snapshot api.AgentExecution,
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
	snapshot api.AgentExecution,
	after uint64,
	current uint64,
	timeout time.Duration,
) (api.AgentWaitResult, error) {
	return waitAgentTurnResultMode(c, sessionID, snapshot, after, current, timeout, false)
}

func waitAgentTurnResultForInitialPrompt(
	c *client.Client,
	sessionID string,
	snapshot api.AgentExecution,
	after uint64,
	current uint64,
	timeout time.Duration,
) (api.AgentWaitResult, error) {
	return waitAgentTurnResultMode(c, sessionID, snapshot, after, current, timeout, true)
}

func waitAgentTurnResultMode(
	c *client.Client,
	sessionID string,
	snapshot api.AgentExecution,
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
	if acceptCompletedSnapshot && current == 0 && executionTurn(snapshot).ID > after && terminalAgentTurnStatus(executionTurn(snapshot).Status) {
		return completedAgentTurnResult(c, sessionID, snapshot)
	}
	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	waitContext, cancel := context.WithTimeout(signalContext, timeout)
	defer cancel()
	turn, err := c.WaitAgentTurn(waitContext, sessionID, snapshot.StreamID, after, current)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return api.AgentWaitResult{}, fmt.Errorf("agent turn did not complete before timeout %s", timeout)
		}
		return api.AgentWaitResult{}, err
	}
	fetchContext, fetchCancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer fetchCancel()
	events, err := readCanonicalTurn(fetchContext, c, snapshot.StreamID, turn.ID)
	if err != nil {
		return api.AgentWaitResult{}, fmt.Errorf("read completed agent turn %d: %w", turn.ID, err)
	}
	return api.AgentWaitResult{
		Session:     sessionID,
		ExecutionID: snapshot.ID,
		Turn:        turn.ID,
		Status:      turn.Status,
		Events:      events,
	}, nil
}

func terminalAgentTurnStatus(status api.AgentTurnStatus) bool {
	switch status {
	case api.AgentTurnCompleted, api.AgentTurnFailed, api.AgentTurnInterrupted, api.AgentTurnCancelled, api.AgentTurnAborted:
		return true
	default:
		return false
	}
}

func completedAgentTurnResult(
	c *client.Client,
	sessionID string,
	snapshot api.AgentExecution,
) (api.AgentWaitResult, error) {
	fetchContext, fetchCancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer fetchCancel()
	events, err := readCanonicalTurn(fetchContext, c, snapshot.StreamID, executionTurn(snapshot).ID)
	if err != nil {
		return api.AgentWaitResult{}, fmt.Errorf("read completed agent turn %d: %w", executionTurn(snapshot).ID, err)
	}
	return api.AgentWaitResult{
		Session:     sessionID,
		ExecutionID: snapshot.ID,
		Turn:        executionTurn(snapshot).ID,
		Status:      executionTurn(snapshot).Status,
		Events:      events,
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
	"tools": true, "tool-output": true,
	"current": true, "help": true,
}

var agentCreateValueFlags = map[string]bool{
	"provider": true, "agent-handler": true, "command": true, "prompt": true, "title": true,
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
	if present["full"] {
		for _, name := range []string{
			"recent", "limit", "count", "all", "include", "filter", "exclude",
			"chars", "max-chars", "head", "full-content", "no-truncate",
			"text", "text-only", "plain", "tools", "tool-output",
		} {
			if present[name] {
				return false, fmt.Errorf("--full cannot be combined with --%s", name)
			}
		}
	}
	if (present["full-content"] || present["no-truncate"]) && contentFlag {
		return false, errors.New("--full-content and --no-truncate cannot be combined with --chars, --max-chars, or --head")
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
