package server

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// coordinatorTestRequest is a barrier-driven coordinated request: its run
// reports entry and blocks until the test releases it, while the terminal
// callback reports the single outcome.
type coordinatorTestRequest struct {
	entered   chan struct{}
	release   chan struct{}
	terminal  chan requestTerminal
	cancelled atomic.Int32
	rejected  atomic.Int32
}

func newCoordinatorTestRequest(ctx context.Context, workspaceID string) (*gitCoordinatedRequest, *coordinatorTestRequest) {
	barrier := &coordinatorTestRequest{
		entered:  make(chan struct{}),
		release:  make(chan struct{}),
		terminal: make(chan requestTerminal, 1),
	}
	request := &gitCoordinatedRequest{
		workspaceID: workspaceID,
		ctx:         ctx,
		writeCancelled: func() {
			barrier.cancelled.Add(1)
		},
		writeRejected: func() {
			barrier.rejected.Add(1)
		},
		run: func(context.Context) {
			close(barrier.entered)
			<-barrier.release
		},
		terminal: func(outcome requestTerminal) {
			barrier.terminal <- outcome
		},
	}
	return request, barrier
}

// queueingAdmit accepts every submission without executing it, so tests can
// hold admitted heads and start them explicitly.
type queueingAdmit struct {
	mu   sync.Mutex
	jobs []requestJob
}

func (a *queueingAdmit) submit(job requestJob) bool {
	a.mu.Lock()
	a.jobs = append(a.jobs, job)
	a.mu.Unlock()
	return true
}

func (a *queueingAdmit) waitForJob(t *testing.T) requestJob {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		a.mu.Lock()
		if len(a.jobs) > 0 {
			job := a.jobs[0]
			a.jobs = a.jobs[1:]
			a.mu.Unlock()
			return job
		}
		a.mu.Unlock()
		time.Sleep(time.Millisecond)
	}
	t.Fatal("timed out waiting for an admitted job")
	return requestJob{}
}

func (a *queueingAdmit) start(job requestJob) {
	go func() {
		outcome := requestRan
		if job.ctx != nil && job.ctx.Err() != nil {
			outcome = requestCancelled
		} else if job.run != nil {
			job.run(job.ctx)
		}
		if job.terminal != nil {
			job.terminal(outcome)
		}
	}()
}

// flakyAdmit rejects the first few submissions and then accepts and executes
// the rest, mirroring an auxiliary lane that is briefly unavailable.
type flakyAdmit struct {
	mu      sync.Mutex
	rejects int
	calls   int
}

func newFlakyAdmit(rejects int) *flakyAdmit {
	return &flakyAdmit{rejects: rejects}
}

func (a *flakyAdmit) submit(job requestJob) bool {
	a.mu.Lock()
	a.calls++
	reject := a.calls <= a.rejects
	a.mu.Unlock()
	if reject {
		return false
	}
	go func() {
		outcome := requestRan
		if job.ctx != nil && job.ctx.Err() != nil {
			outcome = requestCancelled
		} else if job.run != nil {
			job.run(job.ctx)
		}
		if job.terminal != nil {
			job.terminal(outcome)
		}
	}()
	return true
}

func newCoordinatorWithExecutor(workerLimit, capacityLimit int) *workspaceGitCoordinator {
	executor := newAuxiliaryExecutor(workerLimit, capacityLimit)
	return newWorkspaceGitCoordinator(executor.submit, gitCoordinatorPendingLimit, gitCoordinatorWorkspacePendingLimit, workerLimit)
}

func waitForCoordinatorQueued(t *testing.T, coordinator *workspaceGitCoordinator, workspaceID string, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		coordinator.mu.Lock()
		queue := coordinator.workspaces[workspaceID]
		queued := 0
		if queue != nil {
			queued = len(queue.queued)
		}
		coordinator.mu.Unlock()
		if queued == count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("workspace %s queue never reached %d items", workspaceID, count)
}

func assertCoordinatorTerminal(t *testing.T, terminals <-chan requestTerminal, want requestTerminal) {
	t.Helper()
	select {
	case outcome := <-terminals:
		if outcome != want {
			t.Fatalf("terminal = %v, want %v", outcome, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for terminal %v", want)
	}
}

func TestWorkspaceGitCoordinatorSerializesSameWorkspace(t *testing.T) {
	coordinator := newCoordinatorWithExecutor(1, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first, firstBarrier := newCoordinatorTestRequest(ctx, "workspace")
	second, secondBarrier := newCoordinatorTestRequest(ctx, "workspace")

	if !coordinator.submit(first) {
		t.Fatal("first request was rejected")
	}
	waitDone(t, firstBarrier.entered, "first request to start")
	if !coordinator.submit(second) {
		t.Fatal("second request was rejected")
	}
	coordinator.mu.Lock()
	queue := coordinator.workspaces["workspace"]
	queued := 0
	if queue != nil {
		queued = len(queue.queued)
	}
	admitted := queue != nil && queue.admitted == first
	coordinator.mu.Unlock()
	if queued != 1 || !admitted {
		t.Fatalf("second request not queued behind the running head: queued=%d", queued)
	}
	select {
	case <-secondBarrier.entered:
		t.Fatal("second workspace request entered while the first was running")
	default:
	}

	close(firstBarrier.release)
	assertCoordinatorTerminal(t, firstBarrier.terminal, requestRan)
	waitDone(t, secondBarrier.entered, "second request to start after the first completed")
	close(secondBarrier.release)
	assertCoordinatorTerminal(t, secondBarrier.terminal, requestRan)
}

func TestWorkspaceGitCoordinatorDifferentWorkspacesConcur(t *testing.T) {
	coordinator := newCoordinatorWithExecutor(2, 2)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first, firstBarrier := newCoordinatorTestRequest(ctx, "workspace-a")
	second, secondBarrier := newCoordinatorTestRequest(ctx, "workspace-b")

	if !coordinator.submit(first) {
		t.Fatal("first request was rejected")
	}
	waitDone(t, firstBarrier.entered, "first request to start")
	if !coordinator.submit(second) {
		t.Fatal("second request was rejected")
	}
	waitDone(t, secondBarrier.entered, "second workspace to start while the first is running")

	close(firstBarrier.release)
	close(secondBarrier.release)
	assertCoordinatorTerminal(t, firstBarrier.terminal, requestRan)
	assertCoordinatorTerminal(t, secondBarrier.terminal, requestRan)
}

func TestWorkspaceGitCoordinatorReadyWorkspaceBeatsFollower(t *testing.T) {
	coordinator := newCoordinatorWithExecutor(1, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	head, headBarrier := newCoordinatorTestRequest(ctx, "workspace-a")
	follower, followerBarrier := newCoordinatorTestRequest(ctx, "workspace-a")
	other, otherBarrier := newCoordinatorTestRequest(ctx, "workspace-b")

	if !coordinator.submit(head) {
		t.Fatal("head was rejected")
	}
	waitDone(t, headBarrier.entered, "head to start")
	if !coordinator.submit(follower) {
		t.Fatal("follower was rejected")
	}
	if !coordinator.submit(other) {
		t.Fatal("other workspace head was rejected")
	}
	if got := otherBarrier.rejected.Load(); got != 0 {
		t.Fatalf("ready workspace B was rejected %d times; want it to wait", got)
	}
	waitForCoordinatorQueued(t, coordinator, "workspace-b", 1)

	close(headBarrier.release)
	assertCoordinatorTerminal(t, headBarrier.terminal, requestRan)
	// After A completes, already-ready B must enter before A's next follower
	// and only after A's running and capacity permits were released.
	waitDone(t, otherBarrier.entered, "ready workspace B to start before A's follower")
	select {
	case <-followerBarrier.entered:
		t.Fatal("A follower entered before ready workspace B")
	default:
	}
	close(otherBarrier.release)
	assertCoordinatorTerminal(t, otherBarrier.terminal, requestRan)
	waitDone(t, followerBarrier.entered, "A follower to start after B completed")
	close(followerBarrier.release)
	assertCoordinatorTerminal(t, followerBarrier.terminal, requestRan)
}

func TestWorkspaceGitCoordinatorCancelQueuedFollower(t *testing.T) {
	coordinator := newCoordinatorWithExecutor(2, 2)
	headCtx, headCancel := context.WithCancel(context.Background())
	defer headCancel()
	head, headBarrier := newCoordinatorTestRequest(headCtx, "workspace")
	if !coordinator.submit(head) {
		t.Fatal("head was rejected")
	}
	waitDone(t, headBarrier.entered, "head to start")

	followerCtx, followerCancel := context.WithCancel(context.Background())
	follower, followerBarrier := newCoordinatorTestRequest(followerCtx, "workspace")
	if !coordinator.submit(follower) {
		t.Fatal("follower was rejected")
	}
	followerCancel()
	assertCoordinatorTerminal(t, followerBarrier.terminal, requestCancelled)
	if got := followerBarrier.cancelled.Load(); got != 1 {
		t.Fatalf("cancelled responses = %d, want 1", got)
	}
	select {
	case <-followerBarrier.entered:
		t.Fatal("cancelled follower ran")
	default:
	}

	// A third workspace still starts while the head holds one slot, proving
	// the cancelled follower never consumed an auxiliary slot.
	third, thirdBarrier := newCoordinatorTestRequest(headCtx, "workspace-c")
	if !coordinator.submit(third) {
		t.Fatal("third request was rejected")
	}
	waitDone(t, thirdBarrier.entered, "third workspace to start after follower cancellation")

	close(headBarrier.release)
	close(thirdBarrier.release)
	assertCoordinatorTerminal(t, headBarrier.terminal, requestRan)
	assertCoordinatorTerminal(t, thirdBarrier.terminal, requestRan)
}

func TestWorkspaceGitCoordinatorCancelledHeadBeforeRun(t *testing.T) {
	coordinator := newCoordinatorWithExecutor(2, 2)
	blockerCtx, blockerCancel := context.WithCancel(context.Background())
	defer blockerCancel()
	blocker, blockerBarrier := newCoordinatorTestRequest(blockerCtx, "blocker")
	if !coordinator.submit(blocker) {
		t.Fatal("blocker was rejected")
	}
	waitDone(t, blockerBarrier.entered, "blocker to start")

	headCtx, headCancel := context.WithCancel(context.Background())
	head, headBarrier := newCoordinatorTestRequest(headCtx, "workspace")
	if !coordinator.submit(head) {
		t.Fatal("head was rejected")
	}
	// The head is admitted to the auxiliary executor but cannot start while
	// the blocker holds the only worker; cancelling it before it runs must
	// publish one cancelled terminal without invoking the run.
	headCancel()
	close(blockerBarrier.release)
	assertCoordinatorTerminal(t, blockerBarrier.terminal, requestRan)
	assertCoordinatorTerminal(t, headBarrier.terminal, requestCancelled)
	if got := headBarrier.cancelled.Load(); got != 1 {
		t.Fatalf("cancelled responses = %d, want 1", got)
	}
	select {
	case <-headBarrier.entered:
		t.Fatal("cancelled admitted head ran")
	default:
	}
}

func TestWorkspaceGitCoordinatorHeadRejectionPublishesBusyAndAdvances(t *testing.T) {
	admit := newFlakyAdmit(1)
	coordinator := newWorkspaceGitCoordinator(admit.submit, gitCoordinatorPendingLimit, gitCoordinatorWorkspacePendingLimit, 4)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	first, firstBarrier := newCoordinatorTestRequest(ctx, "workspace")
	if !coordinator.submit(first) {
		t.Fatal("first request was rejected at enqueue")
	}
	assertCoordinatorTerminal(t, firstBarrier.terminal, requestRejected)
	if got := firstBarrier.rejected.Load(); got != 1 {
		t.Fatalf("busy responses = %d, want 1", got)
	}
	if got := firstBarrier.cancelled.Load(); got != 0 {
		t.Fatalf("cancelled responses = %d, want 0 for a rejection", got)
	}

	second, secondBarrier := newCoordinatorTestRequest(ctx, "workspace")
	if !coordinator.submit(second) {
		t.Fatal("second request was rejected at enqueue")
	}
	waitDone(t, secondBarrier.entered, "next head to run after rejection")
	close(secondBarrier.release)
	assertCoordinatorTerminal(t, secondBarrier.terminal, requestRan)
}

func TestWorkspaceGitCoordinatorPerWorkspacePendingLimit(t *testing.T) {
	admit := &queueingAdmit{}
	coordinator := newWorkspaceGitCoordinator(admit.submit, gitCoordinatorPendingLimit, 2, 4)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first, _ := newCoordinatorTestRequest(ctx, "workspace")
	second, _ := newCoordinatorTestRequest(ctx, "workspace")
	third, _ := newCoordinatorTestRequest(ctx, "workspace")

	if !coordinator.submit(first) {
		t.Fatal("first request was rejected")
	}
	if !coordinator.submit(second) {
		t.Fatal("second request was rejected")
	}
	if coordinator.submit(third) {
		t.Fatal("third request accepted beyond the per-workspace pending limit")
	}
}

func TestWorkspaceGitCoordinatorGlobalPendingLimit(t *testing.T) {
	admit := &queueingAdmit{}
	coordinator := newWorkspaceGitCoordinator(admit.submit, 2, gitCoordinatorWorkspacePendingLimit, 4)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first, _ := newCoordinatorTestRequest(ctx, "workspace-a")
	second, _ := newCoordinatorTestRequest(ctx, "workspace-b")
	third, _ := newCoordinatorTestRequest(ctx, "workspace-c")

	if !coordinator.submit(first) {
		t.Fatal("first request was rejected")
	}
	if !coordinator.submit(second) {
		t.Fatal("second request was rejected")
	}
	if coordinator.submit(third) {
		t.Fatal("third request accepted beyond the global pending limit")
	}
}

func TestWorkspaceGitCoordinatorTurnRejectsWhenBusy(t *testing.T) {
	admit := &queueingAdmit{}
	coordinator := newWorkspaceGitCoordinator(admit.submit, 1, 1, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	head, headBarrier := newCoordinatorTestRequest(ctx, "workspace")
	if !coordinator.submit(head) {
		t.Fatal("head was rejected")
	}
	if err := coordinator.turn(ctx, "workspace", func(context.Context) {}); err != errGitCoordinatorBusy {
		t.Fatalf("turn error = %v, want busy", err)
	}
	headJob := admit.waitForJob(t)
	close(headBarrier.release)
	admit.start(headJob)
	assertCoordinatorTerminal(t, headBarrier.terminal, requestRan)
}

func TestWorkspaceGitCoordinatorTurnCancelledWhileQueued(t *testing.T) {
	admit := &queueingAdmit{}
	coordinator := newWorkspaceGitCoordinator(admit.submit, gitCoordinatorPendingLimit, gitCoordinatorWorkspacePendingLimit, 4)
	headCtx, headCancel := context.WithCancel(context.Background())
	defer headCancel()
	head, headBarrier := newCoordinatorTestRequest(headCtx, "workspace")
	if !coordinator.submit(head) {
		t.Fatal("head was rejected")
	}
	headJob := admit.waitForJob(t)

	turnCtx, turnCancel := context.WithCancel(context.Background())
	turnDone := make(chan error, 1)
	go func() {
		turnDone <- coordinator.turn(turnCtx, "workspace", func(context.Context) {})
	}()
	waitForCoordinatorQueued(t, coordinator, "workspace", 1)
	turnCancel()
	select {
	case err := <-turnDone:
		if err == nil {
			t.Fatal("turn returned nil after cancellation")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("turn did not return after cancellation while queued")
	}

	close(headBarrier.release)
	admit.start(headJob)
	assertCoordinatorTerminal(t, headBarrier.terminal, requestRan)
}
