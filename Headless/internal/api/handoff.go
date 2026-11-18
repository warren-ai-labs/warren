package api

import "time"

// A handoff starts a fresh Agent Session from a long one. The Host reads the
// source Session and returns the text the new Session should start from; the
// client creates the Session and leaves the text in its input for the person
// to send. These types are unrelated to `session.handoff`, which moves one ACP
// conversation into its provider's terminal.

// HandoffBriefMode says who writes the brief.
type HandoffBriefMode string

const (
	// HandoffBriefExtract assembles the brief from the Session's recorded
	// events with no model call.
	HandoffBriefExtract HandoffBriefMode = "extract"
	// HandoffBriefAgent asks the source Agent to write the brief in a turn of
	// its own, which costs one read of its whole context.
	HandoffBriefAgent HandoffBriefMode = "agent"
)

// HandoffStatusRequest names the Session a handoff would start from.
type HandoffStatusRequest struct {
	Session string `json:"session"`
}

// HandoffStatus is what a client needs to say whether the source Session's
// prompt cache is likely still warm.
//
// The Host does not know the cache state. It reports the time of the last
// model response it recorded and the provider's cache lifetime, so the client
// can count down. Estimated is true when the lifetime is not a documented
// fixed value for this provider.
type HandoffStatus struct {
	Session        string     `json:"session"`
	Provider       string     `json:"provider"`
	Model          string     `json:"model,omitempty"`
	LastResponseAt *time.Time `json:"lastResponseAt,omitempty"`
	CacheTTL       int        `json:"cacheTtlSeconds"`
	Estimated      bool       `json:"estimated"`
	// ContextTokens is the input size of the last recorded model call, the
	// amount a cold brief would read again. Zero when no usage was recorded.
	ContextTokens int64 `json:"contextTokens,omitempty"`
	// CanAsk reports whether the source Agent can be asked to write a brief:
	// it is running and not mid-turn or waiting on an approval.
	CanAsk bool `json:"canAsk"`
}

// HandoffBriefRequest asks for the starting text of a new Session.
type HandoffBriefRequest struct {
	Session string           `json:"session"`
	Mode    HandoffBriefMode `json:"mode"`
}

// HandoffBriefResult is the text to place in the new Session's input.
type HandoffBriefResult struct {
	Session string           `json:"session"`
	Mode    HandoffBriefMode `json:"mode"`
	Text    string           `json:"text"`
}

// SessionDraftRequest types text into a terminal Agent's input without
// submitting it, once the Agent has drawn its prompt.
type SessionDraftRequest struct {
	Session string `json:"session"`
	Text    string `json:"text"`
}
