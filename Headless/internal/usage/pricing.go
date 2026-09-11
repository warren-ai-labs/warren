package usage

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// PricingEndpoint is Warren's own projection of the models.dev catalog. Going
// through it rather than models.dev directly keeps the payload small, gives one
// stable document shape to depend on, and resolves each model to its first-party
// vendor price instead of whichever reseller the upstream catalog happened to
// list last.
const PricingEndpoint = "https://warrenai.xyz/api/model-pricing"

// nanoUSDPerUSD scales prices into the integer unit stored in the rollup.
// Costs are kept as integer nanodollars so that summing them across any
// grouping is exact; a float column drifts and a decimal-as-text column has to
// be cast back to a float to be added, which drifts too.
const nanoUSDPerUSD = 1_000_000_000

// tokensPerPriceUnit matches the catalog's quoting convention: every price is
// USD per million tokens.
const tokensPerPriceUnit = 1_000_000

// ModelPrice is the unit price set for one model. A nil field means the catalog
// did not state that price, which is different from stating zero: unknown must
// not be billed as free.
type ModelPrice struct {
	Provider   string   `json:"provider"`
	Name       string   `json:"name"`
	Input      *float64 `json:"input"`
	Output     *float64 `json:"output"`
	CacheRead  *float64 `json:"cacheRead"`
	CacheWrite *float64 `json:"cacheWrite"`
}

// PriceTable maps a normalized model id to its unit prices.
type PriceTable struct {
	Unit      string                `json:"unit"`
	FetchedAt time.Time             `json:"fetchedAt"`
	Models    map[string]ModelPrice `json:"models"`
}

// Price returns the entry for a model id that has already been normalized by
// NormalizeModelID.
func (t *PriceTable) Price(model string) (ModelPrice, bool) {
	if t == nil || len(t.Models) == 0 {
		return ModelPrice{}, false
	}
	value, ok := t.Models[strings.TrimSpace(model)]
	return value, ok
}

// CostStatus describes how completely a set of buckets could be priced. It has
// to survive aggregation: a group holding anything other than Priced must be
// presented as a lower bound, or the panel shows a total that looks complete
// while silently omitting spend.
type CostStatus int

const (
	// CostPriced means every bucket with tokens had a unit price.
	CostPriced CostStatus = iota
	// CostPartial means the model was found but a bucket carrying tokens had no
	// stated price, so the returned cost is short by that bucket.
	CostPartial
	// CostUnpriced means the model is not in the table at all.
	CostUnpriced
)

// Cost prices one call's buckets, returning integer nanodollars.
//
// Reasoning is not priced separately: it is already contained in Output and
// billed at the output rate, so adding it would double-charge.
func Cost(buckets Buckets, price ModelPrice, found bool) (int64, CostStatus) {
	if !found {
		return 0, CostUnpriced
	}
	status := CostPriced
	var total int64
	for _, part := range []struct {
		tokens int64
		rate   *float64
	}{
		{buckets.FreshInput, price.Input},
		{buckets.Output, price.Output},
		{buckets.CacheRead, price.CacheRead},
		{buckets.CacheWrite, price.CacheWrite},
	} {
		if part.tokens == 0 {
			continue
		}
		if part.rate == nil {
			// Tokens were consumed at an unknown rate. Charging zero would make
			// the shortfall invisible, so the status carries it instead.
			status = CostPartial
			continue
		}
		total += int64(float64(part.tokens) * *part.rate * nanoUSDPerUSD / tokensPerPriceUnit)
	}
	return total, status
}

// PriceFetcher retrieves and caches the price table.
type PriceFetcher struct {
	// Endpoint overrides PricingEndpoint in tests.
	Endpoint string
	// Client overrides the default HTTP client.
	Client *http.Client
	// TTL is how long a fetched table is reused. Unit prices change on release
	// announcements, so a short TTL only adds requests.
	TTL time.Duration

	mu    sync.Mutex
	table *PriceTable
}

const defaultPriceTTL = 12 * time.Hour

// Table returns the cached table, fetching it when absent or stale.
//
// On a failed refresh an existing table is returned unchanged: stale prices
// produce a slightly dated cost, while treating the failure as an empty table
// would silently reprice every model to zero.
func (f *PriceFetcher) Table(ctx context.Context) (*PriceTable, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	ttl := f.TTL
	if ttl <= 0 {
		ttl = defaultPriceTTL
	}
	if f.table != nil && time.Since(f.table.FetchedAt) < ttl {
		return f.table, nil
	}

	table, err := f.fetch(ctx)
	if err != nil {
		if f.table != nil {
			return f.table, nil
		}
		return nil, err
	}
	f.table = table
	return table, nil
}

func (f *PriceFetcher) fetch(ctx context.Context) (*PriceTable, error) {
	endpoint := strings.TrimSpace(f.Endpoint)
	if endpoint == "" {
		endpoint = PricingEndpoint
	}
	client := f.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("build pricing request: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("fetch pricing: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("pricing endpoint returned %d", response.StatusCode)
	}
	// Bounded so a misrouted response cannot exhaust memory. The projected
	// document is a few hundred kilobytes.
	body, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return nil, fmt.Errorf("read pricing: %w", err)
	}
	var decoded struct {
		Unit   string                `json:"unit"`
		Models map[string]ModelPrice `json:"models"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return nil, fmt.Errorf("decode pricing: %w", err)
	}
	if len(decoded.Models) == 0 {
		// An empty table would reprice everything to unpriced. Refusing it keeps
		// the previous table in place.
		return nil, fmt.Errorf("pricing document contained no models")
	}
	return &PriceTable{Unit: decoded.Unit, FetchedAt: time.Now(), Models: decoded.Models}, nil
}
