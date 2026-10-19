package server

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/gorilla/websocket"
)

// openTerminalSizeConnection subscribes one Desktop-shaped peer: atomic state
// recovery plus the given capabilities, claiming the size at cols x rows.
func openTerminalSizeConnection(
	t *testing.T,
	capabilities []string,
	sessionID, runtimeName string,
	runtime *GhostlineRuntime,
	columns, rows int,
) (*websocket.Conn, map[string]any, output.Anchor) {
	t.Helper()
	state := newStateWithSession(t, sessionID, runtimeName)
	service := &Service{Store: state, Runtime: runtime, DefaultRuntime: "ghostline"}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	t.Cleanup(httpServer.Close)
	connection := openAuthenticatedConnectionWithStateFormat(t, httpServer.URL, "/v1/ws", capabilities, ghostline.AtomicStateFormat)
	t.Cleanup(func() { _ = connection.Close() })
	_ = requestResultBeforeBinary[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
		"id": sessionID, "claim": true, "cols": columns, "rows": rows,
	})
	attached := readBrowserMessage(t, connection, "attached")
	atomicState := readAtomicStateFrame(t, connection)
	readBrowserMessage(t, connection, "synced")
	return connection, attached, output.Anchor{Epoch: atomicState.Epoch, Sequence: atomicState.Sequence}
}

func startWinchReporter(t *testing.T, runtime *GhostlineRuntime, runtimeName string) {
	t.Helper()
	if err := runtime.Create(context.Background(), runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}
	// Answer every SIGWINCH with the new size, the way a TUI redraws.
	// The quotes keep the input echo from matching the readiness marker, so
	// the wait ends only once the trap is installed. Job control is off so
	// the loop's sleep shares the shell's process group and the shell itself
	// receives SIGWINCH.
	if err := runtime.Input(context.Background(), runtimeName, []byte("set +m; trap 'stty size' WINCH; echo winch-''ready; while :; do sleep 0.01; done\r")); err != nil {
		t.Fatalf("start reporter: %v", err)
	}
	waitGhostlineOutput(t, runtime, runtimeName, "winch-ready")
}

func TestTerminalSizePeerReceivesResizedAtTheOutputBoundary(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	const runtimeName, sessionID = "warren_terminal_size", "session-terminal-size"
	startWinchReporter(t, runtime, runtimeName)
	connection, attached, anchor := openTerminalSizeConnection(
		t, []string{api.CapabilityTerminalSize}, sessionID, runtimeName, runtime, 80, 24,
	)
	if attached["cols"] != float64(80) || attached["rows"] != float64(24) {
		t.Fatalf("attached = %#v, want the 80x24 grid at the anchor", attached)
	}

	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: "resize", Method: "session.resize", Params: map[string]any{
		"id": sessionID, "cols": 101, "rows": 31,
	}}); err != nil {
		t.Fatal(err)
	}

	// Output is laid out by sequence. The resize must name the exact sequence
	// at which the child's answer for the new size begins.
	stream := map[uint64][]byte{}
	var resizedAt uint64
	var resized bool
	answer := []byte("31 101")
	deadline := time.Now().Add(5 * time.Second)
	for {
		_ = connection.SetReadDeadline(deadline)
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("did not receive the resize answer: %v", err)
		}
		if kind == websocket.TextMessage {
			var event map[string]any
			if json.Unmarshal(data, &event) == nil && event["t"] == "resized" {
				if resized {
					t.Fatalf("second resized event: %#v", event)
				}
				if event["cols"] != float64(101) || event["rows"] != float64(31) {
					t.Fatalf("resized = %#v, want 101x31", event)
				}
				at := anchorFromMessage(t, event)
				if at.Epoch != anchor.Epoch || at.Sequence < anchor.Sequence {
					t.Fatalf("resized at %v, before the attach anchor %v", at, anchor)
				}
				resizedAt, resized = at.Sequence, true
			}
			continue
		}
		frame, err := output.DecodeOutput(data)
		if err != nil {
			continue
		}
		stream[frame.Sequence] = append([]byte(nil), frame.Payload...)
		joined, start := joinOutput(stream, anchor.Sequence)
		index := bytes.Index(joined, answer)
		if index < 0 {
			continue
		}
		if !resized {
			t.Fatal("the child's answer for the new size arrived before the resized event")
		}
		if position := start + uint64(index); position < resizedAt {
			t.Fatalf("answer at sequence %d precedes the resize at %d", position, resizedAt)
		}
		return
	}
}

func TestTerminalSizeIsOmittedForPeersThatDidNotNegotiateIt(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	const runtimeName, sessionID = "warren_terminal_size_legacy", "session-terminal-size-legacy"
	startWinchReporter(t, runtime, runtimeName)
	connection, attached, _ := openTerminalSizeConnection(t, nil, sessionID, runtimeName, runtime, 80, 24)
	if _, ok := attached["cols"]; ok {
		t.Fatalf("attached = %#v, want no size for a legacy peer", attached)
	}
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: "resize", Method: "session.resize", Params: map[string]any{
		"id": sessionID, "cols": 101, "rows": 31,
	}}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	var received []byte
	for !bytes.Contains(received, []byte("31 101")) {
		_ = connection.SetReadDeadline(deadline)
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("did not receive the resize answer: %v", err)
		}
		if kind == websocket.TextMessage {
			var event map[string]any
			if json.Unmarshal(data, &event) == nil && event["t"] == "resized" {
				t.Fatalf("legacy peer received %#v", event)
			}
			continue
		}
		if frame, err := output.DecodeOutput(data); err == nil {
			received = append(received, frame.Payload...)
		}
	}
}

// joinOutput concatenates contiguous frames from start and reports the
// sequence of the first byte.
func joinOutput(stream map[uint64][]byte, start uint64) ([]byte, uint64) {
	var joined []byte
	next := start
	for {
		payload, ok := stream[next]
		if !ok {
			return joined, start
		}
		joined = append(joined, payload...)
		next += uint64(len(payload))
	}
}
