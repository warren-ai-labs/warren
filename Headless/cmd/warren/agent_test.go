package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// fakeAgentHost answers the canonical Agent requests the CLI makes and records
// the commands it receives, so the CLI's turns can be driven without a daemon.
type fakeAgentHost struct {
	session    api.Session
	execution  api.AgentExecution
	checkpoint api.AgentProjectionCheckpoint
	// batches are pushed to a connection once it subscribes to the stream.
	batches []api.CanonicalAgentEventsMessage
	// history is returned for agent.events.history.
	history []api.CanonicalAgentEvent

	mu       sync.Mutex
	received []fakeAgentRequest
}

type fakeAgentRequest struct {
	method string
	params map[string]any
}

func (h *fakeAgentHost) requests(method string) []map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	var result []map[string]any
	for _, request := range h.received {
		if request.method == method {
			result = append(result, request.params)
		}
	}
	return result
}

func (h *fakeAgentHost) serve(t *testing.T) *httptest.Server {
	t.Helper()
	upgrader := websocket.Upgrader{}
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
		if err := connection.WriteJSON(map[string]any{
			"t": "welcome", "version": api.Version,
			"host": map[string]any{"id": store.NewID()}, "accessScopeId": store.NewID(),
		}); err != nil {
			return
		}
		for {
			var command struct {
				Type   string         `json:"t"`
				ID     string         `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if connection.ReadJSON(&command) != nil {
				return
			}
			if command.Type != "request" {
				continue
			}
			h.mu.Lock()
			h.received = append(h.received, fakeAgentRequest{method: command.Method, params: command.Params})
			h.mu.Unlock()
			result, err := h.result(command.Method)
			if err != nil {
				_ = connection.WriteJSON(map[string]any{"t": "response", "id": command.ID, "ok": false, "error": err.Error()})
				continue
			}
			if err := connection.WriteJSON(map[string]any{"t": "response", "id": command.ID, "ok": true, "result": result}); err != nil {
				return
			}
			if command.Method == "agent.events.subscribe" {
				for _, batch := range h.batches {
					if err := connection.WriteJSON(batch); err != nil {
						return
					}
				}
			}
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func (h *fakeAgentHost) result(method string) (any, error) {
	switch method {
	case "session.subscribe":
		return map[string]any{"subscribed": true, "attachmentId": "attach-1"}, nil
	case "roster":
		return api.State{Sessions: []api.Session{h.session}}, nil
	case "agent.execution.get":
		return h.execution, nil
	case "agent.events.subscribe":
		return api.AgentEventsSubscriptionResult{
			StreamID: h.execution.StreamID, ExecutionID: h.execution.ID,
			Checkpoint: h.checkpoint, Live: true,
		}, nil
	case "agent.events.history":
		return api.AgentEventsHistoryResult{StreamID: h.execution.StreamID, ExecutionID: h.execution.ID, Events: h.history}, nil
	case "agent.turn.cancel":
		return api.AgentCommandReceipt{CommandID: store.NewID(), Accepted: true}, nil
	default:
		return nil, fmt.Errorf("unexpected method %s", method)
	}
}

func newFakeAgentHost(sessionID, streamID string) *fakeAgentHost {
	return &fakeAgentHost{
		session: api.Session{
			ID: sessionID, Kind: "pi", Command: "pi",
			AgentSessionID: "pi-session-1", AgentExecutionID: streamID,
			Lifecycle: "running",
		},
		execution: api.AgentExecution{
			ID: streamID, StreamID: streamID, Provider: "pi", Driver: AgentHandlerTUIForTest,
			State:  api.AgentExecutionReady,
			Status: api.AgentStatus{Activity: api.AgentActivityReady},
		},
	}
}

// AgentHandlerTUIForTest keeps the fake execution's driver name in one place.
const AgentHandlerTUIForTest = "tui"

func canonicalTurnEventForTest(streamID string, sequence uint64, turn uint64, eventType string) api.CanonicalAgentEvent {
	return api.CanonicalAgentEvent{
		EventID: fmt.Sprintf("%s:%d:%d", eventType, turn, sequence), StreamID: streamID, ExecutionID: streamID,
		Sequence: sequence, TurnID: fmt.Sprint(turn), Type: "turn." + eventType,
		Payload:    map[string]any{"turnId": fmt.Sprint(turn), "status": eventType},
		OccurredAt: time.Unix(int64(sequence), 0).UTC(), RecordedAt: time.Unix(int64(sequence), 0).UTC(),
		Origin: api.AgentEventOrigin{Kind: "host", Confidence: "derived"},
	}
}

func turnBatch(streamID string, sequence uint64, turn uint64, eventType string) api.CanonicalAgentEventsMessage {
	return api.CanonicalAgentEventsMessage{
		Type: "agent.events", StreamID: streamID,
		Events: []api.CanonicalAgentEvent{canonicalTurnEventForTest(streamID, sequence, turn, eventType)},
	}
}

// withFakeHost points the CLI at the fake Host for the duration of the test.
func withFakeHost(t *testing.T, host *fakeAgentHost) {
	t.Helper()
	server := host.serve(t)
	previousURL, previousToken, previousName, previousPath := endpointURL, endpointToken, endpointName, configPath
	endpointURL, endpointToken, endpointName, configPath = server.URL, "test-token", "", ""
	t.Cleanup(func() {
		endpointURL, endpointToken, endpointName, configPath = previousURL, previousToken, previousName, previousPath
	})
}

func TestAgentWaitCursorTargetsOnlyARunningTurn(t *testing.T) {
	tests := []struct {
		name      string
		turn      api.AgentTurn
		wantAfter uint64
		wantTurn  uint64
	}{
		{name: "running turn", turn: api.AgentTurn{ID: 4, Status: api.AgentTurnStarted}, wantAfter: 4, wantTurn: 4},
		// A terminal turn is history. Waiting for turn 3 again would let a
		// replayed boundary end a wait that is meant to watch the work ahead.
		{name: "completed turn", turn: api.AgentTurn{ID: 4, Status: api.AgentTurnCompleted}, wantAfter: 4, wantTurn: 0},
		{name: "interrupted turn", turn: api.AgentTurn{ID: 4, Status: api.AgentTurnInterrupted}, wantAfter: 4, wantTurn: 0},
		{name: "idle agent", turn: api.AgentTurn{}, wantAfter: 0, wantTurn: 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			execution := api.AgentExecution{ActiveTurn: &test.turn}
			if test.turn.ID == 0 {
				execution.ActiveTurn = nil
			}
			after, current := agentWaitCursor(execution)
			if after != test.wantAfter || current != test.wantTurn {
				t.Fatalf("cursor = (%d, %d), want (%d, %d)", after, current, test.wantAfter, test.wantTurn)
			}
		})
	}
}

// The prompt agent create sent can finish before the wait subscribes; its own
// terminal snapshot is then the result the create path must report.
func TestAgentInitialPromptCursorAcceptsTheCompletedPromptTurn(t *testing.T) {
	execution := api.AgentExecution{ActiveTurn: &api.AgentTurn{ID: 1, Status: api.AgentTurnCompleted}}
	after, current := agentInitialPromptCursor(execution)
	if after != 0 || current != 0 {
		t.Fatalf("cursor = (%d, %d), want (0, 0) so the completed snapshot is accepted", after, current)
	}
	running := api.AgentExecution{ActiveTurn: &api.AgentTurn{ID: 1, Status: api.AgentTurnStarted}}
	if after, current := agentInitialPromptCursor(running); after != 1 || current != 1 {
		t.Fatalf("running cursor = (%d, %d), want (1, 1)", after, current)
	}
}

// An Agent created with a prompt is waited on while its first turn runs.
func TestAgentWaitReturnsTheRunningTurnOfACreatedAgent(t *testing.T) {
	const sessionID, streamID = "session-1", "exec-1"
	host := newFakeAgentHost(sessionID, streamID)
	host.execution.State = api.AgentExecutionWorking
	host.execution.Status = api.AgentStatus{Activity: api.AgentActivityWorking}
	host.execution.ActiveTurn = &api.AgentTurn{ID: 1, Status: api.AgentTurnStarted}
	host.checkpoint = api.AgentProjectionCheckpoint{Sequence: 1, State: map[string]any{"turnId": "1", "turnStatus": "started"}}
	host.batches = []api.CanonicalAgentEventsMessage{turnBatch(streamID, 2, 1, "completed")}
	withFakeHost(t, host)

	previousJSON := outputJSON
	outputJSON = true
	t.Cleanup(func() { outputJSON = previousJSON })

	output, err := captureStdout(t, func() error {
		return agentCommand([]string{"wait", sessionID, "--timeout", "5s"})
	})
	if err != nil {
		t.Fatalf("agent wait: %v\n%s", err, output)
	}
	var result api.AgentWaitResult
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("wait output: %v\n%s", err, output)
	}
	if result.Turn != 1 || result.Status != api.AgentTurnCompleted {
		t.Fatalf("wait result = %#v, want turn 1 completed", result)
	}
}

// A wait that begins on an idle Agent must not be satisfied by the boundary a
// watcher replay re-announces for the turn that already finished.
func TestAgentWaitIgnoresAReplayedTerminalTurn(t *testing.T) {
	const sessionID, streamID = "session-1", "exec-1"
	host := newFakeAgentHost(sessionID, streamID)
	host.execution.ActiveTurn = &api.AgentTurn{ID: 3, Status: api.AgentTurnCompleted}
	host.checkpoint = api.AgentProjectionCheckpoint{Sequence: 6, State: map[string]any{"turnId": "3", "turnStatus": "completed"}}
	host.batches = []api.CanonicalAgentEventsMessage{
		turnBatch(streamID, 6, 3, "completed"),
		turnBatch(streamID, 7, 4, "started"),
		turnBatch(streamID, 8, 4, "completed"),
	}
	withFakeHost(t, host)

	previousJSON := outputJSON
	outputJSON = true
	t.Cleanup(func() { outputJSON = previousJSON })

	output, err := captureStdout(t, func() error {
		return agentCommand([]string{"wait", sessionID, "--timeout", "5s"})
	})
	if err != nil {
		t.Fatalf("agent wait: %v\n%s", err, output)
	}
	var result api.AgentWaitResult
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("wait output: %v\n%s", err, output)
	}
	if result.Turn != 4 || result.Status != api.AgentTurnCompleted {
		t.Fatalf("wait result = %#v, want turn 4; a replayed turn 3 boundary was accepted", result)
	}
	if !strings.Contains(output, `"turn": 4`) {
		t.Fatalf("wait output = %s", output)
	}
}

func runningAgentHost(sessionID, streamID string, turn uint64) *fakeAgentHost {
	host := newFakeAgentHost(sessionID, streamID)
	host.execution.State = api.AgentExecutionWorking
	host.execution.Status = api.AgentStatus{Activity: api.AgentActivityWorking}
	host.execution.ActiveTurn = &api.AgentTurn{ID: turn, Status: api.AgentTurnStarted}
	host.checkpoint = api.AgentProjectionCheckpoint{Sequence: 1, State: map[string]any{
		"turnId": fmt.Sprint(turn), "turnStatus": string(api.AgentTurnStarted),
	}}
	return host
}

// cancelling goes through the Host: the CLI names the execution and the turn it
// saw running and leaves the provider interrupt to the Host.
func TestAgentCancelCancelsTheRunningTurn(t *testing.T) {
	const sessionID, streamID = "session-1", "exec-1"
	host := runningAgentHost(sessionID, streamID, 3)
	withFakeHost(t, host)

	previousJSON := outputJSON
	outputJSON = true
	t.Cleanup(func() { outputJSON = previousJSON })

	output, err := captureStdout(t, func() error {
		return agentCommand([]string{"cancel", sessionID})
	})
	if err != nil {
		t.Fatalf("agent cancel: %v\n%s", err, output)
	}
	var result api.AgentTurnInterruptResult
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("cancel output: %v\n%s", err, output)
	}
	if !result.Accepted || result.Turn != 3 || result.Status != string(api.AgentTurnCancelled) {
		t.Fatalf("cancel result = %#v, want an accepted cancellation of turn 3", result)
	}
	commands := host.requests("agent.turn.cancel")
	if len(commands) != 1 {
		t.Fatalf("agent.turn.cancel requests = %d, want 1", len(commands))
	}
	if commands[0]["turnId"] != "3" || commands[0]["reason"] != "cancel" || commands[0]["executionId"] != streamID {
		t.Fatalf("agent.turn.cancel params = %#v", commands[0])
	}
	if commands[0]["commandId"] == "" {
		t.Fatalf("agent.turn.cancel params = %#v, want a command ID", commands[0])
	}
}

// An idle Agent is a no-op the caller can retry, not an error.
func TestAgentCancelIsANoOpWithoutARunningTurn(t *testing.T) {
	const sessionID, streamID = "session-1", "exec-1"
	for _, turn := range []api.AgentTurn{
		{ID: 3, Status: api.AgentTurnCompleted},
		{ID: 3, Status: api.AgentTurnInterrupted},
		{},
	} {
		host := newFakeAgentHost(sessionID, streamID)
		if turn.ID > 0 {
			host.execution.ActiveTurn = &turn
		}
		withFakeHost(t, host)
		previousJSON := outputJSON
		outputJSON = true

		output, err := captureStdout(t, func() error {
			return agentCommand([]string{"cancel", sessionID})
		})
		outputJSON = previousJSON
		if err != nil {
			t.Fatalf("cancel with %#v: %v\n%s", turn, err, output)
		}
		var result api.AgentTurnInterruptResult
		if err := json.Unmarshal([]byte(output), &result); err != nil {
			t.Fatalf("cancel output: %v\n%s", err, output)
		}
		if result.Accepted || result.Status != "idle" {
			t.Fatalf("cancel result = %#v, want an idle no-op", result)
		}
		if commands := host.requests("agent.turn.cancel"); len(commands) != 0 {
			t.Fatalf("idle cancel sent %d commands, want none", len(commands))
		}
	}
}

// --wait reports the ended turn instead of insisting on completion: a
// cancellation is a successful outcome.
func TestAgentCancelWaitReportsTheEndedTurn(t *testing.T) {
	const sessionID, streamID = "session-1", "exec-1"
	host := runningAgentHost(sessionID, streamID, 3)
	host.batches = []api.CanonicalAgentEventsMessage{turnBatch(streamID, 2, 3, "cancelled")}
	withFakeHost(t, host)

	previousJSON := outputJSON
	outputJSON = true
	t.Cleanup(func() { outputJSON = previousJSON })

	output, err := captureStdout(t, func() error {
		return agentCommand([]string{"cancel", sessionID, "--wait", "--timeout", "5s"})
	})
	if err != nil {
		t.Fatalf("agent cancel --wait: %v\n%s", err, output)
	}
	var result api.AgentWaitResult
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("cancel output: %v\n%s", err, output)
	}
	if result.Turn != 3 || result.Status != api.AgentTurnCancelled {
		t.Fatalf("wait result = %#v, want turn 3 cancelled", result)
	}
}

func TestAgentCancelRejectsUnusableFlags(t *testing.T) {
	for _, args := range [][]string{
		{"cancel", "--timeout", "5s"},
		{"cancel", "--unknown"},
		{"cancel", "session-1", "session-2"},
		{"cancel", "--current", "session-1"},
	} {
		if err := agentCommand(args); err == nil {
			t.Fatalf("agent %v was accepted, want a usage error", args)
		}
	}
}

func TestAgentUsageListsCancel(t *testing.T) {
	if !strings.Contains(agentUsageText(), "warren agent cancel AGENT_ID") {
		t.Fatalf("agent usage does not list cancel:\n%s", agentUsageText())
	}
	output, err := captureStdout(t, func() error {
		return agentCommand([]string{"cancel", "--help"})
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output, "warren agent cancel AGENT_ID") || !strings.Contains(output, "status\":\"idle") {
		t.Fatalf("cancel help = %s", output)
	}
}
