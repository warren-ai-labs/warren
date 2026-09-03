package controlplane

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAPNsSenderBuildsLiveActivityRequest(t *testing.T) {
	key, privateKeyPEM := generateAPNsPrivateKey(t)

	type capturedRequest struct {
		method  string
		path    string
		headers http.Header
		body    []byte
	}
	captured := make(chan capturedRequest, 1)
	apnsServer := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		body, _ := io.ReadAll(request.Body)
		captured <- capturedRequest{
			method:  request.Method,
			path:    request.URL.Path,
			headers: request.Header.Clone(),
			body:    body,
		}
		writer.WriteHeader(http.StatusOK)
	}))
	defer apnsServer.Close()

	sender, err := newAPNsSender(Config{
		APNsKeyID:      "KEY123",
		APNsTeamID:     "TEAM123",
		APNsBundleID:   "com.example.Warren",
		APNsPrivateKey: privateKeyPEM,
		APNsEndpoint:   apnsServer.URL,
		APNsHTTPClient: apnsServer.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 3, 12, 34, 56, 0, time.UTC)
	if err := sender.send("AAbb", apnsContentState{
		Connection:            "connected",
		ActiveSessionCount:    2,
		WorkingSessionCount:   1,
		AttentionSessionCount: 0,
		CurrentSessionTitle:   "Build",
		UpdatedAt:             now.Sub(time.Unix(appleReferenceUnix, 0)).Seconds(),
	}, "update", 0.75, now); err != nil {
		t.Fatal(err)
	}
	received := <-captured
	if received.method != http.MethodPost || received.path != "/3/device/aabb" {
		t.Fatalf("APNs request = %s %s", received.method, received.path)
	}
	if got := received.headers.Get("Apns-Push-Type"); got != "liveactivity" {
		t.Fatalf("apns-push-type = %q", got)
	}
	if got := received.headers.Get("Apns-Topic"); got != "com.example.Warren.push-type.liveactivity" {
		t.Fatalf("apns-topic = %q", got)
	}
	if got := received.headers.Get("Apns-Priority"); got != "10" {
		t.Fatalf("apns-priority = %q", got)
	}
	authorization := received.headers.Get("Authorization")
	if !strings.HasPrefix(authorization, "bearer ") {
		t.Fatalf("authorization = %q", authorization)
	}
	verifyAPNsJWT(t, strings.TrimPrefix(authorization, "bearer "), key, now)

	var envelope struct {
		APS struct {
			Timestamp      int64   `json:"timestamp"`
			Event          string  `json:"event"`
			StaleDate      int64   `json:"stale-date"`
			RelevanceScore float64 `json:"relevance-score"`
			ContentState   struct {
				Connection            string  `json:"connection"`
				ActiveSessionCount    int     `json:"activeSessionCount"`
				WorkingSessionCount   int     `json:"workingSessionCount"`
				AttentionSessionCount int     `json:"attentionSessionCount"`
				CurrentSessionTitle   string  `json:"currentSessionTitle"`
				UpdatedAt             float64 `json:"updatedAt"`
			} `json:"content-state"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(received.body, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.APS.Timestamp != now.Unix() || envelope.APS.Event != "update" || envelope.APS.StaleDate != now.Add(time.Hour).Unix() || envelope.APS.RelevanceScore != 0.75 {
		t.Fatalf("APNs aps = %+v", envelope.APS)
	}
	state := envelope.APS.ContentState
	if state.Connection != "connected" || state.ActiveSessionCount != 2 || state.WorkingSessionCount != 1 || state.CurrentSessionTitle != "Build" {
		t.Fatalf("APNs content state = %+v", state)
	}
	if state.UpdatedAt != now.Sub(time.Unix(appleReferenceUnix, 0)).Seconds() {
		t.Fatalf("updatedAt = %v", state.UpdatedAt)
	}
}

func TestAPNsSenderMarksGoneTokenExpired(t *testing.T) {
	apnsServer := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusGone)
	}))
	defer apnsServer.Close()
	_, privateKeyPEM := generateAPNsPrivateKey(t)
	sender, err := newAPNsSender(Config{
		APNsKeyID:      "KEY123",
		APNsTeamID:     "TEAM123",
		APNsBundleID:   "com.example.Warren",
		APNsPrivateKey: privateKeyPEM,
		APNsEndpoint:   apnsServer.URL,
		APNsHTTPClient: apnsServer.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	err = sender.send("aabb", apnsContentState{Connection: "stopped", UpdatedAt: 1}, "end", 0.5, time.Now())
	if !errors.Is(err, errAPNsTokenExpired) {
		t.Fatalf("send error = %v, want token expiration", err)
	}
}

func TestAPNsSenderRejectsEndpointPath(t *testing.T) {
	_, privateKey := generateAPNsPrivateKey(t)
	if _, err := newAPNsSender(Config{
		APNsKeyID:      "KEY123",
		APNsTeamID:     "TEAM123",
		APNsBundleID:   "com.example.Warren",
		APNsPrivateKey: privateKey,
		APNsEndpoint:   "https://api.push.apple.com/provider",
	}); err == nil {
		t.Fatal("accepted APNs endpoint with a path")
	}
}

func generateAPNsPrivateKey(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKey})
}

func verifyAPNsJWT(t *testing.T, token string, key *ecdsa.PrivateKey, now time.Time) {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT parts = %d", len(parts))
	}
	var header struct {
		Algorithm string `json:"alg"`
		KeyID     string `json:"kid"`
	}
	if data, err := base64.RawURLEncoding.DecodeString(parts[0]); err != nil || json.Unmarshal(data, &header) != nil {
		t.Fatal("invalid JWT header")
	}
	if header.Algorithm != "ES256" || header.KeyID != "KEY123" {
		t.Fatalf("JWT header = %+v", header)
	}
	var claims struct {
		Issuer   string `json:"iss"`
		IssuedAt int64  `json:"iat"`
	}
	if data, err := base64.RawURLEncoding.DecodeString(parts[1]); err != nil || json.Unmarshal(data, &claims) != nil {
		t.Fatal("invalid JWT claims")
	}
	if claims.Issuer != "TEAM123" || claims.IssuedAt != now.Unix() {
		t.Fatalf("JWT claims = %+v", claims)
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(signature) != 64 {
		t.Fatal("invalid JWT signature")
	}
	hash := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(key.Public().(*ecdsa.PublicKey), hash[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
		t.Fatal("JWT signature did not verify")
	}
}
