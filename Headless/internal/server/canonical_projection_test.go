package server

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestRestoreCanonicalProjectionReplaysEventsAfterCheckpoint(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.db")
	events := storeForProjectionTest(t, path)
	defer events.Close()

	ctx := context.Background()
	if _, err := events.AppendCanonicalEventsWithCheckpoint(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{{
		EventID: "status-1", Type: "status.changed", Origin: api.AgentEventOrigin{Kind: "host", Confidence: "derived"},
		Payload: map[string]any{"activity": string(api.AgentActivityWorking)},
	}}, map[string]any{"status": map[string]any{"activity": string(api.AgentActivityWorking)}}); err != nil {
		t.Fatal(err)
	}
	if _, err := events.AppendCanonicalEventsWithCheckpoint(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{{
		EventID: "turn-1", Type: "turn.started", TurnID: "7", Origin: api.AgentEventOrigin{Kind: "host", Confidence: "derived"},
		Payload: map[string]any{"turnId": "7", "status": string(api.AgentTurnStarted)},
	}}, map[string]any{
		"status":     map[string]any{"activity": string(api.AgentActivityWorking)},
		"turnId":     "7",
		"turnStatus": string(api.AgentTurnStarted),
	}); err != nil {
		t.Fatal(err)
	}
	// Simulate a process that committed an event but had not yet refreshed a
	// checkpoint when it was restarted. The replay must win over the stale
	// checkpoint without inventing a cursor.
	if _, err := events.AppendCanonicalEvents(ctx, "exec-1", "exec-1", []api.CanonicalAgentEvent{{
		EventID: "status-2", Type: "status.changed", Origin: api.AgentEventOrigin{Kind: "host", Confidence: "derived"},
		Payload: map[string]any{"activity": string(api.AgentActivityReady)},
	}}); err != nil {
		t.Fatal(err)
	}

	status, turn, ok := (&Service{AgentStore: events}).restoreCanonicalProjection("exec-1")
	if !ok || status.Activity != api.AgentActivityReady {
		t.Fatalf("restored status = %#v, ok=%v", status, ok)
	}
	if turn.ID != 7 || turn.Status != api.AgentTurnStarted {
		t.Fatalf("restored turn = %#v", turn)
	}
}

func storeForProjectionTest(t *testing.T, path string) *store.AgentEventStore {
	t.Helper()
	value, err := store.OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	return value
}
