package server

import (
	"context"
	"sync"
	"time"
)

// Output flow control for clients that negotiated output-ack-v1.
//
// Without it a direct Ghostline reader enqueues output as fast as the PTY
// produces it. On a slow link those bytes pile up in the peer queue and in
// Relay, and a keystroke echo or Agent event sent afterwards waits behind all
// of them. With it the reader keeps roughly one round trip of output plus
// outputFlowQueueTarget in flight, and pauses (leaving the bytes in Ghostline)
// once the client stops acknowledging.
const (
	outputFlowInitialWindow = 256 * 1024
	outputFlowMinWindow     = 64 * 1024
	outputFlowMaxWindow     = 4 * 1024 * 1024
	// outputFlowQueueTarget is how much output may wait in queues beyond the
	// link's own round trip.
	outputFlowQueueTarget = 200 * time.Millisecond
	// outputFlowGain leaves headroom above the measured delivery rate so the
	// window can grow when the link has more capacity than the last sample.
	outputFlowGain = 1.25
	// outputFlowRateHold keeps the highest recent delivery rate for this long;
	// an idle terminal must not shrink the window to its quiet-period rate.
	outputFlowRateHold = 10 * time.Second
	// outputFlowRTTHold bounds how long a minimum round trip is trusted after a
	// route change.
	outputFlowRTTHold = 30 * time.Second
	// outputFlowMinRateInterval ignores ack pairs too close together to give a
	// meaningful delivery rate.
	outputFlowMinRateInterval = 50 * time.Millisecond
	outputFlowMaxSamples      = 64
	// outputFlowSkipAfter is how long, beyond two round trips, a reader may be
	// held back before the backlog is skipped: the client gets a fresh
	// terminal state instead of replaying output it would scroll past anyway.
	// Waiting for an ack always takes at least one round trip, so an absolute
	// threshold would skip a healthy client on a link slower than it.
	outputFlowSkipAfter = time.Second
	// outputFlowUnmeasuredRTT stands in for the round trip before the first
	// ack has measured it.
	outputFlowUnmeasuredRTT = time.Second
	// outputFlowSkipInterval limits snapshot recoveries per subscription; each
	// one briefly pauses the Session's shared reader.
	outputFlowSkipInterval = 3 * time.Second
)

type outputFlowSample struct {
	end uint64
	at  time.Time
}

type outputFlow struct {
	mu       sync.Mutex
	epoch    uint64
	sent     uint64
	acked    uint64
	samples  []outputFlowSample
	minRTT   time.Duration
	rttAt    time.Time
	rate     float64
	rateAt   time.Time
	lastAck  time.Time
	lastSeq  uint64
	wake     chan struct{}
	lastSkip time.Time
}

func newOutputFlow(epoch, sequence uint64) *outputFlow {
	return &outputFlow{
		epoch:   epoch,
		sent:    sequence,
		acked:   sequence,
		lastSeq: sequence,
		wake:    make(chan struct{}, 1),
	}
}

// window is the number of unacknowledged bytes the reader may have in flight.
func (f *outputFlow) window() uint64 {
	if f.minRTT <= 0 || f.rate <= 0 {
		return outputFlowInitialWindow
	}
	value := outputFlowGain * f.rate * (f.minRTT + outputFlowQueueTarget).Seconds()
	switch {
	case value < outputFlowMinWindow:
		return outputFlowMinWindow
	case value > outputFlowMaxWindow:
		return outputFlowMaxWindow
	}
	return uint64(value)
}

// recordSent notes that output up to end was handed to the peer queue.
func (f *outputFlow) recordSent(end uint64, now time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if end <= f.sent {
		return
	}
	f.sent = end
	if len(f.samples) >= outputFlowMaxSamples {
		// Drop the oldest sample; the newer ones still measure the round trip.
		copy(f.samples, f.samples[1:])
		f.samples = f.samples[:len(f.samples)-1]
	}
	f.samples = append(f.samples, outputFlowSample{end: end, at: now})
}

// recordAck applies a client acknowledgement. Acks for another epoch, for
// bytes already acknowledged, or beyond what was sent are ignored.
func (f *outputFlow) recordAck(epoch, sequence uint64, now time.Time) {
	f.mu.Lock()
	if epoch != f.epoch || sequence <= f.acked || sequence > f.sent {
		f.mu.Unlock()
		return
	}
	f.acked = sequence
	consumed := 0
	for _, sample := range f.samples {
		if sample.end > sequence {
			break
		}
		consumed++
		rtt := now.Sub(sample.at)
		if rtt > 0 && (f.minRTT <= 0 || rtt <= f.minRTT || now.Sub(f.rttAt) > outputFlowRTTHold) {
			f.minRTT = rtt
			f.rttAt = now
		}
	}
	f.samples = f.samples[consumed:]
	if !f.lastAck.IsZero() {
		if interval := now.Sub(f.lastAck); interval >= outputFlowMinRateInterval {
			rate := float64(sequence-f.lastSeq) / interval.Seconds()
			if rate >= f.rate || now.Sub(f.rateAt) > outputFlowRateHold {
				f.rate = rate
				f.rateAt = now
			}
			f.lastAck, f.lastSeq = now, sequence
		}
	} else {
		f.lastAck, f.lastSeq = now, sequence
	}
	f.mu.Unlock()
	select {
	case f.wake <- struct{}{}:
	default:
	}
}

func (f *outputFlow) hasRoom() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.sent-f.acked < f.window()
}

// waitForRoom blocks until the window has room. It reports how long it was
// held back and how long it was allowed to be, or false when ctx ended first.
// The allowance is fixed when the wait starts: the ack that ends a long hold
// measures the hold as its round trip, and must not excuse it.
func (f *outputFlow) waitForRoom(ctx context.Context) (blocked, allowed time.Duration, ok bool) {
	start := time.Now()
	allowed = f.skipAfter()
	for !f.hasRoom() {
		select {
		case <-ctx.Done():
			return time.Since(start), allowed, false
		case <-f.wake:
		}
	}
	return time.Since(start), allowed, true
}

// shouldSkip reports whether a reader held back for blocked, of allowed,
// should replace its backlog with a fresh terminal state now.
func (f *outputFlow) shouldSkip(blocked, allowed time.Duration, now time.Time) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return blocked >= allowed && now.Sub(f.lastSkip) >= outputFlowSkipInterval
}

// skipAfter is how long the reader may be held back before the backlog is
// skipped, given the round trip measured so far.
func (f *outputFlow) skipAfter() time.Duration {
	f.mu.Lock()
	defer f.mu.Unlock()
	rtt := f.minRTT
	if rtt <= 0 {
		rtt = outputFlowUnmeasuredRTT
	}
	return outputFlowSkipAfter + 2*rtt
}

// ackPeerOutput routes a session.ack to the peer's direct reader for sessionID.
func (s *Service) ackPeerOutput(peer *wsPeer, sessionID string, epoch, sequence uint64) {
	s.outputMu.Lock()
	stream := s.peerOutputs[peer][sessionID]
	s.outputMu.Unlock()
	if stream == nil || stream.flow == nil {
		return
	}
	stream.flow.recordAck(epoch, sequence, time.Now())
}

// skipPeerOutputBacklog replaces a held-back subscription's unsent output with
// a fresh atomic terminal state, in place, without closing the connection. It
// runs after the stream's reader has returned. A client subscribe or
// unsubscribe for the same Session, in flight or later, takes precedence.
func (s *Service) skipPeerOutputBacklog(peer *wsPeer, sessionID string, previous *peerOutputStream) {
	<-previous.done
	stillCurrent := func() bool {
		s.outputMu.Lock()
		defer s.outputMu.Unlock()
		return s.peerOutputs[peer][sessionID] == previous
	}
	if peer.isClosed() || !stillCurrent() {
		return
	}
	// A client subscribe already in flight replaces this stream anyway.
	// Cancelling it would fail the client's request and could leave the
	// Session with no subscription at all.
	ctx, finish, ok := peer.beginIdlePendingSubscription(context.Background(), sessionID)
	if !ok {
		return
	}
	defer finish()
	fail := func(err error) {
		if ctx.Err() != nil || peer.isClosed() {
			return
		}
		s.logWarn("skip output backlog", "session", sessionID, "error", err)
		peer.closeWithReason("force_reanchor")
	}
	session, ok := s.Session(sessionID)
	if !ok || session.Lifecycle != "running" || !stillCurrent() {
		return
	}
	lock, resume, err := s.prepareAttach(ctx, session)
	if err != nil {
		fail(err)
		return
	}
	defer resume()
	defer lock.Unlock()
	if ctx.Err() != nil || !stillCurrent() {
		return
	}
	s.reservePeerCursorOutput(peer, sessionID)
	if err := s.attachOutputLocked(ctx, peer, session, nil, "output.skip"); err != nil {
		fail(err)
		return
	}
	s.outputMu.Lock()
	if current := s.peerOutputs[peer][sessionID]; current != nil && current.flow != nil {
		current.flow.mu.Lock()
		current.flow.lastSkip = time.Now()
		current.flow.mu.Unlock()
	}
	s.outputMu.Unlock()
}
