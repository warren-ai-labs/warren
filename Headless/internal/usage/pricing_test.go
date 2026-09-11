package usage

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func rate(value float64) *float64 { return &value }

func TestCostPricesEachBucketAtItsOwnRate(t *testing.T) {
	// Real Anthropic list prices for claude-opus-5, USD per million tokens.
	price := ModelPrice{
		Input: rate(5), Output: rate(25), CacheRead: rate(0.5), CacheWrite: rate(6.25),
	}
	// One million tokens in each bucket makes the arithmetic checkable by eye:
	// 5 + 25 + 0.5 + 6.25 = 36.75 USD.
	buckets := Buckets{
		FreshInput: 1_000_000,
		Output:     1_000_000,
		CacheRead:  1_000_000,
		CacheWrite: 1_000_000,
	}
	cost, status := Cost(buckets, price, true)
	if status != CostPriced {
		t.Fatalf("status = %v, want priced", status)
	}
	if want := int64(36_750_000_000); cost != want {
		t.Fatalf("cost = %d nanoUSD, want %d (36.75 USD)", cost, want)
	}
}

func TestCostIgnoresReasoningBecauseOutputAlreadyContainsIt(t *testing.T) {
	price := ModelPrice{Input: rate(1), Output: rate(10)}
	withReasoning := Buckets{Output: 1_000_000, Reasoning: 900_000}
	withoutReasoning := Buckets{Output: 1_000_000}
	first, _ := Cost(withReasoning, price, true)
	second, _ := Cost(withoutReasoning, price, true)
	if first != second {
		t.Fatalf("reasoning changed the cost: %d vs %d", first, second)
	}
}

func TestCostReportsPartialWhenABucketHasNoRate(t *testing.T) {
	// 608 of 1654 live catalog entries state no cache prices. Charging zero for
	// those tokens would hide the shortfall.
	price := ModelPrice{Input: rate(5), Output: rate(25)}
	buckets := Buckets{FreshInput: 1_000_000, Output: 1_000_000, CacheRead: 1_000_000}
	cost, status := Cost(buckets, price, true)
	if status != CostPartial {
		t.Fatalf("status = %v, want partial", status)
	}
	if want := int64(30_000_000_000); cost != want {
		t.Fatalf("cost = %d, want %d covering only the priced buckets", cost, want)
	}
}

func TestCostIgnoresMissingRateForAnEmptyBucket(t *testing.T) {
	// No cache tokens were consumed, so an absent cache rate costs nothing and
	// must not downgrade the status.
	price := ModelPrice{Input: rate(5), Output: rate(25)}
	_, status := Cost(Buckets{FreshInput: 1_000_000, Output: 1_000_000}, price, true)
	if status != CostPriced {
		t.Fatalf("status = %v, want priced", status)
	}
}

func TestCostReportsUnpricedForUnknownModel(t *testing.T) {
	cost, status := Cost(Buckets{FreshInput: 1_000_000}, ModelPrice{}, false)
	if status != CostUnpriced || cost != 0 {
		t.Fatalf("cost=%d status=%v, want 0 and unpriced", cost, status)
	}
}

func TestPriceFetcherCachesWithinTTL(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls++
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"unit":"usd-per-million-tokens","models":{"claude-opus-5":{"provider":"anthropic","input":5,"output":25,"cacheRead":0.5,"cacheWrite":6.25}}}`))
	}))
	defer server.Close()

	fetcher := &PriceFetcher{Endpoint: server.URL, TTL: time.Hour}
	for attempt := 0; attempt < 3; attempt++ {
		table, err := fetcher.Table(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		price, ok := table.Price("claude-opus-5")
		if !ok || price.Provider != "anthropic" || *price.CacheWrite != 6.25 {
			t.Fatalf("price = %+v ok=%v", price, ok)
		}
	}
	if calls != 1 {
		t.Fatalf("upstream calls = %d, want 1", calls)
	}
}

func TestPriceFetcherKeepsStaleTableWhenRefreshFails(t *testing.T) {
	// Repricing every model to unpriced because a refresh failed would be worse
	// than reporting a slightly dated cost.
	fail := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if fail {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		_, _ = w.Write([]byte(`{"unit":"u","models":{"m":{"input":1,"output":2}}}`))
	}))
	defer server.Close()

	fetcher := &PriceFetcher{Endpoint: server.URL, TTL: time.Nanosecond}
	if _, err := fetcher.Table(context.Background()); err != nil {
		t.Fatal(err)
	}
	fail = true
	table, err := fetcher.Table(context.Background())
	if err != nil {
		t.Fatalf("a failed refresh must not surface as an error: %v", err)
	}
	if _, ok := table.Price("m"); !ok {
		t.Fatal("stale table must be retained")
	}
}

func TestPriceFetcherRejectsEmptyDocument(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"unit":"u","models":{}}`))
	}))
	defer server.Close()
	if _, err := (&PriceFetcher{Endpoint: server.URL}).Table(context.Background()); err == nil {
		t.Fatal("an empty document must fail rather than reprice everything to zero")
	}
}

func TestPriceFetcherReportsUpstreamFailureWithNoCache(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()
	if _, err := (&PriceFetcher{Endpoint: server.URL}).Table(context.Background()); err == nil {
		t.Fatal("want an error when there is nothing cached to fall back to")
	}
}
