package title

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGeneratorCloudflareInitialTitle(t *testing.T) {
	var gotDeviceID, gotApp string
	var gotBody workerTitleRequest
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/title" {
			t.Errorf("path = %q, want /v1/title", r.URL.Path)
		}
		gotDeviceID = r.Header.Get("X-Device-Id")
		gotApp = r.Header.Get("X-App")
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Errorf("decode body: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"title":"Fix reconnect loop","quota":{"limit":50,"remaining":49}}`))
	}))
	defer server.Close()

	got, err := (Generator{Config: Config{
		Provider:  ProviderCloudflare,
		WorkerURL: server.URL,
		DeviceID:  "wrn-test-device-1234",
		App:       "warren",
	}}).Generate(context.Background(), Input{
		User:      "Fix the reconnect loop",
		Assistant: "Inspecting backoff",
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if got != "Fix reconnect loop" {
		t.Fatalf("title = %q, want Fix reconnect loop", got)
	}
	if gotDeviceID != "wrn-test-device-1234" || gotApp != "warren" {
		t.Fatalf("headers = (%q, %q)", gotDeviceID, gotApp)
	}
	if gotBody.Mode != "initial" || len(gotBody.Messages) != 2 {
		t.Fatalf("body = %+v", gotBody)
	}
}

func TestGeneratorCloudflareConversationAndRateLimit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":"daily device title quota reached"}`))
	}))
	defer server.Close()

	input := NewConversationInput([]ConversationMessage{
		{Role: ConversationRoleUser, Text: "Export ledger"},
		{Role: ConversationRoleAssistant, Text: "Added CSV export"},
	})
	_, err := (Generator{Config: Config{
		Provider:  ProviderCloudflare,
		WorkerURL: server.URL,
		DeviceID:  "wrn-test-device-1234",
	}}).GenerateConversation(context.Background(), input)
	if err == nil || !strings.Contains(err.Error(), "daily device title quota reached") {
		t.Fatalf("err = %v, want rate-limit error", err)
	}
}
