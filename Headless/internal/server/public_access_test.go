package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

func TestPublicAccessUsesRelayRouteLifecycle(t *testing.T) {
	var route relay.Route
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method == http.MethodPost {
			var body map[string]any
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body["auth_mode"] != "public" || body["enabled"] != true {
				t.Fatalf("route request = %#v", body)
			}
			route = relay.Route{ID: "route-1", PublicHostname: "public.example.com", HostID: "00000000-0000-4000-8000-000000000001", Generation: 1, PathPrefix: "/", AuthMode: "public", Enabled: true}
			_ = json.NewEncoder(writer).Encode(route)
			return
		}
		if request.Method == http.MethodGet {
			route.Enabled = true
			_ = json.NewEncoder(writer).Encode(route)
			return
		}
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	service := &Service{
		SettingsPath: filepath.Join(t.TempDir(), "settings.json"),
		Settings:     settings.Settings{Relay: settings.RelaySettings{URL: server.URL, HostID: "00000000-0000-4000-8000-000000000001"}},
	}
	handler := NewHTTPServer(service, "host-secret", nil)
	handler.RelayStart = func() error { return nil }
	handler.RelayRouteClient = func() (*relay.RouteClient, error) {
		return relay.NewRouteClient(server.URL, service.Settings.Relay.HostID, "host-secret")
	}
	httpServer := httptest.NewServer(handler.Handler())
	defer httpServer.Close()

	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/public-access/enable", nil)
	request.Header.Set("Authorization", "Bearer host-secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("enable public access: response=%v err=%v", response, err)
	}
	response.Body.Close()
	status := handler.publicAccessStatus()
	if !status.Enabled || !status.Running || status.PublicEndpoint != "http://public.example.com/" {
		t.Fatalf("public access status = %#v", status)
	}

	request, _ = http.NewRequest(http.MethodPost, httpServer.URL+"/v1/public-access/disable", nil)
	request.Header.Set("Authorization", "Bearer host-secret")
	response, err = http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("disable public access: response=%v err=%v", response, err)
	}
	response.Body.Close()
	if service.PublicAccessEnabled() {
		t.Fatal("public route intent remained enabled after disable")
	}
}

func TestPublicAccessRejectsLegacyBootstrapFields(t *testing.T) {
	service := &Service{Settings: settings.Settings{Relay: settings.RelaySettings{URL: "https://relay.example", HostID: "host"}}}
	handler := NewHTTPServer(service, "secret", nil)
	httpServer := httptest.NewServer(handler.Handler())
	defer httpServer.Close()
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/public-access/enable", strings.NewReader(`{"inviteKey":"legacy"}`))
	request.Header.Set("Authorization", "Bearer secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("legacy request status = %d", response.StatusCode)
	}
}
