package agent

import (
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Claude writes a slash command and its output as transcript rows wrapped in
// provider markup. These lines are copied from local Claude Code transcripts
// with project content removed.
func TestClaudeLocalCommandInvocationProjectsToQuietNotice(t *testing.T) {
	for name, line := range map[string]string{
		"system row": `{"type":"system","subtype":"local_command","uuid":"s1","timestamp":"2026-10-14T11:49:33Z","content":"<command-name>/resume</command-name>\n            <command-message>resume</command-message>\n            <command-args></command-args>"}`,
		"user row":   `{"type":"user","uuid":"u1","timestamp":"2026-10-14T11:49:33Z","isMeta":false,"message":{"role":"user","content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"}}`,
	} {
		t.Run(name, func(t *testing.T) {
			events := newParser("claude").parse([]byte(line))
			if len(events) != 1 {
				t.Fatalf("events = %#v, want one notice", events)
			}
			event := events[0]
			if event.Type != "system" || event.Role != "system" {
				t.Fatalf("event = %#v, want a system-role notice", event)
			}
			if strings.ContainsAny(event.Content, "<>") {
				t.Fatalf("content = %q, want the command without markup", event.Content)
			}
			if !strings.HasPrefix(event.Content, "/") {
				t.Fatalf("content = %q, want a slash command", event.Content)
			}
			command, _ := event.Payload["localCommand"].(map[string]any)
			if command["kind"] != "command" || command["name"] != event.Content {
				t.Fatalf("localCommand = %#v, want kind=command name=%q", command, event.Content)
			}
			canonical := api.CanonicalAgentEventFromObservation(event, "s", "s", 1, time.Now())
			if canonical.Type != "message.created" || canonical.Payload["role"] != "system" {
				t.Fatalf("canonical = %#v, want a system message row", canonical)
			}
		})
	}
}

func TestClaudeLocalCommandKeepsArguments(t *testing.T) {
	// Real transcripts put command-message before command-name and carry the
	// prompt-sized argument the person typed.
	line := `{"type":"user","uuid":"u1","timestamp":"2026-10-14T11:49:33Z","message":{"role":"user","content":"<command-message>review-mr</command-message>\n<command-name>/review-mr</command-name>\n<command-args>https://example.test/merge_requests/1 fix the layout</command-args>"}}`
	events := newParser("claude").parse([]byte(line))
	if len(events) != 1 {
		t.Fatalf("events = %#v, want one notice", events)
	}
	if got, want := events[0].Content, "/review-mr https://example.test/merge_requests/1 fix the layout"; got != want {
		t.Fatalf("content = %q, want %q", got, want)
	}
	command, _ := events[0].Payload["localCommand"].(map[string]any)
	if command["args"] != "https://example.test/merge_requests/1 fix the layout" {
		t.Fatalf("args = %v", command["args"])
	}
}

func TestClaudeLocalCommandOutputIsMutedText(t *testing.T) {
	events := newParser("claude").parse([]byte(`{"type":"system","subtype":"local_command","uuid":"s2","timestamp":"2026-10-14T11:49:33Z","content":"<local-command-stdout>Resume cancelled</local-command-stdout>"}`))
	if len(events) != 1 || events[0].Type != "system" || events[0].Content != "Resume cancelled" {
		t.Fatalf("events = %#v, want the output as a notice", events)
	}
	command, _ := events[0].Payload["localCommand"].(map[string]any)
	if command["kind"] != "output" {
		t.Fatalf("localCommand = %#v, want kind=output", command)
	}
}

func TestClaudeLocalCommandEmptyOutputIsDropped(t *testing.T) {
	events := newParser("claude").parse([]byte(`{"type":"system","subtype":"local_command","uuid":"s3","timestamp":"2026-10-14T11:49:33Z","content":"<local-command-stdout></local-command-stdout>"}`))
	if len(events) != 0 {
		t.Fatalf("events = %#v, want none for empty output", events)
	}
}

func TestClaudeLocalCommandStripsTerminalEscapes(t *testing.T) {
	// A /context dump is mostly cursor and color codes; a notice shows text.
	events := newParser("claude").parse([]byte(`{"type":"system","subtype":"local_command","uuid":"s4","timestamp":"2026-10-14T11:49:33Z","content":"<local-command-stdout> \u001b[1mContext Usage\u001b[22m\n\u001b[38;2;136;136;136m854.2k/1m tokens (85%)\u001b[39m</local-command-stdout>"}`))
	if len(events) != 1 {
		t.Fatalf("events = %#v, want one notice", events)
	}
	if strings.ContainsRune(events[0].Content, 0x1b) {
		t.Fatalf("content = %q, want escapes stripped", events[0].Content)
	}
	if !strings.Contains(events[0].Content, "Context Usage") || !strings.Contains(events[0].Content, "854.2k/1m tokens (85%)") {
		t.Fatalf("content = %q, want the readable text", events[0].Content)
	}
}

func TestClaudeLocalCommandCaveatStaysHidden(t *testing.T) {
	line := `{"type":"user","uuid":"u2","timestamp":"2026-10-14T11:49:33Z","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request.</local-command-caveat>"}}`
	events := newParser("claude").parse([]byte(line))
	if len(events) != 1 || events[0].Type != "system_instructions" || events[0].Role != "system" {
		t.Fatalf("events = %#v, want hidden system_instructions", events)
	}
}

func TestClaudeUnknownLocalCommandMarkupIsLeftAsIs(t *testing.T) {
	raw := "<local-command-stdout>kept</local-command-stdout><unexpected>text</unexpected>"
	line := `{"type":"system","subtype":"local_command","uuid":"s5","timestamp":"2026-10-14T11:49:33Z","content":"` + raw + `"}`
	events := newParser("claude").parse([]byte(line))
	if len(events) != 1 || events[0].Type != "system" {
		t.Fatalf("events = %#v, want the row left as a system event", events)
	}
	if events[0].Content != raw {
		t.Fatalf("content = %q, want %q", events[0].Content, raw)
	}
	if _, ok := events[0].Payload["localCommand"]; ok {
		t.Fatalf("payload = %#v, want no localCommand for unknown markup", events[0].Payload)
	}
}

func TestClaudeSlashCommandTextPromptIsUntouched(t *testing.T) {
	// A person typing about a tag in a prompt is not a provider envelope.
	line := `{"type":"user","uuid":"u3","timestamp":"2026-10-14T11:49:33Z","message":{"role":"user","content":"please explain <command-name> in the docs"}}`
	events := newParser("claude").parse([]byte(line))
	if len(events) != 1 || events[0].Type != "user" {
		t.Fatalf("events = %#v, want a user prompt", events)
	}
}
