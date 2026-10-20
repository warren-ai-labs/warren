package server

import (
	"context"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
)

// recordHandler collects slog records so a test can assert what the attach
// phase reported without parsing a log file.
type recordHandler struct {
	mu      sync.Mutex
	records []slog.Record
}

func (h *recordHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h *recordHandler) Handle(_ context.Context, record slog.Record) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, record.Clone())
	return nil
}

func (h *recordHandler) WithAttrs([]slog.Attr) slog.Handler { return h }

func (h *recordHandler) WithGroup(string) slog.Handler { return h }

// messages returns the collected record messages in order.
func (h *recordHandler) messages() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	values := make([]string, 0, len(h.records))
	for _, record := range h.records {
		values = append(values, record.Message)
	}
	return values
}

// attr returns one attribute of the first record with the given message.
func (h *recordHandler) attr(message, key string) (slog.Value, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, record := range h.records {
		if record.Message != message {
			continue
		}
		var found slog.Value
		var ok bool
		record.Attrs(func(attr slog.Attr) bool {
			if attr.Key == key {
				found = attr.Value
				ok = true
				return false
			}
			return true
		})
		return found, ok
	}
	return slog.Value{}, false
}

// countingCursorRuntime fails the test if the attach opens a reader for a gap
// it already knows it cannot walk.
type countingCursorRuntime struct {
	*GhostlineRuntime
	mu        sync.Mutex
	openCalls []ghostline.Cursor
}

func (r *countingCursorRuntime) OpenOutput(ctx context.Context, name string, cursor ghostline.Cursor) (CursorOutputReader, error) {
	r.mu.Lock()
	r.openCalls = append(r.openCalls, cursor)
	r.mu.Unlock()
	return r.GhostlineRuntime.OpenOutput(ctx, name, cursor)
}

func (r *countingCursorRuntime) opens() []ghostline.Cursor {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]ghostline.Cursor(nil), r.openCalls...)
}

// seedGenerationBoundary writes a large backlog into one output generation,
// rotates the log, and returns the start of the completed generation together
// with the live checkpoint cursor. Those two cursors are exactly the
// incomparable pair a generation change produces: the old generation is still
// readable, so a probe reader would find bytes while no distance to the
// checkpoint exists.
func seedGenerationBoundary(
	t *testing.T,
	runtime *GhostlineRuntime,
	client *ghostline.Client,
	runtimeName string,
) (stale, head ghostline.Cursor) {
	t.Helper()
	ctx := context.Background()
	if err := runtime.Create(ctx, runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}
	// A gap this size costs minutes when read one byte per round trip, so the
	// assertions below cannot pass by accident on a fast machine.
	if err := runtime.Input(ctx, runtimeName, []byte("head -c 600000 /dev/zero | base64 -w0; printf '\\nGEN1-READY\\n'\r")); err != nil {
		t.Fatalf("seed generation 1: %v", err)
	}
	waitGhostlineOutput(t, runtime, runtimeName, "GEN1-READY")
	// The visible marker can land before the PTY reader has appended every
	// backlog byte to the log. Wait for the log itself, not the screen.
	deadline := time.Now().Add(10 * time.Second)
	var before ghostline.Cursor
	for time.Now().Before(deadline) {
		state, err := runtime.AtomicState(ctx, runtimeName)
		if err != nil {
			t.Fatalf("capture atomic state: %v", err)
		}
		before = state.Cursor
		if offset, ok := cursorOffset(before); ok && offset > 700000 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	offset, ok := cursorOffset(before)
	if !ok || offset <= 700000 {
		t.Fatalf("backlog never reached the output log: cursor %q offset %d", before.String(), offset)
	}
	generation := cursorGeneration(t, before)
	ghostlineSession, err := client.Get(ctx, runtimeName)
	if err != nil {
		t.Fatalf("get ghostline session: %v", err)
	}
	boundary, err := ghostlineSession.RotateOutput(ctx)
	if err != nil {
		t.Fatalf("rotate output: %v", err)
	}
	if cursorGeneration(t, boundary) != generation+1 {
		t.Fatalf("rotation boundary = %q, want generation %d", boundary.String(), generation+1)
	}
	if err := runtime.Input(ctx, runtimeName, []byte("printf 'GEN2-READY\\n'\r")); err != nil {
		t.Fatalf("seed generation 2: %v", err)
	}
	waitGhostlineOutput(t, runtime, runtimeName, "GEN2-READY")
	stale, err = ghostline.ParseCursor(fmt.Sprintf("v1:%d:0", generation))
	if err != nil {
		t.Fatalf("parse completed-generation cursor: %v", err)
	}
	state, err := runtime.AtomicState(ctx, runtimeName)
	if err != nil {
		t.Fatalf("capture atomic state: %v", err)
	}
	if _, known := stale.Distance(state.Cursor); known {
		t.Fatalf("cursors %q and %q are comparable; the test needs a generation boundary", stale.String(), state.Cursor.String())
	}
	return stale, state.Cursor
}

// cursorOffset returns a cursor's byte offset inside its generation.
func cursorOffset(cursor ghostline.Cursor) (int, bool) {
	parts := strings.Split(cursor.String(), ":")
	if len(parts) != 3 {
		return 0, false
	}
	value, err := strconv.Atoi(parts[2])
	if err != nil {
		return 0, false
	}
	return value, true
}

// cursorGeneration returns a cursor's output generation.
func cursorGeneration(t *testing.T, cursor ghostline.Cursor) int {
	t.Helper()
	parts := strings.Split(cursor.String(), ":")
	if len(parts) != 3 {
		t.Fatalf("unexpected cursor %q", cursor.String())
	}
	value, err := strconv.Atoi(parts[1])
	if err != nil {
		t.Fatalf("parse generation from %q: %v", cursor.String(), err)
	}
	return value
}

// An incomparable catch-up pair must not be walked byte by byte. The ring is
// reseeded at the checkpoint instead, which is the boundary a fresh attach
// takes, so the atomic snapshot still goes out and the attach stays fast.
func TestCatchUpOutputCursorReseedsInsteadOfCrawlingAnIncomparableGap(t *testing.T) {
	runtime, client := startGhostlineRuntime(t)
	const runtimeName = "warren_catchup_unit"
	const sessionID = "session-catchup-unit"
	stale, head := seedGenerationBoundary(t, runtime, client, runtimeName)

	logger := slog.New(&recordHandler{})
	state := newStateWithSession(t, sessionID, runtimeName)
	recording := &countingCursorRuntime{GhostlineRuntime: runtime}
	service := &Service{
		Store:          state,
		Runtime:        recording,
		DefaultRuntime: "ghostline",
		CommandTimeout: 3 * time.Second,
		Logger:         logger,
	}
	session := state.Snapshot().Sessions[0]
	ringState, err := service.ensureOutput(context.Background(), session)
	if err != nil {
		t.Fatalf("ensure output: %v", err)
	}
	waitForCursorAt(t, ringState, head)
	// Stop the shared reader so it cannot record over the poisoned cursor, then
	// put the ring behind the generation boundary the checkpoint crossed.
	service.stopCursorOutput(ringState)
	ringState.mu.Lock()
	ringState.outputCursor = stale
	ringState.mu.Unlock()
	opensBefore := len(recording.opens())

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	started := time.Now()
	skipped, err := service.catchUpOutputCursor(ctx, session, ringState, head)
	elapsed := time.Since(started)
	if err != nil {
		t.Fatalf("incomparable gap returned an error: %v", err)
	}
	if !skipped {
		t.Fatal("incomparable gap was not reported as skipped")
	}
	if elapsed > time.Second {
		t.Fatalf("catch-up took %s for a gap it cannot walk", elapsed)
	}
	if opens := recording.opens(); len(opens) != opensBefore {
		t.Fatalf("catch-up opened a reader at %v for an incomparable gap", opens[opensBefore:])
	}
	ringState.mu.Lock()
	reseeded := ringState.outputCursor
	ringState.mu.Unlock()
	if reseeded != head {
		t.Fatalf("ring cursor = %q, want the checkpoint %q", reseeded.String(), head.String())
	}
	handler := logger.Handler().(*recordHandler)
	if value, ok := handler.attr("reanchor: catchUpSkipped", "from"); !ok || value.String() != stale.String() {
		t.Fatalf("skipped catch-up did not report its origin cursor: %v", value)
	}
	if value, ok := handler.attr("reanchor: catchUpSkipped", "distanceKnown"); !ok || value.Bool() {
		t.Fatalf("skipped catch-up did not report distanceKnown=false: %v", value)
	}
	for _, message := range handler.messages() {
		if message == "reanchor: catchUp" {
			t.Fatal("an incomparable gap was walked")
		}
	}
}

// A cold attach whose ring cursor is incomparable with the checkpoint must still
// produce a complete snapshot anchor. Anything else leaves the client waiting
// for a recovery marker that never arrives, which is the black pane.
func TestColdAttachWithIncomparableCursorStillSendsASnapshotAnchor(t *testing.T) {
	runtime, client := startGhostlineRuntime(t)
	const runtimeName = "warren_catchup_attach"
	const sessionID = "session-catchup-attach"
	stale, head := seedGenerationBoundary(t, runtime, client, runtimeName)

	logger := slog.New(&recordHandler{})
	state := newStateWithSession(t, sessionID, runtimeName)
	service := &Service{
		Store:          state,
		Runtime:        runtime,
		DefaultRuntime: "ghostline",
		CommandTimeout: 3 * time.Second,
		Logger:         logger,
	}
	session := state.Snapshot().Sessions[0]
	ringState, err := service.ensureOutput(context.Background(), session)
	if err != nil {
		t.Fatalf("ensure output: %v", err)
	}
	// Let the shared reader reach the head, then poison its recorded cursor.
	// The session is quiet afterwards, so the reader cannot record over it
	// before the attach stops it.
	waitForCursorAt(t, ringState, head)
	ringState.mu.Lock()
	ringState.outputCursor = stale
	ringState.mu.Unlock()

	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", logger).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnectionWithStateFormat(
		t,
		httpServer.URL,
		"/v1/ws",
		nil,
		ghostline.AtomicStateFormat,
	)
	defer connection.Close()

	started := time.Now()
	_ = requestResultBeforeBinary[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
		"id": sessionID, "claim": true, "cols": 80, "rows": 24,
	})
	attached := readBrowserMessage(t, connection, "attached")
	if attached["reanchor"] != true {
		t.Fatalf("attached message = %#v, want reanchor", attached)
	}
	atomicState := readAtomicStateFrame(t, connection)
	if atomicState.SessionID != sessionID || len(atomicState.Payload) == 0 {
		t.Fatalf("atomic state = %#v, want a snapshot for %s", atomicState, sessionID)
	}
	synced := readBrowserMessage(t, connection, "synced")
	if anchorFromMessage(t, synced) != anchorFromMessage(t, attached) {
		t.Fatalf("synced marker %#v does not match the attachment %#v", synced, attached)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("attach took %s for a gap it cannot walk", elapsed)
	}
	handler := logger.Handler().(*recordHandler)
	if value, ok := handler.attr("reanchor: catchUpSkipped", "from"); !ok || value.String() != stale.String() {
		t.Fatalf("the attach did not report the skipped catch-up with its origin cursor: %v", value)
	}
	for _, message := range handler.messages() {
		if message == "reanchor: catchUp" {
			t.Fatal("an incomparable gap was walked during the attach")
		}
	}
}

// waitForCursorAt waits until the shared reader recorded cursor, which proves
// the backlog has been drained and the reader will not overwrite a poisoned
// cursor before the attach stops it.
func waitForCursorAt(t *testing.T, outputSession *outputSession, cursor ghostline.Cursor) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		outputSession.mu.Lock()
		current := outputSession.outputCursor
		outputSession.mu.Unlock()
		if current == cursor {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	outputSession.mu.Lock()
	current := outputSession.outputCursor
	outputSession.mu.Unlock()
	t.Fatalf("shared reader cursor = %q, want %q", current.String(), cursor.String())
}
