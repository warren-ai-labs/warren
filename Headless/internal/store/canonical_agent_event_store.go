package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Canonical event persistence is the only Host-owned Agent journal.

var (
	ErrCanonicalSequenceConflict = errors.New("canonical agent event sequence conflict")
	ErrCanonicalEventConflict    = errors.New("canonical agent event identity conflict")
	ErrCanonicalHistoryBoundary  = errors.New("canonical agent history boundary")
	ErrCanonicalCommandConflict  = errors.New("canonical agent command identity conflict")
	ErrCanonicalCommandPending   = errors.New("canonical agent command is pending")
	ErrCanonicalCommandUnknown   = errors.New("canonical agent command outcome is unknown")
)

// CanonicalCommandRecord is the durable admission record for one mutation.
// Result is decoded as generic JSON because command result types belong to the
// wire method, not to the journal. A pending row means another Host process
// may still be executing the command; it is never re-run implicitly.
type CanonicalCommandRecord struct {
	ExecutionID string
	CommandID   string
	Fingerprint string
	Status      string
	Result      any
	Error       string
	CreatedAt   int64
}

const (
	CanonicalCommandPending   = "pending"
	CanonicalCommandCompleted = "completed"
	CanonicalCommandFailed    = "failed"
	// CanonicalCommandUnknown means the Host stopped after durable admission
	// but before recording a result. It must never be re-executed implicitly:
	// the provider side effect may already have happened.
	CanonicalCommandUnknown = "unknown"
)

// CanonicalHistoryBoundary carries the first sequence still retained by the
// Host. Callers should return this as a structured history_boundary error and
// install a replacement checkpoint rather than guessing a cursor.
type CanonicalHistoryBoundary struct {
	StreamID             string
	RetainedFromSequence uint64
	HeadSequence         uint64
	CheckpointSequence   uint64
	Checkpoint           map[string]any
}

func (e *CanonicalHistoryBoundary) Error() string {
	if e == nil {
		return ErrCanonicalHistoryBoundary.Error()
	}
	return fmt.Sprintf("agent history for %s is retained from sequence %d", e.StreamID, e.RetainedFromSequence)
}

// GetCanonicalCommand returns the durable admission record for one command.
// The boolean is false when the command has never been admitted.
func (s *AgentEventStore) GetCanonicalCommand(
	ctx context.Context,
	executionID, commandID string,
) (CanonicalCommandRecord, bool, error) {
	executionID = strings.TrimSpace(executionID)
	commandID = strings.TrimSpace(commandID)
	if executionID == "" || commandID == "" {
		return CanonicalCommandRecord{}, false, errors.New("canonical command executionId and commandId are required")
	}

	s.mu.RLock()
	defer s.mu.RUnlock()
	return queryCanonicalCommand(ctx, s.db, executionID, commandID)
}

// BeginCanonicalCommand atomically admits a command. The caller becomes the
// leader only when it inserted a new pending row. A completed or failed row is
// returned for idempotent replay; a pending row belongs to another attempt.
func (s *AgentEventStore) BeginCanonicalCommand(
	ctx context.Context,
	executionID, commandID, fingerprint string,
) (CanonicalCommandRecord, bool, error) {
	executionID = strings.TrimSpace(executionID)
	commandID = strings.TrimSpace(commandID)
	fingerprint = strings.TrimSpace(fingerprint)
	if executionID == "" || commandID == "" || fingerprint == "" {
		return CanonicalCommandRecord{}, false, errors.New("canonical command executionId, commandId and fingerprint are required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CanonicalCommandRecord{}, false, fmt.Errorf("begin canonical command tx: %w", err)
	}
	defer tx.Rollback()
	record, found, err := queryCanonicalCommand(ctx, tx, executionID, commandID)
	if err != nil {
		return CanonicalCommandRecord{}, false, err
	}
	if found {
		if record.Fingerprint != fingerprint {
			return CanonicalCommandRecord{}, false, fmt.Errorf("%w: executionId=%s commandId=%s", ErrCanonicalCommandConflict, executionID, commandID)
		}
		return record, false, nil
	}
	now := time.Now().UTC().UnixMilli()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO agent_command_journal
		(execution_id, command_id, fingerprint, status, result_json, error_text, created_at, completed_at)
		VALUES (?, ?, ?, ?, NULL, NULL, ?, NULL)
	`, executionID, commandID, fingerprint, CanonicalCommandPending, now); err != nil {
		return CanonicalCommandRecord{}, false, fmt.Errorf("insert canonical command: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return CanonicalCommandRecord{}, false, fmt.Errorf("commit canonical command admission: %w", err)
	}
	return CanonicalCommandRecord{
		ExecutionID: executionID,
		CommandID:   commandID,
		Fingerprint: fingerprint,
		Status:      CanonicalCommandPending,
		CreatedAt:   now,
	}, true, nil
}

// CompleteCanonicalCommand records the immutable result of an admitted
// command. Completion is intentionally independent from the request context:
// a disconnected client must not leave a successful provider call pending.
func (s *AgentEventStore) CompleteCanonicalCommand(
	ctx context.Context,
	executionID, commandID, fingerprint string,
	result any,
	callErr error,
) error {
	executionID = strings.TrimSpace(executionID)
	commandID = strings.TrimSpace(commandID)
	fingerprint = strings.TrimSpace(fingerprint)
	if executionID == "" || commandID == "" || fingerprint == "" {
		return errors.New("canonical command executionId, commandId and fingerprint are required")
	}
	var encoded []byte
	var err error
	if result != nil {
		encoded, err = json.Marshal(result)
		if err != nil {
			return fmt.Errorf("marshal canonical command result: %w", err)
		}
	}
	status := CanonicalCommandCompleted
	errorText := ""
	if callErr != nil {
		status = CanonicalCommandFailed
		errorText = callErr.Error()
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin canonical command completion tx: %w", err)
	}
	defer tx.Rollback()
	var storedFingerprint, storedStatus string
	err = tx.QueryRowContext(ctx, `
		SELECT fingerprint, status FROM agent_command_journal
		WHERE execution_id = ? AND command_id = ?
	`, executionID, commandID).Scan(&storedFingerprint, &storedStatus)
	if err == sql.ErrNoRows {
		return fmt.Errorf("canonical command was not admitted: %s", commandID)
	}
	if err != nil {
		return fmt.Errorf("read canonical command completion: %w", err)
	}
	if storedFingerprint != fingerprint {
		return fmt.Errorf("%w: executionId=%s commandId=%s", ErrCanonicalCommandConflict, executionID, commandID)
	}
	if storedStatus != CanonicalCommandPending {
		return nil
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE agent_command_journal
		SET status = ?, result_json = ?, error_text = ?, completed_at = ?
		WHERE execution_id = ? AND command_id = ? AND status = ?
	`, status, nullableString(encoded), nullableString([]byte(errorText)), time.Now().UTC().UnixMilli(), executionID, commandID, CanonicalCommandPending); err != nil {
		return fmt.Errorf("update canonical command result: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit canonical command result: %w", err)
	}
	return nil
}

func queryCanonicalCommand(ctx context.Context, queryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, executionID, commandID string) (CanonicalCommandRecord, bool, error) {
	var record CanonicalCommandRecord
	var resultJSON, errorText sql.NullString
	err := queryer.QueryRowContext(ctx, `
		SELECT execution_id, command_id, fingerprint, status, result_json, error_text, created_at
		FROM agent_command_journal
		WHERE execution_id = ? AND command_id = ?
	`, executionID, commandID).Scan(
		&record.ExecutionID, &record.CommandID, &record.Fingerprint, &record.Status,
		&resultJSON, &errorText, &record.CreatedAt,
	)
	if err == sql.ErrNoRows {
		return CanonicalCommandRecord{}, false, nil
	}
	if err != nil {
		return CanonicalCommandRecord{}, false, fmt.Errorf("query canonical command: %w", err)
	}
	if resultJSON.Valid && strings.TrimSpace(resultJSON.String) != "" {
		if err := json.Unmarshal([]byte(resultJSON.String), &record.Result); err != nil {
			return CanonicalCommandRecord{}, false, fmt.Errorf("decode canonical command result: %w", err)
		}
	}
	if errorText.Valid {
		record.Error = errorText.String
	}
	return record, true, nil
}

// ReconcilePendingCanonicalCommands marks commands left pending by an older
// Host process as indeterminate. Admission is durable before the provider is
// called, so replaying such a row could duplicate a turn or an attachment;
// callers must surface the state and ask the client to issue a new command ID.
// Only rows older than maxAge are touched, so a long-running command in the
// current process is never converted while it is still executing.
func (s *AgentEventStore) ReconcilePendingCanonicalCommands(
	ctx context.Context,
	now time.Time,
	maxAge time.Duration,
) (int64, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	}
	if maxAge < 0 {
		maxAge = 0
	}
	cutoff := now.Add(-maxAge).UnixMilli()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("begin canonical command reconciliation: %w", err)
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_command_journal
		SET status = ?, error_text = ?, completed_at = ?
		WHERE status = ? AND created_at > 0 AND created_at <= ?
	`, CanonicalCommandUnknown,
		ErrCanonicalCommandUnknown.Error()+": retry with a new commandId",
		now.UnixMilli(), CanonicalCommandPending, cutoff)
	if err != nil {
		return 0, fmt.Errorf("reconcile canonical commands: %w", err)
	}
	count, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("count reconciled canonical commands: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit canonical command reconciliation: %w", err)
	}
	return count, nil
}

func nullableString(value []byte) any {
	if len(value) == 0 {
		return nil
	}
	return string(value)
}

// AppendCanonicalEvents appends one batch atomically. A zero sequence is
// assigned by the Host; explicit sequences are accepted only when they match
// an existing immutable row. Replayed event IDs and positions are idempotent,
// while a different payload at either identity is a hard integrity error.
func (s *AgentEventStore) AppendCanonicalEvents(
	ctx context.Context,
	streamID, executionID string,
	events []api.CanonicalAgentEvent,
) ([]api.CanonicalAgentEvent, error) {
	return s.appendCanonicalEvents(ctx, streamID, executionID, events, nil)
}

// AppendCanonicalEventsWithCheckpoint commits the immutable event batch and
// the replaceable projection checkpoint in the same SQLite transaction. A
// checkpoint is only written when the argument is non-nil; callers that do
// not have a projection update retain the last durable checkpoint.
func (s *AgentEventStore) AppendCanonicalEventsWithCheckpoint(
	ctx context.Context,
	streamID, executionID string,
	events []api.CanonicalAgentEvent,
	checkpoint map[string]any,
) ([]api.CanonicalAgentEvent, error) {
	return s.appendCanonicalEvents(ctx, streamID, executionID, events, checkpoint)
}

func (s *AgentEventStore) appendCanonicalEvents(
	ctx context.Context,
	streamID, executionID string,
	events []api.CanonicalAgentEvent,
	checkpoint map[string]any,
) ([]api.CanonicalAgentEvent, error) {
	streamID = strings.TrimSpace(streamID)
	executionID = strings.TrimSpace(executionID)
	if streamID == "" {
		return nil, errors.New("canonical agent streamId is required")
	}
	if executionID == "" {
		executionID = streamID
	}
	if len(events) == 0 {
		return nil, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin canonical append tx: %w", err)
	}
	defer tx.Rollback()

	var head uint64
	_ = tx.QueryRowContext(ctx,
		`SELECT head_sequence FROM agent_stream_state WHERE stream_id = ?`, streamID,
	).Scan(&head)
	if head == 0 {
		_ = tx.QueryRowContext(ctx,
			`SELECT COALESCE(MAX(sequence), 0) FROM agent_event_journal WHERE stream_id = ?`, streamID,
		).Scan(&head)
	}

	resolved := make([]api.CanonicalAgentEvent, 0, len(events))
	now := time.Now().UTC()
	for _, source := range events {
		event := source
		if strings.TrimSpace(event.StreamID) == "" {
			event.StreamID = streamID
		}
		if event.StreamID != streamID {
			return nil, fmt.Errorf("canonical event stream mismatch: %s", event.StreamID)
		}
		if strings.TrimSpace(event.ExecutionID) == "" {
			event.ExecutionID = executionID
		}
		if event.ExecutionID != executionID {
			return nil, fmt.Errorf("canonical event execution mismatch: %s", event.ExecutionID)
		}
		if event.EventID == "" {
			event.EventID = NewID()
		}
		if event.RecordedAt.IsZero() {
			event.RecordedAt = now
		}
		if event.OccurredAt.IsZero() {
			event.OccurredAt = event.RecordedAt
		}

		// An existing event ID is checked before sequence assignment. This is
		// what makes retries with a zero sequence resolve to their original
		// Host position.
		var existingSequence uint64
		var existingJSON string
		err := tx.QueryRowContext(ctx,
			`SELECT sequence, event_json FROM agent_event_journal WHERE stream_id = ? AND event_id = ?`,
			streamID, event.EventID,
		).Scan(&existingSequence, &existingJSON)
		if err == nil {
			var existing api.CanonicalAgentEvent
			if json.Unmarshal([]byte(existingJSON), &existing) != nil || !canonicalEventsEquivalent(existing, event) {
				return nil, fmt.Errorf("%w: stream=%s eventId=%s", ErrCanonicalEventConflict, streamID, event.EventID)
			}
			if event.Sequence != 0 && event.Sequence != existingSequence {
				return nil, fmt.Errorf("%w: stream=%s sequence=%d", ErrCanonicalSequenceConflict, streamID, event.Sequence)
			}
			event = existing
			resolved = append(resolved, event)
			continue
		}
		if err != sql.ErrNoRows {
			return nil, fmt.Errorf("lookup canonical event identity: %w", err)
		}

		if event.Sequence == 0 {
			head++
			event.Sequence = head
		} else {
			var positionJSON, positionEventID string
			positionErr := tx.QueryRowContext(ctx,
				`SELECT event_id, event_json FROM agent_event_journal WHERE stream_id = ? AND sequence = ?`,
				streamID, event.Sequence,
			).Scan(&positionEventID, &positionJSON)
			if positionErr == nil {
				var position api.CanonicalAgentEvent
				if json.Unmarshal([]byte(positionJSON), &position) != nil || positionEventID != event.EventID || !canonicalEventsEquivalent(position, event) {
					return nil, fmt.Errorf("%w: stream=%s sequence=%d", ErrCanonicalSequenceConflict, streamID, event.Sequence)
				}
				resolved = append(resolved, event)
				if event.Sequence > head {
					head = event.Sequence
				}
				continue
			}
			if positionErr != sql.ErrNoRows {
				return nil, fmt.Errorf("lookup canonical event position: %w", positionErr)
			}
			if event.Sequence > head {
				head = event.Sequence
			}
		}

		encoded, err := json.Marshal(event)
		if err != nil {
			return nil, fmt.Errorf("marshal canonical event %s: %w", event.EventID, err)
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO agent_event_journal
			(stream_id, execution_id, sequence, event_id, event_type, event_json, recorded_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)
		`, streamID, executionID, event.Sequence, event.EventID, event.Type, string(encoded), event.RecordedAt.UnixMilli()); err != nil {
			return nil, fmt.Errorf("insert canonical event %s: %w", event.EventID, err)
		}
		// Only newly inserted rows reach here; replays returned above. That is
		// what makes accounting idempotent without a cursor of its own, since
		// the watcher re-reads every transcript from offset zero on restart.
		if err := s.accumulateUsage(ctx, tx, streamID, event); err != nil {
			return nil, err
		}
		resolved = append(resolved, event)
	}

	var retained uint64
	_ = tx.QueryRowContext(ctx,
		`SELECT retained_from_sequence FROM agent_stream_state WHERE stream_id = ?`, streamID,
	).Scan(&retained)
	if retained == 0 {
		_ = tx.QueryRowContext(ctx,
			`SELECT COALESCE(MIN(sequence), 0) FROM agent_event_journal WHERE stream_id = ?`, streamID,
		).Scan(&retained)
	}
	checkpointSequence := uint64(0)
	var checkpointJSON any
	if checkpoint != nil {
		encoded, err := json.Marshal(checkpoint)
		if err != nil {
			return nil, fmt.Errorf("marshal canonical checkpoint: %w", err)
		}
		checkpointSequence = head
		checkpointJSON = string(encoded)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO agent_stream_state
		(stream_id, execution_id, retained_from_sequence, head_sequence, checkpoint_sequence, checkpoint_json, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(stream_id) DO UPDATE SET
			execution_id = excluded.execution_id,
			head_sequence = MAX(agent_stream_state.head_sequence, excluded.head_sequence),
			checkpoint_sequence = CASE WHEN excluded.checkpoint_sequence > 0 THEN excluded.checkpoint_sequence ELSE agent_stream_state.checkpoint_sequence END,
			checkpoint_json = CASE WHEN excluded.checkpoint_sequence > 0 THEN excluded.checkpoint_json ELSE agent_stream_state.checkpoint_json END,
			updated_at = excluded.updated_at
	`, streamID, executionID, retained, head, checkpointSequence, checkpointJSON, now.UnixMilli()); err != nil {
		return nil, fmt.Errorf("update canonical stream state: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit canonical append tx: %w", err)
	}
	return resolved, nil
}

// QueryCanonicalEvents returns an ascending page. afterSequence is exclusive;
// beforeSequence is exclusive. With neither bound the newest page is returned.
func (s *AgentEventStore) QueryCanonicalEvents(
	ctx context.Context,
	streamID string,
	afterSequence, beforeSequence uint64,
	limit int,
) (api.AgentEventsHistoryResult, error) {
	streamID = strings.TrimSpace(streamID)
	if streamID == "" {
		return api.AgentEventsHistoryResult{}, errors.New("canonical agent streamId is required")
	}
	if limit <= 0 {
		limit = defaultHistoryLimit
	}
	if limit > maxHistoryLimit {
		limit = maxHistoryLimit
	}

	s.mu.RLock()
	defer s.mu.RUnlock()
	var state struct {
		executionID                string
		checkpointJSON             sql.NullString
		retained, head, checkpoint uint64
	}
	_ = s.db.QueryRowContext(ctx, `
		SELECT execution_id, retained_from_sequence, head_sequence, checkpoint_sequence, checkpoint_json
		FROM agent_stream_state WHERE stream_id = ?
	`, streamID).Scan(&state.executionID, &state.retained, &state.head, &state.checkpoint, &state.checkpointJSON)
	if state.retained == 0 {
		_ = s.db.QueryRowContext(ctx,
			`SELECT COALESCE(MIN(sequence), 0), COALESCE(MAX(sequence), 0), COALESCE(MAX(execution_id), '') FROM agent_event_journal WHERE stream_id = ?`,
			streamID,
		).Scan(&state.retained, &state.head, &state.executionID)
	}
	if state.retained > 0 && ((afterSequence > 0 && afterSequence+1 < state.retained) ||
		(afterSequence == 0 && beforeSequence > 0 && beforeSequence <= state.retained)) {
		checkpointSequence := state.checkpoint
		checkpoint := decodeCheckpoint(state.checkpointJSON.String)
		if checkpointSequence == 0 {
			// A stream created before durable checkpoints were introduced still
			// has a safe replacement cursor: the current journal head. Clients
			// must render the supplied projection and continue after this point.
			checkpointSequence = state.head
		}
		return api.AgentEventsHistoryResult{}, &CanonicalHistoryBoundary{
			StreamID: streamID, RetainedFromSequence: state.retained, HeadSequence: state.head,
			CheckpointSequence: checkpointSequence, Checkpoint: checkpoint,
		}
	}

	query := `SELECT event_json FROM agent_event_journal WHERE stream_id = ?`
	args := []any{streamID}
	if afterSequence > 0 {
		query += ` AND sequence > ?`
		args = append(args, afterSequence)
	}
	if beforeSequence > 0 {
		query += ` AND sequence < ?`
		args = append(args, beforeSequence)
	}
	reversePage := afterSequence == 0 && (beforeSequence == 0 || beforeSequence > 0)
	if reversePage {
		query += ` ORDER BY sequence DESC LIMIT ?`
	} else {
		query += ` ORDER BY sequence ASC LIMIT ?`
	}
	args = append(args, limit+1)
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return api.AgentEventsHistoryResult{}, fmt.Errorf("query canonical events: %w", err)
	}
	defer rows.Close()
	result := api.AgentEventsHistoryResult{StreamID: streamID, ExecutionID: state.executionID, HeadSequence: state.head, RetainedFrom: state.retained}
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return api.AgentEventsHistoryResult{}, fmt.Errorf("scan canonical event: %w", err)
		}
		var event api.CanonicalAgentEvent
		if err := json.Unmarshal([]byte(raw), &event); err != nil {
			return api.AgentEventsHistoryResult{}, fmt.Errorf("decode canonical event: %w", err)
		}
		result.Events = append(result.Events, event)
	}
	if err := rows.Err(); err != nil {
		return api.AgentEventsHistoryResult{}, err
	}
	if len(result.Events) > limit {
		result.HasMore = true
		result.Events = result.Events[:limit]
	}
	if reversePage {
		for left, right := 0, len(result.Events)-1; left < right; left, right = left+1, right-1 {
			result.Events[left], result.Events[right] = result.Events[right], result.Events[left]
		}
	}
	if len(result.Events) > 0 {
		result.NextAfterSequence = result.Events[len(result.Events)-1].Sequence
	}
	return result, nil
}

// CanonicalCheckpoint returns the last checkpoint committed with a stream.
// It is deliberately separate from the event page so subscription code can
// establish a coherent snapshot while holding its broadcast fence.
func (s *AgentEventStore) CanonicalCheckpoint(
	ctx context.Context,
	streamID string,
) (api.AgentProjectionCheckpoint, bool, error) {
	streamID = strings.TrimSpace(streamID)
	if streamID == "" {
		return api.AgentProjectionCheckpoint{}, false, errors.New("canonical agent streamId is required")
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var sequence uint64
	var raw sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT checkpoint_sequence, checkpoint_json
		FROM agent_stream_state WHERE stream_id = ?
	`, streamID).Scan(&sequence, &raw)
	if err == sql.ErrNoRows {
		return api.AgentProjectionCheckpoint{}, false, nil
	}
	if err != nil {
		return api.AgentProjectionCheckpoint{}, false, fmt.Errorf("query canonical checkpoint: %w", err)
	}
	if sequence == 0 {
		return api.AgentProjectionCheckpoint{}, false, nil
	}
	return api.AgentProjectionCheckpoint{Sequence: sequence, State: decodeCheckpoint(raw.String)}, true, nil
}

func (s *AgentEventStore) CanonicalExecution(ctx context.Context, streamID string) (api.AgentExecution, bool, error) {
	result, err := s.QueryCanonicalEvents(ctx, streamID, 0, 0, maxHistoryLimit)
	if err != nil {
		return api.AgentExecution{}, false, err
	}
	if result.ExecutionID == "" {
		return api.AgentExecution{}, false, nil
	}
	return api.AgentExecution{ID: result.ExecutionID, StreamID: streamID, HeadSequence: result.HeadSequence}, true, nil
}

// canonicalEventsEquivalent compares the immutable semantic identity of an
// event while ignoring Host-assigned sequence and recording time. A retried
// provider observation has the same event ID/payload but is normalized at a
// later wall-clock instant; treating that as a conflict would make at-least
// once delivery impossible.
func canonicalEventsEquivalent(existing, incoming api.CanonicalAgentEvent) bool {
	existing.Sequence = 0
	incoming.Sequence = 0
	existing.OccurredAt = time.Time{}
	incoming.OccurredAt = time.Time{}
	existing.RecordedAt = time.Time{}
	incoming.RecordedAt = time.Time{}
	encodedExisting, errExisting := json.Marshal(existing)
	encodedIncoming, errIncoming := json.Marshal(incoming)
	if errExisting != nil || errIncoming != nil {
		return false
	}
	normalizedExisting, errExisting := normalizeCanonicalJSON(encodedExisting)
	normalizedIncoming, errIncoming := normalizeCanonicalJSON(encodedIncoming)
	return errExisting == nil && errIncoming == nil && bytes.Equal(normalizedExisting, normalizedIncoming)
}

// normalizeCanonicalJSON removes representation-only differences such as
// object key order and typed-vs-generic payload objects. The journal stores
// JSON and replays it into map[string]any, while a live provider event may
// still carry a typed payload struct; both representations must remain
// idempotent.
func normalizeCanonicalJSON(encoded []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return json.Marshal(value)
}

func decodeCheckpoint(raw string) map[string]any {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	var value map[string]any
	if json.Unmarshal([]byte(raw), &value) != nil {
		return nil
	}
	return value
}
