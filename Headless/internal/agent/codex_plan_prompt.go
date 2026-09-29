package agent

import (
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Codex's TUI asks "Implement this plan?" when a Plan mode turn that proposed
// a plan completes. The picker is drawn only on screen; the rollout records
// nothing until the user's choice starts the next turn. The Host projects the
// picker as a confirmation so clients can answer it, and names each option
// after the picker row it selects.
const (
	PlanImplementationAction        = "plan_implementation"
	PlanImplementationImplement     = "yes"
	PlanImplementationClearContext  = "yes_clear_context"
	PlanImplementationKeepPlanning  = "keep_planning"
	codexPlanImplementationMessage  = "Implement the plan."
	codexPlanImplementationRequest  = "codex-plan-implementation-"
	codexPlanImplementationTitle    = "Implement this plan?"
	codexCollaborationModePlanValue = "plan"
)

// codexPlanPrompt is the picker the TUI is showing, or the one whose answer
// the next turn is about to reveal.
type codexPlanPrompt struct {
	requestID string
	proposal  api.AgentEvent
	// closing is set once the next turn starts: that turn's first user
	// message tells whether the user chose to implement the plan.
	closing bool
}

// noteCodexProposal remembers the latest proposed plan of the running turn;
// the TUI offers to implement the latest one.
func (p *codexParser) noteCodexProposal(events []api.AgentEvent) []api.AgentEvent {
	for _, event := range events {
		if event.Type == "plan" && event.Payload["proposal"] == true {
			proposal := event
			p.codexTurnProposal = &proposal
		}
	}
	return events
}

// openCodexPlanPrompt mirrors the TUI's condition for the picker: the turn
// completed normally in Plan mode and proposed a plan.
func (p *codexParser) openCodexPlanPrompt(event api.AgentEvent, turnID string) []api.AgentEvent {
	proposal := p.codexTurnProposal
	p.codexTurnProposal = nil
	if !p.codexTurnPlanMode || proposal == nil {
		return nil
	}
	requestID := codexPlanImplementationRequest + firstNonEmpty(strings.TrimSpace(turnID), proposal.ID)
	p.codexPlanPrompt = &codexPlanPrompt{requestID: requestID, proposal: *proposal}
	p.tracker.MarkIdleAttention(api.AgentAttentionInput, PlanImplementationAction, requestID, event.Timestamp)
	title, _ := proposal.Payload["title"].(string)
	event.ID = requestID
	event.Type = "confirmation"
	event.Payload = map[string]any{
		"requestId":   requestID,
		"title":       codexPlanImplementationTitle,
		"description": title,
		"action":      PlanImplementationAction,
		"planId":      proposal.ID,
		"options": []any{
			map[string]any{"id": PlanImplementationImplement, "label": "Yes, implement this plan", "description": "Switch to Default and start coding"},
			map[string]any{"id": PlanImplementationClearContext, "label": "Yes, clear context and implement", "description": "Fresh thread with this plan"},
			map[string]any{"id": PlanImplementationKeepPlanning, "label": "No, stay in Plan mode", "description": "Continue planning with the model"},
		},
		"state": "pending",
	}
	return []api.AgentEvent{event}
}

// settleCodexPlanPrompt closes the picker from the first user message of the
// turn that followed it. The TUI's Yes submits a fixed message in Default
// mode; anything else means the picker was dismissed and the user typed on.
func (p *codexParser) settleCodexPlanPrompt(user api.AgentEvent) []api.AgentEvent {
	prompt := p.codexPlanPrompt
	if prompt == nil || !prompt.closing {
		return nil
	}
	p.codexPlanPrompt = nil
	if strings.TrimSpace(user.Content) != codexPlanImplementationMessage || p.codexTurnPlanMode {
		return []api.AgentEvent{codexPlanPromptResult(prompt, user.Timestamp, "expired", nil)}
	}
	approved := prompt.proposal
	approved.Timestamp = user.Timestamp
	approved.Payload = make(map[string]any, len(prompt.proposal.Payload))
	for key, value := range prompt.proposal.Payload {
		approved.Payload[key] = value
	}
	approved.Payload["state"] = "approved"
	return []api.AgentEvent{
		codexPlanPromptResult(prompt, user.Timestamp, "resolved", map[string]any{"decision": PlanImplementationImplement}),
		approved,
	}
}

// expireCodexPlanPrompt withdraws a picker whose follow-up turn ended before
// a user message said what was chosen.
func (p *codexParser) expireCodexPlanPrompt(timestamp time.Time) []api.AgentEvent {
	prompt := p.codexPlanPrompt
	if prompt == nil || !prompt.closing {
		return nil
	}
	p.codexPlanPrompt = nil
	return []api.AgentEvent{codexPlanPromptResult(prompt, timestamp, "expired", nil)}
}

func codexPlanPromptResult(prompt *codexPlanPrompt, timestamp time.Time, state string, response map[string]any) api.AgentEvent {
	payload := map[string]any{
		"requestId": prompt.requestID,
		"title":     codexPlanImplementationTitle,
		"action":    PlanImplementationAction,
		"state":     state,
	}
	if response != nil {
		payload["response"] = response
	}
	return api.AgentEvent{
		ID:        prompt.requestID,
		Provider:  prompt.proposal.Provider,
		Type:      "confirmation",
		Timestamp: timestamp,
		Payload:   payload,
	}
}
