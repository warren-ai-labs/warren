package store

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func newPruneTestStore(t *testing.T) *AgentEventStore {
	t.Helper()
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func appendPruneTestEvents(t *testing.T, s *AgentEventStore, streamID string, count int) {
	t.Helper()
	events := make([]api.CanonicalAgentEvent, 0, count)
	for index := 0; index < count; index++ {
		events = append(events, api.CanonicalAgentEvent{
			EventID:    fmt.Sprintf("%s-evt-%d", streamID, index),
			Type:       "message.created",
			Origin:     api.AgentEventOrigin{Kind: "provider", Confidence: "native"},
			Payload:    map[string]any{"index": index},
			OccurredAt: time.Now().UTC(),
		})
	}
	if _, err := s.AppendCanonicalEvents(context.Background(), streamID, streamID, events); err != nil {
		t.Fatal(err)
	}
}

func drainPruneSteps(t *testing.T, s *AgentEventStore, protect map[string]struct{}, cutoffMs int64, maxRows int) []PruneResult {
	t.Helper()
	var results []PruneResult
	for {
		result, err := s.PruneStreamsStep(context.Background(), protect, cutoffMs, maxRows)
		if err != nil {
			t.Fatal(err)
		}
		if result.StreamID == "" {
			break
		}
		results = append(results, result)
		if !result.More {
			break
		}
	}
	return results
}

func TestPruneStreamsStepRemovesRetiredStreams(t *testing.T) {
	s := newPruneTestStore(t)
	appendPruneTestEvents(t, s, "live", 1)
	appendPruneTestEvents(t, s, "dead", 1)

	cutoff := time.Now().UTC().Add(time.Hour).UnixMilli()
	results := drainPruneSteps(t, s, map[string]struct{}{"live": {}}, cutoff, 100)

	var removed []string
	for _, result := range results {
		if result.StreamRemoved {
			removed = append(removed, result.StreamID)
		}
	}
	if len(removed) != 1 || removed[0] != "dead" {
		t.Fatalf("removed = %v, want [dead]", removed)
	}
	if _, found, err := s.CanonicalExecution(context.Background(), "live"); err != nil || !found {
		t.Fatalf("live stream found=%v err=%v, must survive pruning", found, err)
	}
	if _, found, err := s.CanonicalExecution(context.Background(), "dead"); err != nil || found {
		t.Fatalf("dead stream found=%v err=%v, want pruned", found, err)
	}
}

func TestPruneStreamsStepRespectsCutoff(t *testing.T) {
	s := newPruneTestStore(t)
	appendPruneTestEvents(t, s, "fresh", 1)

	cutoff := time.Now().UTC().Add(-time.Hour).UnixMilli()
	result, err := s.PruneStreamsStep(context.Background(), nil, cutoff, 100)
	if err != nil {
		t.Fatal(err)
	}
	if result.StreamID != "" {
		t.Fatalf("pruned stream %q that is newer than the cutoff", result.StreamID)
	}
}

func TestPruneStreamsStepBatchesRows(t *testing.T) {
	s := newPruneTestStore(t)
	appendPruneTestEvents(t, s, "big", 5)
	cutoff := time.Now().UTC().Add(time.Hour).UnixMilli()

	first, err := s.PruneStreamsStep(context.Background(), nil, cutoff, 2)
	if err != nil {
		t.Fatal(err)
	}
	if first.DeletedRows != 2 || first.StreamRemoved || !first.More {
		t.Fatalf("first step = %#v, want 2 rows removed with more work", first)
	}
	second, err := s.PruneStreamsStep(context.Background(), nil, cutoff, 2)
	if err != nil {
		t.Fatal(err)
	}
	if second.DeletedRows != 2 || second.StreamRemoved || !second.More {
		t.Fatalf("second step = %#v, want the same stream drained next", second)
	}
	third, err := s.PruneStreamsStep(context.Background(), nil, cutoff, 2)
	if err != nil {
		t.Fatal(err)
	}
	if third.DeletedRows != 1 || !third.StreamRemoved || third.More {
		t.Fatalf("third step = %#v, want the stream removed", third)
	}
}

func TestPruneStreamsStepKeepsUnresolvedCommands(t *testing.T) {
	s := newPruneTestStore(t)
	ctx := context.Background()
	appendPruneTestEvents(t, s, "dead", 2)
	if _, _, err := s.BeginCanonicalCommand(ctx, "dead", "cmd-pending", "fingerprint-pending"); err != nil {
		t.Fatal(err)
	}

	cutoff := time.Now().UTC().Add(time.Hour).UnixMilli()
	drainPruneSteps(t, s, nil, cutoff, 100)

	record, found, err := s.GetCanonicalCommand(ctx, "dead", "cmd-pending")
	if err != nil || !found {
		t.Fatalf("pending command found=%v err=%v, must survive pruning", found, err)
	}
	if record.Status != CanonicalCommandPending {
		t.Fatalf("pending command status = %q", record.Status)
	}
}

func TestPruneAfterCloseIsNoop(t *testing.T) {
	s := newPruneTestStore(t)
	appendPruneTestEvents(t, s, "dead", 1)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	cutoff := time.Now().UTC().Add(time.Hour).UnixMilli()
	result, err := s.PruneStreamsStep(context.Background(), nil, cutoff, 100)
	if err != nil || result.StreamID != "" {
		t.Fatalf("step after close = %#v, err=%v, want a no-op", result, err)
	}
	if err := s.ReclaimSpace(context.Background(), 100); err != nil {
		t.Fatalf("reclaim after close = %v, want a no-op", err)
	}
}

func TestPruneStreamsStepDropsResolvedCommands(t *testing.T) {
	s := newPruneTestStore(t)
	ctx := context.Background()
	appendPruneTestEvents(t, s, "dead", 1)
	if _, _, err := s.BeginCanonicalCommand(ctx, "dead", "cmd-done", "fingerprint-done"); err != nil {
		t.Fatal(err)
	}
	if err := s.CompleteCanonicalCommand(ctx, "dead", "cmd-done", "fingerprint-done", nil, nil); err != nil {
		t.Fatal(err)
	}

	cutoff := time.Now().UTC().Add(time.Hour).UnixMilli()
	drainPruneSteps(t, s, nil, cutoff, 100)

	if _, found, err := s.GetCanonicalCommand(ctx, "dead", "cmd-done"); err != nil || found {
		t.Fatalf("resolved command found=%v err=%v, want pruned with its stream", found, err)
	}
}
