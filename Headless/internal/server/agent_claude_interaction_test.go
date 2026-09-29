package server

import (
	"context"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func claudeQuestionTestPayload() map[string]any {
	options := func(labels ...string) []any {
		result := make([]any, 0, len(labels))
		for _, label := range labels {
			result = append(result, map[string]any{"id": label, "label": label})
		}
		return result
	}
	return map[string]any{
		"requestId": "toolu_1",
		"state":     "pending",
		"questions": []any{
			map[string]any{"id": "q0", "selection": "single", "options": options("Red", "Green", "Blue")},
			map[string]any{"id": "q1", "selection": "multiple", "options": options("Apple", "Banana", "Cherry")},
		},
	}
}

func recordedKeys(writes [][]byte) string {
	names := map[string]string{"\x1b[B": "Down", "\r": "Enter", "\x1b": "Esc"}
	parts := make([]string, 0, len(writes))
	for _, write := range writes {
		if name, ok := names[string(write)]; ok {
			parts = append(parts, name)
		} else {
			parts = append(parts, "text:"+string(write))
		}
	}
	return strings.Join(parts, " ")
}

func newClaudeInteractionRuntime(t *testing.T) *inputRecordingRuntime {
	t.Helper()
	runtime := &inputRecordingRuntime{memoryRuntime: newMemoryRuntime(t)}
	if err := runtime.Create(context.Background(), "sess", "", "", nil); err != nil {
		t.Fatal(err)
	}
	return runtime
}

// The key script replayed against Claude Code 2.1: Green, then Apple and
// Cherry, then "Submit answers" on the review tab.
func TestClaudeQuestionAnswersDriveTabsAndReview(t *testing.T) {
	runtime := newClaudeInteractionRuntime(t)
	err := sendProviderInteractionInput(context.Background(), runtime, "sess", "claude", api.AgentInteractionResponse{
		Kind: "question",
		Response: map[string]any{
			"answerIndices": map[string]any{"q0": []any{1}, "q1": []any{2, 0}},
		},
	}, claudeQuestionTestPayload())
	if err != nil {
		t.Fatal(err)
	}
	want := "Down Enter Enter Down Down Enter Down Down Enter Enter"
	if got := recordedKeys(runtime.writes); got != want {
		t.Fatalf("keys = %q, want %q", got, want)
	}
}

func TestClaudeSingleQuestionTypesCustomAnswerWithoutReview(t *testing.T) {
	runtime := newClaudeInteractionRuntime(t)
	payload := claudeQuestionTestPayload()
	payload["questions"] = payload["questions"].([]any)[:1]
	err := sendProviderInteractionInput(context.Background(), runtime, "sess", "claude", api.AgentInteractionResponse{
		Kind:     "question",
		Response: map[string]any{"customAnswers": map[string]any{"q0": "Teal"}},
	}, payload)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := recordedKeys(runtime.writes), "Down Down Down text:Teal Enter"; got != want {
		t.Fatalf("keys = %q, want %q", got, want)
	}
}

func TestClaudeQuestionRejectsBeforeTypingAnything(t *testing.T) {
	cases := map[string]map[string]any{
		"out of range":   {"answerIndices": map[string]any{"q0": []any{3}, "q1": []any{0}}},
		"missing answer": {"answerIndices": map[string]any{"q0": []any{0}}},
		"multi note": {
			"answerIndices": map[string]any{"q0": []any{0}, "q1": []any{0}},
			"customAnswers": map[string]any{"q1": "Kiwi"},
		},
	}
	for name, response := range cases {
		t.Run(name, func(t *testing.T) {
			runtime := newClaudeInteractionRuntime(t)
			err := sendProviderInteractionInput(context.Background(), runtime, "sess", "claude", api.AgentInteractionResponse{
				Kind: "question", Response: response,
			}, claudeQuestionTestPayload())
			if err == nil {
				t.Fatal("expected an error")
			}
			if len(runtime.writes) != 0 {
				t.Fatalf("wrote %q before rejecting", recordedKeys(runtime.writes))
			}
		})
	}
}

func TestClaudeQuestionWithoutSchemaIsRejected(t *testing.T) {
	runtime := newClaudeInteractionRuntime(t)
	err := sendProviderInteractionInput(context.Background(), runtime, "sess", "claude", api.AgentInteractionResponse{
		Kind:     "question",
		Response: map[string]any{"answerIndices": map[string]any{"q0": []any{0}}},
	}, nil)
	if err == nil || len(runtime.writes) != 0 {
		t.Fatalf("err = %v, writes = %q; want rejection without input", err, recordedKeys(runtime.writes))
	}
}

func TestClaudeCancelUsesEscNotInterrupt(t *testing.T) {
	runtime := newClaudeInteractionRuntime(t)
	err := sendProviderInteractionInput(context.Background(), runtime, "sess", "claude", api.AgentInteractionResponse{
		Kind: "question", Response: map[string]any{"cancelled": true},
	}, claudeQuestionTestPayload())
	if err != nil {
		t.Fatal(err)
	}
	if got := recordedKeys(runtime.writes); got != "Esc" {
		t.Fatalf("keys = %q, want Esc", got)
	}
}

func TestClaudePermissionIsNeverAnsweredOnAGuess(t *testing.T) {
	runtime := newClaudeInteractionRuntime(t)
	err := sendProviderInteractionInput(context.Background(), runtime, "sess", "claude", api.AgentInteractionResponse{
		Kind: "permission", Response: map[string]any{"decision": "allow"},
	}, nil)
	if err == nil || len(runtime.writes) != 0 {
		t.Fatalf("err = %v, writes = %q; want rejection without input", err, recordedKeys(runtime.writes))
	}
}

func TestInteractionAndGoalProvidersAreGatedSeparately(t *testing.T) {
	if !tuiSupportsAgentInteractions("claude") || !tuiSupportsAgentInteractions("codex") {
		t.Fatal("claude and codex must accept interaction responses")
	}
	if tuiSupportsAgentInteractions("opencode") {
		t.Fatal("providers without a PTY adapter must stay read-only")
	}
	if tuiSupportsAgentGoals("claude") {
		t.Fatal("claude has no /goal command")
	}
}
