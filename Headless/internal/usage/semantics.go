// Package usage normalizes provider token accounting into one additive,
// provider-neutral form so that aggregation never has to know which CLI
// produced an event.
//
// Two provider differences make a raw api.AgentUsage unsafe to sum:
//
//  1. Whether InputTokens already contains the cached portion. Claude and pi
//     report fresh input with cache counted separately; Codex reports a total
//     that includes both cache reads and cache writes.
//  2. Whether the provider reports token counts at all. Antigravity and Qoder
//     transcripts carry none, so a zero there means "unknown", not "free".
//
// Both are resolved here and nowhere else. Write, re-aggregation, and display
// paths must all route through this package: cc-switch, which solves the same
// problem, regressed exactly once by duplicating the cache-inclusive provider
// list in a backfill path and missing one provider there.
package usage

import "github.com/abcdlsj/warren/Headless/internal/api"

// InputBasis describes what a provider's InputTokens already contains.
type InputBasis int

const (
	// InputFresh means InputTokens excludes cache reads and cache writes,
	// which are reported as their own counters. Anthropic's shape.
	InputFresh InputBasis = iota
	// InputTotal means InputTokens is the whole prompt including any cached
	// portion, so billable fresh input is the remainder after subtracting the
	// cache counters. OpenAI's shape.
	InputTotal
)

// Semantics is the per-provider accounting contract. It describes what Warren's
// adapter currently emits, not what the underlying CLI is capable of emitting:
// a provider whose transcript carries usage that Warren does not yet parse must
// stay Reports=false, or the panel would report a confident zero for spend that
// actually happened.
type Semantics struct {
	// Reports is false when the provider's transcript gives Warren no token
	// counts at all. Such providers produce no rollup rows and must surface as
	// unmeasured rather than as zero cost.
	Reports bool
	// Basis is what InputTokens contains.
	Basis InputBasis
	// ReportsCacheWrite is false when the provider never distinguishes cache
	// creation from ordinary input. A zero cache-write bucket from such a
	// provider is unknown, not observed-zero, and must render as N/A.
	ReportsCacheWrite bool
}

// providerSemantics is the single source of truth. An unlisted provider falls
// back to Reports=true and InputFresh, which is the safe direction: a missed
// total-input provider shows up loudly as an impossible cache hit rate, while
// the opposite default silently deducts tokens that were never cached.
var providerSemantics = map[string]Semantics{
	"claude": {Reports: true, Basis: InputFresh, ReportsCacheWrite: true},
	// Codex's input_tokens contains both cached_input_tokens and
	// cache_write_input_tokens; verified against 74921 real token_count
	// events, where input >= cached + cache_write held without exception.
	"codex": {Reports: true, Basis: InputTotal, ReportsCacheWrite: true},
	"pi":    {Reports: true, Basis: InputFresh, ReportsCacheWrite: true},
	// OpenCode's own store does carry tokens_input/output/reasoning/cache_read/
	// cache_write, but Warren's adapter does not project those columns yet.
	// Keep it unmeasured until it does, so the panel does not claim a zero.
	"opencode": {Reports: false},
	// Antigravity and Qoder transcripts carry no token fields at all. Counting
	// these would require tokenizing text Warren cannot see (system prompt,
	// tool definitions, cached context), so input would be wrong by multiples.
	"antigravity": {Reports: false},
	"qoder":       {Reports: false},
}

// SemanticsFor returns the accounting contract for a provider.
func SemanticsFor(provider string) Semantics {
	if value, ok := providerSemantics[provider]; ok {
		return value
	}
	return Semantics{Reports: true, Basis: InputFresh, ReportsCacheWrite: true}
}

// Buckets is one billable model call split into four disjoint token classes.
// Disjoint and exhaustive is the whole point: the four sum to the real total
// and each maps to exactly one unit price, which makes every stored column
// additive across any grouping.
type Buckets struct {
	// FreshInput is prompt input that was neither read from nor written to
	// cache. Priced at the input rate.
	FreshInput int64
	// CacheWrite is input persisted into the prompt cache. Priced above input.
	CacheWrite int64
	// CacheRead is input served from the prompt cache. Priced far below input.
	CacheRead int64
	// Output is every generated token, reasoning included, since reasoning is
	// billed at the output rate. Verified against 46186 real Codex events
	// where reasoning_output_tokens never exceeded output_tokens.
	Output int64
	// Reasoning is the reasoning subset of Output. Display only: adding it to
	// a cost would double-count, so it is deliberately not a fifth bucket.
	Reasoning int64
}

// Total is the real token count for this call.
func (b Buckets) Total() int64 {
	return b.FreshInput + b.CacheWrite + b.CacheRead + b.Output
}

// Empty reports whether the call carried no countable tokens.
func (b Buckets) Empty() bool {
	return b.FreshInput == 0 && b.CacheWrite == 0 && b.CacheRead == 0 && b.Output == 0
}

// Add accumulates another call. Every field is additive by construction.
func (b *Buckets) Add(other Buckets) {
	b.FreshInput += other.FreshInput
	b.CacheWrite += other.CacheWrite
	b.CacheRead += other.CacheRead
	b.Output += other.Output
	b.Reasoning += other.Reasoning
}

// Normalize folds one provider usage observation into disjoint buckets. It
// reports false when the provider does not measure usage or the observation
// carried nothing countable, in which case no rollup row must be written.
//
// TotalTokens and the provider's own InputTokens are deliberately dropped:
// the former is derivable and would disagree with the buckets the moment a
// provider rounds differently, and the latter has no single meaning across
// providers.
func Normalize(provider string, value *api.AgentUsage) (Buckets, bool) {
	semantics := SemanticsFor(provider)
	if !semantics.Reports || value == nil {
		return Buckets{}, false
	}

	cacheRead := nonNegative(value.CacheReadInputTokens)
	cacheWrite := nonNegative(value.CacheCreationInputTokens)
	input := nonNegative(value.InputTokens)
	output := nonNegative(value.OutputTokens)

	freshInput := input
	if semantics.Basis == InputTotal {
		// Clamp before subtracting so a provider that reports a cache counter
		// larger than its own total can never produce a negative bucket and
		// silently cancel out another call's real spend.
		if cacheRead > input {
			cacheRead = input
		}
		if cacheWrite > input-cacheRead {
			cacheWrite = input - cacheRead
		}
		freshInput = input - cacheRead - cacheWrite
	}

	reasoning := nonNegative(value.ReasoningOutputTokens)
	if reasoning > output {
		reasoning = output
	}

	buckets := Buckets{
		FreshInput: freshInput,
		CacheWrite: cacheWrite,
		CacheRead:  cacheRead,
		Output:     output,
		Reasoning:  reasoning,
	}
	if buckets.Empty() {
		return Buckets{}, false
	}
	return buckets, true
}

func nonNegative(value int64) int64 {
	if value < 0 {
		return 0
	}
	return value
}
