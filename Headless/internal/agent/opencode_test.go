package agent

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestOpenCodeDataRootFollowsXDGOverride(t *testing.T) {
	t.Setenv("WARREN_OPENCODE_DATA_DIR", "")
	t.Setenv("XDG_DATA_HOME", filepath.Join(t.TempDir(), "xdg-data"))
	got := OpenCodeDataRoot("")
	want := filepath.Join(os.Getenv("XDG_DATA_HOME"), "opencode")
	if got != want {
		t.Fatalf("OpenCodeDataRoot = %q, want %q", got, want)
	}
	databasePath := filepath.Join(t.TempDir(), "opencode.db")
	if got, want := resolveOpenCodeDataRoot(databasePath), filepath.Dir(databasePath); got != want {
		t.Fatalf("explicit database path root = %q, want %q", got, want)
	}
	override := filepath.Join(t.TempDir(), "warren-opencode")
	t.Setenv("WARREN_OPENCODE_DATA_DIR", override)
	if got := OpenCodeDataRoot(""); got != override {
		t.Fatalf("Warren OpenCode data override = %q, want %q", got, override)
	}
}

func TestValidateOpenCodeCommandRejectsSessionReuse(t *testing.T) {
	for _, command := range []string{
		"opencode --continue",
		"opencode --session ses_existing",
		"opencode --fork",
		"opencode -s=ses_existing",
	} {
		if err := ValidateOpenCodeCommand(command); err == nil || !strings.Contains(err.Error(), "start a new session") {
			t.Fatalf("ValidateOpenCodeCommand(%q) = %v, want session reuse rejection", command, err)
		}
	}
}

func TestValidateOpenCodeCommandAcceptsProviderOptions(t *testing.T) {
	for _, command := range []string{
		"opencode --model openai/gpt-5 --agent build",
		"env OPENCODE_CONFIG=/tmp/config opencode --prompt 'hello world'",
	} {
		if err := ValidateOpenCodeCommand(command); err != nil {
			t.Fatalf("ValidateOpenCodeCommand(%q) = %v, want valid command", command, err)
		}
	}
}

func TestOpenCodeFinderUsesSQLiteAndStableBinding(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`
		CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER);
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
		CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
	`)
	if err != nil {
		t.Fatal(err)
	}
	created := time.Now().UnixMilli()
	_, err = db.Exec(`INSERT INTO session(id,project_id,directory,time_created,time_updated) VALUES(?,?,?,?,?)`, "ses_sqlite", "global", directory, created, created)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO message(id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?)`, "msg_user", "ses_sqlite", created, created, `{"role":"user","time":{"created":1700000000000}}`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO part(id,message_id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?)`, "prt_user", "msg_user", "ses_sqlite", created, created, `{"type":"text","text":"inspect this"}`)
	if err != nil {
		t.Fatal(err)
	}

	t.Setenv("WARREN_DATA_DIR", filepath.Join(directory, "warren"))
	finder := DefaultFinder{OpenCodeRoot: directory}
	binding, err := finder.FindBinding(context.Background(), "warren-session", "opencode", directory, time.UnixMilli(created-1))
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.Backend != openCodeSQLite || binding.SessionID != "ses_sqlite" {
		t.Fatalf("unexpected binding: %+v", binding)
	}
	if !strings.Contains(binding.CachePath, "warren-session-ses_sqlite") {
		t.Fatalf("cache path must include both identities: %s", binding.CachePath)
	}
	if filepath.Base(binding.DatabasePath) != "opencode.db" {
		t.Fatalf("unexpected database path: %s", binding.DatabasePath)
	}

}

func TestOpenCodeFinderUsesSQLiteProjectWorktree(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`
		CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT);
		CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER);
	`)
	if err != nil {
		t.Fatal(err)
	}
	created := time.Now().UnixMilli()
	if _, err := db.Exec(`INSERT INTO project(id,worktree) VALUES(?,?)`, "project-1", directory); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO session(id,project_id,directory,time_created,time_updated) VALUES(?,?,?,?,?)`, "ses_project", "project-1", filepath.Join(directory, "stale-directory"), created, created); err != nil {
		t.Fatal(err)
	}

	t.Setenv("WARREN_DATA_DIR", filepath.Join(directory, "warren"))
	binding, err := (DefaultFinder{OpenCodeRoot: directory}).FindBinding(context.Background(), "warren-session", "opencode", directory, time.UnixMilli(created-1))
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.SessionID != "ses_project" {
		t.Fatalf("project worktree should resolve the session, got %+v", binding)
	}
}

func TestOpenCodeFinderChoosesFirstSessionAfterLaunch(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER);`); err != nil {
		t.Fatal(err)
	}
	base := time.Now().UnixMilli()
	for _, row := range []struct {
		id               string
		created, updated int64
	}{
		{id: "ses_first", created: 10, updated: 30},
		{id: "ses_second", created: 20, updated: 40},
	} {
		if _, err := db.Exec(`INSERT INTO session VALUES(?,?,?,?,?)`, row.id, "project", directory, base+row.created, base+row.updated); err != nil {
			t.Fatal(err)
		}
	}
	binding, err := (DefaultFinder{OpenCodeRoot: directory}).FindBinding(context.Background(), "warren-session", openCodeProvider, directory, time.UnixMilli(base))
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.SessionID != "ses_first" {
		t.Fatalf("finder chose %q, want first session after launch", bindingSessionID(binding))
	}
}

func TestOpenCodeFinderIncludesSessionCreatedWithinLaunchMillisecond(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER);`); err != nil {
		t.Fatal(err)
	}
	launch := time.Unix(1700000000, 999999000)
	created := launch.Truncate(time.Millisecond).UnixMilli()
	if _, err := db.Exec(`INSERT INTO session VALUES(?,?,?,?,?)`, "ses_same_ms", "project", directory, created, created); err != nil {
		t.Fatal(err)
	}
	binding, err := (DefaultFinder{OpenCodeRoot: directory}).FindBinding(context.Background(), "warren-session", openCodeProvider, directory, launch)
	if err != nil {
		t.Fatal(err)
	}
	if binding == nil || binding.SessionID != "ses_same_ms" {
		t.Fatalf("session created in launch millisecond was rejected: %+v", binding)
	}
}

func bindingSessionID(binding *OpenCodeBinding) string {
	if binding == nil {
		return ""
	}
	return binding.SessionID
}

func TestOpenCodeTailerWaitsForPartsAndRecoversIncrementalText(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
		CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
	`)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UnixMilli()
	_, err = db.Exec(`INSERT INTO message VALUES(?,?,?,?,?)`, "msg_assistant", "ses_1", now, now, `{"role":"assistant","modelID":"gpt","providerID":"openai","time":{"created":1700000000000}}`)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("WARREN_DATA_DIR", filepath.Join(directory, "warren"))
	binding := OpenCodeBinding{Provider: "opencode", SessionID: "ses_1", Backend: openCodeSQLite, DatabasePath: dbPath, CachePath: filepath.Join(directory, "cache.jsonl")}
	tailer, err := NewOpenCodeTailer(binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := tailer.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(binding.CachePath); !os.IsNotExist(err) {
		t.Fatalf("message without parts must stay pending, stat err=%v", err)
	}

	_, err = db.Exec(`INSERT INTO part VALUES(?,?,?,?,?,?)`, "prt_text", "msg_assistant", "ses_1", now, now, `{"type":"text","text":"hello"}`)
	if err != nil {
		t.Fatal(err)
	}
	if err := tailer.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(binding.CachePath)
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(string(data), "\n"); lines != 1 {
		t.Fatalf("expected one recovered snapshot, got %d lines", lines)
	}

	_, err = db.Exec(`UPDATE part SET data=?, time_updated=? WHERE id=?`, `{"type":"text","text":"hello world"}`, now+2, "prt_text")
	if err != nil {
		t.Fatal(err)
	}
	if err := tailer.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(binding.CachePath)
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(string(data), "\n"); lines != 2 {
		t.Fatalf("expected one update snapshot, got %d lines", lines)
	}

	parser := newParser("opencode")
	var events []api.AgentEvent
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		events = append(events, parser.parse([]byte(line))...)
	}
	if len(events) != 2 || events[0].Content != "hello" || events[1].Content != " world" {
		t.Fatalf("expected incremental text events, got %+v", events)
	}
}

func TestOpenCodeReaderIsReadOnlyAndDoesNotCreateMissingDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "missing.db")
	_, err := (sqliteOpenCodeReader{databasePath: dbPath}).ReadMessages(context.Background(), "ses_missing", 0)
	if err == nil {
		t.Fatal("missing OpenCode database should return an error")
	}
	if _, statErr := os.Stat(dbPath); !os.IsNotExist(statErr) {
		t.Fatalf("read-only reader created %q, stat error = %v", dbPath, statErr)
	}
}

func TestOpenCodeTailerDerivesCachePathWhenBindingOmitsIt(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("WARREN_DATA_DIR", directory)
	binding := OpenCodeBinding{
		Provider: openCodeProvider, SessionID: "ses_default_cache", Backend: openCodeSQLite,
		DatabasePath: filepath.Join(directory, "opencode.db"),
	}
	tailer, err := NewOpenCodeTailer(binding)
	if err != nil {
		t.Fatal(err)
	}
	want := OpenCodeCachePath("warren", binding.SessionID)
	if got := tailer.Path(); got != want {
		t.Fatalf("derived OpenCode cache path = %q, want %q", got, want)
	}
}

func TestOpenCodeTailerRestoresCacheAndKeepsSessionsIsolated(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
		CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
	`)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UnixMilli()
	for _, sessionID := range []string{"ses_a", "ses_b"} {
		messageID := "msg_" + sessionID
		partID := "prt_" + sessionID
		if _, err := db.Exec(`INSERT INTO message VALUES(?,?,?,?,?)`, messageID, sessionID, now, now, `{"role":"user","time":{"created":1700000000000}}`); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`INSERT INTO part VALUES(?,?,?,?,?,?)`, partID, messageID, sessionID, now, now, `{"type":"text","text":"`+sessionID+`"}`); err != nil {
			t.Fatal(err)
		}
	}

	cachePath := filepath.Join(directory, "cache.jsonl")
	binding := OpenCodeBinding{Provider: openCodeProvider, SessionID: "ses_a", Backend: openCodeSQLite, DatabasePath: dbPath, CachePath: cachePath}
	tailer, err := NewOpenCodeTailer(binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := tailer.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(first), "\n") != 1 || !strings.Contains(string(first), "ses_a") {
		t.Fatalf("session A cache = %q", first)
	}

	restarted, err := NewOpenCodeTailer(binding)
	if err != nil {
		t.Fatal(err)
	}
	if err := restarted.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if restarted.updatedSince == 0 {
		t.Fatal("restored cache poll must advance the OpenCode update cursor")
	}
	afterRestart, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(afterRestart) != string(first) {
		t.Fatalf("daemon restart duplicated cache: before=%q after=%q", first, afterRestart)
	}

	if _, err := db.Exec(`UPDATE part SET data=?, time_updated=? WHERE id=?`, `{"type":"text","text":"ses_b changed"}`, now+1, "prt_ses_b"); err != nil {
		t.Fatal(err)
	}
	if err := restarted.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	unchanged, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(unchanged) != string(first) {
		t.Fatalf("session B update leaked into session A cache: %q", unchanged)
	}
}

type mutableOpenCodeReader struct {
	source openCodeSourceMessage
}

func (r *mutableOpenCodeReader) ReadMessages(context.Context, string, int64) ([]openCodeSourceMessage, error) {
	return []openCodeSourceMessage{r.source}, nil
}

func TestOpenCodeTailerCompactsMutableSnapshots(t *testing.T) {
	cachePath := filepath.Join(t.TempDir(), "cache.jsonl")
	reader := &mutableOpenCodeReader{source: openCodeSourceMessage{
		Message: openCodeMessage{ID: "msg_long", SessionID: "ses_long", Role: "assistant", Time: openCodeTime{Created: 1}},
		Parts:   []openCodePart{{ID: "part_long", MessageID: "msg_long", Type: "text", Text: "reply-0"}},
		Updated: 1,
	}}
	tailer, err := NewOpenCodeTailer(OpenCodeBinding{
		Provider: openCodeProvider, SessionID: "ses_long", Backend: openCodeSQLite,
		DatabasePath: filepath.Join(t.TempDir(), "unused.db"), CachePath: cachePath,
	})
	if err != nil {
		t.Fatal(err)
	}
	tailer.reader = reader
	if err := tailer.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	for index := 1; index < openCodeCacheCompactionLines; index++ {
		reader.source.Updated = int64(index + 1)
		reader.source.Parts[0].Text = "reply-" + strings.Repeat("x", index)
		if err := tailer.Poll(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(string(data), "\n"); lines != 1 {
		t.Fatalf("compacted cache has %d lines, want one latest snapshot: %q", lines, data)
	}
	if !strings.Contains(string(data), strings.Repeat("x", openCodeCacheCompactionLines-1)) {
		t.Fatalf("compacted cache lost latest mutable text: %q", data)
	}
}

func TestOpenCodeParserMapsCurrentSchema(t *testing.T) {
	line := openCodeEnvelope{
		MessageID: "msg_1", Role: "assistant", ModelID: "model", ProviderID: "provider",
		Finish: "stop", Time: openCodeTime{Created: 1700000000000},
		Parts: []openCodePart{
			{ID: "p_text", Type: "text", Text: "answer"},
			{ID: "p_reasoning", Type: "reasoning", Text: "because"},
			{ID: "p_tool", Type: "tool", CallID: "call-1", Tool: "bash", State: openCodeToolState{Status: "completed", Input: json.RawMessage(`{"command":"pwd"}`), Output: json.RawMessage(`"/tmp"`)}},
		},
	}
	raw, _ := json.Marshal(line)
	events := newParser("opencode").parse(raw)
	if len(events) != 4 {
		t.Fatalf("expected text, reasoning, call, output; got %+v", events)
	}
	if events[0].Type != "assistant" || events[1].Type != "reasoning" || events[2].CallID != "call-1" || events[3].ToolStatus != "success" {
		t.Fatalf("unexpected event mapping: %+v", events)
	}
	if events[len(events)-1].StopReason != "stop" {
		t.Fatalf("finish=stop must be a completion boundary: %+v", events[len(events)-1])
	}
	if got := newParser("opencode").parse([]byte(`{"messageId":"msg_err","role":"assistant","error":{"name":"APIError","data":{"message":"upstream failed"}}}`)); len(got) != 1 || got[0].Error != "upstream failed" {
		t.Fatalf("unexpected assistant error: %+v", got)
	}
}

func TestOpenCodeEnvelopeTreatsNullErrorAsIncomplete(t *testing.T) {
	_, complete := openCodeEnvelopeFromSource(openCodeSourceMessage{
		Message: openCodeMessage{
			ID: "msg_pending", Role: "assistant", Error: json.RawMessage(`null`),
		},
	})
	if complete {
		t.Fatal("error:null must not mark a message without parts or finish as complete")
	}
}

func TestOpenCodeReaderSupportsCurrentSQLiteJSONColumns(t *testing.T) {
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
		CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
	`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO message VALUES(?,?,?,?,?)`, "msg_current", "ses_current", 1700000000000, 1700000000000,
		`{"role":"assistant","modelID":"model","providerID":"provider","time":{"created":1700000000000}}`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO part VALUES(?,?,?,?,?,?)`, "part_current", "msg_current", "ses_current", 1700000000000, 1700000000000,
		`{"type":"text","text":"first"}`); err != nil {
		t.Fatal(err)
	}
	tailer, err := NewOpenCodeTailer(OpenCodeBinding{
		Provider: openCodeProvider, SessionID: "ses_current", Backend: openCodeSQLite,
		DatabasePath: dbPath, CachePath: filepath.Join(directory, "cache.jsonl"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := tailer.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE part SET data=?, time_updated=? WHERE id=?`, `{"type":"text","text":"first second"}`, 1700000000001, "part_current"); err != nil {
		t.Fatal(err)
	}
	if err := tailer.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(tailer.Path())
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(string(data), "\n"); lines != 2 {
		t.Fatalf("current SQLite schema cache lines = %d, want 2: %q", lines, data)
	}
	parser := newParser(openCodeProvider)
	var events []api.AgentEvent
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		events = append(events, parser.parse([]byte(line))...)
	}
	if len(events) != 2 || events[0].Content != "first" || events[1].Content != " second" {
		t.Fatalf("current SQLite incremental events = %#v", events)
	}
}

func TestOpenCodeParserSeparatesToolLifecycleAndCompletion(t *testing.T) {
	parser := newParser("opencode")
	initial := openCodeEnvelope{
		MessageID: "msg_tool",
		Role:      "user",
		Time:      openCodeTime{Created: 1700000000000},
		Parts:     []openCodePart{{ID: "p_user", Type: "text", Text: "run it"}},
	}
	assistant := openCodeEnvelope{
		MessageID:  "msg_tool_assistant",
		Role:       "assistant",
		ModelID:    "model",
		ProviderID: "provider",
		Time:       openCodeTime{Created: 1700000001000},
		Finish:     "",
		Parts: []openCodePart{{
			ID: "p_tool", Type: "tool", CallID: "call-1", Tool: "bash",
			State: openCodeToolState{Status: "running", Input: json.RawMessage(`{"command":"pwd"}`)},
		}},
	}
	for _, value := range []openCodeEnvelope{initial, assistant} {
		raw, _ := json.Marshal(value)
		parser.parse(raw)
	}
	assistant.Parts[0].State = openCodeToolState{Status: "completed", Input: json.RawMessage(`{"command":"pwd"}`), Output: json.RawMessage(`"/tmp"`)}
	assistant.Finish = "stop"
	raw, _ := json.Marshal(assistant)
	events := parser.parse(raw)
	if len(events) != 1 || events[0].Type != "tool_output" || events[0].ToolStatus != "success" || events[0].StopReason != "stop" {
		t.Fatalf("tool completion events = %#v", events)
	}
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("tool completion activity = %q, want ready", got)
	}
	turns := parser.DrainTurns()
	if len(turns) != 2 || turns[0].Status != api.AgentTurnStarted || turns[1].Status != api.AgentTurnCompleted {
		t.Fatalf("tool completion turns = %#v", turns)
	}
}

func TestOpenCodeParserDelaysPendingToolCallUntilInputArrives(t *testing.T) {
	parser := newParser(openCodeProvider)
	pending := openCodeEnvelope{
		MessageID: "msg_pending_tool",
		Role:      "assistant",
		Time:      openCodeTime{Created: 1700000000000},
		Parts: []openCodePart{{
			ID: "part_pending_tool", Type: "tool", CallID: "call-pending", Tool: "bash",
			State: openCodeToolState{Status: "pending", Input: json.RawMessage(`{}`)},
		}},
	}
	raw, _ := json.Marshal(pending)
	if events := parser.parse(raw); len(events) != 0 {
		t.Fatalf("pending tool emitted before input: %#v", events)
	}
	pending.Parts[0].State = openCodeToolState{
		Status: "running", Input: json.RawMessage(`{"command":"pwd"}`),
	}
	raw, _ = json.Marshal(pending)
	events := parser.parse(raw)
	if len(events) != 1 || events[0].Type != "tool_call" || events[0].ToolInput.(map[string]any)["command"] != "pwd" {
		t.Fatalf("tool input update events = %#v", events)
	}
}

func TestOpenCodeParserMapsTerminalFinishReasons(t *testing.T) {
	for _, test := range []struct {
		finish       string
		wantTurn     api.AgentTurnStatus
		wantActivity api.AgentActivity
	}{
		{finish: "length", wantTurn: api.AgentTurnCompleted, wantActivity: api.AgentActivityReady},
		{finish: "content-filter", wantTurn: api.AgentTurnCompleted, wantActivity: api.AgentActivityReady},
		{finish: "error", wantTurn: api.AgentTurnFailed, wantActivity: api.AgentActivityFailed},
	} {
		parser := newParser(openCodeProvider)
		user := openCodeEnvelope{
			MessageID: "msg_" + test.finish,
			Role:      "user",
			Time:      openCodeTime{Created: 1700000000000},
			Parts:     []openCodePart{{ID: "part_" + test.finish, Type: "text", Text: "prompt"}},
		}
		raw, _ := json.Marshal(user)
		parser.parse(raw)
		assistant := openCodeEnvelope{
			MessageID: "assistant_" + test.finish,
			Role:      "assistant",
			Finish:    test.finish,
			Time:      openCodeTime{Created: 1700000001000},
			Parts:     []openCodePart{{ID: "answer_" + test.finish, Type: "text", Text: "answer"}},
		}
		raw, _ = json.Marshal(assistant)
		events := parser.parse(raw)
		if len(events) != 1 || events[0].StopReason != test.finish {
			t.Fatalf("finish %q events = %#v", test.finish, events)
		}
		if got := parser.Activity(); got != test.wantActivity {
			t.Fatalf("finish %q activity = %q", test.finish, got)
		}
		turns := parser.DrainTurns()
		if len(turns) != 2 || turns[1].Status != test.wantTurn {
			t.Fatalf("finish %q turns = %#v", test.finish, turns)
		}
	}
}
