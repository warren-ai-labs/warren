package relay

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPairingClientShareReturnsOnlyOpaqueInvite(t *testing.T) {
	const hostID = "00000000-0000-4000-8000-000000000014"
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/v1/hosts/" + hostID + "/pairing":
			if request.Header.Get("Authorization") != "Bearer host-secret" {
				t.Fatalf("pairing authorization = %q", request.Header.Get("Authorization"))
			}
			_, _ = io.WriteString(writer, `{"pairing_code":"pairing-code"}`)
		case "/v1/pair":
			var body map[string]string
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil || body["host_id"] != hostID || body["pairing_code"] != "pairing-code" {
				t.Fatalf("pair request = %#v (%v)", body, err)
			}
			_, _ = io.WriteString(writer, `{"access_token":"must-not-escape","pairing_url":"`+server.URL+`/invite/opaque-ticket/","pairing_expires_in":604800,"pairing_expires_at":"2030-01-01T00:00:00Z"}`)
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	client, err := NewPairingClient(server.URL, hostID, "host-secret")
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Share(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.PairingURL != server.URL+"/invite/opaque-ticket/" || result.ExpiresIn != 604800 || !result.Reusable {
		t.Fatalf("pairing result = %#v", result)
	}
}

func TestPairingClientRejectsCrossOriginInvite(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(request.URL.Path, "/pairing") {
			_, _ = io.WriteString(writer, `{"pairing_code":"pairing-code"}`)
			return
		}
		_, _ = io.WriteString(writer, `{"pairing_url":"https://attacker.example/invite/opaque-ticket/","pairing_expires_in":604800}`)
	}))
	defer server.Close()
	client, err := NewPairingClient(server.URL, "00000000-0000-4000-8000-000000000015", "host-secret")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Share(context.Background()); err == nil {
		t.Fatal("cross-origin pairing link was accepted")
	}
}

func TestPairingClientRejectsInviteWithFragment(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(request.URL.Path, "/pairing") {
			_, _ = io.WriteString(writer, `{"pairing_code":"pairing-code"}`)
			return
		}
		_, _ = io.WriteString(writer, `{"pairing_url":"`+server.URL+`/invite/opaque-ticket/#credential","pairing_expires_in":604800}`)
	}))
	defer server.Close()
	client, err := NewPairingClient(server.URL, "00000000-0000-4000-8000-000000000016", "host-secret")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Share(context.Background()); err == nil {
		t.Fatal("pairing link with a fragment was accepted")
	}
}
