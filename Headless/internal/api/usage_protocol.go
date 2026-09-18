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
	// IntervalDay narrows the intraday payload to one local day. Clients show a
	// single day's curve at a time, so sending the whole range's five-minute
	// buckets would move data that is never drawn. Empty means "the most recent
	// day that has intraday data", which is what the client shows before the
	// person picks a day.
	IntervalDay string `json:"intervalDay,omitempty"`
}

// UsageRebuildResult is returned by the explicit Usage maintenance action.
// Rebuilding replaces only derived Usage projections; the canonical Agent
// journal remains the source of truth and is never deleted.
type UsageRebuildResult struct {
	Rebuilt bool `json:"rebuilt"`
	// Providers names what was actually replaced. A provider absent from this
	// list kept its stored usage, because this Host could not enumerate its
	// transcripts and clearing it would have zeroed unrecoverable spend.
	Providers []string `json:"providers,omitempty"`
	// Observations is how many provider measurements were read, and Calls how
	// many of them were counted. The difference is the repeats that were
	// collapsed, which is worth showing: it is the size of the error the rebuild
	// just corrected.
	Observations int64 `json:"observations"`
	Calls        int64 `json:"calls"`
	Days         int64 `json:"days"`
	// CompletedAt is when this rebuild committed, RFC 3339. Returned so a client
	// can show the age of the figures without re-reading the panel.
	CompletedAt string `json:"completedAt,omitempty"`
}

// UsageRebuildStamp records when the stored Usage projection was last replaced.
//
// Carried on the panel payload because a rebuild is the only thing that corrects
// historical counting: figures produced by an older parser look exactly like
// current ones, so their age is part of reading them.
type UsageRebuildStamp struct {
	// CompletedAt is RFC 3339. The client renders it relative to its own clock,
	// which may differ from the Host's.
	CompletedAt string `json:"completedAt"`
	// Providers is the scope that rebuild covered. Anything outside it holds
	// figures from live accumulation or an earlier rebuild.
	Providers []string `json:"providers,omitempty"`
	// Calls is how many billable calls that rebuild counted.
	Calls int64 `json:"calls,omitempty"`
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
	// UnpricedModels names the models whose tokens were counted but could not be
	// priced. Carried alongside the amount so a client can say which spend the
	// lower bound is missing instead of only that some is.
	UnpricedModels []string `json:"unpricedModels,omitempty"`
	// ByBucket splits NanoUSD the same four ways the tokens are split, and always
	// sums to it.
	//
	// Not optional, because the money shape is the answer to a different question
	// than the token shape and the two disagree sharply: measured over real
	// history, cache reads are 94.4% of tokens but 43.9% of spend while fresh
	// input is 5.1% of tokens and 41.7% of spend. A client holding only the token
	// mix cannot derive this, and each zero bucket is omitted, so a quiet
	// aggregate costs nothing on the wire.
	ByBucket UsageBucketCost `json:"byBucket"`
}

// UsageBucketCost is a money amount split by the token class that incurred it,
// in integer nanodollars.
type UsageBucketCost struct {
	FreshInput int64 `json:"freshInput,omitempty"`
	CacheWrite int64 `json:"cacheWrite,omitempty"`
	CacheRead  int64 `json:"cacheRead,omitempty"`
	Output     int64 `json:"output,omitempty"`
}

// Total is the whole amount, which always equals the cost it belongs to.
func (c UsageBucketCost) Total() int64 {
	return c.FreshInput + c.CacheWrite + c.CacheRead + c.Output
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

// UsageIntervalStats is one local-day intraday bucket for one provider and
// model. Minute is the start of the bucket measured from local midnight (for
// example, 10:30 is 630). Keeping the day and minute separate avoids converting
// a Host-local bucket through a client's timezone and moving a point to the
// wrong calendar day.
//
// Provider and Model are carried so the curve can answer "when did this model
// run today" rather than only "how busy was today". Without them the Agent and
// model filters have nothing to act on, which made them controls that visibly
// engaged and changed no number. The cost is a day's worth of buckets rather
// than a range's: over local history the busiest day held 462 of these rows.
type UsageIntervalStats struct {
	Day      string       `json:"day"`
	Minute   int          `json:"minute"`
	Provider string       `json:"provider,omitempty"`
	Model    string       `json:"model,omitempty"`
	Buckets  UsageBuckets `json:"buckets"`
	Cost     UsageCost    `json:"cost"`
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
	// DetailDay is the local day the intraday payload describes. When the
	// request named no IntervalDay this is the most recent day with data, so the
	// client can label the curve without a second round trip.
	DetailDay string `json:"detailDay,omitempty"`
	// Intervals are the canonical 5-minute buckets for DetailDay. Clients may
	// merge adjacent buckets for a coarser display without another Host request.
	Intervals             []UsageIntervalStats `json:"intervals"`
	IntervalBucketMinutes int                  `json:"intervalBucketMinutes"`
	Providers             []UsageGroupStats    `json:"providers"`
	Models                []UsageGroupStats    `json:"models"`
	Projects              []UsageGroupStats    `json:"projects"`
	// DayProviders, DayModels, and DayProjects break DetailDay down by the same
	// dimensions as the range, so selecting a day answers "what cost this day"
	// without shipping per-day rows for every day in the range.
	DayProviders []UsageGroupStats `json:"dayProviders,omitempty"`
	DayModels    []UsageGroupStats `json:"dayModels,omitempty"`
	DayProjects  []UsageGroupStats `json:"dayProjects,omitempty"`
	// PricesFetchedAt is when the unit prices behind Cost were retrieved. Zero
	// means no price table was available and every amount is zero.
	PricesFetchedAt string `json:"pricesFetchedAt,omitempty"`
	// LastRebuild is when the stored projection was last replaced, absent when it
	// has only ever been accumulated live.
	LastRebuild *UsageRebuildStamp `json:"lastRebuild,omitempty"`
}
