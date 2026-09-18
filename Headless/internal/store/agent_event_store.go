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
	// Incremental auto-vacuum lets pruning return freed pages to the operating
	// system in bounded steps instead of rewriting the whole file. Switching a
	// database that was created without it requires one VACUUM, so it is
	// attempted here, before any caller is appending. It stays best-effort: a
	// busy database (for example an upgrade that briefly overlaps two daemons)
	// must never stop the journal from opening, and without it the file is still
	// bounded because new appends reuse the pages pruning freed.
	enableIncrementalAutoVacuum(db)

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

	-- Warren 0.17 replaced a two-table Usage projection (a daily rollup beside
	-- this intraday one) with this single table. Two materializations of one
	-- fact drifted apart in practice -- only one of them had a backfill path,
	-- so the same day answered differently depending on which the panel read --
	-- and the cached cost columns they carried went stale whenever the process
	-- that owned the in-memory "needs repricing" flag restarted. Days are now
	-- summed from these buckets and cost is derived at read time, so neither
	-- disagreement is representable. The old tables are dropped rather than
	-- migrated: their contents are recoverable from provider transcripts with
	-- the explicit Usage rebuild.
	DROP TABLE IF EXISTS agent_usage_daily;
	DROP TABLE IF EXISTS agent_usage_meta;

	-- Durable token accounting at the finest display grain: 5-minute local
	-- buckets, which clients merge into coarser points.
	--
	-- Why a separate table rather than querying the journal: journal rows are
	-- opaque event JSON with no usage columns, agent_stream_state carries a
	-- retained_from_sequence boundary that permits trimming, and a transcript
	-- rebuild replaces the stream entirely. None of that may erase spend that
	-- already happened.
	--
	-- Every column here is additive. Rates (cache hit rate, cost per call) and
	-- money are derived at read time and deliberately absent: storing a rate
	-- forces a weighted merge on every accumulate, and storing a cost means
	-- every price change has to find and restate its rows.
	CREATE TABLE IF NOT EXISTS agent_usage_interval (
		-- Local calendar day the spend is attributed to, YYYY-MM-DD. Local and
		-- not UTC because the heatmap cell has to mean the day the person
		-- remembers working; bucketing UTC and converting at read time makes
		-- every historical cell shift when the host moves timezone.
		local_day          TEXT NOT NULL,
		-- Minutes from local midnight, floored to the 5-minute base grain.
		bucket_start_min   INTEGER NOT NULL,
		provider           TEXT NOT NULL,
		-- Pricing-normalized model id, plus the provider's original spelling so
		-- an entry that fails to match a price can be diagnosed instead of
		-- silently disappearing into an unpriced bucket.
		model              TEXT NOT NULL,
		model_raw          TEXT NOT NULL,
		-- Project the spend belongs to, or '' when it cannot be attributed.
		-- Session is deliberately not a dimension: sessions are numerous and
		-- short-lived, so keying on them makes cardinality unbounded.
		project_id         TEXT NOT NULL,
		-- Offset used to derive local_day, so a later timezone change is
		-- detectable. Diagnostic only, which is why it is not part of the key.
		utc_offset_min     INTEGER NOT NULL DEFAULT 0,
		calls              INTEGER NOT NULL DEFAULT 0,
		-- The four disjoint token buckets. They sum to the real total, so the
		-- provider's own input/total counters are intentionally not stored:
		-- input has no consistent cross-provider meaning and total is derivable.
		fresh_input        INTEGER NOT NULL DEFAULT 0,
		cache_write        INTEGER NOT NULL DEFAULT 0,
		cache_read         INTEGER NOT NULL DEFAULT 0,
		output             INTEGER NOT NULL DEFAULT 0,
		-- Reasoning subset of output. Display only; billed inside output.
		reasoning          INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY (local_day, bucket_start_min, provider, model, model_raw, project_id)
	);
	CREATE INDEX IF NOT EXISTS idx_agent_usage_interval_day
	ON agent_usage_interval(local_day, bucket_start_min);

	-- One row per billable model call already counted above.
	--
	-- This is what makes accounting idempotent, and it has to be durable
	-- because the repeats it guards against span processes: a resumed
	-- conversation copies its history into a new transcript that Warren binds
	-- to a new stream, and a Usage rebuild re-reads files the live watcher
	-- already consumed. Parser-local memory cannot see either repeat.
	--
	-- The key is stored as a 64-bit fingerprint of provider plus the provider's
	-- own call key rather than the key itself, because the keys are long and the
	-- table gets one row per call for as long as usage is retained.
	CREATE TABLE IF NOT EXISTS agent_usage_call (
		fingerprint  INTEGER PRIMARY KEY,
		provider     TEXT NOT NULL,
		-- The day the call was counted under, so pruning a day's usage can drop
		-- its fingerprints with it.
		local_day    TEXT NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_agent_usage_call_provider
	ON agent_usage_call(provider);

	-- When the Usage projection was last replaced, and for which providers.
	--
	-- A rebuild is the only operation that corrects historical counting, so how
	-- long ago it ran is part of reading the numbers: a panel showing figures
	-- produced by a parser from three releases ago looks identical to one showing
	-- current figures. The scope is stored with the time because a rebuild only
	-- replaces providers this Host can re-read, so "rebuilt an hour ago" is only
	-- true of the listed ones.
	--
	-- One row, pinned by a constant primary key. Per-provider rows would be the
	-- more precise shape, but nothing reads staleness per provider and every
	-- caller would have to re-derive the same single answer from them.
	CREATE TABLE IF NOT EXISTS agent_usage_rebuild (
		id            INTEGER PRIMARY KEY CHECK (id = 1),
		completed_at  TEXT NOT NULL,
		providers     TEXT NOT NULL,
		calls         INTEGER NOT NULL DEFAULT 0
	);
`
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("init canonical Agent schema: %w", err)
	}
	return &AgentEventStore{db: db}, nil
}

func enableIncrementalAutoVacuum(db *sql.DB) {
	var mode int
	if err := db.QueryRow("PRAGMA auto_vacuum").Scan(&mode); err != nil || mode == 2 {
		return
	}
	if _, err := db.Exec("PRAGMA auto_vacuum=INCREMENTAL;"); err != nil {
		return
	}
	// Required for the setting to take effect on a database that already has
	// tables. It is instant on a fresh journal.
	_, _ = db.Exec("VACUUM;")
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
