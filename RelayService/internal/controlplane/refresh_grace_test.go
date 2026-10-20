package controlplane

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func refreshGraceServer(t *testing.T) (*Server, *httptest.Server, string) {
	t.Helper()
	server, err := NewServer(Config{PublicURL: "https://relay.example.test", AdminToken: "admin-bootstrap", SigningKey: []byte("0123456789abcdef0123456789abcdef"), AllowedOrigin: "https://relay.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server)
	t.Cleanup(httpServer.Close)
	hostID, _ := provisionHost(t, httpServer.URL)
	generation, ok := server.registry.generation(hostID)
	if !ok {
		t.Fatal("provisioned Host has no generation")
	}
	refresh, err := server.newRefresh(hostID, generation, "client-1")
	if err != nil {
		t.Fatal(err)
	}
	return server, httpServer, refresh
}

// postRefresh returns the rotated refresh capability, or "" with the status
// when the Relay refused it.
func postRefresh(t *testing.T, baseURL, refresh string) (string, int) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"refresh_token": refresh})
	response, err := http.Post(baseURL+"/v1/session/refresh", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", response.StatusCode
	}
	var rotated struct {
		Refresh string `json:"refresh_token"`
	}
	if err := json.NewDecoder(response.Body).Decode(&rotated); err != nil || rotated.Refresh == "" {
		t.Fatalf("refresh response: %v %#v", err, rotated)
	}
	return rotated.Refresh, response.StatusCode
}

// A phone that lost the rotation response retries with the capability it
// still holds. That retry must not lock the device out.
func TestRefreshRetryWithinGraceRotatesAgainInsteadOfRevoking(t *testing.T) {
	_, httpServer, original := refreshGraceServer(t)

	lost, status := postRefresh(t, httpServer.URL, original)
	if lost == "" {
		t.Fatalf("first rotation: %d", status)
	}
	retried, status := postRefresh(t, httpServer.URL, original)
	if retried == "" {
		t.Fatalf("retry within grace was refused: %d", status)
	}
	if retried == lost {
		t.Fatal("retry returned the undelivered successor instead of a fresh one")
	}
	// The undelivered successor is withdrawn, not counted as reuse.
	if _, status := postRefresh(t, httpServer.URL, lost); status != http.StatusUnauthorized {
		t.Fatalf("withdrawn successor status = %d", status)
	}
	next, status := postRefresh(t, httpServer.URL, retried)
	if next == "" {
		t.Fatalf("family was revoked by the withdrawn successor: %d", status)
	}
}

// Once the successor has been used, presenting its predecessor again is real
// reuse and still revokes the whole family.
func TestRefreshReuseAfterSuccessorWasUsedRevokesFamily(t *testing.T) {
	_, httpServer, original := refreshGraceServer(t)

	successor, _ := postRefresh(t, httpServer.URL, original)
	latest, _ := postRefresh(t, httpServer.URL, successor)
	if latest == "" {
		t.Fatal("successor did not rotate")
	}
	if _, status := postRefresh(t, httpServer.URL, original); status != http.StatusUnauthorized {
		t.Fatalf("reuse of a spent predecessor status = %d", status)
	}
	if _, status := postRefresh(t, httpServer.URL, latest); status != http.StatusUnauthorized {
		t.Fatalf("family survived reuse: %d", status)
	}
}

func TestRefreshRetryAfterGraceRevokesFamily(t *testing.T) {
	server, httpServer, original := refreshGraceServer(t)

	successor, _ := postRefresh(t, httpServer.URL, original)
	server.sessionMu.Lock()
	for hash, retry := range server.refreshRetries {
		retry.Until = time.Now().Add(-time.Second)
		server.refreshRetries[hash] = retry
	}
	server.sessionMu.Unlock()
	if _, status := postRefresh(t, httpServer.URL, original); status != http.StatusUnauthorized {
		t.Fatalf("retry after grace status = %d", status)
	}
	if _, status := postRefresh(t, httpServer.URL, successor); status != http.StatusUnauthorized {
		t.Fatalf("family survived reuse after grace: %d", status)
	}
}
