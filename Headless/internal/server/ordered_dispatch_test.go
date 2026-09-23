package server

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// A CLI consumes injected input in arrival order, so two turns sent back to back
// must reach it in that order. Running them as bare goroutines would let the
// scheduler reverse them.
func TestOrderedDispatchPreservesOrderWithinADomain(t *testing.T) {
	dispatcher := newOrderedDispatcher()
	var mu sync.Mutex
	var observed []int
	done := make(chan struct{})
	for index := range 50 {
		if !dispatcher.submit("session:a", func() {
			// A slow first item must not let a later one overtake it.
			if index == 0 {
				time.Sleep(20 * time.Millisecond)
			}
			mu.Lock()
			observed = append(observed, index)
			finished := len(observed) == 50
			mu.Unlock()
			if finished {
				close(done)
			}
		}) {
			t.Fatalf("submit %d was refused", index)
		}
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("ordered work never finished")
	}
	mu.Lock()
	defer mu.Unlock()
	for index, value := range observed {
		if value != index {
			t.Fatalf("observed order = %v, want ascending", observed)
		}
	}
}

// Two sessions are independent: one blocked turn must not stall another
// session's work, which is the whole reason this runs off the reader.
func TestOrderedDispatchRunsDomainsConcurrently(t *testing.T) {
	dispatcher := newOrderedDispatcher()
	blocked := make(chan struct{})
	release := make(chan struct{})
	other := make(chan struct{})
	dispatcher.submit("session:a", func() {
		close(blocked)
		<-release
	})
	<-blocked
	dispatcher.submit("session:b", func() { close(other) })
	select {
	case <-other:
	case <-time.After(2 * time.Second):
		close(release)
		t.Fatal("a blocked domain stalled an unrelated one")
	}
	close(release)
}

// A full backlog is refused rather than dropped: the client has to learn the
// turn never ran, or its queue item waits forever for an echo that is not
// coming.
func TestOrderedDispatchRefusesAnOverfullDomain(t *testing.T) {
	dispatcher := newOrderedDispatcher()
	release := make(chan struct{})
	running := make(chan struct{})
	// Fill the queue behind a submission that is already running, not merely
	// submitted: until the drain goroutine dequeues it, it still occupies a slot
	// and the count would depend on scheduling.
	dispatcher.submit("session:a", func() { close(running); <-release })
	<-running
	accepted := 0
	for range maxOrderedQueueDepth * 2 {
		if dispatcher.submit("session:a", func() {}) {
			accepted++
		}
	}
	close(release)
	if accepted != maxOrderedQueueDepth {
		t.Fatalf("accepted %d submissions, want the depth bound %d", accepted, maxOrderedQueueDepth)
	}
}

// A domain that finished must leave nothing behind; sessions come and go, and
// the maps would otherwise grow for the daemon's lifetime.
func TestOrderedDispatchForgetsFinishedDomains(t *testing.T) {
	dispatcher := newOrderedDispatcher()
	done := make(chan struct{})
	dispatcher.submit("session:a", func() { close(done) })
	<-done
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		dispatcher.mu.Lock()
		queues, active := len(dispatcher.queues), len(dispatcher.active)
		dispatcher.mu.Unlock()
		if queues == 0 && active == 0 {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("a finished domain was left in the dispatcher")
}

// Only the requests that actually blocked a pong are moved off the reader, and
// each is keyed by the session it belongs to.
func TestOrderedRequestKeyCoversTheBlockingRequests(t *testing.T) {
	for _, probe := range []struct {
		method string
		params map[string]any
		want   string
	}{
		{method: "agent.turn.start", params: map[string]any{"executionId": "exec-1"}, want: "execution:exec-1"},
		{method: "agent.turn.steer", params: map[string]any{"executionId": "exec-1"}, want: "execution:exec-1"},
		{method: "agent.turn.cancel", params: map[string]any{"executionId": "exec-1"}, want: "execution:exec-1"},
		{method: "session.focus", params: map[string]any{"id": "sess-1"}, want: "session:sess-1"},
		// Without a session to order against there is nothing to serialize, and
		// the request fails validation immediately anyway.
		{method: "agent.turn.start", params: map[string]any{}, want: ""},
		// Reads already run as background requests and must not be re-routed.
		{method: "agent.events.history", params: map[string]any{"executionId": "exec-1"}, want: ""},
		{method: "session.input", params: map[string]any{"id": "sess-1"}, want: ""},
	} {
		t.Run(fmt.Sprintf("%s/%v", probe.method, probe.params), func(t *testing.T) {
			key := orderedRequestKey(api.Envelope{Method: probe.method, Params: probe.params})
			if key != probe.want {
				t.Fatalf("orderedRequestKey = %q, want %q", key, probe.want)
			}
		})
	}
	// session.focus may carry its session in the envelope instead of params.
	key := orderedRequestKey(api.Envelope{Method: "session.focus", Session: "sess-2"})
	if key != "session:sess-2" {
		t.Fatalf("envelope-scoped focus key = %q, want session:sess-2", key)
	}
}
