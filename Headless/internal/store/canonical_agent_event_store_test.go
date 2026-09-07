package store

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestCanonicalAgentEventStoreAssignsImmutableSequences(t *testing.T) {
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	event := api.CanonicalAgentEvent{
		EventID: "evt-1", Type: "message.created", Origin: api.AgentEventOrigin{Kind: "provider", Confidence: "native"},
		Payload: map[string]any{"role": "assistant", "content": "hello"}, OccurredAt: time.Now().UTC(),
	}
	assigned, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{event})
	if err != nil || len(assigned) != 1 || assigned[0].Sequence != 1 {
		t.Fatalf("append = %#v, err=%v", assigned, err)
	}
	replay, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{event})
	if err != nil || len(replay) != 1 || replay[0].Sequence != 1 {
		t.Fatalf("replay = %#v, err=%v", replay, err)
	}
	conflict := event
	conflict.Payload = map[string]any{"role": "assistant", "content": "changed"}
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{conflict}); !errors.Is(err, ErrCanonicalEventConflict) {
		t.Fatalf("event conflict = %v", err)
	}
	positionConflict := event
	positionConflict.EventID = "evt-2"
	positionConflict.Sequence = 1
	if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{positionConflict}); !errors.Is(err, ErrCanonicalSequenceConflict) {
		t.Fatalf("sequence conflict = %v", err)
	}
}

func TestCanonicalAgentEventStoreReplaysTypedUsagePayload(t *testing.T) {
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	event := api.CanonicalAgentEvent{
		EventID:     "evt-usage-replay",
		StreamID:    "exec-usage",
		ExecutionID: "exec-usage",
		Type:        "usage",
		Origin:      api.AgentEventOrigin{Kind: "provider", Provider: "codex", Confidence: "observed"},
		Payload: map[string]any{
			"content": "Token usage",
			"model":   "gpt-5.6-luna",
			"usage":   &api.AgentUsage{InputTokens: 12736, CacheReadInputTokens: 11008, OutputTokens: 92, ReasoningOutputTokens: 11, TotalTokens: 12828},
		},
	}
	if _, err := s.AppendCanonicalEvents(ctx, "exec-usage", "exec-usage", []api.CanonicalAgentEvent{event}); err != nil {
		t.Fatalf("initial append: %v", err)
	}
	replay, err := s.AppendCanonicalEvents(ctx, "exec-usage", "exec-usage", []api.CanonicalAgentEvent{event})
	if err != nil {
		t.Fatalf("typed usage replay: %v", err)
	}
	if len(replay) != 1 || replay[0].Sequence != 1 {
		t.Fatalf("replay = %#v, want original sequence 1", replay)
	}
}

func TestCanonicalAgentEventStoreHistoryBounds(t *testing.T) {
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	for i := 1; i <= 4; i++ {
		if _, err := s.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{{
			EventID: string(rune('a' + i)), Type: "message.created", Origin: api.AgentEventOrigin{Kind: "host", Confidence: "derived"},
			Payload: map[string]any{"n": i},
		}}); err != nil {
			t.Fatal(err)
		}
	}
	latest, err := s.QueryCanonicalEvents(ctx, "exec-1", 0, 0, 2)
	if err != nil || len(latest.Events) != 2 || latest.Events[0].Sequence != 3 || latest.Events[1].Sequence != 4 {
		t.Fatalf("latest = %#v, err=%v", latest, err)
	}
	page, err := s.QueryCanonicalEvents(ctx, "exec-1", 0, 4, 2)
	if err != nil || len(page.Events) != 2 || page.Events[0].Sequence != 2 || page.Events[1].Sequence != 3 || !page.HasMore {
		t.Fatalf("before page = %#v, err=%v", page, err)
	}
}

func TestCanonicalAgentEventStorePersistsCheckpointWithAppend(t *testing.T) {
	path := filepath.Join(t.TempDir(), "checkpoint.db")
	ctx := context.Background()
	s, err := OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.AppendCanonicalEventsWithCheckpoint(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{{
		EventID: "evt-1", Type: "status.changed", Origin: api.AgentEventOrigin{Kind: "host", Confidence: "derived"},
		Payload: map[string]any{"activity": "working"},
	}}, map[string]any{"status": map[string]any{"activity": "working"}})
	if err != nil {
		t.Fatal(err)
	}
	checkpoint, ok, err := s.CanonicalCheckpoint(ctx, "exec-1")
	if err != nil || !ok || checkpoint.Sequence != 1 || checkpoint.State["status"] == nil {
		t.Fatalf("checkpoint = %#v, ok=%v, err=%v", checkpoint, ok, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	checkpoint, ok, err = s.CanonicalCheckpoint(ctx, "exec-1")
	if err != nil || !ok || checkpoint.Sequence != 1 {
		t.Fatalf("checkpoint after restart = %#v, ok=%v, err=%v", checkpoint, ok, err)
	}
}

func TestCanonicalCommandJournalSurvivesRestartAndRejectsReuse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "commands.db")
	ctx := context.Background()
	s, err := OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	record, leader, err := s.BeginCanonicalCommand(ctx, "exec-1", "cmd-1", "fp-1")
	if err != nil || !leader || record.Status != CanonicalCommandPending {
		t.Fatalf("begin = %#v leader=%v err=%v", record, leader, err)
	}
	if err := s.CompleteCanonicalCommand(ctx, "exec-1", "cmd-1", "fp-1", map[string]any{"accepted": true}, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	s, err = OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	replay, leader, err := s.BeginCanonicalCommand(ctx, "exec-1", "cmd-1", "fp-1")
	if err != nil || leader || replay.Status != CanonicalCommandCompleted {
		t.Fatalf("replay = %#v leader=%v err=%v", replay, leader, err)
	}
	if value, ok := replay.Result.(map[string]any); !ok || value["accepted"] != true {
		t.Fatalf("replay result = %#v", replay.Result)
	}
	if _, _, err := s.BeginCanonicalCommand(ctx, "exec-1", "cmd-1", "different"); !errors.Is(err, ErrCanonicalCommandConflict) {
		t.Fatalf("fingerprint conflict = %v", err)
	}
}

func TestCanonicalCommandJournalDoesNotReexecutePendingCommand(t *testing.T) {
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "commands.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	if _, leader, err := s.BeginCanonicalCommand(ctx, "exec-1", "cmd-1", "fp-1"); err != nil || !leader {
		t.Fatalf("first begin leader=%v err=%v", leader, err)
	}
	record, leader, err := s.BeginCanonicalCommand(ctx, "exec-1", "cmd-1", "fp-1")
	if err != nil || leader || record.Status != CanonicalCommandPending {
		t.Fatalf("pending retry = %#v leader=%v err=%v", record, leader, err)
	}
}

func TestCanonicalCommandJournalReconcilesStalePendingAsUnknown(t *testing.T) {
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "commands.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	record, leader, err := s.BeginCanonicalCommand(ctx, "exec-1", "cmd-1", "fp-1")
	if err != nil || !leader {
		t.Fatalf("begin leader=%v err=%v", leader, err)
	}
	now := time.UnixMilli(record.CreatedAt + 1)
	count, err := s.ReconcilePendingCanonicalCommands(ctx, now, 0)
	if err != nil || count != 1 {
		t.Fatalf("reconcile count=%d err=%v", count, err)
	}
	replay, leader, err := s.BeginCanonicalCommand(ctx, "exec-1", "cmd-1", "fp-1")
	if err != nil || leader || replay.Status != CanonicalCommandUnknown {
		t.Fatalf("unknown replay = %#v leader=%v err=%v", replay, leader, err)
	}
	if !strings.Contains(replay.Error, "new commandId") {
		t.Fatalf("unknown replay error = %q", replay.Error)
	}
}
