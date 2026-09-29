// Package acp is a client for the Agent Client Protocol
// (https://agentclientprotocol.com): JSON-RPC 2.0 carried as newline-delimited
// JSON over an agent subprocess's stdio.
//
// The package knows nothing about Warren Sessions. It owns the wire (framing,
// request correlation, inbound requests and notifications), the handful of
// protocol types Warren uses, and launching the agent process.
package acp

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
)

// maxMessageBytes bounds one JSON-RPC line. Agents embed file contents and
// diffs in tool updates, so this is generous, but a runaway line must not grow
// the Host without limit.
const maxMessageBytes = 32 << 20

// ErrClosed is returned for requests that cannot complete because the
// connection ended.
var ErrClosed = errors.New("acp connection closed")

// Error is a JSON-RPC error object returned by the agent.
type Error struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	if len(e.Data) > 0 && string(e.Data) != "null" {
		// Adapters put the useful detail in data.message; the top-level
		// message is often a generic "Internal error".
		var detail struct {
			Message string `json:"message"`
		}
		if json.Unmarshal(e.Data, &detail) == nil && strings.TrimSpace(detail.Message) != "" {
			return fmt.Sprintf("acp error %d: %s: %s", e.Code, e.Message, clip(detail.Message, 1024))
		}
		return fmt.Sprintf("acp error %d: %s (%s)", e.Code, e.Message, clip(string(e.Data), 512))
	}
	return fmt.Sprintf("acp error %d: %s", e.Code, e.Message)
}

// Well-known JSON-RPC and ACP error codes.
const (
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternalError  = -32603
	CodeAuthRequired   = -32000
)

// IsAuthRequired reports whether err is the ACP authentication-required error.
func IsAuthRequired(err error) bool {
	var rpcErr *Error
	return errors.As(err, &rpcErr) && rpcErr.Code == CodeAuthRequired
}

type wireMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

// Request is an inbound request from the agent. The handler must answer it
// exactly once with Reply or ReplyError; an unanswered request keeps the agent
// waiting, which is the intended behavior for a permission prompt.
type Request struct {
	ID     json.RawMessage
	Method string
	Params json.RawMessage

	conn *Conn
	once sync.Once
}

// Reply answers the request with result.
func (r *Request) Reply(result any) error {
	err := ErrClosed
	r.once.Do(func() {
		encoded, marshalErr := json.Marshal(result)
		if marshalErr != nil {
			err = marshalErr
			return
		}
		err = r.conn.write(wireMessage{JSONRPC: "2.0", ID: r.ID, Result: encoded})
	})
	return err
}

// ReplyError answers the request with a JSON-RPC error.
func (r *Request) ReplyError(code int, message string) error {
	err := ErrClosed
	r.once.Do(func() {
		err = r.conn.write(wireMessage{JSONRPC: "2.0", ID: r.ID, Error: &Error{Code: code, Message: message}})
	})
	return err
}

// Handler receives inbound traffic. Methods are called from the connection's
// read goroutine in wire order, so a handler must not block; long work (such
// as waiting for a person) keeps the Request and answers it later.
type Handler interface {
	HandleNotification(method string, params json.RawMessage)
	HandleRequest(request *Request)
}

type pendingCall struct {
	done   chan struct{}
	result json.RawMessage
	err    error
}

// Conn is one JSON-RPC connection. It is safe for concurrent use.
type Conn struct {
	writeMu sync.Mutex
	writer  io.Writer

	mu      sync.Mutex
	nextID  int64
	pending map[string]*pendingCall
	closed  bool
	doneErr error
	done    chan struct{}
}

// NewConn starts reading reader in a goroutine and dispatches to handler. The
// connection ends when reader returns EOF or an error, or when Close is called.
func NewConn(reader io.Reader, writer io.Writer, handler Handler) *Conn {
	conn := &Conn{writer: writer, pending: make(map[string]*pendingCall), done: make(chan struct{})}
	go conn.readLoop(reader, handler)
	return conn
}

// NewResumedConn continues a connection a previous Host began through a
// holder: request ids continue after nextID, and the calls in open still
// await their answers, which Await collects. The calls are registered before
// reading starts, so no answer is missed.
func NewResumedConn(reader io.Reader, writer io.Writer, handler Handler, nextID int64, open []json.RawMessage) *Conn {
	conn := &Conn{writer: writer, nextID: nextID, pending: make(map[string]*pendingCall), done: make(chan struct{})}
	for _, id := range open {
		conn.pending[string(id)] = &pendingCall{done: make(chan struct{})}
	}
	go conn.readLoop(reader, handler)
	return conn
}

// Await waits for the answer to an open call registered by NewResumedConn and
// decodes it into result.
func (c *Conn) Await(ctx context.Context, id json.RawMessage, result any) error {
	c.mu.Lock()
	call := c.pending[string(id)]
	closed, doneErr := c.closed, c.doneErr
	c.mu.Unlock()
	if call == nil {
		if closed {
			return doneErr
		}
		return fmt.Errorf("no open call %s", id)
	}
	return c.wait(ctx, string(id), call, result)
}

// Done is closed when the connection ends.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Err is the reason the connection ended, or nil while it is open.
func (c *Conn) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.doneErr
}

// Close ends the connection and fails every outstanding call.
func (c *Conn) Close() { c.finish(ErrClosed) }

func (c *Conn) finish(err error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	if err == nil {
		err = ErrClosed
	}
	c.doneErr = err
	pending := c.pending
	c.pending = make(map[string]*pendingCall)
	c.mu.Unlock()
	for _, call := range pending {
		call.err = err
		close(call.done)
	}
	close(c.done)
}

func (c *Conn) readLoop(reader io.Reader, handler Handler) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), maxMessageBytes)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var message wireMessage
		if err := json.Unmarshal(line, &message); err != nil {
			// A non-JSON line is a protocol violation by the agent. Skipping it
			// keeps one stray log line from ending an otherwise healthy session.
			continue
		}
		switch {
		case message.Method != "" && len(message.ID) > 0:
			if handler == nil {
				_ = c.write(wireMessage{JSONRPC: "2.0", ID: message.ID, Error: &Error{Code: CodeMethodNotFound, Message: "method not found"}})
				continue
			}
			handler.HandleRequest(&Request{ID: message.ID, Method: message.Method, Params: message.Params, conn: c})
		case message.Method != "":
			if handler != nil {
				handler.HandleNotification(message.Method, message.Params)
			}
		case len(message.ID) > 0:
			c.resolve(string(message.ID), message.Result, message.Error)
		}
	}
	err := scanner.Err()
	if err == nil {
		err = io.EOF
	}
	c.finish(err)
}

func (c *Conn) resolve(id string, result json.RawMessage, rpcErr *Error) {
	c.mu.Lock()
	call := c.pending[id]
	delete(c.pending, id)
	c.mu.Unlock()
	if call == nil {
		return
	}
	call.result = result
	if rpcErr != nil {
		call.err = rpcErr
	}
	close(call.done)
}

func (c *Conn) write(message wireMessage) error {
	encoded, err := json.Marshal(message)
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return ErrClosed
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err = c.writer.Write(encoded)
	return err
}

// Call sends a request and decodes its result into result (which may be nil).
func (c *Conn) Call(ctx context.Context, method string, params, result any) error {
	encodedParams, err := json.Marshal(params)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if c.closed {
		err := c.doneErr
		c.mu.Unlock()
		return err
	}
	c.nextID++
	id := strconv.FormatInt(c.nextID, 10)
	call := &pendingCall{done: make(chan struct{})}
	c.pending[id] = call
	c.mu.Unlock()
	if err := c.write(wireMessage{JSONRPC: "2.0", ID: json.RawMessage(id), Method: method, Params: encodedParams}); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return err
	}
	return c.wait(ctx, id, call, result)
}

func (c *Conn) wait(ctx context.Context, id string, call *pendingCall, result any) error {
	select {
	case <-call.done:
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return ctx.Err()
	}
	if call.err != nil {
		return call.err
	}
	if result == nil || len(call.result) == 0 {
		return nil
	}
	return json.Unmarshal(call.result, result)
}

// Notify sends a notification.
func (c *Conn) Notify(method string, params any) error {
	encoded, err := json.Marshal(params)
	if err != nil {
		return err
	}
	return c.write(wireMessage{JSONRPC: "2.0", Method: method, Params: encoded})
}

func clip(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit] + "…"
}
