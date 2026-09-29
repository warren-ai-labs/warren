package server

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// acpHandoffTarget is how a provider's TUI resumes one conversation.
type acpHandoffTarget struct {
	executable string
	resumeArgs func(conversationID string) string
}

// acpHandoffTargets lists the TUIs that can continue an ACP conversation
// (RFC 0023 §6.12). The ACP sessionId of each adapter is the provider's own
// conversation ID, so the TUI resumes it directly.
var acpHandoffTargets = map[string]acpHandoffTarget{
	"claude":   {executable: "claude", resumeArgs: func(id string) string { return "--resume " + id }},
	"codex":    {executable: "codex", resumeArgs: func(id string) string { return "resume " + id }},
	"opencode": {executable: "opencode", resumeArgs: func(id string) string { return "--session " + id }},
}

// acpConversationIDPattern bounds a provider conversation ID before it is
// typed into a login shell.
var acpConversationIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// acpHandoffCommand builds the TUI command that resumes conversationID. An
// explicit base (the client's terminal preset, which may carry flags) must
// start the provider's own executable.
func acpHandoffCommand(kind, base, conversationID string) (string, error) {
	target, ok := acpHandoffTargets[kind]
	if !ok {
		return "", fmt.Errorf("hand-off to a terminal is not available for provider %s", kind)
	}
	if !acpConversationIDPattern.MatchString(conversationID) {
		return "", fmt.Errorf("conversation ID %q cannot be resumed in a terminal", conversationID)
	}
	base = strings.TrimSpace(base)
	if base == "" {
		base = target.executable
	}
	if err := validateACPCommand(base); err != nil {
		return "", err
	}
	if filepath.Base(strings.Fields(base)[0]) != target.executable {
		return "", fmt.Errorf("the terminal command must start %s", target.executable)
	}
	return base + " " + target.resumeArgs(conversationID), nil
}

// handoffACPSession replaces an ACP Session with a TUI Session that resumes
// the same provider conversation. The ACP process is closed and confirmed
// gone before the TUI starts, and the ACP Session is removed, so the
// conversation never has two writers.
func (s *Service) handoffACPSession(ctx context.Context, sessionID, baseCommand string) (api.Session, error) {
	session, ok := s.Session(sessionID)
	if !ok {
		return api.Session{}, fmt.Errorf("session not found: %s", sessionID)
	}
	if !isACPSession(session) {
		return api.Session{}, fmt.Errorf("session %s is not a chat Session", sessionID)
	}
	conversationID := strings.TrimSpace(session.AgentSessionID)
	if conversationID == "" {
		return api.Session{}, errors.New("this conversation has not started yet, so there is nothing to continue in a terminal")
	}
	command, err := acpHandoffCommand(session.Kind, baseCommand, conversationID)
	if err != nil {
		return api.Session{}, err
	}
	if _, loaded := s.acpHandoffs.LoadOrStore(sessionID, struct{}{}); loaded {
		return api.Session{}, errors.New("this Session is already moving to a terminal")
	}
	defer s.acpHandoffs.Delete(sessionID)

	// From here Ensure refuses this Session, so no command can start a new
	// agent process while the old one is closing.
	if handle, ok := s.currentAgentHandle(sessionID).(*acpAgentHandle); ok && handle != nil {
		if err := handle.closeForHandoff(); err != nil {
			return api.Session{}, err
		}
	}
	s.stopAgent(sessionID)

	request := sessionCreateRequest{
		workspaceID: session.WorkspaceID, groupID: session.TerminalGroupID,
		command: command, kind: session.Kind, title: session.CustomTitle,
		agentHandler: []string{AgentHandlerTUI}, resumeAgentSessionID: conversationID,
	}
	var created api.Session
	if session.TerminalGroupID != "" {
		s.terminalGroupLifecycleMu.Lock()
		created, err = s.createSessionWith(ctx, request)
		s.terminalGroupLifecycleMu.Unlock()
	} else {
		if lock := s.lockWorkspaceForSession(session.WorkspaceID); lock != nil {
			created, err = s.createSessionWith(ctx, request)
			lock.RUnlock()
		} else {
			created, err = s.createSessionWith(ctx, request)
		}
	}
	if err != nil {
		// The ACP Session stays; its next prompt starts a new process and
		// resumes the conversation as after any process exit.
		return api.Session{}, fmt.Errorf("start the terminal: %w", err)
	}

	// The terminal takes the chat's place: its tab position, its panes, and
	// its pin.
	err = s.Store.Update(func(value *api.State) error {
		oldIndex, newIndex := -1, -1
		for index := range value.Sessions {
			switch value.Sessions[index].ID {
			case sessionID:
				oldIndex = index
			case created.ID:
				newIndex = index
			}
		}
		if newIndex >= 0 && oldIndex >= 0 {
			replacement := value.Sessions[newIndex]
			replacement.Pinned = value.Sessions[oldIndex].Pinned
			value.Sessions[oldIndex] = replacement
			value.Sessions = append(value.Sessions[:newIndex], value.Sessions[newIndex+1:]...)
		}
		for index := range value.PaneGroups {
			replacePaneSession(&value.PaneGroups[index].Tree, sessionID, created.ID)
		}
		reconcilePaneGroups(value)
		return nil
	})
	if err != nil {
		return api.Session{}, err
	}
	s.wakeLiveActivity()
	s.bumpAgentRosterRevision()
	if current, ok := s.Session(created.ID); ok {
		return current, nil
	}
	return created, nil
}

func replacePaneSession(node *api.PaneNode, from, to string) {
	if node == nil {
		return
	}
	if node.SessionID == from {
		node.SessionID = to
	}
	replacePaneSession(node.First, from, to)
	replacePaneSession(node.Second, from, to)
}

func (s *Service) acpHandoffActive(sessionID string) bool {
	_, active := s.acpHandoffs.Load(sessionID)
	return active
}

// closeForHandoff ends the agent process and waits until it is gone. A turn
// that is running or waiting on a decision is the user's to stop first.
func (handle *acpAgentHandle) closeForHandoff() error {
	handle.mu.Lock()
	if handle.promptActive || len(handle.permissions) > 0 {
		handle.mu.Unlock()
		return errors.New("stop the running turn before continuing in a terminal")
	}
	proc := handle.shutdownLocked()
	handle.mu.Unlock()
	if proc != nil {
		proc.Close()
	}
	return nil
}
