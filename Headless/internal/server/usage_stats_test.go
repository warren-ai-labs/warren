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
	if result.IntervalBucketMinutes != 5 || len(result.Intervals) != 1 {
		t.Fatalf("intervals = %#v, want one canonical 5-minute bucket", result.Intervals)
	}
	if result.Intervals[0].Cost.NanoUSD != result.Cost.NanoUSD ||
		result.Intervals[0].Buckets.Total() != result.Total.Total() {
		t.Fatalf("interval = %+v, total = %+v, want matching aggregate", result.Intervals[0], result.Total)
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
	if !result.Rebuilt || result.Events != 1 || result.Calls != 1 || result.Days != 1 {
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
	service.AgentFinder = agent.DefaultFinder{CodexRoot: codexRoot, ClaudeRoot: claudeRoot}
	appendUsage(t, agentStore, "evt-journal-only", "exec-journal", "claude", "claude-opus-5", time.Date(2026, time.September, 10, 9, 0, 0, 0, time.UTC),
		&api.AgentUsage{InputTokens: 999, OutputTokens: 999})

	result, err := service.RebuildUsage(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !result.Rebuilt || result.Events != 2 || result.Calls != 2 || result.Days != 1 {
		t.Fatalf("result = %+v", result)
	}
	stats, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Cost.Calls != 2 || stats.Total.FreshInput != 300 || stats.Total.Output != 50 {
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
	if len(result.Intervals) != 2 {
		t.Fatalf("intervals = %#v, want two buckets", result.Intervals)
	}
	if result.Intervals[0].Minute != 605 || result.Intervals[0].Buckets.Total() != 33 ||
		result.Intervals[0].Cost.Calls != 2 {
		t.Fatalf("first interval = %+v", result.Intervals[0])
	}
	if result.Intervals[1].Minute != 610 || result.Intervals[1].Buckets.Total() != 33 ||
		result.Intervals[1].Cost.Calls != 1 {
		t.Fatalf("second interval = %+v", result.Intervals[1])
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
	// Tokens are still reported: the spend happened even if its price is unknown.
	if result.Total.FreshInput != 1_000_000 {
		t.Fatalf("total = %+v", result.Total)
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
