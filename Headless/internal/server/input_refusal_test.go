package server

import (
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

// nextResponse reads messages until a response with the wanted code arrives.
func nextResponseWithCode(t *testing.T, connection *websocket.Conn, code string) api.Response {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	defer connection.SetReadDeadline(time.Time{})
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.TextMessage {
			continue
		}
		var response api.Response
		if json.Unmarshal(data, &response) != nil || response.Type != "response" {
			continue
		}
		if response.Code == code {
			return response
		}
	}
}

// A refused DENB input frame carries no request id, so the error must name the
// terminal it was aimed at. Without that a client can only drop an anonymous
// failure, which is how input used to disappear without a trace.
func TestRefusedInputNamesTheSessionAndAttachment(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	const runtimeName = "warren_input_refusal"
	const sessionID = "session-input-refusal"
	ctx := context.Background()
	if err := runtime.Create(ctx, runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}

	logger := slog.New(&recordHandler{})
	state := newStateWithSession(t, sessionID, runtimeName)
	service := &Service{
		Store:          state,
		Runtime:        runtime,
		DefaultRuntime: "ghostline",
		Logger:         logger,
	}
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

	subscription := requestResultBeforeBinary[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
		"id": sessionID, "claim": true, "cols": 80, "rows": 24,
	})
	if subscription.AttachmentID == "" {
		t.Fatal("subscription returned no attachment")
	}
	_ = readBrowserMessage(t, connection, "attached")
	_ = readAtomicStateFrame(t, connection)
	_ = readBrowserMessage(t, connection, "synced")

	// Releasing focus leaves the attachment in place but takes the input lease
	// away, which is the state a stolen lease leaves a client in.
	_ = requestResultBeforeBinary[map[string]any](t, connection, "session.focus", map[string]any{
		"id": sessionID, "focused": false,
	})

	frame, err := output.EncodeInput(output.InputMetadata{
		Version:      api.Version,
		SessionID:    sessionID,
		AttachmentID: subscription.AttachmentID,
	}, []byte("x"))
	if err != nil {
		t.Fatalf("encode input: %v", err)
	}
	if err := connection.WriteMessage(websocket.BinaryMessage, frame); err != nil {
		t.Fatal(err)
	}

	rejection := nextResponseWithCode(t, connection, "input_rejected")
	if rejection.Session != sessionID {
		t.Fatalf("rejection session = %q, want %s", rejection.Session, sessionID)
	}
	if rejection.AttachmentID != subscription.AttachmentID {
		t.Fatalf("rejection attachment = %q, want %s", rejection.AttachmentID, subscription.AttachmentID)
	}
	if rejection.Error == "" {
		t.Fatalf("rejection carried no reason: %#v", rejection)
	}
}
