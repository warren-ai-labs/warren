package store

import (
	"path/filepath"
	"strings"
	"testing"
)

// A journal created by an older build carries an explicit index that
// duplicates the UNIQUE (stream_id, event_id) automatic index. Reopening it
// must drop the duplicate so appends stop maintaining two identical trees.
func TestOpenAgentEventStoreDropsDuplicateEventIndex(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.db")
	s, err := OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`CREATE INDEX idx_agent_event_journal_event ON agent_event_journal(stream_id, event_id)`); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	s, err = OpenAgentEventStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var count int
	if err := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_agent_event_journal_event'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatal("duplicate event index survived reopening the journal")
	}
	var plan string
	var id, parent, unused int
	if err := s.db.QueryRow(`EXPLAIN QUERY PLAN SELECT sequence FROM agent_event_journal WHERE stream_id = 'stream' AND event_id = 'event'`).Scan(&id, &parent, &unused, &plan); err != nil {
		t.Fatal(err)
	}
	if want := "USING INDEX sqlite_autoindex_agent_event_journal_2"; !strings.Contains(plan, want) {
		t.Fatalf("event-id lookup plan = %q, want %q", plan, want)
	}
}
