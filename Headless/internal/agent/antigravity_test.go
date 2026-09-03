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

	// Third event: tool_call (find_by_name)
	if allEvents[2].Type != "tool_call" || allEvents[2].ToolName != "find_by_name" {
		t.Errorf("event 2: got type %q tool %q, want tool_call find_by_name", allEvents[2].Type, allEvents[2].ToolName)
	}

	// Fourth event: tool_output
	if allEvents[3].Type != "tool_output" || !strings.Contains(allEvents[3].Output, "main.go") {
		t.Errorf("event 3: got type %q output %q, want tool_output", allEvents[3].Type, allEvents[3].Output)
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
