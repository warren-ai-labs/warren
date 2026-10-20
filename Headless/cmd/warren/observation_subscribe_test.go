package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// sessionRead is an observation command: it must attach without claiming the
// terminal's input lease, otherwise reading a Session would mute the client the
// user is typing into.
func TestSessionReadObservesWithoutClaimingTheInputLease(t *testing.T) {
	upgrader := websocket.Upgrader{}
	params := make(chan map[string]any, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var auth map[string]any
		if connection.ReadJSON(&auth) != nil {
			return
		}
		if connection.WriteJSON(map[string]any{
			"t": "welcome", "version": api.Version,
			"host":          map[string]any{"id": store.NewID()},
			"accessScopeId": "test-scope",
		}) != nil {
			return
		}
		for {
			kind, data, err := connection.ReadMessage()
			if err != nil {
				return
			}
			if kind != websocket.TextMessage {
				continue
			}
			var envelope struct {
				ID     string         `json:"id"`
				Method string         `json:"method"`
				Params map[string]any `json:"params"`
			}
			if json.Unmarshal(data, &envelope) != nil {
				return
			}
			switch envelope.Method {
			case "session.subscribe":
				params <- envelope.Params
				_ = connection.WriteJSON(map[string]any{
					"t": "response", "id": envelope.ID, "ok": true,
					"result": map[string]any{"subscribed": true, "attachmentId": "attachment-1"},
				})
			case "roster":
				_ = connection.WriteJSON(map[string]any{
					"t": "response", "id": envelope.ID, "ok": true,
					"result": map[string]any{
						"sessions": []map[string]any{{"id": "session-1", "lifecycle": "running"}},
					},
				})
			}
		}
	}))
	defer server.Close()

	previousURL, previousToken, previousName, previousPath := endpointURL, endpointToken, endpointName, configPath
	endpointURL, endpointToken, endpointName, configPath = server.URL, "secret", "", ""
	t.Cleanup(func() {
		endpointURL, endpointToken, endpointName, configPath = previousURL, previousToken, previousName, previousPath
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, value, err := connect()
	if err != nil {
		t.Fatal(err)
	}
	defer value.Close()

	if err := sessionRead(ctx, value, map[string]any{"_": []string{"session-1"}, "timeout": "200ms"}, false); err != nil {
		t.Fatalf("session read: %v", err)
	}
	subscribe := <-params
	if _, claimed := subscribe["claim"]; claimed {
		t.Fatalf("session read claimed the input lease: %#v", subscribe)
	}
}
