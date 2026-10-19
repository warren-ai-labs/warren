package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

func TestOutputFlowStartsWithInitialWindow(t *testing.T) {
	flow := newOutputFlow(1, 100)
	now := time.Now()
	flow.recordSent(100+outputFlowInitialWindow-1, now)
	if !flow.hasRoom() {
		t.Fatal("window full before the initial budget was used")
	}
	flow.recordSent(100+outputFlowInitialWindow, now)
	if flow.hasRoom() {
		t.Fatal("window still open after the initial budget was used")
	}
	flow.recordAck(1, 100+1024, now.Add(time.Second))
	if !flow.hasRoom() {
		t.Fatal("an ack did not reopen the window")
	}
}

func TestOutputFlowIgnoresStaleAndImpossibleAcks(t *testing.T) {
	flow := newOutputFlow(3, 0)
	now := time.Now()
	flow.recordSent(1000, now)
	flow.recordAck(2, 500, now)
	flow.recordAck(3, 2000, now)
	if flow.acked != 0 {
		t.Fatalf("acked = %d after a wrong-epoch and a future ack", flow.acked)
	}
	flow.recordAck(3, 600, now)
	flow.recordAck(3, 400, now)
	if flow.acked != 600 {
		t.Fatalf("acked = %d, want 600", flow.acked)
	}
}

func TestOutputFlowWindowFollowsRateAndRoundTrip(t *testing.T) {
	flow := newOutputFlow(1, 0)
	start := time.Now()
	// 100 KiB/s over a 1s round trip: each ack arrives one second after its
	// bytes were sent.
	const rate = 100 * 1024
	for second := 0; second < 5; second++ {
		sentAt := start.Add(time.Duration(second) * time.Second)
		flow.recordSent(uint64((second+1)*rate), sentAt)
		flow.recordAck(1, uint64((second+1)*rate), sentAt.Add(time.Second))
	}
	want := uint64(outputFlowGain * rate * (time.Second + outputFlowQueueTarget).Seconds())
	if got := flow.window(); got < want*9/10 || got > want*11/10 {
		t.Fatalf("window = %d, want about %d", got, want)
	}
}

func TestOutputFlowWindowStaysWithinBounds(t *testing.T) {
	flow := newOutputFlow(1, 0)
	flow.minRTT = time.Millisecond
	flow.rate = 1
	if got := flow.window(); got != outputFlowMinWindow {
		t.Fatalf("slow link window = %d, want %d", got, outputFlowMinWindow)
	}
	flow.minRTT = time.Second
	flow.rate = 1 << 30
	if got := flow.window(); got != outputFlowMaxWindow {
		t.Fatalf("fast link window = %d, want %d", got, outputFlowMaxWindow)
	}
}

func TestOutputFlowWaitForRoomWakesOnAck(t *testing.T) {
	flow := newOutputFlow(1, 0)
	flow.recordSent(outputFlowInitialWindow, time.Now())
	go func() {
		time.Sleep(30 * time.Millisecond)
		flow.recordAck(1, outputFlowInitialWindow, time.Now())
	}()
	blocked, allowed, ok := flow.waitForRoom(context.Background())
	if !ok || blocked < 20*time.Millisecond {
		t.Fatalf("waitForRoom = %v, %v; want to block until the ack", blocked, ok)
	}
	if flow.shouldSkip(blocked, allowed, time.Now()) {
		t.Fatal("a short hold must not skip the backlog")
	}
	if !flow.shouldSkip(allowed, allowed, time.Now()) {
		t.Fatal("a long hold must skip the backlog")
	}
	flow.lastSkip = time.Now()
	if flow.shouldSkip(allowed, allowed, time.Now()) {
		t.Fatal("skips must be rate limited")
	}
}

// Waiting for an ack takes a round trip, so a healthy client on a link slower
// than one second must not be treated as fallen behind.
func TestOutputFlowSkipAllowanceFollowsRoundTrip(t *testing.T) {
	flow := newOutputFlow(1, 0)
	if got := flow.skipAfter(); got != outputFlowSkipAfter+2*outputFlowUnmeasuredRTT {
		t.Fatalf("unmeasured allowance = %v", got)
	}
	flow.minRTT = 1500 * time.Millisecond
	if got := flow.skipAfter(); got != outputFlowSkipAfter+3*time.Second {
		t.Fatalf("allowance at a 1.5s round trip = %v", got)
	}
}

// The ack that ends a long hold measures the hold as its round trip. The
// allowance must be the one in force when the hold began.
func TestOutputFlowLongHoldIsNotExcusedByItsOwnAck(t *testing.T) {
	flow := newOutputFlow(1, 0)
	flow.minRTT = 10 * time.Millisecond
	flow.rttAt = time.Now()
	flow.recordSent(outputFlowInitialWindow, time.Now().Add(-time.Minute))
	go func() {
		time.Sleep(30 * time.Millisecond)
		flow.mu.Lock()
		flow.rttAt = time.Time{}
		flow.mu.Unlock()
		flow.recordAck(1, outputFlowInitialWindow, time.Now())
	}()
	blocked, allowed, ok := flow.waitForRoom(context.Background())
	if !ok || allowed != outputFlowSkipAfter+20*time.Millisecond {
		t.Fatalf("waitForRoom = %v, %v, %v", blocked, allowed, ok)
	}
	if flow.skipAfter() <= allowed {
		t.Fatal("the closing ack should have raised the measured round trip")
	}
}

// Host re-anchoring must yield to a client subscribe already in flight.
func TestIdlePendingSubscriptionYieldsToClientSubscribe(t *testing.T) {
	peer := &wsPeer{}
	_, finishClient := peer.beginPendingSubscription(context.Background(), "s")
	if _, _, ok := peer.beginIdlePendingSubscription(context.Background(), "s"); ok {
		t.Fatal("re-anchor started while a client subscribe was pending")
	}
	finishClient()
	ctx, finish, ok := peer.beginIdlePendingSubscription(context.Background(), "s")
	if !ok {
		t.Fatal("re-anchor refused with no subscribe pending")
	}
	// A later client subscribe still takes precedence over the re-anchor.
	done := make(chan struct{})
	go func() {
		_, finishLater := peer.beginPendingSubscription(context.Background(), "s")
		finishLater()
		close(done)
	}()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("client subscribe did not cancel the re-anchor")
	}
	finish()
	<-done
}

func peerFlow(t *testing.T, service *Service, sessionID string) *outputFlow {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		service.outputMu.Lock()
		for _, streams := range service.peerOutputs {
			if stream := streams[sessionID]; stream != nil && stream.flow != nil {
				service.outputMu.Unlock()
				return stream.flow
			}
		}
		service.outputMu.Unlock()
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("no flow-controlled subscription")
	return nil
}

func flowState(flow *outputFlow) (epoch, sent, acked uint64) {
	flow.mu.Lock()
	defer flow.mu.Unlock()
	return flow.epoch, flow.sent, flow.acked
}

func sendOutputAck(t *testing.T, connection *websocket.Conn, sessionID string, epoch, sequence uint64) {
	t.Helper()
	if err := connection.WriteJSON(api.Envelope{Type: "request", Method: "session.ack", Params: map[string]any{
		"id": sessionID, "epoch": epoch, "sequence": sequence,
	}}); err != nil {
		t.Fatal(err)
	}
}

func TestOutputAckBoundsUnacknowledgedOutput(t *testing.T) {
	const sessionID = "flow-bounded"
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	connection := openAuthenticatedConnectionWithCapabilities(t, httpServer.URL, "/v1/ws", []string{api.CapabilityOutputAck})
	defer connection.Close()
	anchor := subscribeForSeed(t, connection, sessionID)
	flow := peerFlow(t, service, sessionID)

	chunk := strings.Repeat("x", 32*1024)
	for written := 0; written < 3*outputFlowInitialWindow; written += len(chunk) {
		writeMemoryOutput(t, runtime, sessionID, chunk)
	}
	time.Sleep(200 * time.Millisecond)
	epoch, sent, _ := flowState(flow)
	inFlight := sent - anchor.Sequence
	if inFlight < outputFlowInitialWindow || inFlight > outputFlowInitialWindow+64*1024 {
		t.Fatalf("in flight without acks = %d, want about %d", inFlight, outputFlowInitialWindow)
	}

	sendOutputAck(t, connection, sessionID, epoch, sent)
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, next, acked := flowState(flow); acked == sent && next > sent {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("an ack did not let the reader continue")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestOutputAckSkipsBacklogWithFreshState(t *testing.T) {
	const sessionID = "flow-skip"
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	connection := openAuthenticatedConnectionWithCapabilities(t, httpServer.URL, "/v1/ws", []string{api.CapabilityOutputAck})
	defer connection.Close()
	subscribeForSeed(t, connection, sessionID)
	flow := peerFlow(t, service, sessionID)

	chunk := strings.Repeat("y", 32*1024)
	total := 0
	for total < 2*outputFlowInitialWindow {
		writeMemoryOutput(t, runtime, sessionID, chunk)
		total += len(chunk)
	}
	writeMemoryOutput(t, runtime, sessionID, "tail")
	total += len("tail")
	time.Sleep(flow.skipAfter() + 100*time.Millisecond)
	epoch, sent, _ := flowState(flow)
	sendOutputAck(t, connection, sessionID, epoch, sent)

	// The held-back reader is replaced by a fresh state at the current end of
	// output, on the same connection.
	deadline := time.Now().Add(3 * time.Second)
	_ = connection.SetReadDeadline(deadline)
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("no reanchor after the backlog was skipped: %v", err)
		}
		if kind != websocket.TextMessage {
			continue
		}
		var message map[string]any
		if json.Unmarshal(data, &message) != nil || message["t"] != "synced" {
			continue
		}
		if got := uint64(message["sequence"].(float64)); got >= uint64(total) {
			break
		}
	}
	replacement := peerFlow(t, service, sessionID)
	if replacement == flow {
		t.Fatal("the held-back reader was not replaced")
	}
	if _, sent, _ := flowState(replacement); sent < uint64(total) {
		t.Fatalf("replacement starts at %d, want the end of output %d", sent, total)
	}
}
