package output

import (
	"fmt"
)

// Anchor identifies the next byte a client needs within one epoch.
type Anchor struct {
	Epoch    uint64 `json:"epoch"`
	Sequence uint64 `json:"sequence"`
}

// Frame is one sequenced PTY output chunk. PayloadLength is derived from the
// payload; the wire codec keeps it explicit in the header.
type Frame struct {
	SessionID string
	Epoch     uint64
	Sequence  uint64
	Payload   []byte
}

// Ring is the bounded in-memory broadcast buffer for one Session's output. It
// exists to hand live bytes to already-attached peers and to name the sequence
// boundary an attach pairs with its terminal state; it is not the recovery
// store. Recovery reads Ghostline's durable history from an opaque cursor, and
// only a state capture produces that cursor, so a reconnecting client cannot be
// served from these frames.
//
// Sequence values are byte positions since the epoch start, matching the
// Ghostline output stream.
type Ring struct {
	Capacity     int
	MaxBytes     int
	Epoch        uint64
	frames       []Frame
	head         int
	count        int
	totalBytes   int
	nextSequence uint64
}

func NewRing(epoch uint64, capacity, maxBytes int, nextSequence uint64) *Ring {
	if capacity <= 0 {
		capacity = 256
	}
	if maxBytes <= 0 {
		maxBytes = 8 * 1024 * 1024
	}
	return &Ring{Capacity: capacity, MaxBytes: maxBytes, Epoch: epoch, nextSequence: nextSequence}
}

// Lower is the oldest retained sequence. It bounds eviction accounting and is
// not an attach position: an anchor inside this interval still cannot be served
// from the ring.
func (r *Ring) Lower() uint64 {
	if r.count == 0 {
		return r.nextSequence
	}
	return r.frames[r.head].Sequence
}

// Upper is the sequence an attach pairs with its captured terminal state.
func (r *Ring) Upper() uint64 { return r.nextSequence }

func (r *Ring) Frames() []Frame {
	if r.count == 0 {
		return nil
	}
	out := make([]Frame, r.count)
	first := min(r.count, len(r.frames)-r.head)
	copy(out, r.frames[r.head:r.head+first])
	if first < r.count {
		copy(out[first:], r.frames[:r.count-first])
	}
	return out
}

// Append records one frame, evicting the oldest frames to keep both the frame
// count and the retained byte total bounded.
func (r *Ring) Append(sessionID string, payload []byte) (Frame, error) {
	if len(payload) == 0 {
		return Frame{}, fmt.Errorf("output ring rejects an empty payload")
	}
	sequence := r.nextSequence
	if uint64(len(payload)) > ^uint64(0)-sequence {
		return Frame{}, fmt.Errorf("output sequence overflow")
	}
	frame := Frame{
		SessionID: sessionID,
		Epoch:     r.Epoch,
		Sequence:  sequence,
		Payload:   append([]byte(nil), payload...),
	}
	if len(r.frames) < r.Capacity {
		r.frames = make([]Frame, r.Capacity)
	}
	if r.count >= r.Capacity {
		r.discardOldest(r.count - r.Capacity + 1)
	}
	tail := (r.head + r.count) % r.Capacity
	r.frames[tail] = frame
	r.count++
	r.totalBytes += len(frame.Payload)
	r.nextSequence = sequence + uint64(len(payload))

	for r.totalBytes > r.MaxBytes && r.count > 0 {
		r.discardOldest(1)
	}
	return frame, nil
}

func (r *Ring) discardOldest(n int) {
	if n <= 0 || r.count == 0 {
		return
	}
	if n >= r.count {
		clear(r.frames)
		r.head = 0
		r.count = 0
		r.totalBytes = 0
		return
	}
	for range n {
		r.totalBytes -= len(r.frames[r.head].Payload)
		r.frames[r.head] = Frame{}
		r.head = (r.head + 1) % len(r.frames)
	}
	r.count -= n
}

func (r *Ring) Reset(epoch, nextSequence uint64) {
	r.Epoch = epoch
	clear(r.frames)
	r.frames = nil
	r.head = 0
	r.count = 0
	r.totalBytes = 0
	r.nextSequence = nextSequence
}
