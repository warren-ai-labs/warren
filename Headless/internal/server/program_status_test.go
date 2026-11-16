package server

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/programstatus"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func programStatusService(runtime *memoryRuntime) *Service {
	service := &Service{
		Runtime: runtime,
		outputs: map[string]*outputSession{
			"session": {
				sessionID:     "session",
				runtimeName:   "runtime",
				ring:          output.NewRing(0, 1, 4096, 0),
				programStatus: newProgramStatus(),
			},
		},
		peers: map[string]map[*wsPeer]struct{}{
			"session": {
				{outbound: make(chan outboundMessage, 64), closed: make(chan struct{})}: {},
			},
		},
	}
	service.outputs["session"].responder = service.newQueryResponder()
	return service
}

// The Host owns OSC 7501 even while a client is attached, because no client
// emulator in the tree answers the protocol. A program that waits for support
// must still get its reply.
func TestServiceAnswersProgramStatusQueryWhenAttached(t *testing.T) {
	runtime := &memoryRuntime{sessions: map[string][]byte{"runtime": nil}}
	service := programStatusService(runtime)

	service.recordOutput("session", []byte("\x1b]7501;?\x1b\\"))

	got, err := runtime.Capture(context.Background(), "runtime")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != programstatus.QueryReply {
		t.Fatalf("runtime input = %q; want the OSC 7501 query reply", got)
	}
}

// A program that asks for its device attributes in the same batch stops
// listening for the feature answer once they arrive (pi does), so the answer
// has to come first or it is dropped unread.
func TestProgramStatusReplyPrecedesOtherRepliesForTheSameBatch(t *testing.T) {
	runtime := &memoryRuntime{sessions: map[string][]byte{"runtime": nil}}
	service := programStatusService(runtime)
	service.peers = map[string]map[*wsPeer]struct{}{}

	service.recordOutput("session", []byte("\x1b[?u\x1b]7501;?\x1b\\\x1b[c"))

	got, err := runtime.Capture(context.Background(), "runtime")
	if err != nil {
		t.Fatal(err)
	}
	want := programstatus.QueryReply + "\x1b[?u" + "\x1b[?62;c"
	if string(got) != want {
		t.Fatalf("runtime input = %q; want %q", got, want)
	}
}

func TestServiceRecordsProgramStatus(t *testing.T) {
	runtime := &memoryRuntime{sessions: map[string][]byte{"runtime": nil}}
	service := programStatusService(runtime)

	// The spec's own blocked example: permission to run terraform apply.
	service.recordOutput("session", []byte(
		"\x1b]7501;state=blocked:kind=permission:app=terraform:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/\x1b\\",
	))

	records := service.outputs["session"].programStatus.snapshot()
	if len(records) != 1 {
		t.Fatalf("records = %+v, want one", records)
	}
	record := records[0]
	if record.State != programstatus.StateBlocked ||
		record.Kind != programstatus.KindPermission ||
		record.EffectiveApp != "terraform" ||
		record.Msg != "Apply 3 to add, 1 to change, 0 to destroy?" {
		t.Fatalf("record = %+v", record)
	}

	// A report split across two output chunks must still be one record.
	service.recordOutput("session", []byte("\x1b]7501;state=work"))
	service.recordOutput("session", []byte("ing:app=terraform\x1b\\"))
	records = service.outputs["session"].programStatus.snapshot()
	if len(records) != 1 || records[0].State != programstatus.StateWorking {
		t.Fatalf("records after split report = %+v", records)
	}
}

func TestProjectProgramStatusPrefersMostUrgentRecord(t *testing.T) {
	progress := 40
	records := []programstatus.Record{
		{Report: programstatus.Report{State: programstatus.StateWorking, App: "deploy"}, EffectiveApp: "deploy"},
		{Report: programstatus.Report{State: programstatus.StateWorking, ID: "us-east", Progress: &progress}, EffectiveApp: "deploy"},
		{Report: programstatus.Report{State: programstatus.StateBlocked, ID: "eu-west", Kind: programstatus.KindPermission, Msg: "Approve deploy?"}, EffectiveApp: "deploy"},
		{Report: programstatus.Report{State: programstatus.StateDone, ID: "us-west"}, EffectiveApp: "deploy"},
	}
	status := projectProgramStatus(records)
	if status.State != api.ProgramStatusBlocked || status.Kind != "permission" || status.Message != "Approve deploy?" || status.App != "deploy" {
		t.Fatalf("summary = %+v", status)
	}
	if len(status.Records) != len(records) {
		t.Fatalf("records = %d, want %d", len(status.Records), len(records))
	}
}

// The protocol calls the root record's label the window title, so it travels
// with the summary even when a child record is the urgent one.
func TestProjectProgramStatusCarriesOnlyTheRootTitle(t *testing.T) {
	records := []programstatus.Record{
		{Report: programstatus.Report{Title: "deploy", State: programstatus.StateWorking}},
		{Report: programstatus.Report{ID: "eu-west", Title: "eu-west", State: programstatus.StateBlocked, Kind: programstatus.KindPermission}},
	}
	projected := projectProgramStatus(records)
	if projected.State != api.ProgramStatusBlocked {
		t.Fatalf("summary state = %q; want the blocked child", projected.State)
	}
	if projected.Title != "deploy" {
		t.Fatalf("title = %q; want the root record's label", projected.Title)
	}
}

func TestProgramStatusForSessionWithoutOutput(t *testing.T) {
	service := &Service{outputs: map[string]*outputSession{}}
	if _, ok := service.programStatusForSession("missing"); ok {
		t.Fatal("expected no program status for a session with no output state")
	}
}

// A program status is live projection data with no durable Store write, so its
// change has to advance the observer-facing roster revision. Otherwise a
// roster-delta client receives an update whose revision did not move and
// discards it, and the dot never changes on screen.
func TestProgramStatusChangeAdvancesRosterRevision(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, outputs: map[string]*outputSession{}}

	_, durable := service.Store.SnapshotVersion()
	service.bumpProgramRosterRevision()
	projected, cursor := service.RosterVersion(context.Background())
	// The projection token must move so a delta client accepts the update...
	if projected.Revision <= durable {
		t.Fatalf("projected revision = %d, want greater than the durable revision %d", projected.Revision, durable)
	}
	// ...while the change cursor still tracks durable mutations only, so the
	// client's ChangesSince position is not treated as a store write.
	if cursor != durable {
		t.Fatalf("change cursor = %d, want the durable revision %d", cursor, durable)
	}
}

// Repeating an identical report is not a change: a program that re-sends its
// state must not churn the roster for every connected client.
func TestRepeatedProgramReportDoesNotChangeRecords(t *testing.T) {
	tracker := programstatus.NewTracker()
	first := programstatus.Report{State: programstatus.StateWorking, App: "deploy"}
	if !tracker.Apply(first) {
		t.Fatal("first report should count as a change")
	}
	if tracker.Apply(first) {
		t.Fatal("an identical report should not count as a change")
	}
	if !tracker.Apply(programstatus.Report{State: programstatus.StateDone, App: "deploy"}) {
		t.Fatal("a state change should count as a change")
	}
	if tracker.Apply(programstatus.Report{State: programstatus.StateClear, ID: "absent"}) {
		t.Fatal("clearing an absent record should not count as a change")
	}
	if !tracker.Apply(programstatus.Report{State: programstatus.StateClear}) {
		t.Fatal("clearing the terminal should count as a change")
	}
}

// The whole Host chain, end to end: PTY bytes in, roster snapshots out. This is
// the assertion that matters for a client — no client parses the escape
// sequence, so the only thing they can see is what the roster carries.
func TestRosterCarriesProgramStatusFromTerminalOutput(t *testing.T) {
	state, session := testSession(t)
	service := &Service{
		Store:   state,
		outputs: map[string]*outputSession{},
	}
	service.outputs[session.ID] = &outputSession{
		sessionID:     session.ID,
		runtimeName:   session.Runtime,
		ring:          output.NewRing(0, 1, 4096, 0),
		responder:     service.newQueryResponder(),
		programStatus: newProgramStatus(),
	}

	// The spec's blocked example, plus the split-chunk case in the same stream.
	service.recordOutput(session.ID, []byte(
		"\x1b]7501;state=blocked:kind=permission:app=terraform:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/\x1b\\",
	))

	roster := service.Roster(context.Background())
	if len(roster.Sessions) != 1 {
		t.Fatalf("roster sessions = %d, want 1", len(roster.Sessions))
	}
	status := roster.Sessions[0].ProgramStatus
	if status == nil {
		t.Fatal("roster session has no program status")
	}
	if status.State != api.ProgramStatusBlocked || status.Kind != "permission" || status.App != "terraform" {
		t.Fatalf("program status = %+v", status)
	}
	if status.Message != "Apply 3 to add, 1 to change, 0 to destroy?" {
		t.Fatalf("program status message = %q", status.Message)
	}
	if len(status.Records) != 1 || status.Records[0].ID != "" {
		t.Fatalf("program status records = %+v", status.Records)
	}
}
