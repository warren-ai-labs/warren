package agent

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func writeLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	data := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
}

func appendLine(t *testing.T, path, line string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(line + "\n"); err != nil {
		t.Fatal(err)
	}
}

func TestReadNewNormalizesCodexTranscript(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-test.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/work"}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"Bash","arguments":"{\"command\":\"ls\"}"}}`,
		`{"timestamp":"2026-08-16T10:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"file.txt\n"}}`,
		`{"timestamp":"2026-08-16T10:00:04Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Do it"}]}}`,
	)

	events, next, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	if next <= 0 {
		t.Fatalf("offset did not advance: %d", next)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "assistant,tool_call,tool_output,user"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[0].Content != "Hello" || events[1].ToolName != "shell" || events[2].Output != "file.txt\n" {
		t.Fatalf("normalized events = %#v", events)
	}
}

func TestReadNewTrackedRestartsAfterAtomicReplacement(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "session.jsonl")
	writeLines(t, path, `{"type":"user","uuid":"u1","message":{"role":"user","content":"old"}}`)
	parser := newParser("claude")
	first, offset, info, err := readNewTracked(path, 0, parser, nil)
	if err != nil || len(first) != 1 || info == nil {
		t.Fatalf("initial tracked read = events %v, offset %d, info %v, err %v", first, offset, info, err)
	}
	temporary := filepath.Join(directory, "session.new")
	writeLines(t, temporary, `{"type":"user","uuid":"u2","message":{"role":"user","content":"new content after replacement"}}`)
	if err := os.Rename(temporary, path); err != nil {
		t.Fatal(err)
	}
	second, next, replacementInfo, err := readNewTracked(path, offset, parser, info)
	if err != nil {
		t.Fatal(err)
	}
	if replacementInfo == nil || os.SameFile(info, replacementInfo) {
		t.Fatal("atomic replacement must expose a new file identity")
	}
	if next <= offset || len(second) != 1 || second[0].Content != "new content after replacement" {
		t.Fatalf("replacement read = events %v, offset %d (previous %d)", second, next, offset)
	}
}

func TestContentStringLimitBoundsBlockAssembly(t *testing.T) {
	large := strings.Repeat("x", maxEventContent*2)
	value, err := json.Marshal([]map[string]any{
		{"text": "prefix"},
		{"text": large},
		{"text": large},
	})
	if err != nil {
		t.Fatal(err)
	}

	got := contentStringLimit(value, 16)
	want := "prefix\n" + strings.Repeat("x", 9) + "…"
	if got != want {
		t.Fatalf("limited content = %q, want %q", got, want)
	}
}

func TestContentStringLimitKeepsFullReadAndNestedContent(t *testing.T) {
	value := json.RawMessage(`[{"text":"hello"},{"type":"image"},{"content":"nested content"}]`)
	if got, want := contentStringLimit(value, 0), "hello\n[image]\nnested content"; got != want {
		t.Fatalf("full content = %q, want %q", got, want)
	}
	if got, want := contentStringLimit(value, 8), "hello\n[i…"; got != want {
		t.Fatalf("limited content = %q, want %q", got, want)
	}
}

func TestTruncatePreservesRuneLimit(t *testing.T) {
	for _, test := range []struct {
		value string
		limit int
		want  string
	}{
		{value: "abcdef", limit: 3, want: "abc…"},
		{value: "ééé", limit: 2, want: "éé…"},
		{value: "éé", limit: 3, want: "éé"},
	} {
		if got := truncate(test.value, test.limit); got != test.want {
			t.Errorf("truncate(%q, %d) = %q, want %q", test.value, test.limit, got, test.want)
		}
	}
}

func TestCodexDeveloperAndInjectedContextCollapseToSystemInstructions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-instructions.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions> long policy"}]}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/work</cwd>\n</environment_context>"}]}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Real question"}]}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "system_instructions,system_instructions,user"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[2].Content != "Real question" {
		t.Fatalf("last user content = %q", events[2].Content)
	}
}

func TestCodexWebSearchAndStreamingMessagesNormalize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-web.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"web_search_call","id":"call-1","status":"completed","action":{"type":"search","queries":["site:example.com codex"]}}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"web_search_call","id":"call-2","status":"failed","action":{"type":"open_page","url":"https://example.com/a"}}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"Let me look at that file"}}`,
		`{"timestamp":"2026-08-16T10:00:03Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Checking read scope"}}`,
		`{"timestamp":"2026-08-16T10:00:04Z","type":"response_item","payload":{"type":"plan","id":"plan-1","content":[{"type":"output_text","text":"Proposed plan"}]}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "tool_call,tool_call,assistant,reasoning,unknown"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[0].ToolName != "web_search" || events[0].ToolStatus != "success" {
		t.Fatalf("web search success = %#v", events[0])
	}
	if events[1].ToolStatus != "error" {
		t.Fatalf("web search failure = %#v", events[1])
	}
	if events[2].Content != "Let me look at that file" || events[3].Content != "Checking read scope" {
		t.Fatalf("streaming events = %#v", events[2:4])
	}
	if events[4].Content != "Proposed plan" {
		t.Fatalf("unknown fallback should extract inner text, got %q", events[4].Content)
	}
}

func TestCodexDeduplicatesTwinStreamingEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-twin.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"reasoning","content":[{"type":"reasoning","text":"Think once"}]}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Think once"}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Reply once"}]}}`,
		`{"timestamp":"2026-08-16T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"Reply once"}}`,
		`{"timestamp":"2026-08-16T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}}`,
		`{"timestamp":"2026-08-16T10:00:05Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"Bash","arguments":"{\"command\":\"ls\"}"}}`,
		`{"timestamp":"2026-08-16T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4,"output_tokens":5,"total_tokens":9}}}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	// Reasoning and assistant appear once. Usage events stay in the stream;
	// the web client decides where to surface them.
	if got, want := strings.Join(kinds, ","), "reasoning,assistant,usage,tool_call,usage"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
}

func TestCodexApprovedPrefixNoticeIsHidden(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-approved.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"Approved command prefix saved:\n- [\"glab\", \"mr\", \"view\"]"}]}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Real user turn"}]}}`,
	)
	events, _, err := readNew(path, 0, newParser("codex"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Type != "user" {
		t.Fatalf("events = %#v, want only the real user turn", events)
	}
}

func TestClaudeHookAttachmentIsSuppressed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-hooks.jsonl")
	writeLines(t, path,
		`{"type":"attachment","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"","stdout":"done"}}`,
	)
	events, _, err := readNew(path, 0, newParser("claude"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("hook attachment produced events = %#v, want none", events)
	}
}

func TestClaudeSkillListingStaysAsSystemInstructions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-skill-listing.jsonl")
	writeLines(t, path,
		`{"type":"attachment","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","attachment":{"type":"skill_listing","content":"- skill: demo"}}`,
	)
	events, _, err := readNew(path, 0, newParser("claude"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Type != "system_instructions" || events[0].Content != "- skill: demo" {
		t.Fatalf("skill listing = %#v", events)
	}
}

func TestReadNewNormalizesClaudeTranscript(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	writeLines(t, path,
		`{"type":"summary","summary":"fixture","leafUuid":null}`,
		`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"user","content":"Hello"}}`,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}`,
	)

	events, _, err := readNew(path, 0, newParser("claude"))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, event := range events {
		kinds = append(kinds, event.Type)
	}
	if got, want := strings.Join(kinds, ","), "user,assistant,tool_call"; got != want {
		t.Fatalf("event kinds = %q, want %q", got, want)
	}
	if events[0].Content != "Hello" || events[1].Content != "Hi" || events[2].ToolName != "shell" {
		t.Fatalf("normalized events = %#v", events)
	}
}

func TestWatcherTailsNewLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-live.jsonl")
	writeLines(t, path, `{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}`)

	var mu sync.Mutex
	var seen []api.AgentEvent
	watcher := Start("session-1", "codex", path, func(events []api.AgentEvent, _ api.AgentStatus) {
		mu.Lock()
		seen = append(seen, events...)
		mu.Unlock()
	}, nil, nil)
	defer watcher.Close()

	deadline := time.Now().Add(3 * time.Second)
	for {
		mu.Lock()
		count := len(seen)
		mu.Unlock()
		if count >= 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("initial event never arrived")
		}
		time.Sleep(10 * time.Millisecond)
	}

	appendLine(t, path, `{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"live"}]}}`)
	deadline = time.Now().Add(3 * time.Second)
	for {
		mu.Lock()
		count := len(seen)
		var contents []string
		var sequences []uint64
		for _, event := range seen {
			contents = append(contents, event.Content)
			sequences = append(sequences, event.Sequence)
		}
		mu.Unlock()
		if count >= 2 {
			if contents[1] != "live" {
				t.Fatalf("live event content = %q, want live", contents[1])
			}
			if sequences[0] != 1 || sequences[1] != 2 {
				t.Fatalf("event sequences = %d,%d, want 1,2", sequences[0], sequences[1])
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("live event never arrived: %#v", contents)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestWatcherPreservesFastTurnBoundaries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-fast-turn.jsonl")
	writeLines(t, path, `{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ready"}]}}`)

	type observedTurns struct {
		turns  []api.AgentTurn
		replay bool
	}
	turns := make(chan observedTurns, 2)
	initial := make(chan struct{}, 1)
	watcher := Start("session-1", "codex", path, func([]api.AgentEvent, api.AgentStatus) {
		initial <- struct{}{}
	}, nil, func(value []api.AgentTurn, replay bool) {
		turns <- observedTurns{turns: value, replay: replay}
	})
	defer watcher.Close()
	select {
	case <-initial:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for initial transcript read")
	}

	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(strings.Join([]string{
		`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"task_started"}}`,
		`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}`,
	}, "\n") + "\n")
	closeErr := file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}

	select {
	case observed := <-turns:
		got := observed.turns
		if observed.replay || len(got) != 2 || got[0] != (api.AgentTurn{ID: 1, Status: api.AgentTurnStarted}) ||
			got[1] != (api.AgentTurn{ID: 1, Status: api.AgentTurnCompleted}) {
			t.Fatalf("turns = %#v, want fast turn boundaries", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for turn boundaries")
	}
}

func TestFinderPicksNewestMatchingCodex(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sessions")
	older := filepath.Join(root, "2026", "08", "16", "rollout-old.jsonl")
	newer := filepath.Join(root, "2026", "08", "16", "rollout-new.jsonl")
	writeLines(t, older, `{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"old","cwd":"/work/warren"}}`)
	writeLines(t, newer, `{"timestamp":"2026-08-16T11:00:00Z","type":"session_meta","payload":{"id":"new","cwd":"/work/warren"}}`)
	writeLines(t, filepath.Join(root, "2026", "08", "16", "rollout-other.jsonl"),
		`{"timestamp":"2026-08-16T11:10:00Z","type":"session_meta","payload":{"id":"other","cwd":"/elsewhere"}}`)

	finder := DefaultFinder{CodexRoot: root}
	path, err := finder.Find(context.Background(), "codex", "/work/warren", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(path) != "rollout-new.jsonl" {
		t.Fatalf("finder picked %q, want rollout-new.jsonl", path)
	}
}

func TestFinderMatchesCodexTranscriptEvenWhenFileIsLarge(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sessions")
	path := filepath.Join(root, "2026", "08", "19", "rollout-large.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	first := `{"timestamp":"2026-08-19T10:00:00Z","type":"session_meta","payload":{"id":"large","cwd":"/work/warren"}}` + "\n"
	data := append([]byte(first), []byte(strings.Repeat("x", 2*1024*1024))...)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	found, err := (DefaultFinder{CodexRoot: root}).Find(context.Background(), "codex", "/work/warren", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if found != path {
		t.Fatalf("finder picked %q, want %q", found, path)
	}
}

func TestFinderSkipsSymlinkTranscripts(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sessions")
	outside := filepath.Join(t.TempDir(), "rollout-outside.jsonl")
	if err := os.WriteFile(outside, []byte(`{"timestamp":"2026-08-19T10:00:00Z","type":"session_meta","payload":{"cwd":"/work/warren"}}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "rollout-link.jsonl")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	found, err := (DefaultFinder{CodexRoot: root}).Find(context.Background(), "codex", "/work/warren", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if found != "" {
		t.Fatalf("finder adopted symlink transcript %q", found)
	}
}

func TestFinderIgnoresTranscriptsBeforeSessionStart(t *testing.T) {
	root := filepath.Join(t.TempDir(), "sessions")
	path := filepath.Join(root, "2026", "08", "16", "rollout-old.jsonl")
	writeLines(t, path, `{"timestamp":"2026-08-16T10:00:00Z","type":"session_meta","payload":{"id":"old","cwd":"/work/warren"}}`)
	finder := DefaultFinder{CodexRoot: root}
	future := time.Now().Add(time.Hour)
	found, err := finder.Find(context.Background(), "codex", "/work/warren", future)
	if err != nil {
		t.Fatal(err)
	}
	if found != "" {
		t.Fatalf("finder adopted a transcript older than the session: %q", found)
	}
}

func TestFinderMatchesClaudeCwd(t *testing.T) {
	root := filepath.Join(t.TempDir(), "projects")
	path := filepath.Join(root, "-work-warren", "session.jsonl")
	writeLines(t, path,
		`{"type":"summary","summary":"x","leafUuid":null}`,
		`{"type":"user","uuid":"u1","cwd":"/work/warren","message":{"role":"user","content":"hi"}}`,
	)

	finder := DefaultFinder{ClaudeRoot: root}
	found, err := finder.Find(context.Background(), "claude", "/work/warren", time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if found != path {
		t.Fatalf("finder picked %q, want %q", found, path)
	}
}

func TestCodexToolOutputAttributionAndStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-tools.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"Bash","arguments":"{\"command\":\"false\"}"}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"output\":\"boom\",\"metadata\":{\"exit_code\":1,\"error\":\"command failed\"}}"}}`,
	)
	parser := newParser("codex")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v, want 2", events)
	}
	call := events[0]
	output := events[1]
	if call.ToolName != "shell" || output.ToolName != "shell" || output.CallID != "call-1" {
		t.Fatalf("tool attribution = %#v / %#v", call, output)
	}
	if output.ToolStatus != "error" || output.Error != "command failed" || output.Output != "boom" {
		t.Fatalf("tool status = %#v", output)
	}
}

func TestCodexTokenUsageEvent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-tokens.jsonl")
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5","effort":"high"}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":30},"model_context_window":272000}}}`,
	)
	parser := newParser("codex")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v, want config and usage events", events)
	}
	cfg := events[0]
	if cfg.Type != "config" || cfg.Payload["model"] != "gpt-5" || cfg.Payload["reasoningEffort"] != "high" {
		t.Fatalf("config event = %#v", cfg)
	}
	usage := events[1]
	if usage.Type != "usage" || usage.Model != "gpt-5" || usage.Usage == nil {
		t.Fatalf("usage event = %#v", usage)
	}
	if usage.Usage.InputTokens != 10 || usage.Usage.CacheReadInputTokens != 4 ||
		usage.Usage.OutputTokens != 20 || usage.Usage.ReasoningOutputTokens != 5 ||
		usage.Usage.TotalTokens != 30 {
		t.Fatalf("usage details = %#v", usage.Usage)
	}
}

func TestClaudeToolResultErrorAndFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-tools.jsonl")
	writeLines(t, path,
		`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"cannot read file","is_error":true}]},"toolUseResult":{"filePath":"/work/warren/main.go","interrupted":false}}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %#v, want 1", events)
	}
	event := events[0]
	if event.Type != "tool_output" || event.CallID != "toolu_1" ||
		event.ToolStatus != "error" || event.Error != "cannot read file" ||
		len(event.Files) != 1 || event.Files[0] != "/work/warren/main.go" {
		t.Fatalf("tool result = %#v", event)
	}
}

func TestClaudeAssistantCarriesModelUsage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-assistant.jsonl")
	writeLines(t, path,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","isSidechain":false,"message":{"id":"msg_1","model":"claude-opus-4-7","role":"assistant","content":[{"type":"text","text":"top-level reply"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("events = %#v, want 1", events)
	}
	event := events[0]
	if event.Type != "assistant" || event.Sidechain || event.Model != "claude-opus-4-7" ||
		event.StopReason != "end_turn" || event.Usage == nil ||
		event.Usage.InputTokens != 100 || event.Usage.OutputTokens != 50 {
		t.Fatalf("assistant event = %#v", event)
	}
}

func TestClaudeApiErrorBecomesErrorEvent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-error.jsonl")
	writeLines(t, path,
		`{"type":"system","subtype":"api_error","uuid":"s1","timestamp":"2026-08-16T10:00:00Z","content":"upstream timeout"}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Type != "error" || events[0].Error != "upstream timeout" {
		t.Fatalf("error event = %#v", events)
	}
}

func TestClaudeUserInterruptSetsStopReason(t *testing.T) {
	parser := newParser("claude")
	events := parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}`))
	if len(events) != 1 || events[0].Type != "system" || events[0].StopReason != "interrupted" {
		t.Fatalf("interrupt event = %#v, want Type=system StopReason=interrupted", events)
	}
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("activity after Claude interrupt = %q, want ready", got)
	}
}

func TestCodexTaskCompleteErrorBecomesErrorEvent(t *testing.T) {
	parser := newParser("codex")
	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}`))
	events := parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"unexpected status 403 Forbidden: quota exceeded","codex_error_info":"other"}}}`))
	if len(events) != 1 || events[0].Type != "error" ||
		events[0].Error != "unexpected status 403 Forbidden: quota exceeded" {
		t.Fatalf("error event = %#v", events)
	}
	if got := parser.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("activity after 403 task_complete = %q, want failed", got)
	}
}

func TestCodexLegacyEventMsgErrorStaysFailedAfterTaskComplete(t *testing.T) {
	parser := newParser("codex")
	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}`))
	events := parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"error","message":"unexpected status 502 Bad Gateway: nginx","codex_error_info":"other"}}`))
	if len(events) != 1 || events[0].Type != "error" {
		t.Fatalf("legacy error event = %#v", events)
	}
	if got := parser.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("activity after legacy error = %q, want failed", got)
	}

	events = parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}`))
	if len(events) != 0 {
		t.Fatalf("task_complete after error emitted %#v, want none", events)
	}
	if got := parser.Activity(); got != api.AgentActivityFailed {
		t.Fatalf("activity after legacy task_complete = %q, want failed", got)
	}
}

func TestCodexNon200ErrorsAllFail(t *testing.T) {
	for _, message := range []string{
		"unexpected status 401 Unauthorized: no auth available",
		"unexpected status 403 Forbidden: insufficient balance",
		"unexpected status 404 Not Found: missing route",
		"unexpected status 413 Payload Too Large: request too big",
		"exceeded retry limit, last status: 429 Too Many Requests",
		"unexpected status 502 Bad Gateway: nginx",
		"unexpected status 503 Service Unavailable: backend down",
		"stream disconnected before completion: stream closed before response.completed",
	} {
		parser := newParser("codex")
		parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}`))
		events := parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"` + message + `","codex_error_info":"other"}}}`))
		if len(events) != 1 || events[0].Error != message {
			t.Fatalf("error event for %q = %#v", message, events)
		}
		if got := parser.Activity(); got != api.AgentActivityFailed {
			t.Fatalf("activity for %q = %q, want failed", message, got)
		}
	}
}

func TestCodexTurnAbortedAfterErrorReturnsReady(t *testing.T) {
	parser := newParser("codex")
	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}`))
	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"unexpected status 403 Forbidden: quota exceeded","codex_error_info":"other"}}}`))
	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:02Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}`))
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("activity after Esc = %q, want ready", got)
	}

	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:03Z","type":"event_msg","payload":{"type":"task_started"}}`))
	parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}`))
	if got := parser.Activity(); got != api.AgentActivityReady {
		t.Fatalf("activity after next clean turn = %q, want ready", got)
	}
}

func TestCodexApplyPatchExtractsFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-patch.jsonl")
	arguments := `{\"patch\":\"*** Add File: src/a.go\\n+package a\\n*** Update File: src/b.go\\n- old\\n+ new\"}`
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"apply_patch","arguments":"`+arguments+`"}}`,
	)
	parser := newParser("codex")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || len(events[0].Files) != 2 ||
		events[0].Files[0] != "src/a.go" || events[0].Files[1] != "src/b.go" {
		t.Fatalf("patch files = %#v", events)
	}
}

func TestCodexCustomToolCallNormalizes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-custom-tool.jsonl")
	patch := "*** Begin Patch\n*** Update File: src/a.go\n- old\n+ new\n*** Add File: src/b.go\n+package b"
	input, err := json.Marshal(patch)
	if err != nil {
		t.Fatal(err)
	}
	writeLines(t, path,
		`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","id":"item-1","call_id":"call-1","status":"completed","name":"apply_patch","input":`+string(input)+`}}`,
		`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1","output":"patched"}}`,
	)
	parser := newParser("codex")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v, want tool_call and tool_output", events)
	}
	call := events[0]
	if call.Type != "tool_call" || call.ToolName != "apply_patch" ||
		call.CallID != "call-1" || call.ToolStatus != "success" {
		t.Fatalf("custom tool call = %#v", call)
	}
	inputMap, ok := call.ToolInput.(map[string]any)
	if !ok || inputMap["patch"] != patch {
		t.Fatalf("custom tool input = %#v, want patch map", call.ToolInput)
	}
	if len(call.Files) != 2 || call.Files[0] != "src/a.go" || call.Files[1] != "src/b.go" {
		t.Fatalf("custom tool files = %#v", call.Files)
	}
	output := events[1]
	if output.Type != "tool_output" || output.CallID != "call-1" ||
		output.ToolName != "apply_patch" || output.Output != "patched" {
		t.Fatalf("custom tool output = %#v", output)
	}
}

func TestClaudeEditToolCarriesFilePath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-edit.jsonl")
	writeLines(t, path,
		`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/work/warren/main.go","old_string":"a","new_string":"b"}}]}}`,
	)
	parser := newParser("claude")
	events, _, err := readNew(path, 0, parser)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || len(events[0].Files) != 1 || events[0].Files[0] != "/work/warren/main.go" {
		t.Fatalf("edit files = %#v", events)
	}
}

func TestCanonicalToolName(t *testing.T) {
	cases := []struct {
		provider string
		raw      string
		want     string
	}{
		{"claude", "Bash", "shell"},
		{"claude", "Read", "read"},
		{"claude", "Edit", "edit"},
		{"claude", "Write", "write"},
		{"claude", "Grep", "grep"},
		{"claude", "Glob", "glob"},
		{"claude", "WebSearch", "web_search"},
		{"claude", "WebFetch", "fetch"},
		{"claude", "Task", "subagent"},
		{"claude", "AskUserQuestion", "ask_user_question"},
		{"claude", "PermissionRequest", "permission_request"},
		{"codex", "local_shell_call", "shell"},
		{"codex", "exec", "shell"},
		{"codex", "web_search_call", "web_search"},
		{"codex", "apply_patch", "apply_patch"},
		{"codex", "read_file", "read"},
		{"antigravity", "run_command", "shell"},
		{"antigravity", "replace_file_content", "edit"},
		{"opencode", "bash", "shell"},
		{"opencode", "edit", "edit"},
		{"opencode", "task", "subagent"},
		{"opencode", "web_search", "web_search"},
		// unknown names are passed through lowercased
		{"claude", "SomeUnknownTool", "someunknowntool"},
		{"codex", "CustomFutureTool", "customfuturetool"},
		// empty / whitespace
		{"claude", "", ""},
		{"claude", "   ", ""},
	}
	for _, test := range cases {
		if got := canonicalToolName(test.provider, test.raw); got != test.want {
			t.Errorf("canonicalToolName(%q, %q) = %q, want %q", test.provider, test.raw, got, test.want)
		}
	}
}

func TestEventIsRenderable(t *testing.T) {
	cases := []struct {
		name  string
		event api.AgentEvent
		want  bool
	}{
		{"empty", api.AgentEvent{}, false},
		{"system with content", api.AgentEvent{Type: "system", Content: "hello"}, true},
		{"tool output with output", api.AgentEvent{Type: "tool_output", Output: "result"}, true},
		{"error with error", api.AgentEvent{Type: "error", Error: "boom"}, true},
		{"usage with payload", api.AgentEvent{Type: "usage", Usage: &api.AgentUsage{InputTokens: 1}}, true},
		{"tool call with input", api.AgentEvent{Type: "tool_call", ToolName: "shell", ToolInput: map[string]any{"cmd": "ls"}}, true},
		{"tool call with name only", api.AgentEvent{Type: "tool_call", ToolName: "shell"}, true},
		{"tool output bare", api.AgentEvent{Type: "tool_output"}, true},
		{"canonical tool started bare", api.AgentEvent{Type: "tool_started"}, true},
		{"canonical tool failed bare", api.AgentEvent{Type: "tool_failed"}, true},
		{"question structured", api.AgentEvent{Type: "question", Payload: map[string]any{"x": 1}}, true},
		{"compaction bare", api.AgentEvent{Type: "compaction"}, true},
		{"subagent bare", api.AgentEvent{Type: "subagent"}, true},
		{"attachment with content", api.AgentEvent{Type: "attachment", Content: "x"}, true},
		{"attachment empty", api.AgentEvent{Type: "attachment"}, false},
		{"system_instructions bare", api.AgentEvent{Type: "system_instructions"}, false},
		{"unknown bare", api.AgentEvent{Type: "unknown"}, false},
		{"whitespace only", api.AgentEvent{Type: "system", Content: "   \n\t  "}, false},
	}
	for _, test := range cases {
		if got := eventIsRenderable(test.event); got != test.want {
			t.Errorf("%s: eventIsRenderable(%#v) = %v, want %v", test.name, test.event, got, test.want)
		}
	}
}

func TestClaudeEmptyAttachmentIsSuppressed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-empty-attach.jsonl")
	writeLines(t, path,
		`{"type":"attachment","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","attachment":{"type":"file","content":""}}`,
		`{"type":"attachment","uuid":"a2","timestamp":"2026-08-16T10:00:01Z","attachment":{"type":"file","content":"   "}}`,
	)
	events, _, err := readNew(path, 0, newParser("claude"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("empty attachments produced events = %#v, want none", events)
	}
}

func TestClaudeNonEmptyAttachmentPreserved(t *testing.T) {
	path := filepath.Join(t.TempDir(), "claude-attach.jsonl")
	writeLines(t, path,
		`{"type":"attachment","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","attachment":{"type":"file","content":"aGVsbG8gd29ybGQ="}}`,
	)
	events, _, err := readNew(path, 0, newParser("claude"))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Type != "attachment" || events[0].Content != "aGVsbG8gd29ybGQ=" {
		t.Fatalf("attachment = %#v", events)
	}
}

func TestClaudeToolOutputCarriesToolName(t *testing.T) {
	// Claude tool_result blocks don't carry the originating tool name. The
	// parser must look it up via the assistant tool_use block's callID so a
	// standalone tool_output card (one whose activity group has flushed) can
	// still display "Shell" rather than "Tool".
	parser := newParser("claude")
	parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}`))
	events := parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file.txt"}]}}`))
	if len(events) != 1 || events[0].Type != "tool_output" || events[0].ToolName != "shell" {
		t.Fatalf("tool output = %#v, want ToolName=shell", events)
	}
}

func TestCodexCompactedEventPromotedToCompaction(t *testing.T) {
	parser := newParser("codex")
	events := parser.parse([]byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"compacted","payload":{}}`))
	if len(events) != 1 || events[0].Type != "compaction" {
		t.Fatalf("compacted event = %#v, want Type=compaction", events)
	}
}

func TestClaudeAskUserQuestionProjectsToRFC0010Question(t *testing.T) {
	parser := newParser("claude")
	events := parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q1","name":"AskUserQuestion","input":{"questions":[{"question":"Which database?","header":"DB","options":[{"label":"Postgres","description":"sql"},{"label":"MySQL","description":"sql too"}],"multiSelect":false}]}}]}}`))
	if len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("events = %#v, want single question event", events)
	}
	if events[0].Payload == nil {
		t.Fatal("question event has no payload")
	}
	if events[0].Payload["requestId"] != "toolu_q1" {
		t.Errorf("requestId = %v, want toolu_q1", events[0].Payload["requestId"])
	}
	if events[0].Payload["title"] != "Question" {
		t.Errorf("title = %v, want Question", events[0].Payload["title"])
	}
	if events[0].Payload["state"] != "pending" {
		t.Errorf("state = %v, want pending", events[0].Payload["state"])
	}
	if events[0].Payload["questions"] == nil {
		t.Error("payload.questions missing")
	}
	if questions, ok := events[0].Payload["questions"].([]any); !ok || len(questions) != 1 {
		t.Fatalf("payload.questions = %v, want exactly one question", events[0].Payload["questions"])
	} else {
		q0, ok := questions[0].(map[string]any)
		if !ok {
			t.Fatalf("payload.questions[0] is not an object: %T", questions[0])
		}
		if q0["id"] != "q0" {
			t.Errorf("questions[0].id = %v, want q0", q0["id"])
		}
		if q0["prompt"] != "Which database?" {
			t.Errorf("questions[0].prompt = %v, want Which database?", q0["prompt"])
		}
		if q0["selection"] != "single" {
			t.Errorf("questions[0].selection = %v, want single", q0["selection"])
		}
		options, ok := q0["options"].([]any)
		if !ok || len(options) != 2 {
			t.Fatalf("questions[0].options = %v, want two options", q0["options"])
		}
		first, ok := options[0].(map[string]any)
		if !ok {
			t.Fatalf("options[0] is not an object: %T", options[0])
		}
		if first["id"] != "Postgres" || first["label"] != "Postgres" || first["description"] != "sql" {
			t.Errorf("options[0] = %v, want id/label Postgres and description sql", first)
		}
	}
}

func TestClaudeAskUserQuestionMultiSelect(t *testing.T) {
	parser := newParser("claude")
	events := parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q2","name":"AskUserQuestion","input":{"questions":[{"question":"Pick many","options":[{"label":"A"},{"label":"B"}],"multiSelect":true}]}}]}}`))
	if len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("events = %#v, want single question event", events)
	}
	questions, ok := events[0].Payload["questions"].([]any)
	if !ok || len(questions) != 1 {
		t.Fatalf("payload.questions = %v, want one question", events[0].Payload["questions"])
	}
	q0, ok := questions[0].(map[string]any)
	if !ok {
		t.Fatalf("questions[0] is not an object: %T", questions[0])
	}
	if q0["selection"] != "multiple" {
		t.Errorf("selection = %v, want multiple", q0["selection"])
	}
	if q0["prompt"] != "Pick many" {
		t.Errorf("prompt = %v, want Pick many", q0["prompt"])
	}
}

func TestClaudePermissionRequestProjectsToRFC0010Permission(t *testing.T) {
	parser := newParser("claude")
	events := parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_p1","name":"PermissionRequest","input":{"tool":"Bash","behavior":"allow","updated_input":{"command":"ls"}}}]}}`))
	if len(events) != 1 || events[0].Type != "permission" {
		t.Fatalf("events = %#v, want single permission event", events)
	}
	if events[0].Payload == nil {
		t.Fatal("permission event has no payload")
	}
	if events[0].Payload["requestId"] != "toolu_p1" {
		t.Errorf("requestId = %v, want toolu_p1", events[0].Payload["requestId"])
	}
	if events[0].Payload["action"] != "Bash" {
		t.Errorf("action = %v, want Bash", events[0].Payload["action"])
	}
	if events[0].Payload["description"] != "Claude requests permission to run Bash" {
		t.Errorf("description = %v, want a sanitized tool summary", events[0].Payload["description"])
	}
	options, ok := events[0].Payload["options"].([]any)
	if !ok || len(options) == 0 {
		t.Fatalf("payload.options = %v, want decision options", events[0].Payload["options"])
	}
	if first, ok := options[0].(map[string]any); !ok || first["id"] != "allow" {
		t.Errorf("options[0] = %v, want allow decision", options[0])
	}
	if events[0].Payload["state"] != "pending" {
		t.Errorf("state = %v, want pending", events[0].Payload["state"])
	}
}

func TestClaudeQuestionResolvesOnAnswer(t *testing.T) {
	parser := newParser("claude")
	pending := parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q1","name":"AskUserQuestion","input":{"questions":[{"question":"Which database?","options":[{"label":"Postgres"}]}]}}]}}`))
	if len(pending) != 1 || pending[0].Type != "question" || pending[0].Payload["state"] != "pending" {
		t.Fatalf("pending = %#v, want single pending question", pending)
	}
	resolved := parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_q1","content":"Postgres"}]}}`))
	if len(resolved) != 1 || resolved[0].Type != "question" {
		t.Fatalf("resolved = %#v, want single resolved question", resolved)
	}
	if resolved[0].ID != "toolu_q1" {
		t.Errorf("resolved id = %v, want toolu_q1", resolved[0].ID)
	}
	if resolved[0].Payload["state"] != "resolved" {
		t.Errorf("resolved state = %v, want resolved", resolved[0].Payload["state"])
	}
	if resolved[0].Payload["requestId"] != "toolu_q1" {
		t.Errorf("resolved requestId = %v, want toolu_q1", resolved[0].Payload["requestId"])
	}
}

func TestClaudePermissionRejectedOnError(t *testing.T) {
	parser := newParser("claude")
	parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_p1","name":"PermissionRequest","input":{"tool":"Bash","behavior":"allow"}}]}}`))
	events := parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_p1","content":"denied","is_error":true}]}}`))
	if len(events) != 1 || events[0].Type != "permission" {
		t.Fatalf("events = %#v, want single permission event", events)
	}
	if events[0].Payload["state"] != "cancelled" {
		t.Errorf("state = %v, want cancelled", events[0].Payload["state"])
	}
}

func TestClaudeTodoWriteProjectsToTodo(t *testing.T) {
	parser := newParser("claude")
	events := parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_t1","name":"TodoWrite","input":{"todos":[{"content":"Investigate","status":"in_progress","activeForm":"Investigating"},{"content":"Fix","status":"pending","activeForm":"Fixing"}]}}]}}`))
	if len(events) != 1 || events[0].Type != "todo" {
		t.Fatalf("events = %#v, want single todo event", events)
	}
	if events[0].ID != "claude-todos" {
		t.Errorf("id = %v, want claude-todos", events[0].ID)
	}
	if events[0].Payload["todoId"] != "claude-todos" {
		t.Errorf("todoId = %v, want claude-todos", events[0].Payload["todoId"])
	}
	if events[0].Payload["state"] != "in_progress" {
		t.Errorf("state = %v, want in_progress", events[0].Payload["state"])
	}
	items, ok := events[0].Payload["items"].([]any)
	if !ok || len(items) != 2 {
		t.Fatalf("items = %v, want two items", events[0].Payload["items"])
	}
	first, ok := items[0].(map[string]any)
	if !ok {
		t.Fatalf("items[0] is not an object: %T", items[0])
	}
	if first["label"] != "Investigate" || first["state"] != "in_progress" {
		t.Errorf("items[0] = %v, want label Investigate state in_progress", first)
	}
}

func TestClaudeTodoWriteToolResultIsSuppressed(t *testing.T) {
	parser := newParser("claude")
	parser.parse([]byte(`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_t1","name":"TodoWrite","input":{"todos":[{"content":"Investigate","status":"in_progress"}]}}]}}`))
	events := parser.parse([]byte(`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_t1","content":"success"}]}}`))
	if len(events) != 0 {
		t.Fatalf("events = %#v, want no events for TodoWrite result", events)
	}
}

func TestClaudeSidechainAssistantProjectsToSubagent(t *testing.T) {
	parser := newParser("claude")
	events := parser.parse([]byte(`{"type":"assistant","uuid":"sub-1","timestamp":"2026-08-16T10:00:00Z","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent finished"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}`))
	if len(events) != 2 {
		t.Fatalf("events = %#v, want 2 (subagent + tool_call)", events)
	}
	if events[0].Type != "subagent" {
		t.Fatalf("first event = %#v, want Type=subagent", events[0])
	}
	if events[0].Payload["subagentId"] != "sub-1" {
		t.Errorf("subagentId = %v, want sub-1", events[0].Payload["subagentId"])
	}
	if events[0].Payload["summary"] != "subagent finished" {
		t.Errorf("summary = %v, want subagent finished", events[0].Payload["summary"])
	}
	if events[0].Payload["label"] != "Subagent" {
		t.Errorf("label = %v, want Subagent", events[0].Payload["label"])
	}
	if events[0].Payload["state"] != "completed" {
		t.Errorf("state = %v, want completed", events[0].Payload["state"])
	}
	if events[1].Type != "tool_call" || events[1].ToolName != "shell" {
		t.Fatalf("second event = %#v, want tool_call shell", events[1])
	}
}

// TestAgentEventProtocolAcrossProviders is the cross-provider regression
// check that the parser contract is uniform: every event the UI sees must
// use a canonical Type, every tool_call / tool_output must carry the same
// canonical ToolName, and no protocol-noise event (hooks, empty cards,
// usage placeholders) ever leaks into the stream.
func TestAgentEventProtocolAcrossProviders(t *testing.T) {
	allowedTypes := map[string]struct{}{
		"user": {}, "assistant": {}, "reasoning": {},
		"tool_call": {}, "tool_output": {},
		"error": {}, "compaction": {}, "usage": {},
		"system": {}, "system_instructions": {},
		"question": {}, "permission": {}, "plan": {}, "todo": {},
		"activity": {}, "plugin": {}, "subagent": {}, "attachment": {}, "config": {},
	}

	type fixture struct {
		name     string
		provider string
		lines    []string
	}
	fixtures := []fixture{
		{
			name:     "claude turn",
			provider: "claude",
			lines: []string{
				`{"type":"user","uuid":"u1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"user","content":"hi"}}`,
				`{"type":"assistant","uuid":"a1","timestamp":"2026-08-16T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"hello"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}`,
				`{"type":"user","uuid":"u2","timestamp":"2026-08-16T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file.txt"}]}}`,
				`{"type":"attachment","uuid":"a2","timestamp":"2026-08-16T10:00:03Z","attachment":{"type":"hook_success","hookName":"x"}}`,
				`{"type":"attachment","uuid":"a3","timestamp":"2026-08-16T10:00:04Z","attachment":{"type":"file","content":""}}`,
			},
		},
		{
			name:     "codex turn",
			provider: "codex",
			lines: []string{
				`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}`,
				`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"c1","name":"Bash","arguments":"{\"command\":\"ls\"}"}}`,
				`{"timestamp":"2026-08-16T10:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"file.txt"}}`,
				`{"timestamp":"2026-08-16T10:00:03Z","type":"compacted","payload":{}}`,
				`{"timestamp":"2026-08-16T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}}`,
			},
		},
		{
			name:     "opencode turn",
			provider: "opencode",
			lines: []string{
				`{"messageID":"m1","role":"user","parts":[{"id":"p1","type":"text","text":"hi"}]}`,
				`{"messageID":"m2","role":"assistant","modelID":"claude","parts":[{"id":"p2","type":"text","text":"hello"},{"id":"p3","type":"tool","callID":"c1","tool":"bash","state":{"status":"running","input":{"command":"ls"}}}]}`,
			},
		},
	}

	for _, fx := range fixtures {
		t.Run(fx.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), fx.provider+".jsonl")
			writeLines(t, path, fx.lines...)
			events, _, err := readNew(path, 0, newParser(fx.provider))
			if err != nil {
				t.Fatal(err)
			}
			// Every Type must be in the canonical vocabulary.
			for _, event := range events {
				if _, ok := allowedTypes[event.Type]; !ok {
					t.Errorf("event Type %q is not in canonical vocabulary", event.Type)
				}
			}
			// tool_call and tool_output sharing a callID must share a
			// canonical ToolName. Codex/claude: matched by codexCallTool /
			// claudeCallTool. opencode: same callID in the same envelope.
			seen := map[string]string{}
			for _, event := range events {
				if event.CallID == "" {
					continue
				}
				if event.Type == "tool_call" || event.Type == "tool_output" {
					if other, exists := seen[event.CallID]; exists && other != event.ToolName {
						t.Errorf("call %q: tool_call ToolName=%q, tool_output ToolName=%q", event.CallID, other, event.ToolName)
					}
					seen[event.CallID] = event.ToolName
				}
			}
			// No empty-content event except the structured kinds that don't
			// need text.
			for _, event := range events {
				if strings.TrimSpace(event.Content) == "" &&
					strings.TrimSpace(event.Output) == "" &&
					strings.TrimSpace(event.Error) == "" &&
					event.Usage == nil &&
					event.ToolInput == nil &&
					event.Type != "tool_call" && event.Type != "tool_output" &&
					event.Type != "question" && event.Type != "permission" &&
					event.Type != "plan" && event.Type != "todo" &&
					event.Type != "activity" && event.Type != "plugin" &&
					event.Type != "subagent" && event.Type != "compaction" &&
					event.Type != "config" {
					t.Errorf("event %s/%s slipped through with no payload: %#v", event.Provider, event.Type, event)
				}
			}
		})
	}
}

func TestCodexUpdatePlanAndSpawnAgent(t *testing.T) {
	p := newParser("codex")

	planLine := []byte(`{"timestamp":"2025-09-24T06:05:37Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","call_id":"call_1","arguments":"{\"plan\":[{\"step\":\"Inspect repo structure\",\"status\":\"in_progress\"},{\"step\":\"Check scripts\",\"status\":\"pending\"}]}"}}`)
	events := p.Parse(planLine)
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "plan" {
		t.Errorf("expected type plan, got %s", events[0].Type)
	}
	items, ok := events[0].Payload["items"].([]map[string]any)
	if !ok || len(items) != 2 {
		t.Fatalf("expected 2 plan items, got %#v", events[0].Payload["items"])
	}
	if items[0]["title"] != "Inspect repo structure" || items[0]["state"] != "in_progress" {
		t.Errorf("unexpected first item: %#v", items[0])
	}

	spawnLine := []byte(`{"timestamp":"2025-09-24T06:05:38Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","call_id":"call_spawn_1","arguments":"{\"agent_type\":\"CodeReviewer\",\"prompt\":\"Review changed files\"}"}}`)
	events = p.Parse(spawnLine)
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "subagent" {
		t.Errorf("expected type subagent, got %s", events[0].Type)
	}
	if events[0].Payload["label"] != "CodeReviewer" || events[0].Payload["summary"] != "Review changed files" {
		t.Errorf("unexpected subagent payload: %#v", events[0].Payload)
	}
}

func TestAntigravityPlanAndSubagent(t *testing.T) {
	p := newParser("antigravity")

	planLine := []byte(`{"step_index":2,"source":"PLANNER_RESPONSE","type":"PLAN","status":"in_progress","created_at":"2025-09-02T11:41:00Z","content":"Inspect the iOS session stream","tool_calls":[]}`)
	events := p.Parse(planLine)
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "plan" {
		t.Errorf("expected type plan, got %s", events[0].Type)
	}
	if events[0].Payload["summary"] != "Inspect the iOS session stream" {
		t.Errorf("expected summary %q, got %q", "Inspect the iOS session stream", events[0].Payload["summary"])
	}

	subagentLine := []byte(`{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2025-09-02T11:42:00Z","content":"","tool_calls":[{"name":"invoke_subagent","args":{"Subagents":[{"Role":"Tester","Prompt":"Run test suite"}]}}]}`)
	events = p.Parse(subagentLine)
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "subagent" {
		t.Errorf("expected type subagent, got %s", events[0].Type)
	}
	if events[0].Payload["label"] != "Tester" || events[0].Payload["summary"] != "Run test suite" {
		t.Errorf("unexpected subagent payload: %#v", events[0].Payload)
	}
}

func TestQoderSidechainSubagent(t *testing.T) {
	p := newParser("qoder")

	sidechainLine := []byte(`{"type":"assistant","uuid":"q-sidechain-1","isSidechain":true,"timestamp":"2025-09-02T11:41:00Z","sessionId":"s1","message":{"role":"assistant","content":[{"type":"text","text":"Explored repo and found entrypoint."}]}}`)
	events := p.Parse(sidechainLine)
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != "subagent" {
		t.Errorf("expected type subagent, got %s", events[0].Type)
	}
	if events[0].Payload["summary"] != "Explored repo and found entrypoint." {
		t.Errorf("expected summary %q, got %q", "Explored repo and found entrypoint.", events[0].Payload["summary"])
	}
}

func TestCodexQuestionAttentionAndResolution(t *testing.T) {
	p := newParser("codex")
	qLine := []byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"call_q1","name":"request_user_input","arguments":"{\"questions\":[{\"id\":\"q1\",\"header\":\"Confirm\",\"question\":\"Do you want to proceed?\",\"options\":[{\"label\":\"yes\",\"description\":\"continue\"},{\"label\":\"no\"}]}]}"}}`)
	events := p.Parse(qLine)
	if len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("expected question event, got %#v", events)
	}
	if events[0].Payload["state"] != "pending" {
		t.Fatalf("expected state pending, got %v", events[0].Payload["state"])
	}
	status := p.Status()
	if status.Activity != api.AgentActivityBlocked || status.Attention == nil || status.Attention.Reason != "question" || status.Attention.RequestID != "call_q1" {
		t.Fatalf("expected blocked attention on question, got %#v", status)
	}

	ansLine := []byte(`{"timestamp":"2026-08-16T10:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_q1","output":"{\"answers\":{\"q1\":{\"answers\":[\"yes\"]}}}"}}`)
	events = p.Parse(ansLine)
	if len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("expected resolved question event, got %#v", events)
	}
	if events[0].Payload["state"] != "resolved" {
		t.Fatalf("expected state resolved, got %v", events[0].Payload["state"])
	}
	status = p.Status()
	if status.Activity == api.AgentActivityBlocked || status.Attention != nil {
		t.Fatalf("expected attention cleared after answering, got %#v", status)
	}
}

func TestCodexUnavailableRequestUserInputIsToolFailure(t *testing.T) {
	p := newParser("codex")
	qLine := []byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"call-unavailable","name":"request_user_input","arguments":"{\"questions\":[{\"id\":\"q1\",\"question\":\"Continue?\",\"options\":[{\"label\":\"yes\"}]}]}"}}`)
	if events := p.Parse(qLine); len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("expected pending question event, got %#v", events)
	}
	outputLine := []byte(`{"timestamp":"2026-08-16T10:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-unavailable","output":"request_user_input is unavailable in Default mode"}}`)
	events := p.Parse(outputLine)
	if len(events) != 1 || events[0].Type != "tool_output" {
		t.Fatalf("expected diagnostic tool output, got %#v", events)
	}
	if events[0].ToolStatus != "error" || !strings.Contains(events[0].Error, "request_user_input is unavailable") {
		t.Fatalf("unexpected diagnostic event: %#v", events[0])
	}
	status := p.Status()
	if status.Attention != nil {
		t.Fatalf("expected unavailable interaction attention to be cleared, got %#v", status.Attention)
	}
}

func TestCodexThreadGoalUpdatedIsProjected(t *testing.T) {
	p := newParser("codex")
	events := p.Parse([]byte(`{"timestamp":"2026-08-29T17:42:02.437Z","type":"event_msg","payload":{"type":"thread_goal_updated","threadId":"thread-1","turnId":"turn-1","goal":{"threadId":"thread-1","objective":"Ship the mobile polish","status":"active","tokenBudget":12000,"tokensUsed":42,"timeUsedSeconds":9}}}`))
	if len(events) != 1 {
		t.Fatalf("goal events = %#v", events)
	}
	event := events[0]
	if event.Type != "goal" || event.ID != "thread-1" {
		t.Fatalf("goal event identity = %#v", event)
	}
	if event.Payload["objective"] != "Ship the mobile polish" || event.Payload["state"] != "active" {
		t.Fatalf("goal payload = %#v", event.Payload)
	}
	if event.Payload["tokenBudget"] != int64(12000) || event.Payload["tokensUsed"] != int64(42) {
		t.Fatalf("goal accounting = %#v", event.Payload)
	}
}

func TestCodexThreadGoalClearedIsProjected(t *testing.T) {
	p := newParser("codex")
	events := p.Parse([]byte(`{"timestamp":"2026-08-29T17:42:02.437Z","type":"event_msg","payload":{"type":"thread_goal_cleared","threadId":"thread-1"}}`))
	if len(events) != 1 || events[0].Type != "goal" || events[0].Payload["state"] != "cleared" {
		t.Fatalf("cleared goal events = %#v", events)
	}
}

func TestCodexGoalOutputFromCustomToolCallSupportsCamelCaseAndNestedShape(t *testing.T) {
	p := newParser("codex")
	call := []byte(`{"timestamp":"2026-08-29T17:42:02.437Z","type":"response_item","payload":{"type":"custom_tool_call","id":"item-goal","call_id":"call-goal","name":"create_goal","input":"{}"}}`)
	if events := p.Parse(call); len(events) != 1 || events[0].Type != "tool_call" {
		t.Fatalf("goal tool call = %#v", events)
	}
	output := []byte(`{"timestamp":"2026-08-29T17:42:02.438Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-goal","output":"{\"goal\":{\"threadId\":\"thread-2\",\"objective\":\"Review the iOS capsule\",\"status\":\"usageLimited\",\"tokenBudget\":8000,\"tokensUsed\":120,\"timeUsedSeconds\":7}}"}}`)
	events := p.Parse(output)
	if len(events) != 1 || events[0].Type != "goal" || events[0].ID != "thread-2" {
		t.Fatalf("goal output = %#v", events)
	}
	event := events[0]
	if event.Payload["state"] != "usage_limited" || event.Payload["status"] != "usage_limited" {
		t.Fatalf("goal status = %#v", event.Payload)
	}
	if event.Payload["tokenBudget"] != int64(8000) || event.Payload["tokensUsed"] != int64(120) {
		t.Fatalf("goal accounting = %#v", event.Payload)
	}
}

func TestCodexGoalOutputUsesFallbackThreadAndTopLevelCamelCase(t *testing.T) {
	p := newParser("codex")
	p.Parse([]byte(`{"timestamp":"2026-08-29T17:42:02.437Z","type":"session_meta","payload":{"id":"thread-fallback"}}`))
	call := []byte(`{"timestamp":"2026-08-29T17:42:02.438Z","type":"response_item","payload":{"type":"function_call","call_id":"call-goal","name":"get_goal","arguments":"{}"}}`)
	if events := p.Parse(call); len(events) != 1 || events[0].Type != "tool_call" {
		t.Fatalf("goal tool call = %#v", events)
	}
	output := []byte(`{"timestamp":"2026-08-29T17:42:02.439Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-goal","output":"{\"objective\":\"Keep the release green\",\"status\":\"budgetLimited\",\"tokensUsed\":300,\"timeUsedSeconds\":12}"}}`)
	events := p.Parse(output)
	if len(events) != 1 || events[0].Type != "goal" || events[0].ID != "thread-fallback" {
		t.Fatalf("fallback goal output = %#v", events)
	}
	if events[0].Payload["state"] != "budget_limited" {
		t.Fatalf("fallback goal status = %#v", events[0].Payload)
	}
}

func TestCodexGoalOutputFromExecWrapperIsProjected(t *testing.T) {
	p := newParser("codex")
	p.Parse([]byte(`{"timestamp":"2026-09-06T17:34:38.794Z","type":"session_meta","payload":{"id":"thread-exec"}}`))
	call := []byte(`{"timestamp":"2026-09-06T17:34:38.795Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-exec-goal","name":"exec","input":"const r = await tools.get_goal({});\ntext(r);\n"}}`)
	if events := p.Parse(call); len(events) != 1 || events[0].Type != "tool_call" {
		t.Fatalf("exec goal tool call = %#v", events)
	}
	output := []byte(`{"timestamp":"2026-09-06T17:34:38.796Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-exec-goal","output":[{"type":"input_text","text":"Script completed\n"},{"type":"input_text","text":"{\"goal\":{\"threadId\":\"thread-exec\",\"objective\":\"Inspect the Goal capsule\",\"status\":\"active\",\"tokensUsed\":12}}"}]}}`)
	events := p.Parse(output)
	if len(events) != 1 || events[0].Type != "goal" || events[0].ID != "thread-exec" {
		t.Fatalf("exec goal output = %#v", events)
	}
	if events[0].Payload["objective"] != "Inspect the Goal capsule" {
		t.Fatalf("exec goal payload = %#v", events[0].Payload)
	}
}

func TestCodexArbitraryToolOutputIsNotProjectedAsGoal(t *testing.T) {
	p := newParser("codex")
	call := []byte(`{"timestamp":"2026-08-29T17:42:02.437Z","type":"response_item","payload":{"type":"function_call","call_id":"call-json","name":"run_report","arguments":"{}"}}`)
	if events := p.Parse(call); len(events) != 1 || events[0].Type != "tool_call" {
		t.Fatalf("report tool call = %#v", events)
	}
	output := []byte(`{"timestamp":"2026-08-29T17:42:02.438Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-json","output":"{\"objective\":\"not a goal\",\"status\":\"active\"}"}}`)
	events := p.Parse(output)
	if len(events) != 1 || events[0].Type != "tool_output" {
		t.Fatalf("arbitrary object output = %#v", events)
	}
}

func TestCodexPlanStateCalculation(t *testing.T) {
	p := newParser("codex")
	inProgLine := []byte(`{"timestamp":"2026-08-16T10:00:00Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Step 1\",\"status\":\"completed\"},{\"step\":\"Step 2\",\"status\":\"in_progress\"}]}"}}`)
	events := p.Parse(inProgLine)
	if len(events) != 1 || events[0].Type != "plan" {
		t.Fatalf("expected plan event, got %#v", events)
	}
	if events[0].Payload["state"] != "in_progress" {
		t.Fatalf("expected state in_progress, got %v", events[0].Payload["state"])
	}

	doneLine := []byte(`{"timestamp":"2026-08-16T10:00:10Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Step 1\",\"status\":\"completed\"},{\"step\":\"Step 2\",\"status\":\"completed\"}]}"}}`)
	events = p.Parse(doneLine)
	if len(events) != 1 || events[0].Type != "plan" {
		t.Fatalf("expected plan event, got %#v", events)
	}
	if events[0].Payload["state"] != "completed" {
		t.Fatalf("expected state completed, got %v", events[0].Payload["state"])
	}
}

func TestQoderQuestionAttentionAndResolution(t *testing.T) {
	p := newParser("qoder")
	qLine := []byte(`{"type":"assistant","uuid":"a-q1","timestamp":"2026-08-16T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_q1","name":"AskUserQuestion","input":{"questions":[{"question":"Which port?","options":[{"label":"8080"}]}]}}]}}`)
	events := p.Parse(qLine)
	if len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("expected question event, got %#v", events)
	}
	if events[0].Payload["state"] != "pending" {
		t.Fatalf("expected state pending, got %v", events[0].Payload["state"])
	}
	status := p.Status()
	if status.Activity != api.AgentActivityBlocked || status.Attention == nil || status.Attention.Reason != "question" || status.Attention.RequestID != "tool_q1" {
		t.Fatalf("expected blocked attention on question, got %#v", status)
	}

	ansLine := []byte(`{"type":"user","uuid":"u-a1","timestamp":"2026-08-16T10:00:05Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_q1","content":"8080","is_error":false}]}}`)
	events = p.Parse(ansLine)
	if len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("expected resolved question event, got %#v", events)
	}
	if events[0].Payload["state"] != "resolved" {
		t.Fatalf("expected state resolved, got %v", events[0].Payload["state"])
	}
	status = p.Status()
	if status.Activity == api.AgentActivityBlocked || status.Attention != nil {
		t.Fatalf("expected attention cleared after answering, got %#v", status)
	}
}

func TestQoderRuntimeConfigAndPlanAttachment(t *testing.T) {
	p := newParser("qoder")
	cfgLine := []byte(`{"type":"runtime-config","sessionId":"s1","model":"claude-3-7-sonnet","reasoningEffort":"high","timestamp":1788350322619}`)
	events := p.Parse(cfgLine)
	if len(events) != 1 || events[0].Type != "config" {
		t.Fatalf("expected config event, got %#v", events)
	}
	if events[0].Payload["model"] != "claude-3-7-sonnet" || events[0].Payload["reasoningEffort"] != "high" {
		t.Fatalf("unexpected config payload: %#v", events[0].Payload)
	}

	attLine := []byte(`{"type":"attachment","uuid":"att-plan-1","timestamp":"2026-08-16T10:00:01Z","attachment":{"type":"plan","planFilePath":".qoder/plans/setup.md"}}`)
	events = p.Parse(attLine)
	if len(events) != 1 || events[0].Type != "plan" {
		t.Fatalf("expected plan event, got %#v", events)
	}
	if events[0].Payload["file"] != ".qoder/plans/setup.md" {
		t.Fatalf("unexpected plan payload: %#v", events[0].Payload)
	}
}

func TestOpenCodeQuestionTodoAndSubagent(t *testing.T) {
	p := newParser("opencode")
	// Question pending
	qPending := []byte(`{"messageID":"m1","role":"assistant","parts":[{"id":"p_q1","type":"tool","callID":"call_q1","tool":"question","state":{"status":"running","input":{"questions":[{"question":"Deploy now?","options":[{"label":"yes"},{"label":"no"}]}]}}}]}`)
	events := p.Parse(qPending)
	if len(events) != 1 || events[0].Type != "question" {
		t.Fatalf("expected question event, got %#v", events)
	}
	status := p.Status()
	if status.Activity != api.AgentActivityBlocked || status.Attention == nil || status.Attention.Reason != "question" || status.Attention.RequestID != "call_q1" {
		t.Fatalf("expected blocked attention on opencode question, got %#v", status)
	}

	// Question completed
	qDone := []byte(`{"messageID":"m1","role":"assistant","parts":[{"id":"p_q1","type":"tool","callID":"call_q1","tool":"question","state":{"status":"completed","output":"yes"}}]}`)
	events = p.Parse(qDone)
	if len(events) != 1 || events[0].Type != "question" || events[0].Payload["state"] != "resolved" {
		t.Fatalf("expected resolved question event, got %#v", events)
	}
	status = p.Status()
	if status.Activity == api.AgentActivityBlocked || status.Attention != nil {
		t.Fatalf("expected attention cleared after opencode question resolved, got %#v", status)
	}

	// Todowrite
	todoLine := []byte(`{"messageID":"m2","role":"assistant","parts":[{"id":"p_td","type":"tool","callID":"call_td","tool":"todowrite","state":{"status":"completed","input":{"todos":[{"content":"step 1","status":"completed"},{"content":"step 2","status":"pending"}]}}}]}`)
	events = p.Parse(todoLine)
	if len(events) != 1 || events[0].Type != "todo" {
		t.Fatalf("expected todo event, got %#v", events)
	}
	if events[0].Payload["state"] != "in_progress" {
		t.Fatalf("expected todo state in_progress, got %v", events[0].Payload["state"])
	}

	// Subagent (call_omo_agent)
	subLine := []byte(`{"messageID":"m3","role":"assistant","parts":[{"id":"p_sub","type":"tool","callID":"call_sub1","tool":"call_omo_agent","state":{"status":"running","input":{"subagent_type":"explore","prompt":"Search auth logic"}}}]}`)
	events = p.Parse(subLine)
	if len(events) != 1 || events[0].Type != "subagent" {
		t.Fatalf("expected subagent event, got %#v", events)
	}
	if events[0].Payload["state"] != "running" || events[0].Payload["label"] != "explore" {
		t.Fatalf("unexpected subagent payload: %#v", events[0].Payload)
	}
}

func TestPiConfigChangeAndCompaction(t *testing.T) {
	p := newParser("pi")
	modelLine := []byte(`{"type":"model_change","id":"mc-1","provider":"google","modelId":"gemini-2.5-pro","timestamp":"2026-08-16T10:00:00Z"}`)
	events := p.Parse(modelLine)
	if len(events) != 1 || events[0].Type != "config" {
		t.Fatalf("expected config event from model_change, got %#v", events)
	}
	if events[0].Payload["model"] != "google/gemini-2.5-pro" {
		t.Fatalf("unexpected model in payload: %#v", events[0].Payload)
	}

	thinkingLine := []byte(`{"type":"thinking_level_change","id":"tc-1","thinkingLevel":"high","timestamp":"2026-08-16T10:00:01Z"}`)
	events = p.Parse(thinkingLine)
	if len(events) != 1 || events[0].Type != "config" {
		t.Fatalf("expected config event from thinking_level_change, got %#v", events)
	}
	if events[0].Payload["reasoningEffort"] != "high" {
		t.Fatalf("unexpected reasoningEffort in payload: %#v", events[0].Payload)
	}

	compactionLine := []byte(`{"type":"compaction","id":"cmp-1","timestamp":"2026-08-16T10:00:02Z"}`)
	events = p.Parse(compactionLine)
	if len(events) != 1 || events[0].Type != "compaction" {
		t.Fatalf("expected compaction event, got %#v", events)
	}
}

func TestCanonicalProtocolProjectionForNewEvents(t *testing.T) {
	now := time.Now()
	// Test question -> interaction.requested
	qEvt := api.AgentEvent{
		Provider:  "codex",
		Type:      "question",
		ID:        "q-1",
		Payload:   map[string]any{"requestId": "q-1", "title": "Question"},
		Timestamp: now,
	}
	canonQ := api.CanonicalAgentEventFromObservation(qEvt, "stream-1", "exec-1", 1, now)
	if canonQ.Type != "interaction.requested" {
		t.Fatalf("expected interaction.requested, got %s", canonQ.Type)
	}

	// Test config -> config.updated with model and reasoningEffort preserved
	cfgEvt := api.AgentEvent{
		Provider:  "codex",
		Type:      "config",
		ID:        "cfg-1",
		Payload:   map[string]any{"model": "gpt-5", "reasoningEffort": "high"},
		Timestamp: now,
	}
	canonCfg := api.CanonicalAgentEventFromObservation(cfgEvt, "stream-1", "exec-1", 2, now)
	if canonCfg.Type != "config.updated" {
		t.Fatalf("expected config.updated, got %s", canonCfg.Type)
	}
	if canonCfg.Payload["model"] != "gpt-5" || canonCfg.Payload["reasoningEffort"] != "high" {
		t.Fatalf("unexpected canonical config payload: %#v", canonCfg.Payload)
	}

	// Test compaction -> compaction.updated
	cmpEvt := api.AgentEvent{
		Provider:  "pi",
		Type:      "compaction",
		ID:        "cmp-1",
		Payload:   map[string]any{"summary": "History compacted"},
		Timestamp: now,
	}
	canonCmp := api.CanonicalAgentEventFromObservation(cmpEvt, "stream-1", "exec-1", 3, now)
	if canonCmp.Type != "compaction.updated" {
		t.Fatalf("expected compaction.updated, got %s", canonCmp.Type)
	}
}

func TestRealDataCodexPlayback(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	sessionsRoot := filepath.Join(home, ".codex", "sessions")
	var targetFile string
	_ = filepath.WalkDir(sessionsRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		targetFile = path
		return filepath.SkipAll
	})
	if targetFile == "" {
		t.Skip("no real codex sessions found")
	}

	f, err := os.Open(targetFile)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	parser := newParser("codex")
	scanner := bufio.NewScanner(f)
	var totalEvents int
	typeCounts := make(map[string]int)

	for scanner.Scan() {
		line := scanner.Bytes()
		events := parser.Parse(line)
		for _, e := range events {
			totalEvents++
			typeCounts[e.Type]++
			canon := api.CanonicalAgentEventFromObservation(e, "test-stream", "test-exec", uint64(totalEvents), time.Now())
			if canon.Type == "" {
				t.Fatalf("empty canonical type for event: %#v", e)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if totalEvents == 0 {
		t.Fatalf("expected events parsed from real codex session %s, got 0", targetFile)
	}
	t.Logf("Replayed Codex %s: %d total events, breakdown: %+v", filepath.Base(targetFile), totalEvents, typeCounts)
}

func TestRealDataQoderPlayback(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	projectsRoot := filepath.Join(home, ".qoder", "projects")
	var targetFile string
	_ = filepath.WalkDir(projectsRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		targetFile = path
		return filepath.SkipAll
	})
	if targetFile == "" {
		t.Skip("no real qoder sessions found")
	}

	f, err := os.Open(targetFile)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	parser := newParser("qoder")
	scanner := bufio.NewScanner(f)
	var totalEvents int
	typeCounts := make(map[string]int)

	for scanner.Scan() {
		line := scanner.Bytes()
		events := parser.Parse(line)
		for _, e := range events {
			totalEvents++
			typeCounts[e.Type]++
			canon := api.CanonicalAgentEventFromObservation(e, "test-stream", "test-exec", uint64(totalEvents), time.Now())
			if canon.Type == "" {
				t.Fatalf("empty canonical type for event: %#v", e)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if totalEvents == 0 {
		t.Fatalf("expected events parsed from real qoder session %s, got 0", targetFile)
	}
	t.Logf("Replayed Qoder %s: %d total events, breakdown: %+v", filepath.Base(targetFile), totalEvents, typeCounts)
}

func TestRealDataPiPlayback(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	sessionsRoot := filepath.Join(home, ".pi", "agent", "sessions")
	var targetFile string
	_ = filepath.WalkDir(sessionsRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Ext(path) != ".jsonl" {
			return nil
		}
		targetFile = path
		return filepath.SkipAll
	})
	if targetFile == "" {
		t.Skip("no real pi sessions found")
	}

	f, err := os.Open(targetFile)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	parser := newParser("pi")
	scanner := bufio.NewScanner(f)
	var totalEvents int
	typeCounts := make(map[string]int)

	for scanner.Scan() {
		line := scanner.Bytes()
		events := parser.Parse(line)
		for _, e := range events {
			totalEvents++
			typeCounts[e.Type]++
			canon := api.CanonicalAgentEventFromObservation(e, "test-stream", "test-exec", uint64(totalEvents), time.Now())
			if canon.Type == "" {
				t.Fatalf("empty canonical type for event: %#v", e)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if totalEvents == 0 {
		t.Fatalf("expected events parsed from real pi session %s, got 0", targetFile)
	}
	t.Logf("Replayed Pi %s: %d total events, breakdown: %+v", filepath.Base(targetFile), totalEvents, typeCounts)
}

func TestRealDataOpenCodePlayback(t *testing.T) {
	dbPath := OpenCodeDatabasePath("")
	if _, err := os.Stat(dbPath); err != nil {
		t.Skip("no real opencode.db found")
	}

	reader := sqliteOpenCodeReader{databasePath: dbPath}
	sessions, err := findSQLiteOpenCodeSessions(context.Background(), dbPath, "", time.Time{}, "")
	if err != nil || len(sessions) == 0 {
		t.Skip("no opencode sessions in db")
	}
	sessionID := sessions[0].ID

	messages, err := reader.ReadMessages(context.Background(), sessionID, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) == 0 {
		t.Skip("session has no messages")
	}

	parser := newParser("opencode")
	var totalEvents int
	typeCounts := make(map[string]int)

	for _, msg := range messages {
		envelope, complete := openCodeEnvelopeFromSource(msg)
		if !complete || envelope.MessageID == "" {
			continue
		}
		data, err := json.Marshal(envelope)
		if err != nil {
			continue
		}
		events := parser.Parse(data)
		for _, e := range events {
			totalEvents++
			typeCounts[e.Type]++
			canon := api.CanonicalAgentEventFromObservation(e, "test-stream", "test-exec", uint64(totalEvents), time.Now())
			if canon.Type == "" {
				t.Fatalf("empty canonical type for event: %#v", e)
			}
		}
	}
	if totalEvents == 0 {
		t.Fatalf("expected events parsed from opencode session %s, got 0", sessionID)
	}
	t.Logf("Replayed OpenCode %s: %d total events, breakdown: %+v", sessionID, totalEvents, typeCounts)
}

func TestDiffAndDiagnosticsNormalization_Claude(t *testing.T) {
	parser := newParser("claude")
	line := `{"type":"tool_result","timestamp":"2026-09-06T10:00:00Z","tool_name":"edit","tool_output":{"filediff":{"file":"/test/app.go","additions":5,"deletions":2},"diff":"--- a/app.go\n+++ b/app.go\n@@ -1,3 +1,6 @@\n+line1\n+line2\n-old\n","diagnostics":{"/test/app.go":[{"range":{"start":{"line":10,"character":2},"end":{"line":10,"character":8}},"severity":1,"message":"syntax error","source":"compiler","code":"syntax"}]}}}`
	events := parser.Parse([]byte(line))
	if len(events) < 3 {
		t.Fatalf("expected tool_output, diff, and diagnostics events, got %d", len(events))
	}

	var foundDiff, foundDiag bool
	for _, e := range events {
		if e.Type == "diff" {
			foundDiff = true
			if e.Payload["file"] != "/test/app.go" || e.Payload["additions"] != 5 || e.Payload["deletions"] != 2 {
				t.Fatalf("unexpected diff payload: %+v", e.Payload)
			}
			canon := api.CanonicalAgentEventFromObservation(e, "stream-1", "exec-1", 1, time.Now())
			if canon.Type != "diff.updated" {
				t.Fatalf("canonical diff type = %q, want diff.updated", canon.Type)
			}
		}
		if e.Type == "diagnostics" {
			foundDiag = true
			diags, ok := e.Payload["diagnostics"].([]api.AgentDiagnostic)
			if !ok || len(diags) == 0 {
				t.Fatalf("expected diagnostics slice in payload, got %+v", e.Payload)
			}
			if diags[0].Severity != "error" || diags[0].Line != 10 || diags[0].Message != "syntax error" {
				t.Fatalf("unexpected diagnostic item: %+v", diags[0])
			}
			canon := api.CanonicalAgentEventFromObservation(e, "stream-1", "exec-1", 2, time.Now())
			if canon.Type != "diagnostics.updated" {
				t.Fatalf("canonical diagnostics type = %q, want diagnostics.updated", canon.Type)
			}
		}
	}
	if !foundDiff || !foundDiag {
		t.Fatalf("foundDiff=%v, foundDiag=%v, want both true", foundDiff, foundDiag)
	}
}

func TestDiffNormalization_Codex(t *testing.T) {
	parser := newParser("codex")
	line := `{"timestamp":"2026-09-06T10:00:00Z","type":"event_msg","payload":{"type":"patch_apply_end","call_id":"call_123","changes":{"/test/server.go":{"type":"update","unified_diff":"--- a/server.go\n+++ b/server.go\n@@ -1,2 +1,4 @@\n+import \"fmt\"\n+func Run() {}\n-func Old() {}\n"}}}}`
	events := parser.Parse([]byte(line))
	if len(events) != 1 || events[0].Type != "diff" {
		t.Fatalf("expected 1 diff event, got %+v", events)
	}
	diffEvent := events[0]
	if diffEvent.Payload["file"] != "/test/server.go" {
		t.Fatalf("unexpected file: %+v", diffEvent.Payload)
	}
	if diffEvent.Payload["additions"] != 2 || diffEvent.Payload["deletions"] != 1 {
		t.Fatalf("unexpected adds/dels: %+v", diffEvent.Payload)
	}
	canon := api.CanonicalAgentEventFromObservation(diffEvent, "stream-1", "exec-1", 1, time.Now())
	if canon.Type != "diff.updated" {
		t.Fatalf("canonical type = %q, want diff.updated", canon.Type)
	}
}

func TestDiffNormalization_Pi(t *testing.T) {
	parser := newParser("pi")
	line := `{"type":"message","id":"m1","timestamp":"2026-09-06T10:00:00Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"edit","content":"ok","details":{"diff":"--- a/main.go\n+++ b/main.go\n+new line\n-old line\n"}}}`
	events := parser.Parse([]byte(line))
	if len(events) < 2 {
		t.Fatalf("expected tool_output and diff events, got %d", len(events))
	}
	var foundDiff bool
	for _, e := range events {
		if e.Type == "diff" {
			foundDiff = true
			if e.Payload["additions"] != 1 || e.Payload["deletions"] != 1 {
				t.Fatalf("unexpected diff payload: %+v", e.Payload)
			}
			canon := api.CanonicalAgentEventFromObservation(e, "stream-1", "exec-1", 1, time.Now())
			if canon.Type != "diff.updated" {
				t.Fatalf("canonical type = %q, want diff.updated", canon.Type)
			}
		}
	}
	if !foundDiff {
		t.Fatal("diff event not found in pi output")
	}
}

func TestQueueNormalization_Claude(t *testing.T) {
	parser := newParser("claude")
	lineEnqueue := `{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-01T10:10:48.592Z","sessionId":"sess-123","content":"Please check line 10"}`
	events := parser.Parse([]byte(lineEnqueue))
	if len(events) != 1 || events[0].Type != "queue" {
		t.Fatalf("expected 1 queue event, got %+v", events)
	}
	if events[0].Payload["action"] != "enqueue" || events[0].Payload["content"] != "Please check line 10" || events[0].Payload["state"] != "queued" {
		t.Fatalf("unexpected enqueue payload: %+v", events[0].Payload)
	}
	canon := api.CanonicalAgentEventFromObservation(events[0], "stream-1", "exec-1", 1, time.Now())
	if canon.Type != "queue.updated" {
		t.Fatalf("canonical type = %q, want queue.updated", canon.Type)
	}

	lineRemove := `{"type":"queue-operation","operation":"remove","timestamp":"2026-09-01T10:12:07.407Z","sessionId":"sess-123","content":"Please check line 10"}`
	eventsRemove := parser.Parse([]byte(lineRemove))
	if len(eventsRemove) != 1 || eventsRemove[0].Type != "queue" {
		t.Fatalf("expected 1 queue event, got %+v", eventsRemove)
	}
	if eventsRemove[0].Payload["action"] != "remove" || eventsRemove[0].Payload["state"] != "cancelled" {
		t.Fatalf("unexpected remove payload: %+v", eventsRemove[0].Payload)
	}

	lineDequeue := `{"type":"queue-operation","operation":"dequeue","timestamp":"2026-08-30T12:54:26.367Z","sessionId":"sess-123"}`
	eventsDequeue := parser.Parse([]byte(lineDequeue))
	if len(eventsDequeue) != 1 || eventsDequeue[0].Type != "queue" {
		t.Fatalf("expected 1 queue event, got %+v", eventsDequeue)
	}
	if eventsDequeue[0].Payload["action"] != "dequeue" || eventsDequeue[0].Payload["state"] != "dequeued" {
		t.Fatalf("unexpected dequeue payload: %+v", eventsDequeue[0].Payload)
	}

	lineAttachment := `{"parentUuid":"p1","type":"attachment","uuid":"att-1","timestamp":"2026-09-01T10:10:48.592Z","attachment":{"type":"queued_command","prompt":"Buffered command prompt"}}`
	eventsAtt := parser.Parse([]byte(lineAttachment))
	if len(eventsAtt) != 1 || eventsAtt[0].Type != "queue" {
		t.Fatalf("expected 1 queue event from attachment, got %+v", eventsAtt)
	}
	if eventsAtt[0].Payload["action"] != "enqueue" || eventsAtt[0].Payload["content"] != "Buffered command prompt" {
		t.Fatalf("unexpected attachment queue payload: %+v", eventsAtt[0].Payload)
	}
}

func TestQueueNormalization_Qoder(t *testing.T) {
	parser := newParser("qoder")
	line := `{"type":"attachment","uuid":"qatt-1","timestamp":"2026-09-01T10:10:48.592Z","attachment":{"type":"queued_command","prompt":"Qoder buffered command"}}`
	events := parser.Parse([]byte(line))
	if len(events) != 1 || events[0].Type != "queue" {
		t.Fatalf("expected 1 queue event, got %+v", events)
	}
	if events[0].Payload["action"] != "enqueue" || events[0].Payload["content"] != "Qoder buffered command" {
		t.Fatalf("unexpected qoder queue payload: %+v", events[0].Payload)
	}
	canon := api.CanonicalAgentEventFromObservation(events[0], "stream-1", "exec-1", 1, time.Now())
	if canon.Type != "queue.updated" {
		t.Fatalf("canonical type = %q, want queue.updated", canon.Type)
	}
}

func TestQueuePolling_Codex(t *testing.T) {
	tempDir := t.TempDir()
	dbPath := filepath.Join(tempDir, "queue_1.sqlite")

	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()

	_, err = db.Exec(`CREATE TABLE queued_items (
		id TEXT PRIMARY KEY NOT NULL,
		thread_id TEXT NOT NULL,
		payload_json TEXT NOT NULL,
		queue_order INTEGER NOT NULL,
		created_at_ms INTEGER NOT NULL,
		updated_at_ms INTEGER NOT NULL
	);`)
	if err != nil {
		t.Fatalf("create table: %v", err)
	}

	threadID := "thread-test-123"
	_, err = db.Exec(
		"INSERT INTO queued_items (id, thread_id, payload_json, queue_order, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
		"item-1", threadID, `[{"type":"text","text":"Please optimize the build script"}]`, 0, 1788581900000, 1788581900000,
	)
	if err != nil {
		t.Fatalf("insert queued item: %v", err)
	}

	p := newCodexParser(maxEventContent)
	p.SetThreadID(threadID)
	p.SetQueueDBPath(dbPath)

	// Poll 1: should observe enqueue
	events := p.PollEvents()
	if len(events) != 1 || events[0].Type != "queue" {
		t.Fatalf("expected 1 queue event on poll, got %+v", events)
	}
	if events[0].Payload["action"] != "enqueue" || events[0].Payload["content"] != "Please optimize the build script" {
		t.Fatalf("unexpected payload: %+v", events[0].Payload)
	}
	if events[0].Payload["state"] != "queued" || events[0].Payload["queueId"] != "item-1" {
		t.Fatalf("unexpected state/id: %+v", events[0].Payload)
	}
	if got := events[0].Timestamp.UnixMilli(); got != 1788581900000 {
		t.Fatalf("queue timestamp = %d, want created_at_ms", got)
	}

	canon := api.CanonicalAgentEventFromObservation(events[0], "stream-1", "exec-1", 1, time.Now())
	if canon.Type != "queue.updated" {
		t.Fatalf("canonical type = %q, want queue.updated", canon.Type)
	}

	// Poll 2: no changes, should return nil
	eventsEmpty := p.PollEvents()
	if len(eventsEmpty) != 0 {
		t.Fatalf("expected 0 events on unchanged poll, got %+v", eventsEmpty)
	}

	// Remove item (simulating Codex popping the message for execution)
	_, err = db.Exec("DELETE FROM queued_items WHERE id = ?", "item-1")
	if err != nil {
		t.Fatalf("delete queued item: %v", err)
	}

	// Poll 3: should observe dequeue
	eventsDequeue := p.PollEvents()
	if len(eventsDequeue) != 1 || eventsDequeue[0].Type != "queue" {
		t.Fatalf("expected 1 queue dequeue event, got %+v", eventsDequeue)
	}
	if eventsDequeue[0].Payload["action"] != "dequeue" || eventsDequeue[0].Payload["state"] != "dequeued" {
		t.Fatalf("unexpected dequeue payload: %+v", eventsDequeue[0].Payload)
	}
}

func TestCodexThreadIDFromTranscriptPath(t *testing.T) {
	const id = "019efdff-7955-7851-9d59-07134cc1db3b"
	if got := codexThreadIDFromTranscriptPath("/tmp/rollout-2026-06-25T16-57-18-" + id + ".jsonl"); got != id {
		t.Fatalf("thread ID = %q, want %q", got, id)
	}
	if got := codexThreadIDFromTranscriptPath("/tmp/rollout-fixture.jsonl"); got != "fixture" {
		t.Fatalf("fixture thread ID = %q, want fixture", got)
	}
	if got := codexThreadIDFromTranscriptPath("/tmp/transcript.jsonl"); got != "" {
		t.Fatalf("non-Codex path produced thread ID %q", got)
	}
}
