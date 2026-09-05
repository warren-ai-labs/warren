package server

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestRealPTYGuardrailsAndBracketedPaste(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	ctx := context.Background()

	runtimeName := "real-pty-guard-test"
	// Run cat so any input injected into the PTY is echoed back to the PTY output
	if err := runtime.Create(ctx, runtimeName, t.TempDir(), "cat", nil); err != nil {
		t.Fatalf("Create real pty: %v", err)
	}
	defer runtime.Kill(ctx, runtimeName)

	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "real-pty-guard-test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "agent-real-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "codex", Runtime: runtimeName, Lifecycle: "running",
			Title: "Codex", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}

	// 1. Verify Blocked Guard on real PTY
	service.agents[sessionID].status = api.AgentStatus{
		Activity:  api.AgentActivityBlocked,
		Attention: &api.AgentAttention{Kind: "approval", Reason: "permission needed"},
	}
	msgBlocked := api.AgentMessageSendRequest{
		Session: sessionID, ClientMessageID: "msg-blocked", Text: "blocked payload",
	}
	if _, err := service.sendAgentMessage(ctx, msgBlocked); !errors.Is(err, api.ErrAgentBlocked) {
		t.Fatalf("sendAgentMessage on blocked = %v, want %v", err, api.ErrAgentBlocked)
	}

	// Give any background I/O a moment to ensure nothing reaches the real PTY
	time.Sleep(100 * time.Millisecond)
	captured, err := runtime.Capture(ctx, runtimeName)
	if err != nil {
		t.Fatalf("Capture real pty: %v", err)
	}
	if bytes.Contains(captured, []byte("blocked payload")) {
		t.Fatalf("real PTY leaked blocked payload: %q", captured)
	}

	// 2. Verify Busy / Working Guard on real PTY
	service.agents[sessionID].status = api.AgentStatus{
		Activity: api.AgentActivityWorking,
	}
	msgWorking := api.AgentMessageSendRequest{
		Session: sessionID, ClientMessageID: "msg-working", Text: "working payload",
	}
	if _, err := service.sendAgentMessage(ctx, msgWorking); !errors.Is(err, api.ErrAgentBusy) {
		t.Fatalf("sendAgentMessage on working = %v, want %v", err, api.ErrAgentBusy)
	}

	time.Sleep(100 * time.Millisecond)
	captured, err = runtime.Capture(ctx, runtimeName)
	if err != nil {
		t.Fatalf("Capture real pty: %v", err)
	}
	if bytes.Contains(captured, []byte("working payload")) {
		t.Fatalf("real PTY leaked working payload: %q", captured)
	}

	// 3. Verify Ready State writes with Bracketed Paste Mode framing to real PTY
	service.agents[sessionID].status = api.AgentStatus{
		Activity: api.AgentActivityReady,
	}
	msgReady := api.AgentMessageSendRequest{
		Session: sessionID, ClientMessageID: "msg-ready", Text: "first line\nsecond line",
	}
	res, err := service.sendAgentMessage(ctx, msgReady)
	if err != nil {
		t.Fatalf("sendAgentMessage on ready failed: %v", err)
	}
	if !res.Accepted || res.ClientMessageID != "msg-ready" {
		t.Fatalf("res = %#v, want accepted", res)
	}

	// Wait for cat to echo the bracketed paste input from real PTY
	waitGhostlineOutput(t, runtime, runtimeName, "first line")
	waitGhostlineOutput(t, runtime, runtimeName, "second line")
	waitGhostlineOutput(t, runtime, runtimeName, "200~")
	waitGhostlineOutput(t, runtime, runtimeName, "201~")
	waitGhostlineOutput(t, runtime, runtimeName, "13u")
}
