package title

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"unicode/utf8"
)

func TestGenerateUsesCompatibleChatCompletionsEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/chat/completions" {
			t.Fatalf("path = %q, want /v1/chat/completions", request.URL.Path)
		}
		if got := request.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("authorization = %q", got)
		}
		var body struct {
			Model    string `json:"model"`
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if body.Model != "title-model" || len(body.Messages) != 1 {
			t.Fatalf("request body = %#v", body)
		}
		if !strings.Contains(body.Messages[0].Content, "用户请求") || !strings.Contains(body.Messages[0].Content, "助手首句") {
			t.Fatalf("prompt does not contain both contexts: %q", body.Messages[0].Content)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"  标题：修复 session reconnect\n"}}]}`))
	}))
	defer server.Close()

	got, err := (Generator{Config: Config{BaseURL: server.URL + "/v1/", Model: "title-model", APIKey: "test-key"}}).Generate(
		context.Background(), Input{User: "用户请求", Assistant: "助手首句"},
	)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if got != "修复 session reconnect" {
		t.Fatalf("title = %q", got)
	}
}

// Clients truncate a title to the width they have, so the Host keeps the
// whole line rather than writing an ellipsis into the title itself.
func TestNormalizeStripsWrappersAndKeepsTheWholeLine(t *testing.T) {
	long := "inspect 当前分支 merge main 后的 program status 显示"
	if got := Normalize("```标题：" + long + "。```"); got != long {
		t.Fatalf("normalized title = %q, want %q", got, long)
	}
}

func TestGenerateRequiresCredentialsAndAbsoluteBaseURL(t *testing.T) {
	for _, config := range []Config{
		{BaseURL: "https://example.com/v1"},
		{BaseURL: "example.com/v1", APIKey: "key"},
		{BaseURL: "ftp://example.com/v1", APIKey: "key"},
		{BaseURL: "https://user:pass@example.com/v1", APIKey: "key"},
		{BaseURL: "https://example.com/v1?token=secret", APIKey: "key"},
	} {
		if _, err := (Generator{Config: config}).Generate(context.Background(), Input{User: "request"}); err == nil {
			t.Fatalf("Generate(%#v) unexpectedly succeeded", config)
		}
	}
}

func TestGenerateDoesNotRetryOptionalTitleRequests(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		http.Error(writer, "temporary failure", http.StatusBadGateway)
	}))
	defer server.Close()

	if _, err := (Generator{Config: Config{BaseURL: server.URL, APIKey: "test-key"}}).Generate(
		context.Background(), Input{User: "request"},
	); err == nil {
		t.Fatal("Generate unexpectedly succeeded")
	}
	if got := requests.Load(); got != 1 {
		t.Fatalf("requests = %d, want one failed attempt", got)
	}
}

func TestGenerateRejectsEmptyChoices(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[]}`))
	}))
	defer server.Close()

	if _, err := (Generator{Config: Config{BaseURL: server.URL, APIKey: "test-key"}}).Generate(
		context.Background(), Input{User: "request"},
	); err == nil || !strings.Contains(err.Error(), "no choices") {
		t.Fatalf("Generate error = %v, want no choices", err)
	}
}

func TestNewConversationInputKeepsTheNewestMessagesInOrder(t *testing.T) {
	var messages []ConversationMessage
	for index := 0; index < 14; index++ {
		role := ConversationRoleUser
		if index%2 == 1 {
			role = ConversationRoleAssistant
		}
		messages = append(messages, ConversationMessage{Role: role, Text: fmt.Sprintf("message %d", index)})
	}
	// A role that carries no conversation text never reaches the prompt.
	messages = append(messages, ConversationMessage{Role: "tool_call", Text: "ran npm test"})

	input := NewConversationInput(messages)
	if len(input.Messages) != conversationMessageCount {
		t.Fatalf("messages = %d, want %d", len(input.Messages), conversationMessageCount)
	}
	if got := input.Messages[0].Text; got != "message 4" {
		t.Fatalf("oldest kept message = %q, want message 4", got)
	}
	if got := input.Messages[len(input.Messages)-1].Text; got != "message 13" {
		t.Fatalf("newest kept message = %q, want message 13", got)
	}
	for index, message := range input.Messages {
		if want := fmt.Sprintf("message %d", index+4); message.Text != want {
			t.Fatalf("message %d = %q, want %q", index, message.Text, want)
		}
	}
	if !input.HasExchange() {
		t.Fatal("a conversation with both roles reports no exchange")
	}
}

func TestNewConversationInputBoundsEachMessageAndTheWholePrompt(t *testing.T) {
	var messages []ConversationMessage
	for index := 0; index < conversationMessageCount; index++ {
		messages = append(messages, ConversationMessage{
			Role: ConversationRoleUser,
			Text: strings.Repeat("x", conversationMessageLimit*3) + fmt.Sprintf(" tail %d", index),
		})
	}
	input := NewConversationInput(messages)
	total := 0
	for _, message := range input.Messages {
		if got := utf8.RuneCountInString(message.Text); got > conversationMessageLimit+1 {
			t.Fatalf("message length = %d, want at most %d", got, conversationMessageLimit+1)
		}
		// Clipping keeps the head of a message, so the marker of a long message
		// stays out and the subject stays in.
		if !strings.HasPrefix(message.Text, "xxx") || !strings.HasSuffix(message.Text, "…") {
			t.Fatalf("clipped message = %q", message.Text)
		}
		total += utf8.RuneCountInString(message.Text)
	}
	if total > conversationBudget+conversationMessageCount {
		t.Fatalf("conversation prompt budget = %d, want about %d", total, conversationBudget)
	}
}

func TestNewConversationInputDropsEmptyMessages(t *testing.T) {
	input := NewConversationInput([]ConversationMessage{
		{Role: ConversationRoleUser, Text: "   "},
		{Role: ConversationRoleAssistant, Text: "Done"},
	})
	if len(input.Messages) != 1 || input.Messages[0].Text != "Done" {
		t.Fatalf("messages = %#v", input.Messages)
	}
	if input.HasExchange() {
		t.Fatal("one side of a turn is not an exchange")
	}
}

func TestGenerateConversationNamesTheCurrentSubject(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if len(body.Messages) != 1 {
			t.Fatalf("request messages = %d, want 1", len(body.Messages))
		}
		prompt := body.Messages[0].Content
		if !strings.Contains(prompt, "Create a short label") {
			t.Fatalf("prompt lost the shared title rules: %q", prompt)
		}
		if !strings.Contains(prompt, "about now") {
			t.Fatalf("prompt does not ask for the current subject: %q", prompt)
		}
		if strings.Index(prompt, "User: add the export button") > strings.Index(prompt, "Assistant: the button is in") {
			t.Fatalf("prompt reordered the conversation: %q", prompt)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"Title: Add the export button"}}]}`))
	}))
	defer server.Close()

	got, err := (Generator{Config: Config{BaseURL: server.URL, Model: "title-model", APIKey: "test-key"}}).GenerateConversation(
		context.Background(),
		NewConversationInput([]ConversationMessage{
			{Role: ConversationRoleUser, Text: "add the export button"},
			{Role: ConversationRoleAssistant, Text: "the button is in the toolbar"},
		}),
	)
	if err != nil {
		t.Fatalf("GenerateConversation: %v", err)
	}
	if got != "Add the export button" {
		t.Fatalf("title = %q", got)
	}
}

func TestGenerateConversationRequiresAnExchange(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		t.Error("GenerateConversation reached the endpoint without an exchange")
	}))
	defer server.Close()

	for _, messages := range [][]ConversationMessage{
		nil,
		{{Role: ConversationRoleUser, Text: "just a request"}},
	} {
		_, err := (Generator{Config: Config{BaseURL: server.URL, APIKey: "test-key"}}).GenerateConversation(
			context.Background(), NewConversationInput(messages),
		)
		if err == nil || !strings.Contains(err.Error(), "no user and assistant text") {
			t.Fatalf("GenerateConversation error = %v, want a missing-exchange error", err)
		}
	}
}
