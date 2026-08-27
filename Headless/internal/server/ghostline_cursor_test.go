package server

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/gorilla/websocket"
)

type recordingAtomicRuntime struct {
	*GhostlineRuntime
	mu     sync.Mutex
	events []string
}

type injectingAtomicRuntime struct {
	*recordingAtomicRuntime
	once sync.Once
}

func (r *injectingAtomicRuntime) AtomicState(ctx context.Context, name string) (ghostline.AtomicState, error) {
	r.once.Do(func() {
		_ = r.GhostlineRuntime.Input(ctx, name, []byte("echo during-atomic-state\r"))
		marker := []byte("during-atomic-state")
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			checkpoint, err := r.GhostlineRuntime.Checkpoint(ctx, name)
			// The shell echoes the command before it executes it. Wait for both
			// occurrences so the snapshot cursor is past the command result, not
			// merely past the input echo.
			if err == nil && bytes.Count(checkpoint.Replay, marker) >= 2 {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
	})
	return r.recordingAtomicRuntime.AtomicState(ctx, name)
}

func (r *recordingAtomicRuntime) Resize(ctx context.Context, name string, columns, rows int) error {
	r.mu.Lock()
	r.events = append(r.events, "resize")
	r.mu.Unlock()
	return r.GhostlineRuntime.Resize(ctx, name, columns, rows)
}

func (r *recordingAtomicRuntime) AtomicState(ctx context.Context, name string) (ghostline.AtomicState, error) {
	r.mu.Lock()
	r.events = append(r.events, "atomic-state")
	r.mu.Unlock()
	return r.GhostlineRuntime.AtomicState(ctx, name)
}

func (r *recordingAtomicRuntime) snapshotEvents() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.events...)
}

func TestRosterOmitsGhostlineInternalRecoveryData(t *testing.T) {
	state := newStateWithSession(t, "session-cursor", "runtime-cursor")
	if err := state.Update(func(value *api.State) error {
		value.Sessions[0].OutputCursor = "opaque-v1-cursor"
		value.GhostlineMigration = &api.GhostlineMigration{
			SessionID:    "migration",
			SourceSocket: "/private/source.sock",
			TargetSocket: "/private/target.sock",
			Phase:        api.GhostlineMigrationCommitted,
		}
		return nil
	}); err != nil {
		t.Fatalf("seed internal state: %v", err)
	}

	roster := (&Service{Store: state}).Roster(context.Background())
	if roster.GhostlineMigration != nil {
		t.Fatalf("roster exposed migration: %#v", roster.GhostlineMigration)
	}
	if got := roster.Sessions[0].OutputCursor; got != "" {
		t.Fatalf("roster exposed output cursor %q", got)
	}
	encoded, err := json.Marshal(roster)
	if err != nil {
		t.Fatalf("marshal roster: %v", err)
	}
	for _, internal := range [][]byte{[]byte("outputCursor"), []byte("ghostlineMigration"), []byte("/private/source.sock")} {
		if bytes.Contains(encoded, internal) {
			t.Fatalf("serialized roster exposed internal value %q: %s", internal, encoded)
		}
	}
}

func TestPublicSessionOmitsOutputCursor(t *testing.T) {
	session := api.Session{ID: "session", OutputCursor: "opaque-v1-cursor"}
	if got := publicSession(session); got.OutputCursor != "" {
		t.Fatalf("public session exposed output cursor %q", got.OutputCursor)
	}
	preflight := publicSessionMovePreflight(api.SessionMovePreflight{Session: session})
	if preflight.Session.OutputCursor != "" {
		t.Fatalf("public preflight exposed output cursor %q", preflight.Session.OutputCursor)
	}
}

func TestGhostlineCursorOutputRemainsLiveDuringAttachAndPersistsOnShutdown(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	const runtimeName = "warren_cursor_output"
	if err := runtime.Create(context.Background(), runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}
	state := newStateWithSession(t, "session-cursor-output", runtimeName)
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: "ghostline"}
	session := state.Snapshot().Sessions[0]
	outputSession, err := service.ensureOutput(context.Background(), session)
	if err != nil {
		t.Fatalf("ensure output: %v", err)
	}
	if !cursorReaderRunning(outputSession) {
		t.Fatal("cursor reader did not start")
	}

	lock, resume, err := service.prepareAttach(context.Background(), session)
	if err != nil {
		t.Fatalf("prepare attach: %v", err)
	}
	if cursorReaderRunning(outputSession) {
		t.Fatal("shared cursor reader remained active during peer recovery")
	}
	lock.Unlock()
	resume()
	waitForCursorReader(t, outputSession, true)

	if err := runtime.Input(context.Background(), runtimeName, []byte("echo cursor-persist\r")); err != nil {
		t.Fatalf("write ghostline input: %v", err)
	}
	waitForRingUpper(t, service, session.ID, 1)
	service.Shutdown()

	persisted := state.Snapshot().Sessions[0].OutputCursor
	if persisted == "" {
		t.Fatal("shutdown did not persist the v1 output cursor")
	}
	if _, err := ghostline.ParseCursor(persisted); err != nil {
		t.Fatalf("persisted cursor is invalid: %v", err)
	}
}

func TestAtomicDesktopRecoveryResizesBeforeSnapshotAndKeepsSnapshotOpaque(t *testing.T) {
	baseRuntime, _ := startGhostlineRuntime(t)
	runtime := &recordingAtomicRuntime{GhostlineRuntime: baseRuntime}
	const runtimeName = "warren_atomic_recovery"
	const sessionID = "session-atomic-recovery"
	if err := runtime.Create(context.Background(), runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}
	if err := runtime.Input(context.Background(), runtimeName, []byte("printf '\\033[48;5;240mstyled blank    \\033[0m\\r\\n'\r")); err != nil {
		t.Fatalf("seed ghostline session: %v", err)
	}
	waitGhostlineOutput(t, baseRuntime, runtimeName, "styled blank")

	state := newStateWithSession(t, sessionID, runtimeName)
	service := &Service{
		Store:          state,
		Runtime:        runtime,
		DefaultRuntime: "ghostline",
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnectionWithStateFormat(
		t,
		httpServer.URL,
		"/v1/ws",
		nil,
		ghostline.AtomicStateFormat,
	)
	defer connection.Close()

	_ = requestResultBeforeBinary[map[string]bool](t, connection, "session.subscribe", map[string]any{
		"id": sessionID, "claim": true, "cols": 113, "rows": 37,
	})
	attached := readBrowserMessage(t, connection, "attached")
	if attached["reanchor"] != true {
		t.Fatalf("attached message = %#v, want reanchor", attached)
	}

	_ = connection.SetReadDeadline(time.Now().Add(3 * time.Second))
	messageType, payload, err := connection.ReadMessage()
	_ = connection.SetReadDeadline(time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if messageType != websocket.BinaryMessage {
		t.Fatalf("message type = %d, want binary atomic state", messageType)
	}
	atomicState, err := output.DecodeAtomicState(payload)
	if err != nil {
		t.Fatalf("decode atomic state: %v", err)
	}
	if atomicState.SessionID != sessionID || atomicState.Format != ghostline.AtomicStateFormat {
		t.Fatalf("atomic state header = %#v", atomicState)
	}
	if !bytes.HasPrefix(atomicState.Payload, []byte("GHOSTSNP")) {
		t.Fatalf("atomic state payload is not a Ghostty snapshot: %q", atomicState.Payload[:min(len(atomicState.Payload), 16)])
	}
	synced := readBrowserMessage(t, connection, "synced")
	if anchorFromMessage(t, synced) != (output.Anchor{Epoch: atomicState.Epoch, Sequence: atomicState.Sequence}) {
		t.Fatalf("synced marker does not match atomic state: %#v", synced)
	}
	if events := runtime.snapshotEvents(); len(events) < 2 || events[0] != "resize" || events[1] != "atomic-state" {
		t.Fatalf("runtime events = %v, want resize before atomic-state", events)
	}
}

func TestANSITerminalStatePeerReceivesAtomicReplayFrame(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	const runtimeName = "warren_ansi_state"
	const sessionID = "session-ansi-state"
	if err := runtime.Create(context.Background(), runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}
	if err := runtime.Input(context.Background(), runtimeName, []byte("echo ansi-state\r")); err != nil {
		t.Fatalf("seed ghostline session: %v", err)
	}
	waitGhostlineOutput(t, runtime, runtimeName, "ansi-state")

	state := newStateWithSession(t, sessionID, runtimeName)
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: "ghostline"}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	_ = requestResultBeforeBinary[map[string]bool](t, connection, "session.subscribe", map[string]any{"id": sessionID})
	readBrowserMessage(t, connection, "attached")
	_ = connection.SetReadDeadline(time.Now().Add(3 * time.Second))
	messageType, payload, err := connection.ReadMessage()
	_ = connection.SetReadDeadline(time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if messageType != websocket.BinaryMessage {
		t.Fatalf("message type = %d, want binary terminal state", messageType)
	}
	stateFrame, err := output.DecodeAtomicState(payload)
	if err != nil {
		t.Fatalf("decode terminal state: %v", err)
	}
	if stateFrame.Format != terminalStateFormatANSI {
		t.Fatalf("terminal state format = %q", stateFrame.Format)
	}
	if !bytes.Contains(stateFrame.Payload, []byte("ansi-state")) {
		t.Fatalf("terminal state missing content: %q", stateFrame.Payload)
	}
	readBrowserMessage(t, connection, "synced")
}

func TestColdAtomicPeerDoesNotInterruptOrDuplicateExistingPeerOutput(t *testing.T) {
	baseRuntime, _ := startGhostlineRuntime(t)
	runtime := &injectingAtomicRuntime{
		recordingAtomicRuntime: &recordingAtomicRuntime{GhostlineRuntime: baseRuntime},
	}
	const runtimeName = "warren_multi_peer_atomic"
	const sessionID = "session-multi-peer-atomic"
	if err := runtime.Create(context.Background(), runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}
	state := newStateWithSession(t, sessionID, runtimeName)
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: "ghostline"}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer httpServer.Close()

	existing := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer existing.Close()
	_ = requestResultBeforeBinary[map[string]bool](t, existing, "session.subscribe", map[string]any{"id": sessionID})
	readBrowserMessage(t, existing, "attached")
	readAtomicStateFrame(t, existing)
	readBrowserMessage(t, existing, "synced")

	cold := openAuthenticatedConnectionWithStateFormat(
		t,
		httpServer.URL,
		"/v1/ws",
		nil,
		ghostline.AtomicStateFormat,
	)
	defer cold.Close()
	_ = requestResultBeforeBinary[map[string]bool](t, cold, "session.subscribe", map[string]any{"id": sessionID})
	readBrowserMessage(t, cold, "attached")
	readAtomicStateFrame(t, cold)
	readBrowserMessage(t, cold, "synced")

	_ = readOutputUntilContains(t, existing, "during-atomic-state")

	if err := runtime.Input(context.Background(), runtimeName, []byte("echo after-atomic-state\r")); err != nil {
		t.Fatalf("write live output: %v", err)
	}
	for label, connection := range map[string]*websocket.Conn{"existing": existing, "cold": cold} {
		received := readOutputUntilContains(t, connection, "after-atomic-state")
		if label == "cold" && bytes.Contains(received, []byte("during-atomic-state")) {
			t.Fatalf("cold peer replayed output already covered by its snapshot: %q", received)
		}
		t.Logf("%s peer received post-snapshot output", label)
	}
}

func readOutputUntilContains(t *testing.T, connection *websocket.Conn, marker string) []byte {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	var received []byte
	for time.Now().Before(deadline) {
		_ = connection.SetReadDeadline(deadline)
		messageType, payload, err := connection.ReadMessage()
		_ = connection.SetReadDeadline(time.Time{})
		if err != nil {
			t.Fatalf("read output containing %q: %v (received %q)", marker, err, received)
		}
		if messageType != websocket.BinaryMessage {
			continue
		}
		frame, err := output.DecodeOutput(payload)
		if err != nil {
			continue
		}
		received = append(received, frame.Payload...)
		if bytes.Contains(received, []byte(marker)) {
			return received
		}
	}
	t.Fatalf("output did not contain %q: %q", marker, received)
	return nil
}

func readAtomicStateFrame(t *testing.T, connection *websocket.Conn) output.DecodedAtomicState {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(3 * time.Second))
	defer connection.SetReadDeadline(time.Time{})
	for {
		messageType, payload, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if messageType != websocket.BinaryMessage {
			continue
		}
		state, err := output.DecodeAtomicState(payload)
		if err != nil {
			t.Fatal(err)
		}
		return state
	}
}

func cursorReaderRunning(outputSession *outputSession) bool {
	outputSession.mu.Lock()
	defer outputSession.mu.Unlock()
	return outputSession.reader != nil
}

func waitForCursorReader(t *testing.T, outputSession *outputSession, want bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cursorReaderRunning(outputSession) == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("cursor reader running = %t, want %t", cursorReaderRunning(outputSession), want)
}
