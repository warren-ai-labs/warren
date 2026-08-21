package server

import (
	"context"
	"sync"
)

const (
	controlRequestQueueCapacity = 64
	auxiliaryRequestWorkerLimit = 4
	auxiliaryRequestCapacity    = 32
)

type requestLane uint8

const (
	requestControl requestLane = iota
	requestAuxiliary
)

func requestLaneFor(method string) requestLane {
	if method == "git.panel" {
		return requestAuxiliary
	}
	return requestControl
}

type requestTerminal uint8

const (
	requestRan requestTerminal = iota
	requestRejected
	requestCancelled
)

type requestJob struct {
	ctx      context.Context
	run      func(context.Context)
	terminal func(requestTerminal)
}

type executorState uint8

const (
	executorOpen executorState = iota
	executorStopping
	executorStopped
)

type serialExecutor struct {
	mu            sync.Mutex
	state         executorState
	queue         []requestJob
	queueCapacity int
	outstanding   int
	wake          chan struct{}
	done          chan struct{}
}

func newSerialExecutor(queueCapacity int) *serialExecutor {
	if queueCapacity < 1 {
		panic("serial executor queue capacity must be positive")
	}
	executor := &serialExecutor{
		queueCapacity: queueCapacity,
		wake:          make(chan struct{}, 1),
		done:          make(chan struct{}),
	}
	go executor.run()
	return executor
}

func (e *serialExecutor) submit(job requestJob) bool {
	e.mu.Lock()
	if e.state != executorOpen || len(e.queue) == e.queueCapacity {
		e.mu.Unlock()
		return false
	}
	e.queue = append(e.queue, job)
	e.outstanding++
	e.mu.Unlock()
	e.signal()
	return true
}

func (e *serialExecutor) stop() {
	e.mu.Lock()
	if e.state != executorOpen {
		e.mu.Unlock()
		return
	}
	e.state = executorStopping
	queued := e.queue
	e.queue = nil
	e.mu.Unlock()

	for _, job := range queued {
		e.finish(job, requestCancelled)
	}
	e.mu.Lock()
	e.markStoppedLocked()
	e.mu.Unlock()
	e.signal()
}

func (e *serialExecutor) wait(ctx context.Context) error {
	select {
	case <-e.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (e *serialExecutor) run() {
	for {
		e.mu.Lock()
		if e.state != executorOpen {
			e.mu.Unlock()
			return
		}
		if len(e.queue) == 0 {
			e.mu.Unlock()
			<-e.wake
			continue
		}
		job := e.queue[0]
		e.queue = e.queue[1:]
		e.mu.Unlock()

		ctx := job.ctx
		if ctx == nil {
			ctx = context.Background()
		}
		if ctx.Err() != nil {
			e.finish(job, requestCancelled)
			continue
		}
		if job.run != nil {
			job.run(ctx)
		}
		e.finish(job, requestRan)
	}
}

func (e *serialExecutor) finish(job requestJob, outcome requestTerminal) {
	if job.terminal != nil {
		job.terminal(outcome)
	}
	e.mu.Lock()
	e.outstanding--
	e.markStoppedLocked()
	e.mu.Unlock()
}

func (e *serialExecutor) markStoppedLocked() {
	if e.state == executorStopping && e.outstanding == 0 {
		e.state = executorStopped
		close(e.done)
	}
}

func (e *serialExecutor) signal() {
	select {
	case e.wake <- struct{}{}:
	default:
	}
}

type auxiliaryExecutor struct {
	mu            sync.Mutex
	state         executorState
	queue         []requestJob
	workerLimit   int
	capacityLimit int
	running       int
	capacityUsed  int
	outstanding   int
	wake          chan struct{}
	done          chan struct{}
}

func newAuxiliaryExecutor(workerLimit, capacityLimit int) *auxiliaryExecutor {
	if workerLimit < 1 {
		panic("auxiliary executor worker limit must be positive")
	}
	if capacityLimit < workerLimit {
		panic("auxiliary executor capacity must cover its workers")
	}
	executor := &auxiliaryExecutor{
		workerLimit:   workerLimit,
		capacityLimit: capacityLimit,
		wake:          make(chan struct{}, 1),
		done:          make(chan struct{}),
	}
	go executor.dispatch()
	return executor
}

func (e *auxiliaryExecutor) submit(job requestJob) bool {
	e.mu.Lock()
	if e.state != executorOpen || e.capacityUsed == e.capacityLimit {
		e.mu.Unlock()
		return false
	}
	e.queue = append(e.queue, job)
	e.capacityUsed++
	e.outstanding++
	e.mu.Unlock()
	e.signal()
	return true
}

func (e *auxiliaryExecutor) stop() {
	e.mu.Lock()
	if e.state != executorOpen {
		e.mu.Unlock()
		return
	}
	e.state = executorStopping
	queued := e.queue
	e.queue = nil
	e.capacityUsed -= len(queued)
	e.mu.Unlock()

	for _, job := range queued {
		e.publish(job, requestCancelled)
	}
	e.mu.Lock()
	e.markStoppedLocked()
	e.mu.Unlock()
	e.signal()
}

func (e *auxiliaryExecutor) wait(ctx context.Context) error {
	select {
	case <-e.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (e *auxiliaryExecutor) dispatch() {
	for {
		e.mu.Lock()
		if e.state != executorOpen {
			e.mu.Unlock()
			return
		}
		if len(e.queue) == 0 || e.running == e.workerLimit {
			e.mu.Unlock()
			<-e.wake
			continue
		}
		job := e.queue[0]
		e.queue = e.queue[1:]
		e.running++
		e.mu.Unlock()
		go e.execute(job)
	}
}

func (e *auxiliaryExecutor) execute(job requestJob) {
	ctx := job.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	outcome := requestCancelled
	if ctx.Err() == nil {
		if job.run != nil {
			job.run(ctx)
		}
		outcome = requestRan
	}

	e.mu.Lock()
	e.running--
	e.capacityUsed--
	e.mu.Unlock()
	e.signal()
	e.publish(job, outcome)
}

func (e *auxiliaryExecutor) publish(job requestJob, outcome requestTerminal) {
	if job.terminal != nil {
		job.terminal(outcome)
	}
	e.mu.Lock()
	e.outstanding--
	e.markStoppedLocked()
	e.mu.Unlock()
}

func (e *auxiliaryExecutor) markStoppedLocked() {
	if e.state == executorStopping && e.outstanding == 0 {
		e.state = executorStopped
		close(e.done)
	}
}

func (e *auxiliaryExecutor) signal() {
	select {
	case e.wake <- struct{}{}:
	default:
	}
}
