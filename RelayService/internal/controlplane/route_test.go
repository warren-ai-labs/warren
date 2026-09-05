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

func TestFilterHeadersPreservesWebSocketHopHeadersForUpgrade(t *testing.T) {
	header := http.Header{
		"Connection":               []string{"Upgrade"},
		"Upgrade":                  []string{"websocket"},
		"Sec-WebSocket-Key":        []string{"dGhlIHNhbXBsZSBub25jZQ=="},
		"Sec-WebSocket-Version":    []string{"13"},
		"Sec-WebSocket-Extensions": []string{"permessage-deflate; client_max_window_bits"},
		"X-Request-ID":             []string{"request-1"},
	}
	regular := filterHeaders(header, false)
	if hasHeaderPair(regular, "connection") || hasHeaderPair(regular, "upgrade") {
		t.Fatalf("regular HTTP forwarding retained hop headers: %#v", regular)
	}
	upgrade := filterHeaders(header, true)
	if !hasHeaderPair(upgrade, "connection") || !hasHeaderPair(upgrade, "upgrade") {
		t.Fatalf("WebSocket forwarding dropped required hop headers: %#v", upgrade)
	}
	if hasHeaderPair(upgrade, "sec-websocket-extensions") {
		t.Fatalf("WebSocket forwarding retained an unsupported extension offer: %#v", upgrade)
	}
	request := httptest.NewRequest(http.MethodGet, "http://relay.example/v1/ws", nil)
	for name, values := range header {
		for _, value := range values {
			request.Header.Add(name, value)
		}
	}
	if err := validateRequestHeaders(request, true); err != nil {
		t.Fatalf("valid browser extension offer was rejected: %v", err)
	}
}

func hasHeaderPair(headers [][2]string, name string) bool {
	for _, header := range headers {
		if strings.EqualFold(header[0], name) {
			return true
		}
	}
	return false
}

func TestRouteAddressUsesPathFallbackForIPRelay(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "http://192.0.2.10:8080",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "http://192.0.2.10:8080",
	})
	if err != nil {
		t.Fatal(err)
	}
	host, prefix := server.defaultRouteAddress("route-opaque")
	if host != "192.0.2.10" || prefix != "/t/route-opaque" {
		t.Fatalf("IP Relay route address = %q %q", host, prefix)
	}

	server.config.PublicURL = "https://relay.example.test:8443"
	host, prefix = server.defaultRouteAddress("route-opaque")
	if host != "route-opaque.tunnel.local" || prefix != "/" {
		t.Fatalf("domain Relay route address = %q %q", host, prefix)
	}
}

func TestRelayPublicPathPrefixIsPreservedInGeneratedURLs(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test/relay/",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if server.basePath != "/relay" {
		t.Fatalf("base path = %q, want /relay", server.basePath)
	}
	if got := server.publicPath("/h/host-id/"); got != "/relay/h/host-id/" {
		t.Fatalf("publicPath = %q", got)
	}
	if got := relayPublicOrigin(server.config.PublicURL); got != "https://relay.example.test" {
		t.Fatalf("public origin = %q", got)
	}
}

func TestRouteHostValidationAndPortNormalization(t *testing.T) {
	for _, hostname := range []string{"127.0.0.1", "192.0.2.10", "::1", "[::1]", "relay.example.test"} {
		if !validRouteHostname(hostname) {
			t.Errorf("validRouteHostname(%q) = false", hostname)
		}
	}
	for _, hostname := range []string{"127.0.0.1:8080", "[::1]:8080", "relay.example.test:443", "bad/name", "bad@name"} {
		if validRouteHostname(hostname) {
			t.Errorf("validRouteHostname(%q) = true", hostname)
		}
	}
	for input, want := range map[string]string{
		"127.0.0.1:8080":     "127.0.0.1",
		"[::1]:8443":         "::1",
		"[::1]":              "::1",
		"relay.example.test": "relay.example.test",
	} {
		if got := requestHostname(input); got != want {
			t.Errorf("requestHostname(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestIPRelayAllowsDistinctPathRoutesAndRejectsOverlap(t *testing.T) {
	registry, err := newRegistry("")
	if err != nil {
		t.Fatal(err)
	}
	keys, err := registry.createEnrollmentKeys(2, time.Hour, 1, "")
	if err != nil {
		t.Fatal(err)
	}
	hostOne, _, err := registry.claimHost(keys[0].Code, "one-secret", "one")
	if err != nil {
		t.Fatal(err)
	}
	hostTwo, _, err := registry.claimHost(keys[1].Code, "two-secret", "two")
	if err != nil {
		t.Fatal(err)
	}
	one := routeRecord{ID: "route-one", PublicHostname: "192.0.2.10", HostID: hostOne, Generation: 1, PathPrefix: "/t/route-one", AuthMode: "public", Enabled: true}
	two := routeRecord{ID: "route-two", PublicHostname: "192.0.2.10", HostID: hostTwo, Generation: 1, PathPrefix: "/t/route-two", AuthMode: "public", Enabled: true}
	if err := registry.setRoute(hostOne, &one); err != nil {
		t.Fatal(err)
	}
	if err := registry.setRoute(hostTwo, &two); err != nil {
		t.Fatalf("distinct IP routes conflicted: %v", err)
	}
	if _, ok := registry.findRoute("192.0.2.10:8080", "/t/route-two/health"); ok {
		// findRoute intentionally receives a normalized hostname; callers that
		// have a Host header must use requestHostname first.
		t.Fatal("findRoute accepted an unnormalized host: caller boundary leaked")
	}
	found, ok := registry.findRoute(requestHostname("192.0.2.10:8080"), "/t/route-two/health")
	if !ok || found.ID != two.ID {
		t.Fatalf("path route lookup = %#v, %v", found, ok)
	}
	overlap := two
	overlap.ID = "route-overlap"
	overlap.PathPrefix = "/t"
	if err := registry.setRoute(hostTwo, &overlap); err != errRouteConflict {
		t.Fatalf("overlapping path route error = %v, want %v", err, errRouteConflict)
	}
}

func TestPathRoutesStripConfiguredRoutePrefix(t *testing.T) {
	route := routeRecord{ID: "route-one", PathPrefix: "/t/route-one"}
	for input, value := range map[string]struct {
		want string
		ok   bool
	}{
		"/t/route-one":        {"/", true},
		"/t/route-one/health": {"/health", true},
		"/t/route-oneish":     {"/t/route-oneish", false},
		"/health":             {"/health", false},
	} {
		got, stripped := stripRoutePath(route, input)
		if got != value.want || stripped != value.ok {
			t.Errorf("stripRoutePath(%q) = %q, %v; want %q, %v", input, got, stripped, value.want, value.ok)
		}
	}
	plain := route
	plain.PathPrefix = "/"
	if got, stripped := stripRoutePath(plain, "/health"); got != "/health" || stripped {
		t.Fatalf("root route was stripped: %q, %v", got, stripped)
	}
	custom := routeRecord{ID: "route-custom", PathPrefix: "/workbench"}
	if got, stripped := stripRoutePath(custom, "/workbench/v1/ws"); got != "/v1/ws" || !stripped {
		t.Fatalf("custom route prefix was not stripped: %q, %v", got, stripped)
	}
}

func TestRoutePathPrefixRejectsRelayControlNamespaces(t *testing.T) {
	for _, prefix := range []string{
		"/healthz",
		"/v1",
		"/v1/public",
		"/h",
		"/h/custom",
		"/invite",
		"/assets",
		"/manifest.webmanifest",
		"/service-worker.js",
		"/favicon-16.png",
		"/icon-192.png",
		"/preset-claude.svg",
	} {
		if !routePathPrefixConflictsControlPlane(prefix) {
			t.Errorf("reserved route prefix %q was accepted", prefix)
		}
	}
	for _, prefix := range []string{"/", "/t/route", "/workbench", "/public/v1", "/hardened"} {
		if routePathPrefixConflictsControlPlane(prefix) {
			t.Errorf("safe route prefix %q was rejected", prefix)
		}
	}
}

func TestPublicRootRouteAdmitsOnlyWebSocketControlPath(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "http://127.0.0.1",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "http://127.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, _ := provisionHost(t, httpServer.URL)
	if err := server.registry.setRoute(hostID, &routeRecord{
		ID: "route-root", PublicHostname: "127.0.0.1", PathPrefix: "/",
		AuthMode: "public", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}

	upgrade := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/v1/ws", nil)
	upgrade.Host = "127.0.0.1"
	upgrade.Header.Set("Connection", "Upgrade")
	upgrade.Header.Set("Upgrade", "websocket")
	upgrade.Header.Set("Sec-WebSocket-Version", "13")
	upgrade.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	upgradeResponse := httptest.NewRecorder()
	server.publicRoute(upgradeResponse, upgrade)
	if upgradeResponse.Code != http.StatusServiceUnavailable {
		t.Fatalf("public root WebSocket status = %d, want host-offline %d", upgradeResponse.Code, http.StatusServiceUnavailable)
	}

	control := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/v1/settings", nil)
	control.Host = "127.0.0.1"
	controlResponse := httptest.NewRecorder()
	server.publicRoute(controlResponse, control)
	if controlResponse.Code != http.StatusNotFound {
		t.Fatalf("public root control API status = %d, want %d", controlResponse.Code, http.StatusNotFound)
	}
}

func TestPublicPathFallbackAdmitsOnlyWebSocketControlPath(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "http://127.0.0.1",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "http://127.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, _ := provisionHost(t, httpServer.URL)
	if err := server.registry.setRoute(hostID, &routeRecord{
		ID: "route-path", PublicHostname: "127.0.0.1", PathPrefix: "/t/route-path",
		AuthMode: "public", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}

	legacy := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/t/route-path?tab=terminal", nil)
	legacy.Host = "127.0.0.1"
	legacyResponse := httptest.NewRecorder()
	server.publicRoute(legacyResponse, legacy)
	if legacyResponse.Code != http.StatusPermanentRedirect {
		t.Fatalf("public path root without slash status = %d, want %d", legacyResponse.Code, http.StatusPermanentRedirect)
	}
	if location := legacyResponse.Header().Get("Location"); location != "/t/route-path/?tab=terminal" {
		t.Fatalf("public path root redirect location = %q", location)
	}

	control := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/t/route-path/v1/settings", nil)
	control.Host = "127.0.0.1"
	controlResponse := httptest.NewRecorder()
	server.publicRoute(controlResponse, control)
	if controlResponse.Code != http.StatusNotFound {
		t.Fatalf("public path fallback control API status = %d, want %d", controlResponse.Code, http.StatusNotFound)
	}

	upgrade := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/t/route-path/v1/ws", nil)
	upgrade.Host = "127.0.0.1"
	upgrade.Header.Set("Connection", "Upgrade")
	upgrade.Header.Set("Upgrade", "websocket")
	upgrade.Header.Set("Sec-WebSocket-Version", "13")
	upgrade.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	upgradeResponse := httptest.NewRecorder()
	server.publicRoute(upgradeResponse, upgrade)
	if upgradeResponse.Code != http.StatusServiceUnavailable {
		t.Fatalf("public path fallback WebSocket status = %d, want host-offline %d", upgradeResponse.Code, http.StatusServiceUnavailable)
	}
}

func TestIPRelayPathRouteForwardsApplicationPath(t *testing.T) {
	server, err := NewServer(Config{
		// The listener's actual port is intentionally absent here. The route
		// matches the request Host after its port is normalized.
		PublicURL:     "http://127.0.0.1",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "http://127.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, credential := provisionHost(t, httpServer.URL)
	websocketBase := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	host, _, err := websocket.DefaultDialer.Dial(websocketBase+"/v1/host/connect?host_id="+hostID+"&version=2.0", http.Header{"Authorization": []string{"Bearer " + credential}})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	_, challengePayload, err := host.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var challenge relayChallenge
	if err := json.Unmarshal(challengePayload, &challenge); err != nil {
		t.Fatal(err)
	}
	if err := host.WriteJSON(relayHello{Type: "host_hello", Version: "2.0", HostID: hostID, Capabilities: []string{"control", "http", "upgrade"}, Proof: challengeProof(credential, canonicalChallenge(challenge, hostID))}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := host.ReadMessage(); err != nil {
		t.Fatal(err)
	}
	waitForHost(t, httpServer.URL, server, hostID)

	configure, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/route", strings.NewReader(`{"auth_mode":"public"}`))
	configure.Header.Set("Authorization", "Bearer admin-bootstrap")
	configure.Header.Set("Content-Type", "application/json")
	configured, err := http.DefaultClient.Do(configure)
	if err != nil || configured.StatusCode != http.StatusOK {
		t.Fatalf("configure IP route: %v %v", configured, err)
	}
	var route routeRecord
	if err := json.NewDecoder(configured.Body).Decode(&route); err != nil {
		configured.Body.Close()
		t.Fatal(err)
	}
	configured.Body.Close()
	if route.PublicHostname != "127.0.0.1" || route.PathPrefix != "/t/"+route.ID {
		t.Fatalf("IP route defaults = %#v", route)
	}

	publicRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+route.PathPrefix+"/api/test", strings.NewReader("hello"))
	publicRequest.Header.Set("Authorization", "Bearer should-not-forward")
	result := make(chan *http.Response, 1)
	go func() {
		response, requestErr := http.DefaultClient.Do(publicRequest)
		if requestErr != nil {
			result <- nil
			return
		}
		result <- response
	}()

	messageType, encodedOpen, err := host.ReadMessage()
	if err != nil || messageType != websocket.BinaryMessage {
		t.Fatalf("open: type=%d err=%v", messageType, err)
	}
	open, err := decodeRelayFrame(encodedOpen)
	if err != nil || open.Kind != frameOpen {
		t.Fatalf("invalid open: %v", err)
	}
	_, encodedHeaders, err := host.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	headers, err := decodeRelayFrame(encodedHeaders)
	if err != nil || headers.Kind != frameHTTPHeaders {
		t.Fatalf("invalid request headers: %v", err)
	}
	var requestHeaders httpHeadersMessage
	if err := json.Unmarshal(headers.Payload, &requestHeaders); err != nil {
		t.Fatal(err)
	}
	if requestHeaders.Path != "/api/test" {
		t.Fatalf("path fallback leaked route prefix: %q", requestHeaders.Path)
	}
	if bytes.Contains(requestHeadersBytes(requestHeaders.Headers), []byte("should-not-forward")) {
		t.Fatal("route capability header was forwarded to Host")
	}
	_ = host.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(relayFrame{Kind: frameHTTPHeaders, ConnectionID: open.ConnectionID, Payload: mustJSON(httpHeadersMessage{Status: http.StatusOK, Headers: [][2]string{{"Content-Type", "text/plain"}}})}))
	_ = host.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(relayFrame{Kind: frameData, ConnectionID: open.ConnectionID, Payload: []byte("world")}))
	_ = host.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(relayFrame{Kind: frameEnd, ConnectionID: open.ConnectionID}))
	response := <-result
	if response == nil {
		t.Fatal("public request failed")
	}
	defer response.Body.Close()
	data := make([]byte, 16)
	count, _ := response.Body.Read(data)
	if response.StatusCode != http.StatusOK || string(data[:count]) != "world" {
		t.Fatalf("public response: status=%d body=%q", response.StatusCode, data[:count])
	}
}

func requestHeadersBytes(headers [][2]string) []byte {
	var result []byte
	for _, pair := range headers {
		result = append(result, pair[0]...)
		result = append(result, '=')
		result = append(result, pair[1]...)
	}
	return result
}
