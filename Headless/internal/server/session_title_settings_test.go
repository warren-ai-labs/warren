package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/settings"
)

func TestSettingsTestOpenAIUsesDraftCredentialWithoutPersisting(t *testing.T) {
	type requestDetails struct {
		authorization string
		model         string
	}
	var requestsMu sync.Mutex
	requests := make([]requestDetails, 0, 2)
	requestSeen := make(chan struct{}, 2)
	openAIServer := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode title test request: %v", err)
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		requestsMu.Lock()
		requests = append(requests, requestDetails{
			authorization: request.Header.Get("Authorization"),
			model:         body.Model,
		})
		requestsMu.Unlock()
		requestSeen <- struct{}{}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"choices":[{"message":{"content":"Connection test title"}}]}`))
	}))
	defer openAIServer.Close()

	state, _ := newSessionTitleStore(t)
	service := &Service{
		Store: state,
		Runtime: &memoryRuntime{
			sessions: map[string][]byte{},
		},
		Settings: settings.Settings{
			OpenAIKey: "saved-key",
		},
		SettingsPath: filepath.Join(t.TempDir(), "settings.json"),
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()
	connection := openAuthenticatedConnection(t, httpServer.URL, "/v1/ws")
	defer connection.Close()

	result := requestResult[map[string]bool](t, connection, "settings.testOpenAI", map[string]any{
		"openaiBaseURL": openAIServer.URL + "/v1",
		"openaiModel":   "draft-model",
		"openaiKey":     "draft-key",
	})
	if !result["ok"] {
		t.Fatalf("test OpenAI result = %#v", result)
	}
	<-requestSeen

	result = requestResult[map[string]bool](t, connection, "settings.testOpenAI", map[string]any{
		"openaiBaseURL": openAIServer.URL + "/v1",
		"openaiModel":   "saved-model",
	})
	if !result["ok"] {
		t.Fatalf("saved-key test OpenAI result = %#v", result)
	}
	<-requestSeen

	requestsMu.Lock()
	gotRequests := append([]requestDetails(nil), requests...)
	requestsMu.Unlock()
	if len(gotRequests) != 2 {
		t.Fatalf("OpenAI requests = %d, want two", len(gotRequests))
	}
	if gotRequests[0].authorization != "Bearer draft-key" || gotRequests[0].model != "draft-model" {
		t.Fatalf("draft request = %#v", gotRequests[0])
	}
	if gotRequests[1].authorization != "Bearer saved-key" || gotRequests[1].model != "saved-model" {
		t.Fatalf("saved request = %#v", gotRequests[1])
	}
	if service.Settings.OpenAIKey != "saved-key" {
		t.Fatalf("test changed saved key to %q", service.Settings.OpenAIKey)
	}
}

func TestHTTPSettingsPersistOpenAITitleConfigWithoutReturningKey(t *testing.T) {
	settingsPath := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{
		Runtime:        &memoryRuntime{sessions: map[string][]byte{}},
		DefaultRuntime: settings.RuntimeGhostline,
		SettingsPath:   settingsPath,
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	request, err := http.NewRequest(http.MethodPut, httpServer.URL+"/v1/settings", bytes.NewBufferString(`{"openaiBaseURL":"https://api.openai.com/v1","openaiModel":"gpt-4.1-mini","openaiKey":"test-key","openaiTitleEnabled":true}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("put OpenAI settings: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("put OpenAI settings status = %d", response.StatusCode)
	}
	result, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read settings response: %v", err)
	}
	if strings.Contains(string(result), "test-key") {
		t.Fatalf("settings response leaked OpenAI key: %s", result)
	}
	var decoded map[string]any
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("decode settings response: %v", err)
	}
	if decoded["openaiBaseURL"] != "https://api.openai.com/v1" || decoded["openaiModel"] != "gpt-4.1-mini" || decoded["openaiTitleEnabled"] != true {
		t.Fatalf("OpenAI settings response = %#v", decoded)
	}

	loaded, err := settings.Load(settingsPath)
	if err != nil {
		t.Fatalf("load persisted settings: %v", err)
	}
	if loaded.OpenAIKey != "test-key" || !loaded.OpenAITitleEnabled {
		t.Fatalf("persisted OpenAI settings = %#v", loaded)
	}

	get, err := http.NewRequest(http.MethodGet, httpServer.URL+"/v1/settings", nil)
	if err != nil {
		t.Fatal(err)
	}
	get.Header.Set("Authorization", "Bearer secret")
	getResponse, err := http.DefaultClient.Do(get)
	if err != nil {
		t.Fatalf("get settings: %v", err)
	}
	defer getResponse.Body.Close()
	getBody, err := io.ReadAll(getResponse.Body)
	if err != nil {
		t.Fatalf("read get settings response: %v", err)
	}
	if strings.Contains(string(getBody), "test-key") {
		t.Fatalf("settings GET leaked OpenAI key: %s", getBody)
	}
}
