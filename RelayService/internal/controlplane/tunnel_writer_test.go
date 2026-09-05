package controlplane

import (
	"strings"
	"testing"
	"time"
)

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

func TestTunnelFlowControlWakesAfterCreditReturns(t *testing.T) {
	id := connectionID{1}
	route := newClientRoute()
	route.windowMu.Lock()
	route.window = 0
	route.windowMu.Unlock()
	tunnel := &hostTunnel{
		clients: make(map[connectionID]*clientRoute),
		closed:  make(chan struct{}),
	}
	tunnel.clients[id] = route
	result := make(chan error, 1)
	go func() {
		result <- tunnel.sendStreamContext(nil, id, relayFrame{Kind: frameData, ConnectionID: id, Payload: []byte("x")})
	}()
	select {
	case err := <-result:
		t.Fatalf("flow-controlled send returned before credit: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	if !route.grant(1) {
		t.Fatal("window credit was rejected")
	}
	select {
	case err := <-result:
		if err == nil || !strings.Contains(err.Error(), "connection unavailable") {
			t.Fatalf("send after credit returned %v, want the missing-connection error", err)
		}
	case <-time.After(time.Second):
		t.Fatal("flow-controlled send did not wake after credit")
	}
}

func TestTunnelFlowControlStopsWhenRouteOrTunnelCloses(t *testing.T) {
	id := connectionID{2}
	route := newClientRoute()
	route.windowMu.Lock()
	route.window = 0
	route.windowMu.Unlock()
	tunnel := &hostTunnel{
		clients: map[connectionID]*clientRoute{id: route},
		closed:  make(chan struct{}),
	}
	result := make(chan error, 1)
	go func() {
		result <- tunnel.sendStreamContext(nil, id, relayFrame{Kind: frameData, ConnectionID: id, Payload: []byte("x")})
	}()
	route.close()
	select {
	case err := <-result:
		if err == nil || !strings.Contains(err.Error(), "stream closed") {
			t.Fatalf("closed route send returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("flow-controlled send did not stop after route closure")
	}

	// A route may remain registered while a Host socket is being torn down;
	// tunnel closure must wake the same wait without relying on a window update.
	route = newClientRoute()
	route.windowMu.Lock()
	route.window = 0
	route.windowMu.Unlock()
	tunnel.clientsMu.Lock()
	tunnel.clients[id] = route
	tunnel.clientsMu.Unlock()
	result = make(chan error, 1)
	go func() {
		result <- tunnel.sendStreamContext(nil, id, relayFrame{Kind: frameData, ConnectionID: id, Payload: []byte("x")})
	}()
	tunnel.close()
	select {
	case err := <-result:
		if err == nil || (!strings.Contains(err.Error(), "host tunnel closed") && !strings.Contains(err.Error(), "stream not found")) {
			t.Fatalf("closed tunnel send returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("flow-controlled send did not stop after tunnel closure")
	}
}
