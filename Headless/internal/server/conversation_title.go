package server

import (
	"context"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// conversationTitleObservation is what syncConversationTitles last saw of one
// Session: which provider conversation it was bound to, and the title already
// recorded for or restored to that conversation.
type conversationTitleObservation struct {
	key   string
	title string
}

func conversationTitleKey(provider, agentSessionID string) string {
	return provider + "\x00" + agentSessionID
}

// syncConversationTitles keeps one durable title per provider conversation, so
// a conversation resumed later, in this Session or another, shows the title it
// had before instead of waiting for a new one.
//
// It runs on the lifecycle tick and compares each Session with its previous
// observation. A newly bound conversation with no title gets its stored title
// back. A title that changes while the conversation stays bound is recorded,
// whichever path set it: a rename, the Host's request, or the agent CLI.
func (s *Service) syncConversationTitles() {
	if s.Store == nil {
		return
	}
	state := s.Store.Snapshot()
	s.conversationTitlesMu.Lock()
	defer s.conversationTitlesMu.Unlock()
	if s.conversationTitles == nil {
		s.conversationTitles = map[string]conversationTitleObservation{}
	}
	seen := make(map[string]bool, len(state.Sessions))
	for _, session := range state.Sessions {
		if session.Lifecycle != "running" {
			continue
		}
		provider := agentProviderForKind(session.AgentProvider)
		if provider == "" {
			provider = agentProviderForKind(session.Kind)
		}
		agentSessionID := strings.TrimSpace(session.AgentSessionID)
		if provider == "" || agentSessionID == "" {
			continue
		}
		seen[session.ID] = true
		key := conversationTitleKey(provider, agentSessionID)
		title := strings.TrimSpace(session.CustomTitle)
		previous, observed := s.conversationTitles[session.ID]
		if observed && previous.key == key {
			if title != "" && title != previous.title && s.recordConversationTitle(provider, agentSessionID, title) {
				s.conversationTitles[session.ID] = conversationTitleObservation{key: key, title: title}
			}
			continue
		}
		observation := conversationTitleObservation{key: key, title: title}
		switch {
		case title == "":
			if stored := s.storedConversationTitle(provider, agentSessionID); stored != "" &&
				s.restoreConversationTitle(session.ID, agentSessionID, stored) {
				observation.title = stored
			}
		case !observed:
			// The first observation after the Host starts: the binding did not
			// change, so the title belongs to this conversation.
			if !s.recordConversationTitle(provider, agentSessionID, title) {
				observation.title = ""
			}
		}
		// Otherwise the conversation changed while the previous one's title is
		// still showing. It is recorded only once a title of its own replaces it.
		s.conversationTitles[session.ID] = observation
	}
	for sessionID := range s.conversationTitles {
		if !seen[sessionID] {
			delete(s.conversationTitles, sessionID)
		}
	}
}

func (s *Service) storedConversationTitle(provider, agentSessionID string) string {
	journal := s.agentStore()
	if journal == nil {
		return ""
	}
	title, _, err := journal.ConversationTitle(context.Background(), provider, agentSessionID)
	if err != nil {
		s.logWarn("read conversation title", "provider", provider, "error", err)
		return ""
	}
	return strings.TrimSpace(title)
}

func (s *Service) recordConversationTitle(provider, agentSessionID, title string) bool {
	journal := s.agentStore()
	if journal == nil {
		return false
	}
	if err := journal.SetConversationTitle(context.Background(), provider, agentSessionID, title, time.Now()); err != nil {
		s.logWarn("record conversation title", "provider", provider, "error", err)
		return false
	}
	return true
}

// restoreConversationTitle shows a stored title on a Session that is still
// bound to that conversation and has no title of its own yet.
func (s *Service) restoreConversationTitle(sessionID, agentSessionID, title string) bool {
	restored := false
	err := s.Store.Update(func(state *api.State) error {
		for index := range state.Sessions {
			session := &state.Sessions[index]
			if session.ID != sessionID {
				continue
			}
			if session.Lifecycle == "running" && strings.TrimSpace(session.CustomTitle) == "" &&
				strings.TrimSpace(session.AgentSessionID) == agentSessionID {
				session.CustomTitle = title
				restored = true
			}
			return nil
		}
		return nil
	})
	if err != nil {
		s.logWarn("restore conversation title", "session", sessionID, "error", err)
		return false
	}
	if restored {
		s.wakeLiveActivity()
	}
	return restored
}
