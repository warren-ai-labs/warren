package agent

import (
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// pendingToolTimeout is a liveness warning, not an input timeout. A short
// tool call can be perfectly normal, so five seconds must never turn a
// session yellow.
const pendingToolTimeout = 30 * time.Second

// ActivityTracker folds normalized transcript events into an AgentStatus. It
// owns lifecycle and liveness state; provider-specific attention observations
// can be applied through MarkAttention without teaching the tracker provider
// event names.
type ActivityTracker struct {
	status       api.AgentStatus
	pendingTools int
	pendingSince time.Time
	turn         uint64
	turnActive   bool
	turns        []api.AgentTurn
}

// NewActivityTracker starts an agent in the ready state: open and idle.
func NewActivityTracker() *ActivityTracker {
	return &ActivityTracker{status: api.AgentStatus{Activity: api.AgentActivityReady}}
}

// Status returns the current complete presentation state.
func (t *ActivityTracker) Status() api.AgentStatus {
	status := t.status
	if status.Activity == "" {
		status.Activity = api.AgentActivityReady
	}
	if t.status.Attention != nil {
		attention := *t.status.Attention
		status.Attention = &attention
	}
	return status
}

// Activity returns the lifecycle portion of Status.
func (t *ActivityTracker) Activity() api.AgentActivity {
	return t.Status().Activity
}

// Observe advances the tracker from one normalized transcript event.
func (t *ActivityTracker) Observe(event api.AgentEvent) {
	if event.Sidechain {
		return
	}
	if isInterruptedStopReason(event.StopReason) {
		t.TurnInterrupted()
		return
	}
	switch event.Type {
	case "user":
		t.TurnStarted()
	case "tool_call":
		t.toolStarted(event.Timestamp)
	case "tool_output":
		failed := event.ToolStatus == "error"
		t.toolFinished(failed)
		if !failed && event.StopReason == "stop" {
			t.TurnComplete()
		}
	case "error":
		t.TurnFailed()
	case "assistant":
		// Codex historically called this boundary end_turn while OpenCode
		// stores the provider-native value stop. Other model providers can
		// terminate with a length/content-filter result; those are terminal
		// turns too, while an explicit provider error is a failed turn.
		if completed, failed := observeStopReason(event.StopReason); failed {
			t.TurnFailed()
		} else if completed {
			t.TurnComplete()
		}
	}
	// OpenCode attaches the final `finish` value to the last part in a
	// message. That part can be a successful tool output or a reasoning block,
	// not an assistant text event. Preserve the boundary without manufacturing
	// an empty assistant message in the transcript projection.
	if event.Type != "assistant" && event.Type != "error" && event.ToolStatus != "error" {
		if completed, failed := observeStopReason(event.StopReason); failed {
			t.TurnFailed()
		} else if completed {
			t.TurnComplete()
		}
	}
}

func isInterruptedStopReason(reason string) bool {
	switch strings.ToLower(strings.TrimSpace(reason)) {
	case "interrupted", "aborted", "cancelled", "canceled":
		return true
	default:
		return false
	}
}

func observeStopReason(reason string) (completed, failed bool) {
	switch strings.ToLower(strings.TrimSpace(reason)) {
	case "end_turn", "stop", "stop_sequence", "length", "content-filter", "content_filter", "max_tokens", "other":
		return true, false
	case "error":
		return false, true
	default:
		return false, false
	}
}

// TurnStarted marks the beginning of a new turn and clears attention from a
// request that the new user turn supersedes.
func (t *ActivityTracker) TurnStarted() {
	if !t.turnActive {
		t.turn++
		t.turnActive = true
		t.turns = append(t.turns, api.AgentTurn{ID: t.turn, Status: api.AgentTurnStarted})
	}
	t.clearAttention()
	t.working()
}

// TurnComplete marks a finished turn. The agent is idle and ready for the
// next instruction.
func (t *ActivityTracker) TurnComplete() {
	t.resetPendingTools()
	t.finishTurn(api.AgentTurnCompleted)
	t.setActivity(api.AgentActivityReady)
	t.clearAttention()
}

// TurnFailed marks a turn that ended with an error.
func (t *ActivityTracker) TurnFailed() {
	t.resetPendingTools()
	t.finishTurn(api.AgentTurnFailed)
	t.setActivity(api.AgentActivityFailed)
	t.clearAttention()
}

// TurnInterrupted marks a provider-observed interruption. The provider does
// not know whether a Warren cancel command caused it, so Host correlation is
// deliberately left to the service layer.
func (t *ActivityTracker) TurnInterrupted() {
	t.resetPendingTools()
	t.finishTurn(api.AgentTurnInterrupted)
	t.setActivity(api.AgentActivityReady)
	t.clearAttention()
}

// TurnAborted is kept as a source-compatible alias for provider adapters that
// still use the older name. New adapters should call TurnInterrupted.
func (t *ActivityTracker) TurnAborted() {
	t.TurnInterrupted()
}

// MarkAttention applies a provider-neutral human-facing observation. The
// reducer owns the resulting activity so callers cannot accidentally create a
// yellow state without the corresponding blocked/warning lifecycle state.
func (t *ActivityTracker) MarkAttention(kind api.AgentAttentionKind, reason, requestID string, since time.Time) {
	if kind == "" {
		t.clearAttention()
		if t.status.Activity == api.AgentActivityBlocked || t.status.Activity == api.AgentActivityStalled {
			t.working()
		}
		return
	}
	if since.IsZero() {
		since = time.Now()
	}
	t.status.Attention = &api.AgentAttention{
		Kind:      kind,
		Reason:    reason,
		RequestID: requestID,
		Since:     since,
	}
	if kind == api.AgentAttentionInput || kind == api.AgentAttentionApproval {
		t.setActivity(api.AgentActivityBlocked)
	} else {
		t.setActivity(api.AgentActivityStalled)
	}
}

// ClearAttention removes a pending human-facing condition without changing
// the current lifecycle state unless it was blocked or stalled by the attention.
func (t *ActivityTracker) ClearAttention() {
	t.clearAttention()
	if t.status.Activity == api.AgentActivityBlocked || t.status.Activity == api.AgentActivityStalled {
		t.working()
	}
}

// Turn returns the current turn number. It remains stable after completion so
// events emitted at the boundary can still be associated with that turn.
func (t *ActivityTracker) Turn() uint64 {
	return t.turn
}

// DrainTurns returns lifecycle transitions observed since the previous call.
func (t *ActivityTracker) DrainTurns() []api.AgentTurn {
	turns := append([]api.AgentTurn(nil), t.turns...)
	t.turns = t.turns[:0]
	return turns
}

func (t *ActivityTracker) finishTurn(status api.AgentTurnStatus) {
	if !t.turnActive {
		return
	}
	t.turnActive = false
	t.turns = append(t.turns, api.AgentTurn{ID: t.turn, Status: status})
}

// Exited marks the agent process as gone.
func (t *ActivityTracker) Exited() {
	t.resetPendingTools()
	t.setActivity(api.AgentActivityExited)
	t.clearAttention()
}

// Tick notices a tool call that has made no progress for the liveness grace
// period. It intentionally produces a stalled warning, never an input or
// approval request.
func (t *ActivityTracker) Tick(now time.Time) {
	if t.status.Activity != api.AgentActivityWorking || t.pendingTools == 0 || t.pendingSince.IsZero() {
		return
	}
	if now.Sub(t.pendingSince) >= pendingToolTimeout {
		t.MarkAttention(api.AgentAttentionWarning, "stalled", "", t.pendingSince)
	}
}

func (t *ActivityTracker) working() {
	t.setActivity(api.AgentActivityWorking)
}

func (t *ActivityTracker) toolStarted(at time.Time) {
	t.pendingTools++
	if t.pendingSince.IsZero() {
		if at.IsZero() {
			at = time.Now()
		}
		t.pendingSince = at
	}
	t.clearAttention()
	t.working()
}

func (t *ActivityTracker) toolFinished(failed bool) {
	if t.pendingTools > 0 {
		t.pendingTools--
	}
	if t.pendingTools == 0 {
		t.pendingSince = time.Time{}
	}
	if failed {
		t.TurnFailed()
		return
	}
	if t.status.Activity == api.AgentActivityStalled {
		t.clearAttention()
		t.working()
	}
}

func (t *ActivityTracker) resetPendingTools() {
	t.pendingTools = 0
	t.pendingSince = time.Time{}
}

func (t *ActivityTracker) clearAttention() {
	t.status.Attention = nil
}

func (t *ActivityTracker) setActivity(state api.AgentActivity) {
	t.status.Activity = state
}
