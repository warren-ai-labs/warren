package server

import (
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/output"
)

// closedReason reads the recorded close reason of a peer under the same lock
// the production close path uses.
func closedReason(peer *wsPeer) string {
	peer.enqueueMu.Lock()
	defer peer.enqueueMu.Unlock()
	return peer.closeReason
}

// A shared-ring frame for a session whose only subscribers read their own direct
// Ghostline stream has no recipients. It must not touch the session broadcast
// lock at all, because a legitimate holder — attach recovery capturing a
// checkpoint, focus/resize applying a PTY size, or the Agent subsystem reading a
// canonical history page — would otherwise be misread as a wedged lock and reset
// every subscription multiplexed onto that WebSocket.
func TestBroadcastFrameLeavesDirectSubscribersAloneWhileTheSessionLockIsHeld(t *testing.T) {
	const sessionID = "session-direct-only"
	service := &Service{CommandTimeout: 50 * time.Millisecond}
	service.lazyInit()
	// A production peer owns its close channel from the writer setup; construct
	// the same state directly so the reset path is exercised for real.
	peer := &wsPeer{server: &HTTPServer{Service: service}, closed: make(chan struct{})}

	service.registerPeer(sessionID, peer)
	service.reservePeerCursorOutput(peer, sessionID)

	lock := service.broadcastLock(sessionID)
	lock.Lock()
	defer lock.Unlock()

	started := time.Now()
	service.broadcastFrame(output.Frame{
		SessionID: sessionID,
		Epoch:     1,
		Sequence:  1,
		Payload:   []byte("live output"),
	})
	elapsed := time.Since(started)

	if reason := closedReason(peer); reason != "" {
		t.Fatalf("direct subscriber was closed while the session lock was held: %s", reason)
	}
	if !peer.hasOutput(sessionID) {
		t.Fatal("direct subscriber lost its output subscription")
	}
	if elapsed >= service.CommandTimeout {
		t.Fatalf("frame waited %s for a lock it had no recipient for", elapsed)
	}
}

// A subscriber that is still served from the shared ring can genuinely miss
// bytes, so it is reset. That reset must not extend to peers reading their own
// direct stream: one contended session must never drop the other sessions on the
// same connection.
func TestBroadcastLockTimeoutResetsOnlySharedSubscribers(t *testing.T) {
	const sessionID = "session-mixed-subscribers"
	service := &Service{CommandTimeout: 20 * time.Millisecond}
	service.lazyInit()
	httpServer := &HTTPServer{Service: service}
	shared := &wsPeer{server: httpServer, closed: make(chan struct{})}
	direct := &wsPeer{server: httpServer, closed: make(chan struct{})}

	service.registerPeer(sessionID, shared)
	service.registerPeer(sessionID, direct)
	service.reservePeerCursorOutput(direct, sessionID)

	lock := service.broadcastLock(sessionID)
	lock.Lock()
	defer lock.Unlock()

	service.broadcastFrame(output.Frame{
		SessionID: sessionID,
		Epoch:     1,
		Sequence:  1,
		Payload:   []byte("live output"),
	})

	if reason := closedReason(shared); reason != "force_reanchor" {
		t.Fatalf("shared subscriber was not reanchored after an undeliverable frame: %q", reason)
	}
	if reason := closedReason(direct); reason != "" {
		t.Fatalf("direct subscriber was reset for another peer's gap: %s", reason)
	}
	if !direct.hasOutput(sessionID) {
		t.Fatal("direct subscriber lost its output subscription")
	}
}
