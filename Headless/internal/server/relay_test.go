package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

func TestRelayJoinUsesDaemonOwnedEnrollmentAndPersistsOnlyPinnedMetadata(t *testing.T) {
	const daemonToken = "daemon-token-for-test"
	const hostID = "00000000-0000-4000-8000-000000000031"
	var seenURL, seenKey, seenName string
	service := &Service{Settings: settings.Settings{}}
	var starts atomic.Int32
	httpServer := NewHTTPServer(service, daemonToken, nil)
	httpServer.RelayEnroll = func(ctx context.Context, relayURL, enrollmentKey, hostName string) error {
		if ctx == nil {
			t.Fatal("join callback received a nil context")
		}
		seenURL, seenKey, seenName = relayURL, enrollmentKey, hostName
		service.Settings.Relay = settings.RelaySettings{Enabled: true, URL: relayURL, HostID: hostID, RelayKeyID: "key-1", RelayKey: "pinned-key"}
		return nil
	}
	httpServer.RelayStart = func() error {
		starts.Add(1)
		return nil
	}
	server := httptest.NewServer(httpServer.Handler())
	defer server.Close()

	body, _ := json.Marshal(map[string]string{
		"relayUrl":      "https://relay.example.test/",
		"enrollmentKey": "AAAA-BBBB-CCCC-DDDD",
		"hostName":      "Mac",
	})
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/relay/join", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+daemonToken)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("relay join: response=%v err=%v", response, err)
	}
	response.Body.Close()
	if seenURL != "https://relay.example.test/" || seenKey != "AAAA-BBBB-CCCC-DDDD" || seenName != "Mac" {
		t.Fatalf("join callback values = %q %q %q", seenURL, seenKey, seenName)
	}
	value := service.RelaySettingsSnapshot()
	if !value.Enabled || value.URL != seenURL || value.HostID != hostID || value.RelayKeyID != "key-1" || value.RelayKey == "" {
		t.Fatalf("unexpected Relay settings: %#v", value)
	}
	if starts.Load() != 1 {
		t.Fatalf("Relay lifecycle start count = %d, want 1", starts.Load())
	}
	encoded, _ := json.Marshal(value)
	if strings.Contains(string(encoded), seenKey) || strings.Contains(string(encoded), daemonToken) {
		t.Fatalf("credential leaked into persisted Relay settings: %s", encoded)
	}
}

func TestRelayJoinRejectsUnauthorizedAndUnsafeInput(t *testing.T) {
	service := &Service{Settings: settings.Settings{}}
	httpServer := NewHTTPServer(service, "daemon-token", nil)
	httpServer.RelayEnroll = func(_ context.Context, relayURL, _, _ string) error {
		_, err := normalizeRelayEnrollmentURL(relayURL)
		return err
	}
	server := httptest.NewServer(httpServer.Handler())
	defer server.Close()

	for _, test := range []struct {
		name string
		body string
		want int
	}{
		{name: "unauthorized", body: `{"relayUrl":"http://127.0.0.1:1","enrollmentKey":"AAAA-BBBB-CCCC-DDDD"}`, want: http.StatusUnauthorized},
		{name: "missing key", body: `{"relayUrl":"http://127.0.0.1:1"}`, want: http.StatusBadRequest},
		{name: "unsafe URL", body: `{"relayUrl":"https://relay.example/../private","enrollmentKey":"AAAA-BBBB-CCCC-DDDD"}`, want: http.StatusBadRequest},
		{name: "legacy URL field", body: `{"url":"http://127.0.0.1:1","enrollmentKey":"AAAA-BBBB-CCCC-DDDD"}`, want: http.StatusBadRequest},
		{name: "unknown field", body: `{"relayUrl":"http://127.0.0.1:1","unknown":"value","enrollmentKey":"AAAA-BBBB-CCCC-DDDD"}`, want: http.StatusBadRequest},
	} {
		t.Run(test.name, func(t *testing.T) {
			request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/relay/join", strings.NewReader(test.body))
			if test.name != "unauthorized" {
				request.Header.Set("Authorization", "Bearer daemon-token")
			}
			request.Header.Set("Content-Type", "application/json")
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			response.Body.Close()
			if response.StatusCode != test.want {
				t.Fatalf("status=%d, want %d", response.StatusCode, test.want)
			}
		})
	}
}

func TestRelayPairingEndpointReturnsOnlySafeInvite(t *testing.T) {
	handler := NewHTTPServer(&Service{}, "daemon-token", nil)
	handler.RelayPairing = func(ctx context.Context) (relay.PairingResult, error) {
		if ctx == nil {
			t.Fatal("pairing callback received a nil context")
		}
		return relay.PairingResult{
			PairingURL: "https://relay.example/invite/opaque-ticket/",
			ExpiresIn:  604800,
			ExpiresAt:  "2030-01-01T00:00:00Z",
			Reusable:   true,
		}, nil
	}
	server := httptest.NewServer(handler.Handler())
	defer server.Close()

	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/relay/pairing", nil)
	request.Header.Set("Authorization", "Bearer daemon-token")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("pairing endpoint: response=%v err=%v", response, err)
	}
	var result map[string]any
	if json.NewDecoder(response.Body).Decode(&result) != nil {
		t.Fatal("invalid pairing endpoint response")
	}
	response.Body.Close()
	if result["pairing_url"] != "https://relay.example/invite/opaque-ticket/" || result["expires_in"] != float64(604800) || result["reusable"] != true {
		t.Fatalf("pairing endpoint result = %#v", result)
	}
	if _, present := result["access_token"]; present {
		t.Fatalf("pairing endpoint exposed an access token: %#v", result)
	}

	unauthorized, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/relay/pairing", nil)
	unauthorizedResponse, err := http.DefaultClient.Do(unauthorized)
	if err != nil || unauthorizedResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized pairing endpoint: response=%v err=%v", unauthorizedResponse, err)
	}
	unauthorizedResponse.Body.Close()
}

func TestRelayResetDisablesRouteAndClearsLocalEnrollment(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000033"
	var disabled atomic.Bool
	relayServer := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodDelete {
			t.Fatalf("Relay request method = %s, want DELETE", request.Method)
		}
		disabled.Store(true)
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer relayServer.Close()

	service := &Service{
		SettingsPath: filepath.Join(t.TempDir(), "settings.json"),
		Settings: settings.Settings{
			Relay: settings.RelaySettings{
				Enabled:    true,
				URL:        relayServer.URL,
				HostID:     hostID,
				RelayKeyID: "key-1",
				RelayKey:   "pinned-key",
			},
			PublicTunnel: settings.PublicTunnelSettings{
				Enabled:        true,
				RouteID:        "route-1",
				PublicHostname: "public.example.com",
			},
		},
	}
	handler := NewHTTPServer(service, "host-secret", nil)
	var stops atomic.Int32
	handler.RelayStop = func() { stops.Add(1) }
	handler.RelayRouteClient = func() (*relay.RouteClient, error) {
		return relay.NewRouteClient(relayServer.URL, hostID, "host-secret")
	}

	if err := handler.resetRelayEnrollment(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !disabled.Load() {
		t.Fatal("Relay route was not disabled")
	}
	if stops.Load() != 1 {
		t.Fatalf("Relay stop count = %d, want 1", stops.Load())
	}
	if got := service.RelaySettingsSnapshot(); got != (settings.RelaySettings{}) {
		t.Fatalf("Relay settings = %#v, want zero value", got)
	}
	if got := service.PublicTunnelSettingsSnapshot(); got != (settings.PublicTunnelSettings{}) {
		t.Fatalf("Public tunnel settings = %#v, want zero value", got)
	}
	loaded, err := settings.Load(service.SettingsPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Relay != (settings.RelaySettings{}) || loaded.PublicTunnel != (settings.PublicTunnelSettings{}) {
		t.Fatalf("persisted settings = %#v, want cleared Relay and public tunnel", loaded)
	}
}

func TestNormalizeRelayEnrollmentURL(t *testing.T) {
	for input, want := range map[string]string{
		"http://127.0.0.1:8080/":        "http://127.0.0.1:8080",
		"https://[2001:db8::1]:8443/r/": "https://[2001:db8::1]:8443/r",
	} {
		got, err := normalizeRelayEnrollmentURL(input)
		if err != nil || got != want {
			t.Errorf("normalizeRelayEnrollmentURL(%q) = %q, %v; want %q", input, got, err, want)
		}
	}
	for _, input := range []string{
		"relay.example.test",
		"ftp://relay.example.test",
		"https://user:pass@relay.example.test",
		"https://relay.example.test?token=secret",
		"https://relay.example.test/../private",
	} {
		if got, err := normalizeRelayEnrollmentURL(input); err == nil {
			t.Errorf("normalizeRelayEnrollmentURL(%q) accepted %q", input, got)
		}
	}
}
