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

// Reset moves the ring to a new epoch without carrying frames across it, so a
// stale sequence from the previous epoch can never be read as retained.
func TestRingResetDropsThePreviousEpoch(t *testing.T) {
	ring := NewRing(7, 256, 8*1024*1024, 0)
	for _, payload := range []string{"hello ", "world", "\r\n"} {
		if _, err := ring.Append("s", []byte(payload)); err != nil {
			t.Fatal(err)
		}
	}
	ring.Reset(8, 100)
	if ring.Epoch != 8 {
		t.Fatalf("epoch = %d, want 8", ring.Epoch)
	}
	if len(ring.Frames()) != 0 {
		t.Fatalf("retained frames = %d, want 0 after a reset", len(ring.Frames()))
	}
	if ring.Lower() != 100 || ring.Upper() != 100 {
		t.Fatalf("empty ring interval = [%d,%d], want [100,100]", ring.Lower(), ring.Upper())
	}
}
