// Package programstatus implements the Program Status Protocol (OSC 7501).
//
// A program reports what it is doing by writing an OSC 7501 escape sequence to
// its terminal: idle, working, done, blocked, or error, with an optional reason.
// Warren's Host is the terminal in its architecture, so this package owns the
// parsing and the per-terminal record state. Clients render the projection the
// Host publishes; they never parse the escape sequence themselves.
//
// Spec: https://www.superlogical.com/rex/docs/build/program-status
package programstatus

import (
	"fmt"
	"strings"
)

// State is the required `state` value of a report. Clear is not a state: it
// removes the addressed record instead of reporting one.
type State string

const (
	StateIdle    State = "idle"
	StateWorking State = "working"
	StateDone    State = "done"
	StateBlocked State = "blocked"
	StateError   State = "error"
	StateClear   State = "clear"
)

// Kind explains what a blocked record waits for. Unrecognized values are
// treated as absent.
type Kind string

const (
	KindPermission Kind = "permission"
	KindQuestion   Kind = "question"
	KindAuth       Kind = "auth"
)

// Hard limits from the spec. A report that breaks any limit is discarded whole.
const (
	maxSequenceBytes = 4096
	maxKeyBytes      = 16
	maxAppBytes      = 32
	maxMsgEncoded    = 2732
	maxMsgDecoded    = 2048
	maxTitleEncoded  = 256
	maxTitleDecoded  = 192
	maxIDBytes       = 128
	maxIDSegment     = 32
	maxIDLevels      = 8
	// maxRecords is the per-terminal cap. The spec requires support for at
	// least 64; the least-recently-updated record is evicted past this bound.
	maxRecords = 256
)

// Report is one decoded OSC 7501 report. It is a complete replacement for the
// record it addresses: a key absent here is absent from the record afterwards.
type Report struct {
	State State
	// ID is the record path; empty addresses the root record.
	ID string
	// Kind is present only for blocked reports.
	Kind Kind
	// Progress is present only for working and blocked reports; nil means the
	// program is busy but has no percentage to report.
	Progress *int
	// App is a stable program identifier, not a label.
	App string
	// Title is a short human-readable record label.
	Title string
	// Msg is one human-readable line.
	Msg string
}

// Record is the stored state for one id after the latest report replaced it.
type Record struct {
	Report
	// EffectiveApp is the record's app, inherited from its nearest ancestor
	// that has one when the record itself does not.
	EffectiveApp string
	// Sequence is the order in which the record was last updated, used to
	// evict the least-recently-updated record at the cap.
	Sequence uint64
}

// QueryReply is the feature-detection reply a supporting terminal sends for
// `OSC 7501 ; ? ST`. This build accepts the fixed 0.4 state and kind sets, so
// it advertises them explicitly rather than relying on the implied defaults.
const QueryReply = "\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\"

// validApp reports whether app matches `[A-Za-z0-9_.+-]{1,32}`.
func validApp(app string) bool {
	if len(app) == 0 || len(app) > maxAppBytes {
		return false
	}
	for i := 0; i < len(app); i++ {
		if !appChar(app[i]) {
			return false
		}
	}
	return true
}

// appChar covers the app/id segment alphabet `[A-Za-z0-9_.+-]`.
func appChar(c byte) bool {
	switch {
	case c >= 'a' && c <= 'z':
		return true
	case c >= 'A' && c <= 'Z':
		return true
	case c >= '0' && c <= '9':
		return true
	case c == '_' || c == '.' || c == '+' || c == '-':
		return true
	default:
		return false
	}
}

// validID reports whether id is a well-formed record path. A malformed id must
// not fall back to the root record, so callers discard the whole report.
func validID(id string) bool {
	if id == "" {
		return true
	}
	if len(id) > maxIDBytes {
		return false
	}
	segments := strings.Split(id, "/")
	if len(segments) > maxIDLevels {
		return false
	}
	for _, segment := range segments {
		if len(segment) == 0 || len(segment) > maxIDSegment {
			return false
		}
		for i := 0; i < len(segment); i++ {
			if !appChar(segment[i]) {
				return false
			}
		}
	}
	return true
}

// validValue reports whether value matches the pair value alphabet
// `[A-Za-z0-9_.,+/=-]*`, which excludes the pair and body separators.
func validValue(value string) bool {
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '_' || c == '.' || c == ',' || c == '+' || c == '/' || c == '=' || c == '-':
		default:
			return false
		}
	}
	return true
}

// validKey reports whether key matches `[a-z]+` within the key length limit.
func validKey(key string) bool {
	if len(key) == 0 || len(key) > maxKeyBytes {
		return false
	}
	for i := 0; i < len(key); i++ {
		if key[i] < 'a' || key[i] > 'z' {
			return false
		}
	}
	return true
}

// containsControl reports whether decoded free text holds a C0, DEL, or C1
// control character. Such text is refused so it can never act as markup or a
// terminal command when a client shows it.
func containsControl(text string) bool {
	for _, r := range text {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			return true
		}
	}
	return false
}

func evictedMessage(id string) string {
	return fmt.Sprintf("evicting program status record %q", id)
}
