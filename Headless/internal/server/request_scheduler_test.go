package server

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRequestLaneDefaultsToControl(t *testing.T) {
	tests := []struct {
		method string
		want   requestLane
	}{
		{method: "git.panel", want: requestAuxiliary},
		{method: "git.diff", want: requestControl},
		{method: "git.commit", want: requestControl},
		{method: "future.method", want: requestControl},
	}
	for _, test := range tests {
		t.Run(test.method, func(t *testing.T) {
			if got := requestLaneFor(test.method); got != test.want {
				t.Fatalf("requestLaneFor(%q) = %d; want %d", test.method, got, test.want)
			}
		})
	}
}

func TestSerialExecutorRunsFIFO(t *testing.T) {
	executor := newSerialExecutor(2)
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	runs := make(chan int, 3)
	terminals := make(chan requestTerminal, 3)

	if !executor.submit(requestJob{
		ctx: context.Background(),
		run: func(context.Context) {
			close(firstStarted)
			<-releaseFirst
			runs <- 1
		},
		terminal: func(outcome requestTerminal) { terminals <- outcome },
	}) {
		t.Fatal("first job was rejected")
	}
	waitSignal(t, firstStarted, "first serial job to start")
	for id := 2; id <= 3; id++ {
		id := id
		if !executor.submit(requestJob{
			ctx:      context.Background(),
			run:      func(context.Context) { runs <- id },
			terminal: func(outcome requestTerminal) { terminals <- outcome },
		}) {
			t.Fatalf("job %d was rejected", id)
		}
	}
	close(releaseFirst)

	for want := 1; want <= 3; want++ {
		if got := waitValue(t, runs, "serial run"); got != want {
			t.Fatalf("run order = %d at position %d", got, want)
		}
		if got := waitValue(t, terminals, "serial terminal"); got != requestRan {
			t.Fatalf("terminal = %d; want requestRan", got)
		}
	}
	executor.stop()
	waitExecutor(t, executor.wait)
}

func TestSerialExecutorCancelsQueuedContext(t *testing.T) {
	executor := newSerialExecutor(1)
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	cancelledRan := make(chan struct{}, 1)
	cancelledTerminal := make(chan requestTerminal, 1)

	if !executor.submit(requestJob{
		ctx: context.Background(),
		run: func(context.Context) {
			close(firstStarted)
			<-releaseFirst
		},
		terminal: func(requestTerminal) {},
	}) {
		t.Fatal("first job was rejected")
	}
	waitSignal(t, firstStarted, "first serial job to start")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if !executor.submit(requestJob{
		ctx:      ctx,
		run:      func(context.Context) { cancelledRan <- struct{}{} },
		terminal: func(outcome requestTerminal) { cancelledTerminal <- outcome },
	}) {
		t.Fatal("cancelled queued job was rejected")
	}
	close(releaseFirst)

	if got := waitValue(t, cancelledTerminal, "cancelled terminal"); got != requestCancelled {
		t.Fatalf("terminal = %d; want requestCancelled", got)
	}
	select {
	case <-cancelledRan:
		t.Fatal("cancelled queued job ran")
	default:
	}
	executor.stop()
	waitExecutor(t, executor.wait)
}

func TestSerialExecutorStopRejectsLaterSubmissionsAndTerminatesAcceptedJobs(t *testing.T) {
	executor := newSerialExecutor(2)
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	var mu sync.Mutex
	outcomes := make(map[int][]requestTerminal)
	job := func(id int, run func(context.Context)) requestJob {
		return requestJob{
			ctx: context.Background(),
			run: run,
			terminal: func(outcome requestTerminal) {
				mu.Lock()
				outcomes[id] = append(outcomes[id], outcome)
				mu.Unlock()
			},
		}
	}
	if !executor.submit(job(1, func(context.Context) {
		close(firstStarted)
		<-releaseFirst
	})) {
		t.Fatal("first job was rejected")
	}
	waitSignal(t, firstStarted, "first serial job to start")
	if !executor.submit(job(2, func(context.Context) { t.Error("queued job 2 ran") })) {
		t.Fatal("queued job 2 was rejected")
	}
	if !executor.submit(job(3, func(context.Context) { t.Error("queued job 3 ran") })) {
		t.Fatal("queued job 3 was rejected")
	}

	executor.stop()
	if executor.submit(job(4, func(context.Context) {})) {
		t.Fatal("submission after stop was accepted")
	}
	close(releaseFirst)
	waitExecutor(t, executor.wait)

	mu.Lock()
	defer mu.Unlock()
	for id, want := range map[int]requestTerminal{
		1: requestRan,
		2: requestCancelled,
		3: requestCancelled,
	} {
		got := outcomes[id]
		if len(got) != 1 || got[0] != want {
			t.Errorf("job %d outcomes = %v; want [%d]", id, got, want)
		}
	}
	if got := outcomes[4]; len(got) != 0 {
		t.Errorf("rejected job outcomes = %v; want none", got)
	}
}

func TestSerialExecutorStopAdmissionRaceHasExactlyOneTerminalPerAcceptedJob(t *testing.T) {
	const iterations = 256
	for iteration := 0; iteration < iterations; iteration++ {
		executor := newSerialExecutor(1)
		start := make(chan struct{})
		accepted := make(chan bool, 1)
		terminals := make(chan requestTerminal, 2)
		var racers sync.WaitGroup
		racers.Add(2)
		go func() {
			defer racers.Done()
			<-start
			accepted <- executor.submit(requestJob{
				ctx:      context.Background(),
				run:      func(context.Context) {},
				terminal: func(outcome requestTerminal) { terminals <- outcome },
			})
		}()
		go func() {
			defer racers.Done()
			<-start
			executor.stop()
		}()
		close(start)
		racers.Wait()
		wasAccepted := <-accepted
		waitExecutor(t, executor.wait)

		count := len(terminals)
		if wasAccepted && count != 1 {
			t.Fatalf("iteration %d accepted with %d terminal outcomes", iteration, count)
		}
		if !wasAccepted && count != 0 {
			t.Fatalf("iteration %d rejected with %d terminal outcomes", iteration, count)
		}
		if count == 1 {
			outcome := <-terminals
			if outcome != requestRan && outcome != requestCancelled {
				t.Fatalf("iteration %d terminal = %d; want ran or cancelled", iteration, outcome)
			}
		}
	}
}

func TestAuxiliaryExecutorEnforcesRunningAndCapacityLimits(t *testing.T) {
	executor := newAuxiliaryExecutor(2, 3)
	started := make(chan int, 3)
	release := make(chan struct{})
	terminals := make(chan requestTerminal, 3)
	var running atomic.Int32
	var maximum atomic.Int32

	job := func(id int) requestJob {
		return requestJob{
			ctx: context.Background(),
			run: func(context.Context) {
				current := running.Add(1)
				for {
					observed := maximum.Load()
					if current <= observed || maximum.CompareAndSwap(observed, current) {
						break
					}
				}
				started <- id
				<-release
				running.Add(-1)
			},
			terminal: func(outcome requestTerminal) { terminals <- outcome },
		}
	}
	for id := 1; id <= 3; id++ {
		if !executor.submit(job(id)) {
			t.Fatalf("job %d was rejected", id)
		}
	}
	if executor.submit(job(4)) {
		t.Fatal("job beyond auxiliary capacity was accepted")
	}
	waitValue(t, started, "first auxiliary job to start")
	waitValue(t, started, "second auxiliary job to start")
	select {
	case id := <-started:
		t.Fatalf("job %d exceeded the auxiliary running limit", id)
	default:
	}
	close(release)
	for range 3 {
		if got := waitValue(t, terminals, "auxiliary terminal"); got != requestRan {
			t.Fatalf("terminal = %d; want requestRan", got)
		}
	}
	if got := len(terminals); got != 0 {
		t.Fatalf("rejected job received %d terminal outcomes", got)
	}
	if got := maximum.Load(); got != 2 {
		t.Fatalf("maximum running jobs = %d; want 2", got)
	}
	executor.stop()
	waitExecutor(t, executor.wait)
}

func TestAuxiliaryExecutorReleasesPermitsBeforeTerminal(t *testing.T) {
	executor := newAuxiliaryExecutor(1, 1)
	followupRan := make(chan struct{})
	followupTerminal := make(chan requestTerminal, 1)
	acceptedFromTerminal := make(chan bool, 1)

	if !executor.submit(requestJob{
		ctx: context.Background(),
		run: func(context.Context) {},
		terminal: func(requestTerminal) {
			accepted := executor.submit(requestJob{
				ctx: context.Background(),
				run: func(context.Context) {
					close(followupRan)
				},
				terminal: func(outcome requestTerminal) { followupTerminal <- outcome },
			})
			acceptedFromTerminal <- accepted
			if accepted {
				<-followupRan
			}
		},
	}) {
		t.Fatal("first job was rejected")
	}
	if !waitValue(t, acceptedFromTerminal, "terminal follow-up admission") {
		t.Fatal("terminal callback could not use released auxiliary capacity")
	}
	waitSignal(t, followupRan, "follow-up auxiliary job to run")
	if got := waitValue(t, followupTerminal, "follow-up terminal"); got != requestRan {
		t.Fatalf("terminal = %d; want requestRan", got)
	}
	executor.stop()
	waitExecutor(t, executor.wait)
}

func waitSignal(t *testing.T, signal <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func waitValue[T any](t *testing.T, values <-chan T, description string) T {
	t.Helper()
	select {
	case value := <-values:
		return value
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
		var zero T
		return zero
	}
}

func waitExecutor(t *testing.T, wait func(context.Context) error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := wait(ctx); err != nil {
		t.Fatalf("executor did not stop: %v", err)
	}
}
