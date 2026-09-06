package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// AttentionStreamID is the reserved Host-wide stream carrying sanitized
// attention changes. It is not an AgentExecution ID.
const AttentionStreamID = "host:attention:v1"

// WelcomeMessage is emitted after authentication and is the only source of
// identity used by a client replica namespace.
type WelcomeMessage struct {
	Type          string   `json:"t"`
	Version       string   `json:"version"`
	Host          Host     `json:"host"`
	AccessScopeID string   `json:"accessScopeId"`
	Capabilities  []string `json:"capabilities"`
}

// AgentTargetRef identifies the Warren resource that owns an AgentExecution.
// The target is deliberately separate from a Warren Terminal Session so a
// cloud run can have Agent semantics without allocating a PTY.
type AgentTargetRef struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}

// AgentProviderConversationRef is opaque metadata owned by Headless. Clients
// must not use the provider ID or transcript path as an event identity.
type AgentProviderConversationRef struct {
	ID             string `json:"id,omitempty"`
	TranscriptPath string `json:"transcriptPath,omitempty"`
}

type AgentExecutionState string

const (
	AgentExecutionStarting  AgentExecutionState = "starting"
	AgentExecutionReady     AgentExecutionState = "ready"
	AgentExecutionWorking   AgentExecutionState = "working"
	AgentExecutionBlocked   AgentExecutionState = "blocked"
	AgentExecutionCompleted AgentExecutionState = "completed"
	AgentExecutionFailed    AgentExecutionState = "failed"
	AgentExecutionClosed    AgentExecutionState = "closed"
)

// AgentExecution is the Host-owned identity used by the canonical Agent API.
// It is a projection and may be rebuilt from the execution event stream.
type AgentExecution struct {
	ID           string                       `json:"id"`
	StreamID     string                       `json:"streamId"`
	Target       AgentTargetRef               `json:"target"`
	Provider     string                       `json:"provider"`
	Conversation AgentProviderConversationRef `json:"conversation,omitempty"`
	Driver       string                       `json:"driver"`
	Capabilities []string                     `json:"capabilities"`
	State        AgentExecutionState          `json:"state"`
	Status       AgentStatus                  `json:"status"`
	ActiveTurn   *AgentTurn                   `json:"activeTurn,omitempty"`
	Interactions []AgentInteraction           `json:"interactions,omitempty"`
	HeadSequence uint64                       `json:"headSequence"`
}

// AgentInteraction is a typed, versioned interaction projected by the Host.
// Its schema and options are bounded by the adapter before they reach a
// client.
type AgentInteraction struct {
	ID      string                   `json:"id"`
	TurnID  string                   `json:"turnId,omitempty"`
	Kind    string                   `json:"kind"`
	Version uint64                   `json:"version"`
	Title   string                   `json:"title"`
	Schema  map[string]any           `json:"schema,omitempty"`
	Options []AgentInteractionOption `json:"options,omitempty"`
	State   string                   `json:"state"`
}

type AgentInteractionOption struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

// AgentCommand is shared by all mutating Agent methods. ExpectedVersion is
// checked by Headless before the driver is invoked; CommandID makes retries
// idempotent across reconnects.
type AgentCommand struct {
	CommandID       string `json:"commandId"`
	ExecutionID     string `json:"executionId"`
	ExpectedVersion uint64 `json:"expectedVersion,omitempty"`
	LeaseID         string `json:"leaseId,omitempty"`
}

type AgentTurnStartCommand struct {
	AgentCommand
	Text        string               `json:"text"`
	Attachments []AgentAttachmentRef `json:"attachments,omitempty"`
}

type AgentTurnSteerCommand struct {
	AgentCommand
	TurnID      string               `json:"turnId"`
	Text        string               `json:"text"`
	Attachments []AgentAttachmentRef `json:"attachments,omitempty"`
}

type AgentTurnCancelCommand struct {
	AgentCommand
	TurnID string `json:"turnId"`
	Reason string `json:"reason,omitempty"`
}

type AgentInteractionResolveCommand struct {
	AgentCommand
	InteractionID string         `json:"interactionId"`
	Version       uint64         `json:"version"`
	Resolution    map[string]any `json:"resolution"`
}

type AgentAttachmentPrepareCommand struct {
	AgentCommand
	Name   string `json:"name"`
	MIME   string `json:"mime"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256,omitempty"`
}

type AgentAttachmentChunkCommand struct {
	AgentCommand
	UploadID string `json:"uploadId"`
	Chunk    uint64 `json:"chunk"`
	Length   int    `json:"length"`
	SHA256   string `json:"sha256,omitempty"`
	Data     string `json:"data"`
}

type AgentAttachmentCompleteCommand struct {
	AgentCommand
	UploadID string `json:"uploadId"`
	Length   int64  `json:"length"`
	SHA256   string `json:"sha256,omitempty"`
}

type AgentAttachmentAbortCommand struct {
	AgentCommand
	UploadID string `json:"uploadId"`
}

type AgentCommandReceipt struct {
	CommandID string `json:"commandId"`
	Accepted  bool   `json:"accepted"`
}

type AgentEventOrigin struct {
	Kind       string `json:"kind"`
	Provider   string `json:"provider,omitempty"`
	Driver     string `json:"driver,omitempty"`
	Channel    string `json:"channel,omitempty"`
	Confidence string `json:"confidence"`
}

// CanonicalAgentEvent is the one semantic event envelope emitted by
// Headless. Payload is a discriminated object selected by Type; unknown
// fields are intentionally retained when the event is persisted.
type CanonicalAgentEvent struct {
	EventID     string           `json:"eventId"`
	StreamID    string           `json:"streamId"`
	ExecutionID string           `json:"executionId"`
	Sequence    uint64           `json:"sequence"`
	TurnID      string           `json:"turnId,omitempty"`
	Type        string           `json:"type"`
	OccurredAt  time.Time        `json:"occurredAt"`
	RecordedAt  time.Time        `json:"recordedAt"`
	CausedBy    string           `json:"causedBy,omitempty"`
	Origin      AgentEventOrigin `json:"origin"`
	Payload     map[string]any   `json:"payload"`
}

type CanonicalAgentEventsMessage struct {
	Type        string                `json:"t"`
	StreamID    string                `json:"streamId"`
	ExecutionID string                `json:"executionId,omitempty"`
	Replay      bool                  `json:"replay,omitempty"`
	Events      []CanonicalAgentEvent `json:"events"`
}

type AgentEventsHistoryRequest struct {
	StreamID       string `json:"streamId"`
	AfterSequence  uint64 `json:"afterSequence,omitempty"`
	BeforeSequence uint64 `json:"beforeSequence,omitempty"`
	Limit          uint32 `json:"limit,omitempty"`
}

type AgentEventsHistoryResult struct {
	StreamID          string                `json:"streamId"`
	ExecutionID       string                `json:"executionId,omitempty"`
	Events            []CanonicalAgentEvent `json:"events"`
	NextAfterSequence uint64                `json:"nextAfterSequence,omitempty"`
	HeadSequence      uint64                `json:"headSequence"`
	HasMore           bool                  `json:"hasMore"`
	RetainedFrom      uint64                `json:"retainedFromSequence,omitempty"`
}

type AgentEventsSubscriptionRequest struct {
	StreamID      string `json:"streamId"`
	AfterSequence uint64 `json:"afterSequence,omitempty"`
	Limit         uint32 `json:"limit,omitempty"`
}

type AgentProjectionCheckpoint struct {
	Sequence uint64         `json:"sequence"`
	State    map[string]any `json:"state"`
}

type AgentEventsSubscriptionResult struct {
	StreamID    string                    `json:"streamId"`
	ExecutionID string                    `json:"executionId,omitempty"`
	Checkpoint  AgentProjectionCheckpoint `json:"checkpoint"`
	Events      []CanonicalAgentEvent     `json:"events"`
	Live        bool                      `json:"live"`
}

// CanonicalAgentEventFromLegacy is the sole adapter from the current parser
// projection to the v3 wire envelope. It keeps Provider-specific parsing out
// of clients while allowing the parser rewrite to land independently.
func CanonicalAgentEventFromLegacy(event AgentEvent, streamID, executionID string, sequence uint64, recordedAt time.Time) CanonicalAgentEvent {
	if sequence == 0 {
		sequence = event.Sequence
	}
	if recordedAt.IsZero() {
		recordedAt = time.Now().UTC()
	}
	occurredAt := event.Timestamp
	if occurredAt.IsZero() {
		occurredAt = recordedAt
	}
	eventID := event.ID
	if eventID == "" {
		eventID = fmt.Sprintf("%s:%d", streamID, sequence)
	}
	payload := make(map[string]any)
	putAgentPayload(payload, "role", event.Role)
	putAgentPayload(payload, "content", event.Content)
	putAgentPayload(payload, "contentDelta", event.ContentDelta)
	putAgentPayload(payload, "model", event.Model)
	putAgentPayload(payload, "stopReason", event.StopReason)
	putAgentPayload(payload, "toolName", event.ToolName)
	if event.ToolInput != nil {
		payload["toolInput"] = event.ToolInput
	}
	putAgentPayload(payload, "toolStatus", event.ToolStatus)
	putAgentPayload(payload, "callId", event.CallID)
	putAgentPayload(payload, "output", event.Output)
	if len(event.Files) > 0 {
		payload["files"] = event.Files
	}
	putAgentPayload(payload, "error", event.Error)
	if event.Usage != nil {
		payload["usage"] = event.Usage
	}
	putAgentPayload(payload, "durationMs", event.DurationMs)
	putAgentPayload(payload, "sidechain", event.Sidechain)
	for key, value := range event.Payload {
		payload[key] = value
	}

	turnID := ""
	if event.Turn > 0 {
		turnID = fmt.Sprint(event.Turn)
	}
	return CanonicalAgentEvent{
		EventID:     eventID,
		StreamID:    streamID,
		ExecutionID: executionID,
		Sequence:    sequence,
		TurnID:      turnID,
		Type:        canonicalAgentEventType(event.Type, event.ContentDelta),
		OccurredAt:  occurredAt.UTC(),
		RecordedAt:  recordedAt.UTC(),
		Origin: AgentEventOrigin{
			Kind:       "provider",
			Provider:   event.Provider,
			Confidence: "observed",
		},
		Payload: payload,
	}
}

// StableAgentEventID derives an idempotency identity for provider observations
// that do not carry a native message/call ID. The provider-local sequence is
// included as a tie breaker; the Host still owns the canonical stream sequence.
func StableAgentEventID(event AgentEvent) string {
	value := struct {
		Sequence uint64         `json:"sequence"`
		Turn     uint64         `json:"turn"`
		Provider string         `json:"provider"`
		Type     string         `json:"type"`
		ID       string         `json:"id"`
		Role     string         `json:"role"`
		Content  string         `json:"content"`
		Delta    bool           `json:"delta"`
		Tool     string         `json:"tool"`
		CallID   string         `json:"callId"`
		Output   string         `json:"output"`
		Error    string         `json:"error"`
		When     time.Time      `json:"when"`
		Payload  map[string]any `json:"payload,omitempty"`
	}{event.Sequence, event.Turn, event.Provider, event.Type, event.ID, event.Role, event.Content,
		event.ContentDelta, event.ToolName, event.CallID, event.Output, event.Error, event.Timestamp.UTC(), event.Payload}
	encoded, _ := json.Marshal(value)
	digest := sha256.Sum256(encoded)
	return "evt-" + hex.EncodeToString(digest[:16])
}

func putAgentPayload(payload map[string]any, key string, value any) {
	switch value := value.(type) {
	case nil:
		return
	case string:
		if value == "" {
			return
		}
	case bool:
		if !value {
			return
		}
	case int64:
		if value == 0 {
			return
		}
	}
	payload[key] = value
}

func canonicalAgentEventType(value string, delta bool) string {
	value = strings.ToLower(strings.TrimSpace(strings.ReplaceAll(value, "-", "_")))
	switch value {
	case "user", "assistant", "system":
		if delta {
			return "message.delta"
		}
		return "message.created"
	case "reasoning":
		return "reasoning.delta"
	case "tool_call", "tool_use", "tool":
		return "tool.started"
	case "tool_output", "tool_result":
		return "tool.completed"
	case "question", "permission", "confirmation":
		return "interaction.requested"
	case "plan", "todo", "activity", "plugin", "subagent", "attachment", "config", "compaction", "diff", "diagnostics":
		return value + ".updated"
	default:
		if value == "" {
			return "message.created"
		}
		return value
	}
}
