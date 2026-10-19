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
	// routeHandoffFrames is the frame buffer between a route's byte-bounded
	// queue and the goroutine that consumes it. It only smooths scheduling; what
	// bounds a route's buffering is the queue behind it.
	routeHandoffFrames = 16
	// routeBufferBytes bounds how many bytes one route may accumulate for a
	// consumer that has not caught up. It is the whole window the Host may have
	// unacknowledged, so a peer that respects flow control can never be refused:
	// a refusal is a peer that exceeded its window.
	//
	// The bound is in bytes because flow control is in bytes. Counting frames
	// cannot express it: the Host sends whatever size its handler writes, and a
	// gzip writer emits a few hundred bytes at a time, so an 82 KB asset arrives
	// as hundreds of frames and filled a 64-frame queue long before the window
	// was anywhere near full. Filling the queue tore the route down mid-body and
	// truncated the response.
	routeBufferBytes = initialStreamWindow
	// relayReadDeadline bounds silence on a tunnel, not activity. Every inbound
	// frame refreshes it alongside the pong handler: a tunnel carrying a build's
	// output is demonstrably alive, and tying liveness to pongs alone dropped
	// busy tunnels whenever one control frame was lost or delayed.
	relayReadDeadline = 75 * time.Second
	// Terminal traffic is mostly tiny frames: a keystroke echo is a few bytes,
	// and permessage-deflate without context takeover has a per-message floor of
	// its own, so compressing those spends CPU to make them larger. Output
	// bursts, HTTP bodies, and terminal snapshots are where the ratio is worth
	// having, so compression is applied by size rather than globally.
	compressionThreshold = 1024
)

type hostTunnel struct {
	connection *websocket.Conn
	writer     *tunnelWriter
	clientsMu  sync.RWMutex
	clients    map[connectionID]*clientRoute
	closed     chan struct{}
	closeOnce  sync.Once
	// readDeadline is the silence budget for this tunnel. Zero selects
	// relayReadDeadline.
	readDeadline time.Duration
	// hostGone hands over the client routes that were attached when this tunnel
	// died, so the owner can decide whether the Host is actually gone before
	// anything is told to anyone. It takes over closing them. Nil means close
	// them immediately, which is right when there is no presence to consult.
	hostGone func(dying *hostTunnel, routes []*clientRoute)
}

func (tunnel *hostTunnel) silenceBudget() time.Duration {
	if tunnel.readDeadline > 0 {
		return tunnel.readDeadline
	}
	return relayReadDeadline
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
		// Safe from this goroutine: it owns every data write, and the heartbeat's
		// WriteControl never consults the compression flag.
		writer.connection.EnableWriteCompression(len(value.data) >= compressionThreshold)
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
	noticeMu     sync.Mutex
	notice       []byte
	windowMu     sync.Mutex
	window       uint64
	windowChange chan struct{}
	public       bool
	// pendingMu guards pending, the in-order queue of frames admitted for a
	// consumer that has not taken them yet, together with the byte reservation
	// accounting for exactly those frames.
	pendingMu    sync.Mutex
	pending      []relayFrame
	queuedBytes  int64
	maxQueued    int64
	pendingReady chan struct{}
}

func newClientRoute() *clientRoute { return newRoute(false) }

func newRoute(public bool) *clientRoute {
	return &clientRoute{
		frames:       make(chan relayFrame, routeHandoffFrames),
		done:         make(chan struct{}),
		window:       initialStreamWindow,
		windowChange: make(chan struct{}),
		public:       public,
		maxQueued:    routeBufferBytes,
		pendingReady: make(chan struct{}, 1),
	}
}

// reserve accounts for a frame that is about to enter the route's queue. It
// reports false only when the peer has already sent more than one flow-control
// window, which a peer that respects the protocol cannot do.
func (route *clientRoute) reserve(frame relayFrame) bool {
	size := int64(len(frame.Payload))
	route.pendingMu.Lock()
	defer route.pendingMu.Unlock()
	if route.queuedBytes+size > route.maxQueued {
		return false
	}
	route.queuedBytes += size
	return true
}

// enqueue appends a reserved frame to the route in arrival order and wakes the
// delivery goroutine. It never blocks: a frame the peer was allowed to send
// must not stall the tunnel read loop, which carries every other stream on the
// same connection.
func (route *clientRoute) enqueue(frame relayFrame) {
	route.pendingMu.Lock()
	route.pending = append(route.pending, frame)
	route.pendingMu.Unlock()
	select {
	case route.pendingReady <- struct{}{}:
	default:
	}
}

// drain hands queued frames to the consumer in order until the route closes.
// It is the only producer of frames, so a consumer keeps reading one channel
// and the ordering of a response body is preserved. The reservation is dropped
// as each frame leaves the queue: what the bound measures is what is still
// waiting, which is also what flow control counts as unacknowledged.
func (route *clientRoute) drain() {
	defer route.discardPending()
	for {
		route.pendingMu.Lock()
		if len(route.pending) == 0 {
			route.pendingMu.Unlock()
			select {
			case <-route.pendingReady:
				continue
			case <-route.done:
				return
			}
		}
		frame := route.pending[0]
		route.pending[0] = relayFrame{}
		route.pending = route.pending[1:]
		if len(route.pending) == 0 {
			// Drop the backing array once the queue is empty: a long response
			// must not pin a window's worth of buffers for the route's lifetime.
			route.pending = nil
		}
		route.queuedBytes -= int64(len(frame.Payload))
		if route.queuedBytes < 0 {
			route.queuedBytes = 0
		}
		route.pendingMu.Unlock()
		select {
		case route.frames <- frame:
		case <-route.done:
			return
		}
	}
}

// discardPending releases everything a closed route never delivered.
func (route *clientRoute) discardPending() {
	route.pendingMu.Lock()
	route.pending = nil
	route.queuedBytes = 0
	route.pendingMu.Unlock()
}

func (route *clientRoute) close() { route.once.Do(func() { close(route.done) }) }

// notify records the terminal reason the route's consumer owes its peer. The
// first writer wins: a Host that comes back and dies again must not replace the
// explanation the client was already given.
func (route *clientRoute) notify(payload []byte) {
	if len(payload) == 0 {
		return
	}
	route.noticeMu.Lock()
	defer route.noticeMu.Unlock()
	if route.notice == nil {
		route.notice = payload
	}
}

// takeNotice hands the recorded reason over for delivery exactly once, so a
// consumer that races the closure cannot report it twice.
func (route *clientRoute) takeNotice() []byte {
	route.noticeMu.Lock()
	defer route.noticeMu.Unlock()
	notice := route.notice
	route.notice = nil
	return notice
}

func newHostTunnel(
	connection *websocket.Conn,
	readDeadline time.Duration,
	hostGone func(dying *hostTunnel, routes []*clientRoute),
) *hostTunnel {
	if connection != nil {
		connection.SetReadLimit(maxRelayMessageBytes + headerSize)
	}
	var writer *tunnelWriter
	if connection != nil {
		writer = newTunnelWriter(connection)
	}
	return &hostTunnel{
		connection:   connection,
		writer:       writer,
		clients:      make(map[connectionID]*clientRoute),
		closed:       make(chan struct{}),
		readDeadline: readDeadline,
		hostGone:     hostGone,
	}
}

func (tunnel *hostTunnel) openStream(metadata *streamOpen) (connectionID, *clientRoute, error) {
	id, err := newConnectionID()
	if err != nil {
		return connectionID{}, nil, err
	}
	route := newRoute(metadata != nil && (metadata.Class == "http" || metadata.Class == "upgrade"))
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
	// One delivery goroutine per route moves queued frames to the consumer.
	go route.drain()
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
	// Control streams have a bounded route queue and use the control writer
	// lane. Do not make their RPC/input responses wait for the public HTTP body
	// window: a paused browser must not hold Host control traffic for 60s.
	if routeFrameNeedsCredit(route, frame.Kind) {
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

func routeFrameNeedsCredit(route *clientRoute, kind byte) bool {
	return route == nil || route.public || kind == frameData
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

func (route *clientRoute) grant(bytes uint64) bool {
	route.windowMu.Lock()
	defer route.windowMu.Unlock()
	if route.windowChange == nil {
		route.windowChange = make(chan struct{})
	}
	// A WINDOW_UPDATE can only return bytes that were previously consumed.
	// Silently clamping an over-credit to a full window turns a malformed or
	// replayed update into extra send capacity and eventually unbounded relay
	// memory. Zero is a valid no-op for an empty control message.
	if route.window > initialStreamWindow || bytes > initialStreamWindow-route.window {
		return false
	}
	if bytes == 0 {
		return true
	}
	route.window += bytes
	close(route.windowChange)
	route.windowChange = make(chan struct{})
	return true
}

func (tunnel *hostTunnel) readLoop(touch func()) error {
	if tunnel.connection == nil {
		return errors.New("host tunnel connection unavailable")
	}
	defer tunnel.close()
	budget := tunnel.silenceBudget()
	_ = tunnel.connection.SetReadDeadline(time.Now().Add(budget))
	tunnel.connection.SetPongHandler(func(string) error {
		touch()
		return tunnel.connection.SetReadDeadline(time.Now().Add(budget))
	})
	go tunnel.heartbeat()
	for {
		messageType, data, err := tunnel.connection.ReadMessage()
		if err != nil {
			return err
		}
		// Data is liveness evidence, not just pongs.
		_ = tunnel.connection.SetReadDeadline(time.Now().Add(budget))
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
				_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: frame.ConnectionID})
				continue
			}
			if !route.grant(credit) {
				tunnel.removeClient(frame.ConnectionID)
				_ = tunnel.send(relayFrame{Kind: frameError, ConnectionID: frame.ConnectionID, Payload: []byte(`{"code":"invalid_window_update"}`)})
				_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: frame.ConnectionID})
			}
			continue
		}
		if !route.reserve(frame) {
			tunnel.removeClient(frame.ConnectionID)
			_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: frame.ConnectionID})
			continue
		}
		// The queue never refuses a frame the peer's window allowed, and handing
		// it over never blocks: losing a frame here silently truncated a response
		// body, and blocking here would stall every other stream on the tunnel.
		route.enqueue(frame)
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
		// A client holding an established route is owed the reason before its
		// socket goes away — but only once there is a reason worth giving. A
		// tunnel that just died may belong to a Host whose uplink hiccuped and
		// which is back in under a second, so the decision is deferred to the
		// owner rather than made here. It takes over closing these routes.
		routes := make([]*clientRoute, 0, len(clients))
		for _, route := range clients {
			routes = append(routes, route)
		}
		if tunnel.hostGone != nil && len(routes) > 0 {
			tunnel.hostGone(tunnel, routes)
			return
		}
		for _, route := range routes {
			route.close()
		}
	})
}
