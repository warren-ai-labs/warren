package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/acp"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// acpConfigOptionLimit and acpConfigChoiceLimit bound the configuration
	// snapshot journaled for a Session. Model lists are the long ones.
	acpConfigOptionLimit = 16
	acpConfigChoiceLimit = 500
	// acpModeConfigID names the selector synthesized from legacy modes.
	acpModeConfigID = "mode"
)

// acpConfigOption is the normalized form of one ACP config option. Grouped
// values are flattened; each value keeps its group name.
type acpConfigOption struct {
	id           string
	name         string
	description  string
	category     string
	currentValue string
	choices      []acp.ConfigOptionValue
	// viaMode marks a selector synthesized from legacy session modes; it is
	// changed with session/set_mode instead of session/set_config_option.
	viaMode bool
}

// parseACPConfig normalizes the config options and legacy modes an agent
// reports. Config options win: a legacy mode list is only surfaced when no
// config option already covers the mode category.
func parseACPConfig(raw json.RawMessage, modes *acp.ModeState) []acpConfigOption {
	var options []acp.ConfigOption
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &options)
	}
	result := make([]acpConfigOption, 0, len(options)+1)
	hasMode := false
	for _, option := range options {
		if len(result) >= acpConfigOptionLimit {
			break
		}
		id := strings.TrimSpace(option.ID)
		if id == "" || (option.Type != "" && option.Type != "select") {
			continue
		}
		var current string
		if json.Unmarshal(option.CurrentValue, &current) != nil {
			continue
		}
		var values []acp.ConfigOptionValue
		if len(option.Options) > 0 && json.Unmarshal(option.Options, &values) != nil {
			continue
		}
		choices := flattenACPConfigValues(values, "")
		if len(choices) == 0 {
			continue
		}
		if option.Category == "mode" {
			hasMode = true
		}
		result = append(result, acpConfigOption{
			id:           id,
			name:         clipACPText(strings.TrimSpace(option.Name), 200),
			description:  clipACPText(strings.TrimSpace(option.Description), 280),
			category:     option.Category,
			currentValue: current,
			choices:      choices,
		})
	}
	if !hasMode && modes != nil && len(modes.AvailableModes) > 0 && len(result) < acpConfigOptionLimit {
		choices := make([]acp.ConfigOptionValue, 0, len(modes.AvailableModes))
		for _, mode := range modes.AvailableModes {
			if strings.TrimSpace(mode.ID) == "" || len(choices) >= acpConfigChoiceLimit {
				continue
			}
			choices = append(choices, acp.ConfigOptionValue{Value: mode.ID, Name: clipACPText(mode.Name, 200), Description: clipACPText(mode.Description, 280)})
		}
		if len(choices) > 0 {
			result = append(result, acpConfigOption{id: acpModeConfigID, name: "Mode", category: "mode", currentValue: modes.CurrentModeID, choices: choices, viaMode: true})
		}
	}
	return result
}

func flattenACPConfigValues(values []acp.ConfigOptionValue, group string) []acp.ConfigOptionValue {
	result := make([]acp.ConfigOptionValue, 0, len(values))
	for _, value := range values {
		if len(value.Options) > 0 {
			name := strings.TrimSpace(value.Name)
			if name == "" {
				name = strings.TrimSpace(value.Group)
			}
			for _, nested := range flattenACPConfigValues(value.Options, name) {
				if len(result) < acpConfigChoiceLimit {
					result = append(result, nested)
				}
			}
			continue
		}
		if strings.TrimSpace(value.Value) == "" || len(result) >= acpConfigChoiceLimit {
			continue
		}
		result = append(result, acp.ConfigOptionValue{
			Value:       value.Value,
			Name:        clipACPText(strings.TrimSpace(value.Name), 200),
			Description: clipACPText(strings.TrimSpace(value.Description), 280),
			Group:       group,
		})
	}
	return result
}

// configPayload is the journaled snapshot. Every config.updated carries the
// complete set, so a client only ever needs the latest one.
func acpConfigPayload(options []acpConfigOption) map[string]any {
	items := make([]any, 0, len(options))
	for _, option := range options {
		choices := make([]any, 0, len(option.choices))
		for _, choice := range option.choices {
			item := map[string]any{"value": choice.Value, "name": choice.Name}
			if choice.Description != "" {
				item["description"] = choice.Description
			}
			if choice.Group != "" {
				item["group"] = choice.Group
			}
			choices = append(choices, item)
		}
		item := map[string]any{
			"id":           option.id,
			"name":         option.name,
			"category":     option.category,
			"currentValue": option.currentValue,
			"options":      choices,
		}
		if option.description != "" {
			item["description"] = option.description
		}
		items = append(items, item)
	}
	return map[string]any{"configId": "acp-config", "configOptions": items}
}

// replaceConfigLocked installs a new snapshot and returns the event that
// reports it, or nothing when the visible configuration did not change.
func (handle *acpAgentHandle) replaceConfigLocked(options []acpConfigOption) []api.AgentEvent {
	handle.config = options
	handle.saveHeldStateLocked()
	payload := acpConfigPayload(options)
	encoded, _ := json.Marshal(payload)
	if string(encoded) == handle.configEmitted {
		return nil
	}
	handle.configEmitted = string(encoded)
	return []api.AgentEvent{handle.stampLocked(api.AgentEvent{ID: "acp-config", Type: "config", Payload: payload})}
}

// setCurrentConfigLocked records a new current value for one selector.
func (handle *acpAgentHandle) setCurrentConfigLocked(match func(acpConfigOption) bool, value string) []api.AgentEvent {
	options := append([]acpConfigOption(nil), handle.config...)
	changed := false
	for index := range options {
		if match(options[index]) && options[index].currentValue != value {
			options[index].currentValue = value
			changed = true
		}
	}
	if !changed {
		return nil
	}
	return handle.replaceConfigLocked(options)
}

// reportConfig journals the configuration an agent returned from session
// setup or from a set call.
func (handle *acpAgentHandle) reportConfig(raw json.RawMessage, modes *acp.ModeState) {
	options := parseACPConfig(raw, modes)
	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	if handle.closed || (len(options) == 0 && len(handle.config) == 0) {
		handle.mu.Unlock()
		return
	}
	events := handle.replaceConfigLocked(options)
	handle.mu.Unlock()
	handle.emitEvents(events, api.AgentStatus{})
}

// SetConfigOption changes one session selector (RFC 0023 §6.11). The process
// is started when needed, because a Session idle since a Host restart has no
// connection and its selectors are only known once the agent answers.
func (handle *acpAgentHandle) SetConfigOption(ctx context.Context, configID, value string) error {
	configID, value = strings.TrimSpace(configID), strings.TrimSpace(value)
	if configID == "" || value == "" {
		return errors.New("configId and value are required")
	}
	conn, acpSessionID, err := handle.ensureConnected(ctx)
	if err != nil {
		return err
	}
	handle.mu.Lock()
	var option *acpConfigOption
	for index := range handle.config {
		if handle.config[index].id == configID {
			copy := handle.config[index]
			option = &copy
			break
		}
	}
	handle.mu.Unlock()
	if option == nil {
		return fmt.Errorf("agent has no setting %q", configID)
	}
	known := false
	for _, choice := range option.choices {
		if choice.Value == value {
			known = true
			break
		}
	}
	if !known {
		return fmt.Errorf("setting %q has no value %q", configID, value)
	}
	if option.viaMode {
		if err := conn.Call(ctx, acp.MethodSetMode, acp.SetModeRequest{SessionID: acpSessionID, ModeID: value}, nil); err != nil {
			return err
		}
		handle.applyCurrentConfig(func(item acpConfigOption) bool { return item.id == configID }, value)
		return nil
	}
	var response acp.SetConfigOptionResponse
	if err := conn.Call(ctx, acp.MethodSetConfigOption, acp.SetConfigOptionRequest{SessionID: acpSessionID, ConfigID: configID, Value: value}, &response); err != nil {
		return err
	}
	if len(response.ConfigOptions) > 0 {
		// A change can alter other selectors (a model narrows its effort
		// levels), so the agent's full answer replaces the snapshot.
		handle.mu.Lock()
		modes := handle.legacyModesLocked()
		handle.mu.Unlock()
		handle.reportConfig(response.ConfigOptions, modes)
		return nil
	}
	handle.applyCurrentConfig(func(item acpConfigOption) bool { return item.id == configID }, value)
	return nil
}

func (handle *acpAgentHandle) applyCurrentConfig(match func(acpConfigOption) bool, value string) {
	handle.emitMu.Lock()
	defer handle.emitMu.Unlock()
	handle.mu.Lock()
	events := handle.setCurrentConfigLocked(match, value)
	handle.mu.Unlock()
	handle.emitEvents(events, api.AgentStatus{})
}

// legacyModesLocked rebuilds the legacy mode list from a synthesized mode
// selector, so replacing config options keeps it.
func (handle *acpAgentHandle) legacyModesLocked() *acp.ModeState {
	for _, option := range handle.config {
		if !option.viaMode {
			continue
		}
		modes := &acp.ModeState{CurrentModeID: option.currentValue}
		for _, choice := range option.choices {
			modes.AvailableModes = append(modes.AvailableModes, acp.SessionMode{ID: choice.Value, Name: choice.Name, Description: choice.Description})
		}
		return modes
	}
	return nil
}

// AgentConfigHandle is implemented by handles whose agent exposes session
// selectors such as the model or the permission mode.
type AgentConfigHandle interface {
	SetConfigOption(ctx context.Context, configID, value string) error
}

var _ AgentConfigHandle = (*acpAgentHandle)(nil)

// setAgentConfig changes one agent selector for a Session.
func (s *Service) setAgentConfig(ctx context.Context, sessionID, configID, value string) error {
	if _, ok := s.Session(sessionID); !ok {
		return fmt.Errorf("session not found: %s", sessionID)
	}
	if !s.sessionSupportsCapability(sessionID, CapabilityConfig) {
		return fmt.Errorf("capability %s is not available for session %s", api.CapabilityAgentConfig, sessionID)
	}
	handle, ok := s.currentAgentHandle(sessionID).(AgentConfigHandle)
	if !ok || !nonNilInterface(handle) {
		return errors.New("agent settings are unavailable for this Session")
	}
	return handle.SetConfigOption(ctx, configID, value)
}
