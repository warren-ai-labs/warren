package controlplane

import (
	"errors"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type hostTunnel struct {
	connection *websocket.Conn
	v2         bool
	writes     sync.Mutex
	clientsMu  sync.RWMutex
	clients    map[connectionID]*clientRoute
	closed     chan struct{}
	closeOnce  sync.Once
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

func newHostTunnel(connection *websocket.Conn, v2 ...bool) *hostTunnel {
	if connection != nil {
		connection.SetReadLimit(maxRelayMessageBytes + headerSize)
	}
	protocolV2 := len(v2) > 0 && v2[0]
	return &hostTunnel{
		connection: connection,
		v2:         protocolV2,
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
	if tunnel.connection == nil {
		return errors.New("host tunnel connection unavailable")
	}
	select {
	case <-tunnel.closed:
		return errors.New("host tunnel closed")
	default:
	}
	tunnel.writes.Lock()
	defer tunnel.writes.Unlock()
	_ = tunnel.connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
	encoded := encodeRelayFrame(frame)
	if encoded == nil {
		return errors.New("relay frame exceeds limit")
	}
	return tunnel.connection.WriteMessage(websocket.BinaryMessage, encoded)
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
			tunnel.writes.Lock()
			var err error
			if tunnel.connection != nil {
				err = tunnel.connection.WriteControl(
					websocket.PingMessage,
					nil,
					time.Now().Add(10*time.Second),
				)
			} else {
				err = errors.New("host tunnel connection unavailable")
			}
			tunnel.writes.Unlock()
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
