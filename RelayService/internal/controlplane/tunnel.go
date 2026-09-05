package controlplane

import (
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	tunnelControlQueueCapacity = 256
	tunnelDataQueueCapacity    = 32
	tunnelControlFairness      = 32
)

type hostTunnel struct {
	connection *websocket.Conn
	writer     *tunnelWriter
	clientsMu  sync.RWMutex
	clients    map[connectionID]*clientRoute
	closed     chan struct{}
	closeOnce  sync.Once
}

type tunnelQueuedWrite struct {
	data []byte
	done chan error
}

// tunnelWriter is the sole owner of hostTunnel's WebSocket data writes. Relay
// routes can enqueue independently; control frames have a reserved lane so a
// saturated public body cannot block OPEN/CLOSE/WINDOW progress.
type tunnelWriter struct {
	connection *websocket.Conn
	control    chan tunnelQueuedWrite
	data       chan tunnelQueuedWrite
	stop       chan struct{}
	stopped    chan struct{}
	stopOnce   sync.Once
	errMu      sync.Mutex
	err        error
}

func newTunnelWriter(connection *websocket.Conn) *tunnelWriter {
	writer := &tunnelWriter{
		connection: connection,
		control:    make(chan tunnelQueuedWrite, tunnelControlQueueCapacity),
		data:       make(chan tunnelQueuedWrite, tunnelDataQueueCapacity),
		stop:       make(chan struct{}),
		stopped:    make(chan struct{}),
	}
	go writer.run()
	return writer
}

func (writer *tunnelWriter) stopWith(err error) {
	if err == nil {
		err = errors.New("host tunnel closed")
	}
	writer.stopOnce.Do(func() {
		writer.errMu.Lock()
		writer.err = err
		writer.errMu.Unlock()
		close(writer.stop)
	})
}

func (writer *tunnelWriter) error() error {
	writer.errMu.Lock()
	defer writer.errMu.Unlock()
	if writer.err == nil {
		return errors.New("host tunnel closed")
	}
	return writer.err
}

func (writer *tunnelWriter) enqueue(value tunnelQueuedWrite, control bool) error {
	queue := writer.data
	if control {
		queue = writer.control
	}
	select {
	case <-writer.stop:
		return writer.error()
	case <-writer.stopped:
		return writer.error()
	default:
	}
	select {
	case queue <- value:
		return nil
	default:
		if control {
			return errors.New("host tunnel control writer queue full")
		}
		return errors.New("host tunnel data writer queue full")
	}
}

func (writer *tunnelWriter) run() {
	defer close(writer.stopped)
	controlBudget := 0
	for {
		var value tunnelQueuedWrite
		select {
		case <-writer.stop:
			return
		default:
		}
		if controlBudget < tunnelControlFairness {
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
		err := writer.connection.WriteMessage(websocket.BinaryMessage, value.data)
		value.done <- err
		if err != nil {
			writer.stopWith(err)
			return
		}
	}
}

type clientRoute struct {
	frames       chan relayFrame
	done         chan struct{}
	once         sync.Once
	windowMu     sync.Mutex
	window       uint64
	windowChange chan struct{}
	public       bool
}

func newClientRoute() *clientRoute {
	return &clientRoute{
		frames:       make(chan relayFrame, 64),
		done:         make(chan struct{}),
		window:       initialStreamWindow,
		windowChange: make(chan struct{}),
	}
}

func (route *clientRoute) close() { route.once.Do(func() { close(route.done) }) }

func newHostTunnel(connection *websocket.Conn) *hostTunnel {
	if connection != nil {
		connection.SetReadLimit(maxRelayMessageBytes + headerSize)
	}
	var writer *tunnelWriter
	if connection != nil {
		writer = newTunnelWriter(connection)
	}
	return &hostTunnel{
		connection: connection,
		writer:     writer,
		clients:    make(map[connectionID]*clientRoute),
		closed:     make(chan struct{}),
	}
}

func (tunnel *hostTunnel) openClient() (connectionID, *clientRoute, error) {
	return tunnel.openStream(nil)
}

func (tunnel *hostTunnel) openStream(metadata *streamOpen) (connectionID, *clientRoute, error) {
	id, err := newConnectionID()
	if err != nil {
		return connectionID{}, nil, err
	}
	route := newClientRoute()
	if metadata != nil {
		route.public = metadata.Class == "http" || metadata.Class == "upgrade"
	}
	tunnel.clientsMu.Lock()
	select {
	case <-tunnel.closed:
		tunnel.clientsMu.Unlock()
		return connectionID{}, nil, errors.New("host tunnel closed")
	default:
		if len(tunnel.clients) >= maxHostStreams {
			tunnel.clientsMu.Unlock()
			return connectionID{}, nil, errors.New("host stream limit reached")
		}
		if route.public {
			publicStreams := 0
			for _, existing := range tunnel.clients {
				if existing.public {
					publicStreams++
				}
			}
			if publicStreams >= maxPublicStreams {
				tunnel.clientsMu.Unlock()
				return connectionID{}, nil, errors.New("public stream limit reached")
			}
		}
		tunnel.clients[id] = route
	}
	tunnel.clientsMu.Unlock()
	var payload []byte
	if metadata != nil {
		payload, err = metadata.encode()
		if err != nil {
			tunnel.removeClient(id)
			return connectionID{}, nil, err
		}
	}
	if err := tunnel.send(relayFrame{Kind: frameOpen, ConnectionID: id, Payload: payload}); err != nil {
		tunnel.removeClient(id)
		return connectionID{}, nil, err
	}
	return id, route, nil
}

func (tunnel *hostTunnel) send(frame relayFrame) error {
	if tunnel.connection == nil || tunnel.writer == nil {
		return errors.New("host tunnel connection unavailable")
	}
	select {
	case <-tunnel.closed:
		return errors.New("host tunnel closed")
	default:
	}
	encoded := encodeRelayFrame(frame)
	if encoded == nil {
		return errors.New("relay frame exceeds limit")
	}
	control := frame.Kind != frameData && frame.Kind != frameText && frame.Kind != frameBinary
	done := make(chan error, 1)
	if err := tunnel.writer.enqueue(tunnelQueuedWrite{data: encoded, done: done}, control); err != nil {
		return err
	}
	select {
	case err := <-done:
		if err != nil {
			tunnel.close()
		}
		return err
	case <-tunnel.writer.stopped:
		select {
		case err := <-done:
			if err != nil {
				tunnel.close()
			}
			return err
		default:
			err := tunnel.writer.error()
			tunnel.close()
			return err
		}
	}
}

// sendStream applies the per-stream credit window before writing body or
// terminal control frames. OPEN/CLOSE/END/WINDOW_UPDATE metadata is not
// charged to the body window. A sender waits for bounded receiver credit
// rather than accumulating an unbounded pending queue.
func (tunnel *hostTunnel) sendStream(id connectionID, frame relayFrame) error {
	return tunnel.sendStreamContext(nil, id, frame)
}

func (tunnel *hostTunnel) sendStreamContext(ctxDone <-chan struct{}, id connectionID, frame relayFrame) error {
	tunnel.clientsMu.RLock()
	route := tunnel.clients[id]
	tunnel.clientsMu.RUnlock()
	if route == nil {
		return errors.New("stream not found")
	}
	if frame.Kind == frameData || frame.Kind == frameText || frame.Kind == frameBinary {
		credit := uint64(len(frame.Payload))
		if credit > initialStreamWindow {
			route.close()
			return errors.New("stream frame exceeds flow-control window")
		}
		timer := time.NewTimer(60 * time.Second)
		defer timer.Stop()
		for {
			consumed, changed := route.tryConsume(credit)
			if consumed {
				break
			}
			select {
			case <-route.done:
				return errors.New("stream closed")
			case <-tunnel.closed:
				return errors.New("host tunnel closed")
			case <-ctxDone:
				return errors.New("stream context canceled")
			case <-changed:
			case <-timer.C:
				route.close()
				return errors.New("stream flow-control timeout")
			}
		}
	}
	return tunnel.send(frame)
}

func (route *clientRoute) tryConsume(bytes uint64) (bool, <-chan struct{}) {
	route.windowMu.Lock()
	defer route.windowMu.Unlock()
	if route.windowChange == nil {
		route.windowChange = make(chan struct{})
	}
	if bytes > route.window {
		return false, route.windowChange
	}
	route.window -= bytes
	return true, nil
}

func (route *clientRoute) grant(bytes uint64) {
	route.windowMu.Lock()
	defer route.windowMu.Unlock()
	if route.windowChange == nil {
		route.windowChange = make(chan struct{})
	}
	if ^uint64(0)-route.window < bytes || route.window+bytes > initialStreamWindow {
		route.window = initialStreamWindow
	} else {
		route.window += bytes
	}
	close(route.windowChange)
	route.windowChange = make(chan struct{})
}

func (tunnel *hostTunnel) readLoop(touch func()) error {
	if tunnel.connection == nil {
		return errors.New("host tunnel connection unavailable")
	}
	defer tunnel.close()
	_ = tunnel.connection.SetReadDeadline(time.Now().Add(75 * time.Second))
	tunnel.connection.SetPongHandler(func(string) error {
		touch()
		return tunnel.connection.SetReadDeadline(time.Now().Add(75 * time.Second))
	})
	go tunnel.heartbeat()
	for {
		messageType, data, err := tunnel.connection.ReadMessage()
		if err != nil {
			return err
		}
		if messageType != websocket.BinaryMessage || len(data) > maxRelayMessageBytes+headerSize {
			return errors.New("invalid host relay message")
		}
		frame, err := decodeRelayFrame(data)
		if err != nil {
			return err
		}
		touch()
		tunnel.clientsMu.RLock()
		route := tunnel.clients[frame.ConnectionID]
		tunnel.clientsMu.RUnlock()
		if route == nil {
			continue
		}
		if frame.Kind == frameWindowUpdate {
			credit, err := decodeWindowCredit(frame.Payload)
			if err != nil {
				tunnel.removeClient(frame.ConnectionID)
				_ = tunnel.send(relayFrame{Kind: frameError, ConnectionID: frame.ConnectionID, Payload: []byte(`{"code":"invalid_window_update"}`)})
				continue
			}
			route.grant(credit)
			continue
		}
		select {
		case route.frames <- frame:
		case <-route.done:
		default:
			tunnel.removeClient(frame.ConnectionID)
			_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: frame.ConnectionID})
		}
	}
}

func (tunnel *hostTunnel) heartbeat() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-tunnel.closed:
			return
		case <-ticker.C:
			var err error
			if tunnel.connection != nil {
				err = tunnel.connection.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second))
			} else {
				err = errors.New("host tunnel connection unavailable")
			}
			if err != nil {
				tunnel.close()
				return
			}
		}
	}
}

func (tunnel *hostTunnel) removeClient(id connectionID) {
	tunnel.clientsMu.Lock()
	route := tunnel.clients[id]
	delete(tunnel.clients, id)
	tunnel.clientsMu.Unlock()
	if route != nil {
		route.close()
	}
}

func (tunnel *hostTunnel) close() {
	tunnel.closeOnce.Do(func() {
		close(tunnel.closed)
		if tunnel.writer != nil {
			tunnel.writer.stopWith(errors.New("host tunnel closed"))
		}
		if tunnel.connection != nil {
			_ = tunnel.connection.Close()
		}
		tunnel.clientsMu.Lock()
		clients := tunnel.clients
		tunnel.clients = make(map[connectionID]*clientRoute)
		tunnel.clientsMu.Unlock()
		for _, route := range clients {
			route.close()
		}
	})
}
