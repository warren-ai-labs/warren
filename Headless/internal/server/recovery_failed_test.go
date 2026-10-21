package server

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

// failingAtomicStateRuntime fails the recovery payload the way a broken native
// snapshot does: after the subscription has already been acknowledged.
type failingAtomicStateRuntime struct {
	*GhostlineRuntime
}

func (r *failingAtomicStateRuntime) AtomicState(context.Context, string) (ghostline.AtomicState, error) {
	return ghostline.AtomicState{}, errors.New("atomic state unavailable")
}

// The subscription acknowledgement is on the wire before the recovery payload,
// so a later failure cannot be delivered on that command. It must arrive as a
// session-scoped event instead; otherwise the client waits for a recovery
// marker that will never come and the pane stays black until a restart.
func TestSubscribeFailureAfterAcknowledgementEmitsRecoveryFailed(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	const runtimeName = "warren_recovery_failed"
	const sessionID = "session-recovery-failed"
	ctx := context.Background()
	if err := runtime.Create(ctx, runtimeName, t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("create ghostline session: %v", err)
	}

	logger := slog.New(&recordHandler{})
	state := newStateWithSession(t, sessionID, runtimeName)
	service := &Service{
		Store:          state,
		Runtime:        &failingAtomicStateRuntime{GhostlineRuntime: runtime},
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

	// The acknowledgement must still be a success: the client needs the control
	// lease and the attachment identity before the payload exists.
	result := requestResultBeforeBinary[terminalSubscriptionResult](t, connection, "session.subscribe", map[string]any{
		"id": sessionID, "claim": true, "cols": 80, "rows": 24,
	})
	if !result.Subscribed || result.AttachmentID == "" {
		t.Fatalf("subscription result = %#v, want an attachment", result)
	}

	failed := readBrowserMessage(t, connection, "recoveryFailed")
	if failed["session"] != sessionID {
		t.Fatalf("recoveryFailed session = %v, want %s", failed["session"], sessionID)
	}
	reason, _ := failed["reason"].(string)
	if reason == "" {
		t.Fatalf("recoveryFailed carried no reason: %#v", failed)
	}

	// The command id was already retired by the client, so no error response may
	// follow for it; a late error would be dropped and hide the failure.
	_ = connection.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
	for {
		kind, data, err := connection.ReadMessage()
		if err != nil {
			break
		}
		if kind != websocket.TextMessage {
			continue
		}
		var response api.Response
		if json.Unmarshal(data, &response) == nil && response.Type == "response" && !response.OK {
			t.Fatalf("an error response was written for the retired command: %#v", response)
		}
	}
	_ = connection.SetReadDeadline(time.Time{})
	handler := logger.Handler().(*recordHandler)
	if _, ok := handler.attr("subscribe: recovery failed", "session"); !ok {
		t.Fatal("the daemon did not log the post-acknowledgement failure")
	}
}
