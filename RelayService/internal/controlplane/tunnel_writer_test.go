package controlplane

import "testing"

func TestTunnelWriterReservesControlLane(t *testing.T) {
	writer := &tunnelWriter{
		control: make(chan tunnelQueuedWrite, tunnelControlQueueCapacity),
		data:    make(chan tunnelQueuedWrite, tunnelDataQueueCapacity),
		stop:    make(chan struct{}),
		stopped: make(chan struct{}),
	}
	for index := 0; index < tunnelDataQueueCapacity; index++ {
		if err := writer.enqueue(tunnelQueuedWrite{done: make(chan error, 1)}, false); err != nil {
			t.Fatalf("data enqueue %d: %v", index, err)
		}
	}
	if err := writer.enqueue(tunnelQueuedWrite{done: make(chan error, 1)}, false); err == nil {
		t.Fatal("data queue accepted an item beyond its bound")
	}
	if err := writer.enqueue(tunnelQueuedWrite{done: make(chan error, 1)}, true); err != nil {
		t.Fatalf("control lane was starved by data: %v", err)
	}
	writer.stopWith(nil)
}

func TestControlRouteFramesDoNotWaitForBodyCredit(t *testing.T) {
	control := &clientRoute{}
	if routeFrameNeedsCredit(control, frameText) {
		t.Fatal("control text frame was classified as body traffic")
	}
	if routeFrameNeedsCredit(control, frameBinary) {
		t.Fatal("control binary frame was classified as body traffic")
	}
	if !routeFrameNeedsCredit(control, frameData) {
		t.Fatal("control DATA frame lost flow control")
	}
	public := &clientRoute{public: true}
	if !routeFrameNeedsCredit(public, frameText) {
		t.Fatal("public stream bypassed flow control")
	}
}
