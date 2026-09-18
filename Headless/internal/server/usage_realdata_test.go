package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// TestUsageRebuildAgainstLocalTranscripts runs the whole Usage path -- discovery,
// every adapter, dedupe, aggregation, and pricing -- over this machine's own
// transcripts, then checks the invariants that only break at real scale:
//
//   - every day sums to the range total, so no surface can disagree with another
//   - a repeated rebuild moves nothing, so the operation is safe to redo
//
// The figures are logged rather than asserted, because they depend on local
// history. Run with:
//
//	WARREN_USAGE_REALDATA=1 go test ./Headless/internal/server/ -run LocalTranscripts -v
//
// Skipped by default so the suite stays hermetic.
func TestUsageRebuildAgainstLocalTranscripts(t *testing.T) {
	if os.Getenv("WARREN_USAGE_REALDATA") == "" {
		t.Skip("set WARREN_USAGE_REALDATA=1 to measure against local transcripts")
	}
	agentStore, err := store.OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer agentStore.Close()
	agentStore.SetUsageAttributionResolver(func(string) store.UsageAttribution {
		return store.UsageAttribution{}
	})
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	service := &Service{AgentStore: agentStore}
	// Codex history is bounded to the current month: the full rollout tree is
	// tens of thousands of files, and the invariants under test do not need them.
	service.AgentFinder = agent.DefaultFinder{
		ClaudeRoot: filepath.Join(home, ".claude", "projects"),
		CodexRoot:  filepath.Join(home, ".codex", "sessions", "2026", "09"),
		PiRoot:     agent.PiSessionsRoot(),
	}
	result, err := service.RebuildUsage(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("rebuild: providers=%v observations=%d calls=%d collapsed=%d days=%d",
		result.Providers, result.Observations, result.Calls, result.Observations-result.Calls, result.Days)

	stats, err := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("range %s..%s calls=%d priced=%d cost=$%.2f unpriced=%v",
		stats.FromDay, stats.ToDay, stats.Cost.Calls, stats.Cost.PricedCalls,
		float64(stats.Cost.NanoUSD)/1e9, stats.Cost.UnpricedModels)
	t.Logf("total tokens=%d (fresh %d cacheRead %d cacheWrite %d out %d reasoning %d)",
		stats.Total.Total(), stats.Total.FreshInput, stats.Total.CacheRead,
		stats.Total.CacheWrite, stats.Total.Output, stats.Total.Reasoning)
	for _, p := range stats.Providers {
		t.Logf("  provider %-8s calls=%-6d cost=$%.2f priced=%d", p.Key, p.Cost.Calls,
			float64(p.Cost.NanoUSD)/1e9, p.Cost.PricedCalls)
	}
	for _, m := range stats.Models {
		t.Logf("  model %-24s calls=%-6d cost=$%.2f", m.Key, m.Cost.Calls, float64(m.Cost.NanoUSD)/1e9)
	}
	// The two shapes the panel shows side by side. They disagree sharply, which is
	// the reason the token bar alone is not an answer to "where did it go".
	share := func(part, whole int64) float64 {
		if whole == 0 {
			return 0
		}
		return 100 * float64(part) / float64(whole)
	}
	tokens, money := stats.Total.Total(), stats.Cost.ByBucket
	t.Logf("token mix: fresh %.1f%% cacheWrite %.1f%% cacheRead %.1f%% output %.1f%%",
		share(stats.Total.FreshInput, tokens), share(stats.Total.CacheWrite, tokens),
		share(stats.Total.CacheRead, tokens), share(stats.Total.Output, tokens))
	t.Logf("cost mix:  fresh %.1f%% cacheWrite %.1f%% cacheRead %.1f%% output %.1f%%",
		share(money.FreshInput, money.Total()), share(money.CacheWrite, money.Total()),
		share(money.CacheRead, money.Total()), share(money.Output, money.Total()))
	if money.Total() != stats.Cost.NanoUSD {
		t.Errorf("cost split sums to %d, want the amount %d", money.Total(), stats.Cost.NanoUSD)
	}

	// Days must sum to the range total, and intervals to their day.
	var dayCalls, dayCost int64
	for _, d := range stats.Days {
		dayCalls += d.Cost.Calls
		dayCost += d.Cost.NanoUSD
	}
	if dayCalls != stats.Cost.Calls || dayCost != stats.Cost.NanoUSD {
		t.Errorf("days sum calls=%d cost=%d but range says calls=%d cost=%d",
			dayCalls, dayCost, stats.Cost.Calls, stats.Cost.NanoUSD)
	}
	// The intraday payload is one day split by Agent and model, which is what the
	// curve filter acts on. Its cardinality is worth watching: it is the only list
	// here that grows with both time and model count.
	var detailCost int64
	models := map[string]struct{}{}
	for _, interval := range stats.Intervals {
		if interval.Day != stats.DetailDay {
			t.Errorf("interval %+v is outside the detail day %s", interval, stats.DetailDay)
		}
		detailCost += interval.Cost.NanoUSD
		models[interval.Model] = struct{}{}
	}
	for _, d := range stats.Days {
		if d.Day == stats.DetailDay && detailCost != d.Cost.NanoUSD {
			t.Errorf("intervals sum to %d but day %s costs %d", detailCost, d.Day, d.Cost.NanoUSD)
		}
	}
	t.Logf("detail day %s: %d interval rows across %d models",
		stats.DetailDay, len(stats.Intervals), len(models))
	// A second rebuild must be idempotent.
	second, err := service.RebuildUsage(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if second.Calls != result.Calls {
		t.Errorf("second rebuild calls=%d, want the same %d", second.Calls, result.Calls)
	}
	after, _ := service.UsageStats(context.Background(), api.UsageStatsRequest{})
	if after.Total.Total() != stats.Total.Total() {
		t.Errorf("totals moved on a repeat rebuild: %d then %d", stats.Total.Total(), after.Total.Total())
	}
}
