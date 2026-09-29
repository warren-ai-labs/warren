package server

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/acp"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// acpStreamFlushInterval bounds how often one streamed message becomes a
	// journal row (RFC 0023 §5.6).
	acpStreamFlushInterval = 120 * time.Millisecond
	acpInitializeTimeout   = 30 * time.Second
	acpSessionSetupTimeout = 60 * time.Second
	// acpSteerWait bounds how long a steer waits for the cancelled prompt to
	// return before sending its replacement.
	acpSteerWait = 10 * time.Second
	// acpToolTextLimit bounds tool output and inputs copied into events.
	acpToolTextLimit = 16 * 1024
	// acpDiffLineLimit bounds the line diff computed for a tool diff; larger
	// edits are reported as whole-file replacements.
	acpDiffLineLimit = 4000
	// acpImageAttachmentLimit bounds an image sent inline in a prompt.
	acpImageAttachmentLimit = 8 << 20
)

// ACPAgentProvider drives a provider family over the Agent Client Protocol
// (RFC 0023). It serves only Sessions created with the acp handler.
type ACPAgentProvider struct {
	kind    string
	service *Service
}

func NewACPAgentProvider(kind string, service *Service) *ACPAgentProvider {
	return &ACPAgentProvider{kind: normalizeProviderKind(kind), service: service}
}

func (provider *ACPAgentProvider) Kind() string {
	if provider == nil {
		return ""
	}
	return provider.kind
}

func (provider *ACPAgentProvider) HandlerKind() string { return AgentHandlerACP }

// Capabilities advertises what an ACP Session can execute natively.
func (provider *ACPAgentProvider) Capabilities() CapabilitySet {
	if provider == nil || !ACPProviderAvailable(provider.kind) {
		return NewCapabilitySet()
	}
	return NewCapabilitySet(CapabilityTimeline, CapabilityInteractions, CapabilityInterrupt, CapabilityAttachments, CapabilityConfig)
}

// Ensure returns a handle without starting a process; the process starts on
// Start for a new conversation, or lazily on the next prompt (RFC 0023 §5.5).
func (provider *ACPAgentProvider) Ensure(ctx context.Context, value AgentSessionContext) (AgentHandle, error) {
	if provider == nil || provider.service == nil {
		return nil, ErrAgentNotReady
	}
	if !isACPSession(value.Session) {
		return nil, fmt.Errorf("session %s was not created with the acp handler", value.SessionID)
	}
	if !ACPProviderAvailable(provider.kind) {
		return nil, fmt.Errorf("acp is not available for provider %s", provider.kind)
	}
	if provider.service.acpHandoffActive(value.SessionID) {
		return nil, errors.New("this Session is moving to a terminal")
	}
	return &acpAgentHandle{
		service:      provider.service,
		sessionID:    value.SessionID,
		provider:     provider.kind,
		command:      strings.TrimSpace(value.Session.Command),
		cwd:          value.WorkspacePath,
		acpSessionID: strings.TrimSpace(value.Session.AgentSessionID),
		permissions:  make(map[string]*acpPermission),
		tools:        make(map[string]*acpToolState),
		streamIDs:    make(map[string]int),
		terminals:    make(map[string]*acpTerminal),
	}, nil
}

// acpPermission is one open session/request_permission.
type acpPermission struct {
	request   *acp.Request
	optionIDs map[string]struct{}
}

// acpToolState is the merged view of one tool call's updates.
type acpToolState struct {
	title  string
	kind   string
	status string
	detail string
	files  []string
	input  any
	output string
	diff   map[string]any
	// terminalID names the agent terminal whose output is this tool's.
	terminalID string
	emitted    string
}

// acpStream buffers one streamed message or reasoning block.
type acpStream struct {
	kind    string // "assistant" or "reasoning"
	id      string
	pending strings.Builder
	full    strings.Builder
	created bool
}

type acpAgentHandle struct {
	service   *Service
	sessionID string
	provider  string
	command   string
	cwd       string

	// emitMu serializes everything the handle reports, so observations reach
	// the journal in the order the agent produced them.
	emitMu sync.Mutex

	mu      sync.Mutex
	sink    AgentEventSink
	started bool
	closed  bool
	// detaching marks a Host shutdown that leaves the agent running: the
	// connection ends, but the turn and the agent are not over.
	detaching bool
	proc      *acp.Held
	conn      *acp.Conn
	// holdID names the agent's holder; interaction ids derive from it so an
	// agent request delivered again after a Host restart keeps its id.
	holdID string
	// streamEpoch keeps message ids of a turn adopted after a Host restart
	// apart from the ids its first half was journaled under.
	streamEpoch  string
	initResult   acp.InitializeResponse
	acpSessionID string
	connecting   chan struct{}
	loading      bool
	sequence     uint64

	turn          uint64
	promptActive  bool
	promptDone    chan struct{}
	promptCancel  context.CancelFunc
	turnUsage     *api.AgentUsage
	lastAssistant *acpStream

	permissions map[string]*acpPermission
	tools       map[string]*acpToolState
	stream      *acpStream
	streamIDs   map[string]int
	segment     int
	flushTimer  *time.Timer

	// config is the agent's current selector snapshot; configEmitted is the
	// last journaled form, so an unchanged snapshot is not journaled again.
	config        []acpConfigOption
	configEmitted string

	// terminals are the commands the agent runs through terminal/create.
	terminals map[string]*acpTerminal
}

func (handle *acpAgentHandle) BindingKey() string {
	if handle == nil {
		return ""
	}
	return "acp|" + handle.sessionID
}

// BindingMetadata keeps the persisted ACP conversation ID in place when the
// Service records binding metadata after Start.
func (handle *acpAgentHandle) BindingMetadata() (string, string) {
	handle.mu.Lock()
	defer handle.mu.Unlock()
	return handle.acpSessionID, ""
}

// correlatesOwnMessages tells sendAgentMessage that this handle records the
// command correlation itself, before it emits the user message. ACP agents do
// not echo a live prompt, so the handle is the only source of that row.
func (handle *acpAgentHandle) correlatesOwnMessages() bool { return true }

func (handle *acpAgentHandle) Capabilities() CapabilitySet {
	return NewCapabilitySet(CapabilityTimeline, CapabilityInteractions, CapabilityInterrupt, CapabilityAttachments, CapabilityConfig)
}

func (handle *acpAgentHandle) Start(ctx context.Context, sink AgentEventSink) error {
	handle.mu.Lock()
	if handle.closed {
		handle.mu.Unlock()
		return errors.New("agent handle is closed")
	}
	if handle.started {
		handle.mu.Unlock()
		return nil
	}
	handle.started = true
	handle.sink = sink
	fresh := handle.acpSessionID == ""
	handle.mu.Unlock()

	// Restore the journaled projection before reading it, so turn numbers
	// continue after a Host restart instead of starting over.
	handle.service.canonicalExecutionForSession(handle.sessionID)
	turn := handle.service.agentTurn(handle.sessionID)
	adopted := false
	if !fresh {
		// The agent outlives the Host in its holder; take it back, and with
		// it the prompt it is still answering.
		adopted = handle.reattach(ctx, turn)
	}
	switch activity := handle.service.agentStatus(handle.sessionID).Activity; {
	case adopted:
		// reattach reported the turn as running.
	case turn.ID > 0 && turn.Status == api.AgentTurnStarted:
		// The prompt did not survive: the agent exited while the Host was
		// away, or its answer was lost with a crashed Host. Report that
		// instead of leaving the turn open forever.
		handle.emitMu.Lock()
		handle.emitEvents([]api.AgentEvent{handle.errorEvent(turn.ID, "Warren restarted while this turn was running.")}, api.AgentStatus{Activity: api.AgentActivityReady})
		emitAgentTurns(sink, []api.AgentTurn{{ID: turn.ID, Status: api.AgentTurnFailed}}, false)
		handle.emitMu.Unlock()
	case activity == "" || activity == api.AgentActivityWorking || activity == api.AgentActivityBlocked:
		// No turn is running, so a working or blocked status is one the
		// previous Host did not get to clear.
		emitAgentStatus(sink, api.AgentStatus{Activity: api.AgentActivityReady})
	}
	if fresh {
		// A new conversation connects right away so setup errors (a missing
		// login, a broken adapter) appear before the first prompt.
		go func() {
			connectContext, cancel := context.WithTimeout(context.Background(), acpInitializeTimeout+acpSessionSetupTimeout)
			defer cancel()
			if _, _, err := handle.ensureConnected(connectContext); err != nil && !handle.isClosed() {
				handle.emitMu.Lock()
				handle.emitEvents([]api.AgentEvent{handle.errorEvent(0, handle.describeConnectError(err))}, api.AgentStatus{Activity: api.AgentActivityFailed})
				handle.emitMu.Unlock()
			}
		}()
	}
	return nil
}

func (handle *acpAgentHandle) isClosed() bool {
	handle.mu.Lock()
	defer handle.mu.Unlock()
	return handle.closed
}

func (handle *acpAgentHandle) Close() error {
	handle.mu.Lock()
	proc := handle.shutdownLocked()
	handle.mu.Unlock()
	if proc != nil {
		// Sent now, so no Host attaches to the agent while it ends.
		proc.Terminate()
		go proc.Close()
	}
	return nil
}

// Detach ends the handle for a Host shutdown and leaves the agent running in
// its holder, so the next Host attaches to it instead of starting it again.
// What the agent sent before the holder stopped forwarding is journaled
// first.
func (handle *acpAgentHandle) Detach() error {
	handle.mu.Lock()
	proc := handle.proc
	handle.detaching = true
	handle.mu.Unlock()
	if proc != nil {
		proc.Detach()
	}
	handle.mu.Lock()
	handle.shutdownLocked()
	handle.mu.Unlock()
	return nil
}

// shutdownLocked marks the handle closed and ends its connection. It returns
// the process for the caller to stop, or nil when there is none.
func (handle *acpAgentHandle) shutdownLocked() *acp.Held {
	if handle.closed {
		return nil
	}
	handle.closed = true
	proc, conn := handle.proc, handle.conn
	handle.proc, handle.conn = nil, nil
	cancel := handle.promptCancel
	if handle.flushTimer != nil {
		handle.flushTimer.Stop()
		handle.flushTimer = nil
	}
	if cancel != nil {
		cancel()
	}
	if conn != nil {
		conn.Close()
	}
	if terminals := handle.takeTerminalsLocked(); len(terminals) > 0 {
		go handle.releaseTerminals(terminals)
	}
	return proc
}

// ensureConnected starts the agent and binds its conversation, once. Callers
// that arrive while a connection is being made wait for it.
func (handle *acpAgentHandle) ensureConnected(ctx context.Context) (*acp.Conn, string, error) {
	for {
		handle.mu.Lock()
		if handle.closed {
			handle.mu.Unlock()
			return nil, "", errors.New("agent handle is closed")
		}
		if handle.conn != nil && handle.acpSessionID != "" && handle.connecting == nil {
			conn, id := handle.conn, handle.acpSessionID
			handle.mu.Unlock()
			return conn, id, nil
		}
		if waiting := handle.connecting; waiting != nil {
			handle.mu.Unlock()
			select {
			case <-waiting:
				continue
			case <-ctx.Done():
				return nil, "", ctx.Err()
			}
		}
		done := make(chan struct{})
		handle.connecting = done
		handle.mu.Unlock()
		err := handle.connect(ctx)
		handle.mu.Lock()
		handle.connecting = nil
		conn, id := handle.conn, handle.acpSessionID
		handle.mu.Unlock()
		close(done)
		if err != nil {
			return nil, "", err
		}
		if conn == nil {
			// Closed, or the agent exited, while the connection was made.
			return nil, "", errors.New("agent handle is closed")
		}
		return conn, id, nil
	}
}

func (handle *acpAgentHandle) launchOptions() (acp.LaunchOptions, error) {
	env, err := handle.service.acpEnvironment()
	if err != nil {
		return acp.LaunchOptions{}, err
	}
	shell, args, fallback := handle.service.acpShell()
	options := acp.LaunchOptions{Shell: shell, ShellArgs: args, FallbackShellArgs: fallback, Command: handle.command, Dir: handle.cwd, Env: env}
	if shell == "" {
		options.Argv = strings.Fields(handle.command)
	}
	return options, nil
}

func (handle *acpAgentHandle) connect(ctx context.Context) error {
	options, err := handle.launchOptions()
	if err != nil {
		return err
	}
	proc, err := handle.service.startACPHold(ctx, handle.sessionID, options)
	if err != nil {
		return err
	}
	conn := acp.NewConn(proc.Stdout(), proc.Stdin(), handle)
	handle.mu.Lock()
	if handle.closed {
		handle.mu.Unlock()
		conn.Close()
		proc.Close()
		return errors.New("agent handle is closed")
	}
	handle.proc, handle.conn = proc, conn
	handle.holdID = proc.Info().ID
	persisted := handle.acpSessionID
	handle.mu.Unlock()
	go handle.watchExit(proc, conn)

	fail := func(err error) error {
		handle.mu.Lock()
		if handle.conn == conn {
			handle.conn, handle.proc = nil, nil
		}
		handle.mu.Unlock()
		conn.Close()
		proc.Close()
		if errors.Is(err, acp.ErrClosed) || isEOF(err) {
			return fmt.Errorf("agent exited during startup: %s", proc.DescribeExit())
		}
		return err
	}

	initContext, cancelInit := context.WithTimeout(ctx, acpInitializeTimeout)
	var initResult acp.InitializeResponse
	err = conn.Call(initContext, acp.MethodInitialize, acp.InitializeRequest{
		ProtocolVersion:    acp.ProtocolVersion,
		ClientCapabilities: acp.ClientCapabilities{Terminal: handle.service.processRuntime() != nil},
		ClientInfo:         &acp.Implementation{Name: "warren", Title: "Warren", Version: api.Version},
	}, &initResult)
	cancelInit()
	if err != nil {
		return fail(fmt.Errorf("initialize: %w", err))
	}
	if initResult.ProtocolVersion != acp.ProtocolVersion {
		return fail(fmt.Errorf("agent speaks ACP version %d; Warren supports version %d", initResult.ProtocolVersion, acp.ProtocolVersion))
	}
	handle.mu.Lock()
	handle.initResult = initResult
	handle.saveHeldStateLocked()
	handle.mu.Unlock()

	setupContext, cancelSetup := context.WithTimeout(ctx, acpSessionSetupTimeout)
	defer cancelSetup()
	if persisted != "" {
		resumed, resumeErr := handle.resume(setupContext, conn, initResult, persisted)
		if resumeErr == nil {
			handle.mu.Lock()
			handle.acpSessionID = persisted
			handle.mu.Unlock()
			handle.reportConfig(resumed.ConfigOptions, resumed.Modes)
			return nil
		}
		if errors.Is(resumeErr, acp.ErrClosed) || isEOF(resumeErr) {
			return fail(resumeErr)
		}
		handle.service.logWarn("acp resume failed; starting a new conversation", "session", handle.sessionID, "error", resumeErr)
		var created acp.NewSessionResponse
		if err := conn.Call(setupContext, acp.MethodSessionNew, acp.NewSessionRequest{CWD: handle.cwd, MCPServers: []any{}}, &created); err != nil {
			return fail(handle.setupError("session/new", err))
		}
		// The previous provider conversation is gone, so this is a new
		// execution. Say so in the new stream rather than splicing silently.
		handle.service.rotateACPExecution(handle.sessionID, handle)
		handle.mu.Lock()
		handle.acpSessionID = created.SessionID
		handle.resetConversationLocked()
		handle.mu.Unlock()
		handle.service.persistACPSessionID(handle.sessionID, created.SessionID)
		handle.emitMu.Lock()
		handle.emitEvents([]api.AgentEvent{handle.noticeEvent(0, "The previous conversation could not be resumed, so this is a new conversation.")}, api.AgentStatus{Activity: api.AgentActivityReady})
		handle.emitMu.Unlock()
		handle.reportConfig(created.ConfigOptions, created.Modes)
		return nil
	}
	var created acp.NewSessionResponse
	if err := conn.Call(setupContext, acp.MethodSessionNew, acp.NewSessionRequest{CWD: handle.cwd, MCPServers: []any{}}, &created); err != nil {
		return fail(handle.setupError("session/new", err))
	}
	if strings.TrimSpace(created.SessionID) == "" {
		return fail(errors.New("session/new returned no sessionId"))
	}
	handle.mu.Lock()
	handle.acpSessionID = created.SessionID
	handle.mu.Unlock()
	handle.service.persistACPSessionID(handle.sessionID, created.SessionID)
	handle.reportConfig(created.ConfigOptions, created.Modes)
	return nil
}

// resume reattaches a persisted conversation: session/resume when offered,
// otherwise session/load with its replay suppressed, because the journal
// already holds that history.
func (handle *acpAgentHandle) resume(ctx context.Context, conn *acp.Conn, initResult acp.InitializeResponse, id string) (acp.LoadSessionResponse, error) {
	request := acp.LoadSessionRequest{SessionID: id, CWD: handle.cwd, MCPServers: []any{}}
	var response acp.LoadSessionResponse
	if initResult.CanResume() {
		err := conn.Call(ctx, acp.MethodSessionResume, request, &response)
		return response, err
	}
	if !initResult.AgentCapabilities.LoadSession {
		return response, errors.New("agent can neither resume nor load a conversation")
	}
	handle.mu.Lock()
	handle.loading = true
	handle.mu.Unlock()
	err := conn.Call(ctx, acp.MethodSessionLoad, request, &response)
	handle.mu.Lock()
	handle.loading = false
	handle.mu.Unlock()
	return response, err
}

func (handle *acpAgentHandle) setupError(method string, err error) error {
	if acp.IsAuthRequired(err) {
		return &acpAuthError{hint: handle.authHint()}
	}
	return fmt.Errorf("%s: %w", method, err)
}

type acpAuthError struct{ hint string }

func (err *acpAuthError) Error() string { return "authentication required: " + err.hint }

func (handle *acpAgentHandle) authHint() string {
	handle.mu.Lock()
	methods := handle.initResult.AuthMethods
	handle.mu.Unlock()
	for _, method := range methods {
		if description := strings.TrimSpace(method.Description); description != "" {
			return description
		}
	}
	for _, method := range methods {
		if name := strings.TrimSpace(method.Name); name != "" {
			return name
		}
	}
	return "log in with the provider's CLI in a terminal on this Host"
}

func (handle *acpAgentHandle) describeConnectError(err error) string {
	var authErr *acpAuthError
	if errors.As(err, &authErr) {
		return fmt.Sprintf("%s needs you to sign in. %s, then send your message again.", providerDisplayName(handle.provider), strings.TrimSuffix(authErr.hint, "."))
	}
	return fmt.Sprintf("%s could not start: %s", providerDisplayName(handle.provider), clipACPText(err.Error(), 2048))
}

func providerDisplayName(kind string) string {
	switch kind {
	case "claude":
		return "Claude Code"
	case "codex":
		return "Codex"
	case "opencode":
		return "OpenCode"
	default:
		return kind
	}
}

func isEOF(err error) bool {
	return err != nil && strings.Contains(err.Error(), "EOF")
}

// watchExit clears a dead connection so the next prompt starts a new process.
// A running prompt learns about the exit from its own failed call.
func (handle *acpAgentHandle) watchExit(proc *acp.Held, conn *acp.Conn) {
	select {
	case <-proc.Exited():
	case <-conn.Done():
	}
	conn.Close()
	handle.mu.Lock()
	current := handle.conn == conn && !handle.detaching
	var terminals []*acpTerminal
	if current {
		handle.conn, handle.proc = nil, nil
		// A terminal belongs to the agent that created it.
		terminals = handle.takeTerminalsLocked()
	}
	closed := handle.closed
	handle.mu.Unlock()
	if len(terminals) > 0 {
		go handle.releaseTerminals(terminals)
	}
	if current && !closed {
		proc.Close()
		handle.service.logWarn("acp agent exited", "session", handle.sessionID, "detail", proc.DescribeExit())
	}
}

// resetConversationLocked drops per-conversation state after a new
// conversation replaces the old one.
func (handle *acpAgentHandle) resetConversationLocked() {
	handle.turn = 0
	handle.tools = make(map[string]*acpToolState)
	handle.streamIDs = make(map[string]int)
	handle.stream = nil
	handle.segment = 0
}

// ---------------------------------------------------------------------------
// Commands

func (handle *acpAgentHandle) SendMessage(ctx context.Context, message api.AgentMessageSendRequest) error {
	return handle.startTurn(message)
}

// startTurn admits a prompt and runs it in the background. The user's message
// and the turn boundary are reported before the agent is reached, so the
// prompt appears immediately even when the agent still has to start.
func (handle *acpAgentHandle) startTurn(message api.AgentMessageSendRequest) error {
	blocks, displayText, err := handle.promptBlocks(message)
	if err != nil {
		return err
	}
	handle.emitMu.Lock()
	handle.mu.Lock()
	if handle.closed {
		handle.mu.Unlock()
		handle.emitMu.Unlock()
		return errors.New("agent handle is closed")
	}
	if handle.promptActive {
		handle.mu.Unlock()
		handle.emitMu.Unlock()
		return api.ErrAgentBusy
	}
	current := handle.service.agentTurn(handle.sessionID).ID
	if handle.turn < current {
		handle.turn = current
	}
	handle.turn++
	turn := handle.turn
	handle.promptActive = true
	handle.promptDone = make(chan struct{})
	promptContext, cancel := context.WithCancel(context.Background())
	handle.promptCancel = cancel
	handle.turnUsage = nil
	handle.lastAssistant = nil
	handle.segment = 0
	handle.streamEpoch = ""
	handle.mu.Unlock()

	if strings.TrimSpace(message.ClientMessageID) != "" {
		handle.service.recordAgentMessageCorrelation(handle.sessionID, message.ClientMessageID, displayText)
	}
	userEvent := api.AgentEvent{
		ID:        "acp-user-" + randomACPID(),
		Type:      "user",
		Role:      "user",
		Content:   displayText,
		Turn:      turn,
		Timestamp: time.Now().UTC(),
	}
	if len(message.Attachments) > 0 {
		names := make([]any, 0, len(message.Attachments))
		for _, attachment := range message.Attachments {
			names = append(names, map[string]any{"name": attachment.Name, "mime": attachment.MIME, "size": attachment.Size})
		}
		userEvent.Payload = map[string]any{"attachments": names}
	}
	handle.emitEvents([]api.AgentEvent{userEvent}, api.AgentStatus{Activity: api.AgentActivityWorking})
	handle.emitTurns(api.AgentTurn{ID: turn, Status: api.AgentTurnStarted})
	handle.emitMu.Unlock()

	go handle.runPrompt(promptContext, turn, blocks)
	return nil
}

func (handle *acpAgentHandle) runPrompt(ctx context.Context, turn uint64, blocks []acp.ContentBlock) {
	var response acp.PromptResponse
	conn, acpSessionID, err := handle.ensureConnected(ctx)
	if err == nil {
		err = conn.Call(ctx, acp.MethodSessionPrompt, acp.PromptRequest{SessionID: acpSessionID, Prompt: blocks}, &response)
	}
	handle.finishTurn(turn, response, err)
}

func (handle *acpAgentHandle) finishTurn(turn uint64, response acp.PromptResponse, callErr error) {
	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	// A detaching Host leaves the turn running in the agent; the next Host
	// finishes it.
	closed := handle.closed || handle.detaching
	events := handle.finishStreamLocked()
	if response.Usage != nil {
		handle.turnUsage = &api.AgentUsage{
			InputTokens:              response.Usage.InputTokens,
			OutputTokens:             response.Usage.OutputTokens,
			CacheReadInputTokens:     response.Usage.CachedReadTokens,
			CacheCreationInputTokens: response.Usage.CachedWriteTokens,
			ReasoningOutputTokens:    response.Usage.ThoughtTokens,
			TotalTokens:              response.Usage.TotalTokens,
			CallKey:                  fmt.Sprintf("acp:%s:%d", handle.acpSessionID, turn),
		}
	}
	events = append(events, handle.completedAssistantLocked()...)
	pending := handle.permissions
	handle.permissions = make(map[string]*acpPermission)
	handle.promptActive = false
	done := handle.promptDone
	handle.promptDone = nil
	handle.promptCancel = nil
	proc := handle.proc
	handle.mu.Unlock()
	if closed {
		if done != nil {
			close(done)
		}
		return
	}
	for id, permission := range pending {
		_ = permission.request.Reply(acp.Cancelled())
		handle.service.recordAgentInteractionTerminal(api.AgentInteractionResponse{
			Session: handle.sessionID, RequestID: id, Kind: "permission",
			Response: map[string]any{"cancelled": true},
		}, "expired")
	}
	status := api.AgentStatus{Activity: api.AgentActivityReady}
	turnStatus := api.AgentTurnCompleted
	switch {
	case callErr != nil:
		status.Activity = api.AgentActivityFailed
		turnStatus = api.AgentTurnFailed
		detail := callErr.Error()
		if errors.Is(callErr, acp.ErrClosed) || isEOF(callErr) {
			detail = "the agent exited"
			if proc != nil {
				detail += ": " + proc.DescribeExit()
			}
		} else if errors.Is(callErr, context.Canceled) {
			detail = "the turn was abandoned"
		} else {
			var authErr *acpAuthError
			if errors.As(callErr, &authErr) || !strings.HasPrefix(detail, "acp error") {
				detail = handle.describeConnectError(callErr)
				events = append(events, handle.errorEvent(turn, detail))
				break
			}
		}
		events = append(events, handle.errorEvent(turn, clipACPText(strings.TrimPrefix(detail, "acp error "), 2048)))
	case response.StopReason == acp.StopCancelled:
		turnStatus = api.AgentTurnInterrupted
	case response.StopReason == acp.StopRefusal:
		status.Activity = api.AgentActivityFailed
		turnStatus = api.AgentTurnFailed
		events = append(events, handle.errorEvent(turn, "The agent refused to continue this turn."))
	case response.StopReason == acp.StopMaxTokens:
		events = append(events, handle.noticeEvent(turn, "The agent stopped at its output token limit."))
	case response.StopReason == acp.StopMaxTurnRequests:
		events = append(events, handle.noticeEvent(turn, "The agent stopped at its request limit for one turn."))
	}
	// The turn's last text and any error precede its boundary, and the
	// boundary precedes the status that follows it.
	handle.emitEvents(events, api.AgentStatus{})
	handle.emitTurns(api.AgentTurn{ID: turn, Status: turnStatus})
	emitAgentStatus(handle.currentSink(), status)
	if done != nil {
		close(done)
	}
}

func (handle *acpAgentHandle) Interrupt(ctx context.Context, request api.AgentTurnInterruptRequest) error {
	handle.mu.Lock()
	active := handle.promptActive
	turn := handle.turn
	done := handle.promptDone
	conn := handle.conn
	acpSessionID := handle.acpSessionID
	handle.mu.Unlock()
	if !active || (request.Turn != 0 && request.Turn != turn) {
		return fmt.Errorf("turn %d is not active", request.Turn)
	}
	handle.cancelPendingPermissions()
	if conn != nil && acpSessionID != "" {
		if err := conn.Notify(acp.MethodSessionCancel, acp.CancelNotification{SessionID: acpSessionID}); err != nil {
			return err
		}
	} else {
		// The agent is still starting; abandon the prompt instead.
		handle.mu.Lock()
		cancel := handle.promptCancel
		handle.mu.Unlock()
		if cancel != nil {
			cancel()
		}
	}
	if request.Replacement == nil {
		return nil
	}
	replacement := *request.Replacement
	go func() {
		if done != nil {
			select {
			case <-done:
			case <-time.After(acpSteerWait):
				handle.service.logWarn("acp steer: cancelled prompt did not return", "session", handle.sessionID)
				return
			}
		}
		if err := handle.startTurn(replacement); err != nil {
			handle.service.logWarn("acp steer replacement failed", "session", handle.sessionID, "error", err)
		}
	}()
	return nil
}

// cancelPendingPermissions answers every open permission request with the
// cancelled outcome, as ACP requires before session/cancel.
func (handle *acpAgentHandle) cancelPendingPermissions() {
	handle.mu.Lock()
	pending := handle.permissions
	handle.permissions = make(map[string]*acpPermission)
	handle.mu.Unlock()
	for id, permission := range pending {
		_ = permission.request.Reply(acp.Cancelled())
		handle.service.recordAgentInteractionTerminal(api.AgentInteractionResponse{
			Session: handle.sessionID, RequestID: id, Kind: "permission",
			Response: map[string]any{"cancelled": true},
		}, "expired")
	}
}

func (handle *acpAgentHandle) RespondInteraction(ctx context.Context, response api.AgentInteractionResponse) error {
	id := strings.TrimSpace(response.RequestID)
	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	permission := handle.permissions[id]
	if permission == nil {
		handle.mu.Unlock()
		return fmt.Errorf("interaction %s is not pending", id)
	}
	var reply acp.RequestPermissionResponse
	if cancelled, _ := response.Response["cancelled"].(bool); cancelled {
		reply = acp.Cancelled()
	} else {
		choice := strings.TrimSpace(agentStringValue(response.Response["decision"]))
		if choice == "" {
			choice = strings.TrimSpace(agentStringValue(response.Response["value"]))
		}
		if _, ok := permission.optionIDs[choice]; !ok {
			handle.mu.Unlock()
			return fmt.Errorf("interaction %s has no option %q", id, choice)
		}
		reply = acp.Selected(choice)
	}
	delete(handle.permissions, id)
	remaining := len(handle.permissions)
	handle.mu.Unlock()
	if err := permission.request.Reply(reply); err != nil {
		return err
	}
	if remaining == 0 {
		emitAgentStatus(handle.currentSink(), api.AgentStatus{Activity: api.AgentActivityWorking})
	}
	return nil
}

// ---------------------------------------------------------------------------
// Inbound traffic (acp.Handler)

func (handle *acpAgentHandle) HandleNotification(method string, params json.RawMessage) {
	if method != acp.MethodSessionUpdate {
		return
	}
	var notification acp.SessionNotification
	if json.Unmarshal(params, &notification) != nil {
		return
	}
	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	if handle.closed || handle.loading || (handle.acpSessionID != "" && notification.SessionID != handle.acpSessionID) {
		handle.mu.Unlock()
		return
	}
	events := handle.applyUpdateLocked(notification.Update)
	handle.mu.Unlock()
	if len(events) > 0 {
		handle.emitEvents(events, api.AgentStatus{})
	}
}

func (handle *acpAgentHandle) HandleRequest(request *acp.Request) {
	switch request.Method {
	case acp.MethodRequestPermission:
	case acp.MethodTerminalCreate, acp.MethodTerminalOutput, acp.MethodTerminalWaitForExit, acp.MethodTerminalKill, acp.MethodTerminalRelease:
		handle.handleTerminalRequest(request)
		return
	default:
		// Warren advertises no fs client capability (RFC 0023 §6.6).
		_ = request.ReplyError(acp.CodeMethodNotFound, "method not supported by Warren: "+request.Method)
		return
	}
	var params acp.RequestPermissionRequest
	if err := json.Unmarshal(request.Params, &params); err != nil || len(params.Options) == 0 {
		_ = request.ReplyError(acp.CodeInvalidParams, "invalid permission request")
		return
	}
	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	if handle.closed || !handle.promptActive {
		handle.mu.Unlock()
		_ = request.Reply(acp.Cancelled())
		return
	}
	events := handle.flushStreamLocked()
	id := handle.interactionIDLocked(request.ID)
	optionIDs := make(map[string]struct{}, len(params.Options))
	options := make([]any, 0, len(params.Options))
	for _, option := range orderedPermissionOptions(params.Options) {
		optionIDs[option.OptionID] = struct{}{}
		options = append(options, map[string]any{"id": option.OptionID, "label": option.Name, "kind": option.Kind})
	}
	handle.permissions[id] = &acpPermission{request: request, optionIDs: optionIDs}
	tool := handle.mergeToolLocked(params.ToolCall.ToolCallID, acp.SessionUpdate{
		ToolCallID: params.ToolCall.ToolCallID, Title: params.ToolCall.Title, Kind: params.ToolCall.Kind,
		Locations: params.ToolCall.Locations, RawInput: params.ToolCall.RawInput,
	}, params.ToolCall.Content)
	title := strings.TrimSpace(tool.title)
	if title == "" {
		title = "Permission"
	}
	payload := map[string]any{
		"interactionId": id,
		"requestId":     id,
		"kind":          "permission",
		"version":       1,
		"title":         title,
		"toolKind":      tool.kind,
		"toolDetail":    tool.detail,
		"callId":        params.ToolCall.ToolCallID,
		"options":       options,
		"state":         "pending",
	}
	if tool.diff != nil {
		payload["diff"] = tool.diff
	}
	turn := handle.turn
	handle.mu.Unlock()
	now := time.Now().UTC()
	events = append(events, api.AgentEvent{ID: id, Type: "permission", Turn: turn, Payload: payload, Timestamp: now})
	handle.emitEvents(events, api.AgentStatus{
		Activity:  api.AgentActivityBlocked,
		Attention: &api.AgentAttention{Kind: api.AgentAttentionApproval, Reason: "permission", RequestID: id, Since: now},
	})
}

// orderedPermissionOptions puts the options in the order the decision dock
// presents them: allow before reject, once before always.
func orderedPermissionOptions(options []acp.PermissionOption) []acp.PermissionOption {
	rank := map[string]int{acp.PermissionAllowOnce: 0, acp.PermissionAllowAlways: 1, acp.PermissionRejectOnce: 2, acp.PermissionRejectAlways: 3}
	result := append([]acp.PermissionOption(nil), options...)
	for i := 1; i < len(result); i++ {
		for j := i; j > 0; j-- {
			left, lok := rank[result[j-1].Kind]
			right, rok := rank[result[j].Kind]
			if !lok {
				left = 4
			}
			if !rok {
				right = 4
			}
			if left <= right {
				break
			}
			result[j-1], result[j] = result[j], result[j-1]
		}
	}
	return result
}

// applyUpdateLocked translates one session/update into observations.
func (handle *acpAgentHandle) applyUpdateLocked(update acp.SessionUpdate) []api.AgentEvent {
	switch update.SessionUpdate {
	case "agent_message_chunk", "agent_thought_chunk":
		block, ok := update.ChunkContent()
		if !ok || block.Type != "text" || block.Text == "" {
			return nil
		}
		kind := "assistant"
		if update.SessionUpdate == "agent_thought_chunk" {
			kind = "reasoning"
		}
		return handle.appendChunkLocked(kind, update.MessageID, block.Text)
	case "user_message_chunk":
		// Live prompts are reported by startTurn; replayed history is dropped
		// while loading. Anything else is an echo of the former.
		return nil
	case "tool_call", "tool_call_update":
		events := handle.flushAndEndStreamLocked()
		if event, ok := handle.toolEventLocked(update); ok {
			events = append(events, event)
		}
		return events
	case "plan":
		events := handle.flushAndEndStreamLocked()
		return append(events, handle.planEventLocked(update.Entries))
	case "available_commands_update":
		commands := make([]any, 0, len(update.AvailableCommands))
		for _, command := range update.AvailableCommands {
			commands = append(commands, map[string]any{"name": command.Name, "description": clipACPText(command.Description, 280)})
		}
		return []api.AgentEvent{handle.stampLocked(api.AgentEvent{ID: "acp-commands", Type: "commands.updated", Payload: map[string]any{"commands": commands}})}
	case "current_mode_update":
		if strings.TrimSpace(update.CurrentModeID) == "" {
			return nil
		}
		return handle.setCurrentConfigLocked(func(option acpConfigOption) bool { return option.category == "mode" }, update.CurrentModeID)
	case "config_option_update":
		if len(update.ConfigOptions) == 0 {
			return nil
		}
		return handle.replaceConfigLocked(parseACPConfig(update.ConfigOptions, handle.legacyModesLocked()))
	case "usage_update":
		if update.Used == nil || update.Size == nil {
			return nil
		}
		payload := map[string]any{"used": *update.Used, "size": *update.Size}
		if update.Cost != nil && update.Cost.Currency != "" {
			payload["cost"] = map[string]any{"amount": update.Cost.Amount, "currency": update.Cost.Currency}
		}
		return []api.AgentEvent{handle.stampLocked(api.AgentEvent{ID: "acp-context", Type: "context.updated", Payload: payload})}
	default:
		return nil
	}
}

func (handle *acpAgentHandle) stampLocked(event api.AgentEvent) api.AgentEvent {
	handle.sequence++
	event.Sequence = handle.sequence
	event.Provider = handle.provider
	if event.Turn == 0 {
		event.Turn = handle.turn
	}
	if event.Timestamp.IsZero() {
		event.Timestamp = time.Now().UTC()
	}
	return event
}

// ---------------------------------------------------------------------------
// Streaming

func (handle *acpAgentHandle) appendChunkLocked(kind, messageID, text string) []api.AgentEvent {
	var events []api.AgentEvent
	if handle.stream != nil && (handle.stream.kind != kind || (messageID != "" && !strings.HasPrefix(handle.stream.id, messageID))) {
		events = handle.flushAndEndStreamLocked()
	}
	if handle.stream == nil {
		id := messageID
		if id == "" {
			handle.segment++
			id = fmt.Sprintf("acp-%s-%d-%d", kind, handle.turn, handle.segment)
		}
		id += handle.streamEpoch
		// A message that resumes after a tool call gets a fresh identity so
		// its first flush does not replace the text already shown.
		if count := handle.streamIDs[id]; count > 0 {
			handle.streamIDs[id] = count + 1
			id = fmt.Sprintf("%s#%d", id, count)
		} else {
			handle.streamIDs[id] = 1
		}
		handle.stream = &acpStream{kind: kind, id: id}
	}
	handle.stream.pending.WriteString(text)
	handle.stream.full.WriteString(text)
	if handle.flushTimer == nil {
		handle.flushTimer = time.AfterFunc(acpStreamFlushInterval, handle.flushTimerFired)
	}
	return events
}

func (handle *acpAgentHandle) flushTimerFired() {
	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	handle.flushTimer = nil
	if handle.closed {
		handle.mu.Unlock()
		return
	}
	events := handle.flushStreamLocked()
	handle.mu.Unlock()
	if len(events) > 0 {
		handle.emitEvents(events, api.AgentStatus{})
	}
}

// flushStreamLocked turns buffered text into one created or delta event.
func (handle *acpAgentHandle) flushStreamLocked() []api.AgentEvent {
	if handle.flushTimer != nil {
		handle.flushTimer.Stop()
		handle.flushTimer = nil
	}
	stream := handle.stream
	if stream == nil || stream.pending.Len() == 0 {
		return nil
	}
	event := api.AgentEvent{ID: stream.id, Type: stream.kind, Content: stream.pending.String(), ContentDelta: stream.created}
	if stream.kind == "assistant" {
		event.Role = "assistant"
	}
	stream.pending.Reset()
	stream.created = true
	return []api.AgentEvent{handle.stampLocked(event)}
}

// flushAndEndStreamLocked closes the current text segment at a non-text
// boundary. The assistant's completion is reported once at the end of the
// turn, so narration between tool calls stays a delta stream.
func (handle *acpAgentHandle) flushAndEndStreamLocked() []api.AgentEvent {
	events := handle.flushStreamLocked()
	if handle.stream != nil && handle.stream.kind == "assistant" && handle.stream.created {
		handle.lastAssistant = handle.stream
	}
	handle.stream = nil
	return events
}

func (handle *acpAgentHandle) finishStreamLocked() []api.AgentEvent {
	return handle.flushAndEndStreamLocked()
}

// completedAssistantLocked reports the turn's final answer as complete, with
// the turn's token usage attached for Usage accounting.
func (handle *acpAgentHandle) completedAssistantLocked() []api.AgentEvent {
	last := handle.lastAssistant
	handle.lastAssistant = nil
	if last == nil {
		return nil
	}
	event := api.AgentEvent{ID: last.id, Type: "assistant", Role: "assistant", Content: last.full.String(), StopReason: "end_turn", Usage: handle.turnUsage}
	handle.turnUsage = nil
	return []api.AgentEvent{handle.stampLocked(event)}
}

// ---------------------------------------------------------------------------
// Tools and plans

func (handle *acpAgentHandle) mergeToolLocked(callID string, update acp.SessionUpdate, content []acp.ToolCallContent) *acpToolState {
	tool := handle.tools[callID]
	if tool == nil {
		tool = &acpToolState{}
		handle.tools[callID] = tool
	}
	if update.Title != nil && strings.TrimSpace(*update.Title) != "" {
		tool.title = strings.TrimSpace(*update.Title)
	}
	if update.Kind != "" {
		tool.kind = acpToolKind(update.Kind)
	}
	if update.Status != "" {
		tool.status = update.Status
	}
	if len(update.RawInput) > 0 && string(update.RawInput) != "null" && string(update.RawInput) != "{}" {
		var input any
		if json.Unmarshal(update.RawInput, &input) == nil {
			tool.input = boundACPValue(input)
			if detail := acpToolDetail(input, handle.cwd); detail != "" {
				tool.detail = detail
			}
		}
	}
	if len(update.Locations) > 0 {
		files := make([]string, 0, len(update.Locations))
		for _, location := range update.Locations {
			if path := strings.TrimSpace(location.Path); path != "" {
				files = append(files, relativeToWorkspace(path, handle.cwd))
			}
		}
		if len(files) > 0 {
			tool.files = files
			if tool.detail == "" || tool.kind == "read" || tool.kind == "edit" || tool.kind == "delete" || tool.kind == "move" {
				tool.detail = files[0]
			}
		}
	}
	if content != nil {
		var output strings.Builder
		for _, item := range content {
			switch item.Type {
			case "content":
				if item.Content != nil && item.Content.Type == "text" {
					if output.Len() > 0 {
						output.WriteByte('\n')
					}
					output.WriteString(item.Content.Text)
				}
			case "diff":
				tool.diff = acpDiff(item, handle.cwd)
				if tool.detail == "" {
					tool.detail = relativeToWorkspace(item.Path, handle.cwd)
				}
			case "terminal":
				if id := strings.TrimSpace(item.TerminalID); id != "" {
					tool.terminalID = id
				}
			}
		}
		if output.Len() > 0 {
			tool.output = clipACPText(stripACPCodeFence(output.String()), acpToolTextLimit)
		}
	}
	if tool.detail == "" {
		tool.detail = tool.title
	}
	return tool
}

// stripACPCodeFence unwraps output an adapter wrapped in one Markdown code
// fence (Claude's adapter fences command and file output). Clients render
// tool output as preformatted text already, so the fence is noise.
func stripACPCodeFence(value string) string {
	trimmed := strings.TrimSpace(value)
	if !strings.HasPrefix(trimmed, "```") || !strings.HasSuffix(trimmed, "```") || len(trimmed) < 6 {
		return value
	}
	body := strings.TrimSuffix(trimmed, "```")
	newline := strings.IndexByte(body, '\n')
	if newline < 0 {
		return value
	}
	body = body[newline+1:]
	if strings.Contains(body, "\n```") {
		// More than one fenced block: keep the adapter's formatting.
		return value
	}
	return strings.TrimSuffix(body, "\n")
}

func (handle *acpAgentHandle) toolEventLocked(update acp.SessionUpdate) (api.AgentEvent, bool) {
	callID := strings.TrimSpace(update.ToolCallID)
	if callID == "" {
		return api.AgentEvent{}, false
	}
	_, known := handle.tools[callID]
	content, _ := update.ToolContent()
	if update.SessionUpdate == "tool_call" && update.Status == "" {
		update.Status = "pending"
	}
	tool := handle.mergeToolLocked(callID, update, content)
	eventType := "tool_updated"
	switch tool.status {
	case "completed":
		eventType = "tool_completed"
	case "failed":
		eventType = "tool_failed"
	default:
		if !known {
			eventType = "tool_call"
		}
	}
	fingerprint := strings.Join([]string{eventType, tool.status, tool.title, tool.kind, tool.detail, tool.output, fmt.Sprint(tool.diff != nil)}, "\x00")
	if fingerprint == tool.emitted {
		return api.AgentEvent{}, false
	}
	tool.emitted = fingerprint
	event := api.AgentEvent{
		ID:         callID,
		Type:       eventType,
		CallID:     callID,
		ToolName:   tool.title,
		ToolKind:   tool.kind,
		ToolDetail: tool.detail,
		ToolInput:  tool.input,
		ToolStatus: tool.status,
		Files:      tool.files,
	}
	if eventType == "tool_completed" || eventType == "tool_failed" {
		event.Output = tool.output
		if eventType == "tool_failed" {
			event.Error = tool.output
			if event.Error == "" {
				event.Error = "failed"
			}
		}
	}
	if tool.diff != nil {
		event.Payload = map[string]any{"diff": tool.diff}
	}
	if tool.terminalID != "" {
		if sessionID, output, ok := handle.terminalLinkLocked(tool.terminalID); ok {
			if event.Payload == nil {
				event.Payload = map[string]any{}
			}
			// Clients open the command's own terminal Session from the step.
			event.Payload["terminalSessionId"] = sessionID
			if (eventType == "tool_completed" || eventType == "tool_failed") && event.Output == "" {
				event.Output = clipACPTail(output, acpToolTextLimit)
			}
		}
	}
	return handle.stampLocked(event), true
}

func (handle *acpAgentHandle) planEventLocked(entries []acp.PlanEntry) api.AgentEvent {
	items := make([]map[string]any, 0, len(entries))
	overall := "completed"
	for index, entry := range entries {
		state := entry.Status
		if state == "" {
			state = "pending"
		}
		if state != "completed" {
			overall = "in_progress"
		}
		items = append(items, map[string]any{
			"id":       fmt.Sprintf("step-%d", index),
			"title":    clipACPText(entry.Content, 500),
			"label":    clipACPText(entry.Content, 500),
			"state":    state,
			"priority": entry.Priority,
		})
	}
	if len(entries) == 0 {
		overall = "in_progress"
	}
	return handle.stampLocked(api.AgentEvent{
		ID:   "acp-plan",
		Type: "plan",
		Payload: map[string]any{
			"planId": "acp-plan",
			"title":  "Plan",
			"state":  overall,
			"items":  items,
		},
	})
}

// acpToolKind maps an ACP ToolKind to the client vocabulary (RFC 0023 §6.2).
func acpToolKind(kind string) string {
	switch kind {
	case "read":
		return "read"
	case "edit":
		return "edit"
	case "delete":
		return "delete"
	case "move":
		return "move"
	case "search":
		return "grep"
	case "execute":
		return "ran"
	case "fetch":
		return "fetch"
	case "think":
		return "think"
	case "switch_mode":
		return "mode"
	default:
		return "tool"
	}
}

func acpToolDetail(input any, cwd string) string {
	values, ok := input.(map[string]any)
	if !ok {
		return ""
	}
	if command, ok := values["command"]; ok {
		switch typed := command.(type) {
		case string:
			return clipACPText(strings.TrimSpace(typed), 500)
		case []any:
			parts := make([]string, 0, len(typed))
			for _, part := range typed {
				parts = append(parts, fmt.Sprint(part))
			}
			return clipACPText(strings.Join(parts, " "), 500)
		}
	}
	for _, key := range []string{"filePath", "file_path", "path", "abs_path", "notebook_path"} {
		if value, ok := values[key].(string); ok && strings.TrimSpace(value) != "" {
			return relativeToWorkspace(value, cwd)
		}
	}
	for _, key := range []string{"pattern", "query", "url", "description"} {
		if value, ok := values[key].(string); ok && strings.TrimSpace(value) != "" {
			return clipACPText(strings.TrimSpace(value), 500)
		}
	}
	return ""
}

// relativeToWorkspace shortens a path inside the workspace. Agents may report
// the resolved form of a symlinked directory (/private/tmp for /tmp), so both
// forms of the workspace are tried.
func relativeToWorkspace(path, cwd string) string {
	path = strings.TrimSpace(path)
	if path == "" || cwd == "" || !filepath.IsAbs(path) {
		return path
	}
	roots := []string{filepath.Clean(cwd)}
	if resolved, err := filepath.EvalSymlinks(cwd); err == nil && resolved != roots[0] {
		roots = append(roots, resolved)
	}
	for _, root := range roots {
		if relative, err := filepath.Rel(root, path); err == nil && relative != ".." && !strings.HasPrefix(relative, "../") {
			if relative == "." {
				return filepath.Base(path)
			}
			return relative
		}
	}
	return path
}

func acpDiff(item acp.ToolCallContent, cwd string) map[string]any {
	oldText := ""
	if item.OldText != nil {
		oldText = *item.OldText
	}
	file := relativeToWorkspace(item.Path, cwd)
	unified, additions, deletions := unifiedLineDiff(strings.TrimPrefix(file, "/"), oldText, item.NewText)
	return map[string]any{
		"file":      file,
		"additions": additions,
		"deletions": deletions,
		"diff":      clipACPText(unified, acpToolTextLimit),
	}
}

// ---------------------------------------------------------------------------
// Prompts

func (handle *acpAgentHandle) promptBlocks(message api.AgentMessageSendRequest) ([]acp.ContentBlock, string, error) {
	text := message.Text
	blocks := []acp.ContentBlock{{Type: "text", Text: text}}
	if len(message.Attachments) == 0 {
		return blocks, text, nil
	}
	handle.mu.Lock()
	images := handle.initResult.AgentCapabilities.PromptCapabilities.Image
	handle.mu.Unlock()
	for _, reference := range message.Attachments {
		attachment, err := handle.service.materializedAgentAttachmentFor(handle.sessionID, reference)
		if err != nil {
			return nil, "", fmt.Errorf("attachment %s: %w", reference.AttachmentID, err)
		}
		if images && strings.HasPrefix(attachment.mime, "image/") && attachment.size <= acpImageAttachmentLimit {
			if data, readErr := os.ReadFile(attachment.path); readErr == nil {
				blocks = append(blocks, acp.ContentBlock{Type: "image", MimeType: attachment.mime, Data: base64.StdEncoding.EncodeToString(data)})
				continue
			}
		}
		size := attachment.size
		blocks = append(blocks, acp.ContentBlock{Type: "resource_link", Name: attachment.name, URI: "file://" + attachment.path, MimeType: attachment.mime, Size: &size})
	}
	return blocks, text, nil
}

// ---------------------------------------------------------------------------
// Emission

func (handle *acpAgentHandle) currentSink() AgentEventSink {
	handle.mu.Lock()
	defer handle.mu.Unlock()
	return handle.sink
}

// emitEvents reports observations. The caller holds emitMu.
func (handle *acpAgentHandle) emitEvents(events []api.AgentEvent, status api.AgentStatus) {
	if len(events) == 0 {
		if status.Activity != "" {
			emitAgentStatus(handle.currentSink(), status)
		}
		return
	}
	handle.mu.Lock()
	for index := range events {
		if events[index].Sequence == 0 {
			events[index] = handle.stampLocked(events[index])
		}
	}
	sink := handle.sink
	handle.mu.Unlock()
	emitAgentEvents(sink, events, status)
}

func (handle *acpAgentHandle) emitTurns(turn api.AgentTurn) {
	emitAgentTurns(handle.currentSink(), []api.AgentTurn{turn}, false)
}

func (handle *acpAgentHandle) errorEvent(turn uint64, message string) api.AgentEvent {
	return api.AgentEvent{ID: "acp-error-" + randomACPID(), Type: "error", Error: message, Content: message, Turn: turn, Timestamp: time.Now().UTC()}
}

func (handle *acpAgentHandle) noticeEvent(turn uint64, message string) api.AgentEvent {
	return api.AgentEvent{ID: "acp-notice-" + randomACPID(), Type: "system", Role: "system", Content: message, Turn: turn, Timestamp: time.Now().UTC()}
}

func randomACPID() string {
	value := make([]byte, 8)
	_, _ = rand.Read(value)
	return hex.EncodeToString(value)
}

func clipACPText(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	cut := limit
	for cut > 0 && !isRuneStart(value[cut]) {
		cut--
	}
	return value[:cut] + "…"
}

// clipACPTail keeps the end of value, where a command's result is.
func clipACPTail(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	cut := len(value) - limit
	for cut < len(value) && !isRuneStart(value[cut]) {
		cut++
	}
	return "…" + value[cut:]
}

func isRuneStart(value byte) bool { return value&0xC0 != 0x80 }

// boundACPValue clips long strings inside a decoded JSON value.
func boundACPValue(value any) any {
	switch typed := value.(type) {
	case string:
		return clipACPText(typed, acpToolTextLimit)
	case map[string]any:
		result := make(map[string]any, len(typed))
		for key, item := range typed {
			result[key] = boundACPValue(item)
		}
		return result
	case []any:
		result := make([]any, 0, len(typed))
		for _, item := range typed {
			result = append(result, boundACPValue(item))
		}
		return result
	default:
		return value
	}
}

var _ AgentProvider = (*ACPAgentProvider)(nil)
var _ AgentProviderCapabilities = (*ACPAgentProvider)(nil)
var _ AgentHandle = (*acpAgentHandle)(nil)
var _ acp.Handler = (*acpAgentHandle)(nil)
