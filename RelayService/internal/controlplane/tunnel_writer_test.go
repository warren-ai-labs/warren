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

func TestClientRouteRejectsWindowOverCredit(t *testing.T) {
	route := newClientRoute()
	if consumed, _ := route.tryConsume(8); !consumed {
		t.Fatal("failed to consume initial stream credit")
	}
	if !route.grant(8) {
		t.Fatal("valid window credit was rejected")
	}
	if route.grant(1) {
		t.Fatal("window over-credit was accepted")
	}
	route.windowMu.Lock()
	window := route.window
	route.windowMu.Unlock()
	if window != initialStreamWindow {
		t.Fatalf("over-credit changed window to %d, want %d", window, initialStreamWindow)
	}
	if !route.grant(0) {
		t.Fatal("zero window credit should be a no-op")
	}
}
