package api

// UsageStatsRequest selects a local-day range of token accounting. Both bounds
// are YYYY-MM-DD in the Host's local time, inclusive, and an empty bound is
// unconstrained.
//
// The range is expressed in days rather than instants because that is the grain
// the Host stores. A day is the Host's local day: the heatmap cell has to mean
// the day the person remembers working, and bucketing in UTC would shift every
// historical cell whenever the Host's timezone changed.
type UsageStatsRequest struct {
	FromDay string `json:"fromDay,omitempty"`
	ToDay   string `json:"toDay,omitempty"`
}

// UsageRebuildResult is returned by the explicit Usage maintenance action.
// Rebuilding replaces only derived Usage projections; the canonical Agent
// journal remains the source of truth and is never deleted.
type UsageRebuildResult struct {
	Rebuilt bool  `json:"rebuilt"`
	Events  int64 `json:"events"`
	Calls   int64 `json:"calls"`
	Days    int64 `json:"days"`
}

// UsageBuckets is one aggregate's token counts, split into disjoint classes that
// each carry their own unit price. They sum to the real total, so no separate
// total field is carried.
type UsageBuckets struct {
	FreshInput int64 `json:"freshInput"`
	CacheWrite int64 `json:"cacheWrite"`
	CacheRead  int64 `json:"cacheRead"`
	Output     int64 `json:"output"`
	// Reasoning is the reasoning subset of Output, for display only. It is
	// already billed inside Output.
	Reasoning int64 `json:"reasoning,omitempty"`
}

// Total is the real token count.
func (b UsageBuckets) Total() int64 {
	return b.FreshInput + b.CacheWrite + b.CacheRead + b.Output
}

// UsageCost is a money amount plus how completely it could be derived.
//
// Completeness travels with every amount deliberately. A client that renders
// only NanoUSD would show a total that looks whole while omitting spend whose
// price is unknown, so the counts needed to say "at least" are part of the wire
// shape rather than something a client has to infer.
type UsageCost struct {
	// NanoUSD is integer nanodollars, which keeps sums exact.
	NanoUSD int64 `json:"nanoUsd"`
	// Calls is how many billable model calls the amount covers.
	Calls int64 `json:"calls"`
	// PricedCalls is how many of those had a fully known price. Below Calls, the
	// amount is a lower bound and must be presented as one.
	PricedCalls int64 `json:"pricedCalls"`
	// UnmeasuredProviders names providers active in this range that report no
	// token counts at all, so their spend is missing from every figure here.
	UnmeasuredProviders []string `json:"unmeasuredProviders,omitempty"`
}

// Complete reports whether every call in the amount was priced.
func (c UsageCost) Complete() bool {
	return c.PricedCalls >= c.Calls && len(c.UnmeasuredProviders) == 0
}

// UsageDayStats is one local day, for the heatmap and trend.
type UsageDayStats struct {
	Day     string       `json:"day"`
	Buckets UsageBuckets `json:"buckets"`
	Cost    UsageCost    `json:"cost"`
}

// UsageIntervalBucketMinutes is the Host's durable intraday storage grain.
// Clients may aggregate these base buckets into a larger display interval.
const UsageIntervalBucketMinutes = 5

// UsageIntervalStats is one local-day intraday bucket. Minute is the start of
// the bucket measured from local midnight (for example, 10:30 is 630). Keeping
// the day and minute separate avoids converting a Host-local bucket through a
// client's timezone and moving a point to the wrong calendar day.
type UsageIntervalStats struct {
	Day     string       `json:"day"`
	Minute  int          `json:"minute"`
	Buckets UsageBuckets `json:"buckets"`
	Cost    UsageCost    `json:"cost"`
}

// UsageGroupStats is one aggregate along a single dimension. Key is the
// provider id, normalized model id, or project id depending on which list it
// appears in; an empty key means unattributed.
type UsageGroupStats struct {
	Key string `json:"key"`
	// Label carries a display name when the key alone is not presentable, such
	// as a project id. Empty when the key is already the label.
	Label   string       `json:"label,omitempty"`
	Buckets UsageBuckets `json:"buckets"`
	Cost    UsageCost    `json:"cost"`
}

// UsageStatsResult is the whole panel payload for one range.
//
// The Host aggregates rather than shipping rows for the client to fold, because
// a client's event replica is a bounded cache and summing it would under-report.
// Rates such as cache hit rate are intentionally absent: they are derived from
// these additive counts at render time, which keeps one definition of each rate.
type UsageStatsResult struct {
	FromDay string `json:"fromDay"`
	ToDay   string `json:"toDay"`
	// Total is the range's aggregate across every dimension.
	Total UsageBuckets    `json:"total"`
	Cost  UsageCost       `json:"cost"`
	Days  []UsageDayStats `json:"days"`
	// Intervals are the canonical 5-minute buckets. Clients may merge adjacent
	// buckets for a coarser display without another Host request.
	Intervals             []UsageIntervalStats `json:"intervals"`
	IntervalBucketMinutes int                  `json:"intervalBucketMinutes"`
	Providers             []UsageGroupStats    `json:"providers"`
	Models                []UsageGroupStats    `json:"models"`
	Projects              []UsageGroupStats    `json:"projects"`
	// PricesFetchedAt is when the unit prices behind Cost were retrieved. Zero
	// means no price table was available and every amount is zero.
	PricesFetchedAt string `json:"pricesFetchedAt,omitempty"`
}
