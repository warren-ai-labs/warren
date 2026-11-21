package programstatus

import (
	"bytes"
	"encoding/base64"
	"strconv"
	"strings"
)

// Scanner extracts OSC 7501 reports from a raw terminal byte stream. Output
// arrives in arbitrary chunks, so the scanner buffers a partial sequence until
// its terminator arrives, and drops anything that grows past the spec limit.
//
// The scanner only observes; it never mutates the stream. Unknown OSC numbers
// are skipped, which keeps it safe to run on every session.
type Scanner struct {
	pending []byte
}

// Feed consumes one output chunk and returns the reports it completed plus the
// number of feature-detection queries seen. Reports that break a limit, fail
// to decode, or carry an unknown state are dropped entirely.
func (s *Scanner) Feed(data []byte) ([]Report, int) {
	if len(data) == 0 {
		return nil, 0
	}
	// The scanner runs on every Session's output, so the ordinary batch — plain
	// program output with no escape in it — must not be copied. Only a batch
	// that carries an escape, or a sequence still waiting for its terminator,
	// is buffered.
	if len(s.pending) == 0 && bytes.IndexByte(data, 0x1b) < 0 {
		return nil, 0
	}
	s.pending = append(s.pending, data...)
	var reports []Report
	queries := 0
	for {
		index := bytes.IndexByte(s.pending, 0x1b)
		if index < 0 {
			if cap(s.pending) <= maxSequenceBytes {
				s.pending = s.pending[:0]
			} else {
				s.pending = nil
			}
			return reports, queries
		}
		if index > 0 {
			s.pending = s.pending[index:]
		}
		if len(s.pending) < 2 {
			return reports, queries
		}
		if s.pending[1] != ']' {
			// Not an OSC introducer. Drop the escape and rescan from the next
			// byte so a following OSC on the same chunk is still seen.
			s.pending = s.pending[1:]
			continue
		}
		end, complete := oscEnd(s.pending[2:])
		if !complete {
			if end >= 0 {
				body := s.pending[2:]
				// An ESC at the final byte may be the first byte of a split ST
				// (`ESC \`); keep buffering. Any other control byte or non-ST
				// ESC aborts this OSC so scanning can continue from that byte.
				if body[end] == 0x1b && end+1 == len(body) {
					return reports, queries
				}
				s.pending = body[end:]
				continue
			}
			if len(s.pending) > maxSequenceBytes {
				// A malformed or hostile sequence must not grow unbounded.
				s.pending = nil
			}
			return reports, queries
		}
		body := s.pending[2 : 2+end]
		s.pending = s.pending[2+end:]
		report, query, ok := parseBody(body)
		if query {
			queries++
			continue
		}
		if ok {
			reports = append(reports, report)
		}
	}
}

// oscEnd finds the terminator of an OSC body (the bytes after ESC ]). It
// returns the index of the terminating byte and whether the terminator is
// present. BEL and ST (`ESC \`) both terminate, as the spec allows.
func oscEnd(body []byte) (int, bool) {
	for i := 0; i < len(body); i++ {
		switch body[i] {
		case 0x07:
			return i, true
		case 0x1b:
			if i+1 < len(body) && body[i+1] == '\\' {
				return i, true
			}
			return i, false
		case 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0a,
			0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
			0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1c, 0x1d, 0x1e, 0x1f:
			// A control byte cannot belong to an OSC body; treat the sequence
			// as unterminated so the caller can recover at the next escape.
			return i, false
		}
	}
	return -1, false
}

// parseBody decodes the body of an OSC sequence (the bytes after ESC ]). It
// returns the report for a data report, query=true for a feature-detection
// query, and ok=false when the sequence is not a valid report.
func parseBody(body []byte) (report Report, query bool, ok bool) {
	prefix, rest, found := bytes.Cut(body, []byte(";"))
	if !found || string(prefix) != "7501" {
		return Report{}, false, false
	}
	if isQuery(rest) {
		return Report{}, true, false
	}
	report, ok = parsePairs(string(rest))
	return report, false, ok
}

// isQuery reports whether rest is the feature-detection body `?` or a `?`
// followed by capability pairs (a reply, not a query). A program only sends
// `?`, but tolerating the longer form keeps a reply from being misread.
func isQuery(rest []byte) bool {
	if len(rest) == 0 || rest[0] != '?' {
		return false
	}
	return true
}

// parsePairs decodes the `key=value:key=value` body of a report.
func parsePairs(raw string) (Report, bool) {
	var (
		report       Report
		state        string
		id           string
		kind         string
		progress     string
		app          string
		titleEncoded string
		msgEncoded   string
	)
	for _, pair := range strings.Split(raw, ":") {
		if pair == "" {
			continue
		}
		key, value, found := strings.Cut(pair, "=")
		if !found {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if !validKey(key) || !validValue(value) {
			// A malformed pair is skipped; the rest of the report still counts.
			continue
		}
		switch key {
		case "state":
			state = value
		case "id":
			id = value
		case "kind":
			kind = value
		case "progress":
			progress = value
		case "app":
			app = value
		case "title":
			titleEncoded = value
		case "msg":
			msgEncoded = value
		}
	}

	switch State(state) {
	case StateIdle, StateWorking, StateDone, StateBlocked, StateError, StateClear:
	default:
		// A missing or unrecognized state discards the whole report so a state
		// added in a later revision never degrades into idle.
		return Report{}, false
	}
	report.State = State(state)

	if !validID(id) {
		return Report{}, false
	}
	report.ID = id

	if validApp(app) {
		report.App = app
	}

	if report.State == StateBlocked {
		switch Kind(kind) {
		case KindPermission, KindQuestion, KindAuth:
			report.Kind = Kind(kind)
		}
	}
	if report.State == StateWorking || report.State == StateBlocked {
		if percent, err := strconv.Atoi(progress); err == nil && percent >= 0 && percent <= 100 {
			report.Progress = &percent
		}
	}

	if titleEncoded != "" {
		title, ok := decodeText(titleEncoded, maxTitleEncoded, maxTitleDecoded)
		if !ok {
			return Report{}, false
		}
		report.Title = title
	}
	if msgEncoded != "" {
		message, ok := decodeText(msgEncoded, maxMsgEncoded, maxMsgDecoded)
		if !ok {
			return Report{}, false
		}
		report.Msg = message
	}
	return report, true
}

// decodeText base64-decodes free text, enforcing the encoded and decoded size
// limits and refusing any control character. Padding is optional.
func decodeText(encoded string, maxEncoded, maxDecoded int) (string, bool) {
	if len(encoded) > maxEncoded {
		return "", false
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(encoded)
		if err != nil {
			return "", false
		}
	}
	if len(decoded) > maxDecoded {
		return "", false
	}
	text := string(decoded)
	if containsControl(text) {
		return "", false
	}
	return text, true
}
