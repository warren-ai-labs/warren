package controlplane

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// A tunnel that is forwarding frames is demonstrably alive. Tying the read
// deadline to pongs alone dropped busy tunnels whenever one was lost or
// delayed, which surfaced to users as an unexplained reconnect mid-session.
func TestHostTunnelSurvivesSilentPongsWhileDataFlows(t *testing.T) {
	const budget = 300 * time.Millisecond
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
		ReadDeadline:  budget,
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, credential := provisionHost(t, httpServer.URL)
	base := "ws" + strings.TrimPrefix(httpServer.URL, "http")

	host := dialHostTunnel(t, base, hostID, credential)
	defer host.Close()
	// Never answer a ping, so only data can keep the tunnel alive.
	host.SetPingHandler(func(string) error { return nil })

	// Keep sending well past the silence budget. A frame for an unknown
	// connection is discarded by readLoop after the deadline is refreshed,
	// which is exactly the path under test.
	deadline := time.Now().Add(3 * budget)
	for time.Now().Before(deadline) {
		frame := encodeRelayFrame(relayFrame{Kind: frameData, Payload: []byte("output")})
		if err := host.WriteMessage(websocket.BinaryMessage, frame); err != nil {
			t.Fatalf("tunnel dropped while data was flowing: %v", err)
		}
		time.Sleep(budget / 4)
	}

	if _, ok := server.registry.host(hostID); !ok {
		t.Fatal("host record disappeared")
	}
	if server.registry.authorizedTunnel(hostID, 1) == nil {
		t.Fatal("tunnel was closed despite continuous inbound data")
	}
}

// The budget still applies: a genuinely silent tunnel must be reaped, or a
// half-open socket would live forever.
func TestHostTunnelStillDiesWhenFullySilent(t *testing.T) {
	const budget = 250 * time.Millisecond
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
		ReadDeadline:  budget,
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, credential := provisionHost(t, httpServer.URL)
	base := "ws" + strings.TrimPrefix(httpServer.URL, "http")

	host := dialHostTunnel(t, base, hostID, credential)
	defer host.Close()
	host.SetPingHandler(func(string) error { return nil })

	expired := false
	for attempt := 0; attempt < 40; attempt++ {
		time.Sleep(budget / 4)
		if server.registry.authorizedTunnel(hostID, 1) == nil {
			expired = true
			break
		}
	}
	if !expired {
		t.Fatal("a fully silent tunnel was never reaped")
	}
}

func dialHostTunnel(t *testing.T, base, hostID, credential string) *websocket.Conn {
	t.Helper()
	host, _, err := websocket.DefaultDialer.Dial(
		base+"/v1/host/connect?host_id="+hostID+"&version=2.0",
		map[string][]string{"Authorization": {"Bearer " + credential}},
	)
	if err != nil {
		t.Fatal(err)
	}
	typ, challengePayload, err := host.ReadMessage()
	if err != nil || typ != websocket.TextMessage {
		t.Fatalf("challenge: %d %v", typ, err)
	}
	var challenge relayChallenge
	if json.Unmarshal(challengePayload, &challenge) != nil {
		t.Fatal("invalid challenge")
	}
	proof := challengeProof(credential, canonicalChallenge(challenge, hostID))
	if err := host.WriteJSON(relayHello{
		Type: "host_hello", Version: "2.0", HostID: hostID,
		Capabilities: []string{"control", "http", "upgrade"}, Proof: proof,
	}); err != nil {
		t.Fatal(err)
	}
	typ, welcomePayload, err := host.ReadMessage()
	if err != nil || typ != websocket.TextMessage {
		t.Fatalf("welcome: %d %v", typ, err)
	}
	var welcome map[string]any
	if json.Unmarshal(welcomePayload, &welcome) != nil || welcome["t"] != "host_welcome" {
		t.Fatalf("invalid welcome: %s", welcomePayload)
	}
	return host
}
