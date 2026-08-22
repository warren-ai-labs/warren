package server

import (
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

func TestBackgroundRequestClassification(t *testing.T) {
	for _, method := range []string{"git.panel", "git.diff"} {
		if !isBackgroundRequest(method) {
			t.Errorf("%s is not scheduled as a background request", method)
		}
	}
	for _, method := range []string{"session.attach", "session.input", "git.checkout"} {
		if isBackgroundRequest(method) {
			t.Errorf("%s should stay on the ordered request path", method)
		}
	}
}

func TestGitPanelDoesNotBlockFollowupRequests(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: "secret"}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}

	unlock := service.lockGitMutation(workspaceID)
	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: "git-slow", Method: "git.panel",
		Params: map[string]any{"workspace": workspaceID, "fetch": true, "force": true},
	}); err != nil {
		unlock()
		t.Fatal(err)
	}
	if err := connection.WriteJSON(api.Envelope{Type: "request", ID: "roster-fast", Method: "roster"}); err != nil {
		unlock()
		t.Fatal(err)
	}

	if err := connection.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		unlock()
		t.Fatal(err)
	}
	response := readGitResponse(t, connection, "roster-fast")
	if !response.OK {
		unlock()
		t.Fatalf("roster failed while git.panel was running: %v", response.Error)
	}
	unlock()
	if err := connection.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	response = readGitResponse(t, connection, "git-slow")
	if !response.OK {
		t.Fatalf("git.panel failed after releasing the mutation lock: %v", response.Error)
	}
}

func readGitResponse(t *testing.T, connection *websocket.Conn, id string) api.Response {
	t.Helper()
	for {
		var response api.Response
		if err := connection.ReadJSON(&response); err != nil {
			t.Fatal(err)
		}
		if response.Type == "response" && response.ID == id {
			return response
		}
	}
}

func TestGitPanelOverWebSocket(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: "secret"}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome["t"] != "welcome" {
		t.Fatalf("unexpected welcome: %#v", welcome)
	}

	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: "git-1", Method: "git.panel",
		Params: map[string]any{"workspace": workspaceID},
	}); err != nil {
		t.Fatal(err)
	}
	response := readGitResponse(t, connection, "git-1")
	if !response.OK {
		t.Fatalf("git.panel failed: %v", response.Error)
	}
	result, ok := response.Result.(map[string]any)
	if !ok {
		t.Fatalf("result = %#v, want object", response.Result)
	}
	if result["branch"] != "main" {
		t.Fatalf("branch = %#v, want main", result["branch"])
	}
}

func TestGitCheckoutErrorOverWebSocket(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: "secret"}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}

	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: "git-2", Method: "git.checkout",
		Params: map[string]any{"workspace": workspaceID, "branch": "no-such-branch", "create": false},
	}); err != nil {
		t.Fatal(err)
	}
	response := readGitResponse(t, connection, "git-2")
	if response.OK {
		t.Fatal("git.checkout should fail for a missing branch")
	}
	if response.Error == "" {
		t.Fatal("expected an error message")
	}
}

func TestGitDiffOverWebSocket(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: "secret"}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}
	if welcome["t"] != "welcome" {
		t.Fatalf("unexpected welcome: %#v", welcome)
	}

	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: "git-3", Method: "git.diff",
		Params: map[string]any{"workspace": workspaceID, "path": "a.txt"},
	}); err != nil {
		t.Fatal(err)
	}
	response := readGitResponse(t, connection, "git-3")
	if !response.OK {
		t.Fatalf("git.diff failed: %v", response.Error)
	}
	result, ok := response.Result.(map[string]any)
	if !ok {
		t.Fatalf("result = %#v, want object", response.Result)
	}
	if _, ok := result["diff"]; !ok {
		t.Fatalf("result = %#v, want diff field", result)
	}
	if _, ok := result["content"]; !ok {
		t.Fatalf("result = %#v, want content field", result)
	}
}

func TestGitCreatePullRequestRequiresTitleOverWebSocket(t *testing.T) {
	repository := newRepositoryForServiceTest(t)
	service, workspaceID := gitPanelService(t, repository)
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.Default()).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connection, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: "secret"}); err != nil {
		t.Fatal(err)
	}
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		t.Fatal(err)
	}

	if err := connection.WriteJSON(api.Envelope{
		Type: "request", ID: "git-4", Method: "git.pr.create",
		Params: map[string]any{"workspace": workspaceID, "title": "", "body": ""},
	}); err != nil {
		t.Fatal(err)
	}
	response := readGitResponse(t, connection, "git-4")
	if response.OK {
		t.Fatal("git.pr.create should fail without a title")
	}
	if response.Error == "" {
		t.Fatal("expected an error message")
	}
}
