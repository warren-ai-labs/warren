package server

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// A roster snapshot must never wait for the Agent journal. Every journal commit
// holds the Agent projection lock for its Session, so opening the journal inside
// a commit put the whole one-time cold open -- and, on a Host that restarted
// while another process still held the journal, up to the SQLite busy timeout --
// on the path of the first roster after a restart. Commits therefore open the
// journal before they take the projection lock.
func TestRosterDoesNotWaitForAgentJournalOpen(t *testing.T) {
	directory := t.TempDir()
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session-journal", AgentExecutionID: "exec-journal", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, AgentStorePath: filepath.Join(directory, "events.db")}
	service.lazyInit()
	service.agents["session-journal"] = &agentSession{}

	// Hold the journal's one-time open, as a cold Host does while the file is
	// being opened or is still locked by the previous daemon.
	service.agentStoreMu.Lock()
	journalHeld := true
	defer func() {
		if journalHeld {
			service.agentStoreMu.Unlock()
		}
	}()

	assertRosterCompletes := func(what string) {
		t.Helper()
		done := make(chan struct{})
		go func() {
			service.RosterVersion(context.Background())
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("roster waited for %s", what)
		}
	}
	assertRosterCompletes("the agent journal open")

	// A commit that needs the journal must park before it takes the projection
	// lock, so the same Session's projection stays readable while it waits.
	commitDone := make(chan struct{})
	go func() {
		service.recordAgentStatus("session-journal", api.AgentStatus{Activity: api.AgentActivityWorking})
		close(commitDone)
	}()
	select {
	case <-commitDone:
		t.Fatal("agent commit returned without opening the journal it writes to")
	case <-time.After(50 * time.Millisecond):
	}
	assertRosterCompletes("an agent commit that was waiting for the journal")

	service.agentStoreMu.Unlock()
	journalHeld = false
	select {
	case <-commitDone:
	case <-time.After(5 * time.Second):
		t.Fatal("agent commit did not finish after the journal opened")
	}
}
