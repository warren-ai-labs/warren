package controlplane

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// pairClient provisions a Host, connects it, and returns the Host ID, its
// credential, and a client access capability for that Host.
func pairClient(t *testing.T, server *Server, base, websocketBase string) (string, string, string, *websocket.Conn) {
	t.Helper()
	hostID, credential := provisionHost(t, base)
	host := dialV2Host(t, websocketBase, hostID, credential, "Mac")
	waitForHost(t, base, server, hostID)

	pairingRequest, _ := http.NewRequest(http.MethodPost, base+"/v1/hosts/"+hostID+"/pairing", nil)
	pairingRequest.Header.Set("Authorization", "Bearer admin-bootstrap")
	pairingResponse, err := http.DefaultClient.Do(pairingRequest)
	if err != nil || pairingResponse.StatusCode != http.StatusCreated {
		host.Close()
		t.Fatalf("pairing start: response=%v err=%v", pairingResponse, err)
	}
	var pairing struct {
		Code string `json:"pairing_code"`
	}
	if json.NewDecoder(pairingResponse.Body).Decode(&pairing) != nil || pairing.Code == "" {
		host.Close()
		t.Fatal("missing pairing code")
	}
	pairingResponse.Body.Close()

	body, _ := json.Marshal(map[string]string{"host_id": hostID, "pairing_code": pairing.Code})
	pairResponse, err := http.Post(base+"/v1/pair", "application/json", bytes.NewReader(body))
	if err != nil || pairResponse.StatusCode != http.StatusCreated {
		host.Close()
		t.Fatalf("pair: response=%v err=%v", pairResponse, err)
	}
	var paired struct {
		Token string `json:"access_token"`
	}
	if json.NewDecoder(pairResponse.Body).Decode(&paired) != nil || paired.Token == "" {
		host.Close()
		t.Fatal("missing access token")
	}
	pairResponse.Body.Close()
	return hostID, credential, paired.Token, host
}

func presenceServer(t *testing.T, wait time.Duration) (*Server, *httptest.Server, string) {
	t.Helper()
	server, err := NewServer(Config{
		PublicURL:        "https://relay.example.test",
		AdminToken:       "admin-bootstrap",
		SigningKey:       []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin:    "https://relay.example.test",
		PairingTTL:       time.Minute,
		AccessTTL:        time.Hour,
		HostPresenceWait: wait,
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	t.Cleanup(httpServer.Close)
	return server, httpServer, "ws" + strings.TrimPrefix(httpServer.URL, "http")
}

// A Mac that is waking up, restarting its daemon, or reconnecting after a Relay
// restart is usually back within seconds. The client must not be told the Host
// is offline in that window; it should simply connect once the Host returns.
func TestClientWaitsForAReturningHost(t *testing.T) {
	server, httpServer, websocketBase := presenceServer(t, 5*time.Second)
	hostID, credential, token, host := pairClient(t, server, httpServer.URL, websocketBase)
	host.Close()
	waitForHostOffline(t, server, hostID)

	client, _, err := websocket.DefaultDialer.Dial(websocketBase+"/v1/client/connect", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.WriteJSON(map[string]string{
		"t": "auth", "version": clientProtocolVersion, "access_token": token,
	}); err != nil {
		t.Fatal(err)
	}

	time.Sleep(100 * time.Millisecond)
	returned := dialV2Host(t, websocketBase, hostID, credential, "Mac")
	defer returned.Close()

	_ = returned.SetReadDeadline(time.Now().Add(5 * time.Second))
	messageType, encoded, err := returned.ReadMessage()
	if err != nil || messageType != websocket.BinaryMessage {
		t.Fatalf("returning Host did not receive the waiting client: type=%d err=%v", messageType, err)
	}
	open, err := decodeRelayFrame(encoded)
	if err != nil || open.Kind != frameOpen {
		t.Fatalf("expected an OPEN frame for the waiting client: %#v %v", open, err)
	}
}

// When the Host really is away, the client needs enough detail to explain the
// wait instead of a bare "host offline".
func TestHostOfflineErrorCarriesPresenceDetail(t *testing.T) {
	server, httpServer, websocketBase := presenceServer(t, 150*time.Millisecond)
	hostID, _, token, host := pairClient(t, server, httpServer.URL, websocketBase)
	host.Close()
	waitForHostOffline(t, server, hostID)

	client, _, err := websocket.DefaultDialer.Dial(websocketBase+"/v1/client/connect", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.WriteJSON(map[string]string{
		"t": "auth", "version": clientProtocolVersion, "access_token": token,
	}); err != nil {
		t.Fatal(err)
	}
	_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
	var payload map[string]any
	if err := client.ReadJSON(&payload); err != nil {
		t.Fatalf("read offline error: %v", err)
	}
	if payload["t"] != "error" || payload["error"] != "host offline" {
		t.Fatalf("offline error lost its historical fields: %#v", payload)
	}
	if payload["code"] != "host_offline" {
		t.Fatalf("offline error has no stable code: %#v", payload)
	}
	if payload["retry_after_ms"] != float64(150) {
		t.Fatalf("offline error retry hint = %#v, want 150", payload["retry_after_ms"])
	}
	lastSeen, ok := payload["last_seen_at"].(string)
	if !ok {
		t.Fatalf("offline error has no last_seen_at: %#v", payload)
	}
	if _, err := time.Parse(time.RFC3339, lastSeen); err != nil {
		t.Fatalf("last_seen_at is not RFC3339: %q", lastSeen)
	}
	if payload["host_name"] != "Mac" {
		t.Fatalf("offline error did not name the Host: %#v", payload)
	}
}

// The wait must not become a way to hold a client socket open forever: an
// unrelated Host connecting does not release a waiter.
// A wait longer than a client's welcome deadline would cause the stall it is
// meant to prevent, so it is rejected at construction instead of silently
// clamped.
func TestHostPresenceWaitIsBounded(t *testing.T) {
	base := Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	}
	defaulted, err := NewServer(base)
	if err != nil {
		t.Fatal(err)
	}
	if defaulted.hostPresenceWait() != hostPresenceWait {
		t.Fatalf("default presence wait = %s, want %s", defaulted.hostPresenceWait(), hostPresenceWait)
	}
	configured := base
	configured.HostPresenceWait = 5 * time.Second
	server, err := NewServer(configured)
	if err != nil {
		t.Fatal(err)
	}
	if server.hostPresenceWait() != 5*time.Second {
		t.Fatalf("configured presence wait = %s, want 5s", server.hostPresenceWait())
	}
	for _, invalid := range []time.Duration{-time.Second, maxHostPresenceWait + time.Second} {
		rejected := base
		rejected.HostPresenceWait = invalid
		if _, err := NewServer(rejected); err == nil {
			t.Fatalf("presence wait %s was accepted", invalid)
		}
	}
}

func TestPresenceSignalIsScopedToOneHost(t *testing.T) {
	server, _, _ := presenceServer(t, maxHostPresenceWait)
	first := server.registry.hostOnlineSignal("host-a")
	second := server.registry.hostOnlineSignal("host-a")
	if first != second {
		t.Fatal("waiters on the same Host did not share one signal")
	}
	other := server.registry.hostOnlineSignal("host-b")
	server.registry.signalHostOnline("host-b")
	select {
	case <-other:
	default:
		t.Fatal("signalling a Host did not release its own waiters")
	}
	select {
	case <-first:
		t.Fatal("another Host's connection released this Host's waiters")
	default:
	}
	server.registry.signalHostOnline("host-a")
	select {
	case <-first:
	default:
		t.Fatal("signalling a Host did not release its waiters")
	}
	if replacement := server.registry.hostOnlineSignal("host-a"); replacement == first {
		t.Fatal("a fired signal was reused for the next wait")
	}
}
