package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/usage"
)

// UsageAttribution is the ownership context a spend row is filed under. The
// journal does not know about projects, so the Service supplies this through
// SetUsageAttributionResolver rather than the store reaching into host state.
type UsageAttribution struct {
	// ProjectID is empty when the stream cannot be attributed to a project.
	// An empty value is filed as unattributed rather than dropped, because
	// dropping it would make the panel total disagree with reality.
	ProjectID string
}

// UsageAttributionResolver maps a canonical stream to its ownership context.
type UsageAttributionResolver func(streamID string) UsageAttribution

// SetUsageAttributionResolver installs the project attribution lookup. Usage
// accumulation is inert until a resolver is set, which keeps stores constructed
// by tests and embedders free of a host-state dependency.
func (s *AgentEventStore) SetUsageAttributionResolver(resolver UsageAttributionResolver) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usageAttribution = resolver
	// The intraday table was introduced after the daily rollup. When an
	// existing Host upgrades, the retained journal is the only place that can
	// recover the time-of-day detail; do that once while the resolver is known.
	_ = s.backfillUsageIntervalsLocked()
}

// UsageRebuildResult describes a completed replacement of the Usage
// projections. The canonical Agent journal is intentionally left untouched;
// only the two derived Usage tables are cleared and rebuilt.
type UsageRebuildResult struct {
	Events int64
	Calls  int64
	Days   int64
}

// UsageRebuildObservation is one provider usage observation read directly from
// a historical transcript. It is deliberately separate from the canonical
// journal event: rebuilding Usage must be able to correct an old parser's
// duplicate rows without rewriting that immutable journal.
type UsageRebuildObservation struct {
	Provider   string
	Model      string
	ProjectID  string
	OccurredAt time.Time
	Usage      api.AgentUsage
}

type usageRebuildInput struct {
	event       api.CanonicalAgentEvent
	attribution *UsageAttribution
}

// RebuildUsageRollups replaces the daily and intraday Usage projections from
// every canonical event retained in the Agent journal. It is an explicit
// maintenance operation rather than a normal write path: callers should warn
// the user that the current Usage aggregates are discarded, while the journal
// and every other Host database remain unchanged.
//
// The whole replacement is one SQLite transaction. A failed or cancelled
// rebuild therefore leaves the previous Usage projections intact, and running
// it again is idempotent because the source journal is immutable.
func (s *AgentEventStore) RebuildUsageRollups(ctx context.Context) (UsageRebuildResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return UsageRebuildResult{}, nil
	}
	if s.usageAttribution == nil {
		return UsageRebuildResult{}, fmt.Errorf("usage attribution resolver is not configured")
	}

	encodedEvents, err := s.readCanonicalEventsForUsageRebuild(ctx)
	if err != nil {
		return UsageRebuildResult{}, err
	}
	inputs := make([]usageRebuildInput, 0, len(encodedEvents))
	for _, encoded := range encodedEvents {
		if err := ctx.Err(); err != nil {
			return UsageRebuildResult{}, err
		}
		var event api.CanonicalAgentEvent
		if err := json.Unmarshal([]byte(encoded), &event); err != nil {
			// A malformed journal row cannot be made meaningful by a rebuild. Keep
			// the immutable source intact and skip only that unusable row.
			continue
		}
		inputs = append(inputs, usageRebuildInput{event: event})
	}
	return s.replaceUsageRollupsLocked(ctx, inputs)
}

// RebuildUsageRollupsFromObservations replaces Usage projections from parser
// output collected from historical transcript files. Only the derived Usage
// tables are touched; the canonical journal and every other database remain
// unchanged.
func (s *AgentEventStore) RebuildUsageRollupsFromObservations(
	ctx context.Context,
	observations []UsageRebuildObservation,
) (UsageRebuildResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return UsageRebuildResult{}, nil
	}

	now := time.Now().UTC()
	inputs := make([]usageRebuildInput, 0, len(observations))
	for index, observation := range observations {
		if err := ctx.Err(); err != nil {
			return UsageRebuildResult{}, err
		}
		provider := strings.TrimSpace(observation.Provider)
		if provider == "" {
			continue
		}
		usageValue := observation.Usage
		if _, ok := usage.Normalize(provider, &usageValue); !ok {
			continue
		}
		occurredAt := observation.OccurredAt
		if occurredAt.IsZero() {
			occurredAt = now
		}
		model := strings.TrimSpace(observation.Model)
		payload := map[string]any{"usage": &usageValue}
		if model != "" {
			payload["model"] = model
		}
		attribution := UsageAttribution{ProjectID: strings.TrimSpace(observation.ProjectID)}
		inputs = append(inputs, usageRebuildInput{
			event: api.CanonicalAgentEvent{
				EventID:    fmt.Sprintf("usage-rebuild-%d", index),
				Type:       "usage",
				OccurredAt: occurredAt,
				RecordedAt: now,
				Origin: api.AgentEventOrigin{
					Kind:     "provider",
					Provider: provider,
				},
				Payload: payload,
			},
			attribution: &attribution,
		})
	}
	return s.replaceUsageRollupsLocked(ctx, inputs)
}

func (s *AgentEventStore) replaceUsageRollupsLocked(
	ctx context.Context,
	inputs []usageRebuildInput,
) (UsageRebuildResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return UsageRebuildResult{}, fmt.Errorf("begin usage rebuild: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM agent_usage_daily`); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("clear daily Usage projection: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM agent_usage_interval`); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("clear intraday Usage projection: %w", err)
	}

	result := UsageRebuildResult{}
	for _, input := range inputs {
		if err := ctx.Err(); err != nil {
			return UsageRebuildResult{}, err
		}
		observed := usageFromPayload(input.event.Payload)
		if observed == nil {
			continue
		}
		provider := strings.TrimSpace(input.event.Origin.Provider)
		if _, ok := usage.Normalize(provider, observed); !ok {
			continue
		}
		attribution := UsageAttribution{}
		if input.attribution != nil {
			attribution = *input.attribution
		} else if s.usageAttribution != nil {
			attribution = s.usageAttribution(input.event.StreamID)
		}
		if err := s.accumulateUsageWithAttribution(ctx, tx, input.event, attribution); err != nil {
			return UsageRebuildResult{}, err
		}
		result.Events++
		result.Calls++
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO agent_usage_meta(key, value) VALUES ('last_rebuild_at', ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value
	`, time.Now().UTC().Format(time.RFC3339)); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("record usage rebuild: %w", err)
	}
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(DISTINCT local_day) FROM agent_usage_daily`).Scan(&result.Days); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("count rebuilt Usage days: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("commit usage rebuild: %w", err)
	}
	return result, nil
}

func (s *AgentEventStore) readCanonicalEventsForUsageRebuild(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT event_json FROM agent_event_journal ORDER BY stream_id, sequence
	`)
	if err != nil {
		return nil, fmt.Errorf("read canonical events for Usage rebuild: %w", err)
	}
	defer rows.Close()
	var encodedEvents []string
	for rows.Next() {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var encoded string
		if err := rows.Scan(&encoded); err != nil {
			return nil, fmt.Errorf("scan canonical event for Usage rebuild: %w", err)
		}
		encodedEvents = append(encodedEvents, encoded)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate canonical events for Usage rebuild: %w", err)
	}
	return encodedEvents, nil
}

// accumulateUsage folds one newly inserted event's usage into the daily and
// 5-minute rollups inside the caller's transaction.
//
// It is deliberately only called for rows that the journal actually inserted.
// That is what makes accounting idempotent for free: the transcript watcher
// re-reads each file from offset zero on every restart, so a replay produces
// byte-identical events with the same content-hashed event IDs, and the
// journal's UNIQUE (stream_id, event_id) rejects them before they reach here.
//
// The invariant this relies on is that one billable model call yields exactly
// one canonical event carrying usage. Providers that repeat a measurement --
// Codex re-emitting a token_count per rate-limit lane, Claude copying one
// message's usage onto each of its content blocks -- must collapse that in
// their adapter, which is the only layer that can still see the fields needed
// to tell a repeat from a genuine second call.
func (s *AgentEventStore) accumulateUsage(
	ctx context.Context,
	tx *sql.Tx,
	streamID string,
	event api.CanonicalAgentEvent,
) error {
	resolver := s.usageAttribution
	if resolver == nil {
		return nil
	}
	return s.accumulateUsageWithAttribution(ctx, tx, event, resolver(streamID))
}

func (s *AgentEventStore) accumulateUsageWithAttribution(
	ctx context.Context,
	tx *sql.Tx,
	event api.CanonicalAgentEvent,
	attribution UsageAttribution,
) error {
	observed := usageFromPayload(event.Payload)
	if observed == nil {
		return nil
	}
	provider := strings.TrimSpace(event.Origin.Provider)
	buckets, ok := usage.Normalize(provider, observed)
	if !ok {
		return nil
	}

	occurred := event.OccurredAt
	if occurred.IsZero() {
		occurred = event.RecordedAt
	}
	local := occurred.Local()
	_, offsetSeconds := local.Zone()
	day := local.Format("2006-01-02")
	bucketStartMin := local.Hour()*60 + local.Minute()
	bucketStartMin = (bucketStartMin / api.UsageIntervalBucketMinutes) * api.UsageIntervalBucketMinutes

	modelRaw := payloadString(event.Payload, "model")
	model := usage.NormalizeModelID(modelRaw)

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO agent_usage_daily
		(local_day, provider, model, model_raw, project_id, utc_offset_min,
		 calls, fresh_input, cache_write, cache_read, output, reasoning,
		 cost_nano_usd, priced_calls)
		VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, 0, 0)
		ON CONFLICT(local_day, provider, model, model_raw, project_id) DO UPDATE SET
			calls = agent_usage_daily.calls + 1,
			fresh_input = agent_usage_daily.fresh_input + excluded.fresh_input,
			cache_write = agent_usage_daily.cache_write + excluded.cache_write,
			cache_read = agent_usage_daily.cache_read + excluded.cache_read,
			output = agent_usage_daily.output + excluded.output,
			reasoning = agent_usage_daily.reasoning + excluded.reasoning,
			utc_offset_min = excluded.utc_offset_min
	`,
		day, provider, model, modelRaw, attribution.ProjectID, offsetSeconds/60,
		buckets.FreshInput, buckets.CacheWrite, buckets.CacheRead,
		buckets.Output, buckets.Reasoning,
	); err != nil {
		return fmt.Errorf("accumulate usage rollup: %w", err)
	}
	if err := upsertUsageInterval(ctx, tx, day, bucketStartMin, provider, model, modelRaw,
		attribution.ProjectID, offsetSeconds/60, buckets); err != nil {
		return fmt.Errorf("accumulate usage interval: %w", err)
	}
	return nil
}

func upsertUsageInterval(
	ctx context.Context,
	tx *sql.Tx,
	day string,
	bucketStartMin int,
	provider string,
	model string,
	modelRaw string,
	projectID string,
	utcOffsetMin int,
	buckets usage.Buckets,
) error {
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO agent_usage_interval
		(local_day, bucket_start_min, provider, model, model_raw, project_id, utc_offset_min,
		 calls, fresh_input, cache_write, cache_read, output, reasoning,
		 cost_nano_usd, priced_calls)
		VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, 0, 0)
		ON CONFLICT(local_day, bucket_start_min, provider, model, model_raw, project_id) DO UPDATE SET
			calls = agent_usage_interval.calls + 1,
			fresh_input = agent_usage_interval.fresh_input + excluded.fresh_input,
			cache_write = agent_usage_interval.cache_write + excluded.cache_write,
			cache_read = agent_usage_interval.cache_read + excluded.cache_read,
			output = agent_usage_interval.output + excluded.output,
			reasoning = agent_usage_interval.reasoning + excluded.reasoning,
			utc_offset_min = excluded.utc_offset_min
	`,
		day, bucketStartMin, provider, model, modelRaw, projectID, utcOffsetMin,
		buckets.FreshInput, buckets.CacheWrite, buckets.CacheRead,
		buckets.Output, buckets.Reasoning,
	); err != nil {
		return err
	}
	return nil
}

// backfillUsageIntervalsLocked reconstructs intraday rows from retained
// canonical events after an upgrade. It only runs when the interval table is
// empty; once any new event has populated it, repeating the scan would double
// count. Journal trimming may make very old points unrecoverable, but it never
// fabricates a point that was not retained.
func (s *AgentEventStore) backfillUsageIntervalsLocked() error {
	if s.db == nil || s.usageAttribution == nil {
		return nil
	}
	var existing int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM agent_usage_interval`).Scan(&existing); err != nil {
		return err
	}
	if existing > 0 {
		return nil
	}
	rows, err := s.db.Query(`SELECT event_json FROM agent_event_journal ORDER BY stream_id, sequence`)
	if err != nil {
		return err
	}
	var encodedEvents []string
	for rows.Next() {
		var encoded string
		if err := rows.Scan(&encoded); err != nil {
			rows.Close()
			return err
		}
		encodedEvents = append(encodedEvents, encoded)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	tx, err := s.db.BeginTx(context.Background(), nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, encoded := range encodedEvents {
		var event api.CanonicalAgentEvent
		if err := json.Unmarshal([]byte(encoded), &event); err != nil {
			continue
		}
		observed := usageFromPayload(event.Payload)
		if observed == nil {
			continue
		}
		provider := strings.TrimSpace(event.Origin.Provider)
		buckets, ok := usage.Normalize(provider, observed)
		if !ok {
			continue
		}
		occurred := event.OccurredAt
		if occurred.IsZero() {
			occurred = event.RecordedAt
		}
		local := occurred.Local()
		minute := local.Hour()*60 + local.Minute()
		minute = (minute / api.UsageIntervalBucketMinutes) * api.UsageIntervalBucketMinutes
		modelRaw := payloadString(event.Payload, "model")
		if err := upsertUsageInterval(
			context.Background(), tx, local.Format("2006-01-02"), minute,
			provider, usage.NormalizeModelID(modelRaw), modelRaw,
			s.usageAttribution(event.StreamID).ProjectID,
			func() int { _, seconds := local.Zone(); return seconds / 60 }(), buckets,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// usageFromPayload reads the usage object out of a canonical payload. The value
// is a typed pointer on the append path and a decoded map after a journal round
// trip, so both shapes are accepted.
func usageFromPayload(payload map[string]any) *api.AgentUsage {
	if payload == nil {
		return nil
	}
	raw, exists := payload["usage"]
	if !exists || raw == nil {
		return nil
	}
	switch value := raw.(type) {
	case *api.AgentUsage:
		return value
	case api.AgentUsage:
		return &value
	case map[string]any:
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil
		}
		var decoded api.AgentUsage
		if json.Unmarshal(encoded, &decoded) != nil {
			return nil
		}
		return &decoded
	default:
		return nil
	}
}

func payloadString(payload map[string]any, key string) string {
	if payload == nil {
		return ""
	}
	value, _ := payload[key].(string)
	return strings.TrimSpace(value)
}

// RepriceUsageDaily recomputes the cached cost of every rollup row from the
// supplied price table and returns how many rows changed.
//
// Cost is recomputed rather than accrued per call because unit prices change.
// The tokens are the durable fact; the money is a projection of them, so a price
// correction has to be able to restate history rather than only affect new
// spend. Rows keep their tokens either way.
//
// priced_calls records how many of a row's calls had a fully known price. When
// it trails calls, the row's cost is a lower bound and every aggregate built
// from it must be presented as such.
func (s *AgentEventStore) RepriceUsageDaily(ctx context.Context, table *usage.PriceTable) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil || table == nil {
		return 0, nil
	}

	rows, err := s.db.QueryContext(ctx, `
		SELECT local_day, provider, model, model_raw, project_id,
		       calls, fresh_input, cache_write, cache_read, output,
		       cost_nano_usd, priced_calls
		FROM agent_usage_daily
	`)
	if err != nil {
		return 0, fmt.Errorf("scan usage rollup for repricing: %w", err)
	}
	type update struct {
		key         [5]string
		cost        int64
		pricedCalls int64
	}
	type intervalUpdate struct {
		key         [6]string
		cost        int64
		pricedCalls int64
	}
	var pending []update
	for rows.Next() {
		var (
			day, provider, model, modelRaw, project string
			calls, fresh, cacheWrite, cacheRead     int64
			output, cost, pricedCalls               int64
		)
		if err := rows.Scan(&day, &provider, &model, &modelRaw, &project,
			&calls, &fresh, &cacheWrite, &cacheRead, &output, &cost, &pricedCalls); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan usage rollup row: %w", err)
		}
		price, found := table.Price(model)
		nextCost, status := usage.Cost(usage.Buckets{
			FreshInput: fresh,
			CacheWrite: cacheWrite,
			CacheRead:  cacheRead,
			Output:     output,
		}, price, found)
		// A row aggregates many calls that share one model, so its price is
		// known for all of them or none.
		nextPriced := int64(0)
		if status == usage.CostPriced {
			nextPriced = calls
		}
		if nextCost == cost && nextPriced == pricedCalls {
			continue
		}
		pending = append(pending, update{
			key:         [5]string{day, provider, model, modelRaw, project},
			cost:        nextCost,
			pricedCalls: nextPriced,
		})
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, fmt.Errorf("iterate usage rollup for repricing: %w", err)
	}
	rows.Close()

	intervalRows, err := s.db.QueryContext(ctx, `
		SELECT local_day, bucket_start_min, provider, model, model_raw, project_id,
		       calls, fresh_input, cache_write, cache_read, output,
		       cost_nano_usd, priced_calls
		FROM agent_usage_interval
	`)
	if err != nil {
		return 0, fmt.Errorf("scan usage interval for repricing: %w", err)
	}
	var intervalPending []intervalUpdate
	for intervalRows.Next() {
		var (
			day, provider, model, modelRaw, project string
			bucketStartMin                          int
			calls, fresh, cacheWrite, cacheRead     int64
			output, cost, pricedCalls               int64
		)
		if err := intervalRows.Scan(&day, &bucketStartMin, &provider, &model, &modelRaw, &project,
			&calls, &fresh, &cacheWrite, &cacheRead, &output, &cost, &pricedCalls); err != nil {
			intervalRows.Close()
			return 0, fmt.Errorf("scan usage interval row: %w", err)
		}
		price, found := table.Price(model)
		nextCost, status := usage.Cost(usage.Buckets{
			FreshInput: fresh,
			CacheWrite: cacheWrite,
			CacheRead:  cacheRead,
			Output:     output,
		}, price, found)
		nextPriced := int64(0)
		if status == usage.CostPriced {
			nextPriced = calls
		}
		if nextCost == cost && nextPriced == pricedCalls {
			continue
		}
		intervalPending = append(intervalPending, intervalUpdate{
			key:         [6]string{day, fmt.Sprintf("%d", bucketStartMin), provider, model, modelRaw, project},
			cost:        nextCost,
			pricedCalls: nextPriced,
		})
	}
	if err := intervalRows.Err(); err != nil {
		intervalRows.Close()
		return 0, fmt.Errorf("iterate usage interval for repricing: %w", err)
	}
	intervalRows.Close()
	if len(pending) == 0 && len(intervalPending) == 0 {
		return 0, nil
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("begin usage repricing tx: %w", err)
	}
	defer tx.Rollback()
	for _, item := range pending {
		if _, err := tx.ExecContext(ctx, `
			UPDATE agent_usage_daily
			SET cost_nano_usd = ?, priced_calls = ?
			WHERE local_day = ? AND provider = ? AND model = ?
			  AND model_raw = ? AND project_id = ?
		`, item.cost, item.pricedCalls,
			item.key[0], item.key[1], item.key[2], item.key[3], item.key[4]); err != nil {
			return 0, fmt.Errorf("update usage rollup cost: %w", err)
		}
	}
	for _, item := range intervalPending {
		if _, err := tx.ExecContext(ctx, `
			UPDATE agent_usage_interval
			SET cost_nano_usd = ?, priced_calls = ?
			WHERE local_day = ? AND bucket_start_min = ? AND provider = ? AND model = ?
			  AND model_raw = ? AND project_id = ?
		`, item.cost, item.pricedCalls,
			item.key[0], item.key[1], item.key[2], item.key[3], item.key[4], item.key[5]); err != nil {
			return 0, fmt.Errorf("update usage interval cost: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit usage repricing: %w", err)
	}
	return len(pending), nil
}

// UsageDailyRow is one aggregated spend row.
type UsageDailyRow struct {
	LocalDay    string `json:"localDay"`
	Provider    string `json:"provider"`
	Model       string `json:"model"`
	ModelRaw    string `json:"modelRaw"`
	ProjectID   string `json:"projectId,omitempty"`
	Calls       int64  `json:"calls"`
	FreshInput  int64  `json:"freshInput"`
	CacheWrite  int64  `json:"cacheWrite"`
	CacheRead   int64  `json:"cacheRead"`
	Output      int64  `json:"output"`
	Reasoning   int64  `json:"reasoning,omitempty"`
	CostNanoUSD int64  `json:"costNanoUsd"`
	PricedCalls int64  `json:"pricedCalls"`
}

// UsageIntervalRow is one 5-minute intraday aggregate. BucketStartMin is the
// bucket's local-minute offset from midnight, always a multiple of 5.
type UsageIntervalRow struct {
	LocalDay       string `json:"localDay"`
	BucketStartMin int    `json:"bucketStartMin"`
	Provider       string `json:"provider"`
	Model          string `json:"model"`
	ModelRaw       string `json:"modelRaw"`
	ProjectID      string `json:"projectId,omitempty"`
	Calls          int64  `json:"calls"`
	FreshInput     int64  `json:"freshInput"`
	CacheWrite     int64  `json:"cacheWrite"`
	CacheRead      int64  `json:"cacheRead"`
	Output         int64  `json:"output"`
	Reasoning      int64  `json:"reasoning,omitempty"`
	CostNanoUSD    int64  `json:"costNanoUsd"`
	PricedCalls    int64  `json:"pricedCalls"`
}

// QueryUsageDaily returns rows for the inclusive local-day range, ascending by
// day. Both bounds are YYYY-MM-DD; an empty bound is unconstrained.
func (s *AgentEventStore) QueryUsageDaily(ctx context.Context, fromDay, toDay string) ([]UsageDailyRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil, nil
	}
	query := `
		SELECT local_day, provider, model, model_raw, project_id, calls,
		       fresh_input, cache_write, cache_read, output, reasoning,
		       cost_nano_usd, priced_calls
		FROM agent_usage_daily`
	var clauses []string
	var args []any
	if day := strings.TrimSpace(fromDay); day != "" {
		clauses = append(clauses, "local_day >= ?")
		args = append(args, day)
	}
	if day := strings.TrimSpace(toDay); day != "" {
		clauses = append(clauses, "local_day <= ?")
		args = append(args, day)
	}
	if len(clauses) > 0 {
		query += " WHERE " + strings.Join(clauses, " AND ")
	}
	query += " ORDER BY local_day, provider, model"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query usage rollup: %w", err)
	}
	defer rows.Close()
	var result []UsageDailyRow
	for rows.Next() {
		var row UsageDailyRow
		if err := rows.Scan(
			&row.LocalDay, &row.Provider, &row.Model, &row.ModelRaw, &row.ProjectID,
			&row.Calls, &row.FreshInput, &row.CacheWrite, &row.CacheRead,
			&row.Output, &row.Reasoning, &row.CostNanoUSD, &row.PricedCalls,
		); err != nil {
			return nil, fmt.Errorf("scan usage rollup: %w", err)
		}
		result = append(result, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate usage rollup: %w", err)
	}
	return result, nil
}

// QueryUsageIntervals returns the canonical 5-minute rows for an inclusive
// local-day range, ordered by day and bucket. Both bounds are YYYY-MM-DD; an
// empty bound is unconstrained.
func (s *AgentEventStore) QueryUsageIntervals(ctx context.Context, fromDay, toDay string) ([]UsageIntervalRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil, nil
	}
	query := `
		SELECT local_day, bucket_start_min, provider, model, model_raw, project_id, calls,
		       fresh_input, cache_write, cache_read, output, reasoning,
		       cost_nano_usd, priced_calls
		FROM agent_usage_interval`
	var clauses []string
	var args []any
	if day := strings.TrimSpace(fromDay); day != "" {
		clauses = append(clauses, "local_day >= ?")
		args = append(args, day)
	}
	if day := strings.TrimSpace(toDay); day != "" {
		clauses = append(clauses, "local_day <= ?")
		args = append(args, day)
	}
	if len(clauses) > 0 {
		query += " WHERE " + strings.Join(clauses, " AND ")
	}
	query += " ORDER BY local_day, bucket_start_min, provider, model"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query usage intervals: %w", err)
	}
	defer rows.Close()
	var result []UsageIntervalRow
	for rows.Next() {
		var row UsageIntervalRow
		if err := rows.Scan(
			&row.LocalDay, &row.BucketStartMin, &row.Provider, &row.Model, &row.ModelRaw, &row.ProjectID,
			&row.Calls, &row.FreshInput, &row.CacheWrite, &row.CacheRead,
			&row.Output, &row.Reasoning, &row.CostNanoUSD, &row.PricedCalls,
		); err != nil {
			return nil, fmt.Errorf("scan usage interval: %w", err)
		}
		result = append(result, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate usage intervals: %w", err)
	}
	return result, nil
}
