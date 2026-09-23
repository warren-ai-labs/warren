package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// BrowserRow is one line of `warren browser list`.
//
// It is built from the roster snapshot rather than a browser RPC so a listing
// costs no extra round trip and cannot disagree with the Session list the same
// user is looking at.
type BrowserRow struct {
	api.Session
	Phase string `json:"phase,omitempty"`
	URL   string `json:"url,omitempty"`
}

// browserRows projects the running browser Sessions out of a roster snapshot.
func browserRows(state api.State, params map[string]any) []BrowserRow {
	workspace := stringValue(params, "workspace")
	group := stringValue(params, "group")
	search := strings.ToLower(strings.TrimSpace(stringValue(params, "search")))
	rows := make([]BrowserRow, 0, len(state.Sessions))
	for _, session := range state.Sessions {
		if session.Kind != "browser" || session.Lifecycle != "running" {
			continue
		}
		if workspace != "" && session.WorkspaceID != workspace {
			continue
		}
		if group != "" && session.TerminalGroupID != group {
			continue
		}
		if search != "" && !strings.Contains(strings.ToLower(browserRowTitle(session)), search) {
			continue
		}
		rows = append(rows, BrowserRow{Session: session})
	}
	return rows
}

func browserRowTitle(session api.Session) string {
	if session.CustomTitle != "" {
		return session.CustomTitle
	}
	return session.Title
}

func browserRowCells(item BrowserRow) []string {
	owner := item.WorkspaceID
	if owner == "" {
		owner = item.TerminalGroupID
	}
	return []string{
		displayTruncated(item.ID, 36),
		displayTruncated(browserRowTitle(item.Session), 24),
		displayTruncated(owner, 36),
		displayTruncated(item.Lifecycle, 10),
		formatTime(item.CreatedAt),
	}
}

// browserViewportFromParams reads --width and --height. Zero means the runtime
// default, which is what a caller that does not care gets.
func browserViewportFromParams(params map[string]any) (api.BrowserViewport, error) {
	width, err := browserDimension(params, "width")
	if err != nil {
		return api.BrowserViewport{}, err
	}
	height, err := browserDimension(params, "height")
	if err != nil {
		return api.BrowserViewport{}, err
	}
	return api.BrowserViewport{Width: width, Height: height}, nil
}

func browserDimension(params map[string]any, key string) (int, error) {
	raw, ok := params[key]
	if !ok || raw == nil {
		return 0, nil
	}
	switch value := raw.(type) {
	case int:
		return value, nil
	case float64:
		return int(value), nil
	case string:
		if strings.TrimSpace(value) == "" {
			return 0, nil
		}
		parsed, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return 0, fmt.Errorf("--%s must be a number: %q", key, value)
		}
		return parsed, nil
	default:
		return 0, nil
	}
}

// browserActionFlags maps a CLI flag onto the api.BrowserAction field it sets.
//
// The table is the whole mapping, so a field added to the action type without a
// flag here is visible rather than a flag that silently does nothing. Every
// entry separates conversion from application: convert turns whatever parseFlags
// produced into the type the field wants, and apply stores it. That split is
// what lets the assertion in apply be unchecked — parseFlags hands a value-taking
// flag a string even when the caller wrote `--timeout 5000`, and a flag the
// caller wrote as `--clear=true` arrives as the string "true".
var browserActionFlags = []struct {
	flag    string
	convert func(any) (any, error)
	apply   func(action *api.BrowserAction, value any)
}{
	{"url", browserStringValue, func(action *api.BrowserAction, value any) { action.URL = value.(string) }},
	{"wait-until", browserStringValue, func(action *api.BrowserAction, value any) { action.WaitUntil = value.(string) }},
	{"selector", browserStringValue, func(action *api.BrowserAction, value any) { action.Selector = value.(string) }},
	{"text", browserStringValue, func(action *api.BrowserAction, value any) { action.Text = value.(string) }},
	{"value", browserStringValue, func(action *api.BrowserAction, value any) { action.Value = value.(string) }},
	{"values", browserStringSliceValue, func(action *api.BrowserAction, value any) { action.Values = value.([]string) }},
	{"clear", browserBoolValue, func(action *api.BrowserAction, value any) { action.ClearFirst = value.(bool) }},
	{"delay", browserIntValue, func(action *api.BrowserAction, value any) { action.DelayMs = value.(int) }},
	{"hard", browserBoolValue, func(action *api.BrowserAction, value any) { action.Hard = value.(bool) }},
	{"full-page", browserBoolValue, func(action *api.BrowserAction, value any) { action.FullPage = value.(bool) }},
	{"format", browserStringValue, func(action *api.BrowserAction, value any) { action.Format = value.(string) }},
	{"quality", browserIntValue, func(action *api.BrowserAction, value any) { action.Quality = value.(int) }},
	{"path", browserStringValue, func(action *api.BrowserAction, value any) { action.Path = value.(string) }},
	{"interactive", browserBoolValue, func(action *api.BrowserAction, value any) { action.InteractiveOnly = value.(bool) }},
	{"max-nodes", browserIntValue, func(action *api.BrowserAction, value any) { action.MaxNodes = value.(int) }},
	{"timeout", browserIntValue, func(action *api.BrowserAction, value any) { action.TimeoutMs = value.(int) }},
	{"state", browserStringValue, func(action *api.BrowserAction, value any) { action.State = value.(string) }},
	{"level", browserStringValue, func(action *api.BrowserAction, value any) { action.Level = value.(string) }},
	{"limit", browserIntValue, func(action *api.BrowserAction, value any) { action.Limit = value.(int) }},
	{"dx", browserIntValue, func(action *api.BrowserAction, value any) { action.DX = value.(int) }},
	{"dy", browserIntValue, func(action *api.BrowserAction, value any) { action.DY = value.(int) }},
	{"tab", browserStringValue, func(action *api.BrowserAction, value any) { action.TabID = value.(string) }},
	{"width", browserIntValue, func(action *api.BrowserAction, value any) { action.Width = value.(int) }},
	{"height", browserIntValue, func(action *api.BrowserAction, value any) { action.Height = value.(int) }},
	{"expression", browserStringValue, func(action *api.BrowserAction, value any) { action.Expression = value.(string) }},
}

func browserStringValue(raw any) (any, error) {
	switch value := raw.(type) {
	case string:
		if strings.TrimSpace(value) == "" {
			return nil, errors.New("requires a value")
		}
		return value, nil
	case int:
		return strconv.Itoa(value), nil
	case float64:
		return strconv.FormatInt(int64(value), 10), nil
	default:
		return nil, fmt.Errorf("requires a string, got %T", raw)
	}
}

func browserIntValue(raw any) (any, error) {
	switch value := raw.(type) {
	case int:
		return value, nil
	case float64:
		return int(value), nil
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return nil, fmt.Errorf("must be a number, got %q", value)
		}
		return parsed, nil
	default:
		return nil, fmt.Errorf("must be a number, got %T", raw)
	}
}

func browserBoolValue(raw any) (any, error) {
	switch value := raw.(type) {
	case bool:
		return value, nil
	case string:
		parsed, err := strconv.ParseBool(strings.TrimSpace(value))
		if err != nil {
			return nil, fmt.Errorf("must be true or false, got %q", value)
		}
		return parsed, nil
	case int:
		return value != 0, nil
	case float64:
		return value != 0, nil
	default:
		return nil, fmt.Errorf("must be true or false, got %T", raw)
	}
}

func browserStringSliceValue(raw any) (any, error) {
	switch value := raw.(type) {
	case string:
		parts := splitCommaList(value)
		if len(parts) == 0 {
			return nil, errors.New("requires at least one value")
		}
		return parts, nil
	case []string:
		if len(value) == 0 {
			return nil, errors.New("requires at least one value")
		}
		return value, nil
	default:
		return nil, fmt.Errorf("requires a comma-separated list, got %T", raw)
	}
}

func splitCommaList(value string) []string {
	parts := strings.Split(value, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			values = append(values, trimmed)
		}
	}
	return values
}

// browserActionParams builds the browser.action request from one command line.
//
// The action name is a positional rather than a flag because it is the one part
// of an action that is never optional, and a positional reads the way the
// sentence does: "browser action SESSION navigate --url ...".
func browserActionParams(params map[string]any) (map[string]any, error) {
	request := map[string]any{"id": positional(params, 0, "")}
	action := ""
	if positions := positionals(params); len(positions) > 1 {
		action = positions[1]
	}
	actionValue := api.BrowserAction{Action: action}
	for _, mapping := range browserActionFlags {
		raw, ok := params[mapping.flag]
		if !ok || raw == nil {
			continue
		}
		converted, err := mapping.convert(raw)
		if err != nil {
			return nil, fmt.Errorf("--%s %w", mapping.flag, err)
		}
		mapping.apply(&actionValue, converted)
	}
	request["action"] = actionValue
	return request, nil
}
