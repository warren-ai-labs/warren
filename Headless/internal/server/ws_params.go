package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
)

// paneNodeParam decodes the PaneNode tree of a pane-group request through JSON
// so a WebSocket client and the Go client share one wire shape, exactly as
// decodeAgentParams does for structured Agent parameters.
func paneNodeParam(values map[string]any) (api.PaneNode, error) {
	raw, present := values["tree"]
	if !present || raw == nil {
		return api.PaneNode{}, errors.New("pane group tree is required")
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return api.PaneNode{}, fmt.Errorf("invalid request parameters: %w", err)
	}
	var tree api.PaneNode
	if err := json.Unmarshal(data, &tree); err != nil {
		return api.PaneNode{}, fmt.Errorf("invalid pane tree: %w", err)
	}
	return tree, nil
}

func stringParam(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return strings.TrimSpace(value)
}

// decodeAgentParams deliberately goes through JSON so requests received from
// WebSocket clients and requests assembled by the Go client share one wire
// shape. It also keeps the legacy string-valued parameter helpers untouched.
func decodeAgentParams[T any](values map[string]any) (T, error) {
	var result T
	data, err := json.Marshal(values)
	if err != nil {
		return result, fmt.Errorf("invalid request parameters: %w", err)
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return result, fmt.Errorf("invalid request parameters: %w", err)
	}
	return result, nil
}

func decodeCanonicalCommand(values map[string]any) (api.AgentCommand, error) {
	command, err := decodeAgentParams[api.AgentCommand](values)
	if err != nil {
		return command, err
	}
	command.CommandID = strings.TrimSpace(command.CommandID)
	command.ExecutionID = strings.TrimSpace(command.ExecutionID)
	command.LeaseID = strings.TrimSpace(command.LeaseID)
	if command.CommandID == "" || command.ExecutionID == "" {
		return command, errors.New("commandId and executionId are required")
	}
	return command, nil
}

func sessionMoveExpectations(values map[string]any) SessionMoveExpectations {
	var result SessionMoveExpectations
	if value, ok := firstParam(values, "expectedWorkspace", "expectedWorkspaceId", "expected-workspace"); ok {
		parsed := strings.TrimSpace(fmt.Sprint(value))
		result.WorkspaceID = &parsed
	}
	if value, ok := firstParam(values, "expectedAgentSession", "expectedAgentSessionId", "expected-agent-session"); ok {
		parsed := strings.TrimSpace(fmt.Sprint(value))
		result.AgentSessionID = &parsed
	}
	return result
}

func firstParam(values map[string]any, keys ...string) (any, bool) {
	for _, key := range keys {
		if value, ok := values[key]; ok {
			return value, true
		}
	}
	return nil, false
}

func stringMapParam(values map[string]any, key string) map[string]string {
	raw, ok := values[key].(map[string]any)
	if !ok {
		return nil
	}
	result := make(map[string]string, len(raw))
	for entryKey, entry := range raw {
		value, ok := entry.(string)
		if !ok {
			continue
		}
		result[entryKey] = value
	}
	return result
}

func stringSliceParam(values map[string]any, key string) []string {
	raw, ok := values[key]
	if !ok {
		return nil
	}
	switch value := raw.(type) {
	case []any:
		result := make([]string, 0, len(value))
		for _, entry := range value {
			if item, ok := entry.(string); ok {
				result = append(result, item)
			}
		}
		return result
	case []string:
		return append([]string(nil), value...)
	case string:
		var result []string
		if json.Unmarshal([]byte(value), &result) == nil {
			return result
		}
	}
	return nil
}

func boolParam(values map[string]any, key string) bool {
	switch value := values[key].(type) {
	case bool:
		return value
	case string:
		parsed, err := strconv.ParseBool(value)
		return err == nil && parsed
	default:
		return false
	}
}

func optionalBoolParam(values map[string]any, key string) (value, specified bool, err error) {
	raw, specified := values[key]
	if !specified {
		return false, false, nil
	}
	switch value := raw.(type) {
	case bool:
		return value, true, nil
	case string:
		parsed, parseErr := strconv.ParseBool(strings.TrimSpace(value))
		if parseErr != nil {
			return false, true, fmt.Errorf("invalid boolean parameter %q", key)
		}
		return parsed, true, nil
	default:
		return false, true, fmt.Errorf("invalid boolean parameter %q", key)
	}
}

func intParam(values map[string]any, key string) int {
	switch value := values[key].(type) {
	case int:
		return value
	case int64:
		return int(value)
	case uint64:
		return int(value)
	case float64:
		return int(value)
	case string:
		result, _ := strconv.Atoi(value)
		return result
	}
	return 0
}

func anchorFromParams(values map[string]any) *output.Anchor {
	epoch, hasEpoch := uint64Param(values, "epoch")
	sequence, hasSequence := uint64Param(values, "sequence")
	if !hasEpoch || !hasSequence {
		return nil
	}
	return &output.Anchor{Epoch: epoch, Sequence: sequence}
}

func uint64Param(values map[string]any, key string) (uint64, bool) {
	switch value := values[key].(type) {
	case int:
		return uint64(value), true
	case int64:
		return uint64(value), true
	case uint64:
		return value, true
	case float64:
		return uint64(value), true
	case string:
		parsed, err := strconv.ParseUint(value, 10, 64)
		return parsed, err == nil
	default:
		return 0, false
	}
}

func attachSizeFromParams(values map[string]any) (columns, rows int, specified bool, err error) {
	_, hasColumns := values["cols"]
	_, hasRows := values["rows"]
	if !hasColumns && !hasRows {
		return 0, 0, false, nil
	}
	columns = intParam(values, "cols")
	rows = intParam(values, "rows")
	if columns <= 0 || rows <= 0 {
		return 0, 0, false, fmt.Errorf("invalid terminal size")
	}
	return columns, rows, true, nil
}
