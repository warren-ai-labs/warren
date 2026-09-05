package server

import (
	"testing"
	"time"
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
