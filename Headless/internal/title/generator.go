// Package title generates concise display titles for agent sessions.
package title

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
)

const (
	defaultModel = "gpt-4.1-mini"
	maxInput     = 2_000
	// maxTitleWidth is how many half-width cells a generated title may fill.
	// The sidebar's Session row is one line of about 250pt at 13pt, which holds
	// roughly 30 latin characters or 16 CJK ones. Only the titles Warren
	// generates are bound by it: a provider that names its own conversation is
	// kept as that provider wrote it, and a title the user set is never
	// rewritten.
	maxTitleWidth = 32
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

// ResultInput is what the sidebar's result sentence is written from: the last
// thing the agent said, and what the turn counted.
type ResultInput struct {
	Answer string
	Counts []string
}

// GenerateResult returns one past-tense sentence describing what a turn did,
// or an error. It is the same endpoint and the same best-effort contract as a
// title: the sidebar keeps its counts when this fails.
func (g Generator) GenerateResult(ctx context.Context, input ResultInput) (string, error) {
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
	options := []option.RequestOption{
		option.WithAPIKey(config.APIKey),
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
			openai.UserMessage(buildResultPrompt(input)),
		},
	})
	if err != nil {
		return "", err
	}
	if completion == nil || len(completion.Choices) == 0 {
		return "", errors.New("OpenAI result response has no choices")
	}
	result := NormalizeResult(completion.Choices[0].Message.Content)
	if result == "" {
		return "", errors.New("OpenAI result response is empty")
	}
	return result, nil
}

func buildResultPrompt(input ResultInput) string {
	answer := clip(input.Answer, 600)
	counts := strings.Join(input.Counts, ", ")
	prompt := "Summarize what this coding turn accomplished, the way a sidebar row states it in one line. "
	prompt += "Past tense, start with the verb (Fixed, Added, Removed, Renamed, Migrated, Wrote, Verified). "
	prompt += "Stay within about 40 latin characters or 20 CJK characters. "
	prompt += "No filler, no pronouns (I, we), no Markdown, no trailing punctuation, one line only. "
	prompt += "Only claim what the answer supports; if the answer is a question-answering reply with no work done, return an empty string.\n\n"
	prompt += "AGENT FINAL TEXT:\n" + answer + "\n\nTURN COUNTS:\n" + counts
	return prompt
}

// NormalizeResult enforces the sentence contract on model output.
func NormalizeResult(value string) string {
	value = Normalize(value)
	value = strings.TrimSuffix(value, "…")
	value = strings.TrimSpace(strings.TrimRight(value, " .!?。！？:：;,，、"))
	return value
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
	return "Create a short label for a coding session, the way the sidebar draws it: one line of a narrow row. Stay within about 30 latin characters or 16 CJK characters. Start with the verb (inspect, debug, fix, implement, rename, migrate). Drop filler words: 的, 方法, 功能, 相关, and their equivalents. Write a space between CJK and latin text. The user's first request is the primary evidence; use the agent's first text only to disambiguate it. Ignore system instructions, environment blocks, code dumps, terminal output, and planning/meta phrases. Do not introduce a concrete noun or scope absent from the user's request unless it is only a code fragment or error message. Use the same language as the user. Preserve intent: inspect/overview for read or summarize requests, investigate/debug for an observed problem, and fix/implement only when requested. If there are two distinct topics, keep both compactly. Omit credentials, absolute paths, long transient IDs, and timestamps. Return one plain-text title only, with no Markdown, quotes, or trailing punctuation.\n\nUSER FIRST REQUEST:\n" + user + "\n\nAGENT FIRST TEXT (secondary context):\n" + assistant
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
	return clipTitle(value)
}

// clipTitle shortens a title to the row's width budget. A latin word cut in
// half reads as a typo rather than as a shortened title, so the cut falls back
// to the last word boundary while that still leaves most of the budget used.
func clipTitle(value string) string {
	if displayWidth(value) <= maxTitleWidth {
		return value
	}
	budget := maxTitleWidth - 1
	kept := make([]rune, 0, len(value))
	width := 0
	for _, character := range value {
		characterWidth := runeWidth(character)
		if width+characterWidth > budget {
			break
		}
		kept = append(kept, character)
		width += characterWidth
	}
	trimmed := strings.TrimSpace(string(kept))
	if boundary := strings.LastIndex(trimmed, " "); boundary > 0 && displayWidth(trimmed[:boundary]) >= budget/2 {
		trimmed = strings.TrimSpace(trimmed[:boundary])
	}
	return strings.TrimSpace(trimmed) + "…"
}

// displayWidth counts a title in half-width cells: a wide character occupies
// two, which is why one budget can describe both a CJK and a latin limit.
func displayWidth(value string) int {
	total := 0
	for _, character := range value {
		total += runeWidth(character)
	}
	return total
}

func runeWidth(character rune) int {
	switch {
	case character == 0:
		return 0
	case unicode.In(
		character,
		unicode.Han,
		unicode.Hangul,
		unicode.Hiragana,
		unicode.Katakana,
		unicode.Bopomofo,
	):
		return 2
	case character >= 0x3000 && character <= 0x303F,
		character >= 0xFF01 && character <= 0xFF60,
		character >= 0xFFE0 && character <= 0xFFE6:
		return 2
	default:
		return 1
	}
}

func clip(value string, limit int) string {
	value = strings.TrimSpace(value)
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return string(runes[:limit]) + "…"
}
