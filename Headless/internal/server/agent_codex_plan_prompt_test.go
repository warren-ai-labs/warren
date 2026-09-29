package server

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

const codexPlanPromptRequest = "codex-plan-implementation-turn-1"

// newCodexPlanPromptService is a transcript-only Codex session whose picker
// is on screen, as the parser reports it after a Plan mode turn.
func newCodexPlanPromptService(t *testing.T) (*Service, *inputRecordingRuntime, string) {
	t.Helper()
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "codex-plan-prompt-test")
	if err != nil {
		t.Fatal(err)
	}
	sessionID := "codex-plan-session"
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: sessionID, Kind: "codex", Runtime: "runtime", Lifecycle: "running",
			Title: "Codex", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	if err := runtime.Create(context.Background(), "runtime", "", "", nil); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: runtime}
	service.lazyInit()
	service.agents[sessionID] = &agentSession{}
	service.recordAgentEvents(sessionID, []api.AgentEvent{{
		Type: "confirmation", ID: codexPlanPromptRequest, Provider: "codex",
		Payload: map[string]any{
			"requestId": codexPlanPromptRequest,
			"title":     "Implement this plan?",
			"action":    agent.PlanImplementationAction,
			"options": []any{
				map[string]any{"id": agent.PlanImplementationImplement, "label": "Yes, implement this plan"},
				map[string]any{"id": agent.PlanImplementationClearContext, "label": "Yes, clear context and implement"},
				map[string]any{"id": agent.PlanImplementationKeepPlanning, "label": "No, stay in Plan mode"},
			},
			"state": "pending",
		},
	}}, codexPlanPromptStatus())
	return service, runtime, sessionID
}

func codexPlanPromptStatus() api.AgentStatus {
	return api.AgentStatus{
		Activity: api.AgentActivityReady,
		Attention: &api.AgentAttention{
			Kind: api.AgentAttentionInput, Reason: agent.PlanImplementationAction, RequestID: codexPlanPromptRequest,
		},
	}
}

func respondCodexPlanPrompt(t *testing.T, service *Service, sessionID string, response map[string]any) {
	t.Helper()
	if _, err := service.respondAgentInteraction(context.Background(), api.AgentInteractionResponse{
		Session: sessionID, RequestID: codexPlanPromptRequest, Kind: "confirmation", Response: response,
	}); err != nil {
		t.Fatalf("respondAgentInteraction: %v", err)
	}
}

func TestCodexPlanPromptImplementPressesItsRowAndWaitsForTheTurn(t *testing.T) {
	service, runtime, sessionID := newCodexPlanPromptService(t)
	respondCodexPlanPrompt(t, service, sessionID, map[string]any{"decision": agent.PlanImplementationImplement})
	if got := recordedKeys(runtime.writes); got != "text:1" {
		t.Fatalf("keys = %q, want the picker's first row", got)
	}
	// The parser settles this answer from the "Implement the plan." turn.
	if state, _ := service.agentInteractionState(sessionID, codexPlanPromptRequest, "confirmation"); state != "pending" {
		t.Fatalf("state = %q, want pending until the turn is observed", state)
	}
}

func TestCodexPlanPromptKeepPlanningIsSettledByTheHost(t *testing.T) {
	service, runtime, sessionID := newCodexPlanPromptService(t)
	respondCodexPlanPrompt(t, service, sessionID, map[string]any{"decision": agent.PlanImplementationKeepPlanning})
	if got := recordedKeys(runtime.writes); got != "text:3" {
		t.Fatalf("keys = %q, want the picker's third row", got)
	}
	if state, _ := service.agentInteractionState(sessionID, codexPlanPromptRequest, "confirmation"); state != "resolved" {
		t.Fatalf("state = %q, want resolved", state)
	}
	if status := service.agentStatus(sessionID); status.Attention != nil || status.Activity != api.AgentActivityReady {
		t.Fatalf("status = %#v, want ready without attention", status)
	}
	// The parser still reports the picker until the next turn; the settled
	// request must not come back.
	service.recordAgentStatus(sessionID, codexPlanPromptStatus())
	if status := service.agentStatus(sessionID); status.Attention != nil {
		t.Fatalf("attention = %#v, want the settled picker dropped", status.Attention)
	}
}

func TestCodexPlanPromptCancelDismissesWithEscape(t *testing.T) {
	service, runtime, sessionID := newCodexPlanPromptService(t)
	respondCodexPlanPrompt(t, service, sessionID, map[string]any{"cancelled": true})
	if got := recordedKeys(runtime.writes); got != "text:3" {
		t.Fatalf("keys = %q, want stay in Plan mode", got)
	}
}

func TestCodexPlanPromptClosesBeforeAMessageIsTyped(t *testing.T) {
	service, runtime, sessionID := newCodexPlanPromptService(t)
	if _, err := service.sendAgentMessage(context.Background(), api.AgentMessageSendRequest{
		Session: sessionID, ClientMessageID: "m1", Text: "Step 2 first",
	}); err != nil {
		t.Fatal(err)
	}
	if got := recordedKeys(runtime.writes); got != "Esc text:Step 2 first Enter" {
		t.Fatalf("keys = %q, want Esc before the message", got)
	}
}

func TestCodexPlanPromptExpiresOnDirectTerminalKeys(t *testing.T) {
	service, _, sessionID := newCodexPlanPromptService(t)
	service.noteDirectTerminalInput(sessionID, []byte("\x1b[I"))
	if status := service.agentStatus(sessionID); status.Attention == nil {
		t.Fatal("a focus report must not withdraw the picker")
	}
	service.noteDirectTerminalInput(sessionID, []byte("3"))
	if state, _ := service.agentInteractionState(sessionID, codexPlanPromptRequest, "confirmation"); state != "expired" {
		t.Fatalf("state = %q, want expired", state)
	}
	if status := service.agentStatus(sessionID); status.Attention != nil {
		t.Fatalf("attention = %#v, want cleared", status.Attention)
	}
}
