package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// newPublicRouteTestServer serves the Host handler as a public Relay route
// would reach it: every request carries the public-route marker.
func newPublicRouteTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	directory := t.TempDir()
	state, err := store.Open(filepath.Join(directory, "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	projectID, workspaceID := store.NewID(), store.NewID()
	if err := state.Update(func(value *api.State) error {
		value.Projects = []api.Project{{ID: projectID, Name: "Project", Path: directory, CreatedAt: time.Now().UTC()}}
		value.Workspaces = []api.Workspace{{ID: workspaceID, ProjectID: projectID, Name: "main", Path: directory, Kind: "root", CreatedAt: time.Now().UTC()}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: newMemoryOutputRuntime(t)}
	service.lazyInit()
	handler := NewHTTPServer(service, "secret", nil).Handler()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		handler.ServeHTTP(writer, request.WithContext(relay.ContextWithPublicRoute(request.Context())))
	}))
	t.Cleanup(server.Close)
	return server
}

func openAnonymousPublicConnection(t *testing.T, serverURL string) (*websocket.Conn, api.WelcomeMessage) {
	t.Helper()
	connection, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(serverURL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { connection.Close() })
	if err := connection.WriteJSON(api.Envelope{
		Type: "auth", Version: api.Version, TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatal(err)
	}
	var welcome api.WelcomeMessage
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome.Type != "welcome" {
		t.Fatalf("anonymous public auth = %#v, want welcome", welcome)
	}
	return connection, welcome
}

func requestOK(t *testing.T, connection *websocket.Conn, id, method string, params map[string]any) map[string]any {
	t.Helper()
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var message map[string]any
		if err := connection.ReadJSON(&message); err != nil {
			t.Fatal(err)
		}
		if message["id"] == id {
			return message
		}
	}
	t.Fatalf("no response to %s", method)
	return nil
}

// An anonymous public visitor is its own identity: never the owner, never in
// the owner's access scope. Until a finer policy exists it may operate the
// Host like a paired device, but not change Host settings.
func TestAnonymousPublicVisitorHasItsOwnScopeAndNoOwnerAuthority(t *testing.T) {
	server := newPublicRouteTestServer(t)
	connection, welcome := openAnonymousPublicConnection(t, server.URL)
	if welcome.AccessScopeID != publicAccessScopeID {
		t.Fatalf("anonymous access scope = %q, want %q", welcome.AccessScopeID, publicAccessScopeID)
	}
	var roster map[string]any
	_ = connection.ReadJSON(&roster)
	workspaces := roster["state"].(map[string]any)["workspaces"].([]any)
	workspaceID := workspaces[0].(map[string]any)["id"].(string)

	if message := requestOK(t, connection, "create", "session.create", map[string]any{"workspace": workspaceID, "command": "id"}); message["ok"] != true {
		t.Fatalf("session.create as public visitor = %#v", message)
	}
	for _, method := range []string{"settings.get", "remote.status", "pairing.enable", "public-access.status"} {
		if message := requestOK(t, connection, method, method, nil); message["ok"] == true {
			t.Fatalf("%s as public visitor = %#v, want refusal", method, message)
		}
	}
}

// The owner's own token keeps the owner scope on the same public route.
func TestOwnerTokenOnAPublicRouteKeepsTheOwnerScope(t *testing.T) {
	server := newPublicRouteTestServer(t)
	connection, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{
		Type: "auth", Token: "secret", Version: api.Version, TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatal(err)
	}
	var welcome api.WelcomeMessage
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome.AccessScopeID != "scope-owner" {
		t.Fatalf("owner access scope on a public route = %q", welcome.AccessScopeID)
	}
	if message := requestOK(t, connection, "settings", "settings.get", nil); message["ok"] != true {
		t.Fatalf("settings.get as owner = %#v", message)
	}
}
