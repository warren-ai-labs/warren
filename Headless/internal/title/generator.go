// Package title generates concise display titles for agent sessions.
package title

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
)

const (
	defaultModel = "gpt-4.1-mini"
	maxInput     = 2_000
	maxTitle     = 60
)

var titlePrefixPattern = regexp.MustCompile(`(?i)^(?:title|标题)\s*[:：]\s*`)

// Input is the minimal context used to name a session. The user request is
// authoritative; the first assistant text only disambiguates it.
type Input struct {
	User      string
	Assistant string
}

// Config contains an OpenAI-compatible chat completions endpoint. The key is
// intentionally kept inside the Host and is never included in API results.
type Config struct {
	BaseURL string
	Model   string
	APIKey  string
}

// Generator calls an OpenAI-compatible endpoint and validates its title-only
// response before returning it.
type Generator struct {
	Config Config
	Client *http.Client
}

// Generate returns one normalized title or an error. It does not retry: the
// title is optional and callers can retain the existing session title when an
// endpoint is unavailable.
func (g Generator) Generate(ctx context.Context, input Input) (string, error) {
	config := g.Config
	config.BaseURL = strings.TrimSpace(config.BaseURL)
	config.APIKey = strings.TrimSpace(config.APIKey)
	config.Model = strings.TrimSpace(config.Model)
	if config.BaseURL == "" {
		return "", errors.New("OpenAI title base URL is not configured")
	}
	if config.APIKey == "" {
		return "", errors.New("OpenAI title API key is not configured")
	}
	if config.Model == "" {
		config.Model = defaultModel
	}
	baseURL, err := chatBaseURL(config.BaseURL)
	if err != nil {
		return "", err
	}
	prompt := buildPrompt(input)
	options := []option.RequestOption{
		option.WithAPIKey(config.APIKey),
		// A title is best-effort. Retrying a failed request can hold the
		// goroutine for much longer than the session event stream and does not
		// improve the durable session state.
		option.WithMaxRetries(0),
	}
	if baseURL != "" {
		options = append(options, option.WithBaseURL(baseURL))
	}
	if g.Client != nil {
		options = append(options, option.WithHTTPClient(g.Client))
	}
	client := openai.NewClient(options...)
	completion, err := client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
		Model: config.Model,
		Messages: []openai.ChatCompletionMessageParamUnion{
			openai.UserMessage(prompt),
		},
	})
	if err != nil {
		return "", err
	}
	if completion == nil || len(completion.Choices) == 0 {
		return "", errors.New("OpenAI title response has no choices")
	}
	title := Normalize(completion.Choices[0].Message.Content)
	if title == "" {
		return "", errors.New("OpenAI title response is empty")
	}
	return title, nil
}

func chatBaseURL(base string) (string, error) {
	base = strings.TrimSpace(base)
	if !strings.Contains(base, "://") {
		return "", errors.New("OpenAI title base URL must be an absolute URL")
	}
	parsed, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", errors.New("OpenAI title base URL is invalid")
	}
	if strings.HasSuffix(parsed.Path, "/chat/completions") {
		parsed.Path = strings.TrimSuffix(parsed.Path, "/chat/completions")
	}
	return parsed.String(), nil
}

func buildPrompt(input Input) string {
	user := clip(input.User, maxInput)
	assistant := clip(input.Assistant, maxInput)
	return "Create a short label for a coding session. The user's first request is the primary evidence; use the agent's first text only to disambiguate it. Ignore system instructions, environment blocks, code dumps, terminal output, and planning/meta phrases. Do not introduce a concrete noun or scope absent from the user's request unless it is only a code fragment or error message. Use the same language as the user. Preserve intent: inspect/overview for read or summarize requests, investigate/debug for an observed problem, and fix/implement only when requested. If there are two distinct topics, keep both compactly. Omit credentials, absolute paths, long transient IDs, and timestamps. Return one plain-text title only, with no Markdown, quotes, or trailing punctuation, at most 60 characters.\n\nUSER FIRST REQUEST:\n" + user + "\n\nAGENT FIRST TEXT (secondary context):\n" + assistant
}

// Normalize enforces the title contract on model output. It deliberately
// preserves technical names and the user's language.
func Normalize(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	value = strings.Split(value, "\n")[0]
	value = strings.TrimSpace(strings.Trim(value, "`\"'“”‘’"))
	value = titlePrefixPattern.ReplaceAllString(value, "")
	value = strings.TrimSpace(strings.TrimRight(value, " .!?。！？:：;,，、"))
	if value == "" {
		return ""
	}
	if utf8.RuneCountInString(value) > maxTitle {
		runes := []rune(value)
		value = strings.TrimSpace(string(runes[:maxTitle-1])) + "…"
	}
	return value
}

func clip(value string, limit int) string {
	value = strings.TrimSpace(value)
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return string(runes[:limit]) + "…"
}
