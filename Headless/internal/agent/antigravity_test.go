package agent

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestValidateAntigravityCommand(t *testing.T) {
	valid := []string{
		"agy",
		"agy -i 'inspect code'",
		"agy --prompt-interactive 'hello world'",
		"agy --model auto",
		"agy --effort high",
		"agy --sandbox",
	}
	for _, cmd := range valid {
		if err := ValidateAntigravityCommand(cmd); err != nil {
			t.Errorf("ValidateAntigravityCommand(%q) unexpected error: %v", cmd, err)
		}
	}

	invalid := []struct {
		cmd string
		err string
	}{
		{"", "must not be empty"},
		{"agy; rm -rf /", "shell operators"},
		{"agy | grep foo", "shell operators"},
		{"agy && echo hi", "shell operators"},
		{"agy `echo hi`", "shell operators"},
		{"agy --continue", "session resume flags are not supported"},
		{"agy -c", "session resume flags are not supported"},
		{"agy --conversation 12345", "session resume flags are not supported"},
		{"agy -p 'prompt'", "print and non-interactive flags are not supported"},
		{"agy --print 'prompt'", "print and non-interactive flags are not supported"},
		{"agy --input-format stream-json", "print and non-interactive flags are not supported"},
	}
	for _, tc := range invalid {
		err := ValidateAntigravityCommand(tc.cmd)
		if err == nil {
			t.Errorf("ValidateAntigravityCommand(%q) expected error containing %q, got nil", tc.cmd, tc.err)
		} else if !strings.Contains(err.Error(), tc.err) {
			t.Errorf("ValidateAntigravityCommand(%q) expected error containing %q, got %v", tc.cmd, tc.err, err)
		}
	}
}

func TestAntigravityParser_CleanUserContent(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{
			input:    "<USER_REQUEST>\nDo this task\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\ninfo\n</ADDITIONAL_METADATA>",
			expected: "Do this task",
		},
		{
			input:    "Simple prompt without tags",
			expected: "Simple prompt without tags",
		},
		{
			input:    "<USER_REQUEST>One line</USER_REQUEST>",
			expected: "One line",
		},
		{
			input:    "<CONTEXT_SUMMARY>\nHistory summary\n</CONTEXT_SUMMARY>\n\n<USER_REQUEST>\nUser prompt after compaction\n</USER_REQUEST>",
			expected: "User prompt after compaction",
		},
		{
			input:    "<CONTEXT_SUMMARY>\nOld summary\n</CONTEXT_SUMMARY>\nPrompt without request tags\n<ADDITIONAL_METADATA>\ntime\n</ADDITIONAL_METADATA>",
			expected: "Prompt without request tags",
		},
	}
	for _, tc := range tests {
		got := cleanAntigravityUserContent(tc.input)
		if got != tc.expected {
			t.Errorf("cleanAntigravityUserContent(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestAntigravityParser_Fixture(t *testing.T) {
	data, err := os.ReadFile("testdata/antigravity-v1.jsonl")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	parser := newAntigravityParser(1024)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	var allEvents []api.AgentEvent
	for i, line := range lines {
		events := parser.Parse([]byte(line))
		allEvents = append(allEvents, events...)
		if i == 3 {
			// Status should be blocked due to pending question
			status := parser.tracker.Status()
			if status.Activity != api.AgentActivityBlocked {
				t.Errorf("tracker activity during question = %v, want blocked", status.Activity)
			}
		}
	}

	if len(allEvents) < 7 {
		t.Fatalf("expected at least 7 events, got %d", len(allEvents))
	}

	// First event: user message
	if allEvents[0].Type != "user" || allEvents[0].Content != "Please inspect the codebase." {
		t.Errorf("event 0: got type %q content %q, want user message", allEvents[0].Type, allEvents[0].Content)
	}

	// Second event: reasoning
	if allEvents[1].Type != "reasoning" || !strings.Contains(allEvents[1].Content, "list the files") {
		t.Errorf("event 1: got type %q content %q, want reasoning", allEvents[1].Type, allEvents[1].Content)
	}

	// Third event: tool_call (glob)
	if allEvents[2].Type != "tool_call" || allEvents[2].ToolName != "glob" || allEvents[2].ToolStatus != "running" {
		t.Errorf("event 2: got type %q tool %q status %q, want tool_call glob running", allEvents[2].Type, allEvents[2].ToolName, allEvents[2].ToolStatus)
	}

	// Fourth event: tool_output
	if allEvents[3].Type != "tool_output" || !strings.Contains(allEvents[3].Output, "main.go") || allEvents[3].ToolStatus != "success" {
		t.Errorf("event 3: got type %q output %q status %q, want tool_output success", allEvents[3].Type, allEvents[3].Output, allEvents[3].ToolStatus)
	}

	// Fifth event: reasoning before question
	if allEvents[4].Type != "reasoning" {
		t.Errorf("event 4: got type %q, want reasoning", allEvents[4].Type)
	}

	// Sixth event: question
	if allEvents[5].Type != "question" || allEvents[5].Payload == nil {
		t.Errorf("event 5: got type %q, want question with payload", allEvents[5].Type)
	} else {
		payload := allEvents[5].Payload
		if payload["state"] != "pending" {
			t.Errorf("question state = %v, want pending", payload["state"])
		}
	}

	// Seventh event: tool_output resolving question
	if allEvents[6].Type != "tool_output" || allEvents[6].Output != "main.go" {
		t.Errorf("event 6: got type %q output %q, want tool_output", allEvents[6].Type, allEvents[6].Output)
	}

	// Eighth event: assistant final response
	if allEvents[7].Type != "assistant" || allEvents[7].StopReason != "stop" {
		t.Errorf("event 7: got type %q stop %q, want assistant stop", allEvents[7].Type, allEvents[7].StopReason)
	}

	// Status should be ready at end of turn
	finalStatus := parser.tracker.Status()
	if finalStatus.Activity != api.AgentActivityReady {
		t.Errorf("final tracker activity = %v, want ready", finalStatus.Activity)
	}
}

func TestAntigravityBindHook(t *testing.T) {
	tempDir := t.TempDir()

	// Initial install
	changed, err := EnsureAntigravityBindHook(tempDir)
	if err != nil {
		t.Fatalf("EnsureAntigravityBindHook initial install failed: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true on initial install")
	}

	// Idempotent install
	changed, err = EnsureAntigravityBindHook(tempDir)
	if err != nil {
		t.Fatalf("EnsureAntigravityBindHook second call failed: %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false on second call")
	}

	// Check hooks.json contents
	hooksPath := filepath.Join(tempDir, "hooks.json")
	data, err := os.ReadFile(hooksPath)
	if err != nil {
		t.Fatalf("read hooks.json: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("unmarshal hooks.json: %v", err)
	}
	warrenHook, ok := doc["warren-bind"].(map[string]any)
	if !ok {
		t.Fatalf("warren-bind key missing or invalid: %v", doc)
	}
	if _, ok := warrenHook["PreInvocation"]; !ok {
		t.Errorf("PreInvocation hook missing")
	}
	if _, ok := warrenHook["Stop"]; !ok {
		t.Errorf("Stop hook missing")
	}
}

func TestFindAntigravityTranscript(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("ANTIGRAVITY_HOME", tempDir)

	sessionID := "test-convo-123"
	transcriptDir := filepath.Join(tempDir, "brain", sessionID, ".system_generated", "logs")
	if err := os.MkdirAll(transcriptDir, 0o755); err != nil {
		t.Fatalf("mkdir transcript dir: %v", err)
	}
	transcriptPath := filepath.Join(transcriptDir, "transcript.jsonl")
	if err := os.WriteFile(transcriptPath, []byte("{}"), 0o644); err != nil {
		t.Fatalf("write transcript: %v", err)
	}

	// 1. Direct sessionID lookup
	found := FindAntigravityTranscript(sessionID, "")
	if found != transcriptPath {
		t.Errorf("FindAntigravityTranscript by sessionID = %q, want %q", found, transcriptPath)
	}

	// 2. DB fallback lookup
	dbPath := filepath.Join(tempDir, "conversation_summaries.db")
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	_, err = db.Exec(`CREATE TABLE conversation_summaries (
		conversation_id TEXT PRIMARY KEY,
		workspace_uris TEXT,
		last_modified_time TEXT
	)`)
	if err != nil {
		t.Fatalf("create table: %v", err)
	}
	_, err = db.Exec(
		`INSERT INTO conversation_summaries VALUES (?, ?, ?)`,
		sessionID,
		`["file:///Users/dev/workspace/repo"]`,
		time.Now().UTC().Format(time.RFC3339),
	)
	if err != nil {
		t.Fatalf("insert record: %v", err)
	}
	db.Close()

	foundDB := FindAntigravityTranscript("", "/Users/dev/workspace/repo")
	if foundDB != transcriptPath {
		t.Errorf("FindAntigravityTranscript by DB = %q, want %q", foundDB, transcriptPath)
	}
}

func TestAntigravityParser_QueueResetAndErrors(t *testing.T) {
	parser := newAntigravityParser(1024)

	// Step 1: Tool call in step 1
	step1 := `{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-09-04T10:00:00Z","tool_calls":[{"name":"find_by_name","args":{"Pattern":"*.go"}}]}`
	events1 := parser.Parse([]byte(step1))
	if len(events1) != 1 || events1[0].Type != "tool_call" || events1[0].CallID != "1_0" || events1[0].ToolStatus != "running" {
		t.Fatalf("unexpected events1: %+v", events1)
	}

	// Step 3: Skipped step 2! Another tool call arrives without step 1 ever receiving GENERIC.
	step3 := `{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-09-04T10:00:01Z","tool_calls":[{"name":"run_command","args":{"CommandLine":"go test"}}]}`
	events3 := parser.Parse([]byte(step3))
	if len(events3) != 1 || events3[0].Type != "tool_call" || events3[0].CallID != "3_0" || events3[0].ToolName != "shell" {
		t.Fatalf("unexpected events3: %+v", events3)
	}

	// Step 4: GENERIC output for step 3. Should match callID "3_0", not stale "1_0"!
	step4 := `{"step_index":4,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"2026-09-04T10:00:02Z","content":"PASS"}`
	events4 := parser.Parse([]byte(step4))
	if len(events4) != 1 || events4[0].Type != "tool_output" || events4[0].CallID != "3_0" || events4[0].ToolStatus != "success" || events4[0].ToolName != "shell" {
		t.Fatalf("unexpected events4: %+v", events4)
	}

	// Step 5: Tool call that encounters an ERROR_MESSAGE
	step5 := `{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-09-04T10:00:03Z","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"/foo.txt"}}]}`
	parser.Parse([]byte(step5))

	// Step 6: ERROR_MESSAGE should resolve pending call "5_0" with error status
	step6 := `{"step_index":6,"source":"SYSTEM","type":"ERROR_MESSAGE","created_at":"2026-09-04T10:00:04Z","content":"file not found"}`
	events6 := parser.Parse([]byte(step6))
	if len(events6) != 1 || events6[0].Type != "tool_output" || events6[0].CallID != "5_0" || events6[0].ToolStatus != "error" || events6[0].ToolName != "read" {
		t.Fatalf("unexpected events6: %+v", events6)
	}
}

func TestCanonicalToolStatus(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"completed", "success"},
		{"success", "success"},
		{"done", "success"},
		{"ok", "success"},
		{"failed", "error"},
		{"error", "error"},
		{"interrupted", "interrupted"},
		{"cancelled", "interrupted"},
		{"running", "running"},
		{"in_progress", "running"},
		{"pending", "running"},
		{"working", "running"},
		{"", ""},
		{"custom_unknown", "success"},
	}
	for _, tc := range tests {
		got := canonicalToolStatus(tc.input)
		if got != tc.want {
			t.Errorf("canonicalToolStatus(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestAntigravityParser_CheckpointAndCompaction(t *testing.T) {
	parser := newAntigravityParser(1024)
	checkpointLine := `{"step_index":4304,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-09-08T04:05:12Z","content":"# Resuming from a compaction\n\nYou are continuing work on the task..."}`
	events := parser.Parse([]byte(checkpointLine))
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "compaction" {
		t.Errorf("got type %q, want compaction", events[0].Type)
	}
	if events[0].Role != "system" {
		t.Errorf("got role %q, want system", events[0].Role)
	}
	if events[0].Content != "History compacted" {
		t.Errorf("got content %q, want 'History compacted'", events[0].Content)
	}
	if events[0].Payload["summary"] != "History compacted" {
		t.Errorf("unexpected payload: %+v", events[0].Payload)
	}
}

func TestAntigravityParser_SystemMessage(t *testing.T) {
	parser := newAntigravityParser(1024)
	sysLine := `{"step_index":10,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-09-08T04:00:00Z","content":"The following is a <SYSTEM_MESSAGE> not actually sent by the user."}`
	events := parser.Parse([]byte(sysLine))
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "system_instructions" {
		t.Errorf("got type %q, want system_instructions", events[0].Type)
	}
	if events[0].Role != "system" {
		t.Errorf("got role %q, want system", events[0].Role)
	}
}

func TestAntigravityParser_SystemInjectedUserInput(t *testing.T) {
	parser := newAntigravityParser(1024)
	// Even if type is USER_INPUT, if content is system injected, it must not be tagged as user.
	line := `{"step_index":11,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-09-08T04:00:00Z","content":"<USER_REQUEST>\n<turn_aborted>\n</USER_REQUEST>"}`
	events := parser.Parse([]byte(line))
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "system_instructions" {
		t.Errorf("got type %q, want system_instructions", events[0].Type)
	}
	if events[0].Role != "system" {
		t.Errorf("got role %q, want system", events[0].Role)
	}
}

func TestSystemInjectedContextAcrossProviders(t *testing.T) {
	injectedSamples := []string{
		"<environment_context>cwd=/work</environment_context>",
		"# AGENTS.md rules\n- do not edit",
		"<collaboration_mode>team</collaboration_mode>",
		"<permissions instructions>allow shell",
		"<skill>git-expert</skill>",
		"<skills_instructions>run git",
		"<turn_aborted>",
		"<user_instructions>read only</user_instructions>",
		"<system_message>notice</system_message>",
		"The following is a <SYSTEM_MESSAGE> important",
		"[Request interrupted by user]",
	}
	for _, sample := range injectedSamples {
		if !isSystemInjectedUserContext(sample) {
			t.Errorf("isSystemInjectedUserContext(%q) = false, want true", sample)
		}
	}

	compactionSamples := []string{
		"# Resuming from a compaction\n\nsummary",
		"{{ CHECKPOINT 0 }}\n The earlier parts of this conversation have been truncated",
		"<summary>conversation summary</summary>",
		"<CONTEXT_SUMMARY>compacted</CONTEXT_SUMMARY>",
	}
	for _, sample := range compactionSamples {
		if !isCompactionContext(sample) {
			t.Errorf("isCompactionContext(%q) = false, want true", sample)
		}
	}

	userSamples := []string{
		"Please fix the bug in main.go",
		"How do I use this library?",
		"Run tests and let me know",
	}
	for _, sample := range userSamples {
		if isSystemInjectedUserContext(sample) {
			t.Errorf("isSystemInjectedUserContext(%q) = true, want false", sample)
		}
		if isCompactionContext(sample) {
			t.Errorf("isCompactionContext(%q) = true, want false", sample)
		}
	}
}

