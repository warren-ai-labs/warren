package usage

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
)

func fmtF(v float64) string { return fmt.Sprintf("%.6f", v) }

func TestProbePricingEndpoint(t *testing.T) {
	if os.Getenv("WARREN_PRICING_PROBE") == "" {
		t.Skip("probe only")
	}
	f := &PriceFetcher{}
	table, err := f.Table(context.Background())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	t.Logf("unit=%q models=%d", table.Unit, len(table.Models))
	var keys []string
	for k := range table.Models {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	show := func(k string) {
		p, ok := table.Models[k]
		if !ok {
			t.Logf("  %-28s MISSING", k)
			return
		}
		d := func(v *float64) string {
			if v == nil {
				return "nil"
			}
			return strings.TrimRight(strings.TrimRight(fmtF(*v), "0"), ".")
		}
		t.Logf("  %-28s provider=%-12s in=%s out=%s cr=%s cw=%s",
			k, p.Provider, d(p.Input), d(p.Output), d(p.CacheRead), d(p.CacheWrite))
	}
	for _, k := range []string{
		"claude-opus-5", "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001",
		"gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra",
		"deepseek-v4.1-flash", "deepseek-v4-flash", "deepseek-v4-pro", "glm-5.3-flash",
	} {
		show(k)
	}
	// Any hint of tiered/long-context pricing in the key space?
	var suspicious []string
	for _, k := range keys {
		lower := strings.ToLower(k)
		for _, marker := range []string{"200k", "1m", "long", "tier", "above", "[", "]"} {
			if strings.Contains(lower, marker) {
				suspicious = append(suspicious, k)
				break
			}
		}
	}
	t.Logf("keys hinting at context tiers (%d): %v", len(suspicious), suspicious)
	var nilCache, nilInput int
	for _, p := range table.Models {
		if p.CacheRead == nil || p.CacheWrite == nil {
			nilCache++
		}
		if p.Input == nil {
			nilInput++
		}
	}
	t.Logf("models missing a cache price: %d; missing input price: %d", nilCache, nilInput)
}
