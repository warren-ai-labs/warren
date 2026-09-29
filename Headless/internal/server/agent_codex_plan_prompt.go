package server

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Codex's "Implement this plan?" picker selects a row by its number and
// dismisses with Esc. Its rows, in order: implement, clear context and
// implement, stay in Plan mode.
var codexPlanPromptKeys = map[string][]byte{
	agent.PlanImplementationImplement:    {'1'},
	agent.PlanImplementationClearContext: {'2'},
	agent.PlanImplementationKeepPlanning: {'3'},
}

var codexKeyEscape = []byte{0x1b}

func isCodexPlanPrompt(kind string, payload map[string]any) bool {
	return kind == "confirmation" && agentStringValue(payload["action"]) == agent.PlanImplementationAction
}

// codexPlanPromptDecision is the picker row a response selects. Cancelling
// dismisses the picker, which is the same as staying in Plan mode.
func codexPlanPromptDecision(response map[string]any) (string, error) {
	if cancelled, _ := response["cancelled"].(bool); cancelled {
		return agent.PlanImplementationKeepPlanning, nil
	}
	decision := strings.TrimSpace(agentStringValue(response["decision"]))
	if strings.EqualFold(decision, "cancel") {
		return agent.PlanImplementationKeepPlanning, nil
	}
	if _, ok := codexPlanPromptKeys[decision]; !ok {
		return "", fmt.Errorf("plan implementation has no option %q", decision)
	}
	return decision, nil
}

func sendCodexPlanPromptInput(ctx context.Context, runtime Runtime, sessionID string, request api.AgentInteractionResponse) error {
	if request.Response == nil {
		return errors.New("interaction response is required")
	}
	decision, err := codexPlanPromptDecision(request.Response)
	if err != nil {
		return err
	}
	return runtime.Input(ctx, sessionID, codexPlanPromptKeys[decision])
}

// codexPlanPromptSettledByHost reports whether the Host must record the
// answer itself. Implementing the plan starts a turn whose message the parser
// recognizes; the other rows leave nothing in this rollout — staying in Plan
// mode records nothing, and clearing context continues in a new thread.
func codexPlanPromptSettledByHost(request api.AgentInteractionResponse) bool {
	decision, err := codexPlanPromptDecision(request.Response)
	return err == nil && decision != agent.PlanImplementationImplement
}

func isCodexPlanPromptAttention(status api.AgentStatus) bool {
	return status.Attention != nil && status.Attention.Reason == agent.PlanImplementationAction
}

// dismissCodexPlanPrompt closes a pending picker before a message is typed.
// The picker owns the keyboard: a digit in the text would select a row, and
// the submitting Enter would implement the plan.
func dismissCodexPlanPrompt(ctx context.Context, runtime Runtime, sessionID string, status api.AgentStatus) error {
	if !isCodexPlanPromptAttention(status) {
		return nil
	}
	if err := runtime.Input(ctx, sessionID, codexKeyEscape); err != nil {
		return err
	}
	return waitAgentTerminalKey(ctx)
}

// withoutSettledPlanPrompt drops attention for a picker the Host already
// settled. The parser cannot see an answer that leaves no rollout record, so
// it keeps reporting the picker until the next turn, and replays it after a
// restart.
func withoutSettledPlanPrompt(entry *agentSession, status api.AgentStatus) api.AgentStatus {
	if !isCodexPlanPromptAttention(status) || !canonicalEntryHasTerminalInteraction(entry, status.Attention.RequestID) {
		return status
	}
	status.Attention = nil
	if status.Activity == api.AgentActivityBlocked {
		status.Activity = api.AgentActivityReady
	}
	return status
}

// settleCodexPlanPromptAttention clears the session's attention once its
// picker has a terminal record.
func (s *Service) settleCodexPlanPromptAttention(sessionID string) {
	status := s.agentStatus(sessionID)
	if !isCodexPlanPromptAttention(status) {
		return
	}
	s.agentsMu.Lock()
	entry := s.agents[sessionID]
	s.agentsMu.Unlock()
	if entry == nil {
		return
	}
	entry.mu.Lock()
	settled := withoutSettledPlanPrompt(entry, status)
	entry.mu.Unlock()
	if settled.Attention == nil {
		s.setAgentStatusForHandle(sessionID, nil, settled, false)
	}
}

// noteDirectTerminalInput withdraws a pending picker when someone types into
// the terminal: the keys may have answered or dismissed it, and neither
// leaves a record. Focus reports carry no intent and are ignored.
func (s *Service) noteDirectTerminalInput(sessionID string, payload []byte) {
	if !isTerminalKeyInput(payload) {
		return
	}
	status := s.agentStatus(sessionID)
	if !isCodexPlanPromptAttention(status) {
		return
	}
	s.recordAgentInteractionTerminal(api.AgentInteractionResponse{
		Session:   sessionID,
		RequestID: status.Attention.RequestID,
		Kind:      "confirmation",
		Response:  map[string]any{"reason": "terminal"},
	}, "expired")
	s.settleCodexPlanPromptAttention(sessionID)
}

func isTerminalKeyInput(payload []byte) bool {
	for _, report := range [][]byte{[]byte("\x1b[I"), []byte("\x1b[O")} {
		payload = bytes.ReplaceAll(payload, report, nil)
	}
	return len(payload) > 0
}
