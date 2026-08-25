package server

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

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

func TestGhostlineCursorOutputStopsForAttachAndPersistsOnShutdown(t *testing.T) {
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
		t.Fatal("cursor reader remained active during attach checkpoint")
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
