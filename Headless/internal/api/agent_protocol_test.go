package api

import (
	"encoding/json"
	"testing"
	"time"
)

func TestCanonicalAgentEventFromObservation(t *testing.T) {
	recorded := time.Date(2026, 9, 5, 10, 0, 1, 0, time.UTC)
	occurred := recorded.Add(-time.Second)
	event := AgentEvent{
		Sequence:     7,
		Turn:         2,
		ID:           "message-1",
		Provider:     "claude",
		Type:         "assistant",
		Role:         "assistant",
		Content:      "hello",
		Timestamp:    occurred,
		ContentDelta: true,
		Payload:      map[string]any{"messageId": "message-1"},
	}

	canonical := CanonicalAgentEventFromObservation(event, "exec-1", "exec-1", 0, recorded)
	if canonical.EventID != "message-1" || canonical.StreamID != "exec-1" || canonical.ExecutionID != "exec-1" {
		t.Fatalf("identity = %#v", canonical)
	}
	if canonical.Sequence != 7 || canonical.TurnID != "2" || canonical.Type != "message.delta" {
		t.Fatalf("position/type = %#v", canonical)
	}
	if !canonical.OccurredAt.Equal(occurred) || !canonical.RecordedAt.Equal(recorded) {
		t.Fatalf("timestamps = %#v", canonical)
	}
	if canonical.Payload["content"] != "hello" || canonical.Payload["messageId"] != "message-1" {
		t.Fatalf("payload = %#v", canonical.Payload)
	}
}

func TestCanonicalInteractionLifecycleUsesProviderState(t *testing.T) {
	tests := []struct {
		name      string
		eventType string
		state     string
		want      string
	}{
		{name: "question pending", eventType: "question", state: "pending", want: "interaction.requested"},
		{name: "question resolved", eventType: "question", state: "resolved", want: "interaction.resolved"},
		{name: "permission answered", eventType: "permission", state: "answered", want: "interaction.resolved"},
		{name: "confirmation cancelled", eventType: "confirmation", state: "cancelled", want: "interaction.expired"},
		{name: "canonical resolved", eventType: "interaction.resolved", state: "resolved", want: "interaction.resolved"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := CanonicalAgentEventFromObservation(AgentEvent{
				ID:       "interaction-1",
				Provider: "codex",
				Type:     tt.eventType,
				Payload: map[string]any{
					"requestId": "interaction-1",
					"state":     tt.state,
				},
			}, "exec-1", "exec-1", 1, time.Now().UTC())
			if event.Type != tt.want {
				t.Fatalf("canonical type = %q, want %q", event.Type, tt.want)
			}
			if tt.eventType != "interaction.resolved" && event.Payload["kind"] == nil {
				t.Fatalf("interaction kind was not retained: %#v", event.Payload)
			}
		})
	}
}

func TestCanonicalInteractionLifecycleInfersResolutionFromResponse(t *testing.T) {
	tests := []struct {
		name     string
		response map[string]any
		want     string
	}{
		{name: "answers", response: map[string]any{"answers": map[string]any{"q1": []any{"yes"}}}, want: "interaction.resolved"},
		{name: "decision", response: map[string]any{"decision": "allow"}, want: "interaction.resolved"},
		{name: "empty answers remain pending", response: map[string]any{"answers": map[string]any{}}, want: "interaction.requested"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := CanonicalAgentEventFromObservation(AgentEvent{
				ID:       "interaction-response-1",
				Provider: "codex",
				Type:     "question",
				Payload: map[string]any{
					"requestId": "interaction-response-1",
					"response":  tt.response,
				},
			}, "exec-1", "exec-1", 1, time.Now().UTC())
			if event.Type != tt.want {
				t.Fatalf("canonical type = %q, want %q", event.Type, tt.want)
			}
		})
	}
}

func TestCanonicalInteractionStateHonorsPendingRequestFields(t *testing.T) {
	tests := []struct {
		name    string
		payload map[string]any
		want    string
	}{
		{
			name: "pending value is not an answer",
			payload: map[string]any{
				"requestId": "request-1",
				"state":     "pending",
				"value":     "visible prompt metadata",
			},
			want: "interaction.requested",
		},
		{
			name: "schema wins over flattened answer",
			payload: map[string]any{
				"requestId": "request-2",
				"questions": []any{map[string]any{"prompt": "Choose", "options": []any{"yes"}}},
				"answer":    "yes",
			},
			want: "interaction.requested",
		},
		{
			name: "answer order alone is not a response",
			payload: map[string]any{
				"requestId":   "request-ordered",
				"answerOrder": []string{"q0"},
			},
			want: "interaction.requested",
		},
		{
			name: "flattened decision resolves schema-less result",
			payload: map[string]any{
				"requestId": "request-3",
				"decision":  "allow",
			},
			want: "interaction.resolved",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := CanonicalAgentEventFromObservation(AgentEvent{
				ID:       "interaction-state-1",
				Provider: "codex",
				Type:     "question",
				Payload:  tt.payload,
			}, "exec-1", "exec-1", 1, time.Now().UTC())
			if event.Type != tt.want {
				t.Fatalf("canonical type = %q, want %q", event.Type, tt.want)
			}
		})
	}
}

func TestCanonicalAgentEventPreservesDottedCanonicalTypes(t *testing.T) {
	tests := []struct {
		name     string
		typeName string
		want     string
	}{
		{name: "message", typeName: "message.created", want: "message.created"},
		{name: "goal", typeName: "goal.updated", want: "goal.updated"},
		{name: "unknown", typeName: "provider.custom", want: "provider.custom"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := CanonicalAgentEventFromObservation(AgentEvent{
				ID:       "dotted-1",
				Provider: "codex",
				Type:     tt.typeName,
			}, "exec-1", "exec-1", 1, time.Now().UTC())
			if event.Type != tt.want {
				t.Fatalf("canonical type = %q, want %q", event.Type, tt.want)
			}
		})
	}
}

func TestAgentGoalSetCommandCarriesReplaceExistingMode(t *testing.T) {
	encoded, err := json.Marshal(AgentGoalSetCommand{
		AgentCommand:    AgentCommand{CommandID: "command-1", ExecutionID: "execution-1"},
		Objective:       "Update the mobile goal",
		ReplaceExisting: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded AgentGoalSetCommand
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if !decoded.ReplaceExisting || decoded.Objective != "Update the mobile goal" {
		t.Fatalf("decoded goal command = %#v", decoded)
	}
}

func TestCanonicalAgentEventGeneratesStableIdentity(t *testing.T) {
	event := CanonicalAgentEventFromObservation(AgentEvent{Type: "tool_call"}, "exec-1", "exec-1", 9, time.Time{})
	if event.EventID != "exec-1:9" || event.Sequence != 9 || event.Type != "tool.started" {
		t.Fatalf("event = %#v", event)
	}
	if event.Payload["toolKind"] != "tool" {
		t.Fatalf("tool event should carry a fallback tool kind: %#v", event.Payload)
	}
	if event.OccurredAt.IsZero() || event.RecordedAt.IsZero() {
		t.Fatal("canonical timestamps must be populated")
	}
}

func TestCanonicalAgentEventDoesNotAddToolSemanticsToMessages(t *testing.T) {
	event := CanonicalAgentEventFromObservation(AgentEvent{
		Type:      "assistant",
		Content:   "done",
		ToolInput: map[string]any{"command": "echo should-not-be-a-tool"},
		ToolName:  "shell",
	}, "exec-1", "exec-1", 1, time.Time{})
	if _, ok := event.Payload["toolKind"]; ok {
		t.Fatalf("message unexpectedly contains toolKind: %#v", event.Payload)
	}
	if _, ok := event.Payload["toolDetail"]; ok {
		t.Fatalf("message unexpectedly contains toolDetail: %#v", event.Payload)
	}
}

func TestCanonicalAgentEventInfersConversationRoleFromLegacyType(t *testing.T) {
	tests := []struct {
		name     string
		typeName string
		wantRole string
	}{
		{name: "user", typeName: "user", wantRole: "user"},
		{name: "assistant", typeName: "assistant", wantRole: "assistant"},
		{name: "system", typeName: "system", wantRole: "system"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := CanonicalAgentEventFromObservation(
				AgentEvent{Type: tt.typeName, Content: "message"},
				"exec-1",
				"exec-1",
				1,
				time.Time{},
			)
			if got := event.Payload["role"]; got != tt.wantRole {
				t.Fatalf("role = %#v, want %q; payload = %#v", got, tt.wantRole, event.Payload)
			}
		})
	}
}

func TestCanonicalAgentEventUsesRoleForGenericMessageType(t *testing.T) {
	event := CanonicalAgentEventFromObservation(
		AgentEvent{Type: "message", Role: "user", Content: "prompt"},
		"exec-1",
		"exec-1",
		1,
		time.Time{},
	)
	if event.Type != "message.created" {
		t.Fatalf("type = %q, want message.created", event.Type)
	}
	if event.Payload["role"] != "user" {
		t.Fatalf("role = %#v, want user", event.Payload["role"])
	}
}

func TestCanonicalAgentEventAddsInteractionDiscriminatorForLegacyRows(t *testing.T) {
	tests := []struct {
		name     string
		typeName string
		wantKind string
	}{
		{name: "question", typeName: "question", wantKind: "question"},
		{name: "permission", typeName: "permission", wantKind: "permission"},
		{name: "confirmation", typeName: "confirmation", wantKind: "confirmation"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := CanonicalAgentEventFromObservation(
				AgentEvent{Type: tt.typeName, ID: "interaction-1", Payload: map[string]any{"requestId": "interaction-1"}},
				"exec-1",
				"exec-1",
				1,
				time.Time{},
			)
			if event.Type != "interaction.requested" || event.Payload["kind"] != tt.wantKind {
				t.Fatalf("canonical interaction = %#v, want %q", event, tt.wantKind)
			}
		})
	}
}

func TestCanonicalAgentEventRolePrefersExplicitLegacyRole(t *testing.T) {
	event := CanonicalAgentEventFromObservation(
		AgentEvent{
			Type:    "user",
			Role:    "assistant",
			Payload: map[string]any{"role": "system"},
		},
		"exec-1",
		"exec-1",
		1,
		time.Time{},
	)
	if got := event.Payload["role"]; got != "assistant" {
		t.Fatalf("role = %#v, want explicit legacy role", got)
	}
}

func TestStableAgentEventIDIncludesCanonicalPayloadFields(t *testing.T) {
	base := AgentEvent{
		Provider: "opencode",
		Type:     "tool_call",
		ID:       "part-1",
	}
	variants := []struct {
		name  string
		apply func(*AgentEvent)
	}{
		{name: "model", apply: func(event *AgentEvent) { event.Model = "gpt-5" }},
		{name: "stop reason", apply: func(event *AgentEvent) { event.StopReason = "stop" }},
		{name: "tool input", apply: func(event *AgentEvent) { event.ToolInput = map[string]any{"command": "pwd"} }},
		{name: "tool status", apply: func(event *AgentEvent) { event.ToolStatus = "completed" }},
		{name: "files", apply: func(event *AgentEvent) { event.Files = []string{"README.md"} }},
		{name: "usage", apply: func(event *AgentEvent) { event.Usage = &AgentUsage{OutputTokens: 7} }},
		{name: "duration", apply: func(event *AgentEvent) { event.DurationMs = 42 }},
		{name: "sidechain", apply: func(event *AgentEvent) { event.Sidechain = true }},
	}

	baseID := StableAgentEventID(base)
	if baseID != StableAgentEventID(base) {
		t.Fatal("stable event identity changed for the same observation")
	}
	for _, variant := range variants {
		t.Run(variant.name, func(t *testing.T) {
			event := base
			variant.apply(&event)
			if got := StableAgentEventID(event); got == baseID {
				t.Fatalf("identity did not change for %s: %q", variant.name, got)
			}
		})
	}
}

func TestCanonicalToolSemanticsNormalizeAliasesAndArguments(t *testing.T) {
	event := CanonicalAgentEventFromObservation(AgentEvent{
		Type:      "tool_call",
		ToolName:  "run-command",
		ToolInput: map[string]any{"argv": []any{"printf", "hello"}},
	}, "exec-1", "exec-1", 1, time.Time{})
	if event.Payload["toolKind"] != "ran" || event.Payload["toolDetail"] != "printf hello" {
		t.Fatalf("unexpected tool semantics: %#v", event.Payload)
	}
}
