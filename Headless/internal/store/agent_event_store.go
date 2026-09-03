package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	_ "github.com/ncruces/go-sqlite3/driver"
)

// AgentEventStore persists normalized agent events into a local SQLite database,
// providing monotonically increasing sequence assignment and indexed range queries.
type AgentEventStore struct {
	mu sync.RWMutex
	db *sql.DB
}

const (
	defaultHistoryLimit = 100
	maxHistoryLimit     = 1000
)

// OpenAgentEventStore opens or creates the SQLite event database at dbPath.
func OpenAgentEventStore(dbPath string) (*AgentEventStore, error) {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		return nil, fmt.Errorf("create agent store directory: %w", err)
	}

	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open agent event sqlite: %w", err)
	}

	// Performance & durability pragmas for single-daemon embedded SQLite
	pragmas := []string{
		"PRAGMA journal_mode=WAL;",
		"PRAGMA busy_timeout=5000;",
		"PRAGMA synchronous=NORMAL;",
	}
	for _, pragma := range pragmas {
		if _, err := db.Exec(pragma); err != nil {
			db.Close()
			return nil, fmt.Errorf("exec %s: %w", pragma, err)
		}
	}

	schema := `
	CREATE TABLE IF NOT EXISTS agent_events (
		session_id    TEXT NOT NULL,
		epoch         INTEGER NOT NULL,
		sequence      INTEGER NOT NULL,
		turn          INTEGER,
		id            TEXT,
		type          TEXT NOT NULL,
		role          TEXT,
		content       TEXT,
		content_delta INTEGER DEFAULT 0,
		tool_name     TEXT,
		tool_status   TEXT,
		call_id       TEXT,
		raw_json      TEXT NOT NULL,
		created_at    INTEGER NOT NULL,
		PRIMARY KEY (session_id, epoch, sequence)
	);

	CREATE INDEX IF NOT EXISTS idx_agent_events_seq 
	ON agent_events(session_id, epoch, sequence ASC);

	CREATE TABLE IF NOT EXISTS agent_session_state (
		session_id   TEXT NOT NULL,
		epoch        INTEGER NOT NULL,
		max_sequence INTEGER NOT NULL DEFAULT 0,
		status_json  TEXT,
		updated_at   INTEGER NOT NULL,
		PRIMARY KEY (session_id, epoch)
	);
	`
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("init agent store schema: %w", err)
	}

	return &AgentEventStore{db: db}, nil
}

// Close closes the underlying database.
func (s *AgentEventStore) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		return s.db.Close()
	}
	return nil
}

// AppendEvents atomically appends incoming events to the database, ensuring each
// event has a strictly monotonic sequence number assigned.
func (s *AgentEventStore) AppendEvents(
	ctx context.Context,
	sessionID string,
	epoch uint64,
	events []api.AgentEvent,
	status api.AgentStatus,
) ([]api.AgentEvent, error) {
	if len(events) == 0 {
		return nil, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin append tx: %w", err)
	}
	defer tx.Rollback()

	var maxSeq uint64
	err = tx.QueryRowContext(ctx,
		`SELECT max_sequence FROM agent_session_state WHERE session_id = ? AND epoch = ?`,
		sessionID, epoch,
	).Scan(&maxSeq)
	if err != nil && err != sql.ErrNoRows {
		return nil, fmt.Errorf("read max sequence: %w", err)
	}

	stmt, err := tx.PrepareContext(ctx, `
		INSERT OR REPLACE INTO agent_events (
			session_id, epoch, sequence, turn, id, type, role,
			content, content_delta, tool_name, tool_status, call_id,
			raw_json, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`)
	if err != nil {
		return nil, fmt.Errorf("prepare insert event: %w", err)
	}
	defer stmt.Close()

	assigned := make([]api.AgentEvent, len(events))
	now := time.Now().UnixMilli()

	for i, event := range events {
		if event.Sequence == 0 {
			maxSeq++
			event.Sequence = maxSeq
		} else if event.Sequence > maxSeq {
			maxSeq = event.Sequence
		}

		delta := 0
		if event.ContentDelta {
			delta = 1
		}

		rawJSON, err := json.Marshal(event)
		if err != nil {
			return nil, fmt.Errorf("marshal event %d: %w", event.Sequence, err)
		}

		_, err = stmt.ExecContext(ctx,
			sessionID, epoch, event.Sequence, event.Turn, event.ID, event.Type, event.Role,
			event.Content, delta, event.ToolName, event.ToolStatus, event.CallID,
			string(rawJSON), now,
		)
		if err != nil {
			return nil, fmt.Errorf("exec insert event %d: %w", event.Sequence, err)
		}

		assigned[i] = event
	}

	statusJSON, _ := json.Marshal(status)
	_, err = tx.ExecContext(ctx, `
		INSERT INTO agent_session_state (session_id, epoch, max_sequence, status_json, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(session_id, epoch) DO UPDATE SET
			max_sequence = excluded.max_sequence,
			status_json = excluded.status_json,
			updated_at = excluded.updated_at
	`, sessionID, epoch, maxSeq, string(statusJSON), now)
	if err != nil {
		return nil, fmt.Errorf("update session state: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit append tx: %w", err)
	}

	return assigned, nil
}

// QueryEvents queries events within sequence bounds.
// - If sinceSeq > 0 and beforeSeq > 0: returns events with sinceSeq <= sequence < beforeSeq (ascending).
// - If sinceSeq > 0 and beforeSeq == 0: returns events with sequence >= sinceSeq (ascending).
// - If sinceSeq == 0 and beforeSeq > 0: returns events with sequence < beforeSeq (ascending, last limit events).
// - If sinceSeq == 0 and beforeSeq == 0: returns latest limit events (ascending).
func (s *AgentEventStore) QueryEvents(
	ctx context.Context,
	sessionID string,
	epoch uint64,
	sinceSeq uint64,
	beforeSeq uint64,
	limit int,
) ([]api.AgentEvent, bool, error) {
	if limit <= 0 {
		limit = defaultHistoryLimit
	}
	if limit > maxHistoryLimit {
		limit = maxHistoryLimit
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	var query string
	var args []any

	if sinceSeq > 0 && beforeSeq > 0 {
		query = `
			SELECT raw_json FROM agent_events
			WHERE session_id = ? AND epoch = ? AND sequence >= ? AND sequence < ?
			ORDER BY sequence ASC
			LIMIT ?
		`
		args = []any{sessionID, epoch, sinceSeq, beforeSeq, limit + 1}
	} else if sinceSeq > 0 && beforeSeq == 0 {
		query = `
			SELECT raw_json FROM agent_events
			WHERE session_id = ? AND epoch = ? AND sequence >= ?
			ORDER BY sequence ASC
			LIMIT ?
		`
		args = []any{sessionID, epoch, sinceSeq, limit + 1}
	} else if sinceSeq == 0 && beforeSeq > 0 {
		query = `
			SELECT raw_json FROM (
				SELECT sequence, raw_json FROM agent_events
				WHERE session_id = ? AND epoch = ? AND sequence < ?
				ORDER BY sequence DESC
				LIMIT ?
			)
			ORDER BY sequence ASC
		`
		args = []any{sessionID, epoch, beforeSeq, limit}
	} else {
		query = `
			SELECT raw_json FROM (
				SELECT sequence, raw_json FROM agent_events
				WHERE session_id = ? AND epoch = ?
				ORDER BY sequence DESC
				LIMIT ?
			)
			ORDER BY sequence ASC
		`
		args = []any{sessionID, epoch, limit}
	}

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, false, fmt.Errorf("query agent events: %w", err)
	}
	defer rows.Close()

	var rawRows []string
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, false, fmt.Errorf("scan event row: %w", err)
		}
		rawRows = append(rawRows, raw)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}

	var hasMore bool
	if sinceSeq > 0 {
		if len(rawRows) > limit {
			hasMore = true
			rawRows = rawRows[:limit]
		}
	} else {
		// When querying backwards (beforeSeq > 0 or latest), check if older events exist
		if len(rawRows) > 0 {
			var firstSeq uint64
			var temp api.AgentEvent
			if err := json.Unmarshal([]byte(rawRows[0]), &temp); err == nil {
				firstSeq = temp.Sequence
			}
			if firstSeq > 1 {
				var count int
				_ = s.db.QueryRowContext(ctx,
					`SELECT COUNT(1) FROM agent_events WHERE session_id = ? AND epoch = ? AND sequence < ?`,
					sessionID, epoch, firstSeq,
				).Scan(&count)
				hasMore = count > 0
			}
		}
	}

	events := make([]api.AgentEvent, len(rawRows))
	for i, raw := range rawRows {
		if err := json.Unmarshal([]byte(raw), &events[i]); err != nil {
			return nil, false, fmt.Errorf("unmarshal event json: %w", err)
		}
	}

	return events, hasMore, nil
}

// MaxSequence returns the highest sequence recorded for this session and epoch.
func (s *AgentEventStore) MaxSequence(ctx context.Context, sessionID string, epoch uint64) (uint64, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var maxSeq uint64
	err := s.db.QueryRowContext(ctx,
		`SELECT max_sequence FROM agent_session_state WHERE session_id = ? AND epoch = ?`,
		sessionID, epoch,
	).Scan(&maxSeq)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return maxSeq, nil
}

// ClearSession clears all stored events for a session across all epochs.
func (s *AgentEventStore) ClearSession(ctx context.Context, sessionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `DELETE FROM agent_events WHERE session_id = ?`, sessionID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM agent_session_state WHERE session_id = ?`, sessionID); err != nil {
		return err
	}
	return tx.Commit()
}
