package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// snapshotResizes returns a copy of the recorded runtime resizes so tests
// can assert on them without racing the runtime mutex.
func (runtime *spoolRuntime) snapshotResizes() []recordedResize {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	return append([]recordedResize(nil), runtime.resizes...)
}

// newStateWithSessions seeds a store with one running shell session per
// given ID, each bound to a runtime of the same name.
func newStateWithSessions(t *testing.T, sessions ...string) *store.Store {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID := store.NewID()
	workspaceID := store.NewID()
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: t.TempDir(), CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: "/tmp", Kind: "root", CreatedAt: time.Now().UTC()}}
		for _, sessionID := range sessions {
			value.Sessions = append(value.Sessions, api.Session{
				ID: sessionID, WorkspaceID: workspaceID, Title: "Shell", Kind: "shell",
				Runtime: sessionID, Lifecycle: "running", CreatedAt: time.Now().UTC(),
			})
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return state
}

// newSpoolServiceWithSessions seeds one running session per given ID with a
// matching spool runtime entry, which is enough for subscribe tests to
// exercise several terminals over a single socket.
func newSpoolServiceWithSessions(t *testing.T, sessions ...string) (*Service, *spoolRuntime, *httptest.Server) {
	t.Helper()
	state := newStateWithSessions(t, sessions...)
	runtime := newSpoolRuntime(t)
	for _, session := range sessions {
		if err := runtime.Create(context.Background(), session, t.TempDir(), "", nil); err != nil {
			t.Fatal(err)
		}
	}
	service := &Service{Store: state, Runtime: runtime}
	runtime.mu.Lock()
	runtime.onInput = service.recordOutput
	runtime.mu.Unlock()
	for _, session := range sessions {
		if current, ok := service.Session(session); ok {
			if _, err := service.ensureOutput(context.Background(), current); err != nil {
				t.Fatal(err)
			}
			if seed, err := runtime.Capture(context.Background(), session); err == nil && len(seed) > 0 {
				service.recordOutput(session, seed)
			}
		}
	}
	server := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	t.Cleanup(server.Close)
	return service, runtime, server
}

func writeSpool(t *testing.T, runtime *spoolRuntime, name, data string) {
	t.Helper()
	if err := runtime.Input(context.Background(), name, []byte(data)); err != nil {
		t.Fatal(err)
	}
}

func expectNoBinaryFrame(t *testing.T, connection *websocket.Conn) {
	t.Helper()
	if err := connection.SetReadDeadline(time.Now().Add(200 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, _, err := connection.ReadMessage()
		if err != nil {
			return
		}
		if kind == websocket.BinaryMessage {
			t.Fatal("expected no binary frames, got one")
		}
	}
}

func subscribedSessionCount(t *testing.T, service *Service, sessionID string) int {
	t.Helper()
	service.outputMu.Lock()
	defer service.outputMu.Unlock()
	return len(service.peers[sessionID])
}

func TestSubscribeFeedsMultipleSessionsIndependently(t *testing.T) {
	const firstSession = "subscribe-first"
	const secondSession = "subscribe-second"
	service, runtime, httpServer := newSpoolServiceWithSessions(t, firstSession, secondSession)
	writeSpool(t, runtime, firstSession, "one\r\n")

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	subscribeForSeed(t, connection, firstSession)
	writeSpool(t, runtime, secondSession, "two\r\n")
	subscribeForSeed(t, connection, secondSession)

	writeSpool(t, runtime, firstSession, "live-one\r")
	waitForRingUpper(t, service, firstSession, uint64(len("one\r\nlive-one\r")))
	frame := readBinaryFrame(t, connection)
	if frame.SessionID != firstSession || string(frame.Payload) != "live-one\r" {
		t.Fatalf("first live frame = %#v", frame)
	}

	writeSpool(t, runtime, secondSession, "live-two\r")
	frame = readBinaryFrame(t, connection)
	if frame.SessionID != secondSession || string(frame.Payload) != "live-two\r" {
		t.Fatalf("second live frame = %#v", frame)
	}

	// Unsubscribing the second terminal must not disturb the first. Liveness
	// is asserted before any silence check: a gorilla client connection may
	// not be reused for meaningful reads after a deadline-driven timeout, so
	// every expectNoBinaryFrame call must be a connection's final read.
	requestResult[map[string]bool](t, connection, "session.unsubscribe", map[string]any{"id": secondSession})
	if got := subscribedSessionCount(t, service, secondSession); got != 0 {
		t.Fatalf("second session peers = %d, want 0", got)
	}

	writeSpool(t, runtime, firstSession, "still-one\r")
	frame = readBinaryFrame(t, connection)
	if frame.SessionID != firstSession || string(frame.Payload) != "still-one\r" {
		t.Fatalf("first session lost its subscription: %#v", frame)
	}

	writeSpool(t, runtime, secondSession, "quiet-two\r")
	expectNoBinaryFrame(t, connection)
}

func TestSubscribeDoesNotClaimFocus(t *testing.T) {
	const sessionID = "subscribe-passive"
	service, runtime, httpServer := newSpoolServiceWithSessions(t, sessionID)
	writeSpool(t, runtime, sessionID, "seed\r\n")

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	subscribeForSeed(t, connection, sessionID)
	if service.hasFocusedPeer(sessionID) {
		t.Fatal("subscribe must never claim focus ownership")
	}

	// A subscriber holds no control lease, so its resize requests cannot
	// mutate the shared runtime; the daemon rejects them outright instead of
	// letting stale viewport callbacks fight the focused endpoint.
	requestError(t, connection, "session.resize", map[string]any{
		"cols": 120, "rows": 40,
	})
	if got := len(runtime.snapshotResizes()); got != 0 {
		t.Fatalf("unfocused resize mutated runtime: %d calls", got)
	}
}

func TestClaimingSubscribeResizesBeforeRecovery(t *testing.T) {
	const sessionID = "subscribe-claim"
	service, runtime, httpServer := newSpoolServiceWithSessions(t, sessionID)
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	requestResult[map[string]bool](t, connection, "session.subscribe", map[string]any{
		"id":    sessionID,
		"claim": true,
		"cols":  120,
		"rows":  40,
	})
	if !service.hasFocusedPeer(sessionID) {
		t.Fatal("claiming subscribe did not acquire focus")
	}
	resizes := runtime.snapshotResizes()
	if len(resizes) != 1 || resizes[0] != (recordedResize{columns: 120, rows: 40}) {
		t.Fatalf("claiming subscribe resizes = %#v", resizes)
	}
}

func TestControlOnlyAttachSwapsLeaseWithoutOutputWork(t *testing.T) {
	const sessionID = "control-only"
	service, runtime, httpServer := newSpoolServiceWithSessions(t, sessionID)
	writeSpool(t, runtime, sessionID, "seed\r\n")

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	result := requestResult[map[string]any](t, connection, "session.attach", map[string]any{
		"id": sessionID, "output": "false",
	})
	if result["id"] != sessionID {
		t.Fatalf("control-only attach result = %#v", result)
	}
	if got := subscribedSessionCount(t, service, sessionID); got != 0 {
		t.Fatalf("control-only attach created %d output subscriptions, want 0", got)
	}
	if len(runtime.snapshotResizes()) != 0 {
		t.Fatal("control-only attach resized the shared runtime")
	}

	// The lease swap still routes focus claims: focusPeerLocked requires an
	// output registration, so an unsubscribed control holder stays unfocused.
	focused := requestResult[map[string]bool](t, connection, "session.focus", map[string]any{
		"id": sessionID, "focused": "true", "cols": 100, "rows": 30,
	})
	if focused["focused"] {
		t.Fatal("focus claimed without an output registration")
	}
	// Final read on this connection: no snapshot, replay, or live output may
	// leak from a control-only attach.
	writeSpool(t, runtime, sessionID, "leak\r")
	expectNoBinaryFrame(t, connection)
}

func TestLegacyAttachKeepsSingleSubscriptionSemantics(t *testing.T) {
	const firstSession = "legacy-first"
	const secondSession = "legacy-second"
	service, runtime, httpServer := newSpoolServiceWithSessions(t, firstSession, secondSession)

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	attachBrowser(t, connection, firstSession, nil)
	readBrowserMessage(t, connection, "attached")
	readBinaryFrame(t, connection)
	readBrowserMessage(t, connection, "synced")

	// Switching terminals through the legacy path must unsubscribe the old
	// session so web/mobile clients do not accumulate background streams.
	attachBrowser(t, connection, secondSession, nil)
	readBrowserMessage(t, connection, "attached")
	readBinaryFrame(t, connection)
	readBrowserMessage(t, connection, "synced")
	if got := subscribedSessionCount(t, service, firstSession); got != 0 {
		t.Fatalf("legacy switch left %d subscriptions on the old session", got)
	}

	writeSpool(t, runtime, firstSession, "quiet\r")
	expectNoBinaryFrame(t, connection)
}

func TestPeerCloseCleansEverySubscription(t *testing.T) {
	const firstSession = "close-first"
	const secondSession = "close-second"
	service, _, httpServer := newSpoolServiceWithSessions(t, firstSession, secondSession)

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	requestResult[map[string]bool](t, connection, "session.subscribe", map[string]any{"id": firstSession})
	requestResult[map[string]bool](t, connection, "session.subscribe", map[string]any{"id": secondSession})

	connection.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if subscribedSessionCount(t, service, firstSession) == 0 &&
			subscribedSessionCount(t, service, secondSession) == 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("closing the socket left subscriptions behind")
}

// subscribeForSeed subscribes to a fresh session, consumes the reanchor
// snapshot plus synced marker, and returns the resulting anchor.
func subscribeForSeed(t *testing.T, connection *websocket.Conn, sessionID string) output.Anchor {
	t.Helper()
	id := store.NewID()
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: id, Method: "session.subscribe",
		Params: map[string]any{"id": sessionID},
	}); err != nil {
		t.Fatal(err)
	}
	var anchor output.Anchor
	sawSynced := false
	deadline := time.Now().Add(3 * time.Second)
	_ = connection.SetReadDeadline(deadline)
	defer connection.SetReadDeadline(time.Time{})
	for !sawSynced {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if kind == websocket.BinaryMessage {
			continue
		}
		var message map[string]any
		if json.Unmarshal(data, &message) != nil {
			continue
		}
		switch message["t"] {
		case "response":
			if message["id"] != id {
				continue
			}
			if message["ok"] != true {
				t.Fatalf("subscribe failed: %#v", message["error"])
			}
		case "synced":
			anchor = anchorFromMessage(t, message)
			sawSynced = true
		}
	}
	return anchor
}
