package agent

import (
	"fmt"
	"hash/fnv"
	"regexp"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// proposedPlanEvent is one plan an Agent proposed for review, carried as a
// Plan event whose summary is the Markdown proposal. `proposal` marks the
// shape so clients keep drawing it as a document after its state moves from
// proposed to approved or rejected. The identity is derived from the text so
// a replayed transcript yields the same card, and a revised proposal gets a
// card of its own.
func proposedPlanEvent(event api.AgentEvent, provider, markdown string) (api.AgentEvent, bool) {
	markdown = strings.TrimSpace(markdown)
	if markdown == "" {
		return api.AgentEvent{}, false
	}
	title := "Proposed plan"
	summary := markdown
	if first, remainder, _ := strings.Cut(markdown, "\n"); strings.HasPrefix(first, "# ") {
		if heading := plainMarkdownInline(strings.TrimPrefix(first, "# ")); heading != "" {
			title = heading
			summary = strings.TrimSpace(remainder)
		}
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(markdown))
	planID := fmt.Sprintf("%s-proposed-plan-%016x", provider, hash.Sum64())
	event.ID = planID
	event.Type = "plan"
	event.Content = title
	event.Payload = map[string]any{
		"planId":   planID,
		"title":    title,
		"summary":  summary,
		"items":    []map[string]any{},
		"state":    "proposed",
		"proposal": true,
	}
	return event, true
}

var (
	markdownInlineLink     = regexp.MustCompile(`\[([^\]]+)\]\([^)]*\)`)
	markdownInlineEmphasis = regexp.MustCompile(`\*\*(.+?)\*\*`)
)

// plainMarkdownInline turns a Markdown heading into the plain label clients
// show as a card title: code spans, strong emphasis, and links keep their
// text and lose their markers.
func plainMarkdownInline(value string) string {
	value = markdownInlineLink.ReplaceAllString(value, "$1")
	value = markdownInlineEmphasis.ReplaceAllString(value, "$1")
	value = strings.ReplaceAll(value, "`", "")
	return strings.TrimSpace(value)
}
