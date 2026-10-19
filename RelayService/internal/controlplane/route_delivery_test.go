package controlplane

import (
	"bytes"
	"testing"
	"time"
)

// TestRouteDeliversABurstLargerThanItsHandoffBuffer covers the shape that broke
// public asset responses: the Host frames whatever sizes its handler writes, so
// a single compressed asset arrives as hundreds of small frames. Every one of
// them belongs to the response body, so the consumer must receive all of them in
// order; losing one, or tearing the route down because its buffer was counted in
// frames, truncates a response the Client cannot tell from a complete one.
func TestRouteDeliversABurstLargerThanItsHandoffBuffer(t *testing.T) {
	route := newRoute(true)
	go route.drain()
	const frames = 500
	for index := 0; index < frames; index++ {
		frame := relayFrame{Kind: frameData, Payload: bytes.Repeat([]byte{byte(index)}, 246)}
		if !route.reserve(frame) {
			t.Fatalf("frame %d was refused inside the flow-control window", index)
		}
		route.enqueue(frame)
	}
	for index := 0; index < frames; index++ {
		select {
		case frame := <-route.frames:
			if len(frame.Payload) != 246 || frame.Payload[0] != byte(index) {
				t.Fatalf("frame %d arrived out of order or corrupt: %d bytes starting %d",
					index, len(frame.Payload), frame.Payload[0])
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("only %d of %d frames were delivered", index, frames)
		}
	}
	route.close()
}

// TestRouteBoundsItsBufferInBytesNotFrames pins the bound to the unit the Host's
// flow control uses. A peer that respects its window must never be refused, and
// one that exceeds it still must be, or the queue stops being a bound at all.
func TestRouteBoundsItsBufferInBytesNotFrames(t *testing.T) {
	route := newRoute(true)
	payload := make([]byte, 1024)
	accepted := 0
	for route.reserve(relayFrame{Kind: frameData, Payload: payload}) {
		accepted++
		if accepted > int(initialStreamWindow/1024)+1 {
			t.Fatalf("route accepted more than one window: %d frames", accepted)
		}
	}
	if want := int(initialStreamWindow / 1024); accepted != want {
		t.Fatalf("accepted %d KB before refusing, want one window of %d KB", accepted, want)
	}
	if accepted <= routeHandoffFrames {
		t.Fatalf("the bound is not larger than the handoff buffer: %d frames", accepted)
	}
}

// TestRouteReleasesItsBufferAsFramesAreDelivered keeps the reservation tied to
// what is still waiting, so a long response cannot exhaust a route's window one
// frame at a time.
func TestRouteReleasesItsBufferAsFramesAreDelivered(t *testing.T) {
	route := newRoute(true)
	go route.drain()
	payload := make([]byte, 4096)
	reserved := 0
	for index := 0; index < 32; index++ {
		frame := relayFrame{Kind: frameData, Payload: payload}
		if !route.reserve(frame) {
			t.Fatalf("frame %d was refused inside the flow-control window", index)
		}
		reserved += len(payload)
		route.enqueue(frame)
	}
	for index := 0; index < 32; index++ {
		select {
		case <-route.frames:
		case <-time.After(5 * time.Second):
			t.Fatalf("only %d frames were delivered", index)
		}
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		route.pendingMu.Lock()
		queued := route.queuedBytes
		route.pendingMu.Unlock()
		if queued == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("queuedBytes = %d after every frame was delivered, want 0", queued)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if reserved == 0 {
		t.Fatal("test reserved nothing")
	}
	route.close()
}
