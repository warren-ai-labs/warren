// Package relay implements the Headless side of the owned Relay transport.
// It deliberately depends only on net/http and the protocol primitives so
// the local daemon remains the authority for Sessions, PTYs, and transcripts.
package relay

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	version                       = "2.0"
	headerSize                    = 22
	maxFrameBytes                 = 8 * 1024 * 1024
	maxUpgradeHandshakeBytes      = 64 * 1024
	maxHTTPBodyBytes              = 64 * 1024 * 1024
	initialWindow                 = 16 * 1024 * 1024
	FrameOpen                byte = 1
	FrameClose               byte = 2
	FrameText                byte = 3
	FrameBinary              byte = 4
	FrameHTTPHeads           byte = 5
	FrameData                byte = 6
	FrameEnd                 byte = 7
	FrameWindow              byte = 8
	FrameError               byte = 9
	// Stable descriptive aliases used by callers that do not need the
	// abbreviated wire names above.
	FrameHTTPHeaders  byte = FrameHTTPHeads
	FrameWindowUpdate byte = FrameWindow
)

const (
	frameOpen      = FrameOpen
	frameClose     = FrameClose
	frameText      = FrameText
	frameBinary    = FrameBinary
	frameHTTPHeads = FrameHTTPHeads
	frameData      = FrameData
	frameEnd       = FrameEnd
	frameWindow    = FrameWindow
	frameError     = FrameError
)

const (
	// Control frames (WINDOW, CLOSE, ERROR, headers, and control-stream
	// responses) have a reserved queue so a burst of body frames cannot make
	// liveness or lifecycle progress wait behind data. The queues are bounded;
	// overflow is reported to the owning stream instead of growing memory.
	connectorControlQueueCapacity = 256
	connectorDataQueueCapacity    = 32
	connectorControlFairness      = 32
)

var magic = [4]byte{'B', 'R', 'L', 'Y'}

var errControlQueueOverflow = errors.New("control stream queue overflow")

// ConnectionID identifies one virtual stream on a Host connection. IDs are
// opaque and must never be reused while the underlying WebSocket is alive.
type ConnectionID [16]byte

type connectionID = ConnectionID

// Frame is one complete BRLY/2 message. Payload ownership belongs to the
// caller; Connector copies it before writing to the WebSocket.
type Frame struct {
	Kind    byte
	ID      ConnectionID
	Payload []byte
}

type frame = Frame

// StreamOpen describes a Relay-created virtual stream.
type StreamOpen struct {
	Class      string `json:"class"`
	Version    string `json:"version,omitempty"`
	RequestID  string `json:"request_id,omitempty"`
	DeadlineMS int64  `json:"deadline_ms,omitempty"`
	RouteID    string `json:"route_id,omitempty"`
	HostID     string `json:"host_id,omitempty"`
	ClientID   string `json:"client_id,omitempty"`
	Token      string `json:"access_token,omitempty"`
}

type streamOpen = StreamOpen

type challenge struct {
	Type         string   `json:"t"`
	Version      string   `json:"version"`
	Nonce        string   `json:"nonce"`
	RelayID      string   `json:"relay_id"`
	KeyID        string   `json:"key_id,omitempty"`
	Capabilities []string `json:"capabilities"`
}

type hello struct {
	Type         string   `json:"t"`
	Version      string   `json:"version"`
	HostID       string   `json:"host_id"`
	Capabilities []string `json:"capabilities"`
	Proof        string   `json:"proof"`
}

type welcome struct {
	Type       string `json:"t"`
	Version    string `json:"version"`
	Generation uint64 `json:"generation"`
}

// Config controls a supervised outbound Host connection. Handler is invoked
// in-process for HTTP streams; no loopback address is inferred or required.
type Config struct {
	URL             string
	HostID          string
	Name            string
	Secret          string
	Handler         http.Handler
	RelayPublicKeys map[string]ed25519.PublicKey
	Dial            func(context.Context, string, http.Header) (*websocket.Conn, *http.Response, error)
	Random          func() float64
	OnState         func(string)
	OnControl       func(context.Context, StreamOpen, Frame) error
}

type Connector struct {
	config     Config
	mu         sync.Mutex
	conn       *websocket.Conn
	stop       context.CancelFunc
	loopDone   chan struct{}
	run        bool
	generation uint64
	// connectionEpoch identifies one authenticated Host WebSocket incarnation.
	// Relay generation is an authority/capability version and must not be used
	// to fence goroutines that outlive a broken socket.
	connectionEpoch uint64
	streams         map[connectionID]*stream
	usedIDs         map[connectionID]uint64
	// writes protects the short JSON challenge/hello handshake before the
	// per-connection writer is installed. Data/control frames use writer.
	writes sync.Mutex
	writer *connectionWriter
	// lastState is the most recent state string forwarded to OnState. It is
	// exposed via State() for /healthz and other liveness probes.
	lastState string
	// lastError is the most recent connectOnce failure, retained so /healthz
	// can surface a stable error while the connector is between attempts.
	lastError string
}

type queuedWrite struct {
	messageType int
	data        []byte
	done        chan error
}

// connectionWriter is the sole owner of Gorilla's WebSocket write side for
// one authenticated connection. Callers enqueue a frame and wait only for
// that frame's result; they never hold Connector locks across network I/O.
type connectionWriter struct {
	connection *websocket.Conn
	epoch      uint64
	control    chan queuedWrite
	data       chan queuedWrite
	stop       chan struct{}
	stopped    chan struct{}
	stopOnce   sync.Once
	errMu      sync.Mutex
	err        error
}

func newConnectionWriter(connection *websocket.Conn, epoch uint64) *connectionWriter {
	return &connectionWriter{
		connection: connection,
		epoch:      epoch,
		control:    make(chan queuedWrite, connectorControlQueueCapacity),
		data:       make(chan queuedWrite, connectorDataQueueCapacity),
		stop:       make(chan struct{}),
		stopped:    make(chan struct{}),
	}
}

func (writer *connectionWriter) stopWith(err error) {
	if err == nil {
		err = errors.New("relay connection closed")
	}
	writer.stopOnce.Do(func() {
		writer.errMu.Lock()
		writer.err = err
		writer.errMu.Unlock()
		close(writer.stop)
	})
}

func (writer *connectionWriter) error() error {
	writer.errMu.Lock()
	defer writer.errMu.Unlock()
	if writer.err == nil {
		return errors.New("relay connection closed")
	}
	return writer.err
}

func (writer *connectionWriter) enqueue(value queuedWrite, control bool) error {
	queue := writer.data
	if control {
		queue = writer.control
	}
	select {
	case <-writer.stopped:
		return writer.error()
	case <-writer.stop:
		return writer.error()
	default:
	}
	select {
	case queue <- value:
		return nil
	default:
		if control {
			return errors.New("relay control writer queue full")
		}
		return errors.New("relay data writer queue full")
	}
}

func (writer *connectionWriter) run() {
	defer close(writer.stopped)
	controlBudget := 0
	for {
		var value queuedWrite
		select {
		case <-writer.stop:
			return
		default:
		}
		// Prefer control, but periodically yield to data so a continuous
		// response stream cannot starve terminal/HTTP bodies forever.
		if controlBudget < connectorControlFairness {
			select {
			case value = <-writer.control:
				controlBudget++
			default:
				select {
				case <-writer.stop:
					return
				case value = <-writer.control:
					controlBudget++
				case value = <-writer.data:
					controlBudget = 0
				}
			}
		} else {
			select {
			case <-writer.stop:
				return
			case value = <-writer.data:
				controlBudget = 0
			case value = <-writer.control:
				controlBudget = 1
			}
		}
		_ = writer.connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
		err := writer.connection.WriteMessage(value.messageType, value.data)
		value.done <- err
		if err != nil {
			writer.stopWith(err)
			return
		}
	}
}

type stream struct {
	open         streamOpen
	epoch        uint64
	ctx          context.Context
	body         *io.PipeWriter
	requestMu    sync.Mutex
	request      *http.Request
	start        sync.Once
	close        context.CancelFunc
	done         chan struct{}
	windowMu     sync.Mutex
	window       uint64
	windowChange chan struct{}
	control      chan frame
	controlDone  chan struct{}
	// firstHeaders guards the request/response boundary. A Relay request may
	// contain exactly one HTTP_HEADERS frame; subsequent headers are a
	// protocol error rather than an ambiguous second response.
	firstHeaders bool
	hijackedMu   sync.Mutex
	hijacked     *relayConn
}

func newStream(open streamOpen, epoch uint64, ctx context.Context, cancel context.CancelFunc) *stream {
	return &stream{
		open:         open,
		epoch:        epoch,
		ctx:          ctx,
		close:        cancel,
		done:         make(chan struct{}),
		window:       initialWindow,
		windowChange: make(chan struct{}),
	}
}

func streamContext(open streamOpen) (context.Context, context.CancelFunc) {
	parent, cancel := context.WithCancel(context.Background())
	if open.DeadlineMS <= 0 {
		return parent, cancel
	}
	deadline, deadlineCancel := context.WithTimeout(parent, time.Duration(open.DeadlineMS)*time.Millisecond)
	return deadline, func() {
		deadlineCancel()
		cancel()
	}
}

func New(config Config) (*Connector, error) {
	if strings.TrimSpace(config.URL) == "" || strings.TrimSpace(config.HostID) == "" || strings.TrimSpace(config.Secret) == "" {
		return nil, errors.New("relay URL, host ID, and Host Secret are required")
	}
	if config.Random == nil {
		config.Random = rand.Float64
	}
	return &Connector{config: config, streams: make(map[connectionID]*stream), usedIDs: make(map[connectionID]uint64)}, nil
}

func (connector *Connector) Start(parent context.Context) {
	if parent == nil {
		parent = context.Background()
	}
	connector.mu.Lock()
	if connector.run {
		connector.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(parent)
	connector.stop = cancel
	connector.loopDone = make(chan struct{})
	done := connector.loopDone
	connector.run = true
	connector.mu.Unlock()
	go connector.runLoop(ctx, done)
}

func (connector *Connector) Stop() {
	connector.mu.Lock()
	if connector.stop != nil {
		connector.stop()
	}
	conn := connector.conn
	connector.conn = nil
	done := connector.loopDone
	connector.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
	// A caller may stop and immediately rebuild the connector when settings
	// change. Wait for the old loop to leave its dial/read/backoff state so two
	// Host sockets can never overlap. The context cancellation and connection
	// close normally make this immediate; retain a bounded escape hatch for a
	// misbehaving custom Dial implementation.
	if done != nil {
		select {
		case <-done:
		case <-time.After(10 * time.Second):
		}
	}
}

func (connector *Connector) runLoop(ctx context.Context, done chan struct{}) {
	defer func() {
		connector.mu.Lock()
		connector.run = false
		if connector.loopDone == done {
			connector.loopDone = nil
			connector.stop = nil
		}
		connector.mu.Unlock()
		close(done)
	}()
	attempt := 0
	for {
		if ctx.Err() != nil {
			return
		}
		connector.state("connecting")
		err := connector.connectOnce(ctx)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			connector.recordError(err)
		} else {
			connector.recordError(nil)
		}
		connector.state("waiting")
		delay := BackoffDelay(attempt, connector.config.Random)
		attempt++
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		if err == nil {
			attempt = 0
		}
	}
}

func (connector *Connector) state(value string) {
	connector.mu.Lock()
	connector.lastState = value
	connector.mu.Unlock()
	if connector.config.OnState != nil {
		connector.config.OnState(value)
	}
}

// State returns a snapshot of the supervised connector. running reflects the
// dial loop; connected reflects an open WebSocket; currentState is the most
// recent label surfaced to OnState ("connecting", "waiting", "open"); lastError
// is the most recent connectOnce failure or empty when the last attempt
// succeeded.
func (connector *Connector) State() (running, connected bool, currentState, lastError string) {
	connector.mu.Lock()
	defer connector.mu.Unlock()
	return connector.run, connector.conn != nil, connector.lastState, connector.lastError
}

// recordError stores the most recent dial outcome. A nil error clears
// lastError so /healthz can distinguish a fresh failure from a stale one
// after a successful reconnect.
func (connector *Connector) recordError(err error) {
	connector.mu.Lock()
	defer connector.mu.Unlock()
	if err == nil {
		connector.lastError = ""
		return
	}
	connector.lastError = err.Error()
}

func BackoffDelay(attempt int, randomFn func() float64) time.Duration {
	if attempt < 0 {
		attempt = 0
	}
	if randomFn == nil {
		randomFn = rand.Float64
	}
	base := time.Second << min(attempt, 5)
	if base > 30*time.Second {
		base = 30 * time.Second
	}
	return time.Duration(float64(base) * (0.8 + randomFn()*0.4))
}

func min(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func (connector *Connector) connectOnce(ctx context.Context) error {
	endpoint, err := hostEndpoint(connector.config.URL, connector.config.HostID, connector.config.Name)
	if err != nil {
		return err
	}
	header := http.Header{"Authorization": []string{"Bearer " + connector.config.Secret}, "Sec-WebSocket-Protocol": []string{"brly/2"}}
	dial := connector.config.Dial
	if dial == nil {
		dial = func(ctx context.Context, endpoint string, header http.Header) (*websocket.Conn, *http.Response, error) {
			return websocket.DefaultDialer.DialContext(ctx, endpoint, header)
		}
	}
	connection, _, err := dial(ctx, endpoint, header)
	if err != nil {
		return err
	}
	if connection == nil {
		return errors.New("relay dial returned no connection")
	}
	connection.SetReadLimit(maxFrameBytes + headerSize)
	connector.mu.Lock()
	connector.connectionEpoch++
	epoch := connector.connectionEpoch
	connector.conn = connection
	// Connection IDs only need to be unique for the lifetime of one WebSocket.
	// Reset the guard on reconnect so a long-lived daemon does not retain every
	// random ID ever allocated or reject a valid ID reused by a new peer.
	connector.usedIDs = make(map[connectionID]uint64)
	connector.mu.Unlock()
	var writer *connectionWriter
	defer func() {
		connector.mu.Lock()
		current := connector.conn == connection && connector.connectionEpoch == epoch
		if current {
			connector.conn = nil
			if connector.writer == writer {
				connector.writer = nil
			}
		}
		connector.mu.Unlock()
		if writer != nil {
			writer.stopWith(errors.New("relay connection closed"))
		}
		_ = connection.Close()
		connector.closeStreams(epoch)
	}()
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	messageType, payload, err := connection.ReadMessage()
	if err != nil || messageType != websocket.TextMessage {
		return errors.New("relay challenge missing")
	}
	var received challenge
	if json.Unmarshal(payload, &received) != nil || received.Type != "relay_challenge" || received.Version != version {
		return errors.New("invalid relay challenge")
	}
	if !connector.verifyRelayKey(received.KeyID) {
		return errors.New("relay signing key is not pinned")
	}
	proof := challengeProof(connector.config.Secret, canonicalChallenge(received, connector.config.HostID))
	if err := connector.writeJSON(hello{Type: "host_hello", Version: version, HostID: connector.config.HostID, Capabilities: []string{"control", "http", "upgrade", "p2p-signal"}, Proof: proof}); err != nil {
		return err
	}
	messageType, payload, err = connection.ReadMessage()
	if err != nil || messageType != websocket.TextMessage {
		return errors.New("relay welcome missing")
	}
	var accepted welcome
	if json.Unmarshal(payload, &accepted) != nil || accepted.Type != "host_welcome" || accepted.Version != version {
		return errors.New("invalid relay welcome")
	}
	connector.mu.Lock()
	connector.generation = accepted.Generation
	connector.mu.Unlock()
	writer = newConnectionWriter(connection, epoch)
	connector.mu.Lock()
	if connector.conn != connection || connector.connectionEpoch != epoch {
		connector.mu.Unlock()
		return errors.New("relay connection epoch changed during handshake")
	}
	connector.writer = writer
	connector.mu.Unlock()
	go writer.run()
	_ = connection.SetReadDeadline(time.Time{})
	connector.state("open")
	for {
		messageType, payload, err := connection.ReadMessage()
		if err != nil {
			return err
		}
		if messageType != websocket.BinaryMessage {
			continue
		}
		decoded, err := decode(payload)
		if err != nil {
			return err
		}
		if err := connector.dispatch(decoded); err != nil {
			return err
		}
	}
}

func hostEndpoint(raw, hostID, name string) (string, error) {
	parsed, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil {
		return "", err
	}
	if parsed.Host == "" || parsed.Hostname() == "" || parsed.User != nil || parsed.Fragment != "" || parsed.Opaque != "" {
		return "", errors.New("relay URL must include a host")
	}
	if strings.ContainsAny(parsed.Host, "\r\n\x00") || strings.HasPrefix(parsed.Path, "//") || strings.ContainsAny(parsed.Path, "\r\n\x00") {
		return "", errors.New("relay URL contains an invalid authority or path")
	}
	for _, segment := range strings.Split(parsed.Path, "/") {
		if segment == "." || segment == ".." {
			return "", errors.New("relay URL path traversal is not allowed")
		}
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	case "ws", "wss":
	default:
		return "", errors.New("relay URL must use http(s) or ws(s)")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/v1/host/connect"
	query := parsed.Query()
	query.Set("host_id", hostID)
	query.Set("version", version)
	if name != "" {
		query.Set("name", name)
	}
	parsed.RawQuery = query.Encode()
	return parsed.String(), nil
}

func canonicalChallenge(value challenge, hostID string) string {
	return strings.Join([]string{value.Version, value.RelayID, value.Nonce, hostID, strings.Join(value.Capabilities, ",")}, "|")
}

func challengeProof(secret, canonical string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(canonical))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (connector *Connector) verifyRelayKey(keyID string) bool {
	// Pinning is mandatory for an enrolled Host. An empty key set is not an
	// implicit trust-all mode: it means enrollment has not completed yet.
	if len(connector.config.RelayPublicKeys) == 0 || strings.TrimSpace(keyID) == "" {
		return false
	}
	_, ok := connector.config.RelayPublicKeys[keyID]
	return ok && len(connector.config.RelayPublicKeys[keyID]) == ed25519.PublicKeySize
}

// Send writes a frame on the authenticated Host connection. It is primarily
// used by the Headless control adapter to send responses for a Relay stream;
// callers must use the ID supplied by the corresponding OPEN frame.
func (connector *Connector) Send(value Frame) error {
	if value.Kind == frameData || value.Kind == frameText || value.Kind == frameBinary {
		return connector.sendStream(value.ID, value)
	}
	return connector.send(value)
}

func (connector *Connector) writeJSON(value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	connector.writes.Lock()
	defer connector.writes.Unlock()
	connector.mu.Lock()
	conn := connector.conn
	connector.mu.Unlock()
	if conn == nil {
		return errors.New("relay connection closed")
	}
	_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return conn.WriteMessage(websocket.TextMessage, data)
}

func encode(value frame) []byte {
	result := make([]byte, headerSize+len(value.Payload))
	copy(result[:4], magic[:])
	result[4] = 2
	result[5] = value.Kind
	copy(result[6:22], value.ID[:])
	copy(result[22:], value.Payload)
	return result
}

func decode(data []byte) (frame, error) {
	if len(data) < headerSize || string(data[:4]) != string(magic[:]) || data[4] != 2 || data[5] < frameOpen || data[5] > frameError || len(data)-headerSize > maxFrameBytes {
		return frame{}, errors.New("invalid BRLY/2 frame")
	}
	var id connectionID
	copy(id[:], data[6:22])
	return frame{Kind: data[5], ID: id, Payload: append([]byte(nil), data[22:]...)}, nil
}

func (connector *Connector) dispatch(value frame) error {
	connector.mu.Lock()
	streamValue := connector.streams[value.ID]
	connector.mu.Unlock()
	if value.Kind == frameOpen {
		var metadata streamOpen
		if json.Unmarshal(value.Payload, &metadata) != nil || metadata.Class == "" {
			return errors.New("invalid stream metadata")
		}
		if metadata.Version != version {
			return errors.New("unsupported stream version")
		}
		if metadata.DeadlineMS < 0 || metadata.DeadlineMS > int64((10*time.Minute)/time.Millisecond) {
			return errors.New("invalid stream deadline")
		}
		if strings.TrimSpace(metadata.Token) == "" {
			return errors.New("stream capability is missing")
		}
		if metadata.HostID != "" && metadata.HostID != connector.config.HostID {
			return errors.New("stream host mismatch")
		}
		switch metadata.Class {
		case "control", "http", "upgrade", "signal", "p2p-signal":
		default:
			return errors.New("unsupported stream class")
		}
		connector.mu.Lock()
		epoch := connector.connectionEpoch
		_, used := connector.usedIDs[value.ID]
		if !used {
			connector.usedIDs[value.ID] = epoch
		}
		connector.mu.Unlock()
		if streamValue != nil || used {
			return errors.New("duplicate stream open")
		}
		if metadata.Token != "" {
			scope := "control"
			if metadata.Class == "http" || metadata.Class == "upgrade" {
				scope = "tunnel"
			} else if metadata.Class == "signal" || metadata.Class == "p2p-signal" {
				scope = "p2p-signal"
			}
			connector.mu.Lock()
			generation := connector.generation
			connector.mu.Unlock()
			claims, err := VerifyCapability(metadata.Token, connector.config.RelayPublicKeys, connector.config.HostID, scope, generation, time.Now())
			if err != nil {
				return err
			}
			if metadata.RouteID != "" {
				if routeID, _ := claims["route_id"].(string); routeID != metadata.RouteID {
					return errors.New("capability route mismatch")
				}
			} else if scope == "tunnel" {
				return errors.New("tunnel capability route is missing")
			}
			if metadata.ClientID != "" {
				if clientID, _ := claims["client_id"].(string); clientID != metadata.ClientID {
					return errors.New("capability client mismatch")
				}
			}
		}
		if metadata.Class == "control" || metadata.Class == "signal" || metadata.Class == "p2p-signal" {
			ctx, cancel := streamContext(metadata)
			streamValue := newStream(metadata, epoch, ctx, cancel)
			if connector.config.OnControl != nil {
				connector.mu.Lock()
				connector.streams[value.ID] = streamValue
				connector.mu.Unlock()
				if err := connector.config.OnControl(ctx, metadata, value); err != nil {
					connector.removeStream(value.ID)
					return err
				}
				streamValue.control = make(chan frame, 64)
				streamValue.controlDone = make(chan struct{})
				connector.startControlWorker(value.ID, streamValue)
				return nil
			}
			connector.mu.Lock()
			connector.streams[value.ID] = streamValue
			connector.mu.Unlock()
			return nil
		}
		return connector.openStream(value.ID, metadata)
	}
	if streamValue == nil {
		return nil
	}
	if isControlClass(streamValue.open.Class) && connector.config.OnControl != nil {
		switch value.Kind {
		case frameText, frameBinary, frameData, frameEnd, frameClose, frameError:
			if err := connector.enqueueControl(streamValue, value); err != nil {
				// A slow control client must not tear down unrelated streams on
				// the Host socket. Report the failure on this stream and let the
				// worker/context cleanup release its resources.
				if errors.Is(err, errControlQueueOverflow) {
					_ = connector.send(frame{Kind: frameError, ID: value.ID, Payload: mustJSON(map[string]string{"code": "backpressure", "message": "control stream queue overflow"})})
					connector.removeStream(value.ID)
					return nil
				}
				return err
			}
			return nil
		}
	}
	switch value.Kind {
	case frameHTTPHeads:
		if isControlClass(streamValue.open.Class) {
			return errors.New("control stream cannot carry HTTP headers")
		}
		return connector.handleHeaders(value.ID, streamValue, value.Payload)
	case frameData, frameText, frameBinary:
		streamValue.hijackedMu.Lock()
		hijacked := streamValue.hijacked
		streamValue.hijackedMu.Unlock()
		if hijacked != nil {
			if err := hijacked.feed(value.Payload); err != nil {
				return err
			}
			return connector.send(frame{Kind: frameWindow, ID: value.ID, Payload: encodeCredit(uint64(len(value.Payload)))})
		}
		if streamValue.body != nil {
			if err := writePipeWithContext(streamValue.ctx, streamValue.body, value.Payload); err != nil {
				return err
			}
			// DATA credit is returned only after the in-process handler accepted
			// the bytes. This couples Relay's queue to actual Host capacity.
			return connector.send(frame{Kind: frameWindow, ID: value.ID, Payload: encodeCredit(uint64(len(value.Payload)))})
		}
		return errors.New("HTTP DATA received before headers")
	case frameEnd:
		streamValue.hijackedMu.Lock()
		hijacked := streamValue.hijacked
		streamValue.hijackedMu.Unlock()
		if len(value.Payload) > 0 {
			var trailers httpHeaders
			if json.Unmarshal(value.Payload, &trailers) != nil || !validHeaderPairs(trailers.Trailers) {
				return errors.New("invalid HTTP trailers")
			}
			streamValue.requestMu.Lock()
			if streamValue.request != nil {
				for _, pair := range trailers.Trailers {
					streamValue.request.Trailer.Add(pair[0], pair[1])
				}
			}
			streamValue.requestMu.Unlock()
		}
		if hijacked != nil {
			hijacked.closeInput()
		}
		if streamValue.body != nil {
			_ = streamValue.body.Close()
		}
		if streamValue.body == nil && hijacked == nil {
			streamValue.close()
			connector.removeStream(value.ID)
			return errors.New("HTTP END received before headers")
		}
		return nil
	case frameClose, frameError:
		streamValue.hijackedMu.Lock()
		hijacked := streamValue.hijacked
		streamValue.hijackedMu.Unlock()
		if hijacked != nil {
			_ = hijacked.Close()
		}
		if streamValue.body != nil {
			_ = streamValue.body.CloseWithError(errors.New("relay stream closed"))
		}
		if streamValue.close != nil {
			streamValue.close()
		}
		connector.removeStream(value.ID)
	case frameWindow:
		if len(value.Payload) != 8 {
			return errors.New("invalid window update payload")
		}
		credit := binary.BigEndian.Uint64(value.Payload)
		streamValue.windowMu.Lock()
		if ^uint64(0)-streamValue.window < credit || streamValue.window+credit > initialWindow {
			streamValue.window = initialWindow
		} else {
			streamValue.window += credit
		}
		close(streamValue.windowChange)
		streamValue.windowChange = make(chan struct{})
		streamValue.windowMu.Unlock()
	}
	return nil
}

func isControlClass(class string) bool {
	return class == "control" || class == "signal" || class == "p2p-signal"
}

func (connector *Connector) enqueueControl(value *stream, message frame) error {
	if connector.config.OnControl == nil {
		return nil
	}
	if value.control == nil {
		return errors.New("control stream is not initialized")
	}
	select {
	case value.control <- message:
		return nil
	case <-value.ctx.Done():
		return errors.New("control stream closed")
	default:
		return errControlQueueOverflow
	}
}

func encodeCredit(credit uint64) []byte {
	value := make([]byte, 8)
	binary.BigEndian.PutUint64(value, credit)
	return value
}

func writePipeWithContext(ctx context.Context, writer *io.PipeWriter, data []byte) error {
	if len(data) == 0 {
		return nil
	}
	result := make(chan error, 1)
	go func() {
		_, err := writer.Write(data)
		result <- err
	}()
	select {
	case err := <-result:
		return err
	case <-ctx.Done():
		_ = writer.CloseWithError(ctx.Err())
		return ctx.Err()
	}
}

func (connector *Connector) openStream(id connectionID, metadata streamOpen) error {
	if connector.config.Handler == nil {
		return connector.send(frame{Kind: frameError, ID: id, Payload: mustJSON(map[string]string{"code": "handler_unavailable"})})
	}
	ctx, cancel := streamContext(metadata)
	connector.mu.Lock()
	epoch := connector.connectionEpoch
	streamValue := newStream(metadata, epoch, ctx, cancel)
	connector.streams[id] = streamValue
	connector.mu.Unlock()
	return nil
}

func (connector *Connector) startControlWorker(id connectionID, value *stream) {
	go func() {
		defer func() {
			connector.removeStream(id)
			if value.controlDone != nil {
				close(value.controlDone)
			}
		}()
		for {
			select {
			case <-value.ctx.Done():
				return
			case message, ok := <-value.control:
				if !ok {
					return
				}
				if connector.config.OnControl == nil {
					continue
				}
				if err := connector.config.OnControl(value.ctx, value.open, message); err != nil {
					_ = connector.send(frame{Kind: frameError, ID: id, Payload: mustJSON(map[string]string{"code": "control", "message": err.Error()})})
					connector.removeStream(id)
					return
				}
				if message.Kind == frameText || message.Kind == frameBinary || message.Kind == frameData {
					if err := connector.send(frame{Kind: frameWindow, ID: id, Payload: encodeCredit(uint64(len(message.Payload)))}); err != nil {
						connector.removeStream(id)
						return
					}
				}
				if message.Kind == frameEnd || message.Kind == frameClose || message.Kind == frameError {
					connector.removeStream(id)
					return
				}
			}
		}
	}()
}

func (connector *Connector) handleHeaders(id connectionID, value *stream, data []byte) error {
	var headers httpHeaders
	if json.Unmarshal(data, &headers) != nil {
		return errors.New("invalid HTTP headers")
	}
	if len(data) > 64*1024 || len(headers.Headers) > 4096 {
		return errors.New("HTTP header block exceeds limit")
	}
	if !validHeaderPairs(headers.Headers) {
		return errors.New("invalid HTTP headers")
	}
	if headers.Method == "" {
		headers.Method = http.MethodGet
	}
	if !validHTTPMethod(headers.Method) {
		return errors.New("invalid HTTP method")
	}
	if headers.Scheme != "" && !strings.EqualFold(headers.Scheme, "http") && !strings.EqualFold(headers.Scheme, "https") {
		return errors.New("invalid HTTP scheme")
	}
	if len(headers.Authority) > 8*1024 || strings.ContainsAny(headers.Authority, "\r\n\x00") {
		return errors.New("invalid HTTP authority")
	}
	if value.open.Class == "upgrade" && (!strings.EqualFold(headers.Method, http.MethodGet) || !strings.EqualFold(headerValue(headers.Headers, "upgrade"), "websocket")) {
		return errors.New("invalid upgrade request")
	}
	if value.open.Class == "upgrade" && !strings.EqualFold(headerValue(headers.Headers, "sec-websocket-version"), "13") {
		return errors.New("unsupported websocket version")
	}
	if value.open.Class == "upgrade" && !validWebSocketKey(headerValue(headers.Headers, "sec-websocket-key")) {
		return errors.New("invalid websocket key")
	}
	if headers.Path == "" || len(headers.Path) > 64*1024 || !strings.HasPrefix(headers.Path, "/") || strings.HasPrefix(headers.Path, "//") || strings.ContainsAny(headers.Path, "\r\n\x00") {
		return errors.New("invalid HTTP request path")
	}
	value.hijackedMu.Lock()
	if value.firstHeaders {
		value.hijackedMu.Unlock()
		return errors.New("duplicate HTTP headers")
	}
	value.firstHeaders = true
	value.hijackedMu.Unlock()
	value.start.Do(func() {
		reader, bodyWriter := io.Pipe()
		value.body = bodyWriter
		response := &responseWriter{connector: connector, id: id, stream: value, header: make(http.Header)}
		method := headers.Method
		scheme := headers.Scheme
		if scheme == "" {
			scheme = "http"
		}
		target := scheme + "://relay.invalid" + headers.Path
		request, err := http.NewRequestWithContext(value.ctx, method, target, reader)
		if err != nil {
			value.close()
			return
		}
		request.URL.Host = headers.Authority
		value.requestMu.Lock()
		value.request = request
		value.requestMu.Unlock()
		request.Host = headers.Authority
		bodyLimit := headers.BodyLimit
		if bodyLimit <= 0 || bodyLimit > maxHTTPBodyBytes {
			bodyLimit = maxHTTPBodyBytes
		}
		request.Body = http.MaxBytesReader(response, request.Body, bodyLimit)
		for _, pair := range headers.Headers {
			request.Header.Add(pair[0], pair[1])
		}
		go func() {
			defer close(value.done)
			defer reader.Close()
			connector.config.Handler.ServeHTTP(response, request)
			response.stateMu.Lock()
			hijacked := response.hijacked != nil
			wrote := response.wrote
			response.stateMu.Unlock()
			if !hijacked {
				// net/http commits an implicit 200 response when a handler
				// returns without writing a body. Emit the same response boundary
				// over BRLY/2 so an empty response is not mistaken for a protocol
				// failure by Relay.
				if !wrote {
					response.WriteHeader(http.StatusOK)
				}
				trailers := trailerPairs(response.header)
				_ = connector.send(frame{Kind: frameEnd, ID: id, Payload: mustJSON(map[string]any{"trailers": trailers})})
			}
			connector.removeStream(id)
		}()
	})
	return nil
}

func (connector *Connector) send(value frame) error {
	data := encode(value)
	if len(data) > headerSize+maxFrameBytes {
		return errors.New("frame exceeds limit")
	}
	connector.mu.Lock()
	epoch := connector.connectionEpoch
	usedEpoch, used := connector.usedIDs[value.ID]
	writer := connector.writer
	connector.mu.Unlock()
	if writer == nil {
		return errors.New("relay connection closed")
	}
	if !used || usedEpoch != epoch || writer.epoch != epoch {
		return errors.New("relay connection epoch is stale")
	}
	valueDone := make(chan error, 1)
	control := value.Kind != frameData
	if err := writer.enqueue(queuedWrite{
		messageType: websocket.BinaryMessage,
		data:        data,
		done:        valueDone,
	}, control); err != nil {
		return err
	}
	select {
	case err := <-valueDone:
		return err
	case <-writer.stopped:
		// Prefer a completed result if the writer stopped immediately after
		// handing this frame to Gorilla. The channel is buffered, so this
		// non-blocking check avoids reporting a successful write as failed.
		select {
		case err := <-valueDone:
			return err
		default:
			return writer.error()
		}
	}
}

func (connector *Connector) closeStreams(epoch uint64) {
	connector.mu.Lock()
	streams := make(map[connectionID]*stream)
	for id, value := range connector.streams {
		if value != nil && value.epoch == epoch {
			streams[id] = value
			delete(connector.streams, id)
		}
	}
	connector.mu.Unlock()
	for id, value := range streams {
		if isControlClass(value.open.Class) && connector.config.OnControl != nil {
			terminal := frame{Kind: frameClose, ID: id}
			if value.control != nil {
				timer := time.NewTimer(time.Second)
				select {
				case value.control <- terminal:
				case <-timer.C:
				}
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				if value.controlDone != nil {
					select {
					case <-value.controlDone:
					case <-time.After(time.Second):
					}
				}
			} else {
				_ = connector.config.OnControl(value.ctx, value.open, terminal)
			}
		}
		if value.close != nil {
			value.close()
		}
		value.hijackedMu.Lock()
		hijacked := value.hijacked
		value.hijackedMu.Unlock()
		if hijacked != nil {
			_ = hijacked.Close()
		}
		if value.body != nil {
			_ = value.body.Close()
		}
	}
}

func (connector *Connector) removeStream(id connectionID) {
	connector.mu.Lock()
	value := connector.streams[id]
	delete(connector.streams, id)
	connector.mu.Unlock()
	if value != nil && value.close != nil {
		value.close()
	}
}

type responseWriter struct {
	connector *Connector
	id        connectionID
	stream    *stream
	header    http.Header
	stateMu   sync.Mutex
	status    int
	wrote     bool
	sendErr   error
	hijacked  *relayConn
}

func (writer *responseWriter) Header() http.Header { return writer.header }
func (writer *responseWriter) WriteHeader(status int) {
	writer.stateMu.Lock()
	defer writer.stateMu.Unlock()
	if writer.wrote {
		return
	}
	if status < 100 || status > 999 {
		status = http.StatusInternalServerError
	}
	writer.status = status
	writer.wrote = true
	writer.sendErr = writer.connector.send(frame{Kind: frameHTTPHeads, ID: writer.id, Payload: mustJSON(map[string]any{"status": status, "headers": headerPairs(writer.header)})})
}
func (writer *responseWriter) Write(data []byte) (int, error) {
	writer.stateMu.Lock()
	sendErr := writer.sendErr
	wrote := writer.wrote
	writer.stateMu.Unlock()
	if sendErr != nil {
		return 0, sendErr
	}
	if !wrote {
		writer.WriteHeader(http.StatusOK)
	}
	writer.stateMu.Lock()
	sendErr = writer.sendErr
	writer.stateMu.Unlock()
	if sendErr != nil {
		return 0, sendErr
	}
	if len(data) == 0 {
		return 0, nil
	}
	total := len(data)
	for len(data) > 0 {
		chunk := data
		if len(chunk) > maxFrameBytes {
			chunk = chunk[:maxFrameBytes]
		}
		if err := writer.connector.sendData(writer.id, chunk); err != nil {
			return 0, err
		}
		data = data[len(chunk):]
	}
	return total, nil
}

func (writer *responseWriter) Flush() {
	writer.stateMu.Lock()
	wrote := writer.wrote
	writer.stateMu.Unlock()
	if !wrote {
		writer.WriteHeader(http.StatusOK)
	}
}

// Hijack provides the standard net/http escape hatch used by WebSocket
// handlers. The returned connection maps the HTTP 101 bytes and subsequent
// opaque bytes onto BRLY/2 frames; Relay never parses the upgraded stream.
func (writer *responseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if writer.stream == nil || writer.stream.open.Class != "upgrade" {
		return nil, nil, errors.New("connection hijacking is only available for upgrade streams")
	}
	writer.stream.hijackedMu.Lock()
	defer writer.stream.hijackedMu.Unlock()
	if writer.stream.hijacked != nil {
		return nil, nil, errors.New("connection already hijacked")
	}
	reader, input := io.Pipe()
	connection := &relayConn{connector: writer.connector, id: writer.id, stream: writer.stream, reader: reader, input: input, done: make(chan struct{})}
	writer.stream.hijacked = connection
	writer.stateMu.Lock()
	writer.hijacked = connection
	writer.stateMu.Unlock()
	return connection, bufio.NewReadWriter(bufio.NewReader(connection), bufio.NewWriter(connection)), nil
}

func (writer *responseWriter) Unwrap() http.ResponseWriter { return nil }

type httpHeaders struct {
	Status    int         `json:"status,omitempty"`
	Method    string      `json:"method,omitempty"`
	Scheme    string      `json:"scheme,omitempty"`
	Authority string      `json:"authority,omitempty"`
	Path      string      `json:"path,omitempty"`
	BodyLimit int64       `json:"body_limit,omitempty"`
	Headers   [][2]string `json:"headers,omitempty"`
	Trailers  [][2]string `json:"trailers,omitempty"`
}

func headerValue(values [][2]string, name string) string {
	for _, value := range values {
		if strings.EqualFold(value[0], name) {
			return value[1]
		}
	}
	return ""
}

func headerTokenContains(values []string, wanted string) bool {
	for _, value := range values {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), wanted) {
				return true
			}
		}
	}
	return false
}

func trailerPairs(header http.Header) [][2]string {
	var result [][2]string
	seen := make(map[string]struct{})
	for _, declaration := range header.Values("Trailer") {
		for _, name := range strings.Split(declaration, ",") {
			name = http.CanonicalHeaderKey(strings.TrimSpace(name))
			if name == "" || name == "Trailer" {
				continue
			}
			if _, ok := seen[name]; ok {
				continue
			}
			seen[name] = struct{}{}
			for _, value := range header.Values(name) {
				result = append(result, [2]string{name, value})
			}
		}
	}
	return result
}

func validHeaderPairs(headers [][2]string) bool {
	total := 0
	for _, pair := range headers {
		name := strings.TrimSpace(pair[0])
		value := pair[1]
		if !validHeaderName(name) || len(name) > 8*1024 || len(value) > 8*1024 || strings.ContainsAny(value, "\r\n\x00") {
			return false
		}
		total += len(name) + len(value)
		if total > 64*1024 {
			return false
		}
	}
	return true
}

func validHeaderName(name string) bool {
	if name == "" {
		return false
	}
	for _, character := range name {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			strings.ContainsRune("!#$%&'*+-.^_`|~", character) {
			continue
		}
		return false
	}
	return true
}

func validHTTPMethod(method string) bool {
	method = strings.TrimSpace(method)
	if method == "" {
		return false
	}
	for _, character := range method {
		if (character >= 'A' && character <= 'Z') ||
			(character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') ||
			strings.ContainsRune("!#$%&'*+-.^_`|~", character) {
			continue
		}
		return false
	}
	return true
}

func validWebSocketKey(value string) bool {
	value = strings.TrimSpace(value)
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(value)
	}
	return err == nil && len(decoded) == 16
}

type relayConn struct {
	connector *Connector
	id        connectionID
	stream    *stream
	reader    *io.PipeReader
	input     *io.PipeWriter
	done      chan struct{}
	closeOnce sync.Once
	inputOnce sync.Once
	writeMu   sync.Mutex
	handshake bytes.Buffer
	upgraded  bool
}

func (connection *relayConn) Read(data []byte) (int, error) {
	select {
	case <-connection.done:
		return 0, io.EOF
	default:
	}
	return connection.reader.Read(data)
}

func (connection *relayConn) Write(data []byte) (int, error) {
	connection.writeMu.Lock()
	defer connection.writeMu.Unlock()
	if !connection.upgraded {
		_, _ = connection.handshake.Write(data)
		marker := bytes.Index(connection.handshake.Bytes(), []byte("\r\n\r\n"))
		if marker < 0 {
			if connection.handshake.Len() > maxUpgradeHandshakeBytes {
				return 0, errors.New("upgrade response headers exceed limit")
			}
			return len(data), nil
		}
		if marker+4 > maxUpgradeHandshakeBytes {
			return 0, errors.New("upgrade response headers exceed limit")
		}
		raw := connection.handshake.Bytes()
		headers, _, err := parseUpgradeResponse(raw[:marker+4])
		remainder := append([]byte(nil), raw[marker+4:]...)
		if err != nil {
			return 0, err
		}
		if err := connection.connector.send(frame{Kind: frameHTTPHeads, ID: connection.id, Payload: mustJSON(headers)}); err != nil {
			return 0, err
		}
		connection.upgraded = true
		connection.handshake.Reset()
		if len(remainder) > 0 {
			if err := connection.connector.sendData(connection.id, remainder); err != nil {
				return 0, err
			}
		}
		return len(data), nil
	}
	if err := connection.connector.sendData(connection.id, data); err != nil {
		return 0, err
	}
	return len(data), nil
}

func (connection *relayConn) Close() error {
	connection.closeOnce.Do(func() {
		close(connection.done)
		connection.inputOnce.Do(func() { _ = connection.input.Close() })
		_ = connection.reader.Close()
		// net.Conn.Close is a full close. A handler that only needs to half-close
		// its input receives END from Relay and can return after EOF; emitting
		// CLOSE here ensures an explicitly closed upgraded handler also tears
		// down the public socket.
		_ = connection.connector.send(frame{Kind: frameClose, ID: connection.id})
	})
	return nil
}

func (connection *relayConn) closeInput() {
	connection.inputOnce.Do(func() { _ = connection.input.Close() })
}

func (connection *relayConn) feed(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	return writePipeWithContext(connection.stream.ctx, connection.input, data)
}

func (connection *relayConn) LocalAddr() net.Addr              { return relayAddr("relay-host") }
func (connection *relayConn) RemoteAddr() net.Addr             { return relayAddr("relay-client") }
func (connection *relayConn) SetDeadline(time.Time) error      { return nil }
func (connection *relayConn) SetReadDeadline(time.Time) error  { return nil }
func (connection *relayConn) SetWriteDeadline(time.Time) error { return nil }

type relayAddr string

func (address relayAddr) Network() string { return "relay" }
func (address relayAddr) String() string  { return string(address) }

func parseUpgradeResponse(data []byte) (httpHeaders, []byte, error) {
	if len(data) == 0 || len(data) > maxUpgradeHandshakeBytes {
		return httpHeaders{}, nil, errors.New("upgrade response headers exceed limit")
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\r\n\r\n"), "\r\n")
	if len(lines) == 0 {
		return httpHeaders{}, nil, errors.New("empty upgrade response")
	}
	statusLine := strings.SplitN(lines[0], " ", 3)
	if len(statusLine) < 2 || statusLine[0] != "HTTP/1.1" {
		return httpHeaders{}, nil, errors.New("invalid upgrade response")
	}
	status, err := strconv.Atoi(statusLine[1])
	if err != nil || status != http.StatusSwitchingProtocols {
		return httpHeaders{}, nil, errors.New("upgrade response was not 101")
	}
	result := httpHeaders{Status: status, Headers: make([][2]string, 0, len(lines)-1)}
	for _, line := range lines[1:] {
		separator := strings.IndexByte(line, ':')
		if separator <= 0 {
			return httpHeaders{}, nil, errors.New("invalid upgrade response header")
		}
		name := strings.TrimSpace(line[:separator])
		value := strings.TrimSpace(line[separator+1:])
		if !validHeaderName(name) || len(name) > 8*1024 || len(value) > 8*1024 || strings.ContainsAny(value, "\r\n\x00") {
			return httpHeaders{}, nil, errors.New("upgrade response header too large")
		}
		result.Headers = append(result.Headers, [2]string{name, value})
	}
	if !validHeaderPairs(result.Headers) {
		return httpHeaders{}, nil, errors.New("upgrade response headers exceed limit")
	}
	if !strings.EqualFold(headerValue(result.Headers, "Upgrade"), "websocket") ||
		!headerTokenContains([]string{headerValue(result.Headers, "Connection")}, "upgrade") {
		return httpHeaders{}, nil, errors.New("upgrade response did not include websocket headers")
	}
	return result, nil, nil
}

func (connector *Connector) sendData(id connectionID, data []byte) error {
	connector.mu.Lock()
	streamValue := connector.streams[id]
	epoch := connector.connectionEpoch
	connector.mu.Unlock()
	if streamValue == nil || streamValue.epoch != epoch {
		return errors.New("stream closed")
	}
	return connector.sendStream(id, frame{Kind: frameData, ID: id, Payload: append([]byte(nil), data...)})
}

func (connector *Connector) sendStream(id connectionID, value frame) error {
	connector.mu.Lock()
	streamValue := connector.streams[id]
	epoch := connector.connectionEpoch
	connector.mu.Unlock()
	if streamValue == nil || streamValue.epoch != epoch {
		return errors.New("stream closed")
	}
	// Control streams use their own bounded queues and priority writer lane.
	// Charging their JSON/binary messages to the HTTP body window lets a paused
	// browser block RPC responses and input for the full flow-control timeout.
	// Body and upgrade streams remain credit-controlled below.
	if !streamFrameNeedsCredit(streamValue, value.Kind) {
		return connector.send(value)
	}
	credit := uint64(len(value.Payload))
	if credit > initialWindow {
		streamValue.close()
		return errors.New("stream frame exceeds flow-control window")
	}
	timer := time.NewTimer(60 * time.Second)
	defer timer.Stop()
	for {
		streamValue.windowMu.Lock()
		if credit <= streamValue.window {
			streamValue.window -= credit
			streamValue.windowMu.Unlock()
			return connector.send(value)
		}
		changed := streamValue.windowChange
		streamValue.windowMu.Unlock()
		select {
		case <-streamValue.ctx.Done():
			return errors.New("stream context canceled")
		case <-changed:
		case <-timer.C:
			streamValue.close()
			return errors.New("stream flow-control timeout")
		}
	}
}

func streamFrameNeedsCredit(value *stream, kind byte) bool {
	return !(value != nil && isControlClass(value.open.Class) && kind != frameData)
}

func headerPairs(header http.Header) [][2]string {
	result := make([][2]string, 0, len(header))
	for key, values := range header {
		for _, value := range values {
			result = append(result, [2]string{key, value})
		}
	}
	return result
}
func mustJSON(value any) []byte { data, _ := json.Marshal(value); return data }

func VerifyCapability(token string, keys map[string]ed25519.PublicKey, hostID, scope string, generation uint64, now time.Time) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return nil, errors.New("invalid capability")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("invalid capability payload")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("invalid capability signature")
	}
	var claims map[string]any
	if json.Unmarshal(payload, &claims) != nil {
		return nil, errors.New("invalid capability claims")
	}
	if value, _ := claims["iss"].(string); value != "warren-relay" {
		return nil, errors.New("invalid capability issuer")
	}
	keyID, _ := claims["kid"].(string)
	if strings.TrimSpace(keyID) == "" || len(keys) == 0 {
		return nil, errors.New("capability signing key is not pinned")
	}
	public := keys[keyID]
	if len(public) != ed25519.PublicKeySize || !ed25519.Verify(public, []byte(parts[0]), signature) {
		return nil, errors.New("invalid capability signature")
	}
	if value, _ := claims["aud"].(string); value != "warren-relay-stream" {
		return nil, errors.New("invalid capability audience")
	}
	if value, _ := claims["host_id"].(string); value != hostID {
		return nil, errors.New("invalid capability host")
	}
	if value, ok := claims["generation"].(float64); !ok || uint64(value) != generation {
		return nil, errors.New("stale capability")
	}
	scopes, ok := claims["scope"].([]any)
	if !ok {
		return nil, errors.New("invalid capability scope")
	}
	found := false
	for _, value := range scopes {
		if scopeValue, ok := value.(string); ok && scopeValue == scope {
			found = true
		}
	}
	if !found {
		return nil, errors.New("capability scope denied")
	}
	if jti, _ := claims["jti"].(string); strings.TrimSpace(jti) == "" {
		return nil, errors.New("capability jti is missing")
	}
	value, ok := claims["exp"].(float64)
	if !ok || now.Unix() >= int64(value) {
		return nil, errors.New("capability expired")
	}
	return claims, nil
}
