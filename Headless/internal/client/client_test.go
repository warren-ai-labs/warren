package client

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

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
		if err := connection.WriteJSON(map[string]any{"t": "welcome"}); err != nil {
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
		messages []api.AgentTurnMessage
		want     api.AgentTurn
	}{
		{
			name:  "next turn",
			after: 3,
			messages: []api.AgentTurnMessage{
				{Type: "agent.turn", Session: "session-1", Epoch: 7, Turn: 4, Status: api.AgentTurnStarted},
				{Type: "agent.turn", Session: "session-1", Epoch: 7, Turn: 4, Status: api.AgentTurnCompleted},
			},
			want: api.AgentTurn{ID: 4, Status: api.AgentTurnCompleted},
		},
		{
			name:    "current turn",
			after:   3,
			current: 3,
			messages: []api.AgentTurnMessage{
				{Type: "agent.turn", Session: "session-1", Epoch: 7, Turn: 3, Status: api.AgentTurnFailed},
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
				if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome"}) != nil {
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
			got, err := value.WaitAgentTurn(ctx, "session-1", 7, test.after, test.current)
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
		if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome"}) != nil {
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
	_, err = value.WaitAgentTurn(ctx, "session-1", 1, 0, 0)
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
		if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome"}) != nil {
			return
		}
		if connection.ReadJSON(&envelope) != nil {
			return
		}
		if connection.WriteJSON(api.AgentTurnMessage{
			Type: "agent.turn", Session: "session-1", Epoch: 9, Turn: 1, Status: api.AgentTurnCompleted,
		}) != nil {
			return
		}
		_ = connection.WriteJSON(map[string]any{
			"t": "response", "id": envelope["id"], "ok": true,
			"result": api.AgentSnapshotResult{Epoch: 9, Turn: api.AgentTurn{Status: api.AgentTurnIdle}},
		})
		<-r.Context().Done()
	}))
	defer server.Close()

	value, err := Dial(context.Background(), server.URL, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()
	if _, err := value.AgentSnapshot(context.Background(), "session-1"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	turn, err := value.WaitAgentTurn(ctx, "session-1", 9, 0, 0)
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
		if connection.ReadJSON(&envelope) != nil || connection.WriteJSON(map[string]any{"t": "welcome"}) != nil {
			return
		}
		_ = connection.WriteJSON(api.AgentStatusMessage{
			Type: "agent.status", Session: "session-1", Epoch: 2,
			Status: api.AgentStatus{Activity: api.AgentActivityExited},
		})
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
	_, err = value.WaitAgentTurn(ctx, "session-1", 2, 0, 0)
	if err == nil || !strings.Contains(err.Error(), "agent process exited") {
		t.Fatalf("exit error = %v", err)
	}
}
