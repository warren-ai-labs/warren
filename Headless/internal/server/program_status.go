package server

import (
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/programstatus"
)

// programStatus mirrors one terminal's OSC 7501 world: a streaming scanner that
// tolerates reports split across output chunks, and the record set those reports
// build. The Host owns both so a detached program's status is already known when
// a client attaches later.
//
// Callers serialize access through the owning outputSession's mutex; the type
// holds no lock of its own.
type programStatus struct {
	scanner programstatus.Scanner
	tracker *programstatus.Tracker
}

func newProgramStatus() *programStatus {
	return &programStatus{tracker: programstatus.NewTracker()}
}

// bumpProgramRosterRevision advances the observer-facing roster token for a
// program status change. The record set is live projection data with no durable
// Store write, so this is what lets a roster-delta client accept the update
// instead of discarding it as a revision that never moved. It mirrors
// `bumpAgentRosterRevision` for the same reason and with the same guarantee:
// the token always ends up above the durable revision.
func (s *Service) bumpProgramRosterRevision() {
	if s == nil {
		return
	}
	base := uint64(1)
	if s.Store != nil {
		_, revision := s.Store.SnapshotVersion()
		base = revision + 1
	}
	for {
		current := s.programRosterRevision.Load()
		next := current + 1
		if next <= base {
			next = base + 1
		}
		if s.programRosterRevision.CompareAndSwap(current, next) {
			return
		}
	}
}

// observeProgramStatus scans one live output batch on the terminal that owns
// this output session. It lazily creates the per-terminal state so a manually
// constructed outputSession (tests, embedders) behaves like a real one. It
// reports whether the batch asked for feature detection and whether the record
// set changed.
func (o *outputSession) observeProgramStatus(data []byte) (query bool, changed bool) {
	if o.programStatus == nil {
		o.programStatus = newProgramStatus()
	}
	return o.programStatus.observe(data)
}

// observe folds one live output batch into the record set. It reports whether
// the batch asked for feature detection, in which case the caller must answer,
// and whether the visible record set changed.
func (p *programStatus) observe(data []byte) (query bool, changed bool) {
	reports, queries := p.scanner.Feed(data)
	for _, report := range reports {
		if p.tracker.Apply(report) {
			changed = true
		}
	}
	return queries > 0, changed
}

// snapshot returns the current records, ordered from least to most recent.
func (p *programStatus) snapshot() []programstatus.Record {
	return p.tracker.Records()
}

// programStatusSnapshot reads one session's record set. The boolean is false
// when the session has no output state or has never reported a status.
func (s *Service) programStatusSnapshot(sessionID string) ([]programstatus.Record, bool) {
	s.outputMu.Lock()
	outputSession := s.outputs[sessionID]
	s.outputMu.Unlock()
	if outputSession == nil {
		return nil, false
	}
	outputSession.mu.Lock()
	defer outputSession.mu.Unlock()
	if outputSession.programStatus == nil {
		return nil, false
	}
	records := outputSession.programStatus.snapshot()
	if len(records) == 0 {
		return nil, false
	}
	return records, true
}

// programStatusForSession projects the record set into the roster shape. It is
// overlaid on running sessions only, exactly like AgentStatus.
func (s *Service) programStatusForSession(sessionID string) (*api.ProgramStatus, bool) {
	records, ok := s.programStatusSnapshot(sessionID)
	if !ok {
		return nil, false
	}
	return projectProgramStatus(records), true
}

// projectProgramStatus folds records into the summary a client renders first
// plus the full record list. The summary is the most urgent record, not the
// root: a blocked child must surface even while the root still says working.
func projectProgramStatus(records []programstatus.Record) *api.ProgramStatus {
	projected := make([]api.ProgramStatusRecord, 0, len(records))
	summary := records[0]
	// The title a client may put on the Session is the root record's, never a
	// child's: a child names one thing the program is doing, not the program.
	rootTitle := ""
	for index, record := range records {
		projected = append(projected, api.ProgramStatusRecord{
			ID:       record.ID,
			State:    api.ProgramStatusState(record.State),
			Kind:     string(record.Kind),
			App:      record.EffectiveApp,
			Title:    record.Title,
			Message:  record.Msg,
			Progress: record.Progress,
		})
		if record.ID == "" {
			rootTitle = record.Title
		}
		if index == 0 || programStatusPriority(record.State) <= programStatusPriority(summary.State) {
			summary = record
		}
	}
	return &api.ProgramStatus{
		State:    api.ProgramStatusState(summary.State),
		Kind:     string(summary.Kind),
		App:      summary.EffectiveApp,
		Title:    rootTitle,
		Message:  summary.Msg,
		Progress: summary.Progress,
		Records:  projected,
	}
}

// programStatusPriority orders states by how much they want a person's
// attention. Lower sorts earlier.
func programStatusPriority(state programstatus.State) int {
	switch state {
	case programstatus.StateBlocked:
		return 0
	case programstatus.StateError:
		return 1
	case programstatus.StateWorking:
		return 2
	case programstatus.StateDone:
		return 3
	default:
		return 4
	}
}
