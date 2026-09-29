package agent

import (
	"fmt"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	codexProposedPlanOpen  = "<proposed_plan>"
	codexProposedPlanClose = "</proposed_plan>"
)

// codexAssistantEvents splits a Codex assistant message around the
// `<proposed_plan>` blocks Plan mode writes into its reply. Each block becomes
// a Plan event in the `proposed` state carrying the Markdown proposal, so
// clients can show it as its own card instead of prose wrapped in raw tags;
// the text around a block stays an assistant message. A block cut off by the
// content limit runs to the end of the message.
func codexAssistantEvents(event api.AgentEvent, content string) []api.AgentEvent {
	if !strings.Contains(content, codexProposedPlanOpen) {
		event.Content = content
		return []api.AgentEvent{event}
	}
	var events []api.AgentEvent
	appendProse := func(text string) {
		text = strings.TrimSpace(text)
		if text == "" {
			return
		}
		prose := event
		prose.Content = text
		if len(events) > 0 && prose.ID != "" {
			prose.ID = fmt.Sprintf("%s#%d", event.ID, len(events))
		}
		events = append(events, prose)
	}
	rest := content
	for {
		start := strings.Index(rest, codexProposedPlanOpen)
		if start < 0 {
			appendProse(rest)
			break
		}
		appendProse(rest[:start])
		body := rest[start+len(codexProposedPlanOpen):]
		rest = ""
		if end := strings.Index(body, codexProposedPlanClose); end >= 0 {
			rest = body[end+len(codexProposedPlanClose):]
			body = body[:end]
		}
		if proposal, ok := proposedPlanEvent(event, "codex", body); ok {
			events = append(events, proposal)
		}
	}
	return events
}
