package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

type canonicalInteractionProjection struct {
	kind      string
	version   uint64
	state     string
	optionIDs map[string]struct{}
}

func canonicalEntryHasTerminalInteraction(entry *agentSession, interactionID string) bool {
	if entry == nil || strings.TrimSpace(interactionID) == "" {
		return false
	}
	for _, event := range entry.canonicalEvents {
		if event.Type != "interaction.resolved" && event.Type != "interaction.expired" {
			continue
		}
		if canonicalInteractionEventMatchesID(event, interactionID) {
			return true
		}
	}
	return false
}

func canonicalInteractionEventID(event api.AgentEvent) string {
	if event.Payload != nil {
		for _, key := range []string{"interactionId", "requestId"} {
			if value, ok := event.Payload[key].(string); ok && strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
	}
	return strings.TrimSpace(event.ID)
}

func canonicalInteractionCanonicalID(event api.CanonicalAgentEvent) string {
	if event.Payload != nil {
		for _, key := range []string{"interactionId", "requestId"} {
			if value, ok := event.Payload[key].(string); ok && strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
	}
	return strings.TrimSpace(event.EventID)
}

func canonicalInteractionIdentityValues(event api.CanonicalAgentEvent) []string {
	values := make([]string, 0, 2)
	if event.Payload != nil {
		for _, key := range []string{"interactionId", "requestId"} {
			value, ok := event.Payload[key].(string)
			value = strings.TrimSpace(value)
			if !ok || value == "" {
				continue
			}
			seen := false
			for _, prior := range values {
				if prior == value {
					seen = true
					break
				}
			}
			if !seen {
				values = append(values, value)
			}
		}
	}
	if len(values) == 0 {
		if eventID := strings.TrimSpace(event.EventID); eventID != "" {
			values = append(values, eventID)
		}
	}
	return values
}

func canonicalInteractionEventMatchesID(event api.CanonicalAgentEvent, interactionID string) bool {
	interactionID = strings.TrimSpace(interactionID)
	if interactionID == "" {
		return false
	}
	for _, value := range canonicalInteractionIdentityValues(event) {
		if value == interactionID {
			return true
		}
	}
	return false
}

func canonicalInteractionEventsMatch(left, right api.CanonicalAgentEvent) bool {
	leftValues := canonicalInteractionIdentityValues(left)
	rightValues := canonicalInteractionIdentityValues(right)
	for _, leftValue := range leftValues {
		for _, rightValue := range rightValues {
			if leftValue == rightValue {
				return true
			}
		}
	}
	return false
}

// mergeCanonicalInteractionContext keeps the request schema attached to a
// terminal lifecycle row. Providers commonly emit only requestId/state in the
// tool result; dropping the original questions/options makes an Answered card
// impossible to inspect after replay.
func mergeCanonicalInteractionContext(history []api.CanonicalAgentEvent, event *api.CanonicalAgentEvent) {
	if event == nil || event.Payload == nil || event.Type == "interaction.requested" {
		return
	}
	if canonicalInteractionCanonicalID(*event) == "" {
		return
	}
	for index := len(history) - 1; index >= 0; index-- {
		candidate := history[index]
		if candidate.Type != "interaction.requested" || !canonicalInteractionEventsMatch(candidate, *event) {
			continue
		}
		if candidate.Payload == nil {
			return
		}
		for _, key := range []string{"interactionId", "requestId", "kind", "title", "description", "schema", "options", "questions", "version", "turnId"} {
			if _, exists := event.Payload[key]; exists {
				continue
			}
			if value, exists := candidate.Payload[key]; exists {
				event.Payload[key] = value
			}
		}
		return
	}
}

// canonicalInteraction resolves the provider-neutral interaction projection
// from immutable events. The wire command carries only interactionId and
// version; accepting a guessed kind or an old version would let a client
// answer a different interaction than the one shown by the Host.
func (s *Service) canonicalInteraction(sessionID, interactionID string) (canonicalInteractionProjection, bool) {
	interactionID = strings.TrimSpace(interactionID)
	if interactionID == "" {
		return canonicalInteractionProjection{}, false
	}
	execution, ok := s.canonicalExecutionForSession(sessionID)
	if !ok || execution.StreamID == "" {
		return canonicalInteractionProjection{}, false
	}
	result, err := s.canonicalHistoryPage(context.Background(), execution.StreamID, 0, 0, agentHistoryMaxLimit)
	if err != nil {
		return canonicalInteractionProjection{}, false
	}
	var projection canonicalInteractionProjection
	for _, event := range result.Events {
		if event.Type != "interaction.requested" && event.Type != "interaction.resolved" && event.Type != "interaction.expired" {
			continue
		}
		if !canonicalInteractionEventMatchesID(event, interactionID) {
			continue
		}
		if kind, _ := event.Payload["kind"].(string); kind != "" {
			kind = strings.ToLower(strings.TrimSpace(kind))
			if kind == "question" || kind == "permission" || kind == "confirmation" {
				projection.kind = kind
			}
		}
		if event.Type == "interaction.requested" {
			if projection.optionIDs == nil {
				projection.optionIDs = make(map[string]struct{})
			}
			collectCanonicalInteractionOptionIDs(event.Payload["options"], projection.optionIDs, 0)
			collectCanonicalInteractionOptionIDs(event.Payload["schema"], projection.optionIDs, 0)
			collectCanonicalQuestionOptionIDs(event.Payload["questions"], projection.optionIDs, 0)
		}
		if version := canonicalInteractionVersion(event.Payload["version"]); version > 0 {
			projection.version = version
		} else if projection.version == 0 {
			projection.version = 1
		}
		state, _ := event.Payload["state"].(string)
		state = strings.ToLower(strings.TrimSpace(strings.ReplaceAll(state, "-", "_")))
		switch event.Type {
		case "interaction.requested":
			if state == "" {
				state = "pending"
			}
		case "interaction.resolved":
			// The lifecycle type is authoritative even when a provider uses
			// answered/accepted/completed in its payload.
			state = "resolved"
		case "interaction.expired":
			state = "expired"
		}
		if state != "" {
			projection.state = state
		}
	}
	return projection, projection.kind != ""
}

const (
	canonicalInteractionMaxFields = 32
	canonicalInteractionMaxDepth  = 4
	canonicalInteractionMaxText   = 16 * 1024
)

// collectCanonicalInteractionOptionIDs extracts only bounded option-like
// values from a provider schema. It is deliberately not a general JSON Schema
// evaluator: the Host validates the response shape and option identity while
// leaving provider-specific presentation fields opaque.
func collectCanonicalInteractionOptionIDs(value any, ids map[string]struct{}, depth int) {
	if depth > canonicalInteractionMaxDepth || len(ids) >= 128 {
		return
	}
	switch value := value.(type) {
	case []any:
		for _, item := range value {
			collectCanonicalInteractionOptionIDs(item, ids, depth+1)
			if len(ids) >= 128 {
				return
			}
		}
	case map[string]any:
		for key, item := range value {
			switch strings.ToLower(strings.TrimSpace(key)) {
			case "id", "value":
				if text, ok := item.(string); ok {
					text = strings.TrimSpace(text)
					if text != "" && len(text) <= 1024 {
						ids[text] = struct{}{}
					}
				}
			case "options", "enum", "items", "properties":
				collectCanonicalInteractionOptionIDs(item, ids, depth+1)
			}
			if len(ids) >= 128 {
				return
			}
		}
	}
}

// Question payloads keep their selectable values one level below a
// `questions` array. Do not feed the whole object into the generic collector:
// a question's own `id` is not an answer option and must not become accepted
// merely because it happens to use the same field name.
func collectCanonicalQuestionOptionIDs(value any, ids map[string]struct{}, depth int) {
	if depth > canonicalInteractionMaxDepth || len(ids) >= 128 {
		return
	}
	switch value := value.(type) {
	case []any:
		for _, item := range value {
			collectCanonicalQuestionOptionIDs(item, ids, depth+1)
			if len(ids) >= 128 {
				return
			}
		}
	case map[string]any:
		for key, item := range value {
			switch strings.ToLower(strings.TrimSpace(key)) {
			case "options", "enum":
				collectCanonicalInteractionOptionIDs(item, ids, depth+1)
			case "questions", "schema", "items":
				collectCanonicalQuestionOptionIDs(item, ids, depth+1)
			}
			if len(ids) >= 128 {
				return
			}
		}
	}
}

func validateCanonicalInteractionResolution(projection canonicalInteractionProjection, resolution map[string]any) error {
	if len(resolution) == 0 {
		return errors.New("interaction resolution must not be empty")
	}
	if len(resolution) > canonicalInteractionMaxFields {
		return fmt.Errorf("interaction resolution has too many fields (max %d)", canonicalInteractionMaxFields)
	}
	if cancelled, present := resolution["cancelled"]; present {
		value, ok := cancelled.(bool)
		if !ok {
			return errors.New("interaction resolution cancelled must be a boolean")
		}
		if value {
			return nil
		}
	}
	for _, key := range []string{"decision", "value", "text"} {
		if raw, present := resolution[key]; present {
			text, ok := raw.(string)
			if !ok || strings.TrimSpace(text) == "" {
				return fmt.Errorf("interaction resolution %s must be a non-empty string", key)
			}
			if len(text) > canonicalInteractionMaxText {
				return fmt.Errorf("interaction resolution %s is too large", key)
			}
		}
	}
	if projection.kind == "permission" || projection.kind == "confirmation" {
		choice := strings.TrimSpace(agentStringValue(resolution["decision"]))
		if choice == "" {
			choice = strings.TrimSpace(agentStringValue(resolution["value"]))
		}
		if choice == "" {
			return fmt.Errorf("%s resolution requires decision or value", projection.kind)
		}
		if len(projection.optionIDs) > 0 {
			if _, ok := projection.optionIDs[choice]; !ok {
				return fmt.Errorf("%s resolution selects an unknown option", projection.kind)
			}
		}
		return nil
	}
	if projection.kind != "question" {
		return fmt.Errorf("unsupported interaction kind %q", projection.kind)
	}
	for _, key := range []string{"answers", "customAnswers"} {
		if raw, present := resolution[key]; present {
			values, ok := raw.(map[string]any)
			if !ok || len(values) == 0 || len(values) > canonicalInteractionMaxFields {
				return fmt.Errorf("interaction resolution %s must be a bounded object", key)
			}
			for _, value := range values {
				if err := validateCanonicalInteractionAnswer(value, key == "answers", projection.optionIDs, 0); err != nil {
					return err
				}
			}
		}
	}
	if text := strings.TrimSpace(agentStringValue(resolution["text"])); text != "" {
		return nil
	}
	if _, answers := resolution["answers"]; !answers {
		if _, custom := resolution["customAnswers"]; !custom {
			return errors.New("question resolution requires answers, customAnswers, text, or cancelled")
		}
	}
	return nil
}

func validateCanonicalInteractionAnswer(value any, optionValue bool, optionIDs map[string]struct{}, depth int) error {
	if depth > 3 {
		return errors.New("interaction answer is too deeply nested")
	}
	switch value := value.(type) {
	case string:
		text := strings.TrimSpace(value)
		if text == "" || len(text) > canonicalInteractionMaxText {
			return errors.New("interaction answer must be a bounded non-empty string")
		}
		if optionValue && len(optionIDs) > 0 {
			if _, ok := optionIDs[text]; !ok {
				return errors.New("interaction answer selects an unknown option")
			}
		}
		return nil
	case []any:
		if len(value) == 0 || len(value) > canonicalInteractionMaxFields {
			return errors.New("interaction answer list must be bounded and non-empty")
		}
		for _, item := range value {
			if err := validateCanonicalInteractionAnswer(item, optionValue, optionIDs, depth+1); err != nil {
				return err
			}
		}
		return nil
	case map[string]any:
		if len(value) == 0 || len(value) > canonicalInteractionMaxFields {
			return errors.New("interaction answer object must be bounded and non-empty")
		}
		for _, item := range value {
			if err := validateCanonicalInteractionAnswer(item, false, nil, depth+1); err != nil {
				return err
			}
		}
		return nil
	default:
		return errors.New("interaction answer contains an unsupported value")
	}
}

func canonicalInteractionVersion(value any) uint64 {
	switch value := value.(type) {
	case uint64:
		return value
	case uint32:
		return uint64(value)
	case uint:
		return uint64(value)
	case int:
		if value > 0 {
			return uint64(value)
		}
	case int64:
		if value > 0 {
			return uint64(value)
		}
	case float64:
		if value > 0 && value == float64(uint64(value)) {
			return uint64(value)
		}
	case json.Number:
		if parsed, err := strconv.ParseUint(string(value), 10, 64); err == nil {
			return parsed
		}
	case string:
		if parsed, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64); err == nil {
			return parsed
		}
	}
	return 0
}
