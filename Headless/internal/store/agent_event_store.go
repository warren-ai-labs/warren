package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	_ "github.com/ncruces/go-sqlite3/driver"
)

// AgentEventStore is the durable Host-owned canonical Agent journal.
//
// Protocol 4 starts a clean data boundary: canonical stream rows and command
// admission records are the only persisted Agent state.
type AgentEventStore struct {
	mu sync.RWMutex
	db *sql.DB
}

const (
	defaultHistoryLimit = 100
	maxHistoryLimit     = 1000
)

// OpenAgentEventStore opens the canonical Agent journal database.
func OpenAgentEventStore(dbPath string) (*AgentEventStore, error) {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		return nil, fmt.Errorf("create agent store directory: %w", err)
	}

	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open agent event sqlite: %w", err)
	}
	pragmas := []string{
		"PRAGMA journal_mode=WAL;",
		"PRAGMA busy_timeout=5000;",
		"PRAGMA synchronous=NORMAL;",
	}
	for _, pragma := range pragmas {
		if _, err := db.Exec(pragma); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("exec %s: %w", pragma, err)
		}
	}

	schema := `
	CREATE TABLE IF NOT EXISTS agent_event_journal (
		stream_id      TEXT NOT NULL,
		execution_id   TEXT NOT NULL,
		sequence       INTEGER NOT NULL,
		event_id       TEXT NOT NULL,
		event_type     TEXT NOT NULL,
		event_json     TEXT NOT NULL,
		recorded_at    INTEGER NOT NULL,
		PRIMARY KEY (stream_id, sequence),
		UNIQUE (stream_id, event_id)
	);
	CREATE INDEX IF NOT EXISTS idx_agent_event_journal_event
	ON agent_event_journal(stream_id, event_id);

	CREATE TABLE IF NOT EXISTS agent_stream_state (
		stream_id              TEXT NOT NULL PRIMARY KEY,
		execution_id           TEXT NOT NULL,
		retained_from_sequence INTEGER NOT NULL DEFAULT 0,
		head_sequence         INTEGER NOT NULL DEFAULT 0,
		checkpoint_sequence    INTEGER NOT NULL DEFAULT 0,
		checkpoint_json        TEXT,
		updated_at             INTEGER NOT NULL
	);

	CREATE TABLE IF NOT EXISTS agent_command_journal (
		execution_id  TEXT NOT NULL,
		command_id    TEXT NOT NULL,
		fingerprint   TEXT NOT NULL,
		status        TEXT NOT NULL,
		result_json   TEXT,
		error_text    TEXT,
		created_at    INTEGER NOT NULL,
		completed_at  INTEGER,
		PRIMARY KEY (execution_id, command_id)
	);
`
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("init canonical Agent schema: %w", err)
	}
	return &AgentEventStore{db: db}, nil
}

// Close closes the underlying database.
func (s *AgentEventStore) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil
	}
	err := s.db.Close()
	s.db = nil
	return err
}
