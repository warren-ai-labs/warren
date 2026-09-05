package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

func TestPublicRelayWebSocketAcceptsCredentialFreeProtocol3Auth(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "public-websocket-test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}
	base := NewHTTPServer(service, "daemon-secret", nil).Handler()
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/v1/ws" {
			request = request.WithContext(relay.ContextWithPublicRoute(request.Context()))
		}
		base.ServeHTTP(writer, request)
	})
	httpServer := httptest.NewServer(handler)
	defer httpServer.Close()

	endpoint := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{
		Type:                 "auth",
		Version:              api.Version,
		TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatal(err)
	}
	var welcome api.WelcomeMessage
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome.Type != "welcome" || welcome.Version != api.Version {
		t.Fatalf("public WebSocket welcome = %#v", welcome)
	}
}

func TestPublicRelayWebSocketStillRejectsNonEmptyInvalidToken(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "public-websocket-invalid-token-test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}
	base := NewHTTPServer(service, "daemon-secret", nil).Handler()
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/v1/ws" {
			request = request.WithContext(relay.ContextWithPublicRoute(request.Context()))
		}
		base.ServeHTTP(writer, request)
	})
	httpServer := httptest.NewServer(handler)
	defer httpServer.Close()

	endpoint := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{
		Type:                 "auth",
		Token:                "not-the-daemon-token",
		Version:              api.Version,
		TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatal(err)
	}
	var response api.Response
	if err := connection.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response.Type != "error" || response.Error != "unauthorized" {
		t.Fatalf("invalid public token response = %#v", response)
	}
}

func TestDirectWebSocketStillRequiresDaemonToken(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "direct-websocket-auth-test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}
	httpServer := httptest.NewServer(NewHTTPServer(service, "daemon-secret", nil).Handler())
	defer httpServer.Close()

	endpoint := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{
		Type:                 "auth",
		Version:              api.Version,
		TerminalStateFormats: []string{terminalStateFormatANSI},
	}); err != nil {
		t.Fatal(err)
	}
	var response api.Response
	if err := connection.ReadJSON(&response); err != nil {
		t.Fatal(err)
	}
	if response.Type != "error" || response.Error != "unauthorized" {
		t.Fatalf("direct empty-token response = %#v", response)
	}
}
