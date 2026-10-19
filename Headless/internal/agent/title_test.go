package agent

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestClaudeParserReportsItsOwnGeneratedTitle(t *testing.T) {
	parser := newClaudeParser(4096)
	title := `{"type":"ai-title","sessionId":"s1","aiTitle":"Reconnect the socket"}`
	if events := parser.Parse([]byte(title)); len(events) != 0 {
		t.Fatalf("ai-title produced %d events, want none", len(events))
	}
	if got := parser.TakeTitle(); got != "Reconnect the socket" {
		t.Fatalf("TakeTitle() = %q, want Reconnect the socket", got)
	}
	// The name is reported once; a later poll must not re-apply it.
	if got := parser.TakeTitle(); got != "" {
		t.Fatalf("second TakeTitle() = %q, want empty", got)
	}
}

func TestQoderParserReportsItsOwnGeneratedTitle(t *testing.T) {
	parser := newQoderParser(4096)
	title := `{"type":"ai-title","sessionId":"qoder-1","aiTitle":"Fix button"}`
	if events := parser.Parse([]byte(title)); len(events) != 0 {
		t.Fatalf("ai-title produced %d events, want none", len(events))
	}
	if got := parser.TakeTitle(); got != "Fix button" {
		t.Fatalf("TakeTitle() = %q, want Fix button", got)
	}
	if got := parser.TakeTitle(); got != "" {
		t.Fatalf("second TakeTitle() = %q, want empty", got)
	}
}

func TestParserWithoutOwnTitleReportsNothing(t *testing.T) {
	parser := newParser("pi")
	if reporter, ok := parser.(TitleReporter); ok {
		if got := reporter.TakeTitle(); got != "" {
			t.Fatalf("TakeTitle() = %q, want empty", got)
		}
	}
}

// TestCodexTitleUsesThreadStoreAndSkipsSubagents covers the two things that
// make the Codex lookup safe: the name comes from Codex's own thread store
// rather than the rollout, and a subagent thread is never used.
func TestCodexTitleUsesThreadStoreAndSkipsSubagents(t *testing.T) {
	home := t.TempDir()
	writeCodexStateDB(t, home, []codexThreadRow{
		{id: "01a0e2eb-42d8-7b52-a713-093b2f39aaab", name: "Ask a testable question", source: "user"},
		{id: "01a0f2f8-8dfa-74f0-8db1-9f9d4ac962d7", name: "Delegated task name", source: "subagent"},
	})

	parser := newCodexParser(4096)
	parser.SetCodexHome(home)
	parser.SetThreadID("01a0e2eb-42d8-7b52-a713-093b2f39aaab")
	if got := parser.TakeTitle(); got != "Ask a testable question" {
		t.Fatalf("TakeTitle() = %q, want the stored thread name", got)
	}
	if got := parser.TakeTitle(); got != "" {
		t.Fatalf("second TakeTitle() = %q, want empty", got)
	}

	subagent := newCodexParser(4096)
	subagent.SetCodexHome(home)
	subagent.SetThreadID("01a0f2f8-8dfa-74f0-8db1-9f9d4ac962d7")
	if got := subagent.TakeTitle(); got != "" {
		t.Fatalf("subagent TakeTitle() = %q, want empty", got)
	}
}

// TestCodexTitleIsEmptyForAThreadNobodyNamed keeps the lookup honest about an
// unnamed thread: the Host's own title request, not a stale client-side index,
// is what covers that conversation.
func TestCodexTitleIsEmptyForAThreadNobodyNamed(t *testing.T) {
	home := t.TempDir()
	writeCodexStateDB(t, home, []codexThreadRow{
		{id: "01a0e2eb", name: "", source: "user"},
	})
	// A client-side index that still holds a name for this thread must not be
	// consulted: an index name the store dropped is a withdrawn name.
	writeReadLines(t, filepath.Join(home, "session_index.jsonl"),
		`{"id":"01a0e2eb","thread_name":"Stale index name"}`,
	)
	parser := newCodexParser(4096)
	parser.SetCodexHome(home)
	parser.SetThreadID("01a0e2eb")
	if got := parser.TakeTitle(); got != "" {
		t.Fatalf("TakeTitle() = %q, want empty", got)
	}
	if path := codexStateDBPath(home); path == "" {
		t.Fatal("codexStateDBPath found no store")
	}
}

func TestCodexStateDBPathPrefersTheNewestGeneration(t *testing.T) {
	home := t.TempDir()
	for _, name := range []string{"state_5.sqlite", "state_12.sqlite", "state_7.sqlite", "state_12.sqlite.backup.1"} {
		if err := os.WriteFile(filepath.Join(home, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if got, want := filepath.Base(codexStateDBPath(home)), "state_12.sqlite"; got != want {
		t.Fatalf("codexStateDBPath() = %q, want %q", got, want)
	}
}

func TestCodexHomeFromTranscriptPathResolvesProfiles(t *testing.T) {
	cases := map[string]string{
		"/home/u/.codex/sessions/2026/10/13/rollout-1.jsonl":                  "/home/u/.codex",
		"/home/u/.codex/profiles/cpa/sessions/2026/9/1/rollout-1.jsonl":       "/home/u/.codex/profiles/cpa",
		"/home/u/.codex/sessions/2026/10/13/rollout-01a13496-a0ef-7850.jsonl": "/home/u/.codex",
	}
	for path, want := range cases {
		if got := codexHomeFromTranscriptPath(path); got != want {
			t.Errorf("codexHomeFromTranscriptPath(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestOpenCodeSessionTitleSkipsPlaceholdersAndSubagents(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT)`); err != nil {
		t.Fatal(err)
	}
	for _, row := range []struct{ id, parent, title string }{
		{id: "ses_top", title: "Tab 关闭卡死问题排查"},
		{id: "ses_placeholder", title: "New session - 2026-10-12T10:03:45.551Z"},
		{id: "ses_subagent", parent: "ses_top", title: "提取Lody注意力设计 (@explore subagent)"},
	} {
		if _, err := db.Exec(`INSERT INTO session(id,parent_id,title) VALUES(?,?,?)`, row.id, row.parent, row.title); err != nil {
			t.Fatal(err)
		}
	}

	reader := sqliteOpenCodeReader{databasePath: dbPath}
	ctx := context.Background()
	if got, err := reader.ReadSessionTitle(ctx, "ses_top"); err != nil || got != "Tab 关闭卡死问题排查" {
		t.Fatalf("ReadSessionTitle(top) = %q, %v", got, err)
	}
	if got, err := reader.ReadSessionTitle(ctx, "ses_placeholder"); err != nil || got != "" {
		t.Fatalf("ReadSessionTitle(placeholder) = %q, %v, want empty", got, err)
	}
	if got, err := reader.ReadSessionTitle(ctx, "ses_subagent"); err != nil || got != "" {
		t.Fatalf("ReadSessionTitle(subagent) = %q, %v, want empty", got, err)
	}
}

func TestOpenCodeTailerReportsItsOwnGeneratedTitle(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT);
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
		CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
	`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO session(id,parent_id,title) VALUES(?,?,?)`, "ses_bound", nil, "Shell快进现象原因排查"); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	tailer, err := NewOpenCodeTailer(OpenCodeBinding{
		Provider:     openCodeProvider,
		SessionID:    "ses_bound",
		Backend:      openCodeSQLite,
		DatabasePath: dbPath,
		CachePath:    filepath.Join(directory, "cache.jsonl"),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer tailer.Close()
	if got := tailer.TakeTitle(); got != "Shell快进现象原因排查" {
		t.Fatalf("TakeTitle() = %q, want the provider title", got)
	}
	if got := tailer.TakeTitle(); got != "" {
		t.Fatalf("second TakeTitle() = %q, want empty", got)
	}
}

func TestWatcherTakeTitleReportsProviderName(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude.jsonl")
	writeReadLines(t, path, `{"type":"ai-title","sessionId":"s1","aiTitle":"Name from the CLI"}`)
	watcher := Start("sess-1", "claude", path,
		func([]api.AgentEvent, api.AgentStatus) {},
		func(api.AgentStatus) {},
		func([]api.AgentTurn, bool) {})
	defer watcher.Close()
	if err := watcher.WaitReady(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := watcher.TakeTitle(); got != "Name from the CLI" {
		t.Fatalf("TakeTitle() = %q, want the CLI name", got)
	}
}

type codexThreadRow struct {
	id     string
	name   string
	source string
}

func writeCodexStateDB(t *testing.T, home string, rows []codexThreadRow) {
	t.Helper()
	db, err := sql.Open("sqlite3", filepath.Join(home, "state_5.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, thread_source TEXT)`); err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if _, err := db.Exec(`INSERT INTO threads(id,name,thread_source) VALUES(?,?,?)`, row.id, row.name, row.source); err != nil {
			t.Fatal(err)
		}
	}
}
