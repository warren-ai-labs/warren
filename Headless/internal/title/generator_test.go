package title

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
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

func TestNormalizeBoundsAndStripsWrappers(t *testing.T) {
	got := Normalize("```标题：" + strings.Repeat("长", 70) + "。```")
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("normalized title = %q, want ellipsis", got)
	}
	if len([]rune(got)) != maxTitle {
		t.Fatalf("normalized rune count = %d, want %d", len([]rune(got)), maxTitle)
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
