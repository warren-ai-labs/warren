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

func TestOwnedRelayEnrollmentAndRefreshRotation(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000010"
	server, err := NewServer(Config{PublicURL: "https://relay.example.test", AdminToken: "admin-bootstrap", SigningKey: []byte("0123456789abcdef0123456789abcdef"), AllowedOrigin: "https://relay.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	ticket := provisionHostTicket(t, httpServer.URL, hostID)
	body, _ := json.Marshal(map[string]string{"enrollment_ticket": ticket, "host_secret": "daemon-secret"})
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/enroll", bytes.NewReader(body))
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("enroll: %v %v", response, err)
	}
	response.Body.Close()
	if !server.registry.authenticateHost(hostID, "daemon-secret") {
		t.Fatal("enrollment did not replace the bootstrap credential")
	}
	// Seed a live tunnel so pairing can be consumed.
	tunnel := &hostTunnel{clients: make(map[connectionID]*clientRoute), closed: make(chan struct{})}
	if !server.registry.connectHost(hostID, "Mac", "daemon-secret", tunnel) {
		t.Fatal("connect")
	}
	code, err := server.registry.beginPairing(hostID, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	pairBody, _ := json.Marshal(map[string]string{"host_id": hostID, "pairing_code": code})
	pairResponse, err := http.Post(httpServer.URL+"/v1/pair", "application/json", bytes.NewReader(pairBody))
	if err != nil || pairResponse.StatusCode != http.StatusCreated {
		t.Fatalf("pair: %v %v", pairResponse, err)
	}
	var paired struct {
		Ticket string `json:"pairing_ticket"`
	}
	_ = json.NewDecoder(pairResponse.Body).Decode(&paired)
	pairResponse.Body.Close()
	exchangeBody, _ := json.Marshal(map[string]string{"pairing_ticket": paired.Ticket, "client_id": "client-1"})
	exchange, err := http.Post(httpServer.URL+"/v1/session/exchange", "application/json", bytes.NewReader(exchangeBody))
	if err != nil || exchange.StatusCode != http.StatusOK {
		t.Fatalf("exchange: %v %v", exchange, err)
	}
	if exchange.Header.Get("Set-Cookie") == "" {
		t.Fatal("exchange did not set refresh cookie")
	}
	var exchanged struct {
		Access string `json:"access_token"`
	}
	_ = json.NewDecoder(exchange.Body).Decode(&exchanged)
	exchange.Body.Close()
	if _, err := server.signer.verify(exchanged.Access, hostID, "control"); err != nil {
		t.Fatalf("access token: %v", err)
	}
}

func TestOwnedRelayV2HostHandshake(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000011"
	server, err := NewServer(Config{PublicURL: "https://relay.example.test", AdminToken: "admin-bootstrap", SigningKey: []byte("0123456789abcdef0123456789abcdef"), AllowedOrigin: "https://relay.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	credential := provisionHost(t, httpServer.URL, hostID)
	base := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	host, _, err := websocket.DefaultDialer.Dial(base+"/v1/host/connect?host_id="+hostID+"&version=2.0", http.Header{"Authorization": []string{"Bearer " + credential}})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	typ, challengePayload, err := host.ReadMessage()
	if err != nil || typ != websocket.TextMessage {
		t.Fatalf("challenge: %d %v", typ, err)
	}
	// The challenge proof is verified by the server; read and answer it using
	// the same canonical representation as the connector.
	var challenge relayChallenge
	if json.Unmarshal(challengePayload, &challenge) != nil {
		t.Fatal("invalid challenge")
	}
	proof := challengeProof(credential, canonicalChallenge(challenge, hostID))
	if err := host.WriteJSON(relayHello{Type: "host_hello", Version: "2.0", HostID: hostID, Capabilities: []string{"control", "http", "upgrade"}, Proof: proof}); err != nil {
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
}

func TestOwnedRelayPublicHTTPRouteForwardsBRLY2Stream(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000012"
	server, err := NewServer(Config{PublicURL: "https://relay.example.test", AdminToken: "admin-bootstrap", SigningKey: []byte("0123456789abcdef0123456789abcdef"), AllowedOrigin: "https://relay.example.test", TunnelBaseDomain: "tunnel.example"})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	credential := provisionHost(t, httpServer.URL, hostID)
	base := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	host, _, err := websocket.DefaultDialer.Dial(base+"/v1/host/connect?host_id="+hostID+"&version=2.0", http.Header{"Authorization": []string{"Bearer " + credential}})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	_, challengePayload, err := host.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var challenge relayChallenge
	if json.Unmarshal(challengePayload, &challenge) != nil {
		t.Fatal("invalid challenge")
	}
	proof := challengeProof(credential, canonicalChallenge(challenge, hostID))
	if err := host.WriteJSON(relayHello{Type: "host_hello", Version: "2.0", HostID: hostID, Capabilities: []string{"control", "http", "upgrade"}, Proof: proof}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := host.ReadMessage(); err != nil {
		t.Fatal(err)
	}
	waitForHost(t, httpServer.URL, server, hostID)
	routeRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/route", strings.NewReader(`{"public_hostname":"public.example","auth_mode":"public"}`))
	routeRequest.Header.Set("Authorization", "Bearer admin-bootstrap")
	routeRequest.Header.Set("Content-Type", "application/json")
	routeResponse, err := http.DefaultClient.Do(routeRequest)
	if err != nil || routeResponse.StatusCode != http.StatusOK {
		t.Fatalf("route: %v %v", routeResponse, err)
	}
	routeResponse.Body.Close()
	publicRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/api/test", strings.NewReader("hello"))
	publicRequest.Host = "public.example"
	publicRequest.Header.Set("Authorization", "Bearer should-not-forward")
	result := make(chan *http.Response, 1)
	go func() {
		response, requestErr := http.DefaultClient.Do(publicRequest)
		if requestErr != nil {
			t.Errorf("public request: %v", requestErr)
			return
		}
		result <- response
	}()
	messageType, encodedOpen, err := host.ReadMessage()
	if err != nil || messageType != websocket.BinaryMessage {
		t.Fatalf("open: %v", err)
	}
	open, err := decodeRelayFrame(encodedOpen)
	if err != nil || open.Kind != frameOpen {
		t.Fatalf("invalid open: %v", err)
	}
	_, headersPayload, err := host.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if frameValue, err := decodeRelayFrame(headersPayload); err != nil || frameValue.Kind != frameHTTPHeaders {
		t.Fatalf("headers: %v", err)
	}
	host.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(relayFrame{Kind: frameHTTPHeaders, ConnectionID: open.ConnectionID, Payload: mustJSON(httpHeadersMessage{Status: http.StatusOK, Headers: [][2]string{{"Content-Type", "text/plain"}}})}))
	host.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(relayFrame{Kind: frameData, ConnectionID: open.ConnectionID, Payload: []byte("world")}))
	host.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(relayFrame{Kind: frameEnd, ConnectionID: open.ConnectionID}))
	response := <-result
	defer response.Body.Close()
	data := make([]byte, 16)
	count, _ := response.Body.Read(data)
	if response.StatusCode != http.StatusOK || string(data[:count]) != "world" {
		t.Fatalf("public response: status=%d body=%q", response.StatusCode, data[:count])
	}
}
