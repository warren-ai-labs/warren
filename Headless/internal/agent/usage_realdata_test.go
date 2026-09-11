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

		var total usage.Buckets
		calls, withUsage := 0, 0
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
			}
		}
		t.Logf("%s: files=%d eventsWithUsage=%d billableCalls=%d", source.kind, len(files), withUsage, calls)
		t.Logf("  freshInput=%d cacheWrite=%d cacheRead=%d output=%d total=%d",
			total.FreshInput, total.CacheWrite, total.CacheRead, total.Output, total.Total())
	}
}
