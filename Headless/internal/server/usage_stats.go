package server

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/abcdlsj/warren/Headless/internal/usage"
)

// usageStatsDefaultDays is the range used when a request names no bounds. It
// covers a year so the heatmap has a full grid to draw on first open.
const usageStatsDefaultDays = 365

// RebuildUsage replaces only the derived Usage projections from every retained
// Codex/Claude transcript file. The current parser is deliberately run again
// so historical duplicate observations are corrected without rewriting the
// canonical Agent journal or any other database.
func (s *Service) RebuildUsage(ctx context.Context) (api.UsageRebuildResult, error) {
	if s.AgentStore == nil {
		return api.UsageRebuildResult{}, nil
	}
	// Embedders and focused tests may intentionally disable transcript
	// discovery. Preserve their journal-only maintenance path; production
	// Headless wires the stock DefaultFinder and therefore takes the
	// parser-backed path below. A custom Finder has no historical enumeration
	// contract, so it must also use the journal fallback rather than silently
	// scanning this process's default home directories.
	finder, hasHistoricalFinder := historicalUsageFinder(s.AgentFinder)
	if !hasHistoricalFinder {
		result, err := s.AgentStore.RebuildUsageRollups(ctx)
		if err != nil {
			return api.UsageRebuildResult{}, err
		}
		return api.UsageRebuildResult{
			Rebuilt: true,
			Events:  result.Events,
			Calls:   result.Calls,
			Days:    result.Days,
		}, nil
	}
	transcripts, err := finder.HistoricalUsageTranscripts(ctx)
	if err != nil {
		return api.UsageRebuildResult{}, fmt.Errorf("discover historical Usage transcripts: %w", err)
	}
	observations := make([]store.UsageRebuildObservation, 0)
	for _, transcript := range transcripts {
		events, readErr := agent.ReadTranscriptUsage(ctx, transcript.Provider, transcript.Path)
		if readErr != nil {
			return api.UsageRebuildResult{}, fmt.Errorf("read historical Usage transcript %q: %w", transcript.Path, readErr)
		}
		projectID := s.usageProjectForWorkspacePath(transcript.WorkspacePath)
		for _, event := range events {
			if event.Usage == nil {
				continue
			}
			observations = append(observations, store.UsageRebuildObservation{
				Provider:   transcript.Provider,
				Model:      event.Model,
				ProjectID:  projectID,
				OccurredAt: event.Timestamp,
				Usage:      *event.Usage,
			})
		}
	}

	result, err := s.AgentStore.RebuildUsageRollupsFromObservations(ctx, observations)
	if err != nil {
		return api.UsageRebuildResult{}, err
	}
	return api.UsageRebuildResult{
		Rebuilt: true,
		Events:  result.Events,
		Calls:   result.Calls,
		Days:    result.Days,
	}, nil
}

func historicalUsageFinder(value agent.Finder) (agent.DefaultFinder, bool) {
	switch configured := value.(type) {
	case agent.DefaultFinder:
		return configured, true
	case *agent.DefaultFinder:
		if configured != nil {
			return *configured, true
		}
	}
	return agent.DefaultFinder{}, false
}

func (s *Service) usageProjectForWorkspacePath(path string) string {
	path = strings.TrimSpace(path)
	if path == "" || s.Store == nil {
		return ""
	}
	path = usageCleanPath(path)
	state := s.Store.Snapshot()
	for _, workspace := range state.Workspaces {
		if usageCleanPath(workspace.Path) == path {
			return strings.TrimSpace(workspace.ProjectID)
		}
	}
	for _, project := range state.Projects {
		if usageCleanPath(project.Path) == path {
			return strings.TrimSpace(project.ID)
		}
	}
	return ""
}

func usageCleanPath(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return filepath.Clean(abs)
}

// UsageStats aggregates the durable rollup for one local-day range.
//
// Aggregation happens here rather than on the client because a client's event
// replica is a bounded cache: folding it would silently under-report older
// spend. Prices are refreshed opportunistically, and a failure to reach the
// pricing endpoint leaves token counts intact with cost marked incomplete.
func (s *Service) UsageStats(ctx context.Context, request api.UsageStatsRequest) (api.UsageStatsResult, error) {
	fromDay := strings.TrimSpace(request.FromDay)
	toDay := strings.TrimSpace(request.ToDay)
	if toDay == "" {
		toDay = time.Now().Local().Format("2006-01-02")
	}
	if fromDay == "" {
		fromDay = time.Now().Local().AddDate(0, 0, -usageStatsDefaultDays).Format("2006-01-02")
	}
	if fromDay > toDay {
		fromDay, toDay = toDay, fromDay
	}
	result := api.UsageStatsResult{
		FromDay:               fromDay,
		ToDay:                 toDay,
		IntervalBucketMinutes: api.UsageIntervalBucketMinutes,
	}
	if s.AgentStore == nil {
		return result, nil
	}

	// Repricing before reading keeps a stored cost from lagging a price change.
	// It is best effort: stale or absent prices must not withhold token counts.
	if table, err := s.usagePrices.Table(ctx); err == nil && table != nil {
		if _, err := s.AgentStore.RepriceUsageDaily(ctx, table); err != nil {
			s.logWarn("reprice usage rollup", "error", err)
		}
		result.PricesFetchedAt = table.FetchedAt.UTC().Format(time.RFC3339)
	} else if err != nil {
		s.logWarn("fetch model pricing", "error", err)
	}

	rows, err := s.AgentStore.QueryUsageDaily(ctx, fromDay, toDay)
	if err != nil {
		return api.UsageStatsResult{}, err
	}
	intervalRows, err := s.AgentStore.QueryUsageIntervals(ctx, fromDay, toDay)
	if err != nil {
		return api.UsageStatsResult{}, err
	}

	projectNames := s.usageProjectNames()
	days := map[string]*api.UsageDayStats{}
	intervals := map[usageIntervalKey]*api.UsageIntervalStats{}
	providers := map[string]*api.UsageGroupStats{}
	models := map[string]*api.UsageGroupStats{}
	projects := map[string]*api.UsageGroupStats{}

	for _, row := range rows {
		buckets := api.UsageBuckets{
			FreshInput: row.FreshInput,
			CacheWrite: row.CacheWrite,
			CacheRead:  row.CacheRead,
			Output:     row.Output,
			Reasoning:  row.Reasoning,
		}
		cost := api.UsageCost{
			NanoUSD:     row.CostNanoUSD,
			Calls:       row.Calls,
			PricedCalls: row.PricedCalls,
		}
		addUsageBuckets(&result.Total, buckets)
		addUsageCost(&result.Cost, cost)

		day := usageDayEntry(days, row.LocalDay)
		addUsageBuckets(&day.Buckets, buckets)
		addUsageCost(&day.Cost, cost)

		provider := usageGroupEntry(providers, row.Provider, "")
		addUsageBuckets(&provider.Buckets, buckets)
		addUsageCost(&provider.Cost, cost)

		model := usageGroupEntry(models, row.Model, "")
		addUsageBuckets(&model.Buckets, buckets)
		addUsageCost(&model.Cost, cost)

		project := usageGroupEntry(projects, row.ProjectID, projectNames[row.ProjectID])
		addUsageBuckets(&project.Buckets, buckets)
		addUsageCost(&project.Cost, cost)
	}

	for _, row := range intervalRows {
		buckets := api.UsageBuckets{
			FreshInput: row.FreshInput,
			CacheWrite: row.CacheWrite,
			CacheRead:  row.CacheRead,
			Output:     row.Output,
			Reasoning:  row.Reasoning,
		}
		cost := api.UsageCost{
			NanoUSD:     row.CostNanoUSD,
			Calls:       row.Calls,
			PricedCalls: row.PricedCalls,
		}
		key := usageIntervalKey{day: row.LocalDay, minute: row.BucketStartMin}
		interval := usageIntervalEntry(intervals, key)
		addUsageBuckets(&interval.Buckets, buckets)
		addUsageCost(&interval.Cost, cost)
	}

	// Providers that report no token counts cannot appear in the rollup at all,
	// so their absence is recorded explicitly. Without this the panel would show
	// a total that silently excludes whole Agents.
	unmeasured := s.usageUnmeasuredProviders()
	result.Cost.UnmeasuredProviders = unmeasured

	result.Days = sortedUsageDays(days)
	result.Intervals = sortedUsageIntervals(intervals)
	result.Providers = sortedUsageGroups(providers)
	result.Models = sortedUsageGroups(models)
	result.Projects = sortedUsageGroups(projects)
	return result, nil
}

type usageIntervalKey struct {
	day    string
	minute int
}

// usageUnmeasuredProviders lists providers bound to sessions that exist right
// now but whose transcripts carry no token counts.
func (s *Service) usageUnmeasuredProviders() []string {
	if s.Store == nil {
		return nil
	}
	seen := map[string]struct{}{}
	for _, session := range s.Store.Snapshot().Sessions {
		provider := strings.TrimSpace(session.AgentProvider)
		if provider == "" {
			continue
		}
		if usage.SemanticsFor(provider).Reports {
			continue
		}
		seen[provider] = struct{}{}
	}
	if len(seen) == 0 {
		return nil
	}
	result := make([]string, 0, len(seen))
	for provider := range seen {
		result = append(result, provider)
	}
	sort.Strings(result)
	return result
}

func (s *Service) usageProjectNames() map[string]string {
	names := map[string]string{}
	if s.Store == nil {
		return names
	}
	for _, project := range s.Store.Snapshot().Projects {
		names[project.ID] = project.Name
	}
	return names
}

func usageDayEntry(days map[string]*api.UsageDayStats, day string) *api.UsageDayStats {
	if entry, ok := days[day]; ok {
		return entry
	}
	entry := &api.UsageDayStats{Day: day}
	days[day] = entry
	return entry
}

func usageIntervalEntry(
	intervals map[usageIntervalKey]*api.UsageIntervalStats,
	key usageIntervalKey,
) *api.UsageIntervalStats {
	if entry, ok := intervals[key]; ok {
		return entry
	}
	entry := &api.UsageIntervalStats{Day: key.day, Minute: key.minute}
	intervals[key] = entry
	return entry
}

func usageGroupEntry(groups map[string]*api.UsageGroupStats, key, label string) *api.UsageGroupStats {
	if entry, ok := groups[key]; ok {
		if entry.Label == "" && label != "" {
			entry.Label = label
		}
		return entry
	}
	entry := &api.UsageGroupStats{Key: key, Label: label}
	groups[key] = entry
	return entry
}

func addUsageBuckets(target *api.UsageBuckets, source api.UsageBuckets) {
	target.FreshInput += source.FreshInput
	target.CacheWrite += source.CacheWrite
	target.CacheRead += source.CacheRead
	target.Output += source.Output
	target.Reasoning += source.Reasoning
}

func addUsageCost(target *api.UsageCost, source api.UsageCost) {
	target.NanoUSD += source.NanoUSD
	target.Calls += source.Calls
	target.PricedCalls += source.PricedCalls
}

func sortedUsageDays(days map[string]*api.UsageDayStats) []api.UsageDayStats {
	result := make([]api.UsageDayStats, 0, len(days))
	for _, entry := range days {
		result = append(result, *entry)
	}
	sort.Slice(result, func(left, right int) bool {
		return result[left].Day < result[right].Day
	})
	return result
}

func sortedUsageIntervals(intervals map[usageIntervalKey]*api.UsageIntervalStats) []api.UsageIntervalStats {
	result := make([]api.UsageIntervalStats, 0, len(intervals))
	for _, entry := range intervals {
		result = append(result, *entry)
	}
	sort.Slice(result, func(left, right int) bool {
		if result[left].Day != result[right].Day {
			return result[left].Day < result[right].Day
		}
		return result[left].Minute < result[right].Minute
	})
	return result
}

// sortedUsageGroups orders by cost descending so the dominant consumer leads,
// falling back to token count when nothing is priced yet and then to key for a
// stable order.
func sortedUsageGroups(groups map[string]*api.UsageGroupStats) []api.UsageGroupStats {
	result := make([]api.UsageGroupStats, 0, len(groups))
	for _, entry := range groups {
		result = append(result, *entry)
	}
	sort.Slice(result, func(left, right int) bool {
		first, second := result[left], result[right]
		if first.Cost.NanoUSD != second.Cost.NanoUSD {
			return first.Cost.NanoUSD > second.Cost.NanoUSD
		}
		if first.Buckets.Total() != second.Buckets.Total() {
			return first.Buckets.Total() > second.Buckets.Total()
		}
		return first.Key < second.Key
	})
	return result
}
