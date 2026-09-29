package server

import (
	"context"
	"strings"
	"time"
)

// startAgentJournalPrune runs at most one background journal sweep. The sweep
// deletes rows in bounded transactions and can take minutes on a large
// journal, so it must never run inside the lifecycle loop itself.
func (s *Service) startAgentJournalPrune(ctx context.Context) {
	if !s.agentJournalPruning.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer s.agentJournalPruning.Store(false)
		s.pruneAgentJournal(ctx)
	}()
}

// pruneAgentJournal removes Agent streams no Session refers to any more. The
// journal replicates a conversation to clients; it is not an archive. Once a
// Session is deleted from the roster its execution id is never reused, so the
// stream is garbage after the grace window and can be reclaimed from the
// provider transcript if it is ever needed again.
func (s *Service) pruneAgentJournal(ctx context.Context) {
	s.pruneAgentJournalBefore(ctx, time.Now().UTC().Add(-agentJournalRetentionGrace))
}

// pruneAgentJournalBefore is the sweep with an explicit cutoff. Tests use it to
// prune without waiting out the grace window.
func (s *Service) pruneAgentJournalBefore(ctx context.Context, cutoffTime time.Time) {
	// Rebuilding Usage replaces the rollups of every provider it names, named
	// from the journal itself. A Host that cannot enumerate historical
	// transcripts therefore rebuilds Usage *from* the journal, and pruning rows
	// would let the next rebuild drop spend it can no longer re-derive. The
	// journal is kept complete whenever the parser-backed path is absent.
	if _, ok := historicalUsageFinder(s.AgentFinder); !ok {
		return
	}
	agentStore := s.agentStore()
	if agentStore == nil {
		return
	}
	protect := s.protectedAgentStreams()
	cutoff := cutoffTime.UnixMilli()
	for ctx.Err() == nil {
		result, err := agentStore.PruneStreamsStep(ctx, protect, cutoff, agentJournalPruneRowBudget)
		if err != nil {
			s.logWarn("prune agent journal", "error", err)
			return
		}
		if result.StreamID == "" || !result.More {
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(agentJournalPrunePause):
		}
	}
	if err := agentStore.ReclaimSpace(ctx, agentJournalReclaimPages); err != nil {
		s.logWarn("reclaim agent journal space", "error", err)
	}
}

// protectedAgentStreams returns every execution id a Session still refers to.
//
// A stream is retained exactly while its Session exists in the roster, plus the
// grace window after the Session is deleted. An ended Session keeps its
// execution id and resuming it reuses that id, so protecting only running
// Sessions would let a later resume append into a stream the sweep had already
// released. Release follows Session removal (DeleteSession), not the lifecycle
// transition to ended.
func (s *Service) protectedAgentStreams() map[string]struct{} {
	protect := make(map[string]struct{})
	if s.Store == nil {
		return protect
	}
	for _, session := range s.Store.Snapshot().Sessions {
		if id := strings.TrimSpace(session.AgentExecutionID); id != "" {
			protect[id] = struct{}{}
		}
	}
	return protect
}
