package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/usage"
)

func newUsageStore(t *testing.T, project string) *AgentEventStore {
	t.Helper()
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	s.SetUsageAttributionResolver(func(string) UsageAttribution {
		return UsageAttribution{ProjectID: project}
	})
	return s
}

func usageEvent(id, provider, model string, at time.Time, value *api.AgentUsage) api.CanonicalAgentEvent {
	return api.CanonicalAgentEvent{
		EventID:    id,
		Type:       "message.completed",
		Origin:     api.AgentEventOrigin{Kind: "provider", Provider: provider, Confidence: "observed"},
		OccurredAt: at,
		Payload:    map[string]any{"role": "assistant", "model": model, "usage": value},
	}
}

func totalRows(t *testing.T, s *AgentEventStore) (calls, fresh, cacheWrite, cacheRead, output int64) {
	t.Helper()
	rows, err := s.QueryUsageDaily(context.Background(), "", "")
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		calls += row.Calls
		fresh += row.FreshInput
		cacheWrite += row.CacheWrite
		cacheRead += row.CacheRead
		output += row.Output
	}
	return
}

func TestUsageRollupAccumulatesDisjointBuckets(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	at := time.Now()
	// Codex reports a total input that contains both cache counters, so the
	// fresh bucket is the remainder.
	event := usageEvent("evt-1", "codex", "gpt-5.6-luna", at, &api.AgentUsage{
		InputTokens:              33410,
		CacheReadInputTokens:     22389,
		CacheCreationInputTokens: 7623,
		OutputTokens:             495,
		ReasoningOutputTokens:    1,
	})
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{event}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.QueryUsageDaily(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %#v, want 1", rows)
	}
	row := rows[0]
	if row.Calls != 1 || row.FreshInput != 3398 || row.CacheWrite != 7623 ||
		row.CacheRead != 22389 || row.Output != 495 || row.Reasoning != 1 {
		t.Fatalf("row = %+v", row)
	}
	if row.Provider != "codex" || row.Model != "gpt-5.6-luna" || row.ProjectID != "proj-1" {
		t.Fatalf("row identity = %+v", row)
	}
	if row.LocalDay != at.Local().Format("2006-01-02") {
		t.Fatalf("localDay = %s, want the host's local day", row.LocalDay)
	}
}

func TestUsageRollupUsesFiveMinuteLocalBuckets(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	base := time.Date(2026, time.September, 10, 10, 5, 0, 0, time.Local)
	for index, at := range []time.Time{
		base,
		base.Add(4 * time.Minute),
		base.Add(5 * time.Minute),
	} {
		if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
			usageEvent("evt-boundary-"+string(rune('a'+index)), "claude", "claude-opus-5", at,
				&api.AgentUsage{InputTokens: 10, OutputTokens: 1}),
		}); err != nil {
			t.Fatal(err)
		}
	}
	day := base.Format("2006-01-02")
	rows, err := s.QueryUsageIntervals(ctx, day, day)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("interval rows = %#v, want two five-minute buckets", rows)
	}
	if rows[0].BucketStartMin != 605 || rows[0].Calls != 2 {
		t.Fatalf("first interval = %+v, want 10:05 with two calls", rows[0])
	}
	if rows[1].BucketStartMin != 610 || rows[1].Calls != 1 {
		t.Fatalf("second interval = %+v, want 10:10 with one call", rows[1])
	}

	daily, err := s.QueryUsageDaily(ctx, day, day)
	if err != nil {
		t.Fatal(err)
	}
	if len(daily) != 1 || daily[0].Calls != 3 || daily[0].FreshInput != 30 || daily[0].Output != 3 {
		t.Fatalf("daily = %+v, want the interval totals", daily)
	}
}

func TestUsageRollupBackfillsIntervalsFromRetainedJournal(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	at := time.Date(2026, time.September, 10, 16, 42, 0, 0, time.Local)
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-backfill", "claude", "claude-opus-5", at,
			&api.AgentUsage{InputTokens: 100, OutputTokens: 20}),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`DELETE FROM agent_usage_interval`); err != nil {
		t.Fatal(err)
	}

	// A resolver is normally installed during Service initialization. Reinstalling
	// it here models an upgrade where the old daily table predates intervals.
	s.SetUsageAttributionResolver(func(string) UsageAttribution {
		return UsageAttribution{ProjectID: "proj-1"}
	})
	rows, err := s.QueryUsageIntervals(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].BucketStartMin != 1_000 || rows[0].Calls != 1 {
		t.Fatalf("backfilled intervals = %+v", rows)
	}
	daily, err := s.QueryUsageDaily(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(daily) != 1 || daily[0].Calls != 1 {
		t.Fatalf("backfill must not duplicate daily rows: %+v", daily)
	}
}

func TestUsageRollupRebuildReplacesOnlyUsageProjections(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	base := time.Date(2026, time.September, 10, 16, 42, 0, 0, time.Local)
	events := []api.CanonicalAgentEvent{
		usageEvent("evt-rebuild-1", "claude", "claude-opus-5", base,
			&api.AgentUsage{InputTokens: 100, OutputTokens: 20}),
		usageEvent("evt-rebuild-2", "codex", "gpt-5.6-luna", base.Add(6*time.Minute),
			&api.AgentUsage{InputTokens: 200, CacheReadInputTokens: 150, OutputTokens: 30}),
		{EventID: "evt-no-usage", Type: "tool.started",
			Origin:     api.AgentEventOrigin{Kind: "provider", Provider: "claude"},
			OccurredAt: base, Payload: map[string]any{"callId": "tool-1"}},
	}
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", events); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`DELETE FROM agent_usage_daily`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`DELETE FROM agent_usage_interval`); err != nil {
		t.Fatal(err)
	}

	result, err := s.RebuildUsageRollups(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if result.Events != 2 || result.Calls != 2 || result.Days != 1 {
		t.Fatalf("rebuild result = %+v, want two usage events on one day", result)
	}
	daily, err := s.QueryUsageDaily(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(daily) != 2 {
		t.Fatalf("daily = %+v, want one row per provider/model", daily)
	}
	intervals, err := s.QueryUsageIntervals(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(intervals) != 2 {
		t.Fatalf("intervals = %+v, want one row per provider/model", intervals)
	}

	// The source journal is still complete, including the non-usage event, and
	// repeating the explicit maintenance action does not double the totals.
	var journalRows int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM agent_event_journal`).Scan(&journalRows); err != nil {
		t.Fatal(err)
	}
	if journalRows != 3 {
		t.Fatalf("journal rows = %d, want the untouched source journal", journalRows)
	}
	if _, err := s.RebuildUsageRollups(ctx); err != nil {
		t.Fatal(err)
	}
	calls, fresh, _, cacheRead, output := totalRows(t, s)
	if calls != 2 || fresh != 150 || cacheRead != 150 || output != 50 {
		t.Fatalf("rebuilt totals = calls %d fresh %d cacheRead %d output %d", calls, fresh, cacheRead, output)
	}
}

func TestUsageRollupIsIdempotentOnReplay(t *testing.T) {
	// The transcript watcher re-reads each file from offset zero after a
	// restart, so the same events are re-appended with identical content-hashed
	// IDs. The journal rejects them, and accounting must not move.
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	batch := []api.CanonicalAgentEvent{
		usageEvent("evt-1", "claude", "claude-opus-5", time.Now(), &api.AgentUsage{
			InputTokens: 100, OutputTokens: 20,
		}),
	}
	for attempt := 0; attempt < 3; attempt++ {
		if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", batch); err != nil {
			t.Fatalf("attempt %d: %v", attempt, err)
		}
	}
	calls, fresh, _, _, output := totalRows(t, s)
	if calls != 1 || fresh != 100 || output != 20 {
		t.Fatalf("calls=%d fresh=%d output=%d, want a single counted call", calls, fresh, output)
	}
}

func TestUsageRollupGroupsAcrossStreamsAndDays(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	today := time.Now()
	earlier := today.AddDate(0, 0, -2)
	usage := &api.AgentUsage{InputTokens: 10, OutputTokens: 5}

	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-1", "claude", "claude-opus-5", today, usage),
		usageEvent("evt-2", "claude", "claude-opus-5", today, usage),
	}); err != nil {
		t.Fatal(err)
	}
	// A different stream on the same day and model must fold into one row.
	if _, err := s.AppendCanonicalEvents(ctx, "exec-2", "exec-2", []api.CanonicalAgentEvent{
		usageEvent("evt-3", "claude", "claude-opus-5", today, usage),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendCanonicalEvents(ctx, "exec-3", "exec-3", []api.CanonicalAgentEvent{
		usageEvent("evt-4", "claude", "claude-opus-5", earlier, usage),
	}); err != nil {
		t.Fatal(err)
	}

	rows, err := s.QueryUsageDaily(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %#v, want one per day", rows)
	}
	if rows[0].LocalDay >= rows[1].LocalDay {
		t.Fatalf("rows must be ascending by day: %s then %s", rows[0].LocalDay, rows[1].LocalDay)
	}
	if rows[0].Calls != 1 || rows[1].Calls != 3 {
		t.Fatalf("calls = %d and %d, want 1 then 3", rows[0].Calls, rows[1].Calls)
	}
}

func TestUsageRollupNormalizesModelForPricing(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-1", "codex", "z-ai/glm-5.3-flash", time.Now(), &api.AgentUsage{
			InputTokens: 10, OutputTokens: 5,
		}),
	}); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if len(rows) != 1 || rows[0].Model != "glm-5.3-flash" {
		t.Fatalf("model = %q, want the price-lookup identity", rows[0].Model)
	}
	// The provider's own spelling is retained so an unmatched price is
	// diagnosable rather than invisible.
	if rows[0].ModelRaw != "z-ai/glm-5.3-flash" {
		t.Fatalf("modelRaw = %q", rows[0].ModelRaw)
	}
}

func TestUsageRollupSkipsUnmeasuredProviders(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	// Antigravity transcripts carry no token counts. A row here would let the
	// panel present a confident zero for spend it cannot see.
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-1", "antigravity", "gemini-3", time.Now(), &api.AgentUsage{
			InputTokens: 100, OutputTokens: 20,
		}),
	}); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if len(rows) != 0 {
		t.Fatalf("rows = %#v, want none for an unmeasured provider", rows)
	}
}

func TestUsageRollupIgnoresEventsWithoutUsage(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		{
			EventID: "evt-1", Type: "tool.started",
			Origin:     api.AgentEventOrigin{Kind: "provider", Provider: "claude"},
			OccurredAt: time.Now(),
			Payload:    map[string]any{"callId": "c1"},
		},
	}); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if len(rows) != 0 {
		t.Fatalf("rows = %#v, want none", rows)
	}
}

func TestUsageRollupStaysInertWithoutResolver(t *testing.T) {
	// Stores built by tests and embedders have no host state to attribute
	// against, so accumulation must simply not happen.
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-1", "claude", "claude-opus-5", time.Now(), &api.AgentUsage{
			InputTokens: 100, OutputTokens: 20,
		}),
	}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.QueryUsageDaily(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("rows = %#v, want none without a resolver", rows)
	}
}

func TestUsageRollupReadsUsageAfterJournalRoundTrip(t *testing.T) {
	// Events arrive as a typed pointer on the append path but decode to a map
	// when replayed from the journal, so both shapes must accumulate alike.
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	event := usageEvent("evt-1", "claude", "claude-opus-5", time.Now(), nil)
	event.Payload["usage"] = map[string]any{
		"inputTokens":              float64(100),
		"cacheReadInputTokens":     float64(40),
		"cacheCreationInputTokens": float64(10),
		"outputTokens":             float64(20),
	}
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{event}); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if len(rows) != 1 {
		t.Fatalf("rows = %#v, want 1", rows)
	}
	if rows[0].FreshInput != 100 || rows[0].CacheRead != 40 || rows[0].CacheWrite != 10 || rows[0].Output != 20 {
		t.Fatalf("row = %+v", rows[0])
	}
}

func TestQueryUsageDailyBoundsAreInclusive(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	base := time.Now()
	for index, offset := range []int{-4, -2, 0} {
		at := base.AddDate(0, 0, offset)
		if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
			usageEvent("evt-"+string(rune('a'+index)), "claude", "claude-opus-5", at,
				&api.AgentUsage{InputTokens: 10, OutputTokens: 1}),
		}); err != nil {
			t.Fatal(err)
		}
	}
	from := base.AddDate(0, 0, -2).Local().Format("2006-01-02")
	to := base.Local().Format("2006-01-02")
	rows, err := s.QueryUsageDaily(ctx, from, to)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %#v, want the two days in range", rows)
	}
	if rows[0].LocalDay != from || rows[1].LocalDay != to {
		t.Fatalf("bounds not inclusive: %s..%s", rows[0].LocalDay, rows[1].LocalDay)
	}
}

func priceRate(value float64) *float64 { return &value }

func TestRepriceUsageDailyFillsCostAndPricedCalls(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	// One million tokens per bucket at Anthropic's claude-opus-5 list prices:
	// 5 + 25 + 0.5 + 6.25 = 36.75 USD.
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-1", "claude", "claude-opus-5", time.Now(), &api.AgentUsage{
			InputTokens:              1_000_000,
			OutputTokens:             1_000_000,
			CacheReadInputTokens:     1_000_000,
			CacheCreationInputTokens: 1_000_000,
		}),
	}); err != nil {
		t.Fatal(err)
	}
	table := &usage.PriceTable{Models: map[string]usage.ModelPrice{
		"claude-opus-5": {
			Input: priceRate(5), Output: priceRate(25),
			CacheRead: priceRate(0.5), CacheWrite: priceRate(6.25),
		},
	}}
	changed, err := s.RepriceUsageDaily(ctx, table)
	if err != nil || changed != 1 {
		t.Fatalf("changed = %d, err = %v", changed, err)
	}
	want := int64(36_750_000_000)
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if rows[0].CostNanoUSD != want {
		t.Fatalf("cost = %d, want %d", rows[0].CostNanoUSD, want)
	}
	if rows[0].PricedCalls != rows[0].Calls {
		t.Fatalf("pricedCalls = %d, calls = %d", rows[0].PricedCalls, rows[0].Calls)
	}
	intervals, err := s.QueryUsageIntervals(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(intervals) != 1 || intervals[0].CostNanoUSD != want || intervals[0].PricedCalls != 1 {
		t.Fatalf("intervals = %+v, want repriced interval cost", intervals)
	}
}

func TestRepriceUsageDailyMarksUnpricedModel(t *testing.T) {
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		// `<synthetic>` really appears in Claude transcripts and is in no catalog.
		usageEvent("evt-1", "claude", "<synthetic>", time.Now(), &api.AgentUsage{
			InputTokens: 1_000_000, OutputTokens: 1_000_000,
		}),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RepriceUsageDaily(ctx, &usage.PriceTable{
		Models: map[string]usage.ModelPrice{"claude-opus-5": {Input: priceRate(5)}},
	}); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if rows[0].CostNanoUSD != 0 || rows[0].PricedCalls != 0 {
		t.Fatalf("row = %+v, want zero cost and zero priced calls", rows[0])
	}
	if rows[0].Calls != 1 || rows[0].Output != 1_000_000 {
		t.Fatalf("tokens must survive an unpriced model: %+v", rows[0])
	}
}

func TestRepriceUsageDailyLeavesPartialRowShortOfCalls(t *testing.T) {
	// A model priced for input/output but not cache: the cost covers only the
	// priced buckets, and pricedCalls must stay below calls so the aggregate is
	// presented as a lower bound.
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-1", "claude", "claude-x", time.Now(), &api.AgentUsage{
			InputTokens: 1_000_000, OutputTokens: 1_000_000, CacheReadInputTokens: 1_000_000,
		}),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RepriceUsageDaily(ctx, &usage.PriceTable{
		Models: map[string]usage.ModelPrice{
			"claude-x": {Input: priceRate(5), Output: priceRate(25)},
		},
	}); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if want := int64(30_000_000_000); rows[0].CostNanoUSD != want {
		t.Fatalf("cost = %d, want %d", rows[0].CostNanoUSD, want)
	}
	if rows[0].PricedCalls != 0 || rows[0].Calls != 1 {
		t.Fatalf("row = %+v, want pricedCalls below calls", rows[0])
	}
}

func TestRepriceUsageDailyRestatesHistoryWhenPricesChange(t *testing.T) {
	// The point of recomputing instead of accruing: a corrected price must be
	// able to restate spend that was already recorded.
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{
		usageEvent("evt-1", "claude", "claude-opus-5", time.Now(), &api.AgentUsage{
			InputTokens: 1_000_000,
		}),
	}); err != nil {
		t.Fatal(err)
	}
	cheap := &usage.PriceTable{Models: map[string]usage.ModelPrice{
		"claude-opus-5": {Input: priceRate(5)},
	}}
	if _, err := s.RepriceUsageDaily(ctx, cheap); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.QueryUsageDaily(ctx, "", "")
	if rows[0].CostNanoUSD != 5_000_000_000 {
		t.Fatalf("cost = %d, want 5 USD", rows[0].CostNanoUSD)
	}

	dearer := &usage.PriceTable{Models: map[string]usage.ModelPrice{
		"claude-opus-5": {Input: priceRate(7)},
	}}
	changed, err := s.RepriceUsageDaily(ctx, dearer)
	if err != nil || changed != 1 {
		t.Fatalf("changed = %d, err = %v", changed, err)
	}
	rows, _ = s.QueryUsageDaily(ctx, "", "")
	if rows[0].CostNanoUSD != 7_000_000_000 {
		t.Fatalf("cost = %d, want the restated 7 USD", rows[0].CostNanoUSD)
	}

	// An unchanged table must report no writes.
	changed, err = s.RepriceUsageDaily(ctx, dearer)
	if err != nil || changed != 0 {
		t.Fatalf("changed = %d, err = %v, want no rewrite", changed, err)
	}
}

func TestUsageRollupReadsRealCanonicalConversion(t *testing.T) {
	// The seam that matters in production: the Service builds canonical events
	// with CanonicalAgentEventFromObservation, and accumulation has to find the
	// usage wherever that function puts it. A synthetic payload would not catch
	// a change to the conversion's key or nesting.
	s := newUsageStore(t, "proj-1")
	ctx := context.Background()
	observation := api.AgentEvent{
		Provider:  "codex",
		Type:      "usage",
		Model:     "gpt-5.6-luna",
		Content:   "Token usage",
		Timestamp: time.Now(),
		Sequence:  1,
		Usage: &api.AgentUsage{
			InputTokens:              33410,
			CacheReadInputTokens:     22389,
			CacheCreationInputTokens: 7623,
			OutputTokens:             495,
			ReasoningOutputTokens:    1,
		},
	}
	event := api.CanonicalAgentEventFromObservation(
		observation, "exec-1", "exec-1", 0, time.Now().UTC(),
	)
	event.EventID = api.StableAgentEventID(observation)
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{event}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.QueryUsageDaily(ctx, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %#v, want the converted event to be counted", rows)
	}
	// Codex's total-basis input, with both cache counters removed.
	if rows[0].FreshInput != 3398 || rows[0].CacheRead != 22389 || rows[0].CacheWrite != 7623 {
		t.Fatalf("row = %+v", rows[0])
	}
	if rows[0].Provider != "codex" || rows[0].Model != "gpt-5.6-luna" {
		t.Fatalf("identity = %+v", rows[0])
	}
}
