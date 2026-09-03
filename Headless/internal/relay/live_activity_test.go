package relay

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLiveActivityClientPublishesHostSnapshot(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000021"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/relay/v1/hosts/"+hostID+"/live-activities" {
			t.Fatalf("request = %s %s", request.Method, request.URL.Path)
		}
		if request.Header.Get("Authorization") != "Bearer host-secret" {
			t.Fatalf("authorization = %q", request.Header.Get("Authorization"))
		}
		var snapshot LiveActivitySnapshot
		if err := json.NewDecoder(request.Body).Decode(&snapshot); err != nil {
			t.Fatal(err)
		}
		if snapshot.Connection != "connected" || snapshot.ActiveSessionCount != 1 || len(snapshot.Sessions) != 1 || snapshot.Sessions[0].Title != "Build" {
			t.Fatalf("snapshot = %+v", snapshot)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"sent":1}`)
	}))
	defer server.Close()

	client, err := NewLiveActivityClient(server.URL+"/relay", hostID, "host-secret")
	if err != nil {
		t.Fatal(err)
	}
	err = client.Publish(context.Background(), LiveActivitySnapshot{
		Connection:          "connected",
		ActiveSessionCount:  1,
		WorkingSessionCount: 1,
		Sessions: []LiveActivitySession{{
			ID:         "session-1",
			Title:      "Build",
			Connection: "connected",
		}},
		UpdatedAt: time.Date(2026, 9, 3, 12, 34, 56, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestLiveActivityClientRejectsUnsafeRelayURL(t *testing.T) {
	for _, value := range []string{
		"https://relay.example.test?token=secret",
		"https://relay.example.test/../relay",
		"ftp://relay.example.test",
	} {
		if _, err := NewLiveActivityClient(value, "host-1", "host-secret"); err == nil {
			t.Fatalf("accepted unsafe Relay URL %q", value)
		}
	}
}

func TestLiveActivityClientReportsRelayErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		http.Error(writer, "snapshot rejected", http.StatusUnauthorized)
	}))
	defer server.Close()
	client, err := NewLiveActivityClient(server.URL, "host-1", "host-secret")
	if err != nil {
		t.Fatal(err)
	}
	err = client.Publish(context.Background(), LiveActivitySnapshot{})
	if err == nil || !strings.Contains(err.Error(), "HTTP 401") || !strings.Contains(err.Error(), "snapshot rejected") {
		t.Fatalf("Publish error = %v", err)
	}
}
