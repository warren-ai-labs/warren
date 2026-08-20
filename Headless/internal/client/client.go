package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

type Client struct {
	connection *websocket.Conn
	mu         sync.Mutex
	pendingMu  sync.Mutex
	pending    []inboundMessage
}

type inboundMessage struct {
	typeID int
	data   []byte
}

func Dial(ctx context.Context, endpoint, token string) (*Client, error) {
	endpoint = strings.TrimRight(endpoint, "/")
	endpoint = strings.Replace(endpoint, "http://", "ws://", 1)
	endpoint = strings.Replace(endpoint, "https://", "wss://", 1)
	if !strings.HasSuffix(endpoint, "/v1/ws") {
		endpoint += "/v1/ws"
	}
	if _, err := url.Parse(endpoint); err != nil {
		return nil, err
	}
	connection, response, err := websocket.DefaultDialer.DialContext(ctx, endpoint, http.Header{})
	if err != nil {
		if response != nil {
			return nil, fmt.Errorf("connect %s: HTTP %d", endpoint, response.StatusCode)
		}
		return nil, fmt.Errorf("connect %s: %w", endpoint, err)
	}
	client := &Client{connection: connection}
	if err := connection.WriteJSON(api.Envelope{Type: "auth", Token: token, Version: api.Version}); err != nil {
		connection.Close()
		return nil, err
	}
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	var welcome map[string]any
	if err := connection.ReadJSON(&welcome); err != nil {
		connection.Close()
		return nil, err
	}
	_ = connection.SetReadDeadline(time.Time{})
	if welcome["t"] != "welcome" {
		connection.Close()
		return nil, errors.New("authentication failed")
	}
	return client, nil
}

func (c *Client) Close() error { return c.connection.Close() }

func (c *Client) Request(ctx context.Context, method string, params map[string]any, result any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	id := store.NewID()
	if err := c.connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: params}); err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		messageType, data, err := c.connection.ReadMessage()
		if err != nil {
			return err
		}
		if messageType != websocket.TextMessage {
			c.stash(messageType, data)
			continue
		}
		var response api.Response
		if json.Unmarshal(data, &response) == nil && response.Type == "response" && response.ID == id {
			if !response.OK {
				return errors.New(response.Error)
			}
			if result != nil {
				raw, err := json.Marshal(response.Result)
				if err != nil {
					return err
				}
				return json.Unmarshal(raw, result)
			}
			return nil
		}
		c.stash(messageType, data)
	}
}

func (c *Client) Roster(ctx context.Context) (api.State, error) {
	var value api.State
	err := c.Request(ctx, "roster", nil, &value)
	return value, err
}

func (c *Client) Attach(ctx context.Context, sessionID string) (api.Session, error) {
	var value api.Session
	err := c.Request(ctx, "session.attach", map[string]any{"id": sessionID}, &value)
	return value, err
}

func (c *Client) Input(ctx context.Context, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		return c.connection.WriteMessage(websocket.BinaryMessage, data)
	}
}

func (c *Client) ReadOutput(ctx context.Context, onOutput func([]byte) bool) error {
	// ReadMessage blocks without a deadline, so a context timeout or
	// interrupt alone cannot wake it. Close the connection when the context
	// finishes; the read then returns and we translate the error back to the
	// context result.
	stopClose := context.AfterFunc(ctx, func() {
		_ = c.connection.Close()
	})
	defer stopClose()
	for {
		typeID, data, err := c.nextMessage()
		if err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return ctxErr
			}
			return err
		}
		if typeID == websocket.BinaryMessage {
			payload := data
			if frame, err := output.DecodeOutput(data); err == nil {
				payload = frame.Payload
			}
			if onOutput(payload) {
				return nil
			}
		}
	}
}

func (c *Client) AgentSnapshot(ctx context.Context, sessionID string) (api.AgentSnapshotResult, error) {
	var value api.AgentSnapshotResult
	err := c.Request(ctx, "agent.snapshot", map[string]any{"session": sessionID}, &value)
	return value, err
}

func (c *Client) SubscribeAgent(ctx context.Context, sessionID string) (api.AgentSubscriptionResult, error) {
	var value api.AgentSubscriptionResult
	err := c.Request(ctx, "agent.subscribe", map[string]any{"session": sessionID}, &value)
	return value, err
}

func (c *Client) AgentTurnEvents(ctx context.Context, sessionID string, turn uint64) ([]api.AgentEvent, error) {
	var value []api.AgentEvent
	err := c.Request(ctx, "agent.turn.events", map[string]any{"session": sessionID, "turn": turn}, &value)
	return value, err
}

// WaitAgentTurn blocks on the attached session until a turn newer than after
// reaches a terminal state. current may name an already-running turn that a
// standalone wait should join; send-and-wait callers pass zero.
func (c *Client) WaitAgentTurn(
	ctx context.Context,
	sessionID string,
	epoch, after, current uint64,
) (api.AgentTurn, error) {
	stopClose := context.AfterFunc(ctx, func() {
		_ = c.connection.Close()
	})
	defer stopClose()
	target := current
	for {
		messageType, data, err := c.nextMessage()
		if err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return api.AgentTurn{}, ctxErr
			}
			return api.AgentTurn{}, err
		}
		if messageType != websocket.TextMessage {
			continue
		}
		var envelope struct {
			Type     string              `json:"t"`
			Session  string              `json:"session"`
			Epoch    uint64              `json:"epoch"`
			Turn     uint64              `json:"turn"`
			Status   api.AgentTurnStatus `json:"status"`
			Activity api.AgentActivity   `json:"activity"`
		}
		if json.Unmarshal(data, &envelope) != nil || envelope.Session != sessionID {
			continue
		}
		if envelope.Type == "exited" {
			return api.AgentTurn{}, errors.New("agent session exited before the turn completed")
		}
		if envelope.Type == "agent.activity" && envelope.Activity == api.AgentActivityExited {
			return api.AgentTurn{}, errors.New("agent process exited before the turn completed")
		}
		if envelope.Type != "agent.turn" {
			continue
		}
		if epoch != 0 && envelope.Epoch != 0 && envelope.Epoch != epoch {
			return api.AgentTurn{}, errors.New("agent transcript changed while waiting")
		}
		if target == 0 && envelope.Status == api.AgentTurnStarted && envelope.Turn > after {
			target = envelope.Turn
		}
		if target == 0 && envelope.Turn > after && terminalAgentTurn(envelope.Status) {
			// Accept a terminal boundary even if a transport reconnect or a
			// coalesced producer omitted the corresponding started notification.
			target = envelope.Turn
		}
		if envelope.Turn == target && terminalAgentTurn(envelope.Status) {
			return api.AgentTurn{ID: envelope.Turn, Status: envelope.Status}, nil
		}
	}
}

func (c *Client) stash(typeID int, data []byte) {
	c.pendingMu.Lock()
	defer c.pendingMu.Unlock()
	c.pending = append(c.pending, inboundMessage{typeID: typeID, data: append([]byte(nil), data...)})
}

func (c *Client) nextMessage() (int, []byte, error) {
	c.pendingMu.Lock()
	if len(c.pending) > 0 {
		message := c.pending[0]
		c.pending[0] = inboundMessage{}
		c.pending = c.pending[1:]
		c.pendingMu.Unlock()
		return message.typeID, message.data, nil
	}
	c.pendingMu.Unlock()
	return c.connection.ReadMessage()
}

func terminalAgentTurn(status api.AgentTurnStatus) bool {
	switch status {
	case api.AgentTurnCompleted, api.AgentTurnFailed, api.AgentTurnAborted:
		return true
	default:
		return false
	}
}
