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
	hostID         string
	accessScopeID  string
	replica        *agentReplica
	connection     *websocket.Conn
	inputSessionID string
	attachmentID   string
	inputSequence  uint64
	mu             sync.Mutex
	pendingMu      sync.Mutex
	pending        []inboundMessage
	closeOnce      sync.Once
	closeErr       error
	closeHook      func()
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
		"capabilities":         api.HostCapabilities(),
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
		"capabilities":         api.HostCapabilities(),
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
	dialer := *websocket.DefaultDialer
	dialer.EnableCompression = true
	connection, response, err := dialer.DialContext(ctx, endpoint, http.Header{})
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
	host, _ := welcome["host"].(map[string]any)
	client.hostID, _ = host["id"].(string)
	client.accessScopeID, _ = welcome["accessScopeId"].(string)
	if welcome["version"] != api.Version || client.hostID == "" || client.accessScopeID == "" {
		connection.Close()
		return nil, errors.New("incompatible welcome: protocol 4.0 and replica namespace are required")
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
		if c.replica != nil {
			_ = c.replica.db.Close()
		}
		c.mu.Lock()
		hook := c.closeHook
		c.mu.Unlock()
		if hook != nil {
			hook()
		}
	})
	return c.closeErr
}

func (c *Client) Request(ctx context.Context, method string, params any, result any) error {
	encodedParams, err := requestParams(params)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	id := store.NewID()
	if err := c.connection.WriteJSON(api.Envelope{Type: "request", ID: id, Method: method, Params: encodedParams}); err != nil {
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
		var response struct {
			Type   string          `json:"t"`
			ID     string          `json:"id"`
			OK     bool            `json:"ok"`
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if json.Unmarshal(data, &response) == nil && response.Type == "response" && response.ID == id {
			if !response.OK {
				var detail struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				}
				if json.Unmarshal(response.Error, &detail) == nil && detail.Code != "" {
					return fmt.Errorf("%s: %s", detail.Code, detail.Message)
				}
				var message string
				_ = json.Unmarshal(response.Error, &message)
				return errors.New(message)
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

func requestParams(value any) (map[string]any, error) {
	if value == nil {
		return nil, nil
	}
	if result, ok := value.(map[string]any); ok {
		return result, nil
	}
	data, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("encode request parameters: %w", err)
	}
	var result map[string]any
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, fmt.Errorf("encode request parameters: %w", err)
	}
	return result, nil
}

func (c *Client) Roster(ctx context.Context) (api.State, error) {
	var value api.State
	err := c.Request(ctx, "roster", nil, &value)
	return value, err
}

func (c *Client) Subscribe(ctx context.Context, sessionID string) (api.Session, error) {
	var result struct {
		Subscribed   bool   `json:"subscribed"`
		AttachmentID string `json:"attachmentId"`
	}
	if err := c.Request(ctx, "session.subscribe", map[string]any{
		"id":    sessionID,
		"claim": true,
	}, &result); err != nil {
		return api.Session{}, err
	}
	if !result.Subscribed || strings.TrimSpace(result.AttachmentID) == "" {
		return api.Session{}, errors.New("Host did not return a terminal attachment")
	}
	state, err := c.Roster(ctx)
	if err != nil {
		return api.Session{}, err
	}
	for _, session := range state.Sessions {
		if session.ID != sessionID {
			continue
		}
		c.mu.Lock()
		c.inputSessionID = sessionID
		c.attachmentID = result.AttachmentID
		c.inputSequence = 0
		c.mu.Unlock()
		return session, nil
	}
	return api.Session{}, fmt.Errorf("session not found: %s", sessionID)
}

func (c *Client) Input(ctx context.Context, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		if c.inputSessionID == "" || c.attachmentID == "" {
			return errors.New("terminal subscription is required before input")
		}
		frame, err := output.EncodeInput(output.InputMetadata{
			Version:      api.Version,
			SessionID:    c.inputSessionID,
			AttachmentID: c.attachmentID,
			Sequence:     c.inputSequence,
		}, data)
		if err != nil {
			return err
		}
		c.inputSequence++
		return c.connection.WriteMessage(websocket.BinaryMessage, frame)
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

func (c *Client) AgentExecution(ctx context.Context, executionID string) (api.AgentExecution, error) {
	var value api.AgentExecution
	err := c.Request(ctx, "agent.execution.get", map[string]any{"executionId": executionID}, &value)
	return value, err
}

func (c *Client) SubscribeAgentEvents(ctx context.Context, request api.AgentEventsSubscriptionRequest) (api.AgentEventsSubscriptionResult, error) {
	var value api.AgentEventsSubscriptionResult
	err := c.Request(ctx, "agent.events.subscribe", request, &value)
	if err == nil {
		err = c.persistAgentEvents(value.StreamID, value.Events)
	}
	return value, err
}

func (c *Client) AgentEventsHistory(ctx context.Context, request api.AgentEventsHistoryRequest) (api.AgentEventsHistoryResult, error) {
	var value api.AgentEventsHistoryResult
	err := c.Request(ctx, "agent.events.history", request, &value)
	if err == nil {
		err = c.persistAgentEvents(value.StreamID, value.Events)
	}
	return value, err
}

func (c *Client) ResumeAgentExecution(ctx context.Context, command api.AgentCommand) (api.AgentCommandReceipt, error) {
	var value api.AgentCommandReceipt
	err := c.Request(ctx, "agent.execution.resume", command, &value)
	return value, err
}

func (c *Client) StartAgentTurn(ctx context.Context, command api.AgentTurnStartCommand) (api.AgentCommandReceipt, error) {
	var value api.AgentCommandReceipt
	err := c.Request(ctx, "agent.turn.start", command, &value)
	return value, err
}

func (c *Client) SteerAgentTurn(ctx context.Context, command api.AgentTurnSteerCommand) (api.AgentCommandReceipt, error) {
	var value api.AgentCommandReceipt
	err := c.Request(ctx, "agent.turn.steer", command, &value)
	return value, err
}

func (c *Client) CancelAgentTurn(ctx context.Context, command api.AgentTurnCancelCommand) (api.AgentCommandReceipt, error) {
	var value api.AgentCommandReceipt
	err := c.Request(ctx, "agent.turn.cancel", command, &value)
	return value, err
}

func (c *Client) ResolveAgentInteraction(ctx context.Context, command api.AgentInteractionResolveCommand) (api.AgentCommandReceipt, error) {
	var value api.AgentCommandReceipt
	err := c.Request(ctx, "agent.interaction.resolve", command, &value)
	return value, err
}

func (c *Client) SetAgentGoal(ctx context.Context, command api.AgentGoalSetCommand) (api.AgentCommandReceipt, error) {
	var value api.AgentCommandReceipt
	err := c.Request(ctx, "agent.goal.set", command, &value)
	return value, err
}

func (c *Client) ClearAgentGoal(ctx context.Context, command api.AgentGoalClearCommand) (api.AgentCommandReceipt, error) {
	var value api.AgentCommandReceipt
	err := c.Request(ctx, "agent.goal.clear", command, &value)
	return value, err
}

func (c *Client) PrepareAgentAttachment(ctx context.Context, command api.AgentAttachmentPrepareCommand) (api.AgentAttachmentPrepareResult, error) {
	var value api.AgentAttachmentPrepareResult
	err := c.Request(ctx, "agent.attachment.prepare", command, &value)
	return value, err
}

func (c *Client) PutAgentAttachmentChunk(ctx context.Context, command api.AgentAttachmentChunkCommand) (api.AgentAttachmentResult, error) {
	var value api.AgentAttachmentResult
	err := c.Request(ctx, "agent.attachment.chunk", command, &value)
	return value, err
}

func (c *Client) CompleteAgentAttachment(ctx context.Context, command api.AgentAttachmentCompleteCommand) (api.AgentAttachmentResult, error) {
	var value api.AgentAttachmentResult
	err := c.Request(ctx, "agent.attachment.complete", command, &value)
	return value, err
}

func (c *Client) AbortAgentAttachment(ctx context.Context, command api.AgentAttachmentAbortCommand) (api.AgentAttachmentResult, error) {
	var value api.AgentAttachmentResult
	err := c.Request(ctx, "agent.attachment.abort", command, &value)
	return value, err
}

// WaitAgentTurn consumes only canonical events from the subscribed execution.
// Turn numbers are a local CLI projection; stream identity prevents replacement
// executions from completing a wait for an earlier conversation.
func (c *Client) WaitAgentTurn(ctx context.Context, sessionID, streamID string, after, current uint64) (api.AgentTurn, error) {
	stopClose := context.AfterFunc(ctx, func() { _ = c.connection.Close() })
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
		var batch api.CanonicalAgentEventsMessage
		if json.Unmarshal(data, &batch) != nil || batch.Type != "agent.events" || batch.StreamID != streamID {
			continue
		}
		if err := c.persistAgentEvents(streamID, batch.Events); err != nil {
			return api.AgentTurn{}, err
		}
		for _, event := range batch.Events {
			if event.Type == "execution.replaced" {
				return api.AgentTurn{}, errors.New("agent execution replaced while waiting")
			}
			if event.Type == "status.changed" {
				if event.Payload["activity"] == "exited" {
					return api.AgentTurn{}, errors.New("agent process exited before the turn completed")
				}
			}
			var status api.AgentTurnStatus
			switch event.Type {
			case "turn.started":
				status = api.AgentTurnStarted
			case "turn.completed":
				status = api.AgentTurnCompleted
			case "turn.failed":
				status = api.AgentTurnFailed
			case "turn.cancelled":
				status = api.AgentTurnAborted
			default:
				continue
			}
			turn, err := strconv.ParseUint(event.TurnID, 10, 64)
			if err != nil {
				return api.AgentTurn{}, fmt.Errorf("invalid Host turn ID: %w", err)
			}
			if target == 0 && turn > after {
				target = turn
			}
			if turn == target && terminalAgentTurn(status) {
				return api.AgentTurn{ID: turn, Status: status}, nil
			}
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
