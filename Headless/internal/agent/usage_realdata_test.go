package agent

import (
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/usage"
)

// TestRealTranscriptUsageTotals runs the adapters over this machine's own
// transcripts and reports the aggregate each provider yields.
//
// It is a measurement harness, not an assertion of expected totals: the numbers
// depend on local history. It exists because per-call duplication is invisible
// in unit fixtures -- Claude repeating one response's usage across lines, Codex
// repeating a measurement per rate-limit lane -- and only shows up at the scale
// of real sessions. Run with:
//
//	go test ./Headless/internal/agent/ -run RealTranscriptUsage -v -tags=realdata
//
// Skipped by default so the suite stays hermetic.
func TestRealTranscriptUsageTotals(t *testing.T) {
	if os.Getenv("WARREN_USAGE_REALDATA") == "" {
		t.Skip("set WARREN_USAGE_REALDATA=1 to measure against local transcripts")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home directory")
	}
	for _, source := range []struct {
		kind string
		root string
	}{
		{"claude", filepath.Join(home, ".claude", "projects")},
		{"codex", filepath.Join(home, ".codex", "sessions")},
		{"pi", PiSessionsRoot()},
	} {
		if _, err := os.Stat(source.root); err != nil {
			t.Logf("%s: no transcripts at %s", source.kind, source.root)
			continue
		}
		var files []string
		_ = filepath.Walk(source.root, func(path string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() || filepath.Ext(path) != ".jsonl" {
				return nil
			}
			files = append(files, path)
			return nil
		})
		sort.Strings(files)
		if len(files) > 400 {
			files = files[len(files)-400:]
		}

		var total, deduped usage.Buckets
		calls, withUsage, keyed := 0, 0, 0
		seen := map[string]struct{}{}
		for _, file := range files {
			events, _, err := readNew(file, 0, newParser(source.kind))
			if err != nil {
				continue
			}
			for _, event := range events {
				if event.Usage == nil {
					continue
				}
				withUsage++
				buckets, ok := usage.Normalize(source.kind, event.Usage)
				if !ok {
					continue
				}
				total.Add(buckets)
				calls++
				// What the store will actually count: the same call key across
				// files is one call, which is how a resumed conversation stops
				// being counted twice.
				key := event.Usage.CallKey
				if key == "" {
					deduped.Add(buckets)
					continue
				}
				keyed++
				if _, repeat := seen[key]; repeat {
					continue
				}
				seen[key] = struct{}{}
				deduped.Add(buckets)
			}
		}
		t.Logf("%s: files=%d eventsWithUsage=%d billableCalls=%d withCallKey=%d",
			source.kind, len(files), withUsage, calls, keyed)
		t.Logf("  freshInput=%d cacheWrite=%d cacheRead=%d output=%d total=%d",
			total.FreshInput, total.CacheWrite, total.CacheRead, total.Output, total.Total())
		t.Logf("  after call-key dedupe: total=%d (%.4fx before)",
			deduped.Total(), ratio(total.Total(), deduped.Total()))
		// A counted call without a key is a call whose repeats cannot be
		// collapsed, so every adapter has to key what it counts.
		if calls > 0 && keyed != calls {
			t.Errorf("%s: %d of %d counted calls carry no call key, so their repeats cannot be collapsed",
				source.kind, calls-keyed, calls)
		}
	}
}

func ratio(before, after int64) float64 {
	if after == 0 {
		return 0
	}
	return float64(before) / float64(after)
}
