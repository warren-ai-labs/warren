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
	if len(r.frames) == 0 {
		return r.nextSequence
	}
	return r.frames[0].Sequence
}

// Upper is the sequence an attach pairs with its captured terminal state.
func (r *Ring) Upper() uint64 { return r.nextSequence }

func (r *Ring) Frames() []Frame {
	return append([]Frame(nil), r.frames...)
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
	// Evict before append so a full ring reuses its backing storage instead of
	// growing then allocating a replacement slice for every output frame.
	if len(r.frames) >= r.Capacity {
		r.discardOldest(len(r.frames) - r.Capacity + 1)
	}
	r.frames = append(r.frames, frame)
	r.nextSequence = sequence + uint64(len(payload))

	totalBytes := 0
	for _, value := range r.frames {
		totalBytes += len(value.Payload)
	}
	discard := 0
	for totalBytes > r.MaxBytes && discard < len(r.frames) {
		totalBytes -= len(r.frames[discard].Payload)
		discard++
	}
	r.discardOldest(discard)
	return frame, nil
}

func (r *Ring) discardOldest(count int) {
	if count <= 0 || len(r.frames) == 0 {
		return
	}
	if count >= len(r.frames) {
		clear(r.frames)
		r.frames = r.frames[:0]
		return
	}
	remaining := copy(r.frames, r.frames[count:])
	clear(r.frames[remaining:])
	r.frames = r.frames[:remaining]
}

func (r *Ring) Reset(epoch, nextSequence uint64) {
	r.Epoch = epoch
	r.frames = nil
	r.nextSequence = nextSequence
}
