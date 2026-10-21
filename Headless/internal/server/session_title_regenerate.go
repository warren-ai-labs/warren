package server

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	sessiontitle "github.com/abcdlsj/warren/Headless/internal/title"
)

// regenerateTitleTimeout bounds one explicit rename. The user is waiting for it,
// so it is the same budget every other title request uses rather than an
// open-ended one.
const regenerateTitleTimeout = 15 * time.Second

// ErrNoConversationText is what a regeneration reports when the Agent has not
// yet exchanged a user and an assistant message, which is the least a title can
// be written from. Clients keep the action disabled in that state; this error is
// for a request that raced it.
var ErrNoConversationText = errors.New("the conversation has no user and assistant text yet")

// RegenerateSessionTitle names one Session from the newest texts of its Agent
// conversation and writes the result the way a manual rename does.
//
// It is an explicit user action, so it needs a configured title endpoint but not
// the automatic-naming switch, and it overwrites whatever title the Session
// shows, including a manual one: the user asked for it.
func (s *Service) RegenerateSessionTitle(ctx context.Context, sessionID string) (string, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return "", errors.New("session ID is required")
	}
	if _, ok := s.Session(sessionID); !ok {
		return "", fmt.Errorf("session not found: %s", sessionID)
	}
	if !s.titleEndpointConfigured() {
		return "", errors.New("session title generation is not configured")
	}
	// Capture the conversation generation before the request leaves, so a name
	// that outlives a `/clear`, `/new`, or provider rebind cannot label the
	// conversation that replaced it.
	generation := s.conversationGeneration(sessionID)
	input := sessiontitle.NewConversationInput(conversationTexts(s.agentHistory(sessionID)))
	if !input.HasExchange() {
		return "", ErrNoConversationText
	}
	requestContext, cancel := context.WithTimeout(ctx, regenerateTitleTimeout)
	defer cancel()
	titleValue, err := (sessiontitle.Generator{Config: s.titleConfig()}).GenerateConversation(requestContext, input)
	if err != nil {
		return "", fmt.Errorf("regenerate session title: %w", err)
	}
	if err := s.applyRegeneratedTitle(sessionID, generation, titleValue); err != nil {
		return "", err
	}
	return titleValue, nil
}

// conversationGeneration is the Host-owned identity of the conversation a
// Session is bound to right now.
func (s *Service) conversationGeneration(sessionID string) string {
	entry := s.agentEntry(sessionID)
	if entry == nil {
		return ""
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return strings.TrimSpace(entry.executionID)
}

// applyRegeneratedTitle persists a name the user asked for. It is a rename like
// any other, so it overwrites what the Session shows and becomes its title from
// then on.
func (s *Service) applyRegeneratedTitle(sessionID, generation, titleValue string) error {
	applied := false
	err := s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			session := &state.Sessions[index]
			if session.ID != sessionID {
				continue
			}
			if session.Lifecycle != "running" {
				return fmt.Errorf("session is not running: %s", sessionID)
			}
			// A name written for a conversation that has been replaced must
			// never label the conversation that replaced it.
			if generation != "" && strings.TrimSpace(session.AgentExecutionID) != generation {
				return errors.New("the conversation changed before the new title arrived")
			}
			session.CustomTitle = titleValue
			applied = true
			return nil
		}
		return fmt.Errorf("session not found: %s", sessionID)
	})
	if err != nil {
		return err
	}
	if !applied {
		return fmt.Errorf("session not found: %s", sessionID)
	}
	// The result is the user's title now, so neither the agent CLI's own name
	// nor the Host's automatic request may replace it. Forgetting which title
	// the Host generated is what excludes this one from both flows.
	if entry := s.agentEntry(sessionID); entry != nil {
		entry.mu.Lock()
		entry.aiTitleValue = ""
		entry.mu.Unlock()
	}
	s.wakeLiveActivity()
	return nil
}

// sessionTitleRegeneratable reports whether a user action can name this Session
// from its conversation right now: the Agent has recorded a user and an
// assistant text, and a title endpoint is configured. It is the same readiness
// the request itself needs, so a client can disable the action instead of
// letting it fail.
func (s *Service) sessionTitleRegeneratable(sessionID string) bool {
	if !s.titleEndpointConfigured() {
		return false
	}
	entry := s.agentEntry(sessionID)
	if entry == nil {
		return false
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return strings.TrimSpace(entry.titleUser) != "" && strings.TrimSpace(entry.titleAssistant) != ""
}

// agentEntry is the Host's live Agent projection for one Session, or nil when
// the Session has no Agent.
func (s *Service) agentEntry(sessionID string) *agentSession {
	s.lazyInit()
	s.agentsMu.Lock()
	defer s.agentsMu.Unlock()
	return s.agents[sessionID]
}

// conversationTexts projects the Host's recorded conversation onto the texts a
// regenerated title reads: user and assistant messages in the order they were
// said. Tool calls, tool output, reasoning, errors, and every other observation
// are not conversation text and stay out. A provider that streams a reply as
// deltas contributes one message rather than one per fragment.
func conversationTexts(events []api.AgentEvent) []sessiontitle.ConversationMessage {
	messages := make([]sessiontitle.ConversationMessage, 0, len(events))
	// index maps one provider message identity to its place in messages, so a
	// delta knows which message it continues.
	index := make(map[string]int, len(events))
	for _, event := range events {
		if event.Sidechain {
			// A subagent's conversation is not this conversation.
			continue
		}
		role := sessiontitle.ConversationRoleUser
		switch event.Type {
		case "user":
		case "assistant":
			role = sessiontitle.ConversationRoleAssistant
		default:
			continue
		}
		content := strings.TrimSpace(event.Content)
		if content == "" {
			continue
		}
		if role == sessiontitle.ConversationRoleUser && isTitleSystemContext(content) {
			continue
		}
		key := role + "\x00" + event.Provider + "\x00" + event.ID
		if at, ok := index[key]; ok {
			switch {
			case event.ContentDelta:
				messages[at].Text = strings.TrimSpace(messages[at].Text + event.Content)
				continue
			case messages[at].Text == content:
				// The provider re-reported a message the Host already has.
				continue
			}
		}
		messages = append(messages, sessiontitle.ConversationMessage{Role: role, Text: content})
		index[key] = len(messages) - 1
	}
	return messages
}
