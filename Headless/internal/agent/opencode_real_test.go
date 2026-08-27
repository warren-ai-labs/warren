package agent

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOpenCodeReaderHandlesRealSchemaAndToolCallsFinish(t *testing.T) {
	// Validates against the real opencode 1.18.23 schema. Most assistant
	// messages have finish=tool-calls (non-terminal) and only the final
	// assistant has finish=stop; parts include tool/reasoning/text/file/step-*.
	directory := t.TempDir()
	dbPath := filepath.Join(directory, "opencode.db")
	schema, err := os.ReadFile(filepath.Join("testdata", "opencode-real-v1.sql"))
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range strings.Split(string(schema), ";") {
		stmt = strings.TrimSpace(stmt)
		if stmt == "" {
			continue
		}
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("apply schema: %v: %s", err, stmt)
		}
	}
	created := time.Now().UnixMilli()
	if _, err := db.Exec(`INSERT INTO project(id,worktree,vcs,name,time_created,time_updated,sandboxes) VALUES(?,?,?,?,?,?,?)`,
		"proj-1", directory, "git", "warren", created, created, "[]"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO session(id,project_id,slug,directory,title,version,time_created,time_updated) VALUES(?,?,?,?,?,?,?,?)`,
		"ses_real", "proj-1", "slug", directory, "Warren", "1.18.23", created, created); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO message(id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?)`, "msg_user", "ses_real", created, created, `{"role":"user","time":{"created":1700000000000}}`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO part(id,message_id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?)`, "prt_user", "msg_user", "ses_real", created, created, `{"type":"text","text":"hi"}`); err != nil {
		t.Fatal(err)
	}
	// finish=tool-calls must NOT close the turn; finish=stop must. Use increasing timestamps to preserve order.
	toolCallsData := `{"role":"assistant","modelID":"m","providerID":"p","time":{"created":1700000000001},"finish":"tool-calls"}`
	if _, err := db.Exec(`INSERT INTO message(id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?)`, "msg_toolcalls", "ses_real", created+1, created+1, toolCallsData); err != nil {
		t.Fatal(err)
	}
	stopData := `{"role":"assistant","modelID":"m","providerID":"p","time":{"created":1700000000002},"finish":"stop"}`
	if _, err := db.Exec(`INSERT INTO message(id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?)`, "msg_stop", "ses_real", created+2, created+2, stopData); err != nil {
		t.Fatal(err)
	}
	// Parts: tool completed + file (ignored) + reasoning/text
	if _, err := db.Exec(`INSERT INTO part(id,message_id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?)`,
		"prt_tool", "msg_toolcalls", "ses_real", created+1, created+1, `{"type":"tool","tool":"bash","callID":"call-1","state":{"status":"completed","input":{"command":"pwd"},"output":"/tmp"}}`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO part(id,message_id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?)`,
		"prt_file", "msg_toolcalls", "ses_real", created+1, created+1, `{"type":"file","path":"/tmp/a.txt"}`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO part(id,message_id,session_id,time_created,time_updated,data) VALUES(?,?,?,?,?,?)`,
		"prt_text", "msg_stop", "ses_real", created+2, created+2, `{"type":"text","text":"done"}`); err != nil {
		t.Fatal(err)
	}
	db.Close()

	t.Setenv("WARREN_DATA_DIR", filepath.Join(directory, "warren"))
	binding := OpenCodeBinding{Provider: openCodeProvider, SessionID: "ses_real", Backend: openCodeSQLite, DatabasePath: dbPath, CachePath: filepath.Join(directory, "cache.jsonl")}
	tailer, err := NewOpenCodeTailer(binding)
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
	// Three snapshots (user + toolcalls + stop); file part is ignored in projection but snapshot exists.
	if lines := strings.Count(string(data), "\n"); lines != 3 {
		t.Fatalf("cache lines=%d want 3: %q", lines, data)
	}
	parser := newParser("opencode")
	var events []string
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		for _, ev := range parser.parse([]byte(line)) {
			events = append(events, ev.Type+":"+ev.ToolStatus+":"+ev.StopReason)
		}
	}
	// tool-calls must not produce a terminal turn; parser should emit tool_output with success and no stopReason
	hasToolOutput := false
	hasStop := false
	for _, e := range events {
		if strings.HasPrefix(e, "tool_output:success") {
			hasToolOutput = true
		}
		if strings.Contains(e, "stop") {
			hasStop = true
		}
	}
	if !hasToolOutput {
		t.Fatalf("tool_output missing, events=%v", events)
	}
	if !hasStop {
		t.Fatalf("stop finish must be terminal, events=%v", events)
	}
	if got := parser.Activity(); got != "ready" {
		t.Fatalf("after stop activity=%q want ready", got)
	}
}

func TestEnsureOpenCodeBindPlugin(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv("WARREN_OPENCODE_PLUGIN_PATH", "")
	changed, err := EnsureOpenCodeBindPlugin()
	if err != nil || !changed {
		t.Fatalf("first install changed=%v err=%v", changed, err)
	}
	path := OpenCodePluginPath()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "warren-agent-bind-v1") || !strings.Contains(string(data), "WARREN_SESSION_ID") {
		t.Fatalf("plugin content missing marker: %q", data)
	}
	changed, err = EnsureOpenCodeBindPlugin()
	if err != nil || changed {
		t.Fatalf("second install changed=%v err=%v want false", changed, err)
	}
}
