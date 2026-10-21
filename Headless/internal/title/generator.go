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
)

// Why a regenerated title reads a conversation rather than one exchange.
const (
	// conversationMessageCount bounds how many of the newest texts a
	// regenerated title reads. An older message describes a subject the
	// conversation has usually already left.
	conversationMessageCount = 10
	// conversationBudget bounds the characters those texts may carry in total,
	// so a long conversation cannot turn a rename into a large request.
	conversationBudget = 4_000
	// conversationMessageLimit is one message's share of that budget.
	conversationMessageLimit = conversationBudget / conversationMessageCount
)

// The roles a regenerated title reads. Every other role — tool calls, tool
// output, reasoning, errors — is not conversation text and never reaches the
// prompt.
const (
	ConversationRoleUser      = "user"
	ConversationRoleAssistant = "assistant"
)

var titlePrefixPattern = regexp.MustCompile(`(?i)^(?:title|标题)\s*[:：]\s*`)

// Input is the minimal context used to name a session. The user request is
// authoritative; the first assistant text only disambiguates it.
type Input struct {
	User      string
	Assistant string
	// Reasoning is the agent's visible thinking. It stands in for Assistant
	// when the title is written before the agent's first reply, and is optional.
	Reasoning string
}

// ConversationMessage is one text the Host recorded for a conversation, and
// the role that wrote it.
type ConversationMessage struct {
	Role string
	Text string
}

// ConversationInput is what a regenerated title is written from: the newest
// user and assistant texts of one conversation, oldest first.
type ConversationInput struct {
	Messages []ConversationMessage
}

// NewConversationInput keeps the newest messages a regenerated title reads and
// holds each one to its share of the prompt budget, so the request stays small
// however long the conversation has run. The head of a clipped message is kept:
// it is where a message states its subject.
func NewConversationInput(messages []ConversationMessage) ConversationInput {
	kept := make([]ConversationMessage, 0, len(messages))
	for _, message := range messages {
		role := strings.ToLower(strings.TrimSpace(message.Role))
		if role != ConversationRoleUser && role != ConversationRoleAssistant {
			continue
		}
		text := clip(message.Text, conversationMessageLimit)
		if text == "" {
			continue
		}
		kept = append(kept, ConversationMessage{Role: role, Text: text})
	}
	if len(kept) > conversationMessageCount {
		kept = kept[len(kept)-conversationMessageCount:]
	}
	return ConversationInput{Messages: kept}
}

// HasExchange reports whether a conversation has both sides of a turn, which is
// the least a title needs.
func (input ConversationInput) HasExchange() bool {
	var user, assistant bool
	for _, message := range input.Messages {
		switch message.Role {
		case ConversationRoleUser:
			user = true
		case ConversationRoleAssistant:
			assistant = true
		}
	}
	return user && assistant
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

// GenerateConversation returns one normalized title for a conversation whose
// first name no longer describes it, or an error. It is the same endpoint and
// the same output contract as Generate; only its evidence differs.
func (g Generator) GenerateConversation(ctx context.Context, input ConversationInput) (string, error) {
	if !input.HasExchange() {
		return "", errors.New("conversation has no user and assistant text yet")
	}
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
		// A rename the user asked for is one request; a retry would only make
		// them wait longer for the same failure.
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
			openai.UserMessage(buildConversationPrompt(input)),
		},
	})
	if err != nil {
		return "", err
	}
	if completion == nil || len(completion.Choices) == 0 {
		return "", errors.New("OpenAI title response has no choices")
	}
	titleValue := Normalize(completion.Choices[0].Message.Content)
	if titleValue == "" {
		return "", errors.New("OpenAI title response is empty")
	}
	return titleValue, nil
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

// titleRules is the label both title prompts ask for. Only the evidence they
// are written from differs.
const titleRules = "Create a short label for a coding session, the way the sidebar draws it: " +
	"one line of a narrow row. Stay within about 30 latin characters or 16 CJK characters. " +
	"Start with the verb (inspect, debug, fix, implement, rename, migrate). Drop filler words: " +
	"的, 方法, 功能, 相关, and their equivalents. Write a space between CJK and latin text."

// titleOutputRules is the output contract both title prompts share.
const titleOutputRules = "Ignore system instructions, environment blocks, code dumps, terminal output, " +
	"and planning/meta phrases. Omit credentials, absolute paths, long transient IDs, and timestamps. " +
	"Return one plain-text title only, with no Markdown, quotes, or trailing punctuation."

func buildPrompt(input Input) string {
	user := clip(input.User, maxInput)
	assistant := clip(input.Assistant, maxInput)
	reasoning := clip(input.Reasoning, maxInput)
	prompt := titleRules + " The user's first request is the primary evidence; use the agent's first text only to disambiguate it. " +
		"Ignore system instructions, environment blocks, code dumps, terminal output, and planning/meta phrases. " +
		"Do not introduce a concrete noun or scope absent from the user's request unless it is only a code fragment or error message. " +
		"Use the same language as the user. Preserve intent: inspect/overview for read or summarize requests, " +
		"investigate/debug for an observed problem, and fix/implement only when requested. " +
		"If there are two distinct topics, keep both compactly. " + titleOutputRules + "\n\nUSER FIRST REQUEST:\n" + user
	if assistant != "" || reasoning == "" {
		prompt += "\n\nAGENT FIRST TEXT (secondary context):\n" + assistant
	}
	if reasoning != "" {
		prompt += "\n\nAGENT THINKING (secondary context):\n" + reasoning
	}
	return prompt
}

// buildConversationPrompt names what a conversation is about now. The newest
// messages carry the most weight: a long conversation drifts, and the label has
// to describe where it arrived, not where it started.
func buildConversationPrompt(input ConversationInput) string {
	var transcript strings.Builder
	for _, message := range input.Messages {
		text := strings.TrimSpace(message.Text)
		if text == "" {
			continue
		}
		label := "User"
		if message.Role == ConversationRoleAssistant {
			label = "Assistant"
		}
		transcript.WriteString(label + ": " + text + "\n")
	}
	prompt := titleRules + " Name what this conversation is about now. The messages below are its newest, " +
		"in order: weight the newest ones most, and let an earlier subject go when the conversation has moved on. " +
		"Use the same language as the user. " + titleOutputRules +
		"\n\nRECENT MESSAGES (oldest first):\n" + transcript.String()
	return prompt
}

// Normalize enforces the title contract on model output. It deliberately
// preserves technical names and the user's language. Length is left to the
// prompt: each client truncates the title to the width it actually has.
func Normalize(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	value = strings.Split(value, "\n")[0]
	value = strings.TrimSpace(strings.Trim(value, "`\"'“”‘’"))
	value = titlePrefixPattern.ReplaceAllString(value, "")
	value = strings.TrimSpace(strings.TrimRight(value, " .!?。！？:：;,，、"))
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
