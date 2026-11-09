package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	boltclient "github.com/abcdlsj/bolthole/client"
	"github.com/abcdlsj/bolthole/kinds/wskind"
	boltrelay "github.com/abcdlsj/bolthole/relay"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/remote"
)

type remoteTestHost struct {
	handler *HTTPServer
	local   *httptest.Server
	relay   *httptest.Server
	remote  *remote.Supervisor
	hostID  string
}

func newRemoteTestHost(t *testing.T) *remoteTestHost {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	relayServer := httptest.NewServer(boltrelay.New(boltrelay.Config{}))
	t.Cleanup(relayServer.Close)

	state := newStateWithSession(t, "session-remote", "runtime-remote")
	service := &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{"runtime-remote": []byte("ready\n")}}}
	handler := NewHTTPServer(service, "secret", nil)
	local := httptest.NewServer(handler.Handler())
	t.Cleanup(local.Close)
	supervisor := remote.New(ctx, remote.Config{
		CodePath:   filepath.Join(t.TempDir(), "remote.code"),
		Name:       "test-host",
		HTTP:       handler.Handler(),
		WebSocket:  handler.ServeRemoteWebSocket,
		DirectURLs: func() []string { return []string{"ws" + strings.TrimPrefix(local.URL, "http") + remote.DirectPath} },
	})
	t.Cleanup(supervisor.Stop)
	handler.Remote = supervisor
	handler.RemoteDirect = supervisor.DirectHandler()
	handler.RemoteDefaultRelayURL = relayServer.URL
	handler.RemoteWebURL = "https://app.example.test"
	return &remoteTestHost{
		handler: handler, local: local, relay: relayServer, remote: supervisor,
		hostID: state.Snapshot().Host.ID,
	}
}

func (host *remoteTestHost) ownerPost(t *testing.T, path string, body any) map[string]any {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	} else {
		reader = bytes.NewReader(nil)
	}
	request, _ := http.NewRequest(http.MethodPost, host.local.URL+path, reader)
	request.Header.Set("Authorization", "Bearer secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("POST %s: status %d", path, response.StatusCode)
	}
	var result map[string]any
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

func (host *remoteTestHost) waitConnected(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if host.remote.Status().Connected {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("remote access never connected: %+v", host.remote.Status())
}

func shareFragment(t *testing.T, link string) url.Values {
	t.Helper()
	parsed, err := url.Parse(link)
	if err != nil {
		t.Fatal(err)
	}
	values, err := url.ParseQuery(parsed.Fragment)
	if err != nil {
		t.Fatal(err)
	}
	return values
}

// pairRemote exchanges a share link's invite for a paired-client token over
// the encrypted session, the way a phone does after scanning the QR code.
func pairRemote(t *testing.T, client *boltclient.Client, link, clientID string) string {
	t.Helper()
	fragment := shareFragment(t, link)
	body, _ := json.Marshal(map[string]string{
		"host_id": fragment.Get("host"), "client_id": clientID, "client_name": "Test Phone",
		"invite": fragment.Get("invite"),
	})
	response, err := client.HTTPClient().Post("http://agent/v1/pairing/request", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("remote pairing: status %d", response.StatusCode)
	}
	var result struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil || result.Token == "" {
		t.Fatalf("remote pairing result: %v %+v", err, result)
	}
	return result.Token
}

func remoteAuth(t *testing.T, client *boltclient.Client, token string) (*wskind.Conn, map[string]any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := client.DialWebSocket(ctx, "/v1/ws")
	if err != nil {
		t.Fatal(err)
	}
	auth, _ := json.Marshal(api.Envelope{
		Type: "auth", Token: token, Version: api.Version,
		TerminalStateFormats: []string{terminalStateFormatANSI},
	})
	if err := conn.Write(wskind.OpText, auth); err != nil {
		t.Fatal(err)
	}
	_, data, err := conn.Read()
	if err != nil {
		t.Fatal(err)
	}
	var first map[string]any
	if err := json.Unmarshal(data, &first); err != nil {
		t.Fatal(err)
	}
	return conn, first
}

func TestRemoteShareRelayPairingAndOwnerSession(t *testing.T) {
	host := newRemoteTestHost(t)
	host.ownerPost(t, "/v1/remote/enable", nil)
	host.waitConnected(t)
	share := host.ownerPost(t, "/v1/remote/share", nil)
	link, _ := share["link"].(string)
	if !strings.HasPrefix(link, host.relay.URL+"/#k=") {
		t.Fatalf("share link = %q", link)
	}
	if share["relaySource"] != "default" {
		t.Fatalf("share relaySource = %v, want default", share["relaySource"])
	}
	if fragment := shareFragment(t, link); fragment.Get("host") != host.hostID || fragment.Get("invite") == "" {
		t.Fatalf("share fragment = %v", fragment)
	}
	// The Web link carries the same secrets, only in a fragment, and names
	// the relay because the page is not served by it.
	webLink, _ := share["webLink"].(string)
	if !strings.HasPrefix(webLink, "https://app.example.test/#r=") {
		t.Fatalf("web link = %q", webLink)
	}
	webFragment, linkFragment := shareFragment(t, webLink), shareFragment(t, link)
	if webFragment.Get("r") != host.relay.URL {
		t.Fatalf("web link relay = %q, want %q", webFragment.Get("r"), host.relay.URL)
	}
	for _, key := range []string{"k", "host", "invite"} {
		if webFragment.Get(key) != linkFragment.Get(key) {
			t.Fatalf("web link %s = %q, want %q", key, webFragment.Get(key), linkFragment.Get(key))
		}
	}

	client, err := boltclient.New(link, &boltclient.Options{Mode: boltclient.RelayOnly, Name: "test phone"})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	// The connect code alone does not open a session.
	conn, first := remoteAuth(t, client, "not-a-token")
	conn.Stream().Reset("cancel", "")
	if first["t"] != "error" {
		t.Fatalf("unpaired auth = %#v, want error", first)
	}

	token := pairRemote(t, client, link, "phone-1")
	conn, welcome := remoteAuth(t, client, token)
	defer conn.Close(1000, "")
	if welcome["t"] != "welcome" {
		t.Fatalf("paired auth = %#v, want welcome", welcome)
	}
	clients := host.handler.Service.PairedClientsSnapshot()
	if len(clients) != 1 || !clients[0].Owner || clients[0].Via != pairedViaRemote {
		t.Fatalf("paired clients = %+v", clients)
	}

	// A remote-paired device keeps the owner authority a Relay invite had.
	request, _ := json.Marshal(api.Envelope{Type: "request", ID: "1", Method: "remote.status"})
	if err := conn.Write(wskind.OpText, request); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		_, data, err := conn.Read()
		if err != nil {
			t.Fatal(err)
		}
		var message map[string]any
		_ = json.Unmarshal(data, &message)
		if message["id"] != "1" {
			continue
		}
		if message["ok"] != true {
			t.Fatalf("remote.status as remote-paired owner = %#v", message)
		}
		return
	}
	t.Fatal("no response to remote.status")
}

func TestRemoteDirectPathAndRotation(t *testing.T) {
	host := newRemoteTestHost(t)
	host.ownerPost(t, "/v1/remote/enable", nil)
	host.waitConnected(t)
	share := host.ownerPost(t, "/v1/remote/share", nil)
	link := share["link"].(string)
	direct := "ws" + strings.TrimPrefix(host.local.URL, "http") + remote.DirectPath
	client, err := boltclient.New(link, &boltclient.Options{Mode: boltclient.DirectOnly, Direct: []string{direct}})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	token := pairRemote(t, client, link, "phone-direct")
	conn, welcome := remoteAuth(t, client, token)
	if welcome["t"] != "welcome" {
		t.Fatalf("direct auth = %#v, want welcome", welcome)
	}

	// Disconnecting from the relay leaves the direct entry point serving the
	// same code, so a LAN client keeps its session and its authority.
	host.ownerPost(t, "/v1/remote/disable", nil)
	request, _ := json.Marshal(api.Envelope{Type: "request", ID: "1", Method: "remote.status"})
	if err := conn.Write(wskind.OpText, request); err != nil {
		t.Fatalf("direct session after remote disable: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	answered := false
	for time.Now().Before(deadline) {
		_, data, err := conn.Read()
		if err != nil {
			t.Fatalf("direct session after remote disable: %v", err)
		}
		var message map[string]any
		_ = json.Unmarshal(data, &message)
		if message["id"] == "1" {
			if message["ok"] != true {
				t.Fatalf("remote.status after disable = %#v", message)
			}
			answered = true
			break
		}
	}
	if !answered {
		t.Fatal("no response to remote.status after remote disable")
	}

	// Rotation cuts the live session and forgets remote-paired devices.
	host.ownerPost(t, "/v1/remote/rotate", nil)
	readDeadline := time.After(5 * time.Second)
	closed := make(chan struct{})
	go func() {
		for {
			if _, _, err := conn.Read(); err != nil {
				close(closed)
				return
			}
		}
	}()
	select {
	case <-closed:
	case <-readDeadline:
		t.Fatal("rotation did not close the live session")
	}
	if clients := host.handler.Service.PairedClientsSnapshot(); len(clients) != 0 {
		t.Fatalf("paired clients after rotate = %+v", clients)
	}
	stale, err := boltclient.New(link, &boltclient.Options{Mode: boltclient.DirectOnly, Direct: []string{direct}, DirectTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer stale.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, _, err := stale.DialWebSocket(ctx, "/v1/ws"); err == nil {
		t.Fatal("old connect code still opened a session after rotation")
	}
}

func TestRemoteShareInviteExpiresAndIsNotAPIN(t *testing.T) {
	host := newRemoteTestHost(t)
	host.ownerPost(t, "/v1/remote/enable", nil)
	host.waitConnected(t)
	share := host.ownerPost(t, "/v1/remote/share", nil)
	fragment := shareFragment(t, share["link"].(string))
	post := func(body map[string]string) int {
		data, _ := json.Marshal(body)
		response, err := http.Post(host.local.URL+"/v1/pairing/request", "application/json", bytes.NewReader(data))
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		return response.StatusCode
	}
	if status := post(map[string]string{"host_id": host.hostID, "client_id": "x", "invite": "wrong"}); status != http.StatusConflict {
		t.Fatalf("wrong invite status = %d", status)
	}
	if status := post(map[string]string{"host_id": host.hostID, "client_id": "x", "invite": fragment.Get("invite"), "pin": "123456"}); status != http.StatusBadRequest {
		t.Fatalf("invite plus PIN status = %d", status)
	}
	host.handler.pairingMu.Lock()
	host.handler.remoteShareWindow.expiresAt = time.Now().Add(-time.Second)
	host.handler.pairingMu.Unlock()
	if status := post(map[string]string{"host_id": host.hostID, "client_id": "x", "invite": fragment.Get("invite")}); status != http.StatusConflict {
		t.Fatalf("expired invite status = %d", status)
	}
}

func TestRemoteShareRequiresEnabledRemote(t *testing.T) {
	host := newRemoteTestHost(t)
	// A share link only reaches the Host through the relay it names, so
	// handing one out while remote access is off would produce a link that
	// reads as a broken Host.
	request, _ := http.NewRequest(http.MethodPost, host.local.URL+"/v1/remote/share", bytes.NewReader(nil))
	request.Header.Set("Authorization", "Bearer secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("share while disabled: status %d, body %s", response.StatusCode, body)
	}
	if !strings.Contains(string(body), "remote enable") {
		t.Fatalf("share while disabled: body %q does not point at remote enable", body)
	}

	host.ownerPost(t, "/v1/remote/enable", nil)
	host.waitConnected(t)
	if share := host.ownerPost(t, "/v1/remote/share", nil); share["link"] == nil {
		t.Fatalf("share after enable = %#v", share)
	}
}

func TestRemoteRelaySourceAndReturnToDefault(t *testing.T) {
	host := newRemoteTestHost(t)
	// Nothing configured: the build's relay is the default source.
	state := host.ownerPost(t, "/v1/remote/enable", nil)
	if state["relaySource"] != "default" || state["relayURL"] != host.relay.URL {
		t.Fatalf("enable with the build default = %#v", state)
	}
	host.waitConnected(t)

	// A self-hosted relay replaces the default and is remembered.
	selfHosted := "http://127.0.0.1:1"
	state = host.ownerPost(t, "/v1/remote/enable", map[string]string{"relayUrl": selfHosted})
	if state["relaySource"] != "self-hosted" || state["configuredRelayURL"] != selfHosted {
		t.Fatalf("enable with a self-hosted relay = %#v", state)
	}
	if stored := host.handler.Service.RemoteSettingsSnapshot().RelayURL; stored != selfHosted {
		t.Fatalf("stored relay = %q, want %q", stored, selfHosted)
	}
	// A bare `remote enable` keeps using the configured relay.
	if resolved, err := host.handler.remoteRelayURL(""); err != nil || resolved != selfHosted {
		t.Fatalf("resolved relay = %q, %v", resolved, err)
	}

	// "default" drops it, so the Host goes back to the build's relay.
	state = host.ownerPost(t, "/v1/remote/enable", map[string]string{"relayUrl": "default"})
	if state["relaySource"] != "default" || state["relayURL"] != host.relay.URL {
		t.Fatalf("enable with relay=default = %#v", state)
	}
	if stored := host.handler.Service.RemoteSettingsSnapshot().RelayURL; stored != "" {
		t.Fatalf("stored relay after returning to default = %q, want empty", stored)
	}
	host.waitConnected(t)

	// Sharing honours the same value instead of the stale configured relay.
	share := host.ownerPost(t, "/v1/remote/share", map[string]string{"relayUrl": "default"})
	if link, _ := share["link"].(string); !strings.HasPrefix(link, host.relay.URL+"/#k=") {
		t.Fatalf("share with relay=default = %q", link)
	}
}

func TestRemoteWebLink(t *testing.T) {
	link := "https://relay.example.com/#k=code&host=h1&invite=i1"
	got, err := remoteWebLink("https://app.example.test/path?x=1#old", "https://relay.example.com", link)
	if err != nil {
		t.Fatal(err)
	}
	if want := "https://app.example.test/path#r=https%3A%2F%2Frelay.example.com&k=code&host=h1&invite=i1"; got != want {
		t.Fatalf("web link = %q, want %q", got, want)
	}
	if got, err := remoteWebLink("", "https://relay.example.com", link); err != nil || got != "" {
		t.Fatalf("no Web client = %q, %v", got, err)
	}
	if _, err := remoteWebLink("ftp://app", "https://relay.example.com", link); err == nil {
		t.Fatal("a non-http Web client URL was accepted")
	}
}
