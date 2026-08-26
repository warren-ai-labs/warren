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

// Anchor returns the next byte position after this frame.
func (f Frame) Anchor() Anchor {
	return Anchor{Epoch: f.Epoch, Sequence: f.Sequence + uint64(len(f.Payload))}
}

// Plan is the recovery strategy for a reconnecting client.
type Plan int

const (
	PlanExact    Plan = iota // anchor equals the ring upper bound
	PlanTail                 // anchor is inside the retained interval
	PlanReanchor             // no anchor, wrong epoch, or anchor evicted
)

// Recovery is the bounded reply Host sends on attach.
type Recovery struct {
	Plan     Plan
	Epoch    uint64
	Lower    uint64
	Upper    uint64
	Frames   []Frame
	Reanchor bool
}

func (r Recovery) Anchor() Anchor {
	return Anchor{Epoch: r.Epoch, Sequence: r.Upper}
}

// Ring is a bounded sequence interval retained by Host for reconnecting
// clients. Sequence values are byte positions since the epoch start, matching
// the Ghostline output stream and the Swift Host OutputRing semantics.
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

func (r *Ring) Lower() uint64 {
	if len(r.frames) == 0 {
		return r.nextSequence
	}
	return r.frames[0].Sequence
}

func (r *Ring) Upper() uint64 { return r.nextSequence }

func (r *Ring) Anchor() Anchor {
	return Anchor{Epoch: r.Epoch, Sequence: r.nextSequence}
}

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

func (r *Ring) Plan(anchor *Anchor) Plan {
	if anchor == nil || anchor.Epoch != r.Epoch || r.nextSequence < r.Lower() {
		return PlanReanchor
	}
	if anchor.Sequence == r.nextSequence {
		return PlanExact
	}
	if anchor.Sequence >= r.Lower() && anchor.Sequence < r.nextSequence {
		return PlanTail
	}
	return PlanReanchor
}

// Recovery returns the frames needed by a client. For a tail the first frame
// is trimmed so its header starts exactly at the requested byte; for reanchor
// the entire retained interval is returned and callers decide whether to send
// a full screen snapshot instead.
func (r *Ring) Recovery(anchor *Anchor) Recovery {
	plan := r.Plan(anchor)
	recovery := Recovery{
		Plan:     plan,
		Epoch:    r.Epoch,
		Lower:    r.Lower(),
		Upper:    r.nextSequence,
		Reanchor: plan == PlanReanchor,
	}
	if plan == PlanTail && anchor != nil {
		for _, frame := range r.frames {
			frameStart := frame.Sequence
			frameEnd := frame.Anchor().Sequence
			if frameEnd <= anchor.Sequence {
				continue
			}
			if frameStart < anchor.Sequence {
				offset := int(anchor.Sequence - frameStart)
				frame.Payload = append([]byte(nil), frame.Payload[offset:]...)
				frame.Sequence = anchor.Sequence
			}
			recovery.Frames = append(recovery.Frames, frame)
		}
		return recovery
	}
	if plan == PlanReanchor {
		recovery.Frames = r.Frames()
		return recovery
	}
	return recovery
}

func (r *Ring) Reset(epoch, nextSequence uint64) {
	r.Epoch = epoch
	r.frames = nil
	r.nextSequence = nextSequence
}
