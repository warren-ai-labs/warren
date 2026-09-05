package client

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

func TestDialRelayUsesScopedPathAndAccessAuthentication(t *testing.T) {
	upgrader := websocket.Upgrader{}
	observed := make(chan struct {
		path string
		auth map[string]any
	}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		connection, err := upgrader.Upgrade(writer, request, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var auth map[string]any
		if connection.ReadJSON(&auth) != nil {
			return
		}
		observed <- struct {
			path string
			auth map[string]any
		}{path: request.URL.Path, auth: auth}
		_ = connection.WriteJSON(map[string]any{"t": "welcome", "version": api.Version, "host": map[string]any{"id": t.Name()}, "accessScopeId": "test-scope"})
		<-request.Context().Done()
	}))
	defer server.Close()

	value, err := DialRelay(context.Background(), server.URL+"/relay/", "00000000-0000-4000-8000-000000000001", "access-token")
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()
	result := <-observed
	if result.path != "/relay/h/00000000-0000-4000-8000-000000000001/v1/client/connect" {
		t.Fatalf("path = %q, want scoped Relay path", result.path)
	}
	if result.auth["t"] != "auth" || result.auth["version"] != "3.0" || result.auth["access_token"] != "access-token" {
		t.Fatalf("unexpected Relay auth: %#v", result.auth)
	}
	if _, ok := result.auth["client_id"].(string); !ok {
		t.Fatalf("Relay auth missing client_id: %#v", result.auth)
	}
	if formats, ok := result.auth["terminalStateFormats"].([]any); !ok || len(formats) != 1 || formats[0] != terminalStateFormatANSI {
		t.Fatalf("Relay auth formats = %#v", result.auth["terminalStateFormats"])
	}
}

func TestRelayEndpointDoesNotDuplicateScopedPath(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000001"
	endpoint, err := relayEndpoint(
		"https://relay.example.test/relay/h/"+hostID+"/v1/client/connect/",
		hostID,
	)
	if err != nil {
		t.Fatal(err)
	}
	if endpoint != "wss://relay.example.test/relay/h/"+hostID+"/v1/client/connect" {
		t.Fatalf("endpoint = %q", endpoint)
	}
}

func TestRelayEndpointRejectsUnsafeURLs(t *testing.T) {
	for _, raw := range []string{
		"relay.example.test",
		"ftp://relay.example.test",
		"https://relay.example.test?token=secret",
		"https://relay.example.test/../private",
		"https://user:pass@relay.example.test",
	} {
		if endpoint, err := relayEndpoint(raw, "host"); err == nil {
			t.Errorf("relayEndpoint(%q) accepted %q", raw, endpoint)
		}
	}
	if endpoint, err := relayEndpoint("https://relay.example.test", "host/id"); err == nil {
		t.Errorf("relayEndpoint accepted unsafe host ID as %q", endpoint)
	}
}

func TestReadOutputHonorsContextDeadline(t *testing.T) {
	release := make(chan struct{})
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var envelope map[string]any
		if err := connection.ReadJSON(&envelope); err != nil {
			return
		}
		if err := connection.WriteJSON(map[string]any{"t": "welcome", "version": api.Version, "host": map[string]any{"id": t.Name()}, "accessScopeId": "test-scope"}); err != nil {
			return
		}
		// Hold the connection open without sending terminal output.
		select {
		case <-release:
		case <-time.After(10 * time.Second):
		}
	}))
	defer server.Close()
	defer close(release)

	dialContext, cancelDial := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelDial()
	value, err := Dial(dialContext, server.URL, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()

	readContext, cancelRead := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancelRead()
	started := time.Now()
	err = value.ReadOutput(readContext, func([]byte) bool { return false })
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("ReadOutput error = %v, want context.DeadlineExceeded", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("ReadOutput took %s, want it to return shortly after the deadline", elapsed)
	}
}

func TestWaitAgentTurnHandlesCurrentAndNextTurns(t *testing.T) {
	tests := []struct {
		name     string
		after    uint64
		current  uint64
		messages []api.CanonicalAgentEventsMessage
		want     api.AgentTurn
	}{
		{
			name:  "next turn",
			after: 3,
			messages: []api.CanonicalAgentEventsMessage{
				canonicalTurnBatch(4, "started"),
				canonicalTurnBatch(4, "completed"),
			},
			want: api.AgentTurn{ID: 4, Status: api.AgentTurnCompleted},
		},
		{
			name:    "current turn",
			after:   3,
			current: 3,
			messages: []api.CanonicalAgentEventsMessage{
				canonicalTurnBatch(3, "failed"),
			},
			want: api.AgentTurn{ID: 3, Status: api.AgentTurnFailed},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			upgrader := websocket.Upgrader{}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				connection, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer connection.Close()
				var envelope map[string]any
				if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome", "version": api.Version, "host": map[string]any{"id": t.Name()}, "accessScopeId": "test-scope"}) != nil {
					return
				}
				for _, message := range test.messages {
					if connection.WriteJSON(message) != nil {
						return
					}
				}
				<-r.Context().Done()
			}))
			defer server.Close()

			value, err := Dial(context.Background(), server.URL, "secret")
			if err != nil {
				t.Fatal(err)
			}
			defer value.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			got, err := value.WaitAgentTurn(ctx, "session-1", "exec-1", test.after, test.current)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("turn = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestWaitAgentTurnHonorsContextDeadline(t *testing.T) {
	release := make(chan struct{})
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var envelope map[string]any
		if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome", "version": api.Version, "host": map[string]any{"id": t.Name()}, "accessScopeId": "test-scope"}) != nil {
			return
		}
		<-release
	}))
	defer server.Close()
	defer close(release)

	value, err := Dial(context.Background(), server.URL, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err = value.WaitAgentTurn(ctx, "session-1", "exec-1", 0, 0)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("WaitAgentTurn error = %v, want deadline exceeded", err)
	}
}

func TestRequestPreservesAgentTurnArrivingBeforeResponse(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var envelope map[string]any
		if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome", "version": api.Version, "host": map[string]any{"id": t.Name()}, "accessScopeId": "test-scope"}) != nil {
			return
		}
		if connection.ReadJSON(&envelope) != nil {
			return
		}
		if connection.WriteJSON(canonicalTurnBatch(1, "completed")) != nil {
			return
		}
		_ = connection.WriteJSON(map[string]any{
			"t": "response", "id": envelope["id"], "ok": true,
			"result": api.AgentExecution{ID: "exec-1", StreamID: "exec-1"},
		})
		<-r.Context().Done()
	}))
	defer server.Close()

	value, err := Dial(context.Background(), server.URL, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()
	if _, err := value.AgentExecution(context.Background(), "exec-1"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	turn, err := value.WaitAgentTurn(ctx, "session-1", "exec-1", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if turn != (api.AgentTurn{ID: 1, Status: api.AgentTurnCompleted}) {
		t.Fatalf("turn = %#v, want preserved completion", turn)
	}
}

func TestWaitAgentTurnReportsAgentProcessExit(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var envelope map[string]any
		if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome", "version": api.Version, "host": map[string]any{"id": t.Name()}, "accessScopeId": "test-scope"}) != nil {
			return
		}
		_ = connection.WriteJSON(canonicalExitBatch())
		<-r.Context().Done()
	}))
	defer server.Close()

	value, err := Dial(context.Background(), server.URL, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, err = value.WaitAgentTurn(ctx, "session-1", "exec-1", 0, 0)
	if err == nil || !strings.Contains(err.Error(), "agent process exited") {
		t.Fatalf("exit error = %v", err)
	}
}

func canonicalTurnBatch(turn uint64, status string) api.CanonicalAgentEventsMessage {
	sequence := turn * 2
	if status == "started" {
		sequence--
	}
	return api.CanonicalAgentEventsMessage{Type: "agent.events", StreamID: "exec-1", Events: []api.CanonicalAgentEvent{{
		EventID: fmt.Sprintf("evt-%d", sequence), StreamID: "exec-1", ExecutionID: "exec-1", Sequence: sequence,
		TurnID: fmt.Sprint(turn), Type: "turn." + status, Payload: map[string]any{},
		OccurredAt: time.Unix(1, 0).UTC(), RecordedAt: time.Unix(1, 0).UTC(), Origin: api.AgentEventOrigin{Kind: "host", Confidence: "native"},
	}}}
}

func canonicalExitBatch() api.CanonicalAgentEventsMessage {
	batch := canonicalTurnBatch(1, "completed")
	batch.Events[0].Type = "status.changed"
	batch.Events[0].Payload = map[string]any{"status": map[string]any{"activity": "exited"}}
	return batch
}
