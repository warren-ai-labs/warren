package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
)

func TestUpdateTunnelEnabledPersistsIntent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: path}

	if err := service.UpdateTunnelEnabled(tunnel.KindGnar, true); err != nil {
		t.Fatalf("enable gnar: %v", err)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	if !loaded.TunnelEnabled[tunnel.KindGnar] {
		t.Fatalf("enabled tunnels = %#v, want gnar", loaded.TunnelEnabled)
	}

	if err := service.UpdateTunnelEnabled(tunnel.KindGnar, false); err != nil {
		t.Fatalf("disable gnar: %v", err)
	}
	loaded, err = settings.Load(path)
	if err != nil {
		t.Fatalf("reload settings: %v", err)
	}
	if loaded.TunnelEnabled[tunnel.KindGnar] {
		t.Fatalf("enabled tunnels = %#v, want gnar cleared", loaded.TunnelEnabled)
	}
}

func TestUpdateTunnelEnabledRejectsUnknownKind(t *testing.T) {
	service := &Service{SettingsPath: filepath.Join(t.TempDir(), "settings.json")}
	if err := service.UpdateTunnelEnabled("bogus", true); err == nil {
		t.Fatal("unknown tunnel kind must fail")
	}
}

func TestSetAutoStartAIIsOptInAndPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: path}
	if service.Settings.AutoStartAI {
		t.Fatal("auto-start AI must default to disabled")
	}

	if err := service.SetAutoStartAI(true); err != nil {
		t.Fatalf("enable auto-start AI: %v", err)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load enabled settings: %v", err)
	}
	if !loaded.AutoStartAI {
		t.Fatal("enabled autoStartAI was not persisted")
	}

	if err := service.SetAutoStartAI(false); err != nil {
		t.Fatalf("disable auto-start AI: %v", err)
	}
	loaded, err = settings.Load(path)
	if err != nil {
		t.Fatalf("load disabled settings: %v", err)
	}
	if loaded.AutoStartAI {
		t.Fatal("disabled autoStartAI remained enabled")
	}
}

func TestSetAutoOpenShellIsOptInAndPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: path}
	if service.Settings.AutoOpenShell {
		t.Fatal("auto-open shell must default to disabled")
	}

	if err := service.SetAutoOpenShell(true); err != nil {
		t.Fatalf("enable auto-open shell: %v", err)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load enabled settings: %v", err)
	}
	if !loaded.AutoOpenShell {
		t.Fatal("enabled autoOpenShell was not persisted")
	}

	if err := service.SetAutoOpenShell(false); err != nil {
		t.Fatalf("disable auto-open shell: %v", err)
	}
	loaded, err = settings.Load(path)
	if err != nil {
		t.Fatalf("load disabled settings: %v", err)
	}
	if loaded.AutoOpenShell {
		t.Fatal("disabled autoOpenShell remained enabled")
	}
}

func TestHTTPSettingsExposeWorkspaceDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{
		Runtime:        &memoryRuntime{sessions: map[string][]byte{}},
		DefaultRuntime: settings.RuntimeGhostline,
		SettingsPath:   path,
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	request, err := http.NewRequest(http.MethodGet, httpServer.URL+"/v1/settings", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("get settings: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("get settings status = %d", response.StatusCode)
	}
	var initial map[string]any
	if err := json.NewDecoder(response.Body).Decode(&initial); err != nil {
		t.Fatalf("decode initial settings: %v", err)
	}
	if initial["autoOpenShell"] != false || initial["autoStartAI"] != false {
		t.Fatalf("initial workspace defaults = %#v", initial)
	}

	body, err := json.Marshal(map[string]bool{
		"autoOpenShell": true,
		"autoStartAI":   true,
	})
	if err != nil {
		t.Fatal(err)
	}
	request, err = http.NewRequest(http.MethodPut, httpServer.URL+"/v1/settings", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Content-Type", "application/json")
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("put settings: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("put settings status = %d", response.StatusCode)
	}
	var updated map[string]any
	if err := json.NewDecoder(response.Body).Decode(&updated); err != nil {
		t.Fatalf("decode updated settings: %v", err)
	}
	if updated["autoStartAI"] != true || updated["autoOpenShell"] != true {
		t.Fatalf("updated workspace defaults = %#v", updated)
	}
	loaded, err := settings.Load(path)
	if err != nil {
		t.Fatalf("load persisted settings: %v", err)
	}
	if !loaded.AutoStartAI || !loaded.AutoOpenShell {
		t.Fatalf("persisted workspace defaults = %#v", loaded)
	}
}

func TestHTTPSettingsRejectCredentialBearingGnarEdge(t *testing.T) {
	service := &Service{
		Runtime:        &memoryRuntime{sessions: map[string][]byte{}},
		DefaultRuntime: settings.RuntimeGhostline,
		SettingsPath:   filepath.Join(t.TempDir(), "settings.json"),
	}
	httpServer := httptest.NewServer(NewHTTPServer(service, "secret", nil).Handler())
	defer httpServer.Close()

	body := bytes.NewBufferString(`{"gnarEdge":"https://user:pass@example.com"}`)
	request, err := http.NewRequest(http.MethodPut, httpServer.URL+"/v1/settings", body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("put invalid gnar edge: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid gnar edge status = %d", response.StatusCode)
	}
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "user:pass") {
		t.Fatalf("invalid Edge credentials leaked in settings error: %s", data)
	}
	if service.Settings.GnarEdge != "" {
		t.Fatalf("invalid gnar edge was applied: %q", service.Settings.GnarEdge)
	}
}

func TestHTTPSettingsClearGnarOverrideRestoresReleaseDefault(t *testing.T) {
	service := &Service{
		Runtime:        &memoryRuntime{sessions: map[string][]byte{}},
		DefaultRuntime: settings.RuntimeGhostline,
		Settings:       settings.Settings{GnarEdge: "https://custom.example.com"},
		SettingsPath:   filepath.Join(t.TempDir(), "settings.json"),
	}
	handler := NewHTTPServer(service, "secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9873", "", "", "/missing/gnar")
	handler.Tunnels.SetGnarDefaultEdge("https://release.example.com")
	handler.Tunnels.SetGnarEdge("https://custom.example.com")
	httpServer := httptest.NewServer(handler.Handler())
	defer httpServer.Close()

	request, err := http.NewRequest(http.MethodPut, httpServer.URL+"/v1/settings", bytes.NewBufferString(`{"gnarEdge":""}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("clear gnar edge status = %d", response.StatusCode)
	}
	var result map[string]any
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if result["gnarEdge"] != "" || result["gnarEffectiveEdge"] != "https://release.example.com" {
		t.Fatalf("clear gnar edge response = %#v", result)
	}
	if got := handler.Tunnels.GnarEdge(); got != "https://release.example.com" {
		t.Fatalf("effective edge after clear = %q", got)
	}
	loaded, err := settings.Load(service.SettingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.GnarEdge != "" {
		t.Fatalf("persisted gnar override = %q", loaded.GnarEdge)
	}
}

func TestPublicAccessLifecycleUsesPrivateEnrollmentAndCredentialFreeResponse(t *testing.T) {
	keyPath := filepath.Join(t.TempDir(), "gnar-key")
	loginCountPath := filepath.Join(t.TempDir(), "gnar-login-count")
	t.Setenv("GNAR_KEY_FILE", keyPath)
	t.Setenv("GNAR_LOGIN_COUNT", loginCountPath)
	gnar := writeExecutableScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  count=0
  if [ -f "$GNAR_LOGIN_COUNT" ]; then count=$(cat "$GNAR_LOGIN_COUNT"); fi
  count=$((count + 1))
  printf '%s' "$count" > "$GNAR_LOGIN_COUNT"
  cat > "$GNAR_KEY_FILE"
  printf '%s\n' '{"type":"login_ok"}'
  exit 0
fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/warren/path","target":"http://127.0.0.1:8789"}'
sleep 30
`)
	settingsPath := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: settingsPath}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9879", "", "", gnar)
	defer handler.Tunnels.StopAll()
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	body := bytes.NewBufferString(`{"edgeUrl":"https://edge.example.com","accountName":"warren","enrollmentKey":"memorable-key"}`)
	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/public-access/enable", body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer daemon-secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("enable public access: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("enable status = %d", response.StatusCode)
	}
	var status api.PublicAccessStatus
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatalf("decode enable response: %v", err)
	}
	if !status.Enabled || !status.Running || status.PublicEndpoint != "https://edge.example.com/warren/path/" || strings.Contains(status.PublicEndpoint, "#") {
		t.Fatalf("enable status = %#v", status)
	}
	encoded, _ := json.Marshal(status)
	if strings.Contains(string(encoded), "memorable-key") || strings.Contains(string(encoded), "daemon-secret") {
		t.Fatalf("public access response leaked a secret: %s", encoded)
	}
	key, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatalf("read gnar stdin: %v", err)
	}
	if string(key) != "memorable-key" {
		t.Fatalf("gnar stdin = %q", key)
	}
	settingsData, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatalf("read settings: %v", err)
	}
	if strings.Contains(string(settingsData), "memorable-key") {
		t.Fatalf("enrollment key was persisted: %s", settingsData)
	}

	get, err := http.NewRequest(http.MethodGet, server.URL+"/v1/public-access", nil)
	if err != nil {
		t.Fatal(err)
	}
	get.Header.Set("Authorization", "Bearer daemon-secret")
	getResponse, err := http.DefaultClient.Do(get)
	if err != nil {
		t.Fatalf("get public access: %v", err)
	}
	defer getResponse.Body.Close()
	var current api.PublicAccessStatus
	if err := json.NewDecoder(getResponse.Body).Decode(&current); err != nil {
		t.Fatalf("decode current status: %v", err)
	}
	if current.PublicEndpoint != status.PublicEndpoint || !current.Running {
		t.Fatalf("current status = %#v", current)
	}

	disable, err := http.NewRequest(http.MethodPost, server.URL+"/v1/public-access/disable", nil)
	if err != nil {
		t.Fatal(err)
	}
	disable.Header.Set("Authorization", "Bearer daemon-secret")
	disableResponse, err := http.DefaultClient.Do(disable)
	if err != nil {
		t.Fatalf("disable public access: %v", err)
	}
	defer disableResponse.Body.Close()
	if disableResponse.StatusCode != http.StatusOK {
		t.Fatalf("disable status = %d", disableResponse.StatusCode)
	}
	var disabled api.PublicAccessStatus
	if err := json.NewDecoder(disableResponse.Body).Decode(&disabled); err != nil {
		t.Fatalf("decode disable response: %v", err)
	}
	if disabled.Enabled || disabled.Running {
		t.Fatalf("disabled status = %#v", disabled)
	}

	restart, err := http.NewRequest(http.MethodPost, server.URL+"/v1/public-access/restart", nil)
	if err != nil {
		t.Fatal(err)
	}
	restart.Header.Set("Authorization", "Bearer daemon-secret")
	restartResponse, err := http.DefaultClient.Do(restart)
	if err != nil {
		t.Fatalf("restart public access: %v", err)
	}
	defer restartResponse.Body.Close()
	if restartResponse.StatusCode != http.StatusOK {
		t.Fatalf("restart status = %d", restartResponse.StatusCode)
	}
	var restarted api.PublicAccessStatus
	if err := json.NewDecoder(restartResponse.Body).Decode(&restarted); err != nil {
		t.Fatalf("decode restart response: %v", err)
	}
	if !restarted.Enabled || !restarted.Running || restarted.PublicEndpoint == "" {
		t.Fatalf("restarted status = %#v", restarted)
	}
	loginCount, err := os.ReadFile(loginCountPath)
	if err != nil {
		t.Fatalf("read login count: %v", err)
	}
	if string(loginCount) != "1" {
		t.Fatalf("restart repeated enrollment login: count=%q", loginCount)
	}
}

func TestPublicAccessTestSavesConfigWithoutEnablingAndTopStartReusesToken(t *testing.T) {
	keyPath := filepath.Join(t.TempDir(), "gnar-key")
	loginCountPath := filepath.Join(t.TempDir(), "gnar-login-count")
	t.Setenv("GNAR_KEY_FILE", keyPath)
	t.Setenv("GNAR_LOGIN_COUNT", loginCountPath)
	gnar := writeExecutableScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  count=0
  if [ -f "$GNAR_LOGIN_COUNT" ]; then count=$(cat "$GNAR_LOGIN_COUNT"); fi
  count=$((count + 1))
  printf '%s' "$count" > "$GNAR_LOGIN_COUNT"
  cat > "$GNAR_KEY_FILE"
  printf '%s\n' '{"type":"login_ok"}'
  exit 0
fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/office"}'
sleep 30
`)
	settingsPath := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{HostName: "Office Mac", SettingsPath: settingsPath}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9879", "", "", gnar)
	defer handler.Tunnels.StopAll()
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	testRequest, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/public-access/test",
		bytes.NewBufferString(`{"edgeUrl":"https://edge.example.com","approvalKey":"approval-secret"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	testRequest.Header.Set("Authorization", "Bearer daemon-secret")
	testRequest.Header.Set("Content-Type", "application/json")
	testResponse, err := http.DefaultClient.Do(testRequest)
	if err != nil {
		t.Fatalf("test public access: %v", err)
	}
	defer testResponse.Body.Close()
	if testResponse.StatusCode != http.StatusOK {
		t.Fatalf("test status = %d", testResponse.StatusCode)
	}
	var tested api.PublicAccessStatus
	if err := json.NewDecoder(testResponse.Body).Decode(&tested); err != nil {
		t.Fatalf("decode test status: %v", err)
	}
	if !tested.Authenticated || tested.Enabled || tested.Running || tested.PublicEndpoint != "" {
		t.Fatalf("test status = %#v", tested)
	}

	settingsData, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatalf("read settings: %v", err)
	}
	if strings.Contains(string(settingsData), "approval-secret") || strings.Contains(string(settingsData), "office-mac") {
		t.Fatalf("test persisted a secret or derived account: %s", settingsData)
	}
	key, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatalf("read gnar stdin: %v", err)
	}
	if string(key) != "approval-secret" {
		t.Fatalf("gnar stdin = %q", key)
	}

	startRequest, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/public-access/enable",
		bytes.NewBufferString(`{}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	startRequest.Header.Set("Authorization", "Bearer daemon-secret")
	startRequest.Header.Set("Content-Type", "application/json")
	startResponse, err := http.DefaultClient.Do(startRequest)
	if err != nil {
		t.Fatalf("start public access: %v", err)
	}
	defer startResponse.Body.Close()
	if startResponse.StatusCode != http.StatusOK {
		t.Fatalf("start status = %d", startResponse.StatusCode)
	}
	var started api.PublicAccessStatus
	if err := json.NewDecoder(startResponse.Body).Decode(&started); err != nil {
		t.Fatalf("decode start status: %v", err)
	}
	if !started.Authenticated || !started.Enabled || !started.Running || started.PublicEndpoint == "" {
		t.Fatalf("start status = %#v", started)
	}
	loginCount, err := os.ReadFile(loginCountPath)
	if err != nil {
		t.Fatalf("read login count: %v", err)
	}
	if string(loginCount) != "1" {
		t.Fatalf("start unexpectedly repeated login: %q", loginCount)
	}
}

func TestPublicAccessTestStopsExistingProcessBeforeTestingNewEdge(t *testing.T) {
	edgeLogPath := filepath.Join(t.TempDir(), "gnar-edge-log")
	t.Setenv("GNAR_EDGE_LOG", edgeLogPath)
	gnar := writeExecutableScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  cat >/dev/null
  exit 0
fi
edge=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "--edge" ]; then edge="$argument"; fi
  previous="$argument"
done
printf '%s\n' "$edge" >> "$GNAR_EDGE_LOG"
if [ "$edge" = "https://new.example.com" ]; then
  printf '%s\n' '{"type":"tunnel_ready","public_url":"https://new.example.com/host"}'
else
  printf '%s\n' '{"type":"tunnel_ready","public_url":"https://old.example.com/host"}'
fi
sleep 30
`)
	service := &Service{
		HostName:     "Office Mac",
		SettingsPath: filepath.Join(t.TempDir(), "settings.json"),
	}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9879", "", "", gnar)
	defer handler.Tunnels.StopAll()
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	start := func(edge string) api.PublicAccessStatus {
		request, err := http.NewRequest(
			http.MethodPost,
			server.URL+"/v1/public-access/enable",
			bytes.NewBufferString(fmt.Sprintf(`{"edgeUrl":%q,"accountName":"warren"}`, edge)),
		)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Authorization", "Bearer daemon-secret")
		request.Header.Set("Content-Type", "application/json")
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("enable %s status = %d", edge, response.StatusCode)
		}
		var status api.PublicAccessStatus
		if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
			t.Fatal(err)
		}
		return status
	}

	if status := start("https://old.example.com"); status.PublicEndpoint != "https://old.example.com/host/" {
		t.Fatalf("initial status = %#v", status)
	}
	testRequest, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/public-access/test",
		bytes.NewBufferString(`{"edgeUrl":"https://new.example.com","accountName":"warren"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	testRequest.Header.Set("Authorization", "Bearer daemon-secret")
	testRequest.Header.Set("Content-Type", "application/json")
	testResponse, err := http.DefaultClient.Do(testRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer testResponse.Body.Close()
	if testResponse.StatusCode != http.StatusOK {
		t.Fatalf("test status = %d", testResponse.StatusCode)
	}
	var tested api.PublicAccessStatus
	if err := json.NewDecoder(testResponse.Body).Decode(&tested); err != nil {
		t.Fatal(err)
	}
	if !tested.Running || tested.PublicEndpoint != "https://new.example.com/host/" {
		t.Fatalf("tested status = %#v", tested)
	}

	data, err := os.ReadFile(edgeLogPath)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Fields(string(data))
	want := []string{"https://old.example.com", "https://new.example.com", "https://new.example.com"}
	if !slices.Equal(got, want) {
		t.Fatalf("gnar edge invocations = %#v, want %#v", got, want)
	}
}

func TestPublicAccessEnableRejectsInvalidEdgeBeforePersisting(t *testing.T) {
	settingsPath := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: settingsPath}
	handler := NewHTTPServer(service, "secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9878", "", "", "/missing/gnar")
	server := httptest.NewServer(handler.Handler())
	defer server.Close()
	body := bytes.NewBufferString(`{"edgeUrl":"https://user:pass@example.com","enrollmentKey":"key"}`)
	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/public-access/enable", body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid Edge status = %d", response.StatusCode)
	}
	if _, err := os.Stat(settingsPath); !os.IsNotExist(err) {
		t.Fatalf("invalid Edge unexpectedly persisted settings: %v", err)
	}
}

func TestPublicAccessEnableRejectsInvalidGnarV17Account(t *testing.T) {
	settingsPath := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{SettingsPath: settingsPath}
	handler := NewHTTPServer(service, "secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9878", "", "", "/missing/gnar")
	server := httptest.NewServer(handler.Handler())
	defer server.Close()
	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/public-access/enable",
		bytes.NewBufferString(`{"edgeUrl":"https://edge.example.com","accountName":"bad account"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid account status = %d", response.StatusCode)
	}
	if _, err := os.Stat(settingsPath); !os.IsNotExist(err) {
		t.Fatalf("invalid account unexpectedly persisted settings: %v", err)
	}
}

func TestPublicAccessKeepsEffectiveDefaultEdgeForSignedInGnar(t *testing.T) {
	gnar := writeExecutableScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then exit 1; fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://signed-in.example.com/warren"}'
sleep 30
`)
	service := &Service{SettingsPath: filepath.Join(t.TempDir(), "settings.json")}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9877", "", "", gnar)
	handler.Tunnels.SetGnarEdge("https://edge.example.com")
	defer handler.Tunnels.StopAll()
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/public-access/enable", bytes.NewBufferString(`{"accountName":"warren"}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer daemon-secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("signed-in enable status = %d", response.StatusCode)
	}
	var status api.PublicAccessStatus
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatal(err)
	}
	if status.EdgeURL != "https://edge.example.com" || !status.Running {
		t.Fatalf("signed-in status = %#v", status)
	}
}

func TestPublicAccessStatusDoesNotEchoCredentialBearingEdge(t *testing.T) {
	service := &Service{Settings: settings.Settings{GnarEdge: "https://user:pass@example.com"}}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9875", "", "", "/missing/gnar")
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	request, err := http.NewRequest(http.MethodGet, server.URL+"/v1/public-access", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer daemon-secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "user:pass") {
		t.Fatalf("public access status echoed Edge credentials: %s", data)
	}
	var status api.PublicAccessStatus
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatal(err)
	}
	if status.EdgeURL != "" || status.Error == "" {
		t.Fatalf("invalid Edge status = %#v", status)
	}
}

func TestPublicAccessStatusSeparatesReleaseDefaultFromUserOverride(t *testing.T) {
	service := &Service{Settings: settings.Settings{}}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9874", "", "", "/missing/gnar")
	handler.Tunnels.SetGnarDefaultEdge("https://release.example.com")
	handler.Tunnels.SetGnarEdgeOverride("")
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	getStatus := func() api.PublicAccessStatus {
		request, err := http.NewRequest(http.MethodGet, server.URL+"/v1/public-access", nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Authorization", "Bearer daemon-secret")
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		var status api.PublicAccessStatus
		if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
			t.Fatal(err)
		}
		return status
	}

	status := getStatus()
	if status.EdgeURL != "https://release.example.com" || status.DefaultEdgeURL != "https://release.example.com" || status.ConfiguredEdgeURL != "" || !status.UsingDefaultEdge {
		t.Fatalf("release default status = %#v", status)
	}

	service.Settings.GnarEdge = "https://custom.example.com"
	handler.Tunnels.SetGnarEdge("https://custom.example.com")
	status = getStatus()
	if status.EdgeURL != "https://custom.example.com" || status.ConfiguredEdgeURL != "https://custom.example.com" || status.DefaultEdgeURL != "https://release.example.com" || status.UsingDefaultEdge {
		t.Fatalf("custom override status = %#v", status)
	}
}

func TestPublicAccessResetClearsLocalSetupWithoutRemoteRelease(t *testing.T) {
	settingsPath := filepath.Join(t.TempDir(), "settings.json")
	credentialDir := filepath.Join(t.TempDir(), "warren", "gnar")
	if err := os.MkdirAll(credentialDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(credentialDir, "account.json"), []byte("token"), 0o600); err != nil {
		t.Fatal(err)
	}
	service := &Service{
		Settings: settings.Settings{
			GnarEdge:      "https://custom.example.com",
			GnarAccount:   "abcdlsj",
			TunnelEnabled: map[string]bool{tunnel.KindGnar: true},
		},
		SettingsPath: settingsPath,
	}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9873", "", "", "/missing/gnar")
	handler.Tunnels.SetGnarDefaultEdge("https://release.example.com")
	handler.Tunnels.SetGnarEdge("https://custom.example.com")
	handler.Tunnels.SetGnarConfigDir(credentialDir)
	handler.Tunnels.SetGnarConfigDirOwned(true)
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/public-access/reset", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer daemon-secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("reset public access: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("reset status = %d", response.StatusCode)
	}
	var status api.PublicAccessStatus
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatal(err)
	}
	if status.Enabled || status.Authenticated || status.Running || status.ConfiguredEdgeURL != "" || status.ConfiguredAccountName != "" {
		t.Fatalf("reset status = %#v", status)
	}
	if status.EdgeURL != "https://release.example.com" {
		t.Fatalf("reset effective Edge = %q", status.EdgeURL)
	}
	if _, err := os.Stat(credentialDir); !os.IsNotExist(err) {
		t.Fatalf("local credential store remains after reset: %v", err)
	}
	loaded, err := settings.Load(settingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.GnarEdge != "" || loaded.GnarAccount != "" || loaded.TunnelEnabled[tunnel.KindGnar] {
		t.Fatalf("reset persisted settings = %#v", loaded)
	}
}

func TestPublicAccessApprovalKeyWinsAndDefaultAccountIsNotPersisted(t *testing.T) {
	keyPath := filepath.Join(t.TempDir(), "gnar-key")
	loginArgsPath := filepath.Join(t.TempDir(), "gnar-login-args")
	t.Setenv("GNAR_KEY_FILE", keyPath)
	t.Setenv("GNAR_LOGIN_ARGS_FILE", loginArgsPath)
	gnar := writeExecutableScript(t, `#!/bin/sh
if [ "$1" = "login" ]; then
  printf '%s\n' "$@" > "$GNAR_LOGIN_ARGS_FILE"
  cat > "$GNAR_KEY_FILE"
  printf '%s\n' '{"type":"enrollment_succeeded","account":"office-mac"}'
  exit 0
fi
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://edge.example.com/office"}'
sleep 30
`)
	settingsPath := filepath.Join(t.TempDir(), "settings.json")
	service := &Service{HostName: "Office Mac", SettingsPath: settingsPath}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9879", "", "", gnar)
	defer handler.Tunnels.StopAll()
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/public-access/enable",
		bytes.NewBufferString(`{"edgeUrl":"https://edge.example.com","inviteKey":"invite-secret","approvalKey":"approval-secret"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer daemon-secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("enable public access: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("enable status = %d", response.StatusCode)
	}
	var status api.PublicAccessStatus
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatalf("decode status: %v", err)
	}
	if status.AccountName != "office-mac" || status.ConfiguredAccountName != "" || !status.UsingDefaultAccount {
		t.Fatalf("account status = %#v", status)
	}
	key, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatalf("read key: %v", err)
	}
	if string(key) != "approval-secret" {
		t.Fatalf("approval key priority stdin = %q", key)
	}
	args, err := os.ReadFile(loginArgsPath)
	if err != nil {
		t.Fatalf("read login args: %v", err)
	}
	if !strings.Contains(string(args), "--enrollment-key-stdin") || strings.Contains(string(args), "--key-stdin") {
		t.Fatalf("login args = %q", args)
	}
	settingsData, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatalf("read settings: %v", err)
	}
	if strings.Contains(string(settingsData), "approval-secret") || strings.Contains(string(settingsData), "office-mac") {
		t.Fatalf("secret or derived default account persisted: %s", settingsData)
	}
}

func TestLegacyTunnelRouteRemainsAvailableForExistingClients(t *testing.T) {
	gnar := writeExecutableScript(t, `#!/bin/sh
printf '%s\n' '{"type":"tunnel_ready","public_url":"https://legacy.example.com"}'
sleep 30
`)
	service := &Service{SettingsPath: filepath.Join(t.TempDir(), "settings.json")}
	handler := NewHTTPServer(service, "daemon-secret", nil)
	handler.Tunnels = tunnel.NewManager(nil, "http://127.0.0.1:9876", "", "", gnar)
	defer handler.Tunnels.StopAll()
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	body := bytes.NewBufferString(`{"kind":"gnar"}`)
	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/tunnels/start", body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer daemon-secret")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("legacy start status = %d", response.StatusCode)
	}
	var payload struct {
		Tunnels map[string]struct {
			WebURL string `json:"web_url"`
		} `json:"tunnels"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if got := payload.Tunnels[tunnel.KindGnar].WebURL; !strings.Contains(got, "#t=daemon-secret") {
		t.Fatalf("legacy web_url = %q, want compatibility token fragment", got)
	}
}

func TestLegacyTunnelURLEscapesBase64DaemonToken(t *testing.T) {
	if got := authenticatedWebURL("https://legacy.example.com/t/warren/", "a+/="); got != "https://legacy.example.com/t/warren/#t=a%2B%2F%3D" {
		t.Fatalf("legacy web URL = %q", got)
	}
	if got := authenticatedWebURL("https://legacy.example.com/t/warren/#old", "token"); got != "https://legacy.example.com/t/warren/#t=token" {
		t.Fatalf("legacy web URL did not replace fragment: %q", got)
	}
}

func writeExecutableScript(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gnar")
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		t.Fatalf("write script: %v", err)
	}
	return path
}
