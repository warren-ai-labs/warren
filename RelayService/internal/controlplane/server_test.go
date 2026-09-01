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
	const hostID = "00000000-0000-4000-8000-000000000001"
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

	hostCredential := provisionHost(t, httpServer.URL, hostID)
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

func TestProvisionReturnsRelaySettingsLinkWithoutHostSecret(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000009"
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

	body, _ := json.Marshal(map[string]string{"id": hostID, "name": "Mac"})
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer admin-bootstrap")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusCreated {
		t.Fatalf("provision host: response=%v err=%v", response, err)
	}
	defer response.Body.Close()
	var result struct {
		Credential string `json:"host_credential"`
		Ticket     string `json:"enrollment_ticket"`
		KeyID      string `json:"relay_key_id"`
		PublicKey  string `json:"relay_public_key"`
		Settings   string `json:"settings_url"`
		Setup      string `json:"setup_url"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if result.Credential != "" || result.Ticket == "" || result.KeyID == "" || result.PublicKey == "" {
		t.Fatalf("incomplete provision response: %#v", result)
	}
	if result.Settings == "" || result.Setup != "" {
		t.Fatalf("unexpected setup link fields: settings=%q setup=%q", result.Settings, result.Setup)
	}
	parsed, err := url.Parse(result.Settings)
	if err != nil || parsed.Scheme != "warren" || parsed.Host != "settings" {
		t.Fatalf("invalid settings link: %q (%v)", result.Settings, err)
	}
	query := parsed.Query()
	if query.Get("section") != "relay" || query.Get("relayUrl") != "https://relay.example.test/relay" ||
		query.Get("hostId") != hostID || query.Get("enrollmentTicket") != result.Ticket ||
		query.Get("relayKeyId") != result.KeyID || query.Get("relayPublicKey") != result.PublicKey {
		t.Fatalf("settings link query mismatch: %v", query)
	}
	if parsed.RawQuery == "" || strings.Contains(parsed.RawQuery, "ignored") {
		t.Fatalf("settings link retained deployment query: %q", parsed.RawQuery)
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
	const hostID = "00000000-0000-4000-8000-000000000009"
	const otherHostID = "00000000-0000-4000-8000-00000000000a"
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
	hostCredential := provisionHost(t, httpServer.URL, hostID)
	_ = provisionHost(t, httpServer.URL, otherHostID)
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

func TestProvisionRejectsNonUUIDHostIdentity(t *testing.T) {
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
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer admin-bootstrap")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusBadRequest {
		t.Fatalf("non-UUID Host ID was accepted: response=%v err=%v", response, err)
	}
	response.Body.Close()
}

func TestRelayRequiresBRLY2HostConnection(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-00000000000b"
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
	credential := provisionHost(t, httpServer.URL, hostID)
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

func TestRelayRejectsLegacyEnrollmentCredentialField(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-00000000000c"
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
	ticket := provisionHostTicket(t, httpServer.URL, hostID)
	body, _ := json.Marshal(map[string]string{
		"enrollment_ticket": ticket,
		"token":             "daemon-secret",
	})
	request, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/v1/hosts/"+hostID+"/enroll", bytes.NewReader(body))
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
	const hostID = "00000000-0000-4000-8000-000000000006"
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

	hostCredential := provisionHost(t, httpServer.URL, hostID)
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
	const durableHostID = "00000000-0000-4000-8000-000000000002"
	const otherHostID = "00000000-0000-4000-8000-000000000003"
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
	hostCredential := provisionHost(t, httpServer.URL, durableHostID)
	otherCredential := provisionHost(t, httpServer.URL, otherHostID)
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
	const hostID = "00000000-0000-4000-8000-000000000013"
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
	hostCredential := provisionHost(t, httpServer.URL, hostID)
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
	const hostID = "00000000-0000-4000-8000-000000000004"
	registry, err := newRegistry("")
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.provisionHost(hostID, "Mac"); err != nil {
		t.Fatal("provision failed")
	}
	ticket, _, ok := registry.enrollmentTicket(hostID)
	if !ok {
		t.Fatal("provision did not create enrollment ticket")
	}
	const credential = "daemon-secret-pairing-expiry"
	if _, err := registry.enrollment(hostID, ticket, credential); err != nil || !registry.authenticateHost(hostID, credential) {
		t.Fatal("enrollment failed")
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

func TestCredentialRotationCannotPublishAStaleHostTunnel(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000005"
	registry, err := newRegistry("")
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.provisionHost(hostID, "Mac"); err != nil {
		t.Fatal(err)
	}
	ticket, _, ok := registry.enrollmentTicket(hostID)
	if !ok {
		t.Fatal("initial enrollment ticket missing")
	}
	const oldCredential = "daemon-secret-old"
	if _, err := registry.enrollment(hostID, ticket, oldCredential); err != nil || !registry.authenticateHost(hostID, oldCredential) {
		t.Fatal("initial credential was not accepted")
	}
	if err := registry.provisionHost(hostID, "Mac"); err != nil {
		t.Fatal(err)
	}
	ticket, _, ok = registry.enrollmentTicket(hostID)
	if !ok {
		t.Fatal("rotation enrollment ticket missing")
	}
	const newCredential = "daemon-secret-new"
	if _, err := registry.enrollment(hostID, ticket, newCredential); err != nil {
		t.Fatal(err)
	}
	staleTunnel := &hostTunnel{clients: make(map[connectionID]*clientRoute), closed: make(chan struct{})}
	if registry.connectHost(hostID, "Mac", oldCredential, staleTunnel) {
		t.Fatal("rotated credential published a stale Host tunnel")
	}
	currentTunnel := &hostTunnel{clients: make(map[connectionID]*clientRoute), closed: make(chan struct{})}
	if !registry.connectHost(hostID, "Mac", newCredential, currentTunnel) {
		t.Fatal("current credential could not publish Host tunnel")
	}
	generation, ok := registry.generation(hostID)
	if !ok || registry.authorizedTunnel(hostID, generation) != currentTunnel {
		t.Fatal("current generation could not resolve its Host tunnel")
	}
	if registry.authorizedTunnel(hostID, generation-1) != nil {
		t.Fatal("old access generation resolved the current Host tunnel")
	}
}

func TestRegistryMutationRollsBackWhenPersistenceFails(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000008"
	dataURL := t.TempDir() + "/registry.json"
	registry, err := newRegistry(dataURL)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.provisionHost(hostID, "Mac"); err != nil {
		t.Fatal(err)
	}
	ticket, _, ok := registry.enrollmentTicket(hostID)
	if !ok {
		t.Fatal("enrollment ticket missing")
	}
	const credential = "daemon-secret-persistence"
	if _, err := registry.enrollment(hostID, ticket, credential); err != nil {
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
	if err := registry.provisionHost(hostID, "Rotated Mac"); err == nil {
		t.Fatal("rotation unexpectedly succeeded when persistence failed")
	}
	if !registry.authenticateHost(hostID, credential) {
		t.Fatal("failed rotation changed the in-memory credential")
	}
}

func provisionHost(t *testing.T, base, hostID string) string {
	t.Helper()
	ticket := provisionHostTicket(t, base, hostID)
	secret := "daemon-secret-" + hostID
	body, _ := json.Marshal(map[string]string{"enrollment_ticket": ticket, "host_secret": secret})
	request, _ := http.NewRequest(http.MethodPost, base+"/v1/hosts/"+hostID+"/enroll", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("enroll host: response=%v err=%v", response, err)
	}
	response.Body.Close()
	return secret
}

func provisionHostTicket(t *testing.T, base, hostID string) string {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"id": hostID, "name": "Mac"})
	request, _ := http.NewRequest(http.MethodPost, base+"/v1/hosts", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer admin-bootstrap")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusCreated {
		t.Fatalf("provision host: response=%v err=%v", response, err)
	}
	defer response.Body.Close()
	var result struct {
		Credential string `json:"host_credential"`
		Ticket     string `json:"enrollment_ticket"`
	}
	if json.NewDecoder(response.Body).Decode(&result) != nil || result.Credential != "" || result.Ticket == "" {
		t.Fatalf("invalid host provisioning response: %#v", result)
	}
	return result.Ticket
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
