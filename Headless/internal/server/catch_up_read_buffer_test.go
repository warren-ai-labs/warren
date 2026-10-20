package server

import (
	"testing"

	"github.com/abcdlsj/ghostline"
)

// The catch-up read must never pass the checkpoint cursor: bytes after it
// belong to the live stream, and recording them here would duplicate them in
// the pane. Sizing the read from the reported span is what makes one batch
// possible without that risk.
func TestCatchUpReadBufferSizesTheReadToTheReportedSpan(t *testing.T) {
	buffer := make([]byte, catchUpBatchBytes)

	// 2842 bytes was the measured gap that cost 2842 round trips and 1.4s.
	got, closed, known := catchUpReadBuffer(buffer, testCursor(100), testCursor(100+2842))
	if !known {
		t.Fatal("a forward span must be comparable")
	}
	if closed {
		t.Fatal("a forward span must not report the gap as closed")
	}
	if len(got) != 2842 {
		t.Fatalf("read buffer = %d bytes, want the 2842-byte span", len(got))
	}

	// A span larger than the buffer is capped by the buffer.
	got, closed, known = catchUpReadBuffer(buffer, testCursor(0), testCursor(10*catchUpBatchBytes))
	if !known || closed || len(got) != catchUpBatchBytes {
		t.Fatalf("large span read buffer = %d (closed=%v known=%v), want %d", len(got), closed, known, catchUpBatchBytes)
	}

	// A covered gap closes the loop before another read.
	got, closed, known = catchUpReadBuffer(buffer, testCursor(7), testCursor(7))
	if !known || !closed || got != nil {
		t.Fatalf("covered gap = %d bytes (closed=%v known=%v), want closed with no buffer", len(got), closed, known)
	}
}

// An incomparable pair cannot be walked: the caller must treat it as an
// unrecoverable gap and re-anchor instead of reading it one byte per round
// trip, which used to burn the whole command timeout and fail the attach after
// it had already been acknowledged.
func TestCatchUpReadBufferReportsAnUncomparableSpanInsteadOfOneByteAtATime(t *testing.T) {
	buffer := make([]byte, catchUpBatchBytes)

	otherGeneration, err := ghostline.ParseCursor("v1:2:5")
	if err != nil {
		t.Fatalf("parse generation cursor: %v", err)
	}
	cases := map[string]struct {
		from ghostline.Cursor
		to   ghostline.Cursor
	}{
		"zero origin":       {ghostline.Cursor{}, testCursor(10)},
		"zero target":       {testCursor(10), ghostline.Cursor{}},
		"reversed pair":     {testCursor(10), testCursor(4)},
		"generation change": {testCursor(10), otherGeneration},
	}
	for name, tc := range cases {
		got, closed, known := catchUpReadBuffer(buffer, tc.from, tc.to)
		if known {
			t.Fatalf("%s: incomparable span reported as comparable", name)
		}
		if closed || got != nil {
			t.Fatalf("%s: read buffer = %d bytes (closed=%v), want no read", name, len(got), closed)
		}
	}
}
