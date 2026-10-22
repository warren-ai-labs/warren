package api

import "time"

// SessionHistoryRequest asks for the output the Host kept for one Session. The
// Session may be running or ended: the operation never attaches, never claims
// the terminal, and never sends input.
type SessionHistoryRequest struct {
	Session string `json:"session"`
}

// SessionHistoryResult is the bounded last output of a Session.
//
// Payload is the complete first segment of the runtime's output, from its byte
// zero, because a terminal renderer cannot start halfway through an ANSI
// sequence. Truncated reports that the segment was longer than the Host's
// bound, and BestEffort reports that this is the raw runtime output rather than
// a rendered checkpoint.
type SessionHistoryResult struct {
	Session    string     `json:"session"`
	Lifecycle  string     `json:"lifecycle"`
	EndReason  string     `json:"endReason,omitempty"`
	EndedAt    *time.Time `json:"endedAt,omitempty"`
	Payload    []byte     `json:"payload,omitempty"`
	Bytes      int        `json:"bytes"`
	Truncated  bool       `json:"truncated"`
	BestEffort bool       `json:"bestEffort"`
}

// SessionResumeRequest asks the Host to continue an ended Agent Session's
// provider conversation in a new running Session.
type SessionResumeRequest struct {
	Session string `json:"session"`
}
