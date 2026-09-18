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

// RebuildUsage replaces the derived Usage projection from every retained
// provider transcript. The current parser is deliberately run again so
// historical duplicate observations are corrected without rewriting the
// canonical Agent journal or any other database.
//
// Only providers whose transcripts this Host can actually enumerate are
// replaced. Anything else keeps its stored usage: a rebuild that cleared a
// provider it cannot re-read would silently zero real spend.
func (s *Service) RebuildUsage(ctx context.Context) (api.UsageRebuildResult, error) {
	agentStore := s.agentStore()
	if agentStore == nil {
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
		result, err := agentStore.RebuildUsageRollups(ctx)
		if err != nil {
			return api.UsageRebuildResult{}, err
		}
		return api.UsageRebuildResult{
			Rebuilt:      true,
			Providers:    result.Providers,
			Observations: result.Observations,
			Calls:        result.Calls,
			Days:         result.Days,
			CompletedAt:  usageStampTime(result.CompletedAt),
		}, nil
	}
	transcripts, err := finder.HistoricalUsageTranscripts(ctx)
	if err != nil {
		return api.UsageRebuildResult{}, fmt.Errorf("discover historical Usage transcripts: %w", err)
	}
	observations := make([]store.UsageRebuildObservation, 0)
	covered := map[string]struct{}{}
	for _, transcript := range transcripts {
		covered[transcript.Provider] = struct{}{}
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
	providers := make([]string, 0, len(covered))
	for provider := range covered {
		providers = append(providers, provider)
	}
	sort.Strings(providers)
	if len(providers) == 0 {
		// Nothing to replace, and replacing nothing must not be reported as a
		// successful rebuild that emptied the panel.
		return api.UsageRebuildResult{Rebuilt: false}, nil
	}

	result, err := agentStore.RebuildUsageRollupsFromObservations(ctx, providers, observations)
	if err != nil {
		return api.UsageRebuildResult{}, err
	}
	return api.UsageRebuildResult{
		Rebuilt:      true,
		Providers:    providers,
		Observations: result.Observations,
		Calls:        result.Calls,
		Days:         result.Days,
		CompletedAt:  usageStampTime(result.CompletedAt),
	}, nil
}

func usageStampTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.UTC().Format(time.RFC3339)
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
	agentStore := s.agentStore()
	if agentStore == nil {
		return result, nil
	}

	// Money is derived here, from the tokens and the current price table, rather
	// than read from a stored column. Tokens are the durable fact; a cost is a
	// projection of them that changes whenever a unit price does, so computing it
	// on read is what keeps every figure consistent with the prices the panel
	// names in the same breath. Absent prices withhold cost, never tokens.
	pricer := &usagePricer{}
	if table, err := s.usagePrices.Table(ctx); err == nil && table != nil {
		pricer.table = table
		result.PricesFetchedAt = table.FetchedAt.UTC().Format(time.RFC3339)
	} else if err != nil {
		s.logWarn("fetch model pricing", "error", err)
	}

	// A missing or unreadable stamp only costs the age line, so it is logged and
	// dropped rather than failing the panel.
	if stamp, found, stampErr := agentStore.LastUsageRebuild(ctx); stampErr != nil {
		s.logWarn("read last usage rebuild", "error", stampErr)
	} else if found {
		result.LastRebuild = &api.UsageRebuildStamp{
			CompletedAt: usageStampTime(stamp.CompletedAt),
			Providers:   stamp.Providers,
			Calls:       stamp.Calls,
		}
	}

	rows, err := agentStore.QueryUsageDaily(ctx, fromDay, toDay)
	if err != nil {
		return api.UsageStatsResult{}, err
	}

	// Resolve the day the intraday payload describes. The request may name one;
	// otherwise the most recent day with intraday data is the useful default,
	// because that is the curve the panel opens on. Only one day's buckets are
	// ever sent: the client draws a single day at a time, so moving the whole
	// range's five-minute rows would transfer data that is never rendered.
	detailDay := strings.TrimSpace(request.IntervalDay)
	if detailDay < fromDay || detailDay > toDay {
		detailDay = ""
	}
	if detailDay == "" {
		detailDay, err = agentStore.LatestUsageIntervalDay(ctx, fromDay, toDay)
		if err != nil {
			return api.UsageStatsResult{}, err
		}
	}
	result.DetailDay = detailDay

	var intervalRows []store.UsageIntervalRow
	if detailDay != "" {
		intervalRows, err = agentStore.QueryUsageIntervals(ctx, detailDay, detailDay)
		if err != nil {
			return api.UsageStatsResult{}, err
		}
	}

	projectNames := s.usageProjectNames()
	days := map[string]*api.UsageDayStats{}
	intervals := map[usageIntervalKey]*api.UsageIntervalStats{}
	providers := map[string]*api.UsageGroupStats{}
	models := map[string]*api.UsageGroupStats{}
	projects := map[string]*api.UsageGroupStats{}
	dayProviders := map[string]*api.UsageGroupStats{}
	dayModels := map[string]*api.UsageGroupStats{}
	dayProjects := map[string]*api.UsageGroupStats{}

	for _, row := range rows {
		buckets := api.UsageBuckets{
			FreshInput: row.FreshInput,
			CacheWrite: row.CacheWrite,
			CacheRead:  row.CacheRead,
			Output:     row.Output,
			Reasoning:  row.Reasoning,
		}
		cost := pricer.cost(row.Model, row.ModelRaw, buckets, row.Calls)
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

		if detailDay != "" && row.LocalDay == detailDay {
			dayProvider := usageGroupEntry(dayProviders, row.Provider, "")
			addUsageBuckets(&dayProvider.Buckets, buckets)
			addUsageCost(&dayProvider.Cost, cost)

			dayModel := usageGroupEntry(dayModels, row.Model, "")
			addUsageBuckets(&dayModel.Buckets, buckets)
			addUsageCost(&dayModel.Cost, cost)

			dayProject := usageGroupEntry(dayProjects, row.ProjectID, projectNames[row.ProjectID])
			addUsageBuckets(&dayProject.Buckets, buckets)
			addUsageCost(&dayProject.Cost, cost)
		}
	}

	for _, row := range intervalRows {
		buckets := api.UsageBuckets{
			FreshInput: row.FreshInput,
			CacheWrite: row.CacheWrite,
			CacheRead:  row.CacheRead,
			Output:     row.Output,
			Reasoning:  row.Reasoning,
		}
		cost := pricer.cost(row.Model, row.ModelRaw, buckets, row.Calls)
		// Keyed by provider and model as well as time, so the client can plot the
		// curve for one Agent or model instead of only the day's sum. Rows that
		// share a bucket are already distinct in the store, so this only preserves
		// a dimension that used to be collapsed away.
		key := usageIntervalKey{
			day:      row.LocalDay,
			minute:   row.BucketStartMin,
			provider: row.Provider,
			model:    row.Model,
		}
		interval := usageIntervalEntry(intervals, key)
		addUsageBuckets(&interval.Buckets, buckets)
		addUsageCost(&interval.Cost, cost)
	}

	// Providers that report no token counts cannot appear in the rollup at all,
	// so their absence is recorded explicitly. Without this the panel would show
	// a total that silently excludes whole Agents.
	result.Cost.UnmeasuredProviders = s.usageUnmeasuredProviders(fromDay, toDay)
	// Naming the models whose price is missing turns "this total is a lower
	// bound" into something actionable: the gap is one catalog entry away from
	// being closed, and without the names nobody can tell which.
	result.Cost.UnpricedModels = pricer.unpricedModels()

	result.Days = sortedUsageDays(days)
	result.Intervals = sortedUsageIntervals(intervals)
	result.Providers = sortedUsageGroups(providers)
	result.Models = sortedUsageGroups(models)
	result.Projects = sortedUsageGroups(projects)
	result.DayProviders = sortedUsageGroups(dayProviders)
	result.DayModels = sortedUsageGroups(dayModels)
	result.DayProjects = sortedUsageGroups(dayProjects)
	return result, nil
}

type usageIntervalKey struct {
	day      string
	minute   int
	provider string
	model    string
}

// usagePricer turns one aggregate's tokens into money against a single price
// table, remembering which models it could not fully price.
//
// One instance serves a whole request so that every figure in the response --
// range total, day, provider, model, project, and each intraday bucket -- is
// priced from the same table version. Fetching per figure would let a refresh
// land mid-response and produce a breakdown that does not sum to its own total.
type usagePricer struct {
	// table is nil when prices could not be fetched, in which case every call is
	// unpriced. That renders as an explicit gap; it must never render as free.
	table    *usage.PriceTable
	unpriced map[string]struct{}
}

func (p *usagePricer) cost(model, modelRaw string, buckets api.UsageBuckets, calls int64) api.UsageCost {
	result := api.UsageCost{Calls: calls}
	var price usage.ModelPrice
	found := false
	if p.table != nil {
		price, found = p.table.Price(model)
	}
	split, status := usage.CostByBucket(usage.Buckets{
		FreshInput: buckets.FreshInput,
		CacheWrite: buckets.CacheWrite,
		CacheRead:  buckets.CacheRead,
		Output:     buckets.Output,
	}, price, found)
	result.NanoUSD = split.Total()
	result.ByBucket = api.UsageBucketCost{
		FreshInput: split.FreshInput,
		CacheWrite: split.CacheWrite,
		CacheRead:  split.CacheRead,
		Output:     split.Output,
	}
	if status == usage.CostPriced {
		// A row aggregates many calls that share one model, so its price is
		// known for all of them or none.
		result.PricedCalls = calls
		return result
	}
	if buckets.Total() == 0 {
		// Nothing was consumed, so nothing is missing.
		return result
	}
	label := strings.TrimSpace(model)
	if label == "" {
		label = strings.TrimSpace(modelRaw)
	}
	if label == "" {
		label = "unknown model"
	}
	if p.unpriced == nil {
		p.unpriced = map[string]struct{}{}
	}
	p.unpriced[label] = struct{}{}
	return result
}

func (p *usagePricer) unpricedModels() []string {
	if len(p.unpriced) == 0 {
		return nil
	}
	result := make([]string, 0, len(p.unpriced))
	for model := range p.unpriced {
		result = append(result, model)
	}
	sort.Strings(result)
	return result
}

// usageUnmeasuredProviders lists providers bound to sessions that were in use
// during the requested range but whose transcripts carry no token counts. The
// range matters: flagging today's Agents on a strictly historical window would
// attach a present-day gap to last month's total.
func (s *Service) usageUnmeasuredProviders(fromDay, toDay string) []string {
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
		if fromDay != "" && session.EndedAt != nil &&
			session.EndedAt.Local().Format("2006-01-02") < fromDay {
			continue
		}
		if toDay != "" && session.CreatedAt.Local().Format("2006-01-02") > toDay {
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
	entry := &api.UsageIntervalStats{
		Day:      key.day,
		Minute:   key.minute,
		Provider: key.provider,
		Model:    key.model,
	}
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
	target.ByBucket.FreshInput += source.ByBucket.FreshInput
	target.ByBucket.CacheWrite += source.ByBucket.CacheWrite
	target.ByBucket.CacheRead += source.ByBucket.CacheRead
	target.ByBucket.Output += source.ByBucket.Output
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
		first, second := result[left], result[right]
		if first.Day != second.Day {
			return first.Day < second.Day
		}
		if first.Minute != second.Minute {
			return first.Minute < second.Minute
		}
		if first.Provider != second.Provider {
			return first.Provider < second.Provider
		}
		return first.Model < second.Model
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
