package server

import (
	"context"
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
		{method: "git.diff", want: requestAuxiliary},
		{method: "git.commit", want: requestAuxiliary},
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

func TestGitMethodsUseAuxiliary(t *testing.T) {
	methods := []string{
		"git.panel", "git.diff", "git.checkout",
		"git.pull", "git.push", "git.commit", "git.pr.create",
	}
	for _, method := range methods {
		if got := requestLaneFor(method); got != requestAuxiliary {
			t.Errorf("requestLaneFor(%q) = %d; want requestAuxiliary", method, got)
		}
		if !isCoordinatedGitMethod(method) {
			t.Errorf("isCoordinatedGitMethod(%q) = false; want true", method)
		}
	}
	for _, method := range []string{"session.attach", "session.input", "roster", "future.method"} {
		if isCoordinatedGitMethod(method) {
			t.Errorf("isCoordinatedGitMethod(%q) = true; want false", method)
		}
	}
}
