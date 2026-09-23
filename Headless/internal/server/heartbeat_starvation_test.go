package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// blockingAgentController holds SendMessage until the test releases it, standing
// in for a provider that is busy for seconds.
type blockingAgentController struct {
	recordingAgentViewController
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (c *blockingAgentController) SendMessage(_ context.Context, _ api.AgentMessageSendRequest) error {
	c.once.Do(func() { close(c.entered) })
	<-c.release
	return nil
}

// A turn can sit inside the provider for seconds. While it ran on the WebSocket
// reader it delayed every later command on the same connection, including the
// application heartbeat: the pong missed its 10s deadline and the client closed
// a socket that was perfectly healthy. This is the regression that put
// `agent.turn.*` on the ordered dispatcher.
func TestSlowTurnDoesNotStarveTheHeartbeatPong(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "starvation-test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "starvation-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "codex", Runtime: "runtime", Lifecycle: "running",
			Title: "Codex", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	controller := &blockingAgentController{
		entered: make(chan struct{}),
		release: make(chan struct{}),
	}
	service := &Service{Store: state, AgentController: controller}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	execution, ok := service.canonicalExecutionForSession(sessionID)
	if !ok || execution.ID == "" {
		t.Fatal("agent execution identity was not created")
	}
	defer close(controller.release)

	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnectionWithCapabilities(
		t, httpServer.URL, "/v1/ws", []string{api.CapabilityAppHeartbeat},
	)
	defer connection.Close()

	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: "turn-1", Method: "agent.turn.start",
		Params: map[string]any{
			"commandId":   "cmd-1",
			"executionId": execution.ID,
			"text":        "take your time",
		},
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-controller.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the turn never reached the provider")
	}

	// The turn is now parked inside the provider. A ping sent after it must still
	// be answered: the reader is free precisely because the turn left it.
	if err := connection.WriteJSON(api.Envelope{Type: "ping", ID: "ping-1"}); err != nil {
		t.Fatal(err)
	}
	_ = connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		_, payload, err := connection.ReadMessage()
		if err != nil {
			t.Fatalf("pong never arrived while a turn was in flight: %v", err)
		}
		var message struct {
			Type string `json:"t"`
			ID   string `json:"id"`
		}
		if json.Unmarshal(payload, &message) != nil {
			continue
		}
		if message.Type == "pong" && message.ID == "ping-1" {
			return
		}
		if message.Type == "result" && message.ID == "turn-1" {
			t.Fatal("the turn answered before the pong, so it was still on the reader")
		}
	}
}

// Ordering is the reason these requests are queued rather than simply
// backgrounded: a CLI consumes injected input in arrival order, so two turns
// sent back to back must reach the provider in that order even though neither
// runs on the reader.
func TestPipelinedTurnsReachTheProviderInOrder(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "ordering-test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "ordering-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "codex", Runtime: "runtime", Lifecycle: "running",
			Title: "Codex", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	controller := &orderRecordingController{seen: make(chan string, 8)}
	service := &Service{Store: state, AgentController: controller}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	execution, ok := service.canonicalExecutionForSession(sessionID)
	if !ok {
		t.Fatal("agent execution identity was not created")
	}

	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	want := []string{"first", "second", "third"}
	for index, text := range want {
		if err := connection.WriteJSON(api.Envelope{
			Type: "request", ID: "turn-" + text, Method: "agent.turn.start",
			Params: map[string]any{
				"commandId":   "cmd-" + text,
				"executionId": execution.ID,
				"text":        text,
			},
		}); err != nil {
			t.Fatalf("send %d: %v", index, err)
		}
	}
	for _, expected := range want {
		select {
		case got := <-controller.seen:
			if got != expected {
				t.Fatalf("provider saw %q, want %q: pipelined turns were reordered", got, expected)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("provider never saw %q", expected)
		}
	}
}

type orderRecordingController struct {
	recordingAgentViewController
	seen chan string
}

func (c *orderRecordingController) SendMessage(_ context.Context, value api.AgentMessageSendRequest) error {
	// A small delay widens the window a reordering bug would need to slip
	// through, so the assertion is not merely observing a fast happy path.
	time.Sleep(15 * time.Millisecond)
	c.seen <- value.Text
	return nil
}

var _ = websocket.TextMessage
