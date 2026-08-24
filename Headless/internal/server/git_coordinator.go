package server

import (
	"context"
	"errors"
	"sync"
)

const (
	// gitCoordinatorPendingLimit bounds queued plus admitted Git requests
	// across all workspaces. It stays below the auxiliary executor capacity
	// so a workspace queue head can always claim its slot.
	gitCoordinatorPendingLimit = 24
	// gitCoordinatorWorkspacePendingLimit bounds queued plus admitted Git
	// requests for one workspace so a flood of panel refreshes for one
	// workspace cannot starve other workspaces.
	gitCoordinatorWorkspacePendingLimit = 8
)

var (
	errGitCoordinatorBusy      = errors.New("git workspace queue is busy")
	errGitCoordinatorCancelled = errors.New("git workspace turn cancelled")
)

// gitLeaseContextKey carries a coordinator lease in the context of an
// admitted head so Service methods it calls do not reacquire the workspace
// queue; direct Service callers acquire normally.
type gitLeaseContextKey struct{}

func withGitLease(ctx context.Context, workspaceID string) context.Context {
	return context.WithValue(ctx, gitLeaseContextKey{}, workspaceID)
}

func gitLeaseWorkspace(ctx context.Context) (string, bool) {
	workspaceID, ok := ctx.Value(gitLeaseContextKey{}).(string)
	return workspaceID, ok
}

type gitRequestState uint8

const (
	gitRequestQueued gitRequestState = iota
	gitRequestAdmitted
	gitRequestTerminal
)

// gitCoordinatedRequest is one workspace Git operation. The coordinator owns
// its queued -> admitted -> terminal transitions and publishes exactly one
// terminal outcome. writeCancelled writes the single cancelled response for
// a request that ended before run executed; writeRejected writes the single
// busy response for a head the auxiliary lane refused.
type gitCoordinatedRequest struct {
	workspaceID    string
	ctx            context.Context
	run            func(context.Context)
	writeCancelled func()
	writeRejected  func()
	terminal       func(requestTerminal)

	state gitRequestState
	done  chan struct{}
}

type gitWorkspaceQueue struct {
	id           string
	queued       []*gitCoordinatedRequest
	admitted     *gitCoordinatedRequest
	justRejected bool
}

// workspaceGitCoordinator serializes Git work per workspace and admits each
// workspace's queue head to the shared auxiliary lane. Ready workspaces are
// scheduled round-robin so one busy workspace cannot starve another, and at
// most admitLimit heads are in the auxiliary lane at once so a flood of
// ready workspaces waits for workers instead of overflowing the lane.
type workspaceGitCoordinator struct {
	mu                    sync.Mutex
	passMu                sync.Mutex
	admit                 func(requestJob) bool
	workspaces            map[string]*gitWorkspaceQueue
	ready                 []*gitWorkspaceQueue
	cursor                int
	pending               int
	pendingLimit          int
	workspacePendingLimit int
	admitLimit            int
	admitted              int
}

func newWorkspaceGitCoordinator(admit func(requestJob) bool, pendingLimit, workspacePendingLimit, admitLimit int) *workspaceGitCoordinator {
	return &workspaceGitCoordinator{
		admit:                 admit,
		workspaces:            make(map[string]*gitWorkspaceQueue),
		pendingLimit:          pendingLimit,
		workspacePendingLimit: workspacePendingLimit,
		admitLimit:            admitLimit,
	}
}

// setAdmit replaces the auxiliary submission function. NewHTTPServer wires
// its one shared executor here; tests may install a deterministic fake.
func (c *workspaceGitCoordinator) setAdmit(admit func(requestJob) bool) {
	c.mu.Lock()
	c.admit = admit
	c.mu.Unlock()
}

// submit enqueues a coordinated request. It returns false and owns nothing
// when the global or per-workspace pending limit is reached; the caller then
// writes one busy response and one terminal itself.
func (c *workspaceGitCoordinator) submit(req *gitCoordinatedRequest) bool {
	if req.ctx == nil {
		req.ctx = context.Background()
	}
	c.mu.Lock()
	queue := c.workspaces[req.workspaceID]
	if queue == nil {
		queue = &gitWorkspaceQueue{id: req.workspaceID}
		c.workspaces[req.workspaceID] = queue
	}
	workspacePending := len(queue.queued)
	if queue.admitted != nil {
		workspacePending++
	}
	if c.pending >= c.pendingLimit || workspacePending >= c.workspacePendingLimit {
		c.mu.Unlock()
		return false
	}
	req.state = gitRequestQueued
	req.done = make(chan struct{})
	queue.queued = append(queue.queued, req)
	c.pending++
	if queue.admitted == nil {
		c.addReadyLocked(queue)
	}
	c.mu.Unlock()
	go c.watchCancellation(req)
	c.admitReady()
	return true
}

// turn runs fn synchronously under the workspace coordination. Direct Service
// callers use it; an admitted head carries the lease instead and skips the
// queue entirely.
func (c *workspaceGitCoordinator) turn(ctx context.Context, workspaceID string, fn func(context.Context)) error {
	done := make(chan requestTerminal, 1)
	req := &gitCoordinatedRequest{
		workspaceID: workspaceID,
		ctx:         ctx,
		run:         fn,
		terminal: func(outcome requestTerminal) {
			done <- outcome
		},
	}
	if !c.submit(req) {
		return errGitCoordinatorBusy
	}
	select {
	case outcome := <-done:
		if outcome == requestRan {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		return errGitCoordinatorCancelled
	case <-ctx.Done():
		return ctx.Err()
	}
}

// admitReady admits ready workspace heads in round-robin order up to the
// admitted-head limit. It never holds the coordinator mutex while calling
// the auxiliary submission, so the executor's terminal callback (which takes
// the coordinator mutex) cannot deadlock with admission. passMu serializes
// admission passes so concurrent submit and headTerminal callers cannot
// over-admit past the limit.
func (c *workspaceGitCoordinator) admitReady() {
	c.passMu.Lock()
	defer c.passMu.Unlock()
	c.mu.Lock()
	kept := c.ready[:0]
	for _, queue := range c.ready {
		queue.justRejected = false
		if queue.admitted == nil && len(queue.queued) > 0 {
			kept = append(kept, queue)
		}
	}
	c.ready = kept
	if c.cursor >= len(c.ready) {
		c.cursor = 0
	}
	c.mu.Unlock()

	for {
		c.mu.Lock()
		if c.admitted >= c.admitLimit {
			c.mu.Unlock()
			return
		}
		index := -1
		for offset := 0; offset < len(c.ready); offset++ {
			candidate := (c.cursor + offset) % len(c.ready)
			queue := c.ready[candidate]
			if queue.admitted == nil && len(queue.queued) > 0 && !queue.justRejected {
				index = candidate
				break
			}
		}
		if index == -1 {
			c.mu.Unlock()
			return
		}
		queue := c.ready[index]
		c.ready = append(c.ready[:index], c.ready[index+1:]...)
		if index >= len(c.ready) {
			c.cursor = 0
		} else {
			c.cursor = index
		}
		req := queue.queued[0]
		queue.queued[0] = nil
		queue.queued = queue.queued[1:]
		if len(queue.queued) == 0 {
			queue.queued = nil
		}
		queue.admitted = req
		req.state = gitRequestAdmitted
		workspaceID := queue.id
		job := requestJob{
			ctx: req.ctx,
			run: func(ctx context.Context) {
				req.run(withGitLease(ctx, workspaceID))
			},
			terminal: func(outcome requestTerminal) {
				c.headTerminal(queue, req, outcome)
			},
		}
		c.mu.Unlock()

		if c.admit != nil && c.admit(job) {
			c.mu.Lock()
			c.admitted++
			c.mu.Unlock()
			continue
		}
		// The auxiliary lane refused the head: publish one busy response and
		// terminal, then let the next pass retry the next head.
		c.mu.Lock()
		queue.admitted = nil
		c.pending--
		c.markTerminalLocked(req)
		queue.justRejected = true
		c.addReadyLocked(queue)
		c.mu.Unlock()
		if req.writeRejected != nil {
			req.writeRejected()
		}
		if req.terminal != nil {
			req.terminal(requestRejected)
		}
	}
}

// headTerminal is the single completion closure for an admitted head: it runs
// only from the auxiliary executor's terminal callback after the executor
// released the running permit and capacity slot, and it advances the next
// head. No other path may release an admitted head.
func (c *workspaceGitCoordinator) headTerminal(queue *gitWorkspaceQueue, req *gitCoordinatedRequest, outcome requestTerminal) {
	c.mu.Lock()
	if queue.admitted != req {
		c.mu.Unlock()
		return
	}
	queue.admitted = nil
	c.admitted--
	c.pending--
	c.markTerminalLocked(req)
	if len(queue.queued) > 0 {
		c.addReadyLocked(queue)
	}
	c.mu.Unlock()
	switch outcome {
	case requestCancelled:
		if req.writeCancelled != nil {
			req.writeCancelled()
		}
	case requestRejected:
		if req.writeRejected != nil {
			req.writeRejected()
		}
	}
	if req.terminal != nil {
		req.terminal(outcome)
	}
	c.admitReady()
}

// watchCancellation removes a queued request whose context is cancelled,
// writes one cancelled response, and publishes one terminal. An admitted
// request is left to the auxiliary executor, which publishes the terminal.
func (c *workspaceGitCoordinator) watchCancellation(req *gitCoordinatedRequest) {
	select {
	case <-req.ctx.Done():
	case <-req.done:
		return
	}
	c.mu.Lock()
	if req.state != gitRequestQueued {
		c.mu.Unlock()
		return
	}
	queue := c.workspaces[req.workspaceID]
	for i, queued := range queue.queued {
		if queued == req {
			copy(queue.queued[i:], queue.queued[i+1:])
			queue.queued[len(queue.queued)-1] = nil
			queue.queued = queue.queued[:len(queue.queued)-1]
			break
		}
	}
	c.pending--
	c.markTerminalLocked(req)
	if queue.admitted == nil && len(queue.queued) > 0 {
		c.addReadyLocked(queue)
	}
	c.mu.Unlock()
	if req.writeCancelled != nil {
		req.writeCancelled()
	}
	if req.terminal != nil {
		req.terminal(requestCancelled)
	}
	c.admitReady()
}

func (c *workspaceGitCoordinator) markTerminalLocked(req *gitCoordinatedRequest) {
	if req.state == gitRequestTerminal {
		return
	}
	req.state = gitRequestTerminal
	close(req.done)
}

func (c *workspaceGitCoordinator) addReadyLocked(queue *gitWorkspaceQueue) {
	if queue.admitted != nil || len(queue.queued) == 0 {
		return
	}
	for _, existing := range c.ready {
		if existing == queue {
			return
		}
	}
	c.ready = append(c.ready, queue)
}

const (
	swrWorkerLimit   = 2
	swrQueueCapacity = 8
)

// staleRevalidateLane is the bounded, Service-owned stale-while-revalidate
// lane. Revalidation contexts are Host-owned, so a requesting peer's
// cancellation never cancels already accepted revalidation work.
type staleRevalidateLane struct {
	service *Service
	jobs    chan swrJob
}

type swrJob struct {
	workspaceID string
	path        string
}

func newStaleRevalidateLane(service *Service, workerLimit, queueCapacity int) *staleRevalidateLane {
	lane := &staleRevalidateLane{service: service, jobs: make(chan swrJob, queueCapacity)}
	for i := 0; i < workerLimit; i++ {
		go lane.worker()
	}
	return lane
}

func (l *staleRevalidateLane) worker() {
	for job := range l.jobs {
		l.service.revalidatePanel(job.workspaceID, job.path)
	}
}

func (l *staleRevalidateLane) submit(workspaceID, path string) bool {
	select {
	case l.jobs <- swrJob{workspaceID: workspaceID, path: path}:
		return true
	default:
		return false
	}
}
