package title

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

const (
	ProviderCloudflare = "cloudflare"
	ProviderOpenAI     = "openai"

	// DefaultWorkerURL is the hosted Cloudflare Workers AI title endpoint.
	DefaultWorkerURL = "https://title.warrenai.xyz"
)

type workerMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type workerTitleRequest struct {
	Mode      string          `json:"mode"`
	Messages  []workerMessage `json:"messages"`
	Reasoning string          `json:"reasoning,omitempty"`
}

type workerTitleResponse struct {
	Title string `json:"title"`
	Error string `json:"error"`
}

func (g Generator) generateWorkerTitle(ctx context.Context, payload workerTitleRequest) (string, error) {
	baseURL := strings.TrimSpace(g.Config.WorkerURL)
	if baseURL == "" {
		baseURL = DefaultWorkerURL
	}
	baseURL = strings.TrimRight(baseURL, "/")
	endpoint := baseURL
	if !strings.HasSuffix(endpoint, "/v1/title") {
		endpoint += "/v1/title"
	}

	deviceID := strings.TrimSpace(g.Config.DeviceID)
	if deviceID == "" {
		return "", errors.New("title device ID is not configured")
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", deviceID)
	app := strings.TrimSpace(g.Config.App)
	if app == "" {
		app = "warren"
	}
	req.Header.Set("X-App", app)

	client := g.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32*1024))
	if err != nil {
		return "", err
	}
	var parsed workerTitleResponse
	_ = json.Unmarshal(raw, &parsed)

	if resp.StatusCode == http.StatusTooManyRequests {
		if msg := strings.TrimSpace(parsed.Error); msg != "" {
			return "", fmt.Errorf("title service rate limited: %s", msg)
		}
		return "", errors.New("title service daily quota reached")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if msg := strings.TrimSpace(parsed.Error); msg != "" {
			return "", fmt.Errorf("title service error (%d): %s", resp.StatusCode, msg)
		}
		return "", fmt.Errorf("title service returned HTTP %d", resp.StatusCode)
	}

	titleValue := Normalize(parsed.Title)
	if titleValue == "" {
		return "", errors.New("title service response is empty")
	}
	return titleValue, nil
}

func buildWorkerInitialRequest(input Input) workerTitleRequest {
	messages := make([]workerMessage, 0, 2)
	if user := clip(input.User, maxInput); user != "" {
		messages = append(messages, workerMessage{Role: ConversationRoleUser, Content: user})
	}
	if assistant := clip(input.Assistant, maxInput); assistant != "" {
		messages = append(messages, workerMessage{Role: ConversationRoleAssistant, Content: assistant})
	}
	return workerTitleRequest{
		Mode:      "initial",
		Messages:  messages,
		Reasoning: clip(input.Reasoning, maxInput),
	}
}

func buildWorkerConversationRequest(input ConversationInput) workerTitleRequest {
	messages := make([]workerMessage, 0, len(input.Messages))
	for _, msg := range input.Messages {
		text := strings.TrimSpace(msg.Text)
		if text == "" {
			continue
		}
		messages = append(messages, workerMessage{Role: msg.Role, Content: text})
	}
	return workerTitleRequest{
		Mode:     "conversation",
		Messages: messages,
	}
}
