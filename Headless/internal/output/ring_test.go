package output

import "testing"

func TestRingAppendEvictsByCountAndBytes(t *testing.T) {
	ring := NewRing(0, 4, 12, 0)
	for _, payload := range []string{"a", "bb", "ccc", "dddd", "eeeee"} {
		if _, err := ring.Append("s", []byte(payload)); err != nil {
			t.Fatal(err)
		}
	}
	if ring.Lower() != 3 {
		t.Fatalf("lower sequence = %d, want 3 (oldest two frames evicted)", ring.Lower())
	}
	if ring.Upper() != 15 {
		t.Fatalf("upper sequence = %d, want 15", ring.Upper())
	}
	if len(ring.Frames()) != 3 {
		t.Fatalf("retained frames = %d, want 3", len(ring.Frames()))
	}
}

func TestRingAppendReusesFrameStorageAfterCountEviction(t *testing.T) {
	ring := NewRing(0, 2, 1024, 0)
	for _, payload := range []string{"one", "two"} {
		if _, err := ring.Append("s", []byte(payload)); err != nil {
			t.Fatal(err)
		}
	}
	capacity := cap(ring.frames)
	if _, err := ring.Append("s", []byte("three")); err != nil {
		t.Fatal(err)
	}
	if got := cap(ring.frames); got != capacity {
		t.Fatalf("frame capacity = %d, want retained capacity %d", got, capacity)
	}
	frames := ring.Frames()
	if len(frames) != 2 || string(frames[0].Payload) != "two" || string(frames[1].Payload) != "three" {
		t.Fatalf("retained frames = %#v, want two and three", frames)
	}
}

func TestRingRecoveryPlans(t *testing.T) {
	ring := NewRing(7, 256, 8*1024*1024, 0)
	for _, payload := range []string{"hello ", "world", "\r\n"} {
		_, _ = ring.Append("s", []byte(payload))
	}
	if plan := ring.Plan(nil); plan != PlanReanchor {
		t.Fatalf("nil anchor plan = %v, want reanchor", plan)
	}
	if plan := ring.Plan(&Anchor{Epoch: 6, Sequence: 0}); plan != PlanReanchor {
		t.Fatalf("wrong epoch plan = %v, want reanchor", plan)
	}
	if plan := ring.Plan(&Anchor{Epoch: 7, Sequence: ring.Upper()}); plan != PlanExact {
		t.Fatalf("upper anchor plan = %v, want exact", plan)
	}
	if plan := ring.Plan(&Anchor{Epoch: 7, Sequence: 4}); plan != PlanTail {
		t.Fatalf("inner anchor plan = %v, want tail", plan)
	}
	if plan := ring.Plan(&Anchor{Epoch: 7, Sequence: 99}); plan != PlanReanchor {
		t.Fatalf("evicted anchor plan = %v, want reanchor", plan)
	}
}

func TestRingRecoveryTrimsTailToAnchor(t *testing.T) {
	ring := NewRing(0, 256, 8*1024*1024, 0)
	_, _ = ring.Append("s", []byte("abcdef"))
	_, _ = ring.Append("s", []byte("ghij"))
	recovery := ring.Recovery(&Anchor{Epoch: 0, Sequence: 2})
	if recovery.Plan != PlanTail {
		t.Fatalf("plan = %v, want tail", recovery.Plan)
	}
	if len(recovery.Frames) != 2 {
		t.Fatalf("frames = %d, want 2", len(recovery.Frames))
	}
	if recovery.Frames[0].Sequence != 2 || string(recovery.Frames[0].Payload) != "cdef" {
		t.Fatalf("first trimmed frame = %#v", recovery.Frames[0])
	}
	if recovery.Frames[1].Sequence != 6 || string(recovery.Frames[1].Payload) != "ghij" {
		t.Fatalf("second frame = %#v", recovery.Frames[1])
	}
}
