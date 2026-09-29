package store

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestCanonicalHistoryPageCarriesLatestStateEvents(t *testing.T) {
	s, err := OpenAgentEventStore(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	event := func(id, kind string) api.CanonicalAgentEvent {
		return api.CanonicalAgentEvent{
			EventID: id, Type: kind, Origin: api.AgentEventOrigin{Kind: "host", Confidence: "native"},
			Payload: map[string]any{"id": id}, OccurredAt: time.Now().UTC(),
		}
	}
	events := []api.CanonicalAgentEvent{event("config-old", "config.updated"), event("config-new", "config.updated"), event("plan", "plan.updated")}
	for index := 0; index < 20; index++ {
		events = append(events, event(fmt.Sprintf("msg-%d", index), "message.completed"))
	}
	events = append(events, event("context", "context.updated"))
	if _, err := s.AppendCanonicalEvents(ctx, "exec", "exec", events); err != nil {
		t.Fatal(err)
	}

	// The newest page holds the context event but not the selectors or plan.
	page, err := s.QueryCanonicalEvents(ctx, "exec", 0, 0, 5)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, state := range page.StateEvents {
		got = append(got, state.EventID)
	}
	if fmt.Sprint(got) != "[config-new plan]" {
		t.Fatalf("state events = %v, want the latest config and the plan older than the page", got)
	}

	// An empty catch-up page still names the state as of its cursor.
	caughtUp, err := s.QueryCanonicalEvents(ctx, "exec", page.HeadSequence, 0, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(caughtUp.Events) != 0 || len(caughtUp.StateEvents) != 3 {
		t.Fatalf("caught-up page = %d events, %d state events; want 0 and 3", len(caughtUp.Events), len(caughtUp.StateEvents))
	}
}
