package programstatus

import (
	"bytes"
	"strings"
	"testing"
)

func feed(t *testing.T, scanner *Scanner, chunks ...string) ([]Report, int) {
	t.Helper()
	var reports []Report
	queries := 0
	for _, chunk := range chunks {
		chunkReports, chunkQueries := scanner.Feed([]byte(chunk))
		reports = append(reports, chunkReports...)
		queries += chunkQueries
	}
	return reports, queries
}

func mustOne(t *testing.T, reports []Report) Report {
	t.Helper()
	if len(reports) != 1 {
		t.Fatalf("got %d reports, want 1", len(reports))
	}
	return reports[0]
}

func TestScannerParsesReport(t *testing.T) {
	scanner := &Scanner{}
	// "Installing updates" / "Password required to install updates" /
	// "Upgraded 12 packages" are the spec's own base64 examples.
	reports, queries := feed(t, scanner,
		"hello \x1b]7501;state=working:app=brew:msg=SW5zdGFsbGluZyB1cGRhdGVz\x1b\\ world",
		"\x1b]7501;state=blocked:kind=auth:app=brew:msg=UGFzc3dvcmQgcmVxdWlyZWQgdG8gaW5zdGFsbCB1cGRhdGVz\x07",
		"\x1b]7501;state=done:app=brew:msg=VXBncmFkZWQgMTIgcGFja2FnZXM=\x1b\\",
	)
	if queries != 0 {
		t.Fatalf("queries = %d, want 0", queries)
	}
	if len(reports) != 3 {
		t.Fatalf("got %d reports, want 3", len(reports))
	}
	if reports[0].State != StateWorking || reports[0].App != "brew" || reports[0].Msg != "Installing updates" {
		t.Fatalf("working report = %+v", reports[0])
	}
	if reports[1].State != StateBlocked || reports[1].Kind != KindAuth || reports[1].Msg != "Password required to install updates" {
		t.Fatalf("blocked report = %+v", reports[1])
	}
	if reports[2].State != StateDone || reports[2].Msg != "Upgraded 12 packages" {
		t.Fatalf("done report = %+v", reports[2])
	}
}

func TestScannerBuffersSplitSequence(t *testing.T) {
	scanner := &Scanner{}
	reports, _ := feed(t, scanner,
		"\x1b]7501;state=wor",
		"king:app=deploy:msg=RGVwbG95aW5n",
		"\x1b",
		"\\",
	)
	report := mustOne(t, reports)
	if report.State != StateWorking || report.App != "deploy" || report.Msg != "Deploying" {
		t.Fatalf("report = %+v", report)
	}
}

func TestScannerDetectsQueryAndIgnoresOtherSequences(t *testing.T) {
	scanner := &Scanner{}
	reports, queries := feed(t, scanner,
		"\x1b]0;window title\x07",
		"\x1b]7501;?\x1b\\",
		"\x1b]11;?\x1b\\",
	)
	if queries != 1 {
		t.Fatalf("queries = %d, want 1", queries)
	}
	if len(reports) != 0 {
		t.Fatalf("got %d reports, want 0", len(reports))
	}
}

func TestScannerSkipsMalformedPairButKeepsReport(t *testing.T) {
	scanner := &Scanner{}
	// A pair with no `=` and a pair whose value holds a space are both skipped;
	// the well-formed pairs around them still apply.
	reports, _ := feed(t, scanner, "\x1b]7501;state=working:bogus:app=de ploy:msg=RGVwbG95aW5n\x1b\\")
	report := mustOne(t, reports)
	if report.State != StateWorking || report.App != "" || report.Msg != "Deploying" {
		t.Fatalf("report = %+v", report)
	}
}

func TestScannerDropsReportOnBadStateOrID(t *testing.T) {
	scanner := &Scanner{}
	reports, _ := feed(t, scanner,
		"\x1b]7501;state=busy\x1b\\",                                   // unknown state
		"\x1b]7501;app=deploy\x1b\\",                                   // missing state
		"\x1b]7501;state=working=oops\x1b\\",                           // `=` is legal in a value, so this is an unknown state
		"\x1b]7501;state=working:id=a//b\x1b\\",                        // malformed id
		"\x1b]7501;state=working:id="+strings.Repeat("a", 33)+"\x1b\\", // oversized segment
	)
	if len(reports) != 0 {
		t.Fatalf("got %d reports, want 0", len(reports))
	}
}

func TestScannerDropsReportOnControlOrOversizedText(t *testing.T) {
	scanner := &Scanner{}
	// "a\nb" base64-encoded contains a control character when decoded.
	reports, _ := feed(t, scanner,
		"\x1b]7501;state=working:msg=YQpi\x1b\\",
		"\x1b]7501;state=working:msg="+strings.Repeat("A", maxMsgEncoded+1)+"\x1b\\",
	)
	if len(reports) != 0 {
		t.Fatalf("got %d reports, want 0", len(reports))
	}
}

func TestScannerBoundsRunawaySequence(t *testing.T) {
	scanner := &Scanner{}
	feed(t, scanner, "\x1b]7501;state=working:"+strings.Repeat("a", maxSequenceBytes+16))
	// A later, valid report on a fresh stream state still parses.
	reports, _ := feed(t, scanner, "\x1b]7501;state=idle\x1b\\")
	report := mustOne(t, reports)
	if report.State != StateIdle {
		t.Fatalf("report = %+v", report)
	}
}

func TestParseProgressAndKindScope(t *testing.T) {
	scanner := &Scanner{}
	reports, _ := feed(t, scanner,
		"\x1b]7501;state=working:progress=40\x1b\\",
		"\x1b]7501;state=blocked:kind=permission:progress=150\x1b\\",
		"\x1b]7501;state=working:kind=permission\x1b\\",
	)
	if reports[0].Progress == nil || *reports[0].Progress != 40 {
		t.Fatalf("working progress = %+v", reports[0].Progress)
	}
	// Out-of-range progress is absent; the blocked kind still applies.
	if reports[1].Progress != nil {
		t.Fatalf("blocked progress = %+v, want nil", reports[1].Progress)
	}
	if reports[1].Kind != KindPermission {
		t.Fatalf("blocked kind = %q", reports[1].Kind)
	}
	// Kind is ignored outside blocked.
	if reports[2].Kind != "" {
		t.Fatalf("working kind = %q, want empty", reports[2].Kind)
	}
}

func TestTrackerReplacesRecordCompletely(t *testing.T) {
	tracker := NewTracker()
	tracker.Apply(Report{State: StateBlocked, Kind: KindPermission, Msg: "approve?", App: "deploy"})
	tracker.Apply(Report{State: StateWorking, App: "deploy"})
	root, ok := tracker.Root()
	if !ok {
		t.Fatal("root record missing")
	}
	if root.State != StateWorking || root.Kind != "" || root.Msg != "" {
		t.Fatalf("root = %+v", root)
	}
}

func TestTrackerInheritsAppFromNearestAncestor(t *testing.T) {
	tracker := NewTracker()
	tracker.Apply(Report{State: StateWorking, App: "deploy"})
	tracker.Apply(Report{State: StateWorking, ID: "us-east"})
	tracker.Apply(Report{State: StateWorking, ID: "us-east/worker"})
	for _, record := range tracker.Records() {
		if record.EffectiveApp != "deploy" {
			t.Fatalf("record %q effective app = %q, want deploy", record.ID, record.EffectiveApp)
		}
	}
}

func TestTrackerClearRemovesSubtree(t *testing.T) {
	tracker := NewTracker()
	tracker.Apply(Report{State: StateWorking})
	tracker.Apply(Report{State: StateWorking, ID: "eu-west"})
	tracker.Apply(Report{State: StateWorking, ID: "eu-west/worker"})
	tracker.Apply(Report{State: StateWorking, ID: "eu-west-2"})
	tracker.Apply(Report{State: StateClear, ID: "eu-west"})
	if _, ok := tracker.Root(); !ok {
		t.Fatal("root should survive a subtree clear")
	}
	records := tracker.Records()
	if len(records) != 2 {
		t.Fatalf("records = %+v, want root and eu-west-2", records)
	}
	if records[1].ID != "eu-west-2" {
		t.Fatalf("remaining child = %q, want eu-west-2", records[1].ID)
	}

	tracker.Apply(Report{State: StateClear})
	if tracker.Len() != 0 {
		t.Fatalf("clear without id left %d records", tracker.Len())
	}
}

func TestTrackerEvictsLeastRecentlyUpdated(t *testing.T) {
	tracker := NewTracker()
	for i := 0; i < maxRecords; i++ {
		tracker.Apply(Report{State: StateWorking, ID: "worker-" + string(rune('a'+i%26)) + string(rune('a'+i/26))})
	}
	if tracker.Len() != maxRecords {
		t.Fatalf("len = %d, want %d", tracker.Len(), maxRecords)
	}
	tracker.Apply(Report{State: StateWorking, ID: "brand-new"})
	if tracker.Len() != maxRecords {
		t.Fatalf("len after eviction = %d, want %d", tracker.Len(), maxRecords)
	}
}

func TestQueryReplyIsWellFormed(t *testing.T) {
	if !bytes.HasPrefix([]byte(QueryReply), []byte("\x1b]7501;?")) {
		t.Fatalf("reply does not start with the query form: %q", QueryReply)
	}
	if !bytes.HasSuffix([]byte(QueryReply), []byte("\x1b\\")) {
		t.Fatalf("reply does not end with ST: %q", QueryReply)
	}
}
