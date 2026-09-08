package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type inputRecordingRuntime struct {
	*memoryRuntime
	writes [][]byte
}

func (runtime *inputRecordingRuntime) Input(ctx context.Context, name string, data []byte) error {
	runtime.writes = append(runtime.writes, append([]byte(nil), data...))
	return runtime.memoryRuntime.Input(ctx, name, data)
}

type recordingAgentViewController struct {
	mu           sync.Mutex
	interactions []api.AgentInteractionResponse
	interrupts   []api.AgentTurnInterruptRequest
	atomic       []api.AgentTurnInterruptRequest
	messages     []api.AgentMessageSendRequest
}

func (c *recordingAgentViewController) RespondInteraction(_ context.Context, value api.AgentInteractionResponse) error {
	c.mu.Lock()
	c.interactions = append(c.interactions, value)
	c.mu.Unlock()
	return nil
}

func (c *recordingAgentViewController) InterruptTurn(_ context.Context, value api.AgentTurnInterruptRequest) error {
	c.mu.Lock()
	c.interrupts = append(c.interrupts, value)
	c.mu.Unlock()
	return nil
}

func (c *recordingAgentViewController) InterruptAndSend(_ context.Context, value api.AgentTurnInterruptRequest) error {
	c.mu.Lock()
	c.atomic = append(c.atomic, value)
	c.mu.Unlock()
	return nil
}

func (c *recordingAgentViewController) SendMessage(_ context.Context, value api.AgentMessageSendRequest) error {
	c.mu.Lock()
	c.messages = append(c.messages, value)
	c.mu.Unlock()
	return nil
}

func newAgentViewTestService(t *testing.T, controller AgentViewController) *Service {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "agent-view-test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "agent-view-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "codex", Runtime: "runtime", Lifecycle: "running",
			Title: "Codex", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, AgentController: controller}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	return service
}

func TestRunCanonicalCommandReplaysDurableResultAfterReconnect(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.db")
	journal, err := store.OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{AgentStore: journal}
	payload := api.AgentCommand{CommandID: "command-1", ExecutionID: "execution-1"}
	calls := 0
	first, err := service.runCanonicalCommand(
		context.Background(), payload.ExecutionID, payload.CommandID, payload,
		func() (any, error) {
			calls++
			return map[string]any{"accepted": true}, nil
		},
	)
	if err != nil {
		_ = journal.Close()
		t.Fatal(err)
	}
	if first.(map[string]any)["accepted"] != true || calls != 1 {
		_ = journal.Close()
		t.Fatalf("first canonical result = %#v, calls=%d", first, calls)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}

	journal, err = store.OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	restarted := &Service{AgentStore: journal}
	second, err := restarted.runCanonicalCommand(
		context.Background(), payload.ExecutionID, payload.CommandID, payload,
		func() (any, error) {
			calls++
			return nil, errors.New("durable command was invoked twice")
		},
	)
	if err != nil {
		t.Fatalf("durable replay failed: %v", err)
	}
	result, ok := second.(map[string]any)
	if !ok || result["accepted"] != true || calls != 1 {
		t.Fatalf("durable replay result = %#v, calls=%d", second, calls)
	}
}

func TestInterruptAgentTurnInputSendsInterruptAndReplacement(t *testing.T) {
	runtime := newMemoryRuntime(t)
	if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
		t.Fatal(err)
	}
	request := api.AgentTurnInterruptRequest{
		Session:     "sess",
		Turn:        1,
		Reason:      "send_now",
		Replacement: &api.AgentMessageSendRequest{Session: "sess", ClientMessageID: "m1", Text: "rewrite it"},
	}
	if err := interruptAgentTurnInput(context.Background(), runtime, "sess", request); err != nil {
		t.Fatal(err)
	}
	data, _ := runtime.Capture(context.Background(), "sess")
	if !bytes.Contains(data, []byte{0x03}) {
		t.Errorf("input = %q, want interrupt byte 0x03", data)
	}
	if !bytes.Contains(data, []byte("rewrite it")) {
		t.Errorf("input = %q, want replacement text", data)
	}
}

func TestInterruptAgentTurnInputCancelOnly(t *testing.T) {
	runtime := newMemoryRuntime(t)
	if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
		t.Fatal(err)
	}
	request := api.AgentTurnInterruptRequest{Session: "sess", Turn: 1, Reason: "cancel"}
	if err := interruptAgentTurnInput(context.Background(), runtime, "sess", request); err != nil {
		t.Fatal(err)
	}
	data, _ := runtime.Capture(context.Background(), "sess")
	if !bytes.Contains(data, []byte{0x03}) {
		t.Errorf("input = %q, want interrupt byte 0x03", data)
	}
}

func TestAgentViewActionsAreIdempotentAndRejectConflictingIdentities(t *testing.T) {
	controller := &recordingAgentViewController{}
	service := newAgentViewTestService(t, controller)
	sessionID := "agent-view-session"
	service.recordAgentEvents(sessionID, []api.AgentEvent{{
		Type: "question",
		ID:   "question-1",
		Payload: map[string]any{
			"requestId": "request-1",
			"state":     "pending",
		},
	}}, api.AgentStatus{Activity: api.AgentActivityBlocked})
	request := api.AgentInteractionResponse{
		Session: sessionID, RequestID: "request-1", Kind: "question",
		Response: map[string]any{"answers": map[string]any{"q1": []any{"yes"}}},
	}
	if _, err := service.respondAgentInteraction(context.Background(), request); err != nil {
		t.Fatalf("first interaction response failed: %v", err)
	}
	if _, err := service.respondAgentInteraction(context.Background(), request); err != nil {
		t.Fatalf("idempotent interaction response failed: %v", err)
	}
	if len(controller.interactions) != 1 {
		t.Fatalf("provider interaction calls = %d, want 1", len(controller.interactions))
	}
	request.Kind = "permission"
	if _, err := service.respondAgentInteraction(context.Background(), request); err == nil {
		t.Fatal("same requestId with a different kind was accepted")
	}

	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 3, Status: api.AgentTurnStarted}}, false)
	interrupt := api.AgentTurnInterruptRequest{Session: sessionID, Turn: 3, Reason: "cancel"}
	if _, err := service.interruptAgentTurn(context.Background(), interrupt); err != nil {
		t.Fatalf("first interrupt failed: %v", err)
	}
	if _, err := service.interruptAgentTurn(context.Background(), interrupt); err != nil {
		t.Fatalf("idempotent interrupt failed: %v", err)
	}
	if len(controller.interrupts) != 1 {
		t.Fatalf("provider interrupt calls = %d, want 1", len(controller.interrupts))
	}
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 3, Status: api.AgentTurnCompleted}}, false)
	if _, err := service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		Session: sessionID, Turn: 4, Reason: "cancel",
	}); err == nil {
		t.Fatal("stale turn interrupt was accepted")
	}
}

func TestAgentTurnInterruptionAndCancellationRemainDistinct(t *testing.T) {
	controller := &recordingAgentViewController{}
	service := newAgentViewTestService(t, controller)
	sessionID := "agent-view-session"

	// A provider/TUI interruption has no Host command to correlate. The
	// provider status and turn observation arrive independently, just as they
	// do from the transcript watcher.
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityWorking})
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnStarted}}, false)
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityReady})
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnInterrupted}}, false)
	if got := service.agentTurn(sessionID); got.Status != api.AgentTurnInterrupted {
		t.Fatalf("provider interruption turn = %#v, want interrupted", got)
	}
	if got := service.agentStatus(sessionID).Activity; got != api.AgentActivityReady {
		t.Fatalf("provider interruption activity = %q, want ready", got)
	}

	service.agentsMu.Lock()
	entry := service.agents[sessionID]
	entry.mu.Lock()
	events := append([]api.CanonicalAgentEvent(nil), entry.canonicalEvents...)
	entry.mu.Unlock()
	service.agentsMu.Unlock()
	var interruption *api.CanonicalAgentEvent
	for index := range events {
		if events[index].Type == "turn.interrupted" {
			interruption = &events[index]
		}
	}
	if interruption == nil {
		t.Fatalf("canonical events = %#v, want turn.interrupted", events)
	}
	if interruption.CausedBy != "" || interruption.Payload["cause"] != "interrupt" {
		t.Fatalf("uncorrelated interruption = %#v, want no causedBy and interrupt cause", interruption)
	}

	// A Host cancel receipt is not a terminal observation. The activity must
	// remain working until the Provider reports the interruption.
	service = newAgentViewTestService(t, controller)
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityWorking})
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnStarted}}, false)
	result, err := service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		CommandID: "cancel-1", Session: sessionID, Turn: 1, Reason: "cancel",
	})
	if err != nil || !result.Accepted {
		t.Fatalf("cancel result = %#v, err=%v", result, err)
	}
	if got := service.agentStatus(sessionID).Activity; got != api.AgentActivityWorking {
		t.Fatalf("accepted cancel activity = %q, want working", got)
	}
	service.agentsMu.Lock()
	entry = service.agents[sessionID]
	entry.mu.Lock()
	pending := entry.pendingTurnRequest
	entry.mu.Unlock()
	service.agentsMu.Unlock()
	if pending == nil || pending.commandID != "cancel-1" {
		t.Fatalf("pending cancel = %#v, want command cancel-1", pending)
	}

	// The matching Provider observation converts the turn boundary to
	// cancelled and carries the Host command correlation.
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityReady})
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnInterrupted}}, false)
	if got := service.agentTurn(sessionID); got.Status != api.AgentTurnCancelled {
		t.Fatalf("correlated interruption turn = %#v, want cancelled", got)
	}
	// A duplicate provider callback must not regress the already correlated
	// boundary back to an uncorrelated interruption.
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnInterrupted}}, false)
	service.agentsMu.Lock()
	entry = service.agents[sessionID]
	entry.mu.Lock()
	events = append([]api.CanonicalAgentEvent(nil), entry.canonicalEvents...)
	pending = entry.pendingTurnRequest
	entry.mu.Unlock()
	service.agentsMu.Unlock()
	var cancellation *api.CanonicalAgentEvent
	for index := range events {
		if events[index].Type == "turn.cancelled" {
			cancellation = &events[index]
		}
	}
	if cancellation == nil || cancellation.CausedBy != "cancel-1" || cancellation.Payload["cause"] != "cancel" {
		t.Fatalf("correlated cancellation = %#v, want causedBy cancel-1", cancellation)
	}
	if pending != nil {
		t.Fatalf("pending request after cancellation = %#v, want nil", pending)
	}
	var cancellationCount int
	var interruptionCount int
	for index := range events {
		switch events[index].Type {
		case "turn.cancelled":
			cancellationCount++
		case "turn.interrupted":
			interruptionCount++
		}
	}
	if cancellationCount != 1 || interruptionCount != 0 {
		t.Fatalf("terminal event counts = cancelled %d, interrupted %d; want 1, 0", cancellationCount, interruptionCount)
	}
}

func TestAgentTurnCancelCannotAttachAfterReadyObservation(t *testing.T) {
	controller := &recordingAgentViewController{}
	service := newAgentViewTestService(t, controller)
	sessionID := "agent-view-session"
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityWorking})
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnStarted}}, false)
	// The watcher publishes the terminal status before it publishes the turn
	// cursor. A Host request in this gap is too late to cause the stop.
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityReady})
	if _, err := service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		CommandID: "late-cancel", Session: sessionID, Turn: 1, Reason: "cancel",
	}); err == nil {
		t.Fatal("cancel after ready observation was accepted")
	}
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnInterrupted}}, false)
	if got := service.agentTurn(sessionID); got.Status != api.AgentTurnInterrupted {
		t.Fatalf("late cancel observation = %#v, want interrupted", got)
	}
}

func TestAgentTurnCancelPendingClearsOnNormalTerminalBoundary(t *testing.T) {
	controller := &recordingAgentViewController{}
	service := newAgentViewTestService(t, controller)
	sessionID := "agent-view-session"
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityWorking})
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnStarted}}, false)
	if _, err := service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		CommandID: "cancel-normal", Session: sessionID, Turn: 1, Reason: "cancel",
	}); err != nil {
		t.Fatalf("cancel request failed: %v", err)
	}

	// The Provider completed normally after the request was accepted. It must
	// consume the pending correlation instead of poisoning a future turn.
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnCompleted}}, false)
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 2, Status: api.AgentTurnStarted}}, false)
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 2, Status: api.AgentTurnInterrupted}}, false)
	if got := service.agentTurn(sessionID); got.Status != api.AgentTurnInterrupted {
		t.Fatalf("next turn after normal completion = %#v, want interrupted", got)
	}
}

func TestAgentTurnLegacyAbortedObservationRemainsCompatible(t *testing.T) {
	service := newAgentViewTestService(t, &recordingAgentViewController{})
	sessionID := "agent-view-session"
	service.recordAgentStatus(sessionID, api.AgentStatus{Activity: api.AgentActivityWorking})
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnStarted}}, false)
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 1, Status: api.AgentTurnAborted}}, false)
	if got := service.agentTurn(sessionID); got.Status != api.AgentTurnInterrupted {
		t.Fatalf("legacy aborted turn = %#v, want interrupted projection", got)
	}

	status, turn := canonicalProjectionFromEvent(api.AgentStatus{}, api.AgentTurn{}, api.CanonicalAgentEvent{
		Type:    "turn.aborted",
		TurnID:  "7",
		Payload: map[string]any{"turnId": "7", "status": "aborted"},
	})
	if status.Activity != "" || turn.ID != 7 || turn.Status != api.AgentTurnAborted {
		t.Fatalf("legacy canonical projection = status %#v turn %#v", status, turn)
	}
}

func TestAgentViewAttachmentLifecycleValidatesChunksAndPrepareHash(t *testing.T) {
	service := newAgentViewTestService(t, &recordingAgentViewController{})
	sessionID := "agent-view-session"
	data := []byte("hello")
	digest := sha256.Sum256(data)
	hash := hex.EncodeToString(digest[:])
	prepare := api.AgentAttachmentPrepareRequest{
		Session: sessionID, Name: "hello.txt", MIME: "text/plain", Size: int64(len(data)), SHA256: hash,
	}
	value, err := service.prepareAgentAttachment(context.Background(), sessionID, prepare)
	if err != nil {
		t.Fatalf("prepare failed: %v", err)
	}
	empty := api.AgentAttachmentChunkRequest{
		Session: sessionID, UploadID: value.UploadID, Sequence: 0, Length: 0,
		Data: base64.StdEncoding.EncodeToString(nil),
	}
	if _, err := service.putAgentAttachmentChunk(context.Background(), empty); err == nil {
		t.Fatal("zero-length chunk for a non-empty upload was accepted")
	}
	outOfOrder := api.AgentAttachmentChunkRequest{
		Session: sessionID, UploadID: value.UploadID, Sequence: 1, Length: 1,
		Data: base64.StdEncoding.EncodeToString([]byte("o")),
	}
	if _, err := service.putAgentAttachmentChunk(context.Background(), outOfOrder); err != nil {
		t.Fatalf("out-of-order chunk should be buffered: %v", err)
	}
	service.agentViewMu.Lock()
	service.agentUploads[value.UploadID].expiresAt = time.Now().Add(-time.Second)
	service.agentViewMu.Unlock()
	if _, err := service.putAgentAttachmentChunk(context.Background(), outOfOrder); err == nil {
		t.Fatal("duplicate chunk was accepted after upload expiry")
	}
	if _, err := service.completeAgentAttachment(context.Background(), api.AgentAttachmentCompleteRequest{
		Session: sessionID, UploadID: value.UploadID, Length: 1, SHA256: hash,
	}); err == nil {
		t.Fatal("incomplete chunk sequence was accepted")
	}
	if _, err := service.abortAgentAttachment(context.Background(), api.AgentAttachmentAbortRequest{Session: sessionID, UploadID: value.UploadID}); err != nil {
		t.Fatalf("abort failed: %v", err)
	}

	value, err = service.prepareAgentAttachment(context.Background(), sessionID, prepare)
	if err != nil {
		t.Fatalf("second prepare failed: %v", err)
	}
	chunk := api.AgentAttachmentChunkRequest{
		Session: sessionID, UploadID: value.UploadID, Sequence: 0, Length: len(data),
		SHA256: hash, Data: base64.StdEncoding.EncodeToString(data),
	}
	if _, err := service.putAgentAttachmentChunk(context.Background(), chunk); err != nil {
		t.Fatalf("valid chunk failed: %v", err)
	}
	if _, err := service.completeAgentAttachment(context.Background(), api.AgentAttachmentCompleteRequest{
		Session: sessionID, UploadID: value.UploadID, Length: int64(len(data)), SHA256: "00",
	}); err == nil {
		t.Fatal("completion hash conflicting with prepare hash was accepted")
	}
	if completed, err := service.completeAgentAttachment(context.Background(), api.AgentAttachmentCompleteRequest{
		Session: sessionID, UploadID: value.UploadID, Length: int64(len(data)),
	}); err != nil || !completed.Accepted || completed.State != "ready" {
		t.Fatalf("valid completion = %#v, err=%v", completed, err)
	}
}

func TestAgentViewAttachmentMessageUsesLegacyPTYBridge(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "agent-view-pty")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "agent-view-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "codex", Runtime: "runtime", Lifecycle: "running",
			Title: "Codex", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryRuntime(t)
	if err := runtime.Create(context.Background(), "runtime", "", "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	t.Cleanup(service.cleanupAgentAttachments)

	data := []byte("attachment body")
	digest := sha256.Sum256(data)
	hash := hex.EncodeToString(digest[:])
	prepared, err := service.prepareAgentAttachment(context.Background(), sessionID, api.AgentAttachmentPrepareRequest{
		Session: sessionID, Name: "notes.txt", MIME: "text/plain", Size: int64(len(data)), SHA256: hash,
	})
	if err != nil {
		t.Fatalf("prepare failed: %v", err)
	}
	if _, err := service.putAgentAttachmentChunk(context.Background(), api.AgentAttachmentChunkRequest{
		Session: sessionID, UploadID: prepared.UploadID, Sequence: 0,
		Length: len(data), SHA256: hash, Data: base64.StdEncoding.EncodeToString(data),
	}); err != nil {
		t.Fatalf("chunk failed: %v", err)
	}
	if _, err := service.completeAgentAttachment(context.Background(), api.AgentAttachmentCompleteRequest{
		Session: sessionID, UploadID: prepared.UploadID, Length: int64(len(data)), SHA256: hash,
	}); err != nil {
		t.Fatalf("complete failed: %v", err)
	}
	result, err := service.sendAgentMessage(context.Background(), api.AgentMessageSendRequest{
		Session: sessionID, ClientMessageID: "message-1", Text: "Review this file",
		Attachments: []api.AgentAttachmentRef{{
			AttachmentID: prepared.AttachmentID, Name: "notes.txt", MIME: "text/plain", Size: int64(len(data)),
		}},
	})
	if err != nil || !result.Accepted {
		t.Fatalf("send result = %#v, err=%v", result, err)
	}
	captured, err := runtime.Capture(context.Background(), "runtime")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(captured, []byte("Review this file")) || !bytes.Contains(captured, []byte("notes.txt")) {
		t.Fatalf("PTY input = %q, want message and attachment name", captured)
	}
	materialized, err := service.materializedAgentAttachmentFor(sessionID, api.AgentAttachmentRef{AttachmentID: prepared.AttachmentID})
	if err != nil {
		t.Fatalf("resolve materialized attachment: %v", err)
	}
	if got, err := os.ReadFile(materialized.path); err != nil || !bytes.Equal(got, data) {
		t.Fatalf("materialized file = %q, err=%v, want %q", got, err, data)
	}

	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 4, Status: api.AgentTurnStarted}}, false)
	if _, err := service.interruptAgentTurn(context.Background(), api.AgentTurnInterruptRequest{
		Session: sessionID,
		Turn:    4,
		Reason:  "send_now",
		Replacement: &api.AgentMessageSendRequest{
			Session:         sessionID,
			ClientMessageID: "message-2",
			Attachments:     []api.AgentAttachmentRef{{AttachmentID: prepared.AttachmentID}},
		},
	}); err != nil {
		t.Fatalf("attachment-only send now failed: %v", err)
	}
	captured, err = runtime.Capture(context.Background(), "runtime")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(captured, []byte("Please inspect the attached file(s).")) ||
		!bytes.Contains(captured, []byte(materialized.path)) {
		t.Fatalf("attachment-only Send now input = %q, want default prompt and Host path", captured)
	}
}

func TestAgentViewCapabilitiesExposeAttachmentsForPTYRuntime(t *testing.T) {
	service := &Service{Runtime: newMemoryRuntime(t)}
	capabilities := service.AgentViewCapabilities()
	if !api.SupportsCapability(capabilities, api.CapabilityAgentAttachments) {
		t.Fatalf("capabilities = %q, want %q", capabilities, api.CapabilityAgentAttachments)
	}
}

func TestAgentViewSendNowRejectsReplacementIdentityReuse(t *testing.T) {
	controller := &recordingAgentViewController{}
	service := newAgentViewTestService(t, controller)
	sessionID := "agent-view-session"
	service.recordAgentTurns(sessionID, []api.AgentTurn{{ID: 8, Status: api.AgentTurnStarted}}, false)
	replacement := &api.AgentMessageSendRequest{Session: sessionID, ClientMessageID: "message-1", Text: "first"}
	request := api.AgentTurnInterruptRequest{Session: sessionID, Turn: 8, Reason: "send_now", Replacement: replacement}
	if _, err := service.interruptAgentTurn(context.Background(), request); err != nil {
		t.Fatalf("send now failed: %v", err)
	}
	if len(controller.atomic) != 1 {
		t.Fatalf("atomic provider calls = %d, want 1", len(controller.atomic))
	}
	conflict := request
	conflict.Replacement = &api.AgentMessageSendRequest{Session: sessionID, ClientMessageID: "message-1", Text: "different"}
	if _, err := service.interruptAgentTurn(context.Background(), conflict); err == nil {
		t.Fatal("replacement message identity was reused with a different payload")
	}
}

func TestAgentViewMutationsRequireTheMatchingControlLease(t *testing.T) {
	session := api.Session{ID: "session-1"}
	peer := &wsPeer{attached: &session, controlSession: session.ID}
	if err := peer.requireAgentControl(session.ID); err != nil {
		t.Fatalf("matching control lease rejected: %v", err)
	}
	if err := peer.requireAgentControl("session-2"); err == nil {
		t.Fatal("a different session used the control lease")
	}
	peer.controlSession = ""
	if err := peer.requireAgentControl(session.ID); err == nil {
		t.Fatal("a passive subscription used the control lease")
	}
	if err := peer.requireAgentControl(""); err != nil {
		t.Fatalf("malformed request should reach service validation: %v", err)
	}
}

func TestAgentViewControlOnlyClaimIsAuthoritative(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	httpServer := &HTTPServer{Service: service}
	first := &wsPeer{server: httpServer}
	second := &wsPeer{server: httpServer}
	session := api.Session{ID: "session-control-only"}

	first.claimControl(session)
	if !service.hasControlPeer(first, session.ID) {
		t.Fatal("control-only claim was not recorded by the Host")
	}
	if err := first.requireAgentControl(session.ID); err != nil {
		t.Fatalf("control-only claim rejected: %v", err)
	}

	second.claimControl(session)
	if err := first.requireAgentControl(session.ID); err == nil {
		t.Fatal("superseded control-only peer retained Agent mutation access")
	}
	if err := second.requireAgentControl(session.ID); err != nil {
		t.Fatalf("new control-only owner rejected: %v", err)
	}
}

func TestCanonicalCommandSessionDoesNotRequireTerminalControlLease(t *testing.T) {
	const sessionID = "session-decoupled-agent"
	const execID = "exec-decoupled-agent"
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(s *api.State) error {
		s.Sessions = append(s.Sessions, api.Session{
			ID:               sessionID,
			AgentExecutionID: execID,
			Lifecycle:        "running",
			Kind:             "codex",
		})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state}
	service.lazyInit()

	// Another peer (e.g. Warren Desktop) owns the terminal control lease.
	terminalPeer := &wsPeer{}
	service.outputMu.Lock()
	service.controlPeers[sessionID] = terminalPeer
	service.outputMu.Unlock()

	// A mobile agent peer without terminal control lease submits an agent command.
	agentPeer := &wsPeer{server: &HTTPServer{Service: service}}
	cmd := api.AgentCommand{
		CommandID:   "cmd-1",
		ExecutionID: execID,
	}
	session, execution, err := agentPeer.canonicalCommandSession(context.Background(), cmd)
	if err != nil {
		t.Fatalf("canonical agent command rejected when terminal lease is held by another client: %v", err)
	}
	if session.ID != sessionID || execution.ID != execID {
		t.Fatalf("unexpected session or execution: %v, %v", session, execution)
	}
}

func TestDetachAgentPeerReleasesStaleControlLease(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	server := &HTTPServer{Service: service}
	owner := &wsPeer{server: server}
	replacement := &wsPeer{server: server}
	const sessionID = "session-agent-lease"

	service.registerAgentPeer(sessionID, owner)
	if !service.claimAgentControlPeer(owner, sessionID) {
		t.Fatal("initial Agent control claim was rejected")
	}
	service.detachAgentPeer(owner, sessionID)
	if service.hasControlPeer(owner, sessionID) {
		t.Fatal("detaching Agent peer retained a stale control lease")
	}
	if !service.claimAgentControlPeer(replacement, sessionID) {
		t.Fatal("replacement Agent peer could not claim released control lease")
	}
}

func TestDetachAgentPeerPreservesTerminalFocusLease(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	server := &HTTPServer{Service: service}
	peer := &wsPeer{server: server}
	const sessionID = "session-terminal-focus"

	service.registerAgentPeer(sessionID, peer)
	service.outputMu.Lock()
	service.focusedPeers[sessionID] = peer
	service.controlPeers[sessionID] = peer
	service.outputMu.Unlock()
	service.detachAgentPeer(peer, sessionID)
	if !service.hasControlPeer(peer, sessionID) {
		t.Fatal("detaching Agent stream stole a live terminal focus lease")
	}
}

func TestPeerCloseReleasesAgentOnlyControlLeaseBeforeSubscription(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	server := &HTTPServer{Service: service}
	peer := &wsPeer{
		server: server,
		closed: make(chan struct{}),
	}
	const sessionID = "session-agent-only-before-subscribe"

	service.outputMu.Lock()
	service.controlPeers[sessionID] = peer
	service.outputMu.Unlock()
	peer.enqueueMu.Lock()
	peer.controlSession = sessionID
	peer.enqueueMu.Unlock()

	// The focus request may race the canonical subscribe response. Closing the
	// socket must release the lease even though agentSession is still empty.
	peer.closeWithReason("test")
	if service.hasControlPeer(peer, sessionID) {
		t.Fatal("closing an Agent-only peer retained its control lease")
	}
}

func TestPeerDetachReleasesAgentOnlyControlLease(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	server := &HTTPServer{Service: service}
	peer := &wsPeer{server: server}
	const sessionID = "session-agent-only-detach"

	if !service.claimAgentControlPeer(peer, sessionID) {
		t.Fatal("Agent-only control claim was rejected")
	}
	peer.enqueueMu.Lock()
	peer.controlSession = sessionID
	peer.enqueueMu.Unlock()
	peer.detach()
	if service.hasControlPeer(peer, sessionID) {
		t.Fatal("detaching an Agent-only peer retained its control lease")
	}
}

func TestPeerClaimControlReleasesPreviousAgentOnlyLease(t *testing.T) {
	service := &Service{}
	service.lazyInit()
	server := &HTTPServer{Service: service}
	peer := &wsPeer{server: server}
	const agentSessionID = "session-agent-only-switch"
	const terminalSessionID = "session-terminal-switch"

	if !service.claimAgentControlPeer(peer, agentSessionID) {
		t.Fatal("Agent-only control claim was rejected")
	}
	peer.enqueueMu.Lock()
	peer.controlSession = agentSessionID
	peer.enqueueMu.Unlock()
	peer.claimControl(api.Session{ID: terminalSessionID})
	if service.hasControlPeer(peer, agentSessionID) {
		t.Fatal("switching to terminal focus retained the previous Agent-only lease")
	}
	if !service.hasControlPeer(peer, terminalSessionID) {
		t.Fatal("terminal focus did not claim the new control lease")
	}
}

func TestSendAgentMessageInputHerdrSubmissionFraming(t *testing.T) {
	runtime := newMemoryRuntime(t)
	if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
		t.Fatal(err)
	}
	text := "line1\nline2\twith tab\nline3"
	if err := sendAgentMessageInput(context.Background(), runtime, "sess", text); err != nil {
		t.Fatal(err)
	}
	data, err := runtime.Capture(context.Background(), "sess")
	if err != nil {
		t.Fatal(err)
	}
	want := "\x1b[200~line1\rline2\twith tab\rline3\x1b[201~\r"
	if !bytes.Contains(data, []byte(want)) {
		t.Fatalf("captured = %q, want containing %q", data, want)
	}
}

func TestSendAgentMessageStatusMutexGuards(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "status-mutex-test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "agent-mutex-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "codex", Runtime: "runtime", Lifecycle: "running",
			Title: "Codex", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryRuntime(t)
	if err := runtime.Create(context.Background(), "runtime", "", "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}

	// Case 1: Blocked on attention -> ErrAgentBlocked
	service.agents[sessionID].status = api.AgentStatus{
		Activity:  api.AgentActivityBlocked,
		Attention: &api.AgentAttention{Kind: "approval", Reason: "permission"},
	}
	msg1 := api.AgentMessageSendRequest{Session: sessionID, ClientMessageID: "m1", Text: "hello blocked"}
	if _, err := service.sendAgentMessage(context.Background(), msg1); !errors.Is(err, api.ErrAgentBlocked) {
		t.Fatalf("sendAgentMessage when blocked = %v, want %v", err, api.ErrAgentBlocked)
	}
	captured, _ := runtime.Capture(context.Background(), "runtime")
	if string(captured) != "ready\n" {
		t.Fatalf("runtime captured %q when blocked, want initial ready only", captured)
	}

	// Case 2: Working -> ErrAgentBusy
	service.agents[sessionID].status = api.AgentStatus{
		Activity: api.AgentActivityWorking,
	}
	msg2 := api.AgentMessageSendRequest{Session: sessionID, ClientMessageID: "m2", Text: "hello working"}
	if _, err := service.sendAgentMessage(context.Background(), msg2); !errors.Is(err, api.ErrAgentBusy) {
		t.Fatalf("sendAgentMessage when working = %v, want %v", err, api.ErrAgentBusy)
	}
	captured, _ = runtime.Capture(context.Background(), "runtime")
	if string(captured) != "ready\n" {
		t.Fatalf("runtime captured %q when working, want initial ready only", captured)
	}

	// Case 3: Ready -> Success
	service.agents[sessionID].status = api.AgentStatus{
		Activity: api.AgentActivityReady,
	}
	msg3 := api.AgentMessageSendRequest{Session: sessionID, ClientMessageID: "m3", Text: "hello ready"}
	res, err := service.sendAgentMessage(context.Background(), msg3)
	if err != nil {
		t.Fatalf("sendAgentMessage when ready failed: %v", err)
	}
	if !res.Accepted || res.ClientMessageID != "m3" {
		t.Fatalf("result = %#v, want accepted", res)
	}
	captured, _ = runtime.Capture(context.Background(), "runtime")
	if !bytes.Contains(captured, []byte("hello ready")) {
		t.Fatalf("runtime captured %q, want message text", captured)
	}

	// Case 4: Blocked on input attention (e.g. asking for prompt) -> Success
	service.agents[sessionID].status = api.AgentStatus{
		Activity:  api.AgentActivityBlocked,
		Attention: &api.AgentAttention{Kind: api.AgentAttentionInput, Reason: "prompt"},
	}
	msg4 := api.AgentMessageSendRequest{Session: sessionID, ClientMessageID: "m4", Text: "answer to prompt"}
	res4, err := service.sendAgentMessage(context.Background(), msg4)
	if err != nil {
		t.Fatalf("sendAgentMessage when blocked on input failed: %v", err)
	}
	if !res4.Accepted || res4.ClientMessageID != "m4" {
		t.Fatalf("result = %#v, want accepted", res4)
	}
	captured, _ = runtime.Capture(context.Background(), "runtime")
	if !bytes.Contains(captured, []byte("answer to prompt")) {
		t.Fatalf("runtime captured %q, want answer text", captured)
	}
}

func TestSendAgentInteractionInputPTYSemantics(t *testing.T) {
	runtime := newMemoryRuntime(t)
	if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	// 1. Permission: allow sends y\r
	err := sendAgentInteractionInput(ctx, runtime, "sess", api.AgentInteractionResponse{
		Kind:     "permission",
		Response: map[string]any{"decision": "allow"},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	captured, _ := runtime.Capture(ctx, "sess")
	if !bytes.Contains(captured, []byte("y\r")) {
		t.Fatalf("captured = %q, want containing %q", string(captured), "y\r")
	}

	// 2. Permission: deny sends n\r
	_ = runtime.Create(ctx, "sess-deny", "", "", nil)
	err = sendAgentInteractionInput(ctx, runtime, "sess-deny", api.AgentInteractionResponse{
		Kind:     "permission",
		Response: map[string]any{"decision": "deny"},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	captured, _ = runtime.Capture(ctx, "sess-deny")
	if !bytes.Contains(captured, []byte("n\r")) {
		t.Fatalf("captured = %q, want containing %q", string(captured), "n\r")
	}

	// 3. Cancel sends \x03 (Ctrl+C)
	_ = runtime.Create(ctx, "sess-cancel", "", "", nil)
	err = sendAgentInteractionInput(ctx, runtime, "sess-cancel", api.AgentInteractionResponse{
		Kind:     "permission",
		Response: map[string]any{"cancelled": true},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	captured, _ = runtime.Capture(ctx, "sess-cancel")
	if !bytes.Contains(captured, []byte{0x03}) {
		t.Fatalf("captured = %q, want containing Ctrl+C", captured)
	}

	// 4. Question: custom single-line answer sends text\r
	_ = runtime.Create(ctx, "sess-q1", "", "", nil)
	err = sendAgentInteractionInput(ctx, runtime, "sess-q1", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"customAnswers": map[string]any{"q0": "my-answer"},
		},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	captured, _ = runtime.Capture(ctx, "sess-q1")
	if !bytes.Contains(captured, []byte("my-answer\r")) {
		t.Fatalf("captured = %q, want containing %q", string(captured), "my-answer\r")
	}

	// 5. Question: multi-line answer sends bracketed paste
	_ = runtime.Create(ctx, "sess-q2", "", "", nil)
	err = sendAgentInteractionInput(ctx, runtime, "sess-q2", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"customAnswers": map[string]any{"q0": "line1\nline2"},
		},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	captured, _ = runtime.Capture(ctx, "sess-q2")
	wantBracketed := "\x1b[200~line1\rline2\x1b[201~\r"
	if !bytes.Contains(captured, []byte(wantBracketed)) {
		t.Fatalf("captured = %q, want containing %q", string(captured), wantBracketed)
	}

	// 6. Question: selected option sends choice\r
	_ = runtime.Create(ctx, "sess-q3", "", "", nil)
	err = sendAgentInteractionInput(ctx, runtime, "sess-q3", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"answers": map[string]any{"q0": []any{"option-1"}},
		},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	captured, _ = runtime.Capture(ctx, "sess-q3")
	if !bytes.Contains(captured, []byte("option-1\r")) {
		t.Fatalf("captured = %q, want containing %q", string(captured), "option-1\r")
	}
}

func TestSendAgentInteractionInputUsesSchemaOrderAndSeparateEnter(t *testing.T) {
	runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
		t.Fatal(err)
	}
	err := sendAgentInteractionInput(context.Background(), runtime, "sess", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"answerOrder": []any{"q2", "q1"},
			"answerLabels": map[string]any{
				"q1": []any{"first"},
				"q2": []any{"second"},
			},
		},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	if len(runtime.writes) != 4 {
		t.Fatalf("writes = %#v, want two text/enter pairs", runtime.writes)
	}
	if got := string(runtime.writes[0]); got != "second" {
		t.Fatalf("first answer = %q, want schema order q2", got)
	}
	if got := string(runtime.writes[1]); got != "\r" {
		t.Fatalf("first submit = %q, want separate Enter", got)
	}
	if got := string(runtime.writes[2]); got != "first" {
		t.Fatalf("second answer = %q, want schema order q1", got)
	}
	if got := string(runtime.writes[3]); got != "\r" {
		t.Fatalf("second submit = %q, want separate Enter", got)
	}
}

func TestSendAgentInteractionInputCombinesCustomAndSelectedAnswers(t *testing.T) {
	runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	if err := runtime.Create(context.Background(), "sess-mixed", "", "", nil); err != nil {
		t.Fatal(err)
	}
	err := sendAgentInteractionInput(context.Background(), runtime, "sess-mixed", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"answerOrder": []any{"q1", "q2"},
			"customAnswers": map[string]any{
				"q1": "free-form",
			},
			"answerLabels": map[string]any{
				"q2": []any{"Visible choice"},
			},
			"answers": map[string]any{
				"q2": []any{"choice-id"},
			},
		},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	if len(runtime.writes) != 4 {
		t.Fatalf("writes = %#v, want two text/enter pairs", runtime.writes)
	}
	if got := string(runtime.writes[0]); got != "free-form" {
		t.Fatalf("custom answer = %q, want free-form", got)
	}
	if got := string(runtime.writes[2]); got != "Visible choice" {
		t.Fatalf("selected label = %q, want Visible choice", got)
	}
}

func TestSendAgentInteractionInputUsesArrowKeyNavigation(t *testing.T) {
	runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	if err := runtime.Create(context.Background(), "sess-arrow", "", "", nil); err != nil {
		t.Fatal(err)
	}
	err := sendAgentInteractionInput(context.Background(), runtime, "sess-arrow", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"answerOrder": []any{"q1", "q2"},
			"answerIndices": map[string]any{
				"q1": []any{2}, // Option index 2 -> 2 down arrows + enter
				"q2": []any{0}, // Option index 0 -> 0 down arrows + enter
			},
		},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	// Writes should be: \x1b[B, \x1b[B, \r for q1, then \r for q2
	if len(runtime.writes) != 4 {
		t.Fatalf("writes = %#v (len %d), want 4 writes", runtime.writes, len(runtime.writes))
	}
	if got := string(runtime.writes[0]); got != "\x1b[B" {
		t.Fatalf("write[0] = %q, want down arrow", got)
	}
	if got := string(runtime.writes[1]); got != "\x1b[B" {
		t.Fatalf("write[1] = %q, want down arrow", got)
	}
	if got := string(runtime.writes[2]); got != "\r" {
		t.Fatalf("write[2] = %q, want Enter", got)
	}
	if got := string(runtime.writes[3]); got != "\r" {
		t.Fatalf("write[3] = %q, want Enter", got)
	}
}

func TestSendAgentInteractionInputAddsCodexNotesAfterSelection(t *testing.T) {
	runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	if err := runtime.Create(context.Background(), "sess-notes", "", "", nil); err != nil {
		t.Fatal(err)
	}
	err := sendAgentInteractionInput(context.Background(), runtime, "sess-notes", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"answerOrder": []any{"q1"},
			"answerIndices": map[string]any{
				"q1": []any{1},
			},
			"customAnswers": map[string]any{
				"q1": "additional context",
			},
		},
	})
	if err != nil {
		t.Fatalf("sendAgentInteractionInput failed: %v", err)
	}
	if len(runtime.writes) != 4 {
		t.Fatalf("writes = %#v, want down, tab, note, enter", runtime.writes)
	}
	if got := string(runtime.writes[0]); got != "\x1b[B" {
		t.Fatalf("write[0] = %q, want down arrow", got)
	}
	if got := string(runtime.writes[1]); got != "\t" {
		t.Fatalf("write[1] = %q, want Tab", got)
	}
	if got := string(runtime.writes[2]); got != "additional context" {
		t.Fatalf("write[2] = %q, want note text", got)
	}
	if got := string(runtime.writes[3]); got != "\r" {
		t.Fatalf("write[3] = %q, want Enter", got)
	}
}

func TestSendAgentGoalInputReplaceUsesCodexEditPrompt(t *testing.T) {
	runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
		t.Fatal(err)
	}
	if err := sendAgentGoalInputMode(
		context.Background(),
		runtime,
		"sess",
		"new objective\nwith details",
		true,
	); err != nil {
		t.Fatalf("sendAgentGoalInputMode failed: %v", err)
	}
	if len(runtime.writes) != 5 {
		t.Fatalf("writes = %#v, want edit, enter, clear, objective, enter", runtime.writes)
	}
	if got := string(runtime.writes[0]); got != "/goal edit" {
		t.Fatalf("edit command = %q, want /goal edit", got)
	}
	if got := string(runtime.writes[1]); got != "\r" {
		t.Fatalf("edit submit = %q, want separate Enter", got)
	}
	if len(runtime.writes[2]) != agentGoalMaxObjective+1 {
		t.Fatalf("clear key count = %d, want %d", len(runtime.writes[2]), agentGoalMaxObjective+1)
	}
	for index, value := range runtime.writes[2] {
		if value != 0x15 {
			t.Fatalf("clear key %d = %#x, want Ctrl-U", index, value)
		}
	}
	wantObjective := "\x1b[200~new objective\rwith details\x1b[201~"
	if got := string(runtime.writes[3]); got != wantObjective {
		t.Fatalf("objective write = %q, want %q", got, wantObjective)
	}
	if got := string(runtime.writes[4]); got != "\r" {
		t.Fatalf("objective submit = %q, want separate Enter", got)
	}
}

func TestSendAgentGoalInputNewGoalAndClearUseSlashCommands(t *testing.T) {
	for _, test := range []struct {
		name  string
		value string
		want  string
	}{
		{name: "new", value: "new objective", want: "/goal new objective"},
		{name: "clear", value: "clear", want: "/goal clear"},
	} {
		t.Run(test.name, func(t *testing.T) {
			runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
			if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
				t.Fatal(err)
			}
			if err := sendAgentGoalInput(context.Background(), runtime, "sess", test.value); err != nil {
				t.Fatalf("sendAgentGoalInput failed: %v", err)
			}
			if len(runtime.writes) != 2 || string(runtime.writes[0]) != test.want || string(runtime.writes[1]) != "\r" {
				t.Fatalf("writes = %#v, want %q followed by Enter", runtime.writes, test.want)
			}
		})
	}
}

func TestAgentViewDoesNotGuessPTYInteractionAnswers(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "pty-fallback-test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "agent-fallback-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "claude", Runtime: "runtime", Lifecycle: "running",
			Title: "Claude", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := newMemoryRuntime(t)
	if err := runtime.Create(context.Background(), "runtime", "", "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}

	// Record pending permission
	service.recordAgentEvents(sessionID, []api.AgentEvent{{
		Type: "permission",
		ID:   "perm-1",
		Payload: map[string]any{
			"requestId": "req-perm-1",
			"state":     "pending",
		},
	}}, api.AgentStatus{Activity: api.AgentActivityBlocked})

	// A transcript-only TUI has no provider-native interaction bridge. The
	// Host must not guess that the current prompt still means "allow".
	request := api.AgentInteractionResponse{
		Session: sessionID, RequestID: "req-perm-1", Kind: "permission",
		Response: map[string]any{"decision": "allow"},
	}
	if _, err := service.respondAgentInteraction(context.Background(), request); err == nil || !strings.Contains(err.Error(), "transport is unavailable") {
		t.Fatalf("respondAgentInteraction error = %v, want unavailable transport", err)
	}

	// Verify no guessed y\r reached the terminal.
	captured, err := runtime.Capture(context.Background(), "runtime")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(captured, []byte("y\r")) {
		t.Fatalf("captured = %q, did not expect guessed permission input", string(captured))
	}

	// The interaction remains pending for a native bridge/client retry.
	stateStr, found := service.agentInteractionState(sessionID, "req-perm-1", "permission")
	if !found || stateStr != "pending" {
		t.Fatalf("agentInteractionState = (%q, %v), want (\"pending\", true)", stateStr, found)
	}
}

func TestCanonicalInteractionResolutionValidationIsBounded(t *testing.T) {
	permission := canonicalInteractionProjection{
		kind:      "permission",
		version:   1,
		optionIDs: map[string]struct{}{"allow": {}, "deny": {}},
	}
	if err := validateCanonicalInteractionResolution(permission, map[string]any{"decision": "allow"}); err != nil {
		t.Fatalf("valid permission resolution rejected: %v", err)
	}
	if err := validateCanonicalInteractionResolution(permission, map[string]any{"decision": "maybe"}); err == nil {
		t.Fatal("unknown permission option was accepted")
	}
	if err := validateCanonicalInteractionResolution(permission, map[string]any{}); err == nil {
		t.Fatal("empty permission resolution was accepted")
	}

	question := canonicalInteractionProjection{
		kind:      "question",
		version:   1,
		optionIDs: map[string]struct{}{"one": {}, "two": {}},
	}
	if err := validateCanonicalInteractionResolution(question, map[string]any{
		"answers": map[string]any{"q1": []any{"one"}},
	}); err != nil {
		t.Fatalf("valid question resolution rejected: %v", err)
	}
	if err := validateCanonicalInteractionResolution(question, map[string]any{
		"answers": map[string]any{"q1": []any{"three"}},
	}); err == nil {
		t.Fatal("unknown question option was accepted")
	}

	confirmation := canonicalInteractionProjection{kind: "confirmation", version: 1}
	if err := validateCanonicalInteractionResolution(confirmation, map[string]any{"decision": "confirm"}); err != nil {
		t.Fatalf("valid confirmation resolution rejected: %v", err)
	}
	if err := validateCanonicalInteractionResolution(confirmation, map[string]any{"cancelled": true}); err != nil {
		t.Fatalf("cancelled confirmation rejected: %v", err)
	}
}

func TestProviderInteractionResolvedDoesNotDuplicateHostResolution(t *testing.T) {
	service := newAgentViewTestService(t, &recordingAgentViewController{})
	sessionID := "agent-view-session"
	service.recordAgentEvents(sessionID, []api.AgentEvent{{
		Type: "question",
		ID:   "question-duplicate",
		Payload: map[string]any{
			"requestId": "request-duplicate",
			"kind":      "question",
			"state":     "pending",
		},
	}}, api.AgentStatus{Activity: api.AgentActivityBlocked})
	if _, err := service.respondAgentInteraction(context.Background(), api.AgentInteractionResponse{
		Session:   sessionID,
		RequestID: "request-duplicate",
		Kind:      "question",
		Response:  map[string]any{"text": "answer"},
	}); err != nil {
		t.Fatalf("host interaction response failed: %v", err)
	}
	before, err := service.canonicalHistoryPage(context.Background(), service.canonicalExecutionID(sessionID), 0, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	resolvedBefore := 0
	for _, event := range before.Events {
		if event.Type == "interaction.resolved" {
			resolvedBefore++
		}
	}
	service.recordAgentEvents(sessionID, []api.AgentEvent{{
		Type: "interaction.resolved",
		ID:   "provider-resolution",
		Payload: map[string]any{
			// Providers commonly echo only requestId/state. The Host's local
			// resolution already owns this lifecycle row, so this observation
			// must not create a second canonical resolved event.
			"requestId": "request-duplicate",
			"state":     "resolved",
		},
	}}, api.AgentStatus{Activity: api.AgentActivityReady})
	after, err := service.canonicalHistoryPage(context.Background(), service.canonicalExecutionID(sessionID), 0, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	resolvedAfter := 0
	for _, event := range after.Events {
		if event.Type == "interaction.resolved" {
			resolvedAfter++
		}
	}
	if resolvedBefore != 1 || resolvedAfter != resolvedBefore {
		t.Fatalf("resolved event count before=%d after=%d, want one stable row", resolvedBefore, resolvedAfter)
	}
}

func TestNativeInteractionResolutionPreservesQuestionSchema(t *testing.T) {
	service := newAgentViewTestService(t, &recordingAgentViewController{})
	sessionID := "agent-view-session"
	service.recordAgentEvents(sessionID, []api.AgentEvent{{
		Type: "question",
		ID:   "question-schema",
		Payload: map[string]any{
			"requestId": "request-schema",
			"kind":      "question",
			"state":     "pending",
			"title":     "Question",
			"questions": []any{
				map[string]any{
					"id":       "q1",
					"prompt":   "Continue?",
					"required": true,
					"options": []any{
						map[string]any{"id": "yes", "label": "Yes"},
					},
				},
			},
		},
	}}, api.AgentStatus{Activity: api.AgentActivityBlocked})
	if _, err := service.respondAgentInteraction(context.Background(), api.AgentInteractionResponse{
		Session:   sessionID,
		RequestID: "request-schema",
		Kind:      "question",
		Response: map[string]any{
			"answers": map[string]any{"q1": []any{"yes"}},
		},
	}); err != nil {
		t.Fatalf("host interaction response failed: %v", err)
	}
	history, err := service.canonicalHistoryPage(context.Background(), service.canonicalExecutionID(sessionID), 0, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range history.Events {
		if event.Type != "interaction.resolved" {
			continue
		}
		questions, ok := event.Payload["questions"].([]any)
		if !ok || len(questions) != 1 {
			t.Fatalf("resolved payload dropped questions: %#v", event.Payload)
		}
		return
	}
	t.Fatal("resolved interaction event not found")
}
