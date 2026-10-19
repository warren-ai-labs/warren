package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
)

// conversationTitleSchema keeps the last title shown for each provider
// conversation. It is keyed by the provider's own conversation ID rather than
// the Warren Session, so resuming the conversation in any Session can show the
// title it had before. One row per conversation: a newer title replaces it.
const conversationTitleSchema = `
	CREATE TABLE IF NOT EXISTS agent_conversation_title (
		provider          TEXT NOT NULL,
		agent_session_id  TEXT NOT NULL,
		title             TEXT NOT NULL,
		updated_at        TEXT NOT NULL,
		PRIMARY KEY (provider, agent_session_id)
	);
`

// ConversationTitle returns the stored title of one provider conversation, or
// false when none was recorded.
func (s *AgentEventStore) ConversationTitle(ctx context.Context, provider, agentSessionID string) (string, bool, error) {
	provider, agentSessionID = strings.TrimSpace(provider), strings.TrimSpace(agentSessionID)
	if provider == "" || agentSessionID == "" {
		return "", false, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return "", false, nil
	}
	var title string
	err := s.db.QueryRowContext(ctx, `
		SELECT title FROM agent_conversation_title
		WHERE provider = ? AND agent_session_id = ?`, provider, agentSessionID).Scan(&title)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return title, true, nil
}

// SetConversationTitle records the latest title of one provider conversation,
// replacing any earlier one.
func (s *AgentEventStore) SetConversationTitle(ctx context.Context, provider, agentSessionID, title string, now time.Time) error {
	provider, agentSessionID, title = strings.TrimSpace(provider), strings.TrimSpace(agentSessionID), strings.TrimSpace(title)
	if provider == "" || agentSessionID == "" || title == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO agent_conversation_title (provider, agent_session_id, title, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (provider, agent_session_id) DO UPDATE SET
			title = excluded.title,
			updated_at = excluded.updated_at`,
		provider, agentSessionID, title, now.UTC().Format(time.RFC3339Nano))
	return err
}
