package server

import (
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRelayPeerEnqueueDoesNotWaitForTransport(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	peer := newRelayPeer(&HTTPServer{Service: &Service{}}, func(outboundMessage) bool {
		select {
		case <-started:
		default:
			close(started)
		}
		<-release
		return true
	})

	start := time.Now()
	if !peer.enqueue(outboundMessage{kind: 1, data: []byte("control")}) {
		t.Fatal("Relay peer rejected the first queued message")
	}
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Fatalf("enqueue waited for transport: %s", elapsed)
	}

	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("Relay peer writer did not start")
	}
	peer.close()
	close(release)
}

func TestPeerWriterReservesControlLaneWhenOutputIsFull(t *testing.T) {
	peer := &wsPeer{
		server:          &HTTPServer{Service: &Service{}},
		outbound:        make(chan outboundMessage, outboundQueueCapacity),
		controlOutbound: make(chan outboundMessage, outboundControlQueueCapacity),
		closed:          make(chan struct{}),
	}
	for index := 0; index < outboundQueueCapacity; index++ {
		peer.outbound <- outboundMessage{kind: websocket.BinaryMessage, data: []byte("output")}
	}
	if !peer.enqueue(outboundMessage{kind: websocket.TextMessage, data: []byte("pong")}) {
		t.Fatal("control message was rejected while output lane was full")
	}
	if got := len(peer.controlOutbound); got != 1 {
		t.Fatalf("control queue length = %d, want 1", got)
	}
	if got := len(peer.outbound); got != outboundQueueCapacity {
		t.Fatalf("output queue length = %d, want %d", got, outboundQueueCapacity)
	}
}

func TestPeerWriterFairnessPreventsOutputStarvation(t *testing.T) {
	peer := &wsPeer{
		outbound:        make(chan outboundMessage, outboundQueueCapacity),
		controlOutbound: make(chan outboundMessage, outboundControlQueueCapacity),
	}
	for index := 0; index < outboundControlFairness+1; index++ {
		peer.controlOutbound <- outboundMessage{kind: websocket.TextMessage, data: []byte("control")}
	}
	peer.outbound <- outboundMessage{kind: websocket.BinaryMessage, data: []byte("output")}

	controlBurst := 0
	for index := 0; index < outboundControlFairness; index++ {
		item, ok := peer.nextOutbound(&controlBurst)
		if !ok || item.kind != websocket.TextMessage {
			t.Fatalf("message %d = %#v, ok=%v; want control", index, item, ok)
		}
	}
	item, ok := peer.nextOutbound(&controlBurst)
	if !ok || item.kind != websocket.BinaryMessage {
		t.Fatalf("fairness message = %#v, ok=%v; want output after %d controls", item, ok, outboundControlFairness)
	}
}

func TestAtomicRecoveryUsesControlLane(t *testing.T) {
	peer := &wsPeer{
		server:          &HTTPServer{Service: &Service{}},
		outbound:        make(chan outboundMessage, outboundQueueCapacity),
		controlOutbound: make(chan outboundMessage, outboundControlQueueCapacity),
		closed:          make(chan struct{}),
	}
	if err := peer.enqueueAtomicState("session", 1, 2, "ghostline-vt-replay-v1", []byte("state")); err != nil {
		t.Fatal(err)
	}
	if got := len(peer.controlOutbound); got != 1 {
		t.Fatalf("control queue length = %d, want 1", got)
	}
	if got := len(peer.outbound); got != 0 {
		t.Fatalf("output queue length = %d, want 0", got)
	}
}
