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
	// usageAttribution resolves the project a spend row belongs to. The journal
	// has no host-state dependency of its own, so the Service injects this and
	// usage accumulation stays inert until it does.
	usageAttribution UsageAttributionResolver
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

	-- Durable token accounting, aggregated per local day.
	--
	-- Why a separate table rather than querying the journal: journal rows are
	-- opaque event JSON with no usage columns, agent_stream_state carries a
	-- retained_from_sequence boundary that permits trimming, and a transcript
	-- rebuild replaces the stream entirely. None of that may erase spend that
	-- already happened.
	--
	-- Every column here is additive. Rates (cache hit rate, cost per call) are
	-- derived at read time from these sums and are deliberately absent: storing
	-- a rate forces a weighted merge on every accumulate, which is where this
	-- kind of table usually starts drifting.
	CREATE TABLE IF NOT EXISTS agent_usage_daily (
		-- Local calendar day the spend is attributed to, YYYY-MM-DD. Local and
		-- not UTC because the heatmap cell has to mean the day the person
		-- remembers working; bucketing UTC and converting at read time makes
		-- every historical cell shift when the host moves timezone.
		local_day       TEXT NOT NULL,
		provider        TEXT NOT NULL,
		-- Pricing-normalized model id, plus the provider's original spelling so
		-- an entry that fails to match a price can be diagnosed instead of
		-- silently disappearing into an unpriced bucket.
		model           TEXT NOT NULL,
		model_raw       TEXT NOT NULL,
		-- Project the spend belongs to, or '' when it cannot be attributed.
		-- Session is deliberately not a dimension: sessions are numerous and
		-- short-lived, so keying on them makes cardinality unbounded.
		project_id      TEXT NOT NULL,
		-- Offset used to derive local_day, so a later timezone change is
		-- detectable. Diagnostic only, which is why it is not part of the key.
		utc_offset_min  INTEGER NOT NULL DEFAULT 0,
		calls           INTEGER NOT NULL DEFAULT 0,
		-- The four disjoint token buckets. They sum to the real total, so the
		-- provider's own input/total counters are intentionally not stored:
		-- input has no consistent cross-provider meaning and total is derivable.
		fresh_input     INTEGER NOT NULL DEFAULT 0,
		cache_write     INTEGER NOT NULL DEFAULT 0,
		cache_read      INTEGER NOT NULL DEFAULT 0,
		output          INTEGER NOT NULL DEFAULT 0,
		-- Reasoning subset of output. Display only; billed inside output.
		reasoning       INTEGER NOT NULL DEFAULT 0,
		-- Cost cache in integer nanodollars, filled by the pricing pass rather
		-- than at append time: models.dev prices change, and an integer keeps
		-- the column addable without the float drift a decimal-as-text column
		-- reintroduces the moment it is summed.
		cost_nano_usd   INTEGER NOT NULL DEFAULT 0,
		-- Calls within this row that had a known price. Less than calls means
		-- the row's cost is a lower bound and must render as such.
		priced_calls    INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY (local_day, provider, model, model_raw, project_id)
	);
	CREATE INDEX IF NOT EXISTS idx_agent_usage_daily_day
	ON agent_usage_daily(local_day);

	-- Durable intraday token accounting at the finest display grain. The Host
	-- writes 5-minute buckets and the client may merge adjacent buckets into
	-- one-hour points. Like the daily table, this is independent of the
	-- retained journal so trimming or rebuilding a transcript cannot erase the
	-- usage curve.
	CREATE TABLE IF NOT EXISTS agent_usage_interval (
		local_day          TEXT NOT NULL,
		-- Minutes from local midnight, floored to the 5-minute base grain.
		bucket_start_min   INTEGER NOT NULL,
		provider           TEXT NOT NULL,
		model              TEXT NOT NULL,
		model_raw          TEXT NOT NULL,
		project_id         TEXT NOT NULL,
		utc_offset_min     INTEGER NOT NULL DEFAULT 0,
		calls              INTEGER NOT NULL DEFAULT 0,
		fresh_input        INTEGER NOT NULL DEFAULT 0,
		cache_write        INTEGER NOT NULL DEFAULT 0,
		cache_read         INTEGER NOT NULL DEFAULT 0,
		output             INTEGER NOT NULL DEFAULT 0,
		reasoning          INTEGER NOT NULL DEFAULT 0,
		cost_nano_usd      INTEGER NOT NULL DEFAULT 0,
		priced_calls       INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY (local_day, bucket_start_min, provider, model, model_raw, project_id)
	);
	CREATE INDEX IF NOT EXISTS idx_agent_usage_interval_day
	ON agent_usage_interval(local_day, bucket_start_min);

	-- Deliberately separate from the canonical journal. Maintenance operations
	-- may replace Usage projections without touching the Agent event history.
	CREATE TABLE IF NOT EXISTS agent_usage_meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
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
