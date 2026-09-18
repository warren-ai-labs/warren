package server

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func appendServerPruneEvents(t *testing.T, agentStore *store.AgentEventStore, streamID string, count int) {
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
	if _, err := agentStore.AppendCanonicalEvents(context.Background(), streamID, streamID, events); err != nil {
		t.Fatal(err)
	}
}

func TestPruneAgentJournalRemovesRetiredStreams(t *testing.T) {
	directory := t.TempDir()
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session-live", AgentExecutionID: "exec-live", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	// DefaultFinder is what the daemon wires. Without it the Host rebuilds Usage
	// from the journal, and the sweep correctly refuses to prune.
	service := &Service{Store: state, AgentFinder: agent.DefaultFinder{}, AgentStorePath: filepath.Join(directory, "events.db")}
	service.lazyInit()
	agentStore := service.agentStore()
	if agentStore == nil {
		t.Fatal("agent journal did not open")
	}

	ctx := context.Background()
	appendServerPruneEvents(t, agentStore, "exec-live", 1)
	appendServerPruneEvents(t, agentStore, "exec-dead", 1)

	// A future cutoff makes every stream eligible, so only the protect set can
	// keep the live stream.
	service.pruneAgentJournalBefore(ctx, time.Now().UTC().Add(time.Hour))

	if _, found, err := agentStore.CanonicalExecution(ctx, "exec-live"); err != nil || !found {
		t.Fatalf("protected stream found=%v err=%v, must survive the sweep", found, err)
	}
	if _, found, err := agentStore.CanonicalExecution(ctx, "exec-dead"); err != nil || found {
		t.Fatalf("retired stream found=%v err=%v, want pruned", found, err)
	}
}

func TestPruneAgentJournalKeepsJournalWithoutHistoricalFinder(t *testing.T) {
	directory := t.TempDir()
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	// No AgentFinder means Usage can only be rebuilt from the journal, so the
	// sweep must leave the journal alone even for a stream no Session owns.
	service := &Service{Store: state, AgentStorePath: filepath.Join(directory, "events.db")}
	service.lazyInit()
	agentStore := service.agentStore()
	if agentStore == nil {
		t.Fatal("agent journal did not open")
	}

	ctx := context.Background()
	appendServerPruneEvents(t, agentStore, "exec-dead", 1)
	service.pruneAgentJournalBefore(ctx, time.Now().UTC().Add(time.Hour))

	if _, found, err := agentStore.CanonicalExecution(ctx, "exec-dead"); err != nil || !found {
		t.Fatalf("stream found=%v err=%v, journal must be retained without a historical finder", found, err)
	}
}
