package store

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestAgentEventStoreAppendAndQuery(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "agent-events.db")

	store, err := OpenAgentEventStore(dbPath)
	if err != nil {
		t.Fatalf("OpenAgentEventStore error: %v", err)
	}
	defer store.Close()

	ctx := context.Background()
	sessionID := "session-1"
	epoch := uint64(1)

	events := []api.AgentEvent{
		{Type: "user", Role: "user", Content: "Hello world"},
		{Type: "assistant", Role: "assistant", Content: "I can help with that"},
		{Type: "tool_call", ToolName: "shell", CallID: "call-1"},
		{Type: "tool_output", Output: "done", CallID: "call-1"},
	}

	assigned, err := store.AppendEvents(ctx, sessionID, epoch, events, api.AgentStatus{Activity: api.AgentActivityWorking})
	if err != nil {
		t.Fatalf("AppendEvents error: %v", err)
	}

	if len(assigned) != 4 {
		t.Fatalf("assigned len = %d, want 4", len(assigned))
	}
	for i, e := range assigned {
		expectedSeq := uint64(i + 1)
		if e.Sequence != expectedSeq {
			t.Errorf("event[%d] sequence = %d, want %d", i, e.Sequence, expectedSeq)
		}
	}

	maxSeq, err := store.MaxSequence(ctx, sessionID, epoch)
	if err != nil {
		t.Fatalf("MaxSequence error: %v", err)
	}
	if maxSeq != 4 {
		t.Errorf("maxSeq = %d, want 4", maxSeq)
	}

	// Range query: since 2, before 4 -> events 2, 3
	queried, hasMore, err := store.QueryEvents(ctx, sessionID, epoch, 2, 4, 10)
	if err != nil {
		t.Fatalf("QueryEvents range error: %v", err)
	}
	if len(queried) != 2 {
		t.Fatalf("queried len = %d, want 2", len(queried))
	}
	if queried[0].Sequence != 2 || queried[1].Sequence != 3 {
		t.Errorf("queried sequences = %d, %d, want 2, 3", queried[0].Sequence, queried[1].Sequence)
	}
	if hasMore {
		t.Errorf("hasMore = true, want false")
	}

	// Query latest
	latest, _, err := store.QueryEvents(ctx, sessionID, epoch, 0, 0, 2)
	if err != nil {
		t.Fatalf("QueryEvents latest error: %v", err)
	}
	if len(latest) != 2 {
		t.Fatalf("latest len = %d, want 2", len(latest))
	}
	if latest[0].Sequence != 3 || latest[1].Sequence != 4 {
		t.Errorf("latest sequences = %d, %d, want 3, 4", latest[0].Sequence, latest[1].Sequence)
	}
}
