package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/settings"
)

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
