package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

// PruneResult describes one bounded pruning step over the canonical journal.
type PruneResult struct {
	// StreamID is the stream the step touched. Empty means nothing was
	// eligible.
	StreamID string
	// DeletedRows is the number of event rows removed by this step.
	DeletedRows int64
	// StreamRemoved is true when the stream held no further rows, so its stream
	// state and completed command records were removed as well.
	StreamRemoved bool
	// More reports whether another eligible stream still exists, so a caller
	// can keep stepping without re-deriving the candidate set.
	More bool
}

// PruneStreamsStep removes up to maxRows events from one eligible stream in a
// single transaction.
//
// A stream is eligible when it has not been written since cutoffMs and is not
// listed in protect, which carries the execution ids still reachable from a
// live Session. Rows are removed in bounded chunks rather than all at once
// because one stream can hold tens of thousands of rows, and deleting those in
// one transaction would hold the store write lock long enough to stall live
// appends and history reads.
//
// The store is opened with incremental auto-vacuum, so callers that care about
// releasing the freed pages should call ReclaimSpace once stepping is done.
func (s *AgentEventStore) PruneStreamsStep(
	ctx context.Context,
	protect map[string]struct{},
	cutoffMs int64,
	maxRows int,
) (PruneResult, error) {
	if maxRows <= 0 {
		maxRows = 2000
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return PruneResult{}, nil
	}

	streamID, err := selectPrunableStream(ctx, s.db, protect, cutoffMs)
	if err != nil || streamID == "" {
		return PruneResult{}, err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PruneResult{}, fmt.Errorf("begin journal prune tx: %w", err)
	}
	defer tx.Rollback()

	deleted, err := pruneEventRows(ctx, tx, streamID, maxRows)
	if err != nil {
		return PruneResult{}, err
	}
	result := PruneResult{StreamID: streamID, DeletedRows: deleted}

	remaining, err := streamHasRows(ctx, tx, streamID)
	if err != nil {
		return PruneResult{}, err
	}
	if !remaining {
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM agent_stream_state WHERE stream_id = ?`, streamID); err != nil {
			return PruneResult{}, fmt.Errorf("delete pruned stream state: %w", err)
		}
		// Pending and unknown admissions are deliberately kept. They record
		// that a provider side effect may already have happened, so they must
		// never be silently dropped and later replayed.
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM agent_command_journal WHERE execution_id = ? AND status IN (?, ?)`,
			streamID, CanonicalCommandCompleted, CanonicalCommandFailed,
		); err != nil {
			return PruneResult{}, fmt.Errorf("delete pruned command records: %w", err)
		}
		result.StreamRemoved = true
	}
	if err := tx.Commit(); err != nil {
		return PruneResult{}, fmt.Errorf("commit journal prune tx: %w", err)
	}

	next, err := selectPrunableStream(ctx, s.db, protect, cutoffMs)
	if err != nil {
		return result, err
	}
	result.More = next != ""
	return result, nil
}

// ReclaimSpace returns up to maxPages of the pages freed by pruning to the
// operating system. The journal is opened with incremental auto-vacuum, so
// this moves bounded pages rather than rewriting the whole file the way VACUUM
// does. maxPages is bounded by the caller because an unbounded
// incremental_vacuum can free the entire freelist in one transaction and hold
// the store write lock for seconds. It is a no-op when auto-vacuum is off.
func (s *AgentEventStore) ReclaimSpace(ctx context.Context, maxPages int) error {
	if maxPages <= 0 {
		maxPages = 2000
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, fmt.Sprintf("PRAGMA incremental_vacuum(%d);", maxPages)); err != nil {
		return fmt.Errorf("incremental vacuum journal: %w", err)
	}
	return nil
}

func selectPrunableStream(
	ctx context.Context,
	db *sql.DB,
	protect map[string]struct{},
	cutoffMs int64,
) (string, error) {
	query := `SELECT stream_id FROM agent_stream_state WHERE updated_at < ?`
	args := []any{cutoffMs}
	placeholders := make([]string, 0, len(protect))
	for id := range protect {
		if strings.TrimSpace(id) == "" {
			continue
		}
		placeholders = append(placeholders, "?")
		args = append(args, id)
	}
	if len(placeholders) > 0 {
		query += ` AND stream_id NOT IN (` + strings.Join(placeholders, ",") + `)`
	}
	// Oldest first, so one stream is drained before the next is started and a
	// partially pruned stream is always resumed.
	query += ` ORDER BY updated_at ASC LIMIT 1`

	var streamID string
	err := db.QueryRowContext(ctx, query, args...).Scan(&streamID)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("select prunable stream: %w", err)
	}
	return streamID, nil
}

func pruneEventRows(ctx context.Context, tx *sql.Tx, streamID string, maxRows int) (int64, error) {
	result, err := tx.ExecContext(ctx, `
		DELETE FROM agent_event_journal
		WHERE stream_id = ? AND sequence IN (
			SELECT sequence FROM agent_event_journal WHERE stream_id = ? ORDER BY sequence LIMIT ?
		)
	`, streamID, streamID, maxRows)
	if err != nil {
		return 0, fmt.Errorf("delete pruned journal rows: %w", err)
	}
	return result.RowsAffected()
}

func streamHasRows(ctx context.Context, tx *sql.Tx, streamID string) (bool, error) {
	var exists int
	if err := tx.QueryRowContext(ctx,
		`SELECT EXISTS(SELECT 1 FROM agent_event_journal WHERE stream_id = ? LIMIT 1)`,
		streamID,
	).Scan(&exists); err != nil {
		return false, fmt.Errorf("check pruned stream rows: %w", err)
	}
	return exists == 1, nil
}
