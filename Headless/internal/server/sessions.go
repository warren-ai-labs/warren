package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func (s *Service) RenameSession(id, title string) error {
	title = strings.TrimSpace(title)
	if title == "" {
		return errors.New("session title cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			if state.Sessions[index].ID == id {
				state.Sessions[index].CustomTitle = title
				return nil
			}
		}
		return fmt.Errorf("session not found: %s", id)
	})
}

func (s *Service) SetSessionPinned(id string, pinned bool) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			if state.Sessions[index].ID == id {
				state.Sessions[index].Pinned = pinned
				return nil
			}
		}
		return fmt.Errorf("session not found: %s", id)
	})
}

func (s *Service) CreateSession(ctx context.Context, workspaceID, command, kind, title, runtimeKind string) (api.Session, error) {
	return s.CreateSessionWithHandler(ctx, workspaceID, command, kind, title, runtimeKind, "")
}

// CreateSessionWithHandler is the handler-aware form used by protocol
// clients that explicitly select a transport such as codex/acp. The original
// CreateSession signature remains source-compatible for shell and TUI users.
func (s *Service) CreateSessionWithHandler(ctx context.Context, workspaceID, command, kind, title, runtimeKind, agentHandler string) (api.Session, error) {
	if workspaceID != "" {
		if projectLock := s.lockWorkspaceForSession(workspaceID); projectLock != nil {
			defer projectLock.RUnlock()
		}
	}
	return s.createSession(ctx, workspaceID, "", command, kind, title, runtimeKind, agentHandler)
}

func (s *Service) CreateGroupSession(ctx context.Context, groupID, command, kind, title, runtimeKind string) (api.Session, error) {
	return s.CreateGroupSessionWithHandler(ctx, groupID, command, kind, title, runtimeKind, "")
}

func (s *Service) CreateGroupSessionWithHandler(ctx context.Context, groupID, command, kind, title, runtimeKind, agentHandler string) (api.Session, error) {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()
	return s.createSession(ctx, "", groupID, command, kind, title, runtimeKind, agentHandler)
}

// CreateDefaultGroupSession creates a standalone shell in the first ordered
// Group, recreating Inbox when a Host has no Groups left.
func (s *Service) CreateDefaultGroupSession(ctx context.Context, command, kind, title, runtimeKind string) (api.Session, error) {
	return s.CreateDefaultGroupSessionWithHandler(ctx, command, kind, title, runtimeKind, "")
}

func (s *Service) CreateDefaultGroupSessionWithHandler(ctx context.Context, command, kind, title, runtimeKind, agentHandler string) (api.Session, error) {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()

	group, err := s.ensureTerminalGroup()
	if err != nil {
		return api.Session{}, err
	}
	return s.createSession(ctx, "", group.ID, command, kind, title, runtimeKind, agentHandler)
}

// sessionEnvironment returns the per-session bindings together with the
// current runtime overrides. The overrides are sent with every new session so
// a detached Ghostline server can apply settings changed after it started;
// existing sessions keep the environment they were created with. Empty values
// are retained as explicit unset requests and are handled by the login-shell
// bootstrap in GhostlineRuntime.
func (s *Service) sessionEnvironment(id, kind string) ([]string, error) {
	env := agent.BindEnvironment(id, kind)
	runtimeEnv := s.SettingsSnapshot().RuntimeEnv
	if err := settings.ValidateRuntimeEnv(runtimeEnv); err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(runtimeEnv))
	for key := range runtimeEnv {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	for _, key := range keys {
		env = append(env, key+"="+runtimeEnv[key])
	}
	return env, nil
}

func (s *Service) createSession(ctx context.Context, workspaceID, groupID, command, kind, title, runtimeKind string, agentHandler ...string) (api.Session, error) {
	return s.createSessionWith(ctx, sessionCreateRequest{
		workspaceID: workspaceID, groupID: groupID, command: command, kind: kind,
		title: title, runtimeKind: runtimeKind, agentHandler: agentHandler,
	})
}

// sessionCreateRequest carries createSession's arguments plus the Host-only
// resume binding used by an ACP hand-off (RFC 0023 §6.12).
type sessionCreateRequest struct {
	workspaceID, groupID, command, kind, title, runtimeKind string
	agentHandler                                            []string
	// resumeAgentSessionID binds the new TUI Session to a provider
	// conversation Warren already owns. The command then names that
	// conversation itself, which the provider validators otherwise refuse.
	resumeAgentSessionID string
	// processArgv runs one command as the PTY's process instead of an
	// interactive shell; command is then only the displayed command line.
	// It backs a terminal an ACP agent creates (RFC 0023 §6.6).
	processArgv      []string
	processDirectory string
	processEnv       []string
}

func (s *Service) createSessionWith(ctx context.Context, request sessionCreateRequest) (api.Session, error) {
	workspaceID, groupID, command, kind, title, runtimeKind, agentHandler := request.workspaceID, request.groupID, request.command, request.kind, request.title, request.runtimeKind, request.agentHandler
	resuming := request.resumeAgentSessionID != ""
	startedAt := time.Now()
	if workspaceID == "" && groupID == "" {
		return api.Session{}, errors.New("workspace or terminal group is required")
	}
	if workspaceID != "" && groupID != "" {
		return api.Session{}, errors.New("workspace and terminal group are mutually exclusive")
	}
	if normalizeProviderKind(kind) == sessionKindBrowser {
		// A browser Session has no PTY and no Ghostline runtime, so the terminal
		// creation path would record a Session that can never start. Refusing
		// here is better than a Session stuck in "running" with nothing behind
		// it.
		return api.Session{}, errors.New("a browser Session is created with browser.session.create, not session.create")
	}
	state := s.Store.Snapshot()
	var workspace *api.Workspace
	var group *api.TerminalGroup
	if workspaceID != "" {
		for i := range state.Workspaces {
			if state.Workspaces[i].ID == workspaceID {
				workspace = &state.Workspaces[i]
				break
			}
		}
		if workspace == nil {
			return api.Session{}, fmt.Errorf("workspace not found: %s", workspaceID)
		}
	} else {
		for i := range state.TerminalGroups {
			if state.TerminalGroups[i].ID == groupID {
				group = &state.TerminalGroups[i]
				break
			}
		}
		if group == nil {
			return api.Session{}, fmt.Errorf("terminal group not found: %s", groupID)
		}
	}
	workingDirectory, err := sessionWorkingDirectory(state, workspaceID, groupID)
	if err != nil {
		return api.Session{}, err
	}
	id := store.NewID()
	runtimeName := "warren_" + strings.ReplaceAll(id, "-", "")
	kind = normalizeProviderKind(kind)
	if kind == "" {
		kind = "shell"
	}
	kind, embeddedAgentHandler := splitAgentKey(kind)
	selectedAgentHandler := ""
	if embeddedAgentHandler != "" {
		selectedAgentHandler = embeddedAgentHandler
	}
	if len(agentHandler) > 0 {
		explicitHandler := normalizeProviderKind(agentHandler[0])
		if family, embeddedHandler := splitAgentKey(explicitHandler); family == kind && embeddedHandler != "" {
			selectedAgentHandler = embeddedHandler
		} else if explicitHandler != "" {
			selectedAgentHandler = explicitHandler
		}
	}
	if selectedAgentHandler == AgentHandlerACP {
		// An ACP Session has no PTY; the Agent handle owns its process
		// (RFC 0023).
		return s.createACPSession(ctx, workspaceID, groupID, command, kind, title)
	}
	if kind == "opencode" {
		if strings.TrimSpace(command) == "" {
			command = "opencode"
		}
		if !resuming {
			if err := agent.ValidateOpenCodeCommand(command); err != nil {
				return api.Session{}, err
			}
		}
	}
	if kind == "pi" {
		if strings.TrimSpace(command) == "" {
			command = "pi"
		}
		if err := agent.ValidatePiCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	if kind == "qoder" {
		if strings.TrimSpace(command) == "" {
			command = "qoder"
		}
		if err := agent.ValidateQoderCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	if kind == "antigravity" {
		if strings.TrimSpace(command) == "" {
			command = "agy"
		}
		if err := agent.ValidateAntigravityCommand(command); err != nil {
			return api.Session{}, err
		}
	}
	customTitle := strings.TrimSpace(title)
	defaultTitle := map[string]string{
		"shell": "Shell", "codex": "Codex", "claude": "Claude Code", "opencode": "OpenCode", "trae": "Trae", "pi": "Pi", "qoder": "Qoder", "antigravity": "Antigravity",
	}[kind]
	if defaultTitle == "" {
		fields := strings.Fields(command)
		if len(fields) > 0 {
			defaultTitle = fields[0]
		} else {
			defaultTitle = "Shell"
		}
	}
	// A title that merely repeats the kind-derived default is not a user-set
	// name: preset bars used to echo their display label ("Pi", "Codex") as
	// the create title, which occupied the custom-title slot and suppressed
	// automatic AI title generation. Keep CustomTitle empty in that case so
	// the roster falls back to Title until a real rename or generated title
	// arrives.
	if customTitle == defaultTitle {
		customTitle = ""
	}
	sessionKind := runtimeKind
	if sessionKind == "" {
		sessionKind = s.runtimeKindFor(api.Session{})
	}
	adapter := s.runtimeFor(api.Session{RuntimeKind: sessionKind})
	if adapter == nil {
		return api.Session{}, fmt.Errorf("runtime %q is not available", sessionKind)
	}
	// The Claude transcript path is derived from the session ID we inject,
	// so the daemon can bind it without a hook round-trip.
	injectedClaude := false
	if kind == "claude" {
		injected := agent.InjectClaudeSessionID(command, id)
		if injected != command {
			command = injected
			injectedClaude = true
		}
	}
	injectedQoder := false
	if kind == "qoder" {
		injected := agent.InjectQoderSessionID(command, id)
		if injected != command {
			command = injected
			injectedQoder = true
		}
	}
	// Every session gets the binding environment so a CLI started manually
	// inside a plain shell is bound to the same Warren session by its own
	// lifecycle hooks.
	env, err := s.sessionEnvironment(id, kind)
	if err != nil {
		return api.Session{}, fmt.Errorf("build session environment: %w", err)
	}
	// Capture the Warren creation time before launching the provider. OpenCode
	// creates its SQLite session during process startup, so recording the time
	// afterwards can make a valid first session look older than Warren's
	// discovery lower bound.
	sessionCreatedAt := time.Now().UTC()
	runtimeStartedAt := time.Now()
	if len(request.processArgv) > 0 {
		processRuntime, ok := adapter.(ProcessRuntime)
		if !ok {
			return api.Session{}, fmt.Errorf("runtime %q cannot run a command without a shell", sessionKind)
		}
		directory := workingDirectory
		if request.processDirectory != "" {
			directory = request.processDirectory
		}
		if err := processRuntime.CreateProcess(ctx, runtimeName, directory, request.processArgv, append(env, request.processEnv...)); err != nil {
			return api.Session{}, err
		}
	} else if err := adapter.Create(ctx, runtimeName, workingDirectory, command, env); err != nil {
		return api.Session{}, err
	}
	runtimeDuration := time.Since(runtimeStartedAt)
	session := api.Session{
		ID:              id,
		WorkspaceID:     workspaceID,
		TerminalGroupID: groupID,
		Scope:           api.SessionScopeWorkspace,
		Title:           defaultTitle,
		CustomTitle:     customTitle,
		Kind:            kind,
		AgentProvider:   agentProviderForKind(kind),
		AgentHandler:    selectedAgentHandler,
		Command:         command,
		Runtime:         runtimeName,
		RuntimeKind:     sessionKind,
		Lifecycle:       "running",
		CreatedAt:       sessionCreatedAt,
	}
	if groupID != "" {
		session.Scope = api.SessionScopeTerminalGroup
	}
	if injectedClaude {
		session.AgentSessionID = id
	}
	if injectedQoder {
		session.AgentSessionID = id
	}
	if resuming {
		session.AgentSessionID = request.resumeAgentSessionID
	}
	storeStartedAt := time.Now()
	if err := s.Store.Update(func(value *api.State) error { value.Sessions = append(value.Sessions, session); return nil }); err != nil {
		_ = adapter.Kill(ctx, runtimeName)
		return api.Session{}, err
	}
	s.wakeLiveActivity()
	storeDuration := time.Since(storeStartedAt)
	outputStartedAt := time.Now()
	if _, err := s.ensureOutput(ctx, session); err != nil {
		_ = adapter.Kill(ctx, runtimeName)
		_ = s.Store.Update(func(value *api.State) error {
			value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
			return nil
		})
		return api.Session{}, err
	}
	outputDuration := time.Since(outputStartedAt)
	agentStartedAt := time.Now()
	_, _ = s.ensureAgent(ctx, session)
	agentDuration := time.Since(agentStartedAt)
	s.logInfo(
		"session create complete",
		"session", session.ID,
		"runtimeKind", session.RuntimeKind,
		"runtimeCreate", runtimeDuration,
		"store", storeDuration,
		"output", outputDuration,
		"agent", agentDuration,
		"total", time.Since(startedAt),
	)
	return session, nil
}

func (s *Service) DeleteSession(ctx context.Context, id string) error {
	state := s.Store.Snapshot()
	var session *api.Session
	for i := range state.Sessions {
		if state.Sessions[i].ID == id {
			session = &state.Sessions[i]
			break
		}
	}
	if session == nil {
		// Deleting a missing session is a successful no-op. The desktop can
		// emit a second close for a tab whose roster update has not arrived
		// yet; treating that duplicate as an error makes rapid close actions
		// surface as failures.
		return nil
	}
	var releaseOpenCodeBinding func()
	if session.Kind == "opencode" {
		// Serialize deletion with provider-session discovery so a concurrent
		// reconcile cannot persist a binding or restart a tailer after this
		// Warren session has been removed.
		s.openCodeBindingMu.Lock()
		releaseOpenCodeBinding = s.openCodeBindingMu.Unlock
		defer releaseOpenCodeBinding()
	}
	// A browser Session owns a Chromium and a profile directory, not a PTY
	// runtime. Killing a Ghostline runtime named after it would fail, and the
	// browser would keep running.
	if session.Kind == sessionKindBrowser {
		return s.CloseBrowserSession(ctx, id)
	}
	if isACPSession(*session) {
		// Closing the Agent handle ends the agent process group.
		s.stopAgent(id)
		err := s.Store.Update(func(value *api.State) error {
			value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
			reconcilePaneGroups(value)
			return nil
		})
		if err == nil {
			s.wakeLiveActivity()
		}
		return err
	}
	// Only explicit Close Tab / Terminate Session reaches kill-session.
	adapter := s.runtimeFor(*session)
	if err := adapter.Kill(ctx, session.Runtime); err != nil {
		return err
	}
	s.stopOutput(id, true)
	if session.Kind == "opencode" {
		// OpenCode's projection cache is retained across a daemon restart, but
		// an explicitly deleted Warren session must not leave its conversation
		// snapshot behind indefinitely.
		_ = agent.RemoveOpenCodeCache(session.TranscriptPath)
	}
	agent.RemoveBinding(id)
	err := s.Store.Update(func(value *api.State) error {
		value.Sessions = filter(value.Sessions, func(item api.Session) bool { return item.ID != id })
		// The deleted Session's pane goes with it; an arrangement that loses its
		// last pane is deleted, and every other group keeps its revision.
		reconcilePaneGroups(value)
		return nil
	})
	if err == nil {
		s.wakeLiveActivity()
	}
	return err
}

func (s *Service) Session(id string) (api.Session, bool) {
	for _, session := range s.Store.Snapshot().Sessions {
		if session.ID == id && session.Lifecycle == "running" {
			return session, true
		}
	}
	return api.Session{}, false
}

// SessionMoveExpectations are optional compare-and-swap guards. A nil pointer
// means the caller did not observe that piece of source context and therefore
// does not ask the Host to guard it. A non-nil pointer, including an empty
// string, is an explicit expectation.
type SessionMoveExpectations struct {
	WorkspaceID    *string
	AgentSessionID *string
}

// MoveSession changes the Host scope of a Session between a Workspace and a
// Terminal Group. The compatibility wrapper keeps existing API callers
// working; new callers should use MoveSessionWithExpectations.
func (s *Service) MoveSession(ctx context.Context, id, workspaceID, groupID string) (api.Session, error) {
	return s.MoveSessionWithExpectations(ctx, id, workspaceID, groupID, SessionMoveExpectations{})
}

// MoveSessionWithExpectations performs an atomic move with optional source
// context guards and records a reversible operation audit entry. The runtime,
// working directory, output history, and Session ID are all preserved.
func (s *Service) MoveSessionWithExpectations(_ context.Context, id, workspaceID, groupID string, expectations SessionMoveExpectations) (api.Session, error) {
	if workspaceID == "" && groupID == "" {
		return api.Session{}, errors.New("workspace or terminal group is required")
	}
	if workspaceID != "" && groupID != "" {
		return api.Session{}, errors.New("workspace and terminal group are mutually exclusive")
	}
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()

	var moved api.Session
	var operationID string
	err := s.Store.Update(func(value *api.State) error {
		index := -1
		for candidate := range value.Sessions {
			if value.Sessions[candidate].ID == id {
				index = candidate
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("session not found: %s", id)
		}
		session := value.Sessions[index]
		if expectations.WorkspaceID != nil && session.WorkspaceID != *expectations.WorkspaceID {
			return fmt.Errorf("stale session context for %s: expected workspace %q, found %q; refresh session list and retry", id, *expectations.WorkspaceID, session.WorkspaceID)
		}
		if expectations.AgentSessionID != nil && session.AgentSessionID != *expectations.AgentSessionID {
			return fmt.Errorf("stale agent session context for %s: expected agent session %q, found %q; refresh session list and retry", id, *expectations.AgentSessionID, session.AgentSessionID)
		}
		if workspaceID != "" {
			if !workspaceExists(value, workspaceID) {
				return fmt.Errorf("workspace not found: %s", workspaceID)
			}
		} else if !terminalGroupExists(value, groupID) {
			return fmt.Errorf("terminal group not found: %s", groupID)
		}
		if session.WorkspaceID == workspaceID && session.TerminalGroupID == groupID {
			moved = session
			return nil
		}

		beforeWorkspaceID := session.WorkspaceID
		beforeGroupID := session.TerminalGroupID
		session.WorkspaceID = workspaceID
		session.TerminalGroupID = groupID
		session.Scope = api.SessionScopeWorkspace
		if groupID != "" {
			session.Scope = api.SessionScopeTerminalGroup
		}
		value.Sessions[index] = session
		operationID = store.NewID()
		value.Operations = append(value.Operations, api.OperationAudit{
			ID: operationID, Kind: "session.move", Resource: "session", ResourceID: id,
			BeforeWorkspaceID: beforeWorkspaceID, BeforeTerminalGroupID: beforeGroupID,
			AfterWorkspaceID: workspaceID, AfterTerminalGroupID: groupID,
			AgentSessionID: session.AgentSessionID,
			CreatedAt:      time.Now().UTC(),
		})
		if len(value.Operations) > operationAuditLimit {
			value.Operations = append([]api.OperationAudit(nil), value.Operations[len(value.Operations)-operationAuditLimit:]...)
		}
		// A Session that leaves its owner cannot stay in that owner's
		// arrangement. It reappears as an ordinary unplaced Tab in the new one.
		reconcilePaneGroups(value)
		moved = session
		return nil
	})
	if err != nil {
		return api.Session{}, err
	}
	moved.OperationID = operationID
	return moved, nil
}

func workspaceExists(state *api.State, id string) bool {
	for _, workspace := range state.Workspaces {
		if workspace.ID == id {
			return true
		}
	}
	return false
}

func terminalGroupExists(state *api.State, id string) bool {
	for _, group := range state.TerminalGroups {
		if group.ID == id {
			return true
		}
	}
	return false
}

// PreflightSessionMove validates a move without changing durable state. It
// uses the same context checks as the atomic mutation path so dry-run output
// is actionable rather than a best-effort local guess.
func (s *Service) PreflightSessionMove(id, workspaceID, groupID string, expectations SessionMoveExpectations) (api.SessionMovePreflight, error) {
	if workspaceID == "" && groupID == "" {
		return api.SessionMovePreflight{}, errors.New("workspace or terminal group is required")
	}
	if workspaceID != "" && groupID != "" {
		return api.SessionMovePreflight{}, errors.New("workspace and terminal group are mutually exclusive")
	}
	state := s.Store.Snapshot()
	var session api.Session
	found := false
	for _, candidate := range state.Sessions {
		if candidate.ID == id {
			session = candidate
			found = true
			break
		}
	}
	if !found {
		return api.SessionMovePreflight{}, fmt.Errorf("session not found: %s", id)
	}
	if expectations.WorkspaceID != nil && session.WorkspaceID != *expectations.WorkspaceID {
		return api.SessionMovePreflight{}, fmt.Errorf("stale session context for %s: expected workspace %q, found %q; refresh session list and retry", id, *expectations.WorkspaceID, session.WorkspaceID)
	}
	if expectations.AgentSessionID != nil && session.AgentSessionID != *expectations.AgentSessionID {
		return api.SessionMovePreflight{}, fmt.Errorf("stale agent session context for %s: expected agent session %q, found %q; refresh session list and retry", id, *expectations.AgentSessionID, session.AgentSessionID)
	}
	if workspaceID != "" && !workspaceExists(&state, workspaceID) {
		return api.SessionMovePreflight{}, fmt.Errorf("workspace not found: %s", workspaceID)
	}
	if groupID != "" && !terminalGroupExists(&state, groupID) {
		return api.SessionMovePreflight{}, fmt.Errorf("terminal group not found: %s", groupID)
	}
	result := api.SessionMovePreflight{
		Allowed: true, Session: session,
		SourceWorkspaceID: session.WorkspaceID, SourceTerminalGroupID: session.TerminalGroupID,
		DestinationWorkspaceID: workspaceID, DestinationTerminalGroupID: groupID,
	}
	if expectations.WorkspaceID != nil {
		result.ExpectedWorkspaceID = *expectations.WorkspaceID
	}
	if expectations.AgentSessionID != nil {
		result.ExpectedAgentSessionID = *expectations.AgentSessionID
	}
	return result, nil
}

// UndoSessionMove reverts a recorded move only while the session still has
// the exact post-move ownership recorded by the operation. Any intervening
// change fails closed and leaves both state and audit history untouched.
func (s *Service) UndoSessionMove(operationID string) (api.Session, error) {
	if strings.TrimSpace(operationID) == "" {
		return api.Session{}, errors.New("operation ID is required")
	}
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()
	var moved api.Session
	var reversalID string
	err := s.Store.Update(func(state *api.State) error {
		operationIndex := -1
		for index := len(state.Operations) - 1; index >= 0; index-- {
			if state.Operations[index].ID == operationID {
				operationIndex = index
				break
			}
		}
		if operationIndex < 0 {
			return fmt.Errorf("operation not found: %s", operationID)
		}
		operation := state.Operations[operationIndex]
		if operation.Kind != "session.move" || operation.Resource != "session" {
			return fmt.Errorf("operation is not an undoable session move: %s", operationID)
		}
		if operation.RevertedAt != nil {
			return fmt.Errorf("operation already reverted: %s", operationID)
		}
		sessionIndex := -1
		for index := range state.Sessions {
			if state.Sessions[index].ID == operation.ResourceID {
				sessionIndex = index
				break
			}
		}
		if sessionIndex < 0 {
			return fmt.Errorf("session not found for operation %s: %s", operationID, operation.ResourceID)
		}
		current := state.Sessions[sessionIndex]
		if current.WorkspaceID != operation.AfterWorkspaceID || current.TerminalGroupID != operation.AfterTerminalGroupID || current.AgentSessionID != operation.AgentSessionID {
			return fmt.Errorf("cannot undo operation %s: session context changed; expected workspace %q/group %q/agent %q, found workspace %q/group %q/agent %q", operationID, operation.AfterWorkspaceID, operation.AfterTerminalGroupID, operation.AgentSessionID, current.WorkspaceID, current.TerminalGroupID, current.AgentSessionID)
		}
		current.WorkspaceID = operation.BeforeWorkspaceID
		current.TerminalGroupID = operation.BeforeTerminalGroupID
		current.Scope = api.SessionScopeWorkspace
		if current.TerminalGroupID != "" {
			current.Scope = api.SessionScopeTerminalGroup
		}
		state.Sessions[sessionIndex] = current
		now := time.Now().UTC()
		state.Operations[operationIndex].RevertedAt = &now
		reversalID = store.NewID()
		state.Operations = append(state.Operations, api.OperationAudit{
			ID: reversalID, Kind: "session.move.revert", Resource: "session", ResourceID: current.ID,
			BeforeWorkspaceID: operation.AfterWorkspaceID, BeforeTerminalGroupID: operation.AfterTerminalGroupID,
			AfterWorkspaceID: operation.BeforeWorkspaceID, AfterTerminalGroupID: operation.BeforeTerminalGroupID,
			AgentSessionID:     operation.AgentSessionID,
			RevertsOperationID: operationID, CreatedAt: now,
		})
		if len(state.Operations) > operationAuditLimit {
			state.Operations = append([]api.OperationAudit(nil), state.Operations[len(state.Operations)-operationAuditLimit:]...)
		}
		moved = current
		return nil
	})
	if err != nil {
		return api.Session{}, err
	}
	moved.OperationID = reversalID
	return moved, nil
}

func (s *Service) removeWorkspaceRuntime(ctx context.Context, state api.State, workspaceID string) error {
	for _, session := range state.Sessions {
		if session.WorkspaceID == workspaceID {
			if session.Kind == "opencode" {
				s.openCodeBindingMu.Lock()
			}
			if adapter := s.runtimeFor(session); adapter != nil {
				_ = adapter.Kill(ctx, session.Runtime)
			}
			s.stopOutput(session.ID, true)
			if session.Kind == "opencode" {
				_ = agent.RemoveOpenCodeCache(session.TranscriptPath)
			}
			agent.RemoveBinding(session.ID)
			if session.Kind == "opencode" {
				s.openCodeBindingMu.Unlock()
			}
		}
	}
	return nil
}

func (s *Service) removeTerminalGroupRuntimes(ctx context.Context, state api.State, groupID string) {
	for _, session := range state.Sessions {
		if session.TerminalGroupID != groupID || session.Lifecycle != "running" {
			continue
		}
		if session.Kind == "opencode" {
			s.openCodeBindingMu.Lock()
		}
		if adapter := s.runtimeFor(session); adapter != nil {
			_ = adapter.Kill(ctx, session.Runtime)
		}
		s.stopOutput(session.ID, true)
		if session.Kind == "opencode" {
			_ = agent.RemoveOpenCodeCache(session.TranscriptPath)
		}
		agent.RemoveBinding(session.ID)
		if session.Kind == "opencode" {
			s.openCodeBindingMu.Unlock()
		}
	}
}

// sessionLaunchDirectory is the directory Warren started a Session in: the
// Terminal Group home (falling back to the Host home) or the Workspace path.
// It matches sessionWorkingDirectory without the filesystem check that only
// the create path needs.
func sessionLaunchDirectory(session api.Session, workspacePaths, groupHomes map[string]string) string {
	if session.TerminalGroupID != "" {
		home, ok := groupHomes[session.TerminalGroupID]
		if !ok {
			return ""
		}
		if home != "" {
			return home
		}
		resolved, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		return resolved
	}
	return workspacePaths[session.WorkspaceID]
}

func sessionWorkingDirectory(state api.State, workspaceID, groupID string) (string, error) {
	if groupID != "" {
		for _, group := range state.TerminalGroups {
			if group.ID != groupID {
				continue
			}
			home := group.Home
			if home == "" {
				var err error
				home, err = os.UserHomeDir()
				if err != nil {
					return "", fmt.Errorf("resolve host home directory: %w", err)
				}
			}
			info, err := os.Stat(home)
			if err != nil || !info.IsDir() {
				return "", fmt.Errorf("terminal group home is not a directory: %s", home)
			}
			return home, nil
		}
		return "", fmt.Errorf("terminal group not found: %s", groupID)
	}
	for _, workspace := range state.Workspaces {
		if workspace.ID == workspaceID {
			return workspace.Path, nil
		}
	}
	return "", fmt.Errorf("workspace not found: %s", workspaceID)
}
