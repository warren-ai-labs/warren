package server

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

// newFocusTestPeer builds a registered peer with its own outbound lanes so the
// control events it receives can be read back without a socket.
func newFocusTestPeer(t *testing.T, service *Service, sessionID string) *wsPeer {
	t.Helper()
	peer := &wsPeer{
		server:          &HTTPServer{Service: service},
		outbound:        make(chan outboundMessage, outboundQueueCapacity),
		controlOutbound: make(chan outboundMessage, outboundControlQueueCapacity),
		closed:          make(chan struct{}),
	}
	service.registerPeer(sessionID, peer)
	peer.ensureAttachment(sessionID)
	return peer
}

// nextFocusEvent reads the next control message and returns it decoded.
func nextFocusEvent(t *testing.T, peer *wsPeer) map[string]any {
	t.Helper()
	select {
	case item := <-peer.controlOutbound:
		var value map[string]any
		if err := json.Unmarshal(item.data, &value); err != nil {
			t.Fatalf("decode control event %q: %v", item.data, err)
		}
		return value
	case <-time.After(time.Second):
		t.Fatal("no control event was sent")
		return nil
	}
}

// noFocusEvent asserts that nothing else was sent to a peer.
func noFocusEvent(t *testing.T, peer *wsPeer) {
	t.Helper()
	select {
	case item := <-peer.controlOutbound:
		t.Fatalf("unexpected control event %q", item.data)
	case <-time.After(50 * time.Millisecond):
	}
}

func focusTestSession(sessionID string) api.Session {
	return api.Session{ID: sessionID, Runtime: "ghostline", RuntimeKind: "ghostline", Lifecycle: "running"}
}

// A later claim still wins while its peer is connected, but the peer that lost
// the lease has to be told: its own idea of the keyboard owner is now stale and
// input it sends would be refused.
func TestFocusLeaseTransferNotifiesTheDisplacedPeer(t *testing.T) {
	const sessionID = "session-focus-transfer"
	service := &Service{}
	service.lazyInit()
	session := focusTestSession(sessionID)
	first := newFocusTestPeer(t, service, sessionID)
	second := newFocusTestPeer(t, service, sessionID)

	if focused, _, err := service.focusPeer(context.Background(), first, session, true, 80, 24, false, false); err != nil || !focused {
		t.Fatalf("first claim = (%v, %v), want the lease", focused, err)
	}
	noFocusEvent(t, first)

	if focused, _, err := service.focusPeer(context.Background(), second, session, true, 80, 24, false, false); err != nil || !focused {
		t.Fatalf("second claim = (%v, %v), want the lease", focused, err)
	}
	if !service.isFocused(second, sessionID) {
		t.Fatal("the later claimant does not hold the lease")
	}
	event := nextFocusEvent(t, first)
	if event["t"] != "focusTaken" || event["session"] != sessionID {
		t.Fatalf("event = %#v, want focusTaken for %s", event, sessionID)
	}
	if event["attachmentId"] != second.attachmentID(sessionID) {
		t.Fatalf("event attachment = %v, want the new owner %s", event["attachmentId"], second.attachmentID(sessionID))
	}
}

// The lease returns to the previous holder when the peer that took it goes
// away, and that holder is told so it can treat its lease as confirmed again.
func TestFocusLeaseReturnsToThePreviousHolderWhenTheTakerDetaches(t *testing.T) {
	const sessionID = "session-focus-return"
	service := &Service{}
	service.lazyInit()
	session := focusTestSession(sessionID)
	first := newFocusTestPeer(t, service, sessionID)
	second := newFocusTestPeer(t, service, sessionID)

	if _, _, err := service.focusPeerLocked(context.Background(), first, session, true, 80, 24, false, false); err != nil {
		t.Fatalf("first claim: %v", err)
	}
	if _, _, err := service.focusPeerLocked(context.Background(), second, session, true, 80, 24, false, false); err != nil {
		t.Fatalf("second claim: %v", err)
	}
	service.detachPeer(second, sessionID)

	if !service.isFocused(first, sessionID) {
		t.Fatal("the lease did not return to the previous holder")
	}
	if !service.hasControlPeer(first, sessionID) {
		t.Fatal("the restored holder does not own the mutation lease")
	}
	event := nextFocusEvent(t, first)
	if event["t"] != "focusGranted" || event["session"] != sessionID {
		t.Fatalf("event = %#v, want focusGranted for %s", event, sessionID)
	}
	if event["attachmentId"] != first.attachmentID(sessionID) {
		t.Fatalf("event attachment = %v, want %s", event["attachmentId"], first.attachmentID(sessionID))
	}
}

// A peer that blurred the session no longer wants the lease, so it must not get
// it back when a later claimer disconnects. Last-claimer-wins stays the rule
// while a claimer is connected.
func TestFocusLeaseIsNotRestoredToAPeerThatBlurred(t *testing.T) {
	const sessionID = "session-focus-blur"
	service := &Service{}
	service.lazyInit()
	session := focusTestSession(sessionID)
	first := newFocusTestPeer(t, service, sessionID)
	second := newFocusTestPeer(t, service, sessionID)

	if _, _, err := service.focusPeerLocked(context.Background(), first, session, true, 80, 24, false, false); err != nil {
		t.Fatalf("first claim: %v", err)
	}
	if _, _, err := service.focusPeerLocked(context.Background(), first, session, false, 0, 0, false, false); err != nil {
		t.Fatalf("first release: %v", err)
	}
	if _, _, err := service.focusPeerLocked(context.Background(), second, session, true, 80, 24, false, false); err != nil {
		t.Fatalf("second claim: %v", err)
	}
	service.detachPeer(second, sessionID)

	if service.hasFocusedPeer(sessionID) {
		t.Fatal("the lease was restored to a peer that had blurred the session")
	}
	noFocusEvent(t, first)
}

// The control events travel on the control lane so a burst of terminal output
// cannot delay a lease-loss notice.
func TestFocusControlEventsUseTheControlLane(t *testing.T) {
	peer := &wsPeer{
		server:          &HTTPServer{Service: &Service{}},
		outbound:        make(chan outboundMessage, outboundQueueCapacity),
		controlOutbound: make(chan outboundMessage, outboundControlQueueCapacity),
		closed:          make(chan struct{}),
	}
	if err := peer.enqueueFocusTaken("session", "attachment"); err != nil {
		t.Fatal(err)
	}
	if err := peer.enqueueFocusGranted("session", "attachment"); err != nil {
		t.Fatal(err)
	}
	if got := len(peer.controlOutbound); got != 2 {
		t.Fatalf("control queue length = %d, want 2", got)
	}
	if got := len(peer.outbound); got != 0 {
		t.Fatalf("output queue length = %d, want 0", got)
	}
	item := <-peer.controlOutbound
	if item.kind != websocket.TextMessage {
		t.Fatalf("event kind = %d, want text", item.kind)
	}
}
