package server

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// sendProviderInteractionInput routes a structured answer to the prompt
// protocol of the provider that drew it. Claude and Codex render the same
// question schema as different pickers, so one key script cannot serve both.
// `payload` is the pending interaction as the Host recorded it; Claude's
// picker needs the option counts, which a client response does not carry.
func sendProviderInteractionInput(ctx context.Context, runtime Runtime, sessionID, provider string, request api.AgentInteractionResponse, payload map[string]any) error {
	family, _ := splitAgentKey(normalizeProviderKind(provider))
	if family == "claude" {
		return sendClaudeInteractionInput(ctx, runtime, sessionID, request, payload)
	}
	if family == "codex" && isCodexPlanPrompt(request.Kind, payload) {
		return sendCodexPlanPromptInput(ctx, runtime, sessionID, request)
	}
	return sendAgentInteractionInput(ctx, runtime, sessionID, request)
}

var (
	claudeKeyDown   = []byte("\x1b[B")
	claudeKeyEnter  = []byte{'\r'}
	claudeKeyEscape = []byte{0x1b}
)

// sendClaudeInteractionInput drives Claude Code's own dialogs. Their layout,
// measured against Claude Code 2.1:
//
//   - AskUserQuestion shows one tab per question. The cursor starts on the
//     first option. A single-select row is chosen with Enter, which also moves
//     to the next tab. The row after the options is "Type something", an
//     inline text field.
//   - A multi-select question toggles a row with Enter and stays put. After
//     "Type something" comes a "Submit" row that moves to the next tab.
//   - With more than one question a review tab follows, with "Submit answers"
//     preselected. A single question submits without it.
//
// Esc cancels the dialog. Ctrl+C is not used: it is Claude's interrupt.
func sendClaudeInteractionInput(ctx context.Context, runtime Runtime, sessionID string, request api.AgentInteractionResponse, payload map[string]any) error {
	if request.Response == nil {
		return errors.New("interaction response is required")
	}
	if cancelled, _ := request.Response["cancelled"].(bool); cancelled {
		return runtime.Input(ctx, sessionID, claudeKeyEscape)
	}
	decision := strings.ToLower(strings.TrimSpace(agentStringValue(request.Response["decision"])))
	if decision == "cancel" {
		return runtime.Input(ctx, sessionID, claudeKeyEscape)
	}
	switch request.Kind {
	case "permission", "confirmation":
		// Claude's permission dialog never reaches its transcript, so the Host
		// cannot know one is on screen. An Enter sent on a guess would submit
		// whatever sits in the composer instead.
		return errors.New("agent interaction transport is unavailable for Claude permission prompts")
	case "question":
		return sendClaudeQuestionAnswers(ctx, runtime, sessionID, request.Response, payload)
	default:
		return fmt.Errorf("unsupported interaction kind %q", request.Kind)
	}
}

type claudeQuestionShape struct {
	id          string
	optionCount int
	multiple    bool
}

func claudeQuestionShapes(payload map[string]any) []claudeQuestionShape {
	raw, _ := payload["questions"].([]any)
	shapes := make([]claudeQuestionShape, 0, len(raw))
	for _, item := range raw {
		question, ok := item.(map[string]any)
		if !ok {
			continue
		}
		options, _ := question["options"].([]any)
		shapes = append(shapes, claudeQuestionShape{
			id:          strings.TrimSpace(agentStringValue(question["id"])),
			optionCount: len(options),
			multiple:    strings.EqualFold(strings.TrimSpace(agentStringValue(question["selection"])), "multiple"),
		})
	}
	return shapes
}

func sendClaudeQuestionAnswers(ctx context.Context, runtime Runtime, sessionID string, response, payload map[string]any) error {
	shapes := claudeQuestionShapes(payload)
	if len(shapes) == 0 {
		return errors.New("claude question schema is unavailable")
	}
	customAnswers, _ := response["customAnswers"].(map[string]any)
	answerIndices, _ := response["answerIndices"].(map[string]any)

	// Validate every answer before the first key: a script that stops halfway
	// leaves Claude's picker on an arbitrary tab.
	for _, shape := range shapes {
		custom := strings.TrimSpace(agentStringValue(customAnswers[shape.id]))
		indices := parseInteractionIndices(answerIndices[shape.id])
		for _, index := range indices {
			if index < 0 || index >= shape.optionCount {
				return fmt.Errorf("question %s has no option %d", shape.id, index)
			}
		}
		switch {
		case shape.multiple && custom != "":
			return fmt.Errorf("question %s: Claude's multi-select note is not supported", shape.id)
		case shape.multiple && len(indices) == 0:
			return fmt.Errorf("question %s requires at least one option", shape.id)
		case !shape.multiple && custom == "" && len(indices) != 1:
			return fmt.Errorf("question %s requires exactly one option", shape.id)
		}
	}

	for _, shape := range shapes {
		custom := strings.TrimSpace(agentStringValue(customAnswers[shape.id]))
		indices := parseInteractionIndices(answerIndices[shape.id])
		if shape.multiple {
			sort.Ints(indices)
			cursor := 0
			for _, index := range indices {
				if err := moveClaudeCursor(ctx, runtime, sessionID, index-cursor); err != nil {
					return err
				}
				cursor = index
				if err := sendClaudeKeys(ctx, runtime, sessionID, claudeKeyEnter); err != nil {
					return err
				}
			}
			// Skip "Type something" and land on "Submit".
			if err := moveClaudeCursor(ctx, runtime, sessionID, shape.optionCount+1-cursor); err != nil {
				return err
			}
		} else if custom != "" {
			if err := moveClaudeCursor(ctx, runtime, sessionID, shape.optionCount); err != nil {
				return err
			}
			if err := runtime.Input(ctx, sessionID, encodeTerminalText(custom)); err != nil {
				return err
			}
			if err := waitAgentTerminalInput(ctx); err != nil {
				return err
			}
		} else if err := moveClaudeCursor(ctx, runtime, sessionID, indices[0]); err != nil {
			return err
		}
		if err := runtime.Input(ctx, sessionID, claudeKeyEnter); err != nil {
			return err
		}
		// Let the next tab draw before its first key arrives.
		if err := waitAgentTerminalInput(ctx); err != nil {
			return err
		}
	}
	if len(shapes) > 1 {
		return runtime.Input(ctx, sessionID, claudeKeyEnter)
	}
	return nil
}

func moveClaudeCursor(ctx context.Context, runtime Runtime, sessionID string, steps int) error {
	for i := 0; i < steps; i++ {
		if err := sendClaudeKeys(ctx, runtime, sessionID, claudeKeyDown); err != nil {
			return err
		}
	}
	return nil
}

func sendClaudeKeys(ctx context.Context, runtime Runtime, sessionID string, keys ...[]byte) error {
	for _, key := range keys {
		if err := runtime.Input(ctx, sessionID, key); err != nil {
			return err
		}
		if err := waitAgentTerminalKey(ctx); err != nil {
			return err
		}
	}
	return nil
}

// agentInteractionPayload returns the payload of the newest recorded event for
// one interaction that still carries its question schema.
func (s *Service) agentInteractionPayload(sessionID, requestID, kind string) map[string]any {
	history := s.agentHistory(sessionID)
	for index := len(history) - 1; index >= 0; index-- {
		event := history[index]
		eventKind := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(event.Type), "-", "_"))
		if eventKind != kind || event.Payload == nil {
			continue
		}
		value, ok := event.Payload["requestId"].(string)
		if !ok {
			value, ok = event.Payload["request_id"].(string)
		}
		if !ok || strings.TrimSpace(value) != requestID {
			continue
		}
		if kind == "question" {
			if _, hasSchema := event.Payload["questions"]; !hasSchema {
				continue
			}
		}
		return event.Payload
	}
	return nil
}
