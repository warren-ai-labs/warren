package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"sort"
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
}

// UsageRebuildResult describes a completed replacement of the Usage projection.
// The canonical Agent journal is intentionally left untouched.
type UsageRebuildResult struct {
	// Providers is the scope that was actually replaced, sorted. Anything absent
	// kept its stored usage.
	Providers []string
	// Observations is how many provider usage measurements were read.
	Observations int64
	// Calls is how many of those were counted. It is lower than Observations by
	// the number of repeats collapsed, which is the figure worth surfacing:
	// a resumed conversation reports its whole history again.
	Calls int64
	Days  int64
	// CompletedAt is when the replacement committed, in UTC. It is durable, so a
	// later read of the panel can say how old these figures are.
	CompletedAt time.Time
}

// UsageRebuildStamp is the recorded age of the stored Usage projection.
type UsageRebuildStamp struct {
	CompletedAt time.Time
	// Providers is the scope that rebuild covered. Providers outside it hold
	// figures from whatever earlier rebuild or live accumulation produced them,
	// so the age only speaks for the ones named here.
	Providers []string
	Calls     int64
}

// LastUsageRebuild reports the most recent completed rebuild, or false when the
// projection has only ever been accumulated live.
func (s *AgentEventStore) LastUsageRebuild(ctx context.Context) (UsageRebuildStamp, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return UsageRebuildStamp{}, false, nil
	}
	var (
		completedAt string
		providers   string
		calls       int64
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT completed_at, providers, calls FROM agent_usage_rebuild WHERE id = 1
	`).Scan(&completedAt, &providers, &calls)
	if err == sql.ErrNoRows {
		return UsageRebuildStamp{}, false, nil
	}
	if err != nil {
		return UsageRebuildStamp{}, false, fmt.Errorf("read last usage rebuild: %w", err)
	}
	parsed, parseErr := time.Parse(time.RFC3339Nano, completedAt)
	if parseErr != nil {
		// An unreadable stamp is not worth failing the whole panel over: the
		// figures it describes are still correct, only their age is unknown.
		return UsageRebuildStamp{}, false, nil
	}
	stamp := UsageRebuildStamp{CompletedAt: parsed, Calls: calls}
	for _, provider := range strings.Split(providers, ",") {
		if trimmed := strings.TrimSpace(provider); trimmed != "" {
			stamp.Providers = append(stamp.Providers, trimmed)
		}
	}
	return stamp, true, nil
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

// RebuildUsageRollups replaces the Usage projection from every canonical event
// retained in the Agent journal, for every provider the journal holds. It is the
// fallback for hosts that cannot enumerate historical transcripts.
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
	providers := map[string]struct{}{}
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
		providers[strings.TrimSpace(event.Origin.Provider)] = struct{}{}
		inputs = append(inputs, usageRebuildInput{event: event})
	}
	return s.replaceUsageRollupsLocked(ctx, keys(providers), inputs)
}

// RebuildUsageRollupsFromObservations replaces the Usage projection for exactly
// the named providers from parser output collected over historical transcripts.
//
// The provider list is a parameter rather than something derived from the
// observations because it decides what gets deleted. A provider that reports
// tokens but whose transcripts this host cannot enumerate must keep its stored
// usage: clearing it would silently zero real spend that nothing can restore.
func (s *AgentEventStore) RebuildUsageRollupsFromObservations(
	ctx context.Context,
	providers []string,
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
	return s.replaceUsageRollupsLocked(ctx, providers, inputs)
}

func (s *AgentEventStore) replaceUsageRollupsLocked(
	ctx context.Context,
	providers []string,
	inputs []usageRebuildInput,
) (UsageRebuildResult, error) {
	scope := map[string]struct{}{}
	for _, provider := range providers {
		if trimmed := strings.TrimSpace(provider); trimmed != "" {
			scope[trimmed] = struct{}{}
		}
	}
	if len(scope) == 0 {
		return UsageRebuildResult{}, fmt.Errorf("usage rebuild needs at least one provider")
	}
	replaced := keys(scope)
	sort.Strings(replaced)

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return UsageRebuildResult{}, fmt.Errorf("begin usage rebuild: %w", err)
	}
	defer tx.Rollback()
	for provider := range scope {
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM agent_usage_interval WHERE provider = ?`, provider); err != nil {
			return UsageRebuildResult{}, fmt.Errorf("clear Usage projection for %s: %w", provider, err)
		}
		if _, err := tx.ExecContext(ctx,
			`DELETE FROM agent_usage_call WHERE provider = ?`, provider); err != nil {
			return UsageRebuildResult{}, fmt.Errorf("clear Usage call keys for %s: %w", provider, err)
		}
	}

	result := UsageRebuildResult{Providers: replaced}
	for _, input := range inputs {
		if err := ctx.Err(); err != nil {
			return UsageRebuildResult{}, err
		}
		provider := strings.TrimSpace(input.event.Origin.Provider)
		if _, covered := scope[provider]; !covered {
			// Outside the deleted scope, so re-counting it would double the rows
			// that were deliberately kept.
			continue
		}
		observed := usageFromPayload(input.event.Payload)
		if observed == nil {
			continue
		}
		if _, ok := usage.Normalize(provider, observed); !ok {
			continue
		}
		attribution := UsageAttribution{}
		if input.attribution != nil {
			attribution = *input.attribution
		} else if s.usageAttribution != nil {
			attribution = s.usageAttribution(input.event.StreamID)
		}
		result.Observations++
		counted, err := s.accumulateUsageWithAttribution(ctx, tx, input.event, attribution)
		if err != nil {
			return UsageRebuildResult{}, err
		}
		if counted {
			result.Calls++
		}
	}

	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(DISTINCT local_day) FROM agent_usage_interval`).Scan(&result.Days); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("count rebuilt Usage days: %w", err)
	}
	// Stamped inside the same transaction as the rows it describes, so a rebuild
	// that fails leaves neither the projection nor its recorded age changed.
	result.CompletedAt = time.Now().UTC()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO agent_usage_rebuild (id, completed_at, providers, calls)
		VALUES (1, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			completed_at = excluded.completed_at,
			providers    = excluded.providers,
			calls        = excluded.calls
	`, result.CompletedAt.Format(time.RFC3339Nano), strings.Join(replaced, ","), result.Calls); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("stamp usage rebuild: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return UsageRebuildResult{}, fmt.Errorf("commit usage rebuild: %w", err)
	}
	return result, nil
}

func keys(values map[string]struct{}) []string {
	result := make([]string, 0, len(values))
	for value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
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

// accumulateUsage folds one newly inserted event's usage into the 5-minute
// rollup inside the caller's transaction.
//
// Counting each billable call once is enforced here by agent_usage_call, not by
// the journal's own idempotency. The journal only guarantees that one stream
// never holds the same event twice, and the repeats that matter cross streams:
// a resumed conversation copies its history into a transcript Warren binds to a
// new stream, and a Usage rebuild re-reads files the live watcher consumed. The
// adapters still collapse the repeats they can see -- Codex re-emitting a
// token_count per rate-limit lane, Claude and pi copying one message's usage
// onto each of its content blocks -- because that keeps the journal itself an
// honest record of one call per event.
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
	_, err := s.accumulateUsageWithAttribution(ctx, tx, event, resolver(streamID))
	return err
}

// accumulateUsageWithAttribution reports whether the call was counted. False
// means an identical call key had already been recorded.
func (s *AgentEventStore) accumulateUsageWithAttribution(
	ctx context.Context,
	tx *sql.Tx,
	event api.CanonicalAgentEvent,
	attribution UsageAttribution,
) (bool, error) {
	observed := usageFromPayload(event.Payload)
	if observed == nil {
		return false, nil
	}
	provider := strings.TrimSpace(event.Origin.Provider)
	buckets, ok := usage.Normalize(provider, observed)
	if !ok {
		return false, nil
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

	if key := strings.TrimSpace(observed.CallKey); key != "" {
		claimed, err := claimUsageCall(ctx, tx, provider, key, day)
		if err != nil {
			return false, err
		}
		if !claimed {
			return false, nil
		}
	}

	modelRaw := payloadString(event.Payload, "model")
	model := usage.NormalizeModelID(modelRaw)

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO agent_usage_interval
		(local_day, bucket_start_min, provider, model, model_raw, project_id, utc_offset_min,
		 calls, fresh_input, cache_write, cache_read, output, reasoning)
		VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
		ON CONFLICT(local_day, bucket_start_min, provider, model, model_raw, project_id) DO UPDATE SET
			calls = agent_usage_interval.calls + 1,
			fresh_input = agent_usage_interval.fresh_input + excluded.fresh_input,
			cache_write = agent_usage_interval.cache_write + excluded.cache_write,
			cache_read = agent_usage_interval.cache_read + excluded.cache_read,
			output = agent_usage_interval.output + excluded.output,
			reasoning = agent_usage_interval.reasoning + excluded.reasoning,
			utc_offset_min = excluded.utc_offset_min
	`,
		day, bucketStartMin, provider, model, modelRaw, attribution.ProjectID, offsetSeconds/60,
		buckets.FreshInput, buckets.CacheWrite, buckets.CacheRead,
		buckets.Output, buckets.Reasoning,
	); err != nil {
		return false, fmt.Errorf("accumulate usage interval: %w", err)
	}
	return true, nil
}

// claimUsageCall records a provider call key and reports whether this caller is
// the one that claimed it. A false return means the call was already counted.
func claimUsageCall(ctx context.Context, tx *sql.Tx, provider, callKey, day string) (bool, error) {
	result, err := tx.ExecContext(ctx, `
		INSERT INTO agent_usage_call(fingerprint, provider, local_day)
		VALUES (?, ?, ?)
		ON CONFLICT(fingerprint) DO NOTHING
	`, usageCallFingerprint(provider, callKey), provider, day)
	if err != nil {
		return false, fmt.Errorf("claim usage call: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("claim usage call: %w", err)
	}
	return affected > 0, nil
}

// usageCallFingerprint hashes a provider-scoped call key into the stored 64-bit
// identity. FNV-1a is enough because the input is not adversarial and the space
// is vast next to the number of calls a host records: the keys only have to not
// collide, not resist being forged.
func usageCallFingerprint(provider, callKey string) int64 {
	digest := fnv.New64a()
	_, _ = digest.Write([]byte(provider))
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write([]byte(callKey))
	return int64(digest.Sum64())
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

// UsageDailyRow is one local day's spend for a single provider/model/project.
// It is summed from the interval buckets rather than stored: a second
// materialization of the same fact is a second thing that can be wrong.
type UsageDailyRow struct {
	LocalDay   string `json:"localDay"`
	Provider   string `json:"provider"`
	Model      string `json:"model"`
	ModelRaw   string `json:"modelRaw"`
	ProjectID  string `json:"projectId,omitempty"`
	Calls      int64  `json:"calls"`
	FreshInput int64  `json:"freshInput"`
	CacheWrite int64  `json:"cacheWrite"`
	CacheRead  int64  `json:"cacheRead"`
	Output     int64  `json:"output"`
	Reasoning  int64  `json:"reasoning,omitempty"`
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
}

// usageDayRangeClause builds the shared inclusive local-day filter. Both bounds
// are YYYY-MM-DD; an empty bound is unconstrained.
func usageDayRangeClause(fromDay, toDay string) (string, []any) {
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
	if len(clauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

// QueryUsageDaily returns per-day rows for the inclusive local-day range,
// ascending by day.
func (s *AgentEventStore) QueryUsageDaily(ctx context.Context, fromDay, toDay string) ([]UsageDailyRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil, nil
	}
	where, args := usageDayRangeClause(fromDay, toDay)
	query := `
		SELECT local_day, provider, model, model_raw, project_id,
		       SUM(calls), SUM(fresh_input), SUM(cache_write), SUM(cache_read),
		       SUM(output), SUM(reasoning)
		FROM agent_usage_interval` + where + `
		GROUP BY local_day, provider, model, model_raw, project_id
		ORDER BY local_day, provider, model`

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query usage days: %w", err)
	}
	defer rows.Close()
	var result []UsageDailyRow
	for rows.Next() {
		var row UsageDailyRow
		if err := rows.Scan(
			&row.LocalDay, &row.Provider, &row.Model, &row.ModelRaw, &row.ProjectID,
			&row.Calls, &row.FreshInput, &row.CacheWrite, &row.CacheRead,
			&row.Output, &row.Reasoning,
		); err != nil {
			return nil, fmt.Errorf("scan usage day: %w", err)
		}
		result = append(result, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate usage days: %w", err)
	}
	return result, nil
}

// LatestUsageIntervalDay returns the most recent local day with five-minute
// rows in the inclusive range, or "" when none. It lets the Service choose the
// default detail day without loading every bucket in the range.
func (s *AgentEventStore) LatestUsageIntervalDay(ctx context.Context, fromDay, toDay string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return "", nil
	}
	where, args := usageDayRangeClause(fromDay, toDay)
	query := `SELECT COALESCE(MAX(local_day), '') FROM agent_usage_interval` + where
	var latest string
	if err := s.db.QueryRowContext(ctx, query, args...).Scan(&latest); err != nil {
		return "", fmt.Errorf("query latest usage interval day: %w", err)
	}
	return latest, nil
}

// QueryUsageIntervals returns the canonical 5-minute rows for an inclusive
// local-day range, ordered by day and bucket.
func (s *AgentEventStore) QueryUsageIntervals(ctx context.Context, fromDay, toDay string) ([]UsageIntervalRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return nil, nil
	}
	where, args := usageDayRangeClause(fromDay, toDay)
	query := `
		SELECT local_day, bucket_start_min, provider, model, model_raw, project_id, calls,
		       fresh_input, cache_write, cache_read, output, reasoning
		FROM agent_usage_interval` + where + `
		ORDER BY local_day, bucket_start_min, provider, model`

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
			&row.Output, &row.Reasoning,
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
