package api

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"sort"
	"strings"
	"time"
)

// Agent View capabilities are negotiated independently from protocol 4.0.
// Keep these strings stable: clients persist no capability state and may
// safely ignore names introduced by a newer Host.
const (
	// CapabilityAppHeartbeat enables a lightweight browser-compatible liveness
	// exchange. Native clients use WebSocket ping frames, while browsers cannot
	// originate protocol-level ping frames from JavaScript.
	CapabilityAppHeartbeat      = "app-heartbeat-v1"
	CapabilityRosterDelta       = "roster-delta"
	CapabilityAgentTimeline     = "agent-timeline-v1"
	CapabilityAgentInteractions = "agent-interactions-v1"
	CapabilityAgentInterrupt    = "agent-interrupt-v1"
	CapabilityAgentAttachments  = "agent-attachments-v1"
	CapabilityAgentGoals        = "agent-goals-v1"
)

var (
	// ErrAgentBlocked is returned when a prompt cannot be injected because
	// the terminal agent is currently awaiting human attention or approval.
	ErrAgentBlocked = errors.New("agent is blocked on attention")

	// ErrAgentBusy is returned when a prompt cannot be injected because
	// the agent is currently working on an active turn without queue support.
	ErrAgentBusy = errors.New("agent is currently working")
)

// AgentViewCapabilities is the complete capability set implemented by this
// Host. A copy is returned so callers cannot mutate the process-wide list.
var AgentViewCapabilities = []string{
	CapabilityAgentTimeline,
	CapabilityAgentInteractions,
	CapabilityAgentInterrupt,
	CapabilityAgentAttachments,
	CapabilityAgentGoals,
}

// HostCapabilities returns the capabilities understood by the Headless
// WebSocket endpoint. Keep the legacy roster-delta capability in the same
// negotiation list so a welcome message is a true intersection rather than a
// second, agent-only capability channel.
func HostCapabilities() []string {
	result := make([]string, 0, len(AgentViewCapabilities)+2)
	result = append(result, CapabilityAppHeartbeat)
	result = append(result, CapabilityRosterDelta)
	result = append(result, AgentViewCapabilities...)
	return result
}

// NegotiateCapabilities returns the ordered intersection of the Host's
// capabilities and a client's declaration. Unknown and duplicate names are
// ignored. Ordering follows hostCapabilities, making welcome messages stable
// and easy to compare in contract tests.
func NegotiateCapabilities(hostCapabilities, clientCapabilities []string) []string {
	client := make(map[string]struct{}, len(clientCapabilities))
	for _, value := range clientCapabilities {
		value = strings.TrimSpace(value)
		if value != "" {
			client[value] = struct{}{}
		}
	}
	seen := make(map[string]struct{}, len(hostCapabilities))
	result := make([]string, 0, len(hostCapabilities))
	for _, value := range hostCapabilities {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		if _, ok := client[value]; ok {
			result = append(result, value)
		}
	}
	return result
}

// SupportsCapability reports whether a negotiated list contains capability.
func SupportsCapability(capabilities []string, wanted string) bool {
	wanted = strings.TrimSpace(wanted)
	for _, value := range capabilities {
		if strings.TrimSpace(value) == wanted {
			return true
		}
	}
	return false
}

// AgentInteractionResponse is the common response for question, permission,
// and confirmation cards. Response is intentionally JSON-shaped so a Host can add
// bounded option values without changing the wire envelope.
type AgentInteractionResponse struct {
	CommandID string         `json:"commandId,omitempty"`
	Session   string         `json:"session"`
	RequestID string         `json:"requestId"`
	Kind      string         `json:"kind"`
	Response  map[string]any `json:"response"`
}

// AgentMessageSendRequest is the structured send path. Attachments contain
// opaque references only; file content and local paths never cross this API.
type AgentMessageSendRequest struct {
	Session         string               `json:"session"`
	ClientMessageID string               `json:"clientMessageId"`
	Text            string               `json:"text"`
	Attachments     []AgentAttachmentRef `json:"attachments,omitempty"`
}

type AgentAttachmentRef struct {
	AttachmentID string `json:"attachmentId"`
	Name         string `json:"name,omitempty"`
	MIME         string `json:"mime,omitempty"`
	Size         int64  `json:"size,omitempty"`
}

// AgentTurnInterruptRequest represents cancel and atomic Send now. When
// Replacement is present the Host must accept it only as part of the same
// interrupt transaction.
type AgentTurnInterruptRequest struct {
	CommandID   string                   `json:"commandId,omitempty"`
	Session     string                   `json:"session"`
	Turn        uint64                   `json:"turn"`
	Reason      string                   `json:"reason"`
	Replacement *AgentMessageSendRequest `json:"replacement,omitempty"`
}

type AgentTurnInterruptResult struct {
	Accepted        bool   `json:"accepted"`
	Session         string `json:"session"`
	Turn            uint64 `json:"turn"`
	ClientMessageID string `json:"clientMessageId,omitempty"`
	Status          string `json:"status,omitempty"`
}

type AgentMessageSendResult struct {
	Accepted        bool   `json:"accepted"`
	Session         string `json:"session"`
	ClientMessageID string `json:"clientMessageId"`
}

type AgentInteractionResult struct {
	Accepted  bool   `json:"accepted"`
	Session   string `json:"session"`
	RequestID string `json:"requestId"`
	Kind      string `json:"kind"`
}

// AgentGoalSetRequest updates the current goal for one Agent session. The
// provider owns the goal identity (Codex uses its thread ID), so the Host only
// carries the Warren Session ID across this bridge. ReplaceExisting is set by
// the iOS editor to select Codex's dedicated edit prompt when using PTY.
type AgentGoalSetRequest struct {
	CommandID       string `json:"commandId,omitempty"`
	Session         string `json:"session"`
	Objective       string `json:"objective"`
	Status          string `json:"status,omitempty"`
	TokenBudget     *int64 `json:"tokenBudget,omitempty"`
	ReplaceExisting bool   `json:"replaceExisting,omitempty"`
}

// AgentGoalClearRequest removes the current goal for one Agent session.
type AgentGoalClearRequest struct {
	CommandID string `json:"commandId,omitempty"`
	Session   string `json:"session"`
}

type AgentGoalResult struct {
	Accepted  bool   `json:"accepted"`
	Session   string `json:"session"`
	Objective string `json:"objective,omitempty"`
}

// AgentAttachmentPrepareRequest starts an opaque upload session.
type AgentAttachmentPrepareRequest struct {
	Session string `json:"session"`
	Name    string `json:"name"`
	MIME    string `json:"mime"`
	Size    int64  `json:"size"`
	SHA256  string `json:"sha256,omitempty"`
}

type AgentAttachmentPrepareResult struct {
	AttachmentID string    `json:"attachmentId"`
	UploadID     string    `json:"uploadId"`
	ChunkSize    int       `json:"chunkSize"`
	ExpiresAt    time.Time `json:"expiresAt"`
}

type AgentAttachmentChunkRequest struct {
	Session  string `json:"session"`
	UploadID string `json:"uploadId"`
	Sequence uint64 `json:"sequence"`
	Length   int    `json:"length"`
	SHA256   string `json:"sha256,omitempty"`
	Data     string `json:"data"` // base64 for JSON transports; binary adapters may bypass this field.
}

type AgentAttachmentCompleteRequest struct {
	Session  string `json:"session"`
	UploadID string `json:"uploadId"`
	Length   int64  `json:"length"`
	SHA256   string `json:"sha256,omitempty"`
}

type AgentAttachmentAbortRequest struct {
	Session  string `json:"session"`
	UploadID string `json:"uploadId"`
}

type AgentAttachmentResult struct {
	Accepted     bool   `json:"accepted"`
	AttachmentID string `json:"attachmentId,omitempty"`
	UploadID     string `json:"uploadId,omitempty"`
	State        string `json:"state,omitempty"`
	Received     int64  `json:"received,omitempty"`
	Error        string `json:"error,omitempty"`
}

// AgentAttachmentChunkDigest validates a chunk's declared length and digest.
// It is kept pure so Headless contract tests and alternate transports share
// exactly the same validation rules.
func AgentAttachmentChunkDigest(data []byte, length int, expectedSHA256 string) error {
	if length < 0 || length != len(data) {
		return errors.New("attachment chunk length mismatch")
	}
	if expectedSHA256 == "" {
		return nil
	}
	digest := sha256.Sum256(data)
	expected := strings.ToLower(strings.TrimSpace(expectedSHA256))
	if len(expected) != hex.EncodedLen(len(digest)) || hex.EncodeToString(digest[:]) != expected {
		return errors.New("attachment chunk checksum mismatch")
	}
	return nil
}

// NormalizeCapabilityList provides deterministic values for tests and logs
// without changing the negotiated ordering used in the welcome message.
func NormalizeCapabilityList(values []string) []string {
	seen := map[string]struct{}{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
