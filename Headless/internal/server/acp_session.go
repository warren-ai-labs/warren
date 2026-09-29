package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/acp"
	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// runtimeKindACP marks a Session whose Agent is driven over the Agent Client
// Protocol (RFC 0023). Like a browser Session, it owns no Ghostline runtime;
// every path that assumes a PTY branches on this value.
const runtimeKindACP = "acp"

// errSessionHasNoTerminal is returned by terminal operations on a Session
// without a PTY.
var errSessionHasNoTerminal = errors.New("session has no terminal; use the Agent commands (warren agent read/send)")

// acpProviderCommand is the default ACP server for one provider family.
type acpProviderCommand struct {
	command    string
	executable string
	install    string
}

// acpProviderCommands lists the providers that ship an ACP server. Warren
// never downloads an adapter on the user's behalf (RFC 0023 §5.3).
var acpProviderCommands = map[string]acpProviderCommand{
	"claude":   {command: "claude-agent-acp", executable: "claude-agent-acp", install: "npm install -g @agentclientprotocol/claude-agent-acp"},
	"codex":    {command: "codex-acp", executable: "codex-acp", install: "npm install -g @zed-industries/codex-acp"},
	"opencode": {command: "opencode acp", executable: "opencode", install: "see https://opencode.ai to install OpenCode"},
}

// ACPProviderAvailable reports whether a provider family has an ACP server.
func ACPProviderAvailable(kind string) bool {
	_, ok := acpProviderCommands[normalizeProviderKind(kind)]
	return ok
}

func isACPSession(session api.Session) bool {
	return session.RuntimeKind == runtimeKindACP
}

// validateACPCommand rejects shell syntax that would run more than the ACP
// server. The command is executed by the login shell, so operators and
// substitutions would otherwise reach it.
func validateACPCommand(command string) error {
	command = strings.TrimSpace(command)
	if command == "" {
		return errors.New("ACP command must not be empty")
	}
	if strings.ContainsAny(command, ";&|<>`\n\r") || strings.Contains(command, "$(") {
		return errors.New("ACP command must be one program with arguments; shell operators and substitutions are not allowed")
	}
	return nil
}

// acpShell returns the login shell and flags used to launch agents, matching
// what a terminal Session sees. Tests may override it through Service.
func (s *Service) acpShell() (string, []string, []string) {
	if s.ACPShell != nil {
		shell, args := s.ACPShell()
		return shell, args, nil
	}
	// An interactive login shell matches a terminal Session; when a startup
	// file keeps it from reaching exec, a plain login shell is the fallback.
	return runtime.LoginShellPath(), runtime.LoginShellArgs(), []string{"-l"}
}

// acpEnvironment is the agent's environment: the Host's own, minus Warren's
// TUI binding variables, plus the configured runtime environment. ACP
// Sessions deliberately get no binding variables: a provider hook writing a
// TUI state file for this Session would be a second authority over its status.
func (s *Service) acpEnvironment() ([]string, error) {
	drop := map[string]struct{}{
		agent.BindEnvSession: {}, agent.BindEnvFile: {}, agent.BindEnvState: {}, agent.BindEnvKind: {},
		agent.BindEnvCodexSessionID: {}, agent.BindEnvCodexThreadID: {},
	}
	env := make([]string, 0, len(os.Environ())+8)
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if _, skip := drop[key]; skip {
			continue
		}
		env = append(env, entry)
	}
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

// resolveACPCommand returns the command to launch for a provider. An explicit
// command wins; otherwise the provider default must resolve on the login
// shell's PATH, and a missing adapter is a creation error that names what to
// install.
func (s *Service) resolveACPCommand(ctx context.Context, kind, command, dir string) (string, error) {
	defaults, ok := acpProviderCommands[kind]
	if !ok {
		return "", fmt.Errorf("acp is not available for provider %s", kind)
	}
	if strings.TrimSpace(command) != "" {
		if err := validateACPCommand(command); err != nil {
			return "", err
		}
		return strings.TrimSpace(command), nil
	}
	shell, args, fallback := s.acpShell()
	env, err := s.acpEnvironment()
	if err != nil {
		return "", err
	}
	if !acp.LookPathInShell(ctx, shell, args, fallback, dir, env, defaults.executable) {
		return "", fmt.Errorf("%s was not found on this Host's PATH; install it (%s) or pass an explicit ACP command", defaults.executable, defaults.install)
	}
	return defaults.command, nil
}

// createACPSession records a Session driven over ACP. There is no PTY: the
// agent process is started by the Agent handle and is a disposable worker of
// the Session (RFC 0023 §4).
func (s *Service) createACPSession(ctx context.Context, workspaceID, groupID, command, kind, title string) (api.Session, error) {
	startedAt := time.Now()
	if !ACPProviderAvailable(kind) {
		return api.Session{}, fmt.Errorf("acp is not available for provider %s", kind)
	}
	state := s.Store.Snapshot()
	workingDirectory, err := sessionWorkingDirectory(state, workspaceID, groupID)
	if err != nil {
		return api.Session{}, err
	}
	resolved, err := s.resolveACPCommand(ctx, kind, command, workingDirectory)
	if err != nil {
		return api.Session{}, err
	}
	defaultTitle := map[string]string{"codex": "Codex", "claude": "Claude Code", "opencode": "OpenCode"}[kind]
	customTitle := strings.TrimSpace(title)
	if customTitle == defaultTitle {
		customTitle = ""
	}
	session := api.Session{
		ID:              store.NewID(),
		WorkspaceID:     workspaceID,
		TerminalGroupID: groupID,
		Scope:           api.SessionScopeWorkspace,
		Title:           defaultTitle,
		CustomTitle:     customTitle,
		Kind:            kind,
		AgentProvider:   kind,
		AgentHandler:    AgentHandlerACP,
		Command:         resolved,
		RuntimeKind:     runtimeKindACP,
		Lifecycle:       "running",
		CreatedAt:       time.Now().UTC(),
	}
	if groupID != "" {
		session.Scope = api.SessionScopeTerminalGroup
	}
	if err := s.Store.Update(func(value *api.State) error { value.Sessions = append(value.Sessions, session); return nil }); err != nil {
		return api.Session{}, err
	}
	s.wakeLiveActivity()
	if _, err := s.ensureAgent(ctx, session); err != nil {
		s.logWarn("acp session agent start failed", "session", session.ID, "error", err)
	}
	s.logInfo("acp session create complete", "session", session.ID, "provider", kind, "total", time.Since(startedAt))
	if current, ok := s.Session(session.ID); ok {
		return current, nil
	}
	return session, nil
}

// persistACPSessionID records the agent's conversation ID so a restarted
// agent can resume it.
func (s *Service) persistACPSessionID(sessionID, acpSessionID string) {
	if s.Store == nil {
		return
	}
	_ = s.Store.Update(func(value *api.State) error {
		for index := range value.Sessions {
			if value.Sessions[index].ID == sessionID {
				value.Sessions[index].AgentSessionID = acpSessionID
			}
		}
		return nil
	})
	s.bumpAgentRosterRevision()
}

// rotateACPExecution starts a new execution stream for a Session whose agent
// could not resume its conversation. A new provider conversation is a new
// execution (RFC 0016 §3); the old stream stays immutable.
func (s *Service) rotateACPExecution(sessionID string, handle AgentHandle) {
	executionID := s.ensureAgentExecutionID(nil, sessionID, true)
	lock := s.agentLock(sessionID)
	lock.Lock()
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	if entry != nil {
		entry.mu.Lock()
		if entry.handle == handle {
			entry.executionID = executionID
			resetAgentProjectionLocked(entry)
		}
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	lock.Unlock()
	s.bumpAgentEpoch()
	s.bumpAgentRosterRevision()
}
