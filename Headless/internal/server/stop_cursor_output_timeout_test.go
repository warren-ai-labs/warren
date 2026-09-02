package server

import (
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
)

// stalledCursorReader never returns from Read, simulating a ghostline server
// that stops answering output-read RPCs. Its Close is a no-op on the read
// side, so a join that waits for the reader goroutine to exit would block
// forever without a timeout.
type stalledCursorReader struct {
	closed chan struct{}
}

func newStalledCursorReader() *stalledCursorReader {
	return &stalledCursorReader{closed: make(chan struct{})}
}

func (r *stalledCursorReader) Read([]byte) (int, error) {
	<-r.closed // never closed by the test: Read blocks forever
	return 0, nil
}

func (r *stalledCursorReader) Close() error { return nil }
func (r *stalledCursorReader) Cursor() ghostline.Cursor {
	cursor, _ := ghostline.ParseCursor("v1:1:0")
	return cursor
}

// TestStopCursorOutputJoinBoundedByTimeout guards the rapid tab-switch stall:
// stopCursorOutput must not block forever behind a reader goroutine that does
// not observe Close (its Read is stuck in a ghostline RPC). The join is
// bounded so the next subscribe can proceed instead of leaving the pane black.
func TestStopCursorOutputJoinBoundedByTimeout(t *testing.T) {
	service := &Service{}
	stalled := newStalledCursorReader()
	done := make(chan struct{}) // never closed: reader goroutine never exits

	outputSession := &outputSession{
		sessionID:    "session-stall-test",
		reader:       stalled,
		readerDone:   done,
		readerCancel: func() {},
	}

	start := time.Now()
	// 300ms bound is enough to prove the select returns without waiting on
	// the never-closing done channel. 2s is used in production; 300ms keeps
	// the test fast while still catching a regression to an unbounded join
	// (which would hang until the test framework's own timeout).
	service.stopCursorOutputWithin(outputSession, 300*time.Millisecond, "test")
	elapsed := time.Since(start)
	if elapsed >= 2*time.Second {
		t.Fatalf("stopCursorOutputWithin blocked too long: %v", elapsed)
	}
	t.Logf("stopCursorOutputWithin returned after %v", elapsed)
}

// TestStopCursorOutputJoinCompletesWhenReaderExits verifies the fast path is
// unchanged: when the reader goroutine does exit, the join returns promptly
// and does not wait out the timeout.
func TestStopCursorOutputJoinCompletesWhenReaderExits(t *testing.T) {
	service := &Service{}
	stalled := newStalledCursorReader()
	done := make(chan struct{})
	close(done) // reader already exited

	outputSession := &outputSession{
		sessionID:    "session-fast-test",
		reader:       stalled,
		readerDone:   done,
		readerCancel: func() {},
	}

	start := time.Now()
	service.stopCursorOutputWithin(outputSession, 2*time.Second, "test")
	elapsed := time.Since(start)
	if elapsed >= 1*time.Second {
		t.Fatalf("stopCursorOutputWithin took too long on the fast path: %v", elapsed)
	}
}

// context import is used to keep parity with the surrounding helpers even if
// the stub above evolves; it is referenced by other tests in this package.
