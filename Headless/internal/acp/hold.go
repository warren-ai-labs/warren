package acp

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// A holder keeps one agent alive across Host restarts, the way Ghostline keeps
// a PTY alive. It owns the agent's stdio and serves it on a Unix socket; the
// Host attaches, speaks ACP through it, and detaches when it exits.
//
// The holder forwards ACP lines unchanged but reads their ids, so a Host that
// attaches again learns which of its requests the agent has not answered and
// receives again the agent requests it had not answered itself. Agent output
// that arrives while no Host is attached is queued. Control messages share the
// stream as single-key objects no JSON-RPC message can collide with.

// HoldVersion is the holder protocol version. A Host refuses a holder that
// speaks another one.
const HoldVersion = 1

// holdQueueLimit bounds agent output queued while no Host is attached. Past
// it the oldest notifications are dropped; requests and responses never are.
const holdQueueLimit = 64 << 20

const (
	holdAttachTimeout    = 5 * time.Second
	holdFlushTimeout     = 5 * time.Second
	holdDetachTimeout    = 3 * time.Second
	holdTerminateTimeout = 2*terminateGrace + time.Second
)

// ErrHoldEnding means the holder's agent exited or is being terminated.
var ErrHoldEnding = errors.New("acp holder is ending")

// ErrHoldMismatch means the socket is served by a holder for another Session
// or another protocol version.
var ErrHoldMismatch = errors.New("acp holder mismatch")

var holdPrefix = []byte(`{"warrenHold":`)

// HoldSpec describes one held agent.
type HoldSpec struct {
	Socket string `json:"socket"`
	// Key names the Session the holder serves; Attach checks it.
	Key    string        `json:"key"`
	Launch LaunchOptions `json:"launch"`
}

// HoldInfo is what a holder reports when a Host attaches.
type HoldInfo struct {
	Version int    `json:"version"`
	Key     string `json:"key"`
	// ID names this holder for its lifetime, so ids derived from the agent's
	// request ids stay stable across attaches.
	ID  string `json:"id"`
	PID int    `json:"pid"`
	// NextID is the highest numeric request id a Host has sent; a new
	// connection must continue after it.
	NextID int64 `json:"nextId"`
	// Open lists Host requests the agent has not answered yet.
	Open []HoldRequest `json:"open,omitempty"`
	// State is the last value the Host stored with SetState.
	State json.RawMessage `json:"state,omitempty"`
	// Ending means the agent exited or was told to; the holder takes no Host.
	Ending bool `json:"ending,omitempty"`
}

// HoldRequest is one Host request awaiting the agent's answer.
type HoldRequest struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
}

type holdControl struct {
	Attach    *holdAttach     `json:"attach,omitempty"`
	Attached  *HoldInfo       `json:"attached,omitempty"`
	State     json.RawMessage `json:"state,omitempty"`
	Detach    bool            `json:"detach,omitempty"`
	Detached  bool            `json:"detached,omitempty"`
	Terminate bool            `json:"terminate,omitempty"`
	Exited    *holdExit       `json:"exited,omitempty"`
}

type holdAttach struct {
	Version int    `json:"version"`
	Key     string `json:"key"`
}

type holdExit struct {
	Detail string `json:"detail"`
}

type holdEnvelope struct {
	Control holdControl `json:"warrenHold"`
}

func encodeHoldControl(control holdControl) []byte {
	encoded, _ := json.Marshal(holdEnvelope{Control: control})
	return append(encoded, '\n')
}

func decodeHoldControl(line []byte) (holdControl, bool) {
	if !bytes.HasPrefix(line, holdPrefix) {
		return holdControl{}, false
	}
	var envelope holdEnvelope
	if json.Unmarshal(line, &envelope) != nil {
		return holdControl{}, false
	}
	return envelope.Control, true
}

// ---------------------------------------------------------------------------
// Holder

type holdLine struct {
	data []byte
	// request is the id of an agent request, so its delivery is recorded.
	request string
	// response is the id of the Host request this line answers. The request
	// stays open until the answer is delivered, so a Host that attaches while
	// it is queued still awaits it.
	response string
	// droppable marks a notification the queue may shed when full.
	droppable bool
	// final is the exit notice; the connection closes after it.
	final bool
}

type holdOpen struct {
	key       string
	seq       uint64
	data      []byte
	delivered bool
}

type holdClient struct {
	conn      net.Conn
	detaching bool
	once      sync.Once
	done      chan struct{}
}

func (client *holdClient) finish() {
	client.once.Do(func() {
		_ = client.conn.Close()
		close(client.done)
	})
}

type holder struct {
	spec     HoldSpec
	id       string
	proc     *Process
	listener net.Listener
	socket   os.FileInfo
	finished chan struct{}

	stdinMu sync.Mutex

	mu        sync.Mutex
	cond      *sync.Cond
	client    *holdClient
	queue     []holdLine
	queued    int
	seq       uint64
	agentOpen map[string]*holdOpen
	hostOpen  map[string]HoldRequest
	nextID    int64
	state     json.RawMessage
	exited    bool
	ending    bool
}

// Hold starts the agent and serves it on spec.Socket until the agent exits.
// ready is called once, with nil when the socket accepts attaches.
func Hold(ctx context.Context, spec HoldSpec, ready func(error)) error {
	proc, err := Start(ctx, spec.Launch)
	if err != nil {
		ready(err)
		return err
	}
	listener, info, err := listenHold(spec.Socket)
	if err != nil {
		proc.Close()
		ready(err)
		return err
	}
	token := make([]byte, 6)
	_, _ = rand.Read(token)
	h := &holder{
		spec:      spec,
		id:        hex.EncodeToString(token),
		proc:      proc,
		listener:  listener,
		socket:    info,
		finished:  make(chan struct{}),
		agentOpen: make(map[string]*holdOpen),
		hostOpen:  make(map[string]HoldRequest),
	}
	h.cond = sync.NewCond(&h.mu)
	ready(nil)
	go h.accept()
	h.readAgent()
	<-h.finished
	_ = listener.Close()
	// Remove the socket only while it is still this holder's; a replacement
	// may have taken the path.
	if current, err := os.Stat(spec.Socket); err == nil && os.SameFile(current, info) {
		_ = os.Remove(spec.Socket)
	}
	return nil
}

func listenHold(path string) (net.Listener, os.FileInfo, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, nil, err
	}
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, nil, err
	}
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		return nil, nil, err
	}
	info, err := os.Stat(path)
	if err != nil {
		_ = listener.Close()
		return nil, nil, err
	}
	return listener, info, nil
}

func (h *holder) accept() {
	for {
		conn, err := h.listener.Accept()
		if err != nil {
			return
		}
		go h.serve(conn)
	}
}

// readAgent queues everything the agent writes, then the exit notice.
func (h *holder) readAgent() {
	scanner := bufio.NewScanner(h.proc.Stdout())
	scanner.Buffer(make([]byte, 64*1024), maxMessageBytes)
	for scanner.Scan() {
		raw := scanner.Bytes()
		var message wireMessage
		if len(raw) == 0 || json.Unmarshal(raw, &message) != nil {
			continue
		}
		line := holdLine{data: append(append(make([]byte, 0, len(raw)+1), raw...), '\n')}
		h.mu.Lock()
		switch {
		case message.Method != "" && len(message.ID) > 0:
			key := string(message.ID)
			h.seq++
			h.agentOpen[key] = &holdOpen{key: key, seq: h.seq, data: line.data}
			line.request = key
		case len(message.ID) > 0:
			line.response = string(message.ID)
		default:
			line.droppable = true
		}
		h.enqueueLocked(line)
		h.mu.Unlock()
	}
	select {
	case <-h.proc.Exited():
	case <-time.After(terminateGrace):
		h.proc.Close()
	}
	detail := h.proc.DescribeExit()
	h.mu.Lock()
	h.exited = true
	h.enqueueLocked(holdLine{data: encodeHoldControl(holdControl{Exited: &holdExit{Detail: detail}}), final: true})
	client := h.client
	h.mu.Unlock()
	if client != nil {
		select {
		case <-client.done:
		case <-time.After(holdFlushTimeout):
			client.finish()
		}
	}
	close(h.finished)
}

func (h *holder) enqueueLocked(line holdLine) {
	h.queue = append(h.queue, line)
	h.queued += len(line.data)
	for index := 0; h.queued > holdQueueLimit && index < len(h.queue); {
		if !h.queue[index].droppable {
			index++
			continue
		}
		h.queued -= len(h.queue[index].data)
		h.queue = append(h.queue[:index], h.queue[index+1:]...)
	}
	h.cond.Broadcast()
}

func (h *holder) infoLocked() HoldInfo {
	info := HoldInfo{Version: HoldVersion, Key: h.spec.Key, ID: h.id, PID: h.proc.PID(), NextID: h.nextID, State: h.state, Ending: h.exited || h.ending}
	for _, request := range h.hostOpen {
		info.Open = append(info.Open, request)
	}
	sort.Slice(info.Open, func(i, j int) bool { return string(info.Open[i].ID) < string(info.Open[j].ID) })
	return info
}

// serve attaches one Host. A newer attach replaces an older one.
func (h *holder) serve(conn net.Conn) {
	reader := bufio.NewReaderSize(conn, 64*1024)
	_ = conn.SetReadDeadline(time.Now().Add(holdAttachTimeout))
	line, err := reader.ReadBytes('\n')
	control, ok := decodeHoldControl(line)
	if err != nil || !ok || control.Attach == nil {
		_ = conn.Close()
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	h.mu.Lock()
	info := h.infoLocked()
	if info.Ending || control.Attach.Version != HoldVersion || control.Attach.Key != h.spec.Key {
		h.mu.Unlock()
		// Answer a mismatch so the Host can tell it apart from a dead socket.
		_, _ = conn.Write(encodeHoldControl(holdControl{Attached: &info}))
		_ = conn.Close()
		return
	}
	previous := h.client
	client := &holdClient{conn: conn, done: make(chan struct{})}
	h.client = client
	// Requests the previous Host received but never answered go first; the
	// rest of what it never received is still queued behind them.
	var resend []*holdOpen
	for _, open := range h.agentOpen {
		if open.delivered {
			resend = append(resend, open)
		}
	}
	sort.Slice(resend, func(i, j int) bool { return resend[i].seq < resend[j].seq })
	lines := make([]holdLine, 0, len(resend)+len(h.queue))
	for _, open := range resend {
		open.delivered = false
		lines = append(lines, holdLine{data: open.data, request: open.key})
		h.queued += len(open.data)
	}
	h.queue = append(lines, h.queue...)
	_, writeErr := conn.Write(encodeHoldControl(holdControl{Attached: &info}))
	h.cond.Broadcast()
	h.mu.Unlock()
	if previous != nil {
		previous.finish()
	}
	if writeErr != nil {
		h.release(client)
		return
	}
	go h.write(client)
	h.readHost(client, reader)
}

// release forgets client when it is still the attached Host.
func (h *holder) release(client *holdClient) {
	h.mu.Lock()
	if h.client == client {
		h.client = nil
		h.cond.Broadcast()
	}
	h.mu.Unlock()
	client.finish()
}

func (h *holder) write(client *holdClient) {
	for {
		h.mu.Lock()
		for h.client == client && !client.detaching && len(h.queue) == 0 {
			h.cond.Wait()
		}
		if h.client != client {
			h.mu.Unlock()
			return
		}
		if client.detaching {
			h.client = nil
			h.mu.Unlock()
			_, _ = client.conn.Write(encodeHoldControl(holdControl{Detached: true}))
			client.finish()
			return
		}
		line := h.queue[0]
		h.queue = h.queue[1:]
		h.queued -= len(line.data)
		h.mu.Unlock()

		_, err := client.conn.Write(line.data)
		h.mu.Lock()
		if err != nil {
			h.queue = append([]holdLine{line}, h.queue...)
			h.queued += len(line.data)
			if h.client == client {
				h.client = nil
			}
			h.mu.Unlock()
			client.finish()
			return
		}
		if open := h.agentOpen[line.request]; line.request != "" && open != nil {
			open.delivered = true
		}
		if line.response != "" {
			delete(h.hostOpen, line.response)
		}
		h.mu.Unlock()
		if line.final {
			client.finish()
			return
		}
	}
}

// readHost forwards the Host's lines to the agent. A line cut short by a
// crashed Host is dropped rather than corrupting the agent's input.
func (h *holder) readHost(client *holdClient, reader *bufio.Reader) {
	defer h.release(client)
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			h.forward(client, line)
		}
		if err != nil {
			return
		}
	}
}

func (h *holder) forward(client *holdClient, line []byte) {
	if control, ok := decodeHoldControl(line); ok {
		switch {
		case len(control.State) > 0:
			h.mu.Lock()
			h.state = append(json.RawMessage(nil), control.State...)
			h.mu.Unlock()
		case control.Detach:
			h.mu.Lock()
			client.detaching = true
			h.cond.Broadcast()
			h.mu.Unlock()
		case control.Terminate:
			h.mu.Lock()
			h.ending = true
			h.mu.Unlock()
			go h.proc.Close()
		}
		return
	}
	var message wireMessage
	if json.Unmarshal(line, &message) == nil && len(message.ID) > 0 {
		key := string(message.ID)
		h.mu.Lock()
		if message.Method != "" {
			h.hostOpen[key] = HoldRequest{ID: append(json.RawMessage(nil), message.ID...), Method: message.Method}
			if id, err := strconv.ParseInt(key, 10, 64); err == nil && id > h.nextID {
				h.nextID = id
			}
		} else {
			delete(h.agentOpen, key)
		}
		h.mu.Unlock()
	}
	h.stdinMu.Lock()
	_, _ = h.proc.Stdin().Write(line)
	h.stdinMu.Unlock()
}

// ---------------------------------------------------------------------------
// Launching

// StartHold runs a holder inside this process. The agent then lives as long
// as the process does, which is what tests and embedders without a holder
// executable get.
func StartHold(ctx context.Context, spec HoldSpec) error {
	ready := make(chan error, 1)
	go func() {
		_ = Hold(ctx, spec, func(err error) { ready <- err })
	}()
	select {
	case err := <-ready:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// SpawnHold runs a holder as its own process, in a new session, so it
// outlives the caller. argv is the holder command; it receives spec on stdin
// and runs ServeHold.
func SpawnHold(ctx context.Context, argv []string, spec HoldSpec) error {
	if len(argv) == 0 {
		return errors.New("acp holder command is required")
	}
	encoded, err := json.Marshal(spec)
	if err != nil {
		return err
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = bytes.NewReader(encoded)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	answer := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		answer <- strings.TrimSpace(line)
	}()
	select {
	case line := <-answer:
		if line == "ok" {
			return nil
		}
		if detail, ok := strings.CutPrefix(line, "error: "); ok {
			return errors.New(detail)
		}
		return fmt.Errorf("acp holder exited before it was ready")
	case <-ctx.Done():
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		return ctx.Err()
	}
}

// ServeHold is the holder process: it reads a HoldSpec from stdin, reports
// "ok" or "error: ..." on stdout, and serves until the agent exits. It returns
// the process exit code.
func ServeHold() int {
	var spec HoldSpec
	if err := json.NewDecoder(os.Stdin).Decode(&spec); err != nil {
		fmt.Fprintf(os.Stdout, "error: read spec: %s\n", err)
		return 1
	}
	err := Hold(context.Background(), spec, func(err error) {
		if err != nil {
			fmt.Fprintf(os.Stdout, "error: %s\n", strings.ReplaceAll(err.Error(), "\n", " "))
		} else {
			fmt.Fprintln(os.Stdout, "ok")
		}
		// Nobody reads stdout after this; closing it turns a stray write into
		// an error instead of SIGPIPE.
		_ = os.Stdout.Close()
	})
	if err != nil {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// Host side

// Held is a Host's connection to a holder. It has the shape of a Process:
// Stdin and Stdout carry ACP, Exited closes when the connection ends.
type Held struct {
	conn    net.Conn
	info    HoldInfo
	writeMu sync.Mutex
	stdout  *io.PipeReader
	exited  chan struct{}

	mu     sync.Mutex
	detail string

	stateMu     sync.Mutex
	state       []byte
	stateSignal chan struct{}

	terminateOnce sync.Once
	terminateErr  error
	once          sync.Once
}

// Attach connects to the holder at socket, which must serve key.
func Attach(ctx context.Context, socket, key string) (*Held, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(holdAttachTimeout)
	if value, ok := ctx.Deadline(); ok && value.Before(deadline) {
		deadline = value
	}
	_ = conn.SetDeadline(deadline)
	if _, err := conn.Write(encodeHoldControl(holdControl{Attach: &holdAttach{Version: HoldVersion, Key: key}})); err != nil {
		_ = conn.Close()
		return nil, err
	}
	reader := bufio.NewReaderSize(conn, 64*1024)
	line, err := reader.ReadBytes('\n')
	control, ok := decodeHoldControl(line)
	if err != nil || !ok || control.Attached == nil {
		_ = conn.Close()
		if err == nil {
			err = errors.New("acp holder did not answer the attach")
		}
		return nil, err
	}
	info := *control.Attached
	if info.Ending {
		_ = conn.Close()
		return nil, ErrHoldEnding
	}
	if info.Version != HoldVersion || info.Key != key {
		_ = conn.Close()
		return nil, fmt.Errorf("%w: version %d for %q", ErrHoldMismatch, info.Version, info.Key)
	}
	_ = conn.SetDeadline(time.Time{})
	stdout, sink := io.Pipe()
	held := &Held{conn: conn, info: info, stdout: stdout, exited: make(chan struct{}), stateSignal: make(chan struct{}, 1)}
	go held.read(reader, sink)
	go held.sendState()
	return held, nil
}

func (held *Held) read(reader *bufio.Reader, sink *io.PipeWriter) {
	defer close(held.exited)
	defer sink.Close()
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 && line[len(line)-1] == '\n' {
			if control, ok := decodeHoldControl(line); ok {
				if control.Exited != nil {
					held.mu.Lock()
					held.detail = control.Exited.Detail
					held.mu.Unlock()
				}
			} else if _, writeErr := sink.Write(line); writeErr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// Info is what the holder reported on attach.
func (held *Held) Info() HoldInfo { return held.info }

// Stdout carries the agent's ACP output.
func (held *Held) Stdout() io.Reader { return held.stdout }

// Stdin carries ACP to the agent.
func (held *Held) Stdin() io.Writer { return heldWriter{held} }

type heldWriter struct{ held *Held }

func (writer heldWriter) Write(data []byte) (int, error) {
	writer.held.writeMu.Lock()
	defer writer.held.writeMu.Unlock()
	return writer.held.conn.Write(data)
}

// Exited is closed when the connection ends: the agent exited, the holder
// went away, or the Host detached.
func (held *Held) Exited() <-chan struct{} { return held.exited }

// PID is the agent's process ID.
func (held *Held) PID() int { return held.info.PID }

// DescribeExit summarizes the agent's exit for an error event.
func (held *Held) DescribeExit() string {
	held.mu.Lock()
	defer held.mu.Unlock()
	if held.detail != "" {
		return held.detail
	}
	return "its holder process ended"
}

// SetState stores value in the holder, where the next Attach finds it. It
// never blocks; only the latest value is sent.
func (held *Held) SetState(value []byte) {
	held.stateMu.Lock()
	held.state = value
	held.stateMu.Unlock()
	select {
	case held.stateSignal <- struct{}{}:
	default:
	}
}

func (held *Held) sendState() {
	for {
		select {
		case <-held.exited:
			return
		case <-held.stateSignal:
		}
		held.stateMu.Lock()
		value := held.state
		held.stateMu.Unlock()
		if len(value) > 0 {
			_ = held.control(holdControl{State: value})
		}
	}
}

func (held *Held) control(control holdControl) error {
	_, err := heldWriter{held}.Write(encodeHoldControl(control))
	return err
}

// Detach leaves the agent running. Everything the agent sent before the
// holder stopped forwarding reaches Stdout before the connection ends.
func (held *Held) Detach() {
	held.once.Do(func() {
		if held.control(holdControl{Detach: true}) == nil {
			select {
			case <-held.exited:
			case <-time.After(holdDetachTimeout):
			}
		}
		_ = held.conn.Close()
	})
}

// Terminate tells the holder to end the agent and take no further Host,
// without waiting for the agent to exit. Close then waits for it.
func (held *Held) Terminate() {
	held.terminateOnce.Do(func() {
		held.terminateErr = held.control(holdControl{Terminate: true})
	})
}

// Close ends the agent and its holder. It is safe to call more than once and
// after Detach, which it then leaves in effect.
func (held *Held) Close() {
	held.once.Do(func() {
		held.Terminate()
		if held.terminateErr == nil {
			select {
			case <-held.exited:
			case <-time.After(holdTerminateTimeout):
			}
		}
		_ = held.conn.Close()
	})
}
