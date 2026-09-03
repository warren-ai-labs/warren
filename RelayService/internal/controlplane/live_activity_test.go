package controlplane

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestLiveActivityRegistrationLifecycle(t *testing.T) {
	server, err := NewServer(Config{
		PublicURL:     "https://relay.example.test",
		AdminToken:    "admin-bootstrap",
		SigningKey:    []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin: "https://relay.example.test",
		DataURL:       t.TempDir() + "/registry.json",
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, hostSecret := provisionHost(t, httpServer.URL)
	generation, ok := server.registry.generation(hostID)
	if !ok {
		t.Fatal("host generation missing")
	}
	accessToken, err := server.signer.issue(hostID, "control", generation, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	const sessionID = "session-1"
	const pushToken = "aabbccdd"
	body, _ := json.Marshal(map[string]string{"session_id": sessionID, "push_token": pushToken})
	registerRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/h/"+hostID+"/v1/live-activities", bytes.NewReader(body))
	registerRequest.Header.Set("Authorization", "Bearer "+accessToken)
	registerRequest.Header.Set("Content-Type", "application/json")
	registerResponse, err := http.DefaultClient.Do(registerRequest)
	if err != nil {
		t.Fatal(err)
	}
	if registerResponse.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(registerResponse.Body)
		registerResponse.Body.Close()
		t.Fatalf("register status = %d: %s", registerResponse.StatusCode, data)
	}
	registerResponse.Body.Close()
	if got := server.liveActivityRegistrationCount(hostID); got != 1 {
		t.Fatalf("registration count = %d, want 1", got)
	}

	unregisterRequest, _ := http.NewRequest(http.MethodDelete, httpServer.URL+"/h/"+hostID+"/v1/live-activities", bytes.NewReader(body))
	unregisterRequest.Header.Set("Authorization", "Bearer "+accessToken)
	unregisterRequest.Header.Set("Content-Type", "application/json")
	unregisterResponse, err := http.DefaultClient.Do(unregisterRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer unregisterResponse.Body.Close()
	if unregisterResponse.StatusCode != http.StatusOK {
		t.Fatalf("unregister status = %d", unregisterResponse.StatusCode)
	}
	var result map[string]any
	if err := json.NewDecoder(unregisterResponse.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if result["unregistered"] != true || server.liveActivityRegistrationCount(hostID) != 0 {
		t.Fatalf("unregister result = %#v, registrations = %d", result, server.liveActivityRegistrationCount(hostID))
	}
	_ = hostSecret
}

func TestPublishLiveActivityRemovesGoneTokens(t *testing.T) {
	var apnsStatus atomic.Int32
	apnsStatus.Store(http.StatusOK)
	apnsBodies := make(chan []byte, 2)
	apnsServer := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		body, _ := io.ReadAll(request.Body)
		apnsBodies <- body
		writer.WriteHeader(int(apnsStatus.Load()))
	}))
	defer apnsServer.Close()
	_, privateKey := generateAPNsPrivateKey(t)
	server, err := NewServer(Config{
		PublicURL:      "https://relay.example.test",
		AdminToken:     "admin-bootstrap",
		SigningKey:     []byte("0123456789abcdef0123456789abcdef"),
		AllowedOrigin:  "https://relay.example.test",
		DataURL:        t.TempDir() + "/registry.json",
		APNsKeyID:      "KEY123",
		APNsTeamID:     "TEAM123",
		APNsBundleID:   "com.example.Warren",
		APNsPrivateKey: privateKey,
		APNsEndpoint:   apnsServer.URL,
		APNsHTTPClient: apnsServer.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	defer httpServer.Close()
	hostID, hostSecret := provisionHost(t, httpServer.URL)
	generation, _ := server.registry.generation(hostID)
	accessToken, _ := server.signer.issue(hostID, "control", generation, time.Hour)
	const sessionID = "session-1"
	const pushToken = "0011223344556677"
	registrationBody, _ := json.Marshal(map[string]string{"session_id": sessionID, "push_token": pushToken})
	registerRequest, _ := http.NewRequest(http.MethodPost, httpServer.URL+"/h/"+hostID+"/v1/live-activities", bytes.NewReader(registrationBody))
	registerRequest.Header.Set("Authorization", "Bearer "+accessToken)
	registerRequest.Header.Set("Content-Type", "application/json")
	registerResponse, err := http.DefaultClient.Do(registerRequest)
	if err != nil || registerResponse.StatusCode != http.StatusOK {
		t.Fatalf("register response = %v, %v", registerResponse, err)
	}
	registerResponse.Body.Close()

	snapshot := map[string]any{
		"connection":            "connected",
		"activeSessionCount":    1,
		"workingSessionCount":   1,
		"attentionSessionCount": 0,
		"sessions": []map[string]any{{
			"id":         sessionID,
			"title":      "Build",
			"connection": "connected",
			"activity":   "working",
		}},
		"updatedAt": "2026-09-03T12:34:56Z",
	}
	response := publishLiveActivityRequest(t, httpServer.URL, hostID, hostSecret, snapshot)
	if response["sent"] != float64(1) || response["failed"] != float64(0) || response["removed"] != float64(0) {
		t.Fatalf("publish response = %#v", response)
	}
	firstPayload := <-apnsBodies
	var envelope struct {
		APS struct {
			Event        string `json:"event"`
			ContentState struct {
				Connection          string `json:"connection"`
				CurrentSessionTitle string `json:"currentSessionTitle"`
			} `json:"content-state"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(firstPayload, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.APS.Event != "update" || envelope.APS.ContentState.Connection != "connected" || envelope.APS.ContentState.CurrentSessionTitle != "Build" {
		t.Fatalf("APNs payload = %+v", envelope.APS)
	}

	apnsStatus.Store(http.StatusGone)
	response = publishLiveActivityRequest(t, httpServer.URL, hostID, hostSecret, snapshot)
	if response["sent"] != float64(0) || response["removed"] != float64(1) || server.liveActivityRegistrationCount(hostID) != 0 {
		t.Fatalf("gone-token response = %#v, registrations = %d", response, server.liveActivityRegistrationCount(hostID))
	}
	<-apnsBodies
}

func publishLiveActivityRequest(t *testing.T, base, hostID, secret string, snapshot map[string]any) map[string]any {
	t.Helper()
	body, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, base+"/v1/hosts/"+hostID+"/live-activities", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+secret)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(response.Body)
		t.Fatalf("publish status = %d: %s", response.StatusCode, data)
	}
	var result map[string]any
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}
