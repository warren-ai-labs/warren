package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/client"
)

func sessionRead(ctx context.Context, c *client.Client, params map[string]any, follow bool) error {
	id := positional(params, 0, "session id")
	if _, err := subscribeTerminal(ctx, c, id); err != nil {
		return err
	}
	return sessionTerminalRead(ctx, c, params, follow)
}

// subscribeTerminal subscribes to a Session's terminal and refuses a Session
// that has none, instead of waiting on output that can never arrive.
func subscribeTerminal(ctx context.Context, c *client.Client, id string) (api.Session, error) {
	session, err := c.Subscribe(ctx, id)
	if err != nil {
		return session, err
	}
	if session.RuntimeKind == "acp" {
		return session, fmt.Errorf("session %s is an ACP Agent and has no terminal; use 'warren agent read' and 'warren agent send'", id)
	}
	return session, nil
}

func sessionAgentReadFlag(params map[string]any) bool {
	for _, key := range []string{"recent", "limit", "count", "all", "include", "filter", "exclude", "text-only", "text", "plain", "full", "full-content", "no-truncate", "chars", "max-chars", "head", "tools", "tool-output"} {
		if _, ok := params[key]; ok {
			return true
		}
	}
	return false
}

func sessionTerminalRead(ctx context.Context, c *client.Client, params map[string]any, follow bool) error {
	timeout := durationValue(params, "timeout", 8*time.Second)
	needle := stringValue(params, "contains")
	if follow {
		signalContext, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
		defer stop()
		ctx = signalContext
	} else {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.Background(), timeout)
		defer cancel()
	}
	err := c.ReadOutput(ctx, func(data []byte) bool {
		_, _ = os.Stdout.Write(data)
		return !follow && needle != "" && strings.Contains(string(data), needle)
	})
	if errors.Is(err, context.Canceled) && follow {
		return nil
	}
	if errors.Is(err, context.DeadlineExceeded) {
		if needle == "" {
			return nil
		}
		return fmt.Errorf("expected text not found before timeout: %s", needle)
	}
	return err
}

func agentReadSession(ctx context.Context, c *client.Client, session api.Session, streamID string, params map[string]any) error {
	options, err := agentReadOptions(params)
	if err != nil {
		return err
	}
	streamID = strings.TrimSpace(streamID)
	if streamID == "" {
		streamID = strings.TrimSpace(session.AgentExecutionID)
	}
	events, err := readAgentHistory(ctx, c, streamID, options)
	if err != nil {
		return err
	}
	events, err = agent.ProjectEvents(events, options)
	if err != nil {
		return err
	}
	if agentReadTextOnly(params) {
		return printAgentText(events)
	}
	return printValue(events)
}

func agentReadOptions(params map[string]any) (agent.ReadOptions, error) {
	recent := agent.DefaultReadRecent
	recentFlag := firstFlagValue(params, "recent", "limit", "count")
	if boolValue(params, "all") && recentFlag != "" {
		return agent.ReadOptions{}, newUsageError("--all cannot be combined with --recent, --limit, or --count", agentReadUsageText())
	}
	if boolValue(params, "all") {
		recent = 0
	}
	if recentFlag != "" {
		parsed, err := strconv.Atoi(recentFlag)
		if err != nil || parsed < 0 {
			return agent.ReadOptions{}, newUsageError("--recent must be a non-negative integer", agentReadUsageText())
		}
		recent = parsed
	}
	contentLimit := agent.DefaultReadContentLimit
	if value := firstFlagValue(params, "chars", "max-chars", "head"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			return agent.ReadOptions{}, newUsageError("--chars must be a non-negative integer", agentReadUsageText())
		}
		contentLimit = parsed
	}
	full := boolValue(params, "full-content") || boolValue(params, "no-truncate")
	contentFlag := firstFlagValue(params, "chars", "max-chars", "head") != ""
	if full && contentFlag {
		return agent.ReadOptions{}, newUsageError("--full-content cannot be combined with --chars, --max-chars, or --head", agentReadUsageText())
	}
	return agent.ReadOptions{
		Recent:       recent,
		ContentLimit: contentLimit,
		Full:         full,
		IncludeTypes: splitTypeFlag(stringValue(params, "include")),
		ExcludeTypes: append(splitTypeFlag(stringValue(params, "filter")), splitTypeFlag(stringValue(params, "exclude"))...),
		Tools:        boolValue(params, "tools"),
		ToolOutput:   boolValue(params, "tool-output"),
	}, nil
}

func readAgentHistory(ctx context.Context, c *client.Client, sessionID string, options agent.ReadOptions) ([]api.AgentEvent, error) {
	pageSize := 500
	var before uint64
	var pages []api.AgentEvent
	for {
		page, err := c.AgentEventsHistory(ctx, api.AgentEventsHistoryRequest{StreamID: sessionID, BeforeSequence: before, Limit: uint32(pageSize)})
		if err != nil {
			return nil, err
		}
		if len(page.Events) > 0 {
			pages = append(projectCanonicalEvents(page.Events), pages...)
		}
		if options.Recent > 0 {
			projected, projectErr := agent.ProjectEvents(pages, options)
			if projectErr != nil {
				return nil, projectErr
			}
			if len(projected) >= options.Recent || !page.HasMore || len(page.Events) == 0 {
				break
			}
		} else if !page.HasMore || len(page.Events) == 0 {
			break
		}
		before = page.Events[0].Sequence
	}
	return pages, nil
}

func agentReadTextOnly(params map[string]any) bool {
	return boolValue(params, "text") || boolValue(params, "text-only") || boolValue(params, "plain")
}

// projectCanonicalEvents is a disposable presentation projection, never a wire format.
func projectCanonicalEvents(events []api.CanonicalAgentEvent) []api.AgentEvent {
	result := make([]api.AgentEvent, 0, len(events))
	for _, event := range events {
		eventType := strings.ToLower(strings.TrimSpace(event.Type))
		payload := cloneCanonicalPayload(event.Payload)
		var value api.AgentEvent
		raw, _ := json.Marshal(payload)
		_ = json.Unmarshal(raw, &value)
		value.Sequence, value.ID, value.Timestamp = event.Sequence, event.EventID, event.OccurredAt
		value.Turn, _ = strconv.ParseUint(event.TurnID, 10, 64)
		value.Provider = strings.ToLower(strings.TrimSpace(event.Origin.Provider))
		value.CanonicalType = eventType
		value.Payload = payload
		switch eventType {
		case "message", "message.created", "message.completed":
			value.Type = canonicalMessageProjectionType(value.Role)
			value.ContentDelta = false
		case "message.delta":
			value.Type, value.ContentDelta = canonicalMessageProjectionType(value.Role), true
		case "reasoning.delta":
			value.Type = "reasoning"
		case "tool.started", "tool.updated":
			value.Type = "tool_call"
		case "tool.completed", "tool.failed":
			value.Type = "tool_output"
		case "interaction.requested", "interaction.resolved", "interaction.expired":
			value.Type = canonicalInteractionProjectionType(eventType, payload)
			value.Payload = canonicalInteractionProjectionPayload(eventType, value.Payload)
		case "plan.updated":
			value.Type = "plan"
		case "tasks.updated", "todo.updated":
			value.Type = "todo"
		case "goal.updated":
			value.Type = "goal"
		case "activity.updated":
			value.Type = "activity"
		case "plugin.updated":
			value.Type = "plugin"
		case "subagent.updated":
			value.Type = "subagent"
		case "attachment.updated":
			value.Type = "attachment"
		case "context.updated":
			value.Type = "context"
		case "diff.updated":
			value.Type = "diff"
		case "diagnostics.updated":
			value.Type = "diagnostics"
		case "config.updated":
			value.Type = "config"
		case "compaction.updated":
			value.Type = "compaction"
		case "queue.updated", "queue_operation", "queue":
			value.Type = "queue"
		default:
			value.Type = eventType
		}
		if isCanonicalMessageEventType(eventType) && strings.TrimSpace(value.Role) == "" {
			value.Role = "assistant"
		}
		value.ID = canonicalProjectionID(eventType, value.Payload, value.ID)
		result = append(result, value)
	}
	return result
}

func cloneCanonicalPayload(payload map[string]any) map[string]any {
	if payload == nil {
		return nil
	}
	clone := make(map[string]any, len(payload))
	for key, value := range payload {
		clone[key] = value
	}
	return clone
}

func isCanonicalMessageEventType(eventType string) bool {
	switch strings.ToLower(strings.TrimSpace(eventType)) {
	case "message", "message.created", "message.delta", "message.completed":
		return true
	default:
		return false
	}
}

func canonicalMessageProjectionType(role string) string {
	role = strings.ToLower(strings.TrimSpace(role))
	switch role {
	case "user", "assistant", "system":
		return role
	default:
		// Canonical message rows emitted by older providers may omit role. The
		// Web projection uses the same compatibility default so the row remains
		// visible instead of disappearing from the conversation read.
		return "assistant"
	}
}

func canonicalInteractionProjectionType(eventType string, payload map[string]any) string {
	kind, _ := payload["kind"].(string)
	kind = strings.ToLower(strings.TrimSpace(strings.ReplaceAll(kind, "-", "_")))
	switch kind {
	case "question", "permission", "confirmation":
		return kind
	case "approval":
		return "permission"
	case "confirm":
		return "confirmation"
	default:
		return eventType
	}
}

func canonicalInteractionProjectionPayload(eventType string, payload map[string]any) map[string]any {
	if payload == nil {
		payload = make(map[string]any)
	}
	state, _ := payload["state"].(string)
	if strings.TrimSpace(state) == "" {
		switch eventType {
		case "interaction.requested":
			payload["state"] = "pending"
		case "interaction.resolved":
			payload["state"] = "resolved"
		case "interaction.expired":
			payload["state"] = "expired"
		}
	}
	return payload
}

var canonicalProjectionIDFields = map[string][]string{
	"message.created":       {"messageId"},
	"message.delta":         {"messageId"},
	"message.completed":     {"messageId"},
	"message":               {"messageId"},
	"reasoning.delta":       {"messageId"},
	"tool.started":          {"callId", "toolCallId"},
	"tool.updated":          {"callId", "toolCallId"},
	"tool.completed":        {"callId", "toolCallId"},
	"tool.failed":           {"callId", "toolCallId"},
	"interaction.requested": {"interactionId", "requestId"},
	"interaction.resolved":  {"interactionId", "requestId"},
	"interaction.expired":   {"interactionId", "requestId"},
	"plan.updated":          {"planId"},
	"tasks.updated":         {"taskListId", "todoId"},
	"todo.updated":          {"todoId", "taskListId"},
	"goal.updated":          {"goalId", "threadId", "sessionId"},
	"activity.updated":      {"activityId"},
	"plugin.updated":        {"pluginId"},
	"subagent.updated":      {"subagentId"},
	"attachment.updated":    {"attachmentId"},
	"diff.updated":          {"diffId", "file"},
	"diagnostics.updated":   {"diagnosticsId", "file"},
	"config.updated":        {"configId"},
	"compaction.updated":    {"compactionId"},
	"queue.updated":         {"queueId", "itemId", "requestId"},
	"queue_operation":       {"queueId", "itemId", "requestId"},
	"queue":                 {"queueId", "itemId", "requestId"},
}

func canonicalProjectionID(eventType string, payload map[string]any, fallback string) string {
	eventType = strings.ToLower(strings.TrimSpace(strings.ReplaceAll(eventType, "-", "_")))
	for _, key := range canonicalProjectionIDFields[eventType] {
		if value, ok := canonicalProjectionIDValue(payload[key]); ok {
			return value
		}
	}
	return fallback
}

func canonicalProjectionIDValue(value any) (string, bool) {
	switch value := value.(type) {
	case string:
		value = strings.TrimSpace(value)
		return value, value != ""
	case json.Number:
		text := strings.TrimSpace(string(value))
		return text, text != ""
	case float64:
		return strconv.FormatFloat(value, 'f', -1, 64), true
	case float32:
		return strconv.FormatFloat(float64(value), 'f', -1, 32), true
	case int:
		return strconv.Itoa(value), true
	case int8:
		return strconv.FormatInt(int64(value), 10), true
	case int16:
		return strconv.FormatInt(int64(value), 10), true
	case int32:
		return strconv.FormatInt(int64(value), 10), true
	case int64:
		return strconv.FormatInt(value, 10), true
	case uint:
		return strconv.FormatUint(uint64(value), 10), true
	case uint8:
		return strconv.FormatUint(uint64(value), 10), true
	case uint16:
		return strconv.FormatUint(uint64(value), 10), true
	case uint32:
		return strconv.FormatUint(uint64(value), 10), true
	case uint64:
		return strconv.FormatUint(value, 10), true
	default:
		return "", false
	}
}

func readCanonicalTurn(ctx context.Context, c *client.Client, streamID string, turn uint64) ([]api.CanonicalAgentEvent, error) {
	var result []api.CanonicalAgentEvent
	var before uint64
	for {
		page, err := c.AgentEventsHistory(ctx, api.AgentEventsHistoryRequest{StreamID: streamID, BeforeSequence: before, Limit: 500})
		if err != nil {
			return nil, err
		}
		var matching []api.CanonicalAgentEvent
		for _, event := range page.Events {
			if event.TurnID == strconv.FormatUint(turn, 10) {
				matching = append(matching, event)
			}
		}
		result = append(matching, result...)
		if !page.HasMore || len(page.Events) == 0 {
			return result, nil
		}
		before = page.Events[0].Sequence
	}
}

func printAgentText(events []api.AgentEvent) error {
	lines := agentTextLines(events)
	if outputJSON {
		return printValue(lines)
	}
	for _, line := range lines {
		fmt.Fprintln(os.Stdout, line)
	}
	return nil
}

func agentTextLines(events []api.AgentEvent) []string {
	lines := make([]string, 0, len(events))
	// OpenCode emits mutable text-part updates as deltas with one stable part
	// ID. Keep the plain-text CLI output readable by folding those updates back
	// into one logical message; Codex and Claude retain their existing one-event
	// per-line behavior.
	positions := make(map[string]int)
	for _, event := range events {
		if event.Type != "user" && event.Type != "assistant" {
			continue
		}
		if event.Content == "" {
			continue
		}
		if event.Provider == "opencode" && event.ID != "" {
			key := event.Type + "\x00" + event.ID
			if index, ok := positions[key]; ok {
				if event.ContentDelta {
					lines[index] += event.Content
				} else {
					lines[index] = event.Content
				}
				continue
			}
			positions[key] = len(lines)
		}
		lines = append(lines, event.Content)
	}
	return lines
}
