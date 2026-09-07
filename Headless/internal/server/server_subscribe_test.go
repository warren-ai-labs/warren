package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

type traceEvent struct {
	kind   string
	text   map[string]any
	output output.DecodedFrame
	atomic output.DecodedAtomicState
}

type protocolTrace struct {
	connection *websocket.Conn
	events     chan traceEvent
	history    []traceEvent
}

func newProtocolTrace(t *testing.T, connection *websocket.Conn) *protocolTrace {
	t.Helper()
	trace := &protocolTrace{connection: connection, events: make(chan traceEvent, 4096)}
	go func() {
		for {
			kind, data, err := connection.ReadMessage()
			if err != nil {
				return
			}
			if kind == websocket.BinaryMessage {
				if frame, decodeErr := output.DecodeOutput(data); decodeErr == nil {
					trace.events <- traceEvent{kind: "output", output: frame}
					continue
				}
				if state, decodeErr := output.DecodeAtomicState(data); decodeErr == nil {
					trace.events <- traceEvent{kind: "atomic", atomic: state}
					continue
				}
				trace.events <- traceEvent{kind: "malformed"}
				continue
			}
			var message map[string]any
			if json.Unmarshal(data, &message) == nil {
				trace.events <- traceEvent{kind: "text", text: message}
			}
		}
	}()
	return trace
}

func (trace *protocolTrace) next(timeout time.Duration) (traceEvent, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case event := <-trace.events:
		trace.history = append(trace.history, event)
		return event, nil
	case <-timer.C:
		return traceEvent{}, fmt.Errorf("timed out waiting for protocol event")
	}
}

func traceRequestID(prefix string) string {
	return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
}

func subscribeTrace(t *testing.T, trace *protocolTrace, sessionID string) output.DecodedAtomicState {
	t.Helper()
	requestID := traceRequestID("subscribe")
	if err := trace.connection.WriteJSON(api.Envelope{
		Type: "request", ID: requestID, Method: "session.subscribe",
		Params: map[string]any{"id": sessionID},
	}); err != nil {
		t.Fatal(err)
	}
	var atomicState output.DecodedAtomicState
	gotAtomic := false
	gotSynced := false
	for !gotSynced {
		event, err := trace.next(3 * time.Second)
		if err != nil {
			t.Fatal(err)
		}
		switch event.kind {
		case "atomic":
			if event.atomic.SessionID == sessionID {
				atomicState = event.atomic
				gotAtomic = true
			}
		case "text":
			if event.text["t"] == "response" && event.text["id"] == requestID {
				if ok, _ := event.text["ok"].(bool); !ok {
					t.Fatalf("subscribe failed: %#v", event.text["error"])
				}
			}
			if event.text["t"] == "synced" && event.text["session"] == sessionID {
				gotSynced = true
			}
		}
	}
	if !gotAtomic {
		t.Fatalf("subscribe %s completed without an atomic state", sessionID)
	}
	return atomicState
}

func unsubscribeTrace(t *testing.T, trace *protocolTrace, sessionID string) {
	t.Helper()
	requestID := traceRequestID("unsubscribe")
	if err := trace.connection.WriteJSON(api.Envelope{
		Type: "request", ID: requestID, Method: "session.unsubscribe",
		Params: map[string]any{"id": sessionID},
	}); err != nil {
		t.Fatal(err)
	}
	for {
		event, err := trace.next(3 * time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if event.kind != "text" || event.text["t"] != "response" || event.text["id"] != requestID {
			continue
		}
		if ok, _ := event.text["ok"].(bool); !ok {
			t.Fatalf("unsubscribe failed: %#v", event.text["error"])
		}
		return
	}
}

func validateProtocolTrace(t *testing.T, trace *protocolTrace, final []byte, sessionID string) {
	t.Helper()
	var (
		haveSnapshot bool
		epoch        uint64
		sequence     uint64
		lastEpoch    uint64
		lastSequence uint64
		latest       []byte
	)
	for index, event := range trace.history {
		switch event.kind {
		case "malformed":
			t.Fatalf("peer received malformed binary frame at event %d", index)
		case "atomic":
			state := event.atomic
			if state.SessionID != sessionID {
				continue
			}
			if haveSnapshot && (state.Epoch < lastEpoch || (state.Epoch == lastEpoch && state.Sequence < lastSequence)) {
				t.Fatalf("snapshot anchor regressed: previous=%d:%d current=%d:%d", lastEpoch, lastSequence, state.Epoch, state.Sequence)
			}
			if int(state.Sequence) != len(state.Payload) || state.Sequence > uint64(len(final)) {
				t.Fatalf("snapshot anchor/payload mismatch: anchor=%d:%d payload=%d final=%d", state.Epoch, state.Sequence, len(state.Payload), len(final))
			}
			if !bytes.Equal(state.Payload, final[:state.Sequence]) {
				t.Fatalf("snapshot payload differs from the retained output at %d:%d", state.Epoch, state.Sequence)
			}
			haveSnapshot = true
			epoch = state.Epoch
			sequence = state.Sequence
			lastEpoch = state.Epoch
			lastSequence = state.Sequence
			latest = append(latest[:0], state.Payload...)
		case "output":
			frame := event.output
			if frame.SessionID != sessionID {
				continue
			}
			if !haveSnapshot {
				t.Fatalf("output arrived before the first snapshot: %#v", frame)
			}
			if frame.Epoch != epoch || frame.Sequence != sequence {
				t.Fatalf("output anchor is not contiguous: want=%d:%d got=%d:%d", epoch, sequence, frame.Epoch, frame.Sequence)
			}
			end := frame.Sequence + uint64(len(frame.Payload))
			if end > uint64(len(final)) || !bytes.Equal(frame.Payload, final[frame.Sequence:end]) {
				t.Fatalf("output payload differs at %d:%d (%d bytes)", frame.Epoch, frame.Sequence, len(frame.Payload))
			}
			sequence = end
			lastEpoch = frame.Epoch
			lastSequence = sequence
			latest = append(latest, frame.Payload...)
		case "text":
			if event.text["t"] != "synced" || event.text["session"] != sessionID {
				continue
			}
			syncedEpoch, epochOK := event.text["epoch"].(float64)
			syncedSequence, sequenceOK := event.text["sequence"].(float64)
			if !epochOK || !sequenceOK || uint64(syncedEpoch) != epoch || uint64(syncedSequence) != lastSnapshotSequence(trace.history, index, sessionID) {
				t.Fatalf("synced marker does not match the latest snapshot: %#v", event.text)
			}
		}
	}
	if !haveSnapshot {
		t.Fatal("peer received no atomic snapshot")
	}
	if !bytes.Equal(latest, final) {
		t.Fatalf("latest snapshot plus live tail differs from final output: got=%d want=%d", len(latest), len(final))
	}
}

func lastSnapshotSequence(history []traceEvent, before int, sessionID string) uint64 {
	for index := before - 1; index >= 0; index-- {
		if history[index].kind == "atomic" && history[index].atomic.SessionID == sessionID {
			return history[index].atomic.Sequence
		}
	}
	return ^uint64(0)
}

type blockingAtomicStateRuntime struct {
	*memoryOutputRuntime
	started     chan struct{}
	startedOnce sync.Once
}

func (runtime *blockingAtomicStateRuntime) AtomicState(ctx context.Context, name string) (ghostline.AtomicState, error) {
	runtime.startedOnce.Do(func() { close(runtime.started) })
	<-ctx.Done()
	return ghostline.AtomicState{}, ctx.Err()
}

// snapshotResizes returns a copy of the recorded runtime resizes so tests
// can assert on them without racing the runtime mutex.
func (runtime *memoryOutputRuntime) snapshotResizes() []recordedResize {
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

// newMemoryOutputServiceWithSessions seeds one running session per given ID
// with matching in-memory output, which is enough for subscribe tests to
// exercise several terminals over a single socket.
func newMemoryOutputServiceWithSessions(t *testing.T, sessions ...string) (*Service, *memoryOutputRuntime, *httptest.Server) {
	t.Helper()
	state := newStateWithSessions(t, sessions...)
	runtime := newMemoryOutputRuntime(t)
	for _, session := range sessions {
		if err := runtime.Create(context.Background(), session, t.TempDir(), "", nil); err != nil {
			t.Fatal(err)
		}
	}
	service := &Service{Store: state, Runtime: runtime}
	// memoryOutputRuntime.Input already appends bytes to its cursor source and
	// wakes every reader. Installing Service.recordOutput as an additional
	// callback would append each input twice, making recovery tests observe
	// duplicate output that no real Ghostline reader produces.
	t.Cleanup(service.Shutdown)
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

func writeMemoryOutput(t *testing.T, runtime *memoryOutputRuntime, name, data string) {
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
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, firstSession, secondSession)
	writeMemoryOutput(t, runtime, firstSession, "one\r\n")

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	subscribeForSeed(t, connection, firstSession)
	writeMemoryOutput(t, runtime, secondSession, "two\r\n")
	subscribeForSeed(t, connection, secondSession)

	writeMemoryOutput(t, runtime, firstSession, "live-one\r")
	waitForRingUpper(t, service, firstSession, uint64(len("one\r\nlive-one\r")))
	frame := readBinaryFrame(t, connection)
	if frame.SessionID != firstSession || string(frame.Payload) != "live-one\r" {
		t.Fatalf("first live frame = %#v", frame)
	}

	writeMemoryOutput(t, runtime, secondSession, "live-two\r")
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

	writeMemoryOutput(t, runtime, firstSession, "still-one\r")
	frame = readBinaryFrame(t, connection)
	if frame.SessionID != firstSession || string(frame.Payload) != "still-one\r" {
		t.Fatalf("first session lost its subscription: %#v", frame)
	}

	writeMemoryOutput(t, runtime, secondSession, "quiet-two\r")
	expectNoBinaryFrame(t, connection)
}

func TestSubscribeDoesNotClaimFocus(t *testing.T) {
	const sessionID = "subscribe-passive"
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	writeMemoryOutput(t, runtime, sessionID, "seed\r\n")

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

func TestPassiveSubscriptionCanPromoteExplicitFocus(t *testing.T) {
	const sessionID = "subscribe-explicit-focus"
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	// A hidden Web page subscribes without claiming the shared runtime. The
	// explicit session id on focus is the only authority it needs to promote
	// this already-registered output stream after returning to the foreground.
	subscribeForSeed(t, connection, sessionID)
	if service.hasFocusedPeer(sessionID) {
		t.Fatal("passive subscription unexpectedly claimed focus")
	}

	focused := requestResult[map[string]bool](t, connection, "session.focus", map[string]any{
		"id": sessionID, "focused": true, "cols": 121, "rows": 41,
	})
	if !focused["focused"] || !focused["resized"] {
		t.Fatalf("explicit focus result = %#v, want focused and resized", focused)
	}
	resizes := runtime.snapshotResizes()
	if len(resizes) != 1 || resizes[0] != (recordedResize{columns: 121, rows: 41}) {
		t.Fatalf("explicit focus resizes = %#v", resizes)
	}

	// Blurring releases only the control lease; the output subscription stays
	// alive so a later focus promotion does not require replaying the state.
	unfocused := requestResult[map[string]bool](t, connection, "session.focus", map[string]any{
		"id": sessionID, "focused": false,
	})
	if unfocused["focused"] {
		t.Fatalf("explicit blur result = %#v", unfocused)
	}
	requestResult[map[string]bool](t, connection, "session.resize", map[string]any{
		"cols": 122, "rows": 42,
	})
	if got := len(runtime.snapshotResizes()); got != 1 {
		t.Fatalf("resize after explicit blur mutated runtime: %d calls", got)
	}
}

func TestClaimingSubscribeResizesBeforeRecovery(t *testing.T) {
	const sessionID = "subscribe-claim"
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	requestResult[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
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

func TestPeerCloseCleansEverySubscription(t *testing.T) {
	const firstSession = "close-first"
	const secondSession = "close-second"
	service, _, httpServer := newMemoryOutputServiceWithSessions(t, firstSession, secondSession)

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	requestResult[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{"id": firstSession})
	requestResult[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{"id": secondSession})

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

func TestUnsubscribeCancelsBlockedSubscriptionBeforeReturning(t *testing.T) {
	const sessionID = "unsubscribe-blocked"
	state := newStateWithSessions(t, sessionID)
	runtime := &blockingAtomicStateRuntime{
		memoryOutputRuntime: newMemoryOutputRuntime(t),
		started:             make(chan struct{}),
	}
	if err := runtime.Create(context.Background(), sessionID, t.TempDir(), "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Store:          state,
		Runtime:        runtime,
		DefaultRuntime: "ghostline",
		CommandTimeout: 2 * time.Second,
	}
	defer service.Shutdown()
	handler := NewHTTPServer(service, "secret", nil)
	httpServer := httptest.NewServer(handler.Handler())
	defer httpServer.Close()

	connection := openAuthenticatedConnectionWithStateFormat(
		t,
		httpServer.URL,
		"/v1/ws",
		nil,
		ghostline.AtomicStateFormat,
	)
	defer connection.Close()

	subscribeID := "subscribe-blocked"
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: subscribeID, Method: "session.subscribe",
		Params: map[string]any{"id": sessionID},
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-runtime.started:
	case <-time.After(time.Second):
		t.Fatal("blocked atomic state was not reached")
	}

	unsubscribeID := "unsubscribe-blocked"
	started := time.Now()
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: unsubscribeID, Method: "session.unsubscribe",
		Params: map[string]any{"id": sessionID},
	}); err != nil {
		t.Fatal(err)
	}
	responses := map[string]bool{}
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	for len(responses) < 2 {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("read cancellation responses: %v (responses=%v)", err, responses)
		}
		if kind != websocket.TextMessage {
			continue
		}
		var response api.Response
		if json.Unmarshal(data, &response) != nil || response.Type != "response" {
			continue
		}
		if response.ID == subscribeID {
			// Protocol 4 acknowledges the subscription before replay so input
			// remains responsive. Cancellation may therefore produce a later
			// best-effort error for the same id; the unsubscribe boundary is the
			// authoritative completion signal for this test.
			responses[subscribeID] = true
		} else if response.ID == unsubscribeID {
			if !response.OK {
				t.Fatalf("unsubscribe failed: %s", response.Error)
			}
			responses[unsubscribeID] = true
		}
	}
	_ = connection.SetReadDeadline(time.Time{})
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("unsubscribe waited too long for blocked subscribe: %v", elapsed)
	}
	if got := subscribedSessionCount(t, service, sessionID); got != 0 {
		t.Fatalf("blocked unsubscribe left %d peer subscriptions", got)
	}

	handler.peersMu.Lock()
	peers := make([]*wsPeer, 0, len(handler.peers))
	for peer := range handler.peers {
		peers = append(peers, peer)
	}
	handler.peersMu.Unlock()
	for _, peer := range peers {
		peer.subscriptionMu.Lock()
		pending := len(peer.pendingSubscriptions)
		peer.subscriptionMu.Unlock()
		if pending != 0 {
			t.Fatalf("pending subscriptions after unsubscribe = %d", pending)
		}
	}
}

func TestMultiplePeersKeepOrderedOutputAcrossRepeatedReanchors(t *testing.T) {
	const sessionID = "reanchor-stress"
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	writeMemoryOutput(t, runtime, sessionID, "seed\r\n")

	connections := make([]*websocket.Conn, 0, 3)
	traces := make([]*protocolTrace, 0, 3)
	for index := 0; index < 3; index++ {
		connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
		connections = append(connections, connection)
		traces = append(traces, newProtocolTrace(t, connection))
	}
	defer func() {
		for _, connection := range connections {
			_ = connection.Close()
		}
	}()

	for _, trace := range traces {
		subscribeTrace(t, trace, sessionID)
	}
	if got := subscribedSessionCount(t, service, sessionID); got != 3 {
		t.Fatalf("initial peer subscriptions = %d, want 3", got)
	}

	// Keep the runtime producing output while two peers repeatedly cross the
	// recovery boundary. The third peer is disconnected mid-stream to prove a
	// per-peer teardown does not disturb the remaining readers.
	writerErr := make(chan error, 1)
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		for index := 0; index < 240; index++ {
			marker := []byte(fmt.Sprintf("marker-%03d\r\n", index))
			if err := runtime.Input(context.Background(), sessionID, marker); err != nil {
				writerErr <- err
				return
			}
			time.Sleep(time.Millisecond)
		}
	}()

	for round := 0; round < 12; round++ {
		if round == 2 {
			_ = connections[2].Close()
			deadline := time.Now().Add(time.Second)
			for time.Now().Before(deadline) && subscribedSessionCount(t, service, sessionID) > 2 {
				time.Sleep(5 * time.Millisecond)
			}
			if got := subscribedSessionCount(t, service, sessionID); got != 2 {
				t.Fatalf("disconnecting one peer left %d subscriptions, want 2", got)
			}
		}
		trace := traces[round%2]
		unsubscribeTrace(t, trace, sessionID)
		subscribeTrace(t, trace, sessionID)
	}
	<-writerDone
	select {
	case err := <-writerErr:
		t.Fatal(err)
	default:
	}

	final, err := runtime.Capture(context.Background(), sessionID)
	if err != nil {
		t.Fatal(err)
	}
	// The direct Ghostline readers are asynchronous. Drain each surviving
	// peer until its latest snapshot plus live tail reaches the final cursor.
	for _, trace := range traces[:2] {
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if traceContainsFinalOutput(trace, final, sessionID) {
				break
			}
			_, nextErr := trace.next(50 * time.Millisecond)
			if nextErr != nil {
				continue
			}
		}
		if !traceContainsFinalOutput(trace, final, sessionID) {
			t.Fatalf("peer did not drain to final cursor (%d bytes)", len(final))
		}
		validateProtocolTrace(t, trace, final, sessionID)
	}

	if resizes := runtime.snapshotResizes(); len(resizes) != 0 {
		t.Fatalf("passive peers changed shared runtime size: %#v", resizes)
	}
}

func traceContainsFinalOutput(trace *protocolTrace, final []byte, sessionID string) bool {
	var (
		haveSnapshot bool
		sequence     uint64
		latest       []byte
	)
	for _, event := range trace.history {
		switch event.kind {
		case "atomic":
			if event.atomic.SessionID != sessionID {
				continue
			}
			haveSnapshot = true
			sequence = event.atomic.Sequence
			latest = append(latest[:0], event.atomic.Payload...)
		case "output":
			if !haveSnapshot || event.output.SessionID != sessionID || event.output.Sequence != sequence {
				continue
			}
			sequence += uint64(len(event.output.Payload))
			latest = append(latest, event.output.Payload...)
		}
	}
	return haveSnapshot && sequence == uint64(len(final)) && bytes.Equal(latest, final)
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

// readOutputFrameContaining drains protocol events until an output frame for
// sessionID carries a payload containing substr.
func readOutputFrameContaining(t *testing.T, trace *protocolTrace, sessionID, substr string) output.DecodedFrame {
	t.Helper()
	for {
		event, err := trace.next(3 * time.Second)
		if err != nil {
			t.Fatalf("timed out waiting for output containing %q on %s: %v", substr, sessionID, err)
		}
		if event.kind == "output" && event.output.SessionID == sessionID &&
			bytes.Contains(event.output.Payload, []byte(substr)) {
			return event.output
		}
	}
}

// TestWarmSubscriptionKeepsLiveOutputAfterFocus mirrors the desktop tab
// promotion flow on a single peer: the client subscribes once, then later
// promotes the existing subscription with a focus lease. The warm path must
// keep delivering live output without replaying a second recovery payload.
func TestWarmSubscriptionKeepsLiveOutputAfterFocus(t *testing.T) {
	const sessionID = "warm-after-focus"
	service, runtime, httpServer := newMemoryOutputServiceWithSessions(t, sessionID)
	writeMemoryOutput(t, runtime, sessionID, "seed\r\n")

	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	// All protocol reads go through one goroutine: the trace. Never read the
	// connection directly elsewhere, or concurrent websocket reads corrupt it.
	trace := newProtocolTrace(t, connection)

	subscribeID := traceRequestID("subscribe")
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: subscribeID, Method: "session.subscribe",
		Params: map[string]any{"id": sessionID},
	}); err != nil {
		t.Fatal(err)
	}
	for {
		event, err := trace.next(3 * time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if event.kind == "text" && event.text["t"] == "response" && event.text["id"] == subscribeID {
			if ok, _ := event.text["ok"].(bool); !ok {
				t.Fatalf("subscribe failed: %#v", event.text["error"])
			}
			break
		}
	}
	if got := subscribedSessionCount(t, service, sessionID); got != 1 {
		t.Fatalf("warm subscription count = %d, want 1", got)
	}

	focusID := traceRequestID("focus")
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: focusID, Method: "session.focus",
		Params: map[string]any{"id": sessionID, "focused": true},
	}); err != nil {
		t.Fatal(err)
	}
	for {
		event, err := trace.next(3 * time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if event.kind == "text" && event.text["t"] == "response" && event.text["id"] == focusID {
			if ok, _ := event.text["ok"].(bool); !ok {
				t.Fatalf("focus failed: %#v", event.text["error"])
			}
			break
		}
	}

	// Background output produced while the tab is parked/warm.
	writeMemoryOutput(t, runtime, sessionID, "BACKGROUND-ONE\r")
	writeMemoryOutput(t, runtime, sessionID, "BACKGROUND-TWO\r")

	deadline := time.Now().Add(3 * time.Second)
	var gotOne, gotTwo bool
	for time.Now().Before(deadline) {
		event, err := trace.next(3 * time.Second)
		if err != nil {
			break
		}
		if event.kind == "output" && event.output.SessionID == sessionID {
			if bytes.Contains(event.output.Payload, []byte("BACKGROUND-ONE")) {
				gotOne = true
			}
			if bytes.Contains(event.output.Payload, []byte("BACKGROUND-TWO")) {
				gotTwo = true
			}
		}
		if gotOne && gotTwo {
			break
		}
	}
	if !gotOne || !gotTwo {
		t.Fatalf("warm peer missed background output after control attach: gotOne=%v gotTwo=%v (subscribedCount=%d)",
			gotOne, gotTwo, subscribedSessionCount(t, service, sessionID))
	}
}
