package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func newUsageStatsService(t *testing.T) (*Service, *store.AgentEventStore) {
	t.Helper()
	agentStore, err := store.OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = agentStore.Close() })
	agentStore.SetUsageAttributionResolver(func(string) store.UsageAttribution {
		return store.UsageAttribution{ProjectID: "proj-1"}
	})
	prices := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"unit":"usd-per-million-tokens","models":{
			"claude-opus-5":{"provider":"anthropic","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25},
			"gpt-5.6-luna":{"provider":"openai","input":0.2,"output":1.2,"cacheRead":0.02,"cacheWrite":0.25}
		}}`))
	}))
	t.Cleanup(prices.Close)

	service := &Service{AgentStore: agentStore}
	service.usagePrices.Endpoint = prices.URL
	return service, agentStore
}

func appendUsage(t *testing.T, s *store.AgentEventStore, id, stream, provider, model string, at time.Time, value *api.AgentUsage) {
	t.Helper()
	if _, err := s.AppendCanonicalEvents(context.Background(), stream, stream, []api.CanonicalAgentEvent{{
		EventID:    id,
		Type:       "message.completed",
		Origin:     api.AgentEventOrigin{Kind: "provider", Provider: provider},
		OccurredAt: at,
		Payload:    map[string]any{"role": "assistant", "model": model, "usage": value},
	}}); err != nil {
		t.Fatal(err)
	}
}

func TestUsageStatsAggregatesEveryDimension(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	now := time.Now()
	appendUsage(t, agentStore, "evt-1", "exec-1", "claude", "claude-opus-5", now,
		&api.AgentUsage{InputTokens: 1_000_000, OutputTokens: 1_000_000})
	appendUsage(t, agentStore, "evt-2", "exec-1", "codex", "gpt-5.6-luna", now,
		&api.AgentUsage{InputTokens: 1_000_000, OutputTokens: 500_000})

	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	// Claude: 5 + 25 = 30 USD. Codex input is total-basis with no cache, so
	// 0.2 + 0.6 = 0.8 USD.
	if want := int64(30_800_000_000); result.Cost.NanoUSD != want {
		t.Fatalf("cost = %d, want %d", result.Cost.NanoUSD, want)
	}
	if result.Cost.Calls != 2 || result.Cost.PricedCalls != 2 {
		t.Fatalf("cost = %+v, want 2 fully priced calls", result.Cost)
	}
	if !result.Cost.Complete() {
		t.Fatal("cost must read as complete")
	}
	if len(result.Days) != 1 || result.Days[0].Day != now.Local().Format("2006-01-02") {
		t.Fatalf("days = %#v", result.Days)
	}
	if len(result.Providers) != 2 || len(result.Models) != 2 || len(result.Projects) != 1 {
		t.Fatalf("groups: providers=%d models=%d projects=%d",
			len(result.Providers), len(result.Models), len(result.Projects))
	}
	// Ordered by cost descending, so the dominant consumer leads.
	if result.Providers[0].Key != "claude" {
		t.Fatalf("providers = %#v, want claude first", result.Providers)
	}
	if result.Total.FreshInput != 2_000_000 || result.Total.Output != 1_500_000 {
		t.Fatalf("total = %+v", result.Total)
	}
	// Both calls fall in one 5-minute bucket but belong to different models, and
	// the rows stay apart so the curve can be filtered. They still sum to the day.
	if result.IntervalBucketMinutes != 5 || len(result.Intervals) != 2 {
		t.Fatalf("intervals = %#v, want one row per model in the bucket", result.Intervals)
	}
	var intervalCost, intervalTokens int64
	for _, interval := range result.Intervals {
		if interval.Minute != result.Intervals[0].Minute {
			t.Fatalf("intervals = %#v, want a single 5-minute bucket", result.Intervals)
		}
		if interval.Provider == "" || interval.Model == "" {
			t.Fatalf("interval = %+v, want its provider and model so a filter can act", interval)
		}
		intervalCost += interval.Cost.NanoUSD
		intervalTokens += interval.Buckets.Total()
	}
	if intervalCost != result.Cost.NanoUSD || intervalTokens != result.Total.Total() {
		t.Fatalf("intervals sum to cost %d tokens %d, want %d and %d",
			intervalCost, intervalTokens, result.Cost.NanoUSD, result.Total.Total())
	}
	// Money is split by the class that incurred it, and always sums to the amount.
	if result.Cost.ByBucket.Total() != result.Cost.NanoUSD {
		t.Fatalf("byBucket = %+v, want it to sum to %d", result.Cost.ByBucket, result.Cost.NanoUSD)
	}
	// 2M fresh input priced at $5 and $0.2 per million, against 1.5M output at
	// $25 and $1.2: the same tokens, a very different money shape.
	if result.Cost.ByBucket.FreshInput != 5_200_000_000 ||
		result.Cost.ByBucket.Output != 25_600_000_000 {
		t.Fatalf("byBucket = %+v", result.Cost.ByBucket)
	}
	if result.PricesFetchedAt == "" {
		t.Fatal("want the price fetch time so a client can show staleness")
	}
}

func TestRebuildUsageReplacesDerivedRowsWithoutTouchingJournal(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	base := time.Date(2026, time.September, 10, 10, 5, 0, 0, time.Local)
	appendUsage(t, agentStore, "evt-rebuild-a", "exec-1", "claude", "claude-opus-5", base,
		&api.AgentUsage{InputTokens: 100, OutputTokens: 20})

	result, err := service.RebuildUsage(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !result.Rebuilt || result.Observations != 1 || result.Calls != 1 || result.Days != 1 {
		t.Fatalf("result = %+v", result)
	}
	stats, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Total.FreshInput != 100 || stats.Total.Output != 20 || stats.Cost.Calls != 1 {
		t.Fatalf("stats after rebuild = %+v", stats)
	}
	history, err := agentStore.QueryCanonicalEvents(context.Background(), "exec-1", 0, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(history.Events) != 1 {
		t.Fatalf("journal rows = %d, want one untouched source row", len(history.Events))
	}
	// The age of the figures travels with them: a panel cannot otherwise tell
	// numbers a current parser produced from ones an older release left behind.
	if result.CompletedAt == "" {
		t.Error("rebuild result must say when it finished")
	}
	if stats.LastRebuild == nil {
		t.Fatal("stats must carry the stamp of the rebuild that produced them")
	}
	if stats.LastRebuild.CompletedAt != result.CompletedAt {
		t.Errorf("stats stamp = %q, want the rebuild's %q",
			stats.LastRebuild.CompletedAt, result.CompletedAt)
	}
	if len(stats.LastRebuild.Providers) != 1 || stats.LastRebuild.Providers[0] != "claude" {
		t.Errorf("stamp providers = %v, want only the replaced claude", stats.LastRebuild.Providers)
	}
}

func TestUsageStatsOmitsTheStampBeforeAnyRebuild(t *testing.T) {
	// Live accumulation alone leaves the projection unstamped, and reporting a
	// time anyway would claim a correction that never ran.
	service, agentStore := newUsageStatsService(t)
	appendUsage(t, agentStore, "evt-live", "exec-1", "claude", "claude-opus-5",
		time.Date(2026, time.September, 10, 10, 5, 0, 0, time.Local),
		&api.AgentUsage{InputTokens: 100, OutputTokens: 20})
	stats, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Total.FreshInput != 100 {
		t.Fatalf("live accumulation lost tokens: %+v", stats.Total)
	}
	if stats.LastRebuild != nil {
		t.Errorf("lastRebuild = %+v, want absent until a rebuild runs", stats.LastRebuild)
	}
}

func TestRebuildUsageReadsHistoricalTranscriptsWithCurrentParser(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	root := t.TempDir()
	codexRoot := filepath.Join(root, "codex")
	claudeRoot := filepath.Join(root, "claude")
	if err := os.MkdirAll(filepath.Join(codexRoot, "2026"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(claudeRoot, "project"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(codexRoot, "2026", "rollout-one.jsonl"), []byte(
		`{"timestamp":"2026-09-10T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-luna"}}
{"timestamp":"2026-09-10T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}
`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(claudeRoot, "project", "session.jsonl"), []byte(
		`{"type":"assistant","uuid":"a1","timestamp":"2026-09-10T10:01:00Z","cwd":"/work/warren","message":{"id":"msg-1","model":"claude-opus-5","content":[{"type":"thinking","thinking":"think"}],"usage":{"input_tokens":200,"output_tokens":30}}}
{"type":"assistant","uuid":"a2","timestamp":"2026-09-10T10:01:01Z","cwd":"/work/warren","message":{"id":"msg-1","model":"claude-opus-5","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":200,"output_tokens":30}}}
`), 0o600); err != nil {
		t.Fatal(err)
	}
	piRoot := filepath.Join(root, "pi")
	if err := os.MkdirAll(filepath.Join(piRoot, "session"), 0o755); err != nil {
		t.Fatal(err)
	}
	// pi reports tokens, so leaving it out of the rebuild would keep aggregates
	// no maintenance action could ever correct. Its usage rides on one message
	// whose content splits into several blocks, which must count once.
	if err := os.WriteFile(filepath.Join(piRoot, "session", "2026_pi.jsonl"), []byte(
		`{"type":"session","id":"pi-session-1","timestamp":"2026-09-10T10:02:00Z","cwd":"/work/warren"}
{"type":"model_change","id":"m1","timestamp":"2026-09-10T10:02:01Z","provider":"deepseek","modelId":"deepseek-v4.1-flash"}
{"type":"message","id":"r1","timestamp":"2026-09-10T10:02:02Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"plan"},{"type":"text","text":"done"}],"usage":{"input":50,"output":6,"totalTokens":56}}}
`), 0o600); err != nil {
		t.Fatal(err)
	}
	service.AgentFinder = agent.DefaultFinder{CodexRoot: codexRoot, ClaudeRoot: claudeRoot, PiRoot: piRoot}
	appendUsage(t, agentStore, "evt-journal-only", "exec-journal", "claude", "claude-opus-5", time.Date(2026, time.September, 10, 9, 0, 0, 0, time.UTC),
		&api.AgentUsage{InputTokens: 999, OutputTokens: 999})

	result, err := service.RebuildUsage(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !result.Rebuilt || result.Observations != 3 || result.Calls != 3 || result.Days != 1 {
		t.Fatalf("result = %+v", result)
	}
	if len(result.Providers) != 3 {
		t.Fatalf("providers = %#v, want every measured provider replaced", result.Providers)
	}
	stats, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Cost.Calls != 3 || stats.Total.FreshInput != 350 || stats.Total.Output != 56 {
		t.Fatalf("stats after transcript rebuild = %+v", stats)
	}
	history, err := agentStore.QueryCanonicalEvents(context.Background(), "exec-journal", 0, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(history.Events) != 1 {
		t.Fatalf("canonical journal rows = %d, want untouched journal", len(history.Events))
	}
}

func TestUsageStatsSortsAndMergesIntradayBuckets(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	base := time.Date(2026, time.September, 10, 10, 5, 0, 0, time.Local)
	appendUsage(t, agentStore, "evt-a", "exec-1", "claude", "claude-opus-5", base,
		&api.AgentUsage{InputTokens: 10, OutputTokens: 1})
	appendUsage(t, agentStore, "evt-b", "exec-2", "codex", "gpt-5.6-luna", base.Add(4*time.Minute),
		&api.AgentUsage{InputTokens: 20, OutputTokens: 2})
	appendUsage(t, agentStore, "evt-c", "exec-3", "claude", "claude-opus-5", base.Add(5*time.Minute),
		&api.AgentUsage{InputTokens: 30, OutputTokens: 3})

	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{
		FromDay: base.Format("2006-01-02"),
		ToDay:   base.Format("2006-01-02"),
	})
	if err != nil {
		t.Fatal(err)
	}
	// Two 5-minute buckets, with the first split by model. Ordered by time first
	// so a client can walk the day without sorting, and by provider and model
	// within a bucket so the order is stable across requests.
	if len(result.Intervals) != 3 {
		t.Fatalf("intervals = %#v, want the 10:05 bucket split by model", result.Intervals)
	}
	if result.Intervals[0].Minute != 605 || result.Intervals[0].Provider != "claude" ||
		result.Intervals[0].Buckets.Total() != 11 || result.Intervals[0].Cost.Calls != 1 {
		t.Fatalf("first interval = %+v", result.Intervals[0])
	}
	if result.Intervals[1].Minute != 605 || result.Intervals[1].Provider != "codex" ||
		result.Intervals[1].Buckets.Total() != 22 {
		t.Fatalf("second interval = %+v", result.Intervals[1])
	}
	if result.Intervals[2].Minute != 610 || result.Intervals[2].Buckets.Total() != 33 ||
		result.Intervals[2].Cost.Calls != 1 {
		t.Fatalf("third interval = %+v", result.Intervals[2])
	}
	// Filtering the curve to one Agent must leave the rest of the day out of it.
	var claudeTokens int64
	for _, interval := range result.Intervals {
		if interval.Provider == "claude" {
			claudeTokens += interval.Buckets.Total()
		}
	}
	if claudeTokens != 44 {
		t.Fatalf("claude intervals total %d, want 44", claudeTokens)
	}
}

func TestUsageStatsMarksIncompletePricing(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	// A model absent from the price table must leave the range a lower bound.
	appendUsage(t, agentStore, "evt-1", "exec-1", "claude", "<synthetic>", time.Now(),
		&api.AgentUsage{InputTokens: 1_000_000, OutputTokens: 1_000_000})

	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Cost.NanoUSD != 0 || result.Cost.Calls != 1 || result.Cost.PricedCalls != 0 {
		t.Fatalf("cost = %+v", result.Cost)
	}
	if result.Cost.Complete() {
		t.Fatal("an unpriced call must not read as complete")
	}
	// Naming the model is what makes the gap actionable.
	if len(result.Cost.UnpricedModels) != 1 || result.Cost.UnpricedModels[0] != "<synthetic>" {
		t.Fatalf("unpricedModels = %#v, want the model that could not be priced", result.Cost.UnpricedModels)
	}
	// Tokens are still reported: the spend happened even if its price is unknown.
	if result.Total.FreshInput != 1_000_000 {
		t.Fatalf("total = %+v", result.Total)
	}
}

func TestUsageStatsPricesEveryFigureFromOneTable(t *testing.T) {
	// Cost is derived on read rather than stored, so the range total, the day, the
	// breakdowns and the intraday buckets must all agree by construction. The
	// stored-cost design they replaced could disagree whenever the process that
	// owned the "needs repricing" flag restarted.
	service, agentStore := newUsageStatsService(t)
	base := time.Date(2026, time.September, 10, 10, 5, 0, 0, time.Local)
	appendUsage(t, agentStore, "evt-a", "exec-1", "claude", "claude-opus-5", base,
		&api.AgentUsage{InputTokens: 1_000_000, OutputTokens: 1_000_000})
	appendUsage(t, agentStore, "evt-b", "exec-2", "codex", "gpt-5.6-luna", base.Add(time.Hour),
		&api.AgentUsage{InputTokens: 1_000_000, OutputTokens: 500_000})

	day := base.Format("2006-01-02")
	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{
		FromDay: day, ToDay: day, IntervalDay: day,
	})
	if err != nil {
		t.Fatal(err)
	}
	var intervalCost, providerCost, dayCost int64
	for _, interval := range result.Intervals {
		intervalCost += interval.Cost.NanoUSD
	}
	for _, provider := range result.Providers {
		providerCost += provider.Cost.NanoUSD
	}
	for _, entry := range result.Days {
		dayCost += entry.Cost.NanoUSD
	}
	if want := int64(30_800_000_000); result.Cost.NanoUSD != want {
		t.Fatalf("range cost = %d, want %d", result.Cost.NanoUSD, want)
	}
	if intervalCost != result.Cost.NanoUSD || providerCost != result.Cost.NanoUSD || dayCost != result.Cost.NanoUSD {
		t.Fatalf("intervals %d, providers %d, days %d must each sum to the range total %d",
			intervalCost, providerCost, dayCost, result.Cost.NanoUSD)
	}
}

func TestUsageStatsRestrictsToRequestedRange(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	now := time.Now()
	appendUsage(t, agentStore, "evt-old", "exec-1", "claude", "claude-opus-5", now.AddDate(0, 0, -10),
		&api.AgentUsage{InputTokens: 1_000_000})
	appendUsage(t, agentStore, "evt-new", "exec-1", "claude", "claude-opus-5", now,
		&api.AgentUsage{InputTokens: 2_000_000})

	from := now.AddDate(0, 0, -1).Local().Format("2006-01-02")
	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{FromDay: from})
	if err != nil {
		t.Fatal(err)
	}
	if result.Total.FreshInput != 2_000_000 {
		t.Fatalf("total = %+v, want only the in-range day", result.Total)
	}
	if len(result.Days) != 1 {
		t.Fatalf("days = %#v", result.Days)
	}
}

func TestUsageStatsSwapsInvertedRange(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	now := time.Now()
	appendUsage(t, agentStore, "evt-1", "exec-1", "claude", "claude-opus-5", now,
		&api.AgentUsage{InputTokens: 1_000_000})
	today := now.Local().Format("2006-01-02")
	earlier := now.AddDate(0, 0, -3).Local().Format("2006-01-02")

	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{
		FromDay: today, ToDay: earlier,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.FromDay != earlier || result.ToDay != today {
		t.Fatalf("range = %s..%s, want it normalized", result.FromDay, result.ToDay)
	}
	if result.Total.FreshInput != 1_000_000 {
		t.Fatalf("total = %+v", result.Total)
	}
}

func TestUsageStatsKeepsTokensWhenPricingIsUnreachable(t *testing.T) {
	// Losing the pricing endpoint must not withhold token counts.
	agentStore, err := store.OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer agentStore.Close()
	agentStore.SetUsageAttributionResolver(func(string) store.UsageAttribution {
		return store.UsageAttribution{}
	})
	service := &Service{AgentStore: agentStore}
	service.usagePrices.Endpoint = "http://127.0.0.1:1/nonexistent"

	appendUsage(t, agentStore, "evt-1", "exec-1", "claude", "claude-opus-5", time.Now(),
		&api.AgentUsage{InputTokens: 1_000_000, OutputTokens: 500_000})

	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatalf("unreachable pricing must not fail the query: %v", err)
	}
	if result.Total.FreshInput != 1_000_000 || result.Total.Output != 500_000 {
		t.Fatalf("total = %+v", result.Total)
	}
	if result.Cost.PricedCalls != 0 || result.Cost.Complete() {
		t.Fatalf("cost = %+v, want an explicitly incomplete amount", result.Cost)
	}
	if result.PricesFetchedAt != "" {
		t.Fatal("no price table was fetched, so no fetch time may be claimed")
	}
}

func TestUsageStatsScopesIntradayPayloadAndDayGroupsToTheRequestedDay(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	older := time.Date(2026, time.September, 8, 10, 5, 0, 0, time.Local)
	newer := time.Date(2026, time.September, 9, 11, 5, 0, 0, time.Local)
	appendUsage(t, agentStore, "evt-1", "exec-1", "claude", "claude-opus-5", older,
		&api.AgentUsage{InputTokens: 100})
	appendUsage(t, agentStore, "evt-2", "exec-2", "codex", "gpt-5.6-luna", newer,
		&api.AgentUsage{InputTokens: 200})

	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{
		FromDay:     "2026-09-08",
		ToDay:       "2026-09-09",
		IntervalDay: "2026-09-08",
	})
	if err != nil {
		t.Fatal(err)
	}
	// Daily rows still cover the whole range, or the heatmap would lose days.
	if len(result.Days) != 2 {
		t.Fatalf("days = %#v, want the full range", result.Days)
	}
	if result.DetailDay != "2026-09-08" {
		t.Fatalf("detailDay = %q", result.DetailDay)
	}
	// Only the requested day's five-minute buckets travel, not the whole range.
	if len(result.Intervals) != 1 || result.Intervals[0].Day != "2026-09-08" {
		t.Fatalf("intervals = %#v, want only the requested day", result.Intervals)
	}
	if len(result.DayProviders) != 1 || result.DayProviders[0].Key != "claude" {
		t.Fatalf("dayProviders = %#v, want only the selected day's agent", result.DayProviders)
	}
	if len(result.Providers) != 2 {
		t.Fatalf("providers = %#v, want the whole range", result.Providers)
	}
}

func TestUsageStatsDefaultsDetailDayToTheMostRecentDay(t *testing.T) {
	service, agentStore := newUsageStatsService(t)
	older := time.Date(2026, time.September, 8, 10, 5, 0, 0, time.Local)
	newer := time.Date(2026, time.September, 9, 11, 5, 0, 0, time.Local)
	appendUsage(t, agentStore, "evt-1", "exec-1", "claude", "claude-opus-5", older,
		&api.AgentUsage{InputTokens: 100})
	appendUsage(t, agentStore, "evt-2", "exec-2", "codex", "gpt-5.6-luna", newer,
		&api.AgentUsage{InputTokens: 200})

	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{
		FromDay: "2026-09-08",
		ToDay:   "2026-09-09",
	})
	if err != nil {
		t.Fatal(err)
	}
	// The client opens on the newest curve before anyone picks a day.
	if result.DetailDay != "2026-09-09" {
		t.Fatalf("detailDay = %q, want the most recent day", result.DetailDay)
	}
	if len(result.Intervals) != 1 || result.Intervals[0].Day != "2026-09-09" {
		t.Fatalf("intervals = %#v, want only the most recent day", result.Intervals)
	}
}

func TestUsageStatsUnmeasuredProvidersRespectTheRequestedRange(t *testing.T) {
	service, _ := newUsageStatsService(t)
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session-qoder", Kind: "agent", AgentProvider: "qoder",
			Runtime: "qoder", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service.Store = state

	// A historical window must not be blamed for today's Agents.
	historical := time.Now().AddDate(0, 0, -100).Format("2006-01-02")
	result, err := service.UsageStats(context.Background(), api.UsageStatsRequest{
		FromDay: historical, ToDay: historical,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Cost.UnmeasuredProviders) != 0 {
		t.Fatalf("unmeasured = %#v, want none on a historical range", result.Cost.UnmeasuredProviders)
	}

	// A window that includes the running session reports the gap.
	result, err = service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Cost.UnmeasuredProviders) != 1 || result.Cost.UnmeasuredProviders[0] != "qoder" {
		t.Fatalf("unmeasured = %#v, want qoder", result.Cost.UnmeasuredProviders)
	}
}

func TestUsageStatsWithoutAgentStoreIsEmpty(t *testing.T) {
	result, err := (&Service{}).UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Cost.Calls != 0 || len(result.Days) != 0 {
		t.Fatalf("result = %#v", result)
	}
	if result.FromDay == "" || result.ToDay == "" {
		t.Fatal("the requested range must still be echoed")
	}
}
