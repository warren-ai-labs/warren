package controlplane

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRateLimiterChecksAllKeysAtomically(t *testing.T) {
	current := time.Unix(100, 0)
	limiter := newRateLimiter(1, time.Minute)
	limiter.now = func() time.Time { return current }
	if !limiter.allow("ip:one", "host:one") {
		t.Fatal("first request was rejected")
	}
	if limiter.allow("ip:one", "host:two") {
		t.Fatal("an exhausted IP was accepted")
	}
	if !limiter.allow("ip:two", "host:two") {
		t.Fatal("a rejected request consumed the second Host quota")
	}
	current = current.Add(time.Minute)
	if !limiter.allow("ip:one", "host:one") {
		t.Fatal("expired quota did not reset")
	}
}

func TestRequestClientIPNormalizesRemoteAddress(t *testing.T) {
	for remote, want := range map[string]string{
		"192.0.2.10:443":     "192.0.2.10",
		"[2001:db8::10]:443": "2001:db8::10",
		"2001:db8::10":       "2001:db8::10",
		"192.0.2.10":         "192.0.2.10",
		"":                   "unknown",
	} {
		request := httptest.NewRequest(http.MethodGet, "http://relay.example.test/", nil)
		request.RemoteAddr = remote
		if got := requestClientIP(request); got != want {
			t.Errorf("requestClientIP(%q) = %q, want %q", remote, got, want)
		}
	}
	if got := requestClientIP(nil); got != "unknown" {
		t.Fatalf("requestClientIP(nil) = %q", got)
	}
}

func TestPairingStartRateLimitReturnsRetryAfter(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:        "https://relay.example.test",
		AdminToken:       "admin-bootstrap",
		SigningKey:       []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin:    "https://relay.example.test",
		PairingRateLimit: 1,
		RateLimitWindow:  time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, credential := provisionHost(t, httpServer.URL)
	websocketBase := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	host := dialV2Host(t, websocketBase, hostID, credential, "")
	defer host.Close()
	waitForHost(t, httpServer.URL, server, hostID)

	for index, wantStatus := range []int{http.StatusCreated, http.StatusTooManyRequests} {
		request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/pairing", nil)
		request.Header.Set("Authorization", "Bearer admin-bootstrap")
		response, requestErr := http.DefaultClient.Do(request)
		if requestErr != nil {
			t.Fatal(requestErr)
		}
		if response.StatusCode != wantStatus {
			t.Fatalf("pairing attempt %d status=%d, want %d", index+1, response.StatusCode, wantStatus)
		}
		if index == 1 && response.Header.Get("Retry-After") != "3600" {
			t.Fatalf("Retry-After=%q, want 3600", response.Header.Get("Retry-After"))
		}
		response.Body.Close()
	}
}
