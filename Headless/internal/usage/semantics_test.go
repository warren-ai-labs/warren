package usage

import (
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestNormalizeKeepsAnthropicInputFresh(t *testing.T) {
	buckets, ok := Normalize("claude", &api.AgentUsage{
		InputTokens:              128,
		CacheReadInputTokens:     6144,
		CacheCreationInputTokens: 512,
		OutputTokens:             240,
		ReasoningOutputTokens:    192,
		TotalTokens:              7024,
	})
	if !ok {
		t.Fatal("claude usage must normalize")
	}
	// Claude already excludes cache from input, so nothing may be deducted.
	want := Buckets{FreshInput: 128, CacheWrite: 512, CacheRead: 6144, Output: 240, Reasoning: 192}
	if buckets != want {
		t.Fatalf("buckets = %+v, want %+v", buckets, want)
	}
	if got := buckets.Total(); got != 7024 {
		t.Fatalf("total = %d, want 7024", got)
	}
}

func TestNormalizeDeductsCacheFromCodexTotalInput(t *testing.T) {
	// Shape taken from a real rollout token_count event.
	buckets, ok := Normalize("codex", &api.AgentUsage{
		InputTokens:              33410,
		CacheReadInputTokens:     22389,
		CacheCreationInputTokens: 7623,
		OutputTokens:             495,
		ReasoningOutputTokens:    1,
		TotalTokens:              33905,
	})
	if !ok {
		t.Fatal("codex usage must normalize")
	}
	want := Buckets{FreshInput: 3398, CacheWrite: 7623, CacheRead: 22389, Output: 495, Reasoning: 1}
	if buckets != want {
		t.Fatalf("buckets = %+v, want %+v", buckets, want)
	}
	// The four buckets must still reconstruct the provider's own total.
	if got := buckets.Total(); got != 33905 {
		t.Fatalf("total = %d, want 33905", got)
	}
}

func TestNormalizeClampsCacheCountersAboveTotalInput(t *testing.T) {
	// A negative bucket would cancel real spend from another call, so an
	// inconsistent provider observation must clamp instead of going negative.
	buckets, ok := Normalize("codex", &api.AgentUsage{
		InputTokens:              100,
		CacheReadInputTokens:     140,
		CacheCreationInputTokens: 90,
		OutputTokens:             10,
	})
	if !ok {
		t.Fatal("clamped usage must still normalize")
	}
	want := Buckets{FreshInput: 0, CacheWrite: 0, CacheRead: 100, Output: 10}
	if buckets != want {
		t.Fatalf("buckets = %+v, want %+v", buckets, want)
	}
}

func TestNormalizeClampsReasoningToOutput(t *testing.T) {
	buckets, _ := Normalize("claude", &api.AgentUsage{
		OutputTokens:          50,
		ReasoningOutputTokens: 90,
	})
	if buckets.Reasoning != 50 {
		t.Fatalf("reasoning = %d, want 50", buckets.Reasoning)
	}
}

func TestNormalizeRejectsUnmeasuredProviders(t *testing.T) {
	for _, provider := range []string{"antigravity", "qoder", "opencode"} {
		if _, ok := Normalize(provider, &api.AgentUsage{InputTokens: 100, OutputTokens: 5}); ok {
			t.Fatalf("%s must stay unmeasured so the panel cannot claim a zero", provider)
		}
	}
}

func TestNormalizeRejectsEmptyObservation(t *testing.T) {
	if _, ok := Normalize("claude", nil); ok {
		t.Fatal("nil usage must not produce a rollup row")
	}
	if _, ok := Normalize("claude", &api.AgentUsage{TotalTokens: 99}); ok {
		t.Fatal("a bare total with no bucket detail must not produce a rollup row")
	}
}

func TestUnknownProviderDefaultsToFreshInput(t *testing.T) {
	// The safe default: a missed total-input provider surfaces as an
	// impossible cache hit rate, which is louder than a silent over-deduction.
	semantics := SemanticsFor("some-future-cli")
	if !semantics.Reports || semantics.Basis != InputFresh {
		t.Fatalf("unexpected default semantics: %+v", semantics)
	}
}

func TestBucketsAddIsAdditive(t *testing.T) {
	var total Buckets
	total.Add(Buckets{FreshInput: 1, CacheWrite: 2, CacheRead: 3, Output: 4, Reasoning: 1})
	total.Add(Buckets{FreshInput: 10, CacheWrite: 20, CacheRead: 30, Output: 40, Reasoning: 10})
	want := Buckets{FreshInput: 11, CacheWrite: 22, CacheRead: 33, Output: 44, Reasoning: 11}
	if total != want {
		t.Fatalf("total = %+v, want %+v", total, want)
	}
}
