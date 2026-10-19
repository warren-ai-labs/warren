package server

import (
	"context"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/output"
)

func newSettleTestService(t *testing.T) (*Service, *outputSession) {
	t.Helper()
	s := &Service{}
	s.lazyInit()
	o := &outputSession{sessionID: "session-1", ring: output.NewRing(1, 64, 1<<20, 0)}
	s.outputMu.Lock()
	s.outputs["session-1"] = o
	s.outputMu.Unlock()
	return s, o
}

func appendSettleOutput(o *outputSession, payload string) {
	o.mu.Lock()
	_, _ = o.ring.Append(o.sessionID, []byte(payload))
	o.mu.Unlock()
}

func TestAgentInputSettleEndsOnceOutputGoesQuiet(t *testing.T) {
	s, o := newSettleTestService(t)
	ctx := s.agentInputContext(context.Background(), "session-1")
	go func() {
		time.Sleep(15 * time.Millisecond)
		appendSettleOutput(o, "typed")
	}()
	start := time.Now()
	if err := waitAgentTerminalInput(ctx); err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(start)
	if elapsed < agentInteractionMinimumDelay || elapsed >= agentInteractionSubmitDelay-50*time.Millisecond {
		t.Fatalf("settle took %v, want between %v and well under %v", elapsed, agentInteractionMinimumDelay, agentInteractionSubmitDelay)
	}
}

func TestAgentInputSettleWaitsForContinuedOutput(t *testing.T) {
	s, o := newSettleTestService(t)
	ctx := s.agentInputContext(context.Background(), "session-1")
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				appendSettleOutput(o, "redraw")
			}
		}
	}()
	start := time.Now()
	if err := waitAgentTerminalSettle(ctx, agentInteractionLargeQuiet); err != nil {
		t.Fatal(err)
	}
	// Output never goes quiet, so the pause is capped at the old fixed delay.
	if elapsed := time.Since(start); elapsed < agentInteractionSubmitDelay {
		t.Fatalf("settle ended after %v while output was still changing", elapsed)
	}
}

func TestAgentInputSettleKeepsFixedDelayWithoutEcho(t *testing.T) {
	s, _ := newSettleTestService(t)
	ctx := s.agentInputContext(context.Background(), "session-1")
	start := time.Now()
	if err := waitAgentTerminalInput(ctx); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed < agentInteractionSubmitDelay {
		t.Fatalf("settle without output ended after %v", elapsed)
	}
}

func TestAgentInputSettleCountsOutputBeforeTheWait(t *testing.T) {
	s, o := newSettleTestService(t)
	ctx := s.agentInputContext(context.Background(), "session-1")
	// The echo can land while the input write is still returning.
	appendSettleOutput(o, "typed")
	start := time.Now()
	if err := waitAgentTerminalInput(ctx); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed >= agentInteractionSubmitDelay-50*time.Millisecond {
		t.Fatalf("settle took %v after an early echo", elapsed)
	}
}

func TestAgentInputContextWithoutOutputUsesFixedDelay(t *testing.T) {
	s := &Service{}
	s.lazyInit()
	ctx := s.agentInputContext(context.Background(), "missing")
	if _, ok := ctx.Value(terminalSettleKey{}).(terminalSettleFunc); ok {
		t.Fatal("a Session without output must keep the fixed delay")
	}
}
