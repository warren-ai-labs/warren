package agent

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func TestReadTranscriptReturnsRecentUsefulActivities(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	writeReadLines(t, path,
		`{"timestamp":"2026-08-19T00:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/work"}}`,
		`{"timestamp":"2026-08-19T00:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first assistant"}]}}`,
		`{"timestamp":"2026-08-19T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}}`,
		`{"timestamp":"2026-08-19T00:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"second user"}]}}`,
		`{"timestamp":"2026-08-19T00:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"third assistant"}]}}`,
	)

	events, err := ReadTranscript(context.Background(), "codex", path, ReadOptions{Recent: 2, ContentLimit: 6})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %d, want 2: %#v", len(events), events)
	}
	if events[0].Type != "user" || events[1].Type != "assistant" {
		t.Fatalf("event types = %s,%s, want user,assistant", events[0].Type, events[1].Type)
	}
	if events[0].Content != "second…" || events[1].Content != "third …" {
		t.Fatalf("truncated content = %q,%q", events[0].Content, events[1].Content)
	}
	if events[0].Sequence != 1 || events[1].Sequence != 2 {
		t.Fatalf("sequences = %d,%d, want 1,2", events[0].Sequence, events[1].Sequence)
	}
}

func TestProjectEventsMatchesTranscriptReadProjection(t *testing.T) {
	events, err := ProjectEvents([]api.AgentEvent{
		{Sequence: 1, Type: "usage", Usage: &api.AgentUsage{TotalTokens: 3}},
		{Sequence: 2, Type: "user", Content: "old"},
		{Sequence: 3, Type: "assistant", Content: strings.Repeat("x", 20)},
	}, ReadOptions{Recent: 2, ContentLimit: 8})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 || events[0].Type != "user" || events[1].Type != "assistant" {
		t.Fatalf("projected events = %#v, want recent user/assistant", events)
	}
	if events[1].Content != "xxxxxxxx…" || events[0].Sequence != 1 || events[1].Sequence != 2 {
		t.Fatalf("projected content/sequence = %#v, want clipped contiguous events", events)
	}
}

func TestReadTranscriptIncludeAndExcludeTypes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	writeReadLines(t, path,
		`{"timestamp":"2026-08-19T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}}`,
		`{"timestamp":"2026-08-19T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"question"}]}}`,
		`{"timestamp":"2026-08-19T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}`,
	)

	events, err := ReadTranscript(context.Background(), "codex", path, ReadOptions{
		IncludeTypes: []string{"usage", "assistant"},
		ExcludeTypes: []string{"assistant"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Type != "usage" {
		t.Fatalf("events = %#v, want explicit usage only", events)
	}
	if events[0].Usage == nil || events[0].Usage.TotalTokens != 3 {
		t.Fatalf("usage = %#v", events[0].Usage)
	}
}

func TestReadTranscriptFullKeepsContentLimitDisabled(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	long := strings.Repeat("x", 3000)
	writeReadLines(t, path, `{"type":"user","uuid":"u1","timestamp":"2026-08-19T00:00:00Z","message":{"role":"user","content":"`+long+`"}}`)

	events, err := ReadTranscript(context.Background(), "claude", path, ReadOptions{Full: true, ContentLimit: 1})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || len(events[0].Content) != len(long) {
		t.Fatalf("full content length = %d, want %d: %#v", len(events[0].Content), len(long), events)
	}
}

func TestReadTranscriptFullKeepsContentBeyondParserSafetyLimit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	long := strings.Repeat("x", maxEventContent+1024)
	writeReadLines(t, path, `{"type":"user","uuid":"u1","timestamp":"2026-08-19T00:00:00Z","message":{"role":"user","content":"`+long+`"}}`)

	events, err := ReadTranscript(context.Background(), "claude", path, ReadOptions{Full: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || len(events[0].Content) != len(long) {
		t.Fatalf("full content length = %d, want %d", len(events[0].Content), len(long))
	}
}

func TestReadTranscriptRejectsOversizedJSONLLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	line := `{"type":"user","uuid":"u1","message":{"role":"user","content":"` + strings.Repeat("x", maxTranscriptLine) + `"}}`
	if err := os.WriteFile(path, []byte(line+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := ReadTranscript(context.Background(), "claude", path, ReadOptions{})
	if err == nil || !strings.Contains(err.Error(), "transcript line exceeds") {
		t.Fatalf("oversized line error = %v", err)
	}
}

func TestReadTranscriptRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target.jsonl")
	link := filepath.Join(dir, "link.jsonl")
	writeReadLines(t, target, `{"type":"user","uuid":"u1","message":{"role":"user","content":"hello"}}`)
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	_, err := ReadTranscript(context.Background(), "claude", link, ReadOptions{})
	if err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("symlink read error = %v", err)
	}
}

func TestReadTranscriptRejectsInvalidOptions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	writeReadLines(t, path, `{"type":"summary","summary":"fixture"}`)
	for _, options := range []ReadOptions{{Recent: -1}, {Recent: MaxReadActivities + 1}, {ContentLimit: -1}} {
		if _, err := ReadTranscript(context.Background(), "codex", path, options); err == nil {
			t.Fatalf("ReadTranscript(%+v) accepted invalid options", options)
		}
	}
	if _, err := ReadTranscript(context.Background(), "other", path, ReadOptions{}); err == nil {
		t.Fatal("ReadTranscript accepted an invalid provider")
	}
}

func TestReadTranscriptAllHasActivityLimit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	line := `{"type":"user","message":{"role":"user","content":"x"}}` + "\n"
	for index := 0; index <= MaxReadActivities; index++ {
		if _, err := file.WriteString(line); err != nil {
			file.Close()
			t.Fatal(err)
		}
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	_, err = ReadTranscript(context.Background(), "claude", path, ReadOptions{})
	if err == nil || !strings.Contains(err.Error(), "more than") {
		t.Fatalf("activity limit error = %v", err)
	}
}

func TestReadTranscriptRejectsContextCancellation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	writeReadLines(t, path, `{"type":"user","message":{"role":"user","content":"x"}}`)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := ReadTranscript(ctx, "claude", path, ReadOptions{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel error = %v, want context.Canceled", err)
	}
}

func writeReadLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}
