package controlplane

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestPairingWindowDefaultsToSevenDays(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	const expected = 7 * 24 * time.Hour
	if server.config.PairingTTL != expected || server.config.PairingTicketTTL != expected {
		t.Fatalf("pairing windows = %s/%s, want %s", server.config.PairingTTL, server.config.PairingTicketTTL, expected)
	}

	custom, err := NewServer(Config{
		PublicURL:        "https://relay.example.test",
		AdminToken:       "admin-bootstrap",
		SigningKey:       []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin:    "https://relay.example.test",
		PairingTTL:       3 * 24 * time.Hour,
		PairingTicketTTL: 72 * time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	if custom.config.PairingTTL != 3*24*time.Hour || custom.config.PairingTicketTTL != 72*time.Hour {
		t.Fatalf("custom pairing windows = %s/%s", custom.config.PairingTTL, custom.config.PairingTicketTTL)
	}
}

func TestPairingDiscoveryAndBidirectionalRelay(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
		PairingTTL:    time.Minute,
		AccessTTL:     time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	websocketBase := "ws" + strings.TrimPrefix(httpServer.URL, "http")

	hostID, hostCredential := provisionHost(t, httpServer.URL)
	host := dialV2Host(t, websocketBase, hostID, hostCredential, "Mac")
	defer host.Close()
	waitForHost(t, httpServer.URL, server, hostID)

	pairingRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/pairing", nil)
	pairingRequest.Header.Set("Authorization", "Bearer admin-bootstrap")
	pairingResponse, err := http.DefaultClient.Do(pairingRequest)
	if err != nil || pairingResponse.StatusCode != http.StatusCreated {
		t.Fatalf("pairing start: response=%v err=%v", pairingResponse, err)
	}
	var pairing struct {
		Code string `json:"pairing_code"`
	}
	if json.NewDecoder(pairingResponse.Body).Decode(&pairing) != nil || pairing.Code == "" {
		t.Fatal("missing pairing code")
	}
	pairingResponse.Body.Close()

	body, _ := json.Marshal(map[string]string{"host_id": hostID, "pairing_code": pairing.Code})
	pairResponse, err := http.Post(httpServer.URL+"/v1/pair", "application/json", bytes.NewReader(body))
	if err != nil || pairResponse.StatusCode != http.StatusCreated {
		t.Fatalf("pair: response=%v err=%v", pairResponse, err)
	}
	var paired struct {
		Token         string `json:"access_token"`
		WebURL        string `json:"web_url"`
		PairingURL    string `json:"pairing_url"`
		InviteID      string `json:"invite_id"`
		PairingTicket string `json:"pairing_ticket"`
	}
	if json.NewDecoder(pairResponse.Body).Decode(&paired) != nil || paired.Token == "" || paired.PairingTicket == "" {
		t.Fatal("missing access token")
	}
	pairResponse.Body.Close()
	if paired.WebURL != paired.PairingURL || paired.InviteID == "" || !strings.Contains(paired.WebURL, "/invite/") || strings.Contains(paired.WebURL, hostID) {
		t.Fatalf("unexpected opaque pairing URL: %#v", paired)
	}

	// A pairing code is intentionally reusable during its TTL so one generated
	// link can be shared with more than one client. A new code still replaces
	// the previous code, and Host revocation/re-enrollment invalidates it.
	reused, err := http.Post(httpServer.URL+"/v1/pair", "application/json", bytes.NewReader(body))
	if err != nil || reused.StatusCode != http.StatusCreated {
		t.Fatalf("pairing code could not provision a second client: response=%v err=%v", reused, err)
	}
	reused.Body.Close()

	// Rotating the pairing code also fences tickets issued from the previous
	// code. Existing short-lived access capabilities remain usable until their
	// normal expiry, but an old QR/link cannot create another session.
	rotatedRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/pairing", nil)
	rotatedRequest.Header.Set("Authorization", "Bearer admin-bootstrap")
	rotatedResponse, err := http.DefaultClient.Do(rotatedRequest)
	if err != nil || rotatedResponse.StatusCode != http.StatusCreated {
		t.Fatalf("rotate pairing code: response=%v err=%v", rotatedResponse, err)
	}
	rotatedResponse.Body.Close()
	oldTicketBody, _ := json.Marshal(map[string]string{"pairing_ticket": paired.PairingTicket})
	oldTicketResponse, err := http.Post(httpServer.URL+"/v1/session/exchange", "application/json", bytes.NewReader(oldTicketBody))
	if err != nil || oldTicketResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("old pairing ticket remained valid: response=%v err=%v", oldTicketResponse, err)
	}
	oldTicketResponse.Body.Close()

	client, _, err := websocket.DefaultDialer.Dial(
		websocketBase+"/v1/client/connect",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.WriteJSON(map[string]string{"t": "auth", "version": "2.0", "access_token": paired.Token}); err != nil {
		t.Fatal(err)
	}

	messageType, encodedOpen, err := host.ReadMessage()
	if err != nil || messageType != websocket.BinaryMessage {
		t.Fatalf("read open: type=%d err=%v", messageType, err)
	}
	open, err := decodeRelayFrame(encodedOpen)
	if err != nil || open.Kind != frameOpen {
		t.Fatalf("invalid open frame: %#v %v", open, err)
	}
	_, encodedAuth, err := host.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	authFrame, err := decodeRelayFrame(encodedAuth)
	if err != nil || authFrame.Kind != frameText || authFrame.ConnectionID != open.ConnectionID || !bytes.Contains(authFrame.Payload, []byte(paired.Token)) {
		t.Fatalf("bad auth relay: %#v %v", authFrame, err)
	}

	if err := client.WriteMessage(websocket.TextMessage, []byte(`{"t":"resize"}`)); err != nil {
		t.Fatal(err)
	}
	_, encodedText, err := host.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	textFrame, err := decodeRelayFrame(encodedText)
	if err != nil || textFrame.Kind != frameText || textFrame.ConnectionID != open.ConnectionID || string(textFrame.Payload) != `{"t":"resize"}` {
		t.Fatalf("bad client-to-host relay: %#v %v", textFrame, err)
	}

	binaryPayload := []byte{0, 1, 2, 255}
	if err := host.WriteMessage(websocket.BinaryMessage, encodeRelayFrame(relayFrame{
		Kind: frameBinary, ConnectionID: open.ConnectionID, Payload: binaryPayload,
	})); err != nil {
		t.Fatal(err)
	}
	clientType, clientPayload, err := client.ReadMessage()
	if err != nil || clientType != websocket.BinaryMessage || !bytes.Equal(clientPayload, binaryPayload) {
		t.Fatalf("bad host-to-client relay: type=%d payload=%v err=%v", clientType, clientPayload, err)
	}
}

func TestEnrollmentKeyBatchReturnsSettingsLinksWithoutHostSecrets(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test/relay/?ignored=deployment-metadata",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()

	body := bytes.NewBufferString(`{"count":2,"ttl":"2h","max_uses":1,"label":"macs"}`)
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/admin/enrollment-keys", body)
	request.Header.Set("Authorization", "Bearer admin-bootstrap")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusCreated {
		t.Fatalf("create enrollment keys: response=%v err=%v", response, err)
	}
	if response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("enrollment key response cache control = %q, want no-store", response.Header.Get("Cache-Control"))
	}
	defer response.Body.Close()
	var result struct {
		Keys []struct {
			ID        string `json:"id"`
			Code      string `json:"key"`
			Label     string `json:"label"`
			ExpiresAt string `json:"expires_at"`
			MaxUses   int    `json:"max_uses"`
			UsedUses  int    `json:"used_uses"`
			Settings  string `json:"settings_url"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if len(result.Keys) != 2 {
		t.Fatalf("created %d enrollment keys, want 2", len(result.Keys))
	}
	seen := make(map[string]bool)
	for _, key := range result.Keys {
		if key.ID == "" || key.Code == "" || seen[key.Code] || key.Label != "macs" || key.ExpiresAt == "" || key.MaxUses != 1 || key.UsedUses != 0 {
			t.Fatalf("invalid enrollment key response: %#v", key)
		}
		seen[key.Code] = true
		if len(strings.ReplaceAll(key.Code, "-", "")) != enrollmentCodeLength || strings.Count(key.Code, "-") != 3 {
			t.Fatalf("enrollment key is not formatted as XXXX-XXXX-XXXX-XXXX: %q", key.Code)
		}
		parsed, err := url.Parse(key.Settings)
		if err != nil || parsed.Scheme != "warren" || parsed.Host != "settings" {
			t.Fatalf("invalid settings link: %q (%v)", key.Settings, err)
		}
		query := parsed.Query()
		if query.Get("section") != "relay" || query.Get("relayUrl") != "https://relay.example.test/relay" || query.Get("enrollmentKey") != key.Code {
			t.Fatalf("settings link query mismatch: %v", query)
		}
		for _, forbidden := range []string{"hostId", "enrollmentTicket", "relayKeyId", "relayPublicKey", "setup_url"} {
			if query.Get(forbidden) != "" || strings.Contains(parsed.RawQuery, forbidden) {
				t.Fatalf("settings link retained legacy field %q: %q", forbidden, parsed.RawQuery)
			}
		}
		if strings.Contains(parsed.RawQuery, "ignored") {
			t.Fatalf("settings link retained deployment query: %q", parsed.RawQuery)
		}
	}
}

func TestEnrollmentKeyClaimCreatesRelayOwnedHost(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	key := createEnrollmentKey(t, httpServer.URL)
	body := bytes.NewBufferString(`{"enrollment_key":"` + key + `","host_secret":"daemon-secret","name":"Mac"}`)
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/claim", body)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("claim status = %d, want %d", response.StatusCode, http.StatusOK)
	}
	var result struct {
		HostID     string `json:"host_id"`
		Generation uint64 `json:"generation"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil || !validHostID(result.HostID) || result.Generation != 1 {
		t.Fatalf("invalid claim response: %#v (%v)", result, err)
	}
	if len(server.registry.hosts) != 1 {
		t.Fatalf("claim created %d hosts, want 1", len(server.registry.hosts))
	}
	// The same daemon may retry after losing the response. It gets the same
	// Relay-owned identity without consuming another key.
	retry := bytes.NewBufferString(`{"enrollment_key":"` + key + `","host_secret":"daemon-secret","name":"Renamed"}`)
	retryRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/claim", retry)
	retryRequest.Header.Set("Content-Type", "application/json")
	retryResponse, err := http.DefaultClient.Do(retryRequest)
	if err != nil || retryResponse.StatusCode != http.StatusOK {
		t.Fatalf("idempotent claim status = %v (%v)", retryResponse, err)
	}
	retryResponse.Body.Close()
	if host, ok := server.registry.host(result.HostID); !ok || host.Name != "Renamed" {
		t.Fatalf("idempotent claim did not update host name: %#v", host)
	}
}

func TestLegacyHostProvisioningEndpointsAreRemoved(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	for _, endpoint := range []string{
		httpServer.URL + "/v1/hosts",
		httpServer.URL + "/v1/hosts/00000000-0000-4000-8000-000000000001/enroll",
	} {
		request, _ := http.NewRequest(http.MethodPost, endpoint, strings.NewReader(`{}`))
		request.Header.Set("Authorization", "Bearer admin-bootstrap")
		request.Header.Set("Content-Type", "application/json")
		response, requestErr := http.DefaultClient.Do(request)
		if requestErr != nil {
			t.Fatal(requestErr)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusNotFound {
			t.Fatalf("legacy endpoint %s status = %d, want %d", endpoint, response.StatusCode, http.StatusNotFound)
		}
	}
}

func TestAuthenticationAndHostOfflineContracts(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000007"
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()

	response, err := http.Post(httpServer.URL+"/v1/hosts/missing/pairing", "application/json", nil)
	if err != nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("admin endpoint accepted missing credential: response=%v err=%v", response, err)
	}
	response.Body.Close()

	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/missing/pairing", nil)
	request.Header.Set("Authorization", "Bearer admin-bootstrap")
	response, err = http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusConflict {
		t.Fatalf("offline host pairing: response=%v err=%v", response, err)
	}
	response.Body.Close()

	response, err = http.Get(httpServer.URL + "/h/" + hostID + "/")
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("web shell unavailable: response=%v err=%v", response, err)
	}
	var page bytes.Buffer
	_, _ = page.ReadFrom(response.Body)
	response.Body.Close()
	if !strings.Contains(page.String(), `name="warren-relay-host-id" content="`+hostID+`"`) {
		t.Fatal("relay host ID was not injected into web shell")
	}
	if !strings.Contains(page.String(), `/h/`+hostID+`/assets/app.js`) {
		t.Fatal("relay web shell did not scope the Vite bundle to its host route")
	}
	for _, resource := range []string{
		"apple-touch-icon.png",
		"icon.svg",
		"preset-claude.svg",
		"preset-codex-white.svg",
		"preset-codex.svg",
		"preset-shell.svg",
	} {
		if !strings.Contains(page.String(), `/h/`+hostID+`/`+resource) {
			t.Fatalf("relay web shell did not scope %s to its host route", resource)
		}
	}
	for resource := range webStaticResources {
		staticResponse, err := http.Get(httpServer.URL + "/h/" + hostID + "/" + resource)
		if err != nil || staticResponse.StatusCode != http.StatusOK {
			t.Fatalf("host static resource %s unavailable: response=%v err=%v", resource, staticResponse, err)
		}
		staticResponse.Body.Close()
	}
	assetResponse, err := http.Get(httpServer.URL + "/h/" + hostID + "/assets/app.js")
	if err != nil || assetResponse.StatusCode != http.StatusOK || !strings.Contains(assetResponse.Header.Get("Content-Type"), "javascript") {
		t.Fatalf("host Vite asset unavailable: response=%v err=%v", assetResponse, err)
	}
	assetResponse.Body.Close()
	manifestResponse, err := http.Get(httpServer.URL + "/h/" + hostID + "/manifest.webmanifest")
	if err != nil || manifestResponse.StatusCode != http.StatusOK {
		t.Fatalf("host manifest unavailable: response=%v err=%v", manifestResponse, err)
	}
	var manifest map[string]any
	if json.NewDecoder(manifestResponse.Body).Decode(&manifest) != nil {
		t.Fatal("invalid host manifest")
	}
	manifestResponse.Body.Close()
	expectedScope := "/h/" + hostID + "/"
	if manifest["start_url"] != expectedScope || manifest["scope"] != expectedScope {
		t.Fatalf("host PWA lost scope: %#v", manifest)
	}
	workerResponse, err := http.Get(httpServer.URL + "/h/" + hostID + "/service-worker.js")
	if err != nil || workerResponse.StatusCode != http.StatusOK || workerResponse.Header.Get("Service-Worker-Allowed") != expectedScope {
		t.Fatalf("host service worker unavailable: response=%v err=%v", workerResponse, err)
	}
	workerResponse.Body.Close()

	inviteID := "opaque-test"
	inviteResponse, err := http.Get(httpServer.URL + "/invite/" + inviteID + "/")
	if err != nil || inviteResponse.StatusCode != http.StatusOK {
		t.Fatalf("invite web shell unavailable: response=%v err=%v", inviteResponse, err)
	}
	var invitePage bytes.Buffer
	_, _ = invitePage.ReadFrom(inviteResponse.Body)
	inviteResponse.Body.Close()
	if !strings.Contains(invitePage.String(), `name="warren-relay-invite-id" content="`+inviteID+`"`) {
		t.Fatal("opaque invite was not injected into web shell")
	}
	if strings.Contains(invitePage.String(), hostID) {
		t.Fatal("opaque invite page exposed a Host ID")
	}
	if !strings.Contains(invitePage.String(), `/invite/`+inviteID+`/assets/app.js`) {
		t.Fatal("invite web shell did not scope the Vite bundle")
	}
	inviteManifestResponse, err := http.Get(httpServer.URL + "/invite/" + inviteID + "/manifest.webmanifest")
	if err != nil || inviteManifestResponse.StatusCode != http.StatusOK {
		t.Fatalf("invite manifest unavailable: response=%v err=%v", inviteManifestResponse, err)
	}
	var inviteManifest map[string]any
	if json.NewDecoder(inviteManifestResponse.Body).Decode(&inviteManifest) != nil {
		t.Fatal("invalid invite manifest")
	}
	inviteManifestResponse.Body.Close()
	expectedInviteScope := "/invite/" + inviteID + "/"
	if inviteManifest["start_url"] != expectedInviteScope || inviteManifest["scope"] != expectedInviteScope {
		t.Fatalf("invite PWA lost scope: %#v", inviteManifest)
	}
}

func TestHostCredentialCanInspectAndPairOnlyItsOwnHost(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	websocketBase := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	hostID, hostCredential := provisionHost(t, httpServer.URL)
	otherHostID, _ := provisionHost(t, httpServer.URL)
	host := dialV2Host(t, websocketBase, hostID, hostCredential, "")
	defer host.Close()
	waitForHost(t, httpServer.URL, server, hostID)

	for _, endpoint := range []string{
		"/v1/hosts/" + hostID,
		"/v1/hosts/" + hostID + "/pairing",
	} {
		method := http.MethodGet
		if strings.HasSuffix(endpoint, "/pairing") {
			method = http.MethodPost
		}
		request, _ := http.NewRequest(method, httpServer.URL+endpoint, nil)
		request.Header.Set("Authorization", "Bearer "+hostCredential)
		response, err := http.DefaultClient.Do(request)
		if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
			t.Fatalf("own Host endpoint rejected credential: endpoint=%s response=%v err=%v", endpoint, response, err)
		}
		response.Body.Close()
	}

	request, _ := http.NewRequest(http.MethodGet, httpServer.URL+"/v1/hosts/"+otherHostID, nil)
	request.Header.Set("Authorization", "Bearer "+hostCredential)
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("Host credential crossed Host boundary: response=%v err=%v", response, err)
	}
	response.Body.Close()
}

func TestClaimRejectsUnknownEnrollmentFields(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	body, _ := json.Marshal(map[string]string{"id": "local-default-host", "name": "Mac"})
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/claim", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusBadRequest {
		t.Fatalf("unknown claim fields status = %v, want %d", response, http.StatusBadRequest)
	}
	response.Body.Close()
}

func TestRelayRequiresBRLY2HostConnection(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, credential := provisionHost(t, httpServer.URL)
	websocketBase := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	_, response, err := websocket.DefaultDialer.Dial(
		websocketBase+"/v1/host/connect?host_id="+hostID,
		http.Header{"Authorization": []string{"Bearer " + credential}},
	)
	if err == nil || response == nil || response.StatusCode != http.StatusUpgradeRequired {
		t.Fatalf("legacy host connection was accepted: response=%v err=%v", response, err)
	}
	response.Body.Close()
}

func TestRelayClaimRejectsLegacyEnrollmentFields(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	body, _ := json.Marshal(map[string]string{
		"enrollment_ticket": "legacy-ticket",
		"token":             "daemon-secret",
	})
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/claim", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("legacy enrollment field status = %d, want %d", response.StatusCode, http.StatusBadRequest)
	}
}

func TestNewServerRequiresAllowedOrigin(t *testing.T) {
	if _, err := NewServer(Config{
		PublicURL:  "https://relay.example.test",
		AdminToken: "admin-bootstrap",
		SigningKey: []byte("0123456789abcdef0123456789abcdef"),
	}); err == nil {
		t.Fatal("server accepted an empty AllowedOrigin")
	}
}

func TestBrowserOriginRestrictionDoesNotBlockHostConnector(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	websocketBase := "ws" + strings.TrimPrefix(httpServer.URL, "http")

	hostID, hostCredential := provisionHost(t, httpServer.URL)
	host := dialV2Host(t, websocketBase, hostID, hostCredential, "")
	defer host.Close()

	client, response, err := websocket.DefaultDialer.Dial(
		websocketBase+"/v1/client/connect",
		http.Header{"Origin": []string{"https://attacker.example"}},
	)
	if client != nil {
		client.Close()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusForbidden {
		t.Fatalf("browser Origin was not rejected: response=%v err=%v", response, err)
	}
	response.Body.Close()
}

func TestRegistryPersistsCredentialsAndRevocationInvalidatesAccess(t *testing.T) {
	dataURL := t.TempDir() + "/registry.json"
	config := Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
		DataURL:       dataURL,
		PairingTTL:    time.Minute,
		AccessTTL:     time.Hour,
	}
	server, err := NewServer(config)
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	durableHostID, hostCredential := provisionHost(t, httpServer.URL)
	_, otherCredential := provisionHost(t, httpServer.URL)
	if server.registry.authenticateHost(durableHostID, otherCredential) {
		t.Fatal("credential from another Host was accepted")
	}
	info, err := os.Stat(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("registry permission=%v", info.Mode().Perm())
	}
	httpServer.Close()

	restarted, err := NewServer(config)
	if err != nil {
		t.Fatal(err)
	}
	if !restarted.registry.authenticateHost(durableHostID, hostCredential) {
		t.Fatal("provisioned host credential did not survive restart")
	}
	generation, ok := restarted.registry.generation(durableHostID)
	if !ok {
		t.Fatal("host generation missing after restart")
	}
	accessToken, err := restarted.signer.issue(durableHostID, "control", generation, time.Hour)
	if err != nil || !restarted.authorizeAccess(accessToken, durableHostID) {
		t.Fatal("valid access token rejected")
	}
	if err := restarted.registry.revokeHost(durableHostID); err != nil {
		t.Fatal(err)
	}
	if restarted.registry.authenticateHost(durableHostID, hostCredential) {
		t.Fatal("revoked host credential remained valid")
	}
	if restarted.authorizeAccess(accessToken, durableHostID) {
		t.Fatal("revocation did not invalidate issued access token")
	}
}

func TestPairingInviteSurvivesRelayRestartAndStoresOnlyHash(t *testing.T) {
	dataURL := t.TempDir() + "/registry.json"
	config := Config{
		PublicURL:        "https://relay.example.test",
		AdminToken:       "admin-bootstrap",
		SigningKey:       []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin:    "https://relay.example.test",
		DataURL:          dataURL,
		PairingTTL:       time.Hour,
		PairingTicketTTL: 24 * time.Hour,
		AccessTTL:        time.Hour,
	}
	server, err := NewServer(config)
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	websocketBase := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	hostID, hostCredential := provisionHost(t, httpServer.URL)
	host := dialV2Host(t, websocketBase, hostID, hostCredential, "Mac")
	waitForHost(t, httpServer.URL, server, hostID)

	startRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/pairing", nil)
	startRequest.Header.Set("Authorization", "Bearer admin-bootstrap")
	startResponse, err := http.DefaultClient.Do(startRequest)
	if err != nil || startResponse.StatusCode != http.StatusCreated {
		t.Fatalf("start pairing: response=%v err=%v", startResponse, err)
	}
	var started struct {
		Code string `json:"pairing_code"`
	}
	if json.NewDecoder(startResponse.Body).Decode(&started) != nil || started.Code == "" {
		t.Fatal("missing pairing code")
	}
	startResponse.Body.Close()
	pairBody, _ := json.Marshal(map[string]string{"host_id": hostID, "pairing_code": started.Code})
	pairResponse, err := http.Post(httpServer.URL+"/v1/pair", "application/json", bytes.NewReader(pairBody))
	if err != nil || pairResponse.StatusCode != http.StatusCreated {
		t.Fatalf("pair: response=%v err=%v", pairResponse, err)
	}
	var paired struct {
		InviteID      string `json:"invite_id"`
		PairingTicket string `json:"pairing_ticket"`
		WebURL        string `json:"web_url"`
	}
	if json.NewDecoder(pairResponse.Body).Decode(&paired) != nil {
		t.Fatal("invalid pairing response")
	}
	pairResponse.Body.Close()
	if paired.InviteID == "" || paired.InviteID != paired.PairingTicket || strings.Contains(paired.WebURL, hostID) {
		t.Fatalf("pairing response disclosed Host identity: %#v", paired)
	}
	data, err := os.ReadFile(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte(paired.InviteID)) || bytes.Contains(data, []byte(paired.PairingTicket)) {
		t.Fatal("registry persisted the clear-text pairing invite")
	}

	host.Close()
	waitForHostOffline(t, server, hostID)
	httpServer.Close()
	restarted, err := NewServer(config)
	if err != nil {
		t.Fatal(err)
	}
	restartedHTTP := httptest.NewServer(restarted)
	defer restartedHTTP.Close()
	restartedBase := "ws" + strings.TrimPrefix(restartedHTTP.URL, "http")
	reconnectedHost := dialV2Host(t, restartedBase, hostID, hostCredential, "Mac")
	waitForHost(t, restartedHTTP.URL, restarted, hostID)

	exchangeBody, _ := json.Marshal(map[string]string{"invite_id": paired.InviteID})
	for attempt := 0; attempt < 2; attempt++ {
		exchangeURL := restartedHTTP.URL + "/invite/" + url.PathEscape(paired.InviteID) + "/v1/session/exchange"
		exchange, exchangeErr := http.Post(exchangeURL, "application/json", bytes.NewReader(exchangeBody))
		if exchangeErr != nil || exchange.StatusCode != http.StatusOK {
			t.Fatalf("exchange after restart (attempt %d): response=%v err=%v", attempt+1, exchange, exchangeErr)
		}
		var result struct {
			HostID string `json:"host_id"`
		}
		if json.NewDecoder(exchange.Body).Decode(&result) != nil || result.HostID != hostID {
			t.Fatalf("invalid exchange after restart: %#v", result)
		}
		exchange.Body.Close()
	}
	reconnectedHost.Close()
	waitForHostOffline(t, restarted, hostID)
}

func TestPairingCodeExpires(t *testing.T) {
	registry, err := newRegistry("")
	if err != nil {
		t.Fatal(err)
	}
	const credential = "daemon-secret-pairing-expiry"
	keys, err := registry.createEnrollmentKeys(1, time.Hour, 1, "")
	if err != nil {
		t.Fatal(err)
	}
	hostID, _, err := registry.claimHost(keys[0].Code, credential, "Mac")
	if err != nil || !registry.authenticateHost(hostID, credential) {
		t.Fatalf("claim failed: %v", err)
	}
	tunnel := &hostTunnel{clients: make(map[connectionID]*clientRoute), closed: make(chan struct{})}
	if !registry.connectHost(hostID, "Mac", credential, tunnel) {
		t.Fatal("authenticated host did not connect")
	}
	current := time.Now()
	registry.now = func() time.Time { return current }
	code, err := registry.beginPairing(hostID, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	current = current.Add(time.Minute + time.Nanosecond)
	if _, _, err := registry.consumePairing(hostID, code); err == nil {
		t.Fatal("expired pairing code was accepted")
	}
}

func TestRegistrySkipsMalformedPersistedRecords(t *testing.T) {
	dataURL := t.TempDir() + "/registry.json"
	malformed := `{"hosts":[null,{"id":"not-a-uuid"}],"invites":[null,{"id_hash":"","host_id":"not-a-uuid"}]}`
	if err := os.WriteFile(dataURL, []byte(malformed), 0o600); err != nil {
		t.Fatal(err)
	}
	registry, err := newRegistry(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	if len(registry.hosts) != 0 || len(registry.invites) != 0 {
		t.Fatalf("malformed registry records were loaded: hosts=%d invites=%d", len(registry.hosts), len(registry.invites))
	}
}

func TestClaimsCreateIndependentHostsWithoutCredentialRotation(t *testing.T) {
	registry, err := newRegistry("")
	if err != nil {
		t.Fatal(err)
	}
	keys, err := registry.createEnrollmentKeys(2, time.Hour, 1, "")
	if err != nil {
		t.Fatal(err)
	}
	const oldCredential = "daemon-secret-old"
	hostID, _, err := registry.claimHost(keys[0].Code, oldCredential, "Mac")
	if err != nil {
		t.Fatal(err)
	}
	// A second claim with a different secret creates a separate Host. It must
	// never rotate the credential or publish a stale tunnel for the first Host.
	const newCredential = "daemon-secret-new"
	otherHostID, _, err := registry.claimHost(keys[1].Code, newCredential, "Mac 2")
	if err != nil || otherHostID == hostID {
		t.Fatalf("second claim did not create an independent Host: %s %v", otherHostID, err)
	}
	staleTunnel := &hostTunnel{clients: make(map[connectionID]*clientRoute), closed: make(chan struct{})}
	if !registry.connectHost(hostID, "Mac", oldCredential, staleTunnel) {
		t.Fatal("first Host credential was rejected")
	}
	currentTunnel := &hostTunnel{clients: make(map[connectionID]*clientRoute), closed: make(chan struct{})}
	if !registry.connectHost(otherHostID, "Mac 2", newCredential, currentTunnel) {
		t.Fatal("current credential could not publish second Host tunnel")
	}
	generation, ok := registry.generation(otherHostID)
	if !ok || registry.authorizedTunnel(otherHostID, generation) != currentTunnel {
		t.Fatal("current generation could not resolve its Host tunnel")
	}
	if registry.authorizedTunnel(otherHostID, generation-1) != nil {
		t.Fatal("old access generation resolved the current Host tunnel")
	}
}

func TestRegistryMutationRollsBackWhenPersistenceFails(t *testing.T) {
	dataURL := t.TempDir() + "/registry.json"
	registry, err := newRegistry(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	const credential = "daemon-secret-persistence"
	keys, err := registry.createEnrollmentKeys(1, time.Hour, 1, "")
	if err != nil {
		t.Fatal(err)
	}
	hostID, _, err := registry.claimHost(keys[0].Code, credential, "Mac")
	if err != nil {
		t.Fatal(err)
	}
	// Renaming a file over this existing directory fails on every supported
	// platform, deterministically exercising the registry transaction rollback.
	registry.dataURL = t.TempDir()
	if err := registry.revokeHost(hostID); err == nil {
		t.Fatal("revoke unexpectedly succeeded when persistence failed")
	}
	if !registry.authenticateHost(hostID, credential) {
		t.Fatal("failed revoke changed the in-memory credential")
	}
	if _, err := registry.createEnrollmentKeys(1, time.Hour, 1, ""); err == nil {
		t.Fatal("key creation unexpectedly succeeded when persistence failed")
	}
}

func provisionHost(t *testing.T, base string) (string, string) {
	t.Helper()
	key := createEnrollmentKey(t, base)
	secret, err := randomToken(24)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"enrollment_key": key, "host_secret": secret, "name": "Mac"})
	request, _ := http.NewRequest(http.MethodPost, base+"/v1/hosts/claim", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("claim host: response=%v err=%v", response, err)
	}
	var result struct {
		HostID string `json:"host_id"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil || !validHostID(result.HostID) {
		response.Body.Close()
		t.Fatalf("invalid claim response: %#v (%v)", result, err)
	}
	response.Body.Close()
	return result.HostID, secret
}

func createEnrollmentKey(t *testing.T, base string) string {
	t.Helper()
	request, _ := http.NewRequest(http.MethodPost, base+"/v1/admin/enrollment-keys", strings.NewReader(`{"count":1}`))
	request.Header.Set("Authorization", "Bearer admin-bootstrap")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusCreated {
		t.Fatalf("create enrollment key: response=%v err=%v", response, err)
	}
	defer response.Body.Close()
	var result struct {
		Keys []struct {
			Code string `json:"key"`
		} `json:"keys"`
	}
	if json.NewDecoder(response.Body).Decode(&result) != nil || len(result.Keys) != 1 || result.Keys[0].Code == "" {
		t.Fatalf("invalid enrollment key response: %#v", result)
	}
	return result.Keys[0].Code
}

func dialV2Host(t *testing.T, websocketBase, hostID, credential, name string) *websocket.Conn {
	t.Helper()
	endpoint := websocketBase + "/v1/host/connect?host_id=" + hostID + "&version=2.0"
	if name != "" {
		endpoint += "&name=" + url.QueryEscape(name)
	}
	host, _, err := websocket.DefaultDialer.Dial(endpoint, http.Header{"Authorization": []string{"Bearer " + credential}})
	if err != nil {
		t.Fatal(err)
	}
	typ, payload, err := host.ReadMessage()
	if err != nil || typ != websocket.TextMessage {
		host.Close()
		t.Fatalf("relay challenge: type=%d err=%v", typ, err)
	}
	var challenge relayChallenge
	if err := json.Unmarshal(payload, &challenge); err != nil || challenge.Type != "relay_challenge" || challenge.Version != "2.0" {
		host.Close()
		t.Fatalf("invalid relay challenge: %v %s", err, payload)
	}
	if err := host.WriteJSON(relayHello{
		Type: "host_hello", Version: "2.0", HostID: hostID,
		Capabilities: []string{"control", "http", "upgrade"},
		Proof:        challengeProof(credential, canonicalChallenge(challenge, hostID)),
	}); err != nil {
		host.Close()
		t.Fatal(err)
	}
	typ, payload, err = host.ReadMessage()
	if err != nil || typ != websocket.TextMessage {
		host.Close()
		t.Fatalf("relay welcome: type=%d err=%v", typ, err)
	}
	var welcome struct {
		Type       string `json:"t"`
		Version    string `json:"version"`
		Generation uint64 `json:"generation"`
	}
	if err := json.Unmarshal(payload, &welcome); err != nil || welcome.Type != "host_welcome" || welcome.Version != "2.0" {
		host.Close()
		t.Fatalf("invalid relay welcome: %v %s", err, payload)
	}
	return host
}

func waitForHost(t *testing.T, base string, server *Server, hostID string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if host, ok := server.registry.host(hostID); ok && host.Online {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("host did not register")
}

func waitForHostOffline(t *testing.T, server *Server, hostID string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if host, ok := server.registry.host(hostID); !ok || !host.Online {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("host did not disconnect")
}
