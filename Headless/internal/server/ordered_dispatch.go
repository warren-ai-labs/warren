package server

import (
	"errors"
	"sync"
)

// maxOrderedQueueDepth bounds one ordering domain's backlog. A client that
// pipelines more turns than this into a single session is misbehaving, and
// refusing is better than letting the Host accumulate unbounded work.
const maxOrderedQueueDepth = 64

// errTooManyQueuedRequests is reported when one session's ordered backlog is
// full. It is a refusal, not a drop: the client must know the turn never ran so
// its queue item can fail rather than wait forever for an echo.
var errTooManyQueuedRequests = errors.New("too many queued requests for this session")

// orderedDispatcher runs requests off the caller's goroutine while preserving
// their arrival order within an ordering domain.
//
// It exists for requests that must not block the WebSocket reader but also must
// not be reordered. An `agent.turn.start` can take seconds inside the provider,
// and running it on the reader delays every later command on the same
// connection — including the heartbeat pong, which then misses its deadline and
// closes a healthy socket. A bare `go func()` fixes the blocking and breaks the
// ordering instead: two turns sent back to back would race, and the CLI would
// receive them in whichever order the scheduler picked.
//
// One goroutine drains one domain at a time, so domains are concurrent with
// each other and serial within themselves.
type orderedDispatcher struct {
	mu     sync.Mutex
	queues map[string][]func()
	active map[string]bool
}

func newOrderedDispatcher() *orderedDispatcher {
	return &orderedDispatcher{queues: map[string][]func(){}, active: map[string]bool{}}
}

// submit schedules work to run after every earlier submission for the same key
// has finished. It reports false when the domain's backlog is full; the caller
// must surface that as an error rather than dropping the request silently.
func (dispatcher *orderedDispatcher) submit(key string, work func()) bool {
	if dispatcher == nil || work == nil {
		return false
	}
	dispatcher.mu.Lock()
	if len(dispatcher.queues[key]) >= maxOrderedQueueDepth {
		dispatcher.mu.Unlock()
		return false
	}
	dispatcher.queues[key] = append(dispatcher.queues[key], work)
	if dispatcher.active[key] {
		dispatcher.mu.Unlock()
		return true
	}
	dispatcher.active[key] = true
	dispatcher.mu.Unlock()
	go dispatcher.drain(key)
	return true
}

func (dispatcher *orderedDispatcher) drain(key string) {
	for {
		dispatcher.mu.Lock()
		queue := dispatcher.queues[key]
		if len(queue) == 0 {
			// Drop both entries together. Sessions come and go, so a domain that
			// finished must leave nothing behind or the maps grow for the
			// daemon's lifetime.
			delete(dispatcher.queues, key)
			delete(dispatcher.active, key)
			dispatcher.mu.Unlock()
			return
		}
		work := queue[0]
		dispatcher.queues[key] = queue[1:]
		dispatcher.mu.Unlock()
		work()
	}
}

// depth reports one domain's pending backlog, for tests and diagnostics.
func (dispatcher *orderedDispatcher) depth(key string) int {
	dispatcher.mu.Lock()
	defer dispatcher.mu.Unlock()
	return len(dispatcher.queues[key])
}
