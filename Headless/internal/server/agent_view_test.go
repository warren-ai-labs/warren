package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

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
