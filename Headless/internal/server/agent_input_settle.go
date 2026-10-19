package server

import (
	"context"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
)

// terminalSettleFunc waits until the TUI has drawn the input just written and
// its output has been still for quiet, bounded by agentInteractionSubmitDelay.
type terminalSettleFunc func(ctx context.Context, quiet time.Duration) error

type terminalSettleKey struct{}

const terminalSettlePoll = 10 * time.Millisecond

// agentInputContext prepares ctx for one PTY-driven Agent action on
// sessionID. It is called with the Session's action lock held, so the waits
// it installs run one at a time.
//
// The fixed 300ms pause between keys was sized for a slow redraw; most TUIs
// echo within a few milliseconds. When the Session's output ring is available
// the pause ends once new output has appeared and then stopped. A Session
// without observable output keeps the fixed pause.
//
// It also wakes the transcript watcher so the reply is read at the fast
// interval instead of on the next idle tick.
func (s *Service) agentInputContext(ctx context.Context, sessionID string) context.Context {
	s.pokeAgentTranscript(sessionID)
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession == nil {
		return ctx
	}
	baseline := outputSession.upper()
	settle := func(ctx context.Context, quiet time.Duration) error {
		defer s.pokeAgentTranscript(sessionID)
		start := time.Now()
		var changedAt time.Time
		ticker := time.NewTicker(terminalSettlePoll)
		defer ticker.Stop()
		for {
			now := time.Now()
			if current := outputSession.upper(); current != baseline {
				baseline = current
				changedAt = now
			}
			elapsed := now.Sub(start)
			if elapsed >= agentInteractionSubmitDelay {
				return nil
			}
			if !changedAt.IsZero() && elapsed >= agentInteractionMinimumDelay && now.Sub(changedAt) >= quiet {
				return nil
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-ticker.C:
			}
		}
	}
	return context.WithValue(ctx, terminalSettleKey{}, terminalSettleFunc(settle))
}

func (o *outputSession) upper() uint64 {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.ring.Upper()
}

// pokeAgentTranscript switches the Session's transcript watcher, legacy or
// provider-owned, to its fast interval.
func (s *Service) pokeAgentTranscript(sessionID string) {
	var watcher *agent.Watcher
	var handle *tuiAgentHandle
	s.agentsMu.Lock()
	if entry := s.agents[sessionID]; entry != nil {
		watcher = entry.watcher
		entry.mu.Lock()
		handle, _ = entry.handle.(*tuiAgentHandle)
		entry.mu.Unlock()
	}
	s.agentsMu.Unlock()
	if watcher == nil && handle != nil {
		handle.stateMu.Lock()
		watcher = handle.watcher
		handle.stateMu.Unlock()
	}
	watcher.Poke()
}
