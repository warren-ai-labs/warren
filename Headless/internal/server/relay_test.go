package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/settings"
)

func TestRelayEnrollmentUsesDaemonTokenAndPersistsOnlyPinnedMetadata(t *testing.T) {
	const (
		daemonToken = "daemon-token-for-test"
		hostID      = "00000000-0000-4000-8000-000000000031"
		ticket      = "one-time-enrollment-ticket"
	)
	var seenSecret atomic.Bool
	relay := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/v1/hosts/"+hostID+"/enroll" {
			http.NotFound(writer, request)
			return
		}
		var body map[string]string
		if json.NewDecoder(request.Body).Decode(&body) != nil || body["enrollment_ticket"] != ticket || body["host_secret"] != daemonToken {
			http.Error(writer, "invalid enrollment payload", http.StatusUnauthorized)
			return
		}
		seenSecret.Store(true)
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"relay_key_id":"key-1","relay_public_key":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="}`)
	}))
	defer relay.Close()

	service := &Service{Settings: settings.Settings{}}
	var starts atomic.Int32
	httpServer := NewHTTPServer(service, daemonToken, nil)
	httpServer.RelayStart = func() error {
		starts.Add(1)
		return nil
	}
	server := httptest.NewServer(httpServer.Handler())
	defer server.Close()

	body, _ := json.Marshal(map[string]string{
		"relayUrl":         relay.URL + "/",
		"hostId":           hostID,
		"enrollmentTicket": ticket,
	})
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/relay/enroll", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+daemonToken)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("relay enrollment: response=%v err=%v", response, err)
	}
	response.Body.Close()
	if !seenSecret.Load() {
		t.Fatal("daemon token was not used for Relay enrollment")
	}
	value := service.RelaySettingsSnapshot()
	if !value.Enabled || value.URL != relay.URL || value.HostID != hostID || value.RelayKeyID != "key-1" || value.RelayKey == "" {
		t.Fatalf("unexpected Relay settings: %#v", value)
	}
	if starts.Load() != 1 {
		t.Fatalf("Relay lifecycle start count = %d, want 1", starts.Load())
	}
	encoded, _ := json.Marshal(value)
	if strings.Contains(string(encoded), ticket) || strings.Contains(string(encoded), daemonToken) {
		t.Fatalf("credential leaked into persisted Relay settings: %s", encoded)
	}
}

func TestRelayEnrollmentRejectsUnauthorizedAndUnsafeInput(t *testing.T) {
	service := &Service{Settings: settings.Settings{}}
	httpServer := NewHTTPServer(service, "daemon-token", nil)
	server := httptest.NewServer(httpServer.Handler())
	defer server.Close()

	for _, test := range []struct {
		name string
		body string
		want int
	}{
		{name: "unauthorized", body: `{"relayUrl":"http://127.0.0.1:1","hostId":"00000000-0000-4000-8000-000000000031","enrollmentTicket":"ticket"}`, want: http.StatusUnauthorized},
		{name: "invalid host", body: `{"relayUrl":"http://127.0.0.1:1","hostId":"not-a-host","enrollmentTicket":"ticket"}`, want: http.StatusBadRequest},
		{name: "unsafe URL", body: `{"relayUrl":"https://relay.example/../private","hostId":"00000000-0000-4000-8000-000000000031","enrollmentTicket":"ticket"}`, want: http.StatusBadRequest},
	} {
		t.Run(test.name, func(t *testing.T) {
			request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/relay/enroll", strings.NewReader(test.body))
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

func TestRelayEnrollmentDoesNotFollowRedirectsWithDaemonToken(t *testing.T) {
	const (
		daemonToken = "daemon-token-for-redirect-test"
		hostID      = "00000000-0000-4000-8000-000000000032"
	)
	var redirected atomic.Bool
	var leaked atomic.Bool
	target := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		redirected.Store(true)
		if request.Header.Get("Authorization") != "" {
			leaked.Store(true)
		}
		http.Error(writer, "unexpected redirect target", http.StatusBadRequest)
	}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		http.Redirect(writer, request, target.URL, http.StatusFound)
	}))
	defer redirect.Close()

	service := &Service{Settings: settings.Settings{}}
	httpServer := NewHTTPServer(service, daemonToken, nil)
	server := httptest.NewServer(httpServer.Handler())
	defer server.Close()

	body, _ := json.Marshal(map[string]string{
		"relayUrl":         redirect.URL,
		"hostId":           hostID,
		"enrollmentTicket": "redirect-ticket",
	})
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/relay/enroll", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+daemonToken)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusBadGateway {
		t.Fatalf("status=%d, want %d", response.StatusCode, http.StatusBadGateway)
	}
	if redirected.Load() {
		t.Fatal("enrollment followed a redirect to a different host")
	}
	if leaked.Load() {
		t.Fatal("enrollment leaked the daemon token to a redirect target")
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
