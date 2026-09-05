package server

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

func TestWebSocketHeartbeatIsCapabilityGated(t *testing.T) {
	state := newStateWithSession(t, "heartbeat-session", "heartbeat-runtime")
	httpServer := httptest.NewServer(NewHTTPServer(&Service{Store: state}, "secret", nil).Handler())
	defer httpServer.Close()

	tests := []struct {
		name         string
		capabilities []string
		wantPong     bool
	}{
		{name: "negotiated", capabilities: []string{api.CapabilityAppHeartbeat}, wantPong: true},
		{name: "legacy client", capabilities: nil, wantPong: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			connection := openAuthenticatedConnectionWithCapabilities(
				t, httpServer.URL, "/v1/ws", test.capabilities,
			)
			defer connection.Close()
			waitForRoster(t, connection, func(api.State) bool { return true })

			pingID := store.NewID()
			if err := connection.WriteJSON(api.Envelope{Type: "ping", ID: pingID}); err != nil {
				t.Fatal(err)
			}
			if test.wantPong {
				pong := readBrowserMessage(t, connection, "pong")
				if pong["id"] != pingID {
					t.Fatalf("pong id = %#v, want %q", pong["id"], pingID)
				}
				return
			}

			assertNoWebSocketPong(t, connection, pingID)
		})
	}
}

func assertNoWebSocketPong(t *testing.T, connection *websocket.Conn, pingID string) {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
	defer connection.SetReadDeadline(time.Time{})
	for {
		_, data, err := connection.ReadMessage()
		if err != nil {
			var networkError net.Error
			if errors.As(err, &networkError) && networkError.Timeout() {
				return
			}
			t.Fatalf("reading legacy heartbeat response: %v", err)
		}
		var message map[string]any
		if json.Unmarshal(data, &message) == nil && message["t"] == "pong" && message["id"] == pingID {
			t.Fatalf("legacy client unexpectedly received pong: %#v", message)
		}
	}
}

func TestRelayControlHeartbeatIsCapabilityGated(t *testing.T) {
	tests := []struct {
		name         string
		capabilities []string
		wantPong     bool
	}{
		{name: "negotiated", capabilities: []string{api.CapabilityAppHeartbeat}, wantPong: true},
		{name: "legacy client", capabilities: nil, wantPong: false},
	}
	for index, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state := newStateWithSession(t, "relay-heartbeat-session", "relay-heartbeat-runtime")
			server := NewHTTPServer(&Service{Store: state}, "secret", nil)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			var streamID relay.ConnectionID
			streamID[0] = byte(index + 1)
			frames := make(chan relay.Frame, 16)
			send := func(value relay.Frame) error {
				frames <- value
				return nil
			}
			open := relay.StreamOpen{
				Class: "control", Version: api.Version, ClientID: "client-1", Token: "relay-access",
			}
			if err := server.HandleRelayControl(ctx, open, relay.Frame{Kind: relay.FrameOpen, ID: streamID}, send); err != nil {
				t.Fatalf("open control stream: %v", err)
			}
			auth, err := json.Marshal(map[string]any{
				"t":                    "auth",
				"access_token":         "relay-access",
				"client_id":            "client-1",
				"version":              api.Version,
				"capabilities":         test.capabilities,
				"terminalStateFormats": []string{"ghostline-vt-replay-v1"},
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := server.HandleRelayControl(ctx, open, relay.Frame{Kind: relay.FrameText, ID: streamID, Payload: auth}, send); err != nil {
				t.Fatalf("authenticate control stream: %v", err)
			}
			readRelayJSON(t, frames, "welcome")
			readRelayJSON(t, frames, "roster")

			pingID := store.NewID()
			ping, err := json.Marshal(api.Envelope{Type: "ping", ID: pingID})
			if err != nil {
				t.Fatal(err)
			}
			if err := server.HandleRelayControl(ctx, open, relay.Frame{Kind: relay.FrameText, ID: streamID, Payload: ping}, send); err != nil {
				t.Fatalf("send ping: %v", err)
			}
			if test.wantPong {
				pong := readRelayJSON(t, frames, "pong")
				if pong["id"] != pingID {
					t.Fatalf("pong id = %#v, want %q", pong["id"], pingID)
				}
			} else {
				assertNoRelayPong(t, frames, pingID)
			}

			if err := server.HandleRelayControl(ctx, open, relay.Frame{Kind: relay.FrameClose, ID: streamID}, send); err != nil {
				t.Fatalf("close control stream: %v", err)
			}
		})
	}
}

func readRelayJSON(t *testing.T, frames <-chan relay.Frame, messageType string) map[string]any {
	t.Helper()
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	for {
		select {
		case frame := <-frames:
			if frame.Kind != relay.FrameText {
				continue
			}
			var message map[string]any
			if json.Unmarshal(frame.Payload, &message) == nil && message["t"] == messageType {
				return message
			}
		case <-deadline.C:
			t.Fatalf("timed out waiting for Relay %s", messageType)
		}
	}
}

func assertNoRelayPong(t *testing.T, frames <-chan relay.Frame, pingID string) {
	t.Helper()
	timer := time.NewTimer(250 * time.Millisecond)
	defer timer.Stop()
	for {
		select {
		case frame := <-frames:
			if frame.Kind != relay.FrameText {
				continue
			}
			var message map[string]any
			if json.Unmarshal(frame.Payload, &message) == nil && message["t"] == "pong" && message["id"] == pingID {
				t.Fatalf("legacy Relay client unexpectedly received pong: %#v", message)
			}
		case <-timer.C:
			return
		}
	}
}
