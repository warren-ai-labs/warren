package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
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
	closeOnce  sync.Once
	closeErr   error
	closeHook  func()
}

type inboundMessage struct {
	typeID int
	data   []byte
}

var relayHostIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func Dial(ctx context.Context, endpoint, token string) (*Client, error) {
	endpoint, err := daemonEndpoint(endpoint)
	if err != nil {
		return nil, err
	}
	return dial(ctx, endpoint, map[string]any{
		"t":                    "auth",
		"token":                token,
		"version":              api.Version,
		"capabilities":         []string{"roster-delta"},
		"terminalStateFormats": []string{terminalStateFormatANSI},
	})
}

// DialRelay connects a native client to an access capability issued by the
// Relay. Relay endpoints are not Headless HTTP roots: they use the scoped
// /h/{hostID}/v1/client/connect alias and authenticate with access_token.
func DialRelay(ctx context.Context, relayURL, hostID, accessToken string) (*Client, error) {
	endpoint, err := relayEndpoint(relayURL, hostID)
	if err != nil {
		return nil, err
	}
	accessToken = strings.TrimSpace(accessToken)
	if accessToken == "" {
		return nil, errors.New("Relay access token is required")
	}
	return dial(ctx, endpoint, map[string]any{
		"t":                    "auth",
		"access_token":         accessToken,
		"client_id":            store.NewID(),
		"version":              api.Version,
		"capabilities":         []string{"roster-delta"},
		"terminalStateFormats": []string{terminalStateFormatANSI},
	})
}

func daemonEndpoint(raw string) (string, error) {
	value := strings.TrimRight(strings.TrimSpace(raw), "/")
	if value == "" {
		return "", errors.New("daemon URL is required")
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Opaque != "" {
		return "", errors.New("invalid daemon URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" && parsed.Scheme != "ws" && parsed.Scheme != "wss" {
		return "", errors.New("daemon URL must use http, https, ws, or wss")
	}
	if strings.ContainsAny(parsed.Host+parsed.Path, "\r\n\x00") {
		return "", errors.New("invalid daemon URL")
	}
	path := strings.TrimRight(parsed.Path, "/")
	if !strings.HasSuffix(path, "/v1/ws") {
		path += "/v1/ws"
	}
	parsed.Path = path
	parsed.RawPath = ""
	if parsed.Scheme == "http" {
		parsed.Scheme = "ws"
	} else if parsed.Scheme == "https" {
		parsed.Scheme = "wss"
	}
	return parsed.String(), nil
}

func relayEndpoint(raw, hostID string) (string, error) {
	base := strings.TrimRight(strings.TrimSpace(raw), "/")
	if base == "" {
		return "", errors.New("Relay URL is required")
	}
	hostID = strings.TrimSpace(hostID)
	if hostID == "" {
		return "", errors.New("Relay Host ID is required")
	}
	hostID = strings.ToLower(hostID)
	if !relayHostIDPattern.MatchString(hostID) {
		return "", errors.New("invalid Relay Host ID")
	}
	parsed, err := url.Parse(base)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Opaque != "" {
		return "", errors.New("invalid Relay URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" && parsed.Scheme != "ws" && parsed.Scheme != "wss" {
		return "", errors.New("Relay URL must use http, https, ws, or wss")
	}
	if strings.ContainsAny(parsed.Host+parsed.Path, "\r\n\x00") || strings.HasPrefix(parsed.Path, "//") {
		return "", errors.New("invalid Relay URL")
	}
	for _, segment := range strings.Split(parsed.Path, "/") {
		if segment == "." || segment == ".." {
			return "", errors.New("Relay URL path traversal is not allowed")
		}
	}
	prefix := strings.TrimRight(parsed.Path, "/")
	suffix := "/h/" + hostID + "/v1/client/connect"
	if !strings.HasSuffix(prefix, suffix) {
		prefix += suffix
	}
	parsed.Path = prefix
	parsed.RawPath = ""
	if parsed.Scheme == "http" {
		parsed.Scheme = "ws"
	} else if parsed.Scheme == "https" {
		parsed.Scheme = "wss"
	}
	return parsed.String(), nil
}

func dial(ctx context.Context, endpoint string, auth map[string]any) (*Client, error) {
	connection, response, err := websocket.DefaultDialer.DialContext(ctx, endpoint, http.Header{})
	if err != nil {
		if response != nil {
			return nil, fmt.Errorf("connect %s: HTTP %d", endpoint, response.StatusCode)
		}
		return nil, fmt.Errorf("connect %s: %w", endpoint, err)
	}
	client := &Client{connection: connection}
	if err := connection.WriteJSON(auth); err != nil {
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

const terminalStateFormatANSI = "ghostline-vt-replay-v1"

// SetCloseHook registers a cleanup callback owned by the caller.  It is used
// by the CLI to tie an SSH tunnel's lifetime to the authenticated WebSocket;
// callers must set it before handing the client to command code.
func (c *Client) SetCloseHook(hook func()) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closeHook = hook
}

func (c *Client) Close() error {
	if c == nil {
		return nil
	}
	c.closeOnce.Do(func() {
		c.closeErr = c.connection.Close()
		c.mu.Lock()
		hook := c.closeHook
		c.mu.Unlock()
		if hook != nil {
			hook()
		}
	})
	return c.closeErr
}

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
			var payload []byte
			if frame, err := output.DecodeOutput(data); err == nil {
				payload = frame.Payload
			} else if state, stateErr := output.DecodeAtomicState(data); stateErr == nil {
				if state.Format != terminalStateFormatANSI {
					return fmt.Errorf("unsupported terminal state format %q", state.Format)
				}
				payload = state.Payload
			} else {
				return fmt.Errorf("decode terminal binary frame: %w", err)
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

// AgentHistory returns one bounded page of normalized transcript events. A
// zero before cursor starts at the newest page; callers can pass the returned
// cursor to walk towards older events.
func (c *Client) AgentHistory(
	ctx context.Context,
	sessionID string,
	before uint64,
	limit int,
) (api.AgentHistoryResult, error) {
	var value api.AgentHistoryResult
	err := c.Request(ctx, "agent.history", map[string]any{
		"session": sessionID,
		"before":  before,
		"limit":   limit,
	}, &value)
	return value, err
}

// AgentTranscriptChunk reads a bounded raw JSONL range from the transcript
// bound to sessionID. Offset is encoded as a decimal string so large files do
// not lose precision while crossing JSON's floating-point default.
func (c *Client) AgentTranscriptChunk(
	ctx context.Context,
	sessionID string,
	offset int64,
	limit int,
) (api.AgentTranscriptChunk, error) {
	var value api.AgentTranscriptChunk
	err := c.Request(ctx, "agent.transcript", map[string]any{
		"session": sessionID,
		"offset":  strconv.FormatInt(offset, 10),
		"limit":   strconv.Itoa(limit),
	}, &value)
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
			Type    string          `json:"t"`
			Session string          `json:"session"`
			Epoch   uint64          `json:"epoch"`
			Turn    uint64          `json:"turn"`
			Status  json.RawMessage `json:"status"`
		}
		if json.Unmarshal(data, &envelope) != nil || envelope.Session != sessionID {
			continue
		}
		if envelope.Type == "exited" {
			return api.AgentTurn{}, errors.New("agent session exited before the turn completed")
		}
		if envelope.Type == "agent.status" {
			var status api.AgentStatus
			if json.Unmarshal(envelope.Status, &status) == nil && status.Activity == api.AgentActivityExited {
				return api.AgentTurn{}, errors.New("agent process exited before the turn completed")
			}
			continue
		}
		var turnStatus api.AgentTurnStatus
		if json.Unmarshal(envelope.Status, &turnStatus) != nil {
			continue
		}
		if envelope.Type != "agent.turn" {
			continue
		}
		if epoch != 0 && envelope.Epoch != 0 && envelope.Epoch != epoch {
			return api.AgentTurn{}, errors.New("agent transcript changed while waiting")
		}
		if target == 0 && turnStatus == api.AgentTurnStarted && envelope.Turn > after {
			target = envelope.Turn
		}
		if target == 0 && envelope.Turn > after && terminalAgentTurn(turnStatus) {
			// Accept a terminal boundary even if a transport reconnect or a
			// coalesced producer omitted the corresponding started notification.
			target = envelope.Turn
		}
		if envelope.Turn == target && terminalAgentTurn(turnStatus) {
			return api.AgentTurn{ID: envelope.Turn, Status: turnStatus}, nil
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
