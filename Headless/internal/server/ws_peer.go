package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

type outboundMessage struct {
	kind    int
	data    []byte
	control bool
}

// wsPeer owns an independent outbound queue and writer goroutine. A slow
// client only fills its own queue; overflow or a write timeout closes exactly
// this peer, and the client reconnects from its last Recovery Anchor.
type wsPeer struct {
	server        *HTTPServer
	connection    *websocket.Conn
	accessScopeID string
	clientID      string
	// ownerAuthenticated is true for the daemon's static Host token. Scoped
	// pairing clients may operate the Host but cannot mutate Host settings.
	ownerAuthenticated bool
	// outbound is the bounded terminal-output lane. Text/control traffic uses
	// controlOutbound so a burst of binary output cannot delay a response,
	// heartbeat, or recovery marker.
	outbound        chan outboundMessage
	controlOutbound chan outboundMessage
	// transport is set for a Relay control peer. It bypasses the WebSocket
	// socket but is still owned by the peer's writer goroutine, preserving the
	// same bounded queue and service lifecycle.
	transport func(outboundMessage) bool

	enqueueMu   sync.Mutex
	closed      chan struct{}
	closeFlag   bool
	closeReason string
	attached    *api.Session
	// outputs tracks every terminal session this peer subscribed to for
	// output. A desktop client keeps one subscription per retained warm
	// surface so background sessions keep consuming output; legacy web and
	// mobile clients keep exactly the one implicit subscription created by
	// their attach. Guarded by enqueueMu.
	outputs map[string]struct{}
	// attachments binds every output subscription to the DENB input identity
	// returned by session.subscribe. Input is never accepted without this
	// per-connection, per-session binding.
	attachments    map[string]string
	controlSession string
	// agentStreams maps each Session with a canonical Agent subscription to
	// the one execution stream it holds. Without agent-streams-v1 the map has
	// at most one entry, as it always had.
	agentStreams map[string]string
	// screenMu guards the split-screen presentation state below. It is its own
	// lock because reconciling that state requires session lookups, which take
	// the service lock and must not run under the outbound queue's mutex.
	screenMu sync.Mutex
	// screenSessions is presentation state for this authenticated peer only.
	// A daemon may serve several windows/clients at once; keeping this on the
	// peer prevents one window's split layout from overwriting another's.
	screenSessions []string
	// screenGeneration invalidates a lazily filtered snapshot that raced a new
	// client report.
	screenGeneration uint64
	// screenReportedAt orders the screens of several clients that display one
	// Session. A CLI running inside a Session asks "where am I on screen" and
	// expects one answer; the most recent report is the closest thing to the
	// screen the user is actually looking at.
	screenReportedAt time.Time
	// terminalStateFormat is negotiated once during protocol-3 authentication.
	// Every client must install its selected format behind a presentation gate.
	terminalStateFormat string
	// capabilities contains the Host/client intersection established during
	// authentication. It is immutable after the welcome message and guarded by
	// enqueueMu so request handlers and broadcasts can inspect it safely.
	capabilities []string
	rosterCancel context.CancelFunc
	// session.subscribe is intentionally handled in a background goroutine so
	// a slow Ghostline checkpoint cannot block unrelated control requests. Keep
	// one cancellable operation per session so an unsubscribe (or replacement
	// subscribe) can wait for the old recovery to finish before its response is
	// acknowledged to the client.
	subscriptionMu       sync.Mutex
	pendingSubscriptions map[string]*pendingSubscription
}

type pendingSubscription struct {
	cancel   context.CancelFunc
	done     chan struct{}
	doneOnce sync.Once
}

func (p *wsPeer) logInfo(message string, args ...any) {
	if p.server.Logger != nil {
		p.server.Logger.Info(message, args...)
	}
}

func (p *wsPeer) setCapabilities(values []string) {
	p.enqueueMu.Lock()
	p.capabilities = append([]string(nil), values...)
	p.enqueueMu.Unlock()
}

func (p *wsPeer) capabilitiesList() []string {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	return append([]string(nil), p.capabilities...)
}

func (p *wsPeer) supportsCapability(capability string) bool {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	return api.SupportsCapability(p.capabilities, capability)
}

func newWSPeer(server *HTTPServer, connection *websocket.Conn) *wsPeer {
	peer := &wsPeer{
		server:          server,
		connection:      connection,
		outbound:        make(chan outboundMessage, outboundQueueCapacity),
		controlOutbound: make(chan outboundMessage, outboundControlQueueCapacity),
		closed:          make(chan struct{}),
	}
	go peer.writeLoop()
	return peer
}

func newRelayPeer(server *HTTPServer, transport func(outboundMessage) bool) *wsPeer {
	peer := &wsPeer{
		server:          server,
		transport:       transport,
		outbound:        make(chan outboundMessage, outboundQueueCapacity),
		controlOutbound: make(chan outboundMessage, outboundControlQueueCapacity),
		closed:          make(chan struct{}),
	}
	go peer.writeLoop()
	return peer
}

// beginPendingSubscription installs a cancellable marker for one session. A
// replacement subscribe waits for the previous operation with the same ID so
// its attached/atomic-state/synced frames cannot be emitted after the new
// subscription has been acknowledged.
func (p *wsPeer) beginPendingSubscription(parent context.Context, sessionID string) (context.Context, func()) {
	subscriptionContext, cancel := context.WithCancel(parent)
	pending := &pendingSubscription{cancel: cancel, done: make(chan struct{})}
	p.subscriptionMu.Lock()
	if p.pendingSubscriptions == nil {
		p.pendingSubscriptions = make(map[string]*pendingSubscription)
	}
	previous := p.pendingSubscriptions[sessionID]
	p.pendingSubscriptions[sessionID] = pending
	p.subscriptionMu.Unlock()
	if previous != nil {
		previous.cancel()
		<-previous.done
	}

	finish := func() {
		p.subscriptionMu.Lock()
		if p.pendingSubscriptions[sessionID] == pending {
			delete(p.pendingSubscriptions, sessionID)
		}
		pending.doneOnce.Do(func() { close(pending.done) })
		p.subscriptionMu.Unlock()
	}
	return subscriptionContext, finish
}

// cancelPendingSubscription stops and joins an in-flight subscription before
// the caller detaches its output stream. Joining is what makes unsubscribe a
// usable lifecycle boundary for clients that switch sessions quickly.
func (p *wsPeer) cancelPendingSubscription(sessionID string) {
	p.subscriptionMu.Lock()
	pending := p.pendingSubscriptions[sessionID]
	p.subscriptionMu.Unlock()
	if pending == nil {
		return
	}
	pending.cancel()
	<-pending.done
}

// cancelAllPendingSubscriptions invalidates background subscriptions during a
// peer teardown. Teardown must not wait here: a failing writer can be the same
// goroutine that is about to finish the pending operation.
func (p *wsPeer) cancelAllPendingSubscriptions() {
	p.subscriptionMu.Lock()
	for _, pending := range p.pendingSubscriptions {
		pending.cancel()
	}
	p.subscriptionMu.Unlock()
}

func (p *wsPeer) close() {
	p.closeWithReason("shutdown")
}

func (p *wsPeer) closeWithReason(reason string) {
	p.enqueueMu.Lock()
	sessionIDs, agentSessionIDs, controlSessionID := p.closeLocked(reason)
	p.enqueueMu.Unlock()
	p.cancelAllPendingSubscriptions()
	for _, sessionID := range sessionIDs {
		p.server.Service.detachPeer(p, sessionID)
	}
	for _, agentSessionID := range agentSessionIDs {
		p.server.Service.detachAgentPeer(p, agentSessionID)
	}
	// Agent-only focus does not create a terminal output subscription, so the
	// control lease may have no session ID in either cleanup list above. Always
	// release the lease captured while holding enqueueMu; the service-side
	// comparison keeps this idempotent when detachPeer already removed it.
	if controlSessionID != "" {
		p.server.Service.releaseControlPeer(p, controlSessionID)
	}
}

func (p *wsPeer) writeLoop() {
	if p.connection == nil && p.transport == nil {
		return
	}
	controlBurst := 0
	for {
		item, ok := p.nextOutbound(&controlBurst)
		if !ok {
			break
		}
		if p.transport != nil {
			if !p.transport(item) {
				// The Relay stream is the writer's ownership boundary. A failed
				// transport send closes only this peer and lets the normal detach
				// path release subscriptions; enqueue callers never wait on the
				// network while holding enqueueMu.
				p.closeWithReason("relay_write_error")
				return
			}
			continue
		}
		_ = p.connection.SetWriteDeadline(time.Now().Add(outboundWriteTimeout))
		if err := p.connection.WriteMessage(item.kind, item.data); err != nil {
			p.closeWithReason("write_error")
			return
		}
	}
	// The channel closed after a peer teardown; let the writer flush the
	// already-queued final messages (for example the auth error) before
	// releasing the socket. Relay peers have no local WebSocket to close.
	if p.connection != nil {
		_ = p.connection.Close()
	}
}

// nextOutbound gives control traffic a reserved lane while allowing terminal
// output to make progress under a continuous stream of responses/events. The
// non-blocking probes keep the common control-first path cheap; the final
// select sleeps only when both lanes are empty. A closed lane is drained
// before the writer exits so teardown can still flush an already-queued error
// or recovery marker.
func (p *wsPeer) nextOutbound(controlBurst *int) (outboundMessage, bool) {
	control := p.controlOutbound
	data := p.outbound
	for control != nil || data != nil {
		if control != nil && (*controlBurst < outboundControlFairness || data == nil) {
			select {
			case item, ok := <-control:
				if !ok {
					control = nil
					continue
				}
				(*controlBurst)++
				return item, true
			default:
			}
		}
		if data != nil {
			select {
			case item, ok := <-data:
				if !ok {
					data = nil
					continue
				}
				*controlBurst = 0
				return item, true
			default:
			}
		}
		select {
		case item, ok := <-control:
			if !ok {
				control = nil
				continue
			}
			(*controlBurst)++
			return item, true
		case item, ok := <-data:
			if !ok {
				data = nil
				continue
			}
			*controlBurst = 0
			return item, true
		}
	}
	return outboundMessage{}, false
}

func (p *wsPeer) enqueue(item outboundMessage) bool {
	p.enqueueMu.Lock()
	// A few embedders construct wsPeer directly in tests. Lazily initialize
	// the same owned writer used by production constructors so no code path
	// falls back to a synchronous Relay transport call.
	if p.closed == nil {
		p.closed = make(chan struct{})
	}
	if p.outbound == nil && (p.transport != nil || p.connection != nil) {
		p.outbound = make(chan outboundMessage, outboundQueueCapacity)
		p.controlOutbound = make(chan outboundMessage, outboundControlQueueCapacity)
		go p.writeLoop()
	}
	if p.controlOutbound == nil && (p.transport != nil || p.connection != nil) {
		p.controlOutbound = make(chan outboundMessage, outboundControlQueueCapacity)
	}
	select {
	case <-p.closed:
		p.enqueueMu.Unlock()
		return false
	default:
	}
	queue := p.outbound
	if (item.kind == websocket.TextMessage || item.control) && p.controlOutbound != nil {
		queue = p.controlOutbound
	}
	select {
	case queue <- item:
		p.enqueueMu.Unlock()
		return true
	default:
		// Queue overflow is a per-client failure: close only this peer. The
		// client reconnects with its Recovery Anchor and Host re-serves the
		// retained tail from the ring.
		sessionIDs, agentSessionIDs, controlSessionID := p.closeLocked("queue_overflow")
		p.enqueueMu.Unlock()
		p.cancelAllPendingSubscriptions()
		for _, sessionID := range sessionIDs {
			p.server.Service.detachPeer(p, sessionID)
		}
		for _, agentSessionID := range agentSessionIDs {
			p.server.Service.detachAgentPeer(p, agentSessionID)
		}
		if controlSessionID != "" {
			p.server.Service.releaseControlPeer(p, controlSessionID)
		}
		return false
	}
}

// closeLocked must be called with enqueueMu held. It is idempotent so both
// the writer's error path and queue overflow can tear down the same peer
// exactly once. It returns every terminal subscription ID and the
// agent-only subscription ID so the caller can unregister after releasing
// the lock, keeping registry lock ordering acyclic.

func (p *wsPeer) closeLocked(reason string) ([]string, []string, string) {
	if p.closeFlag {
		agentSessionIDs := p.agentSessionIDsLocked()
		controlSessionID := p.controlSession
		sessionIDs := make([]string, 0, len(p.outputs)+1)
		for sessionID := range p.outputs {
			sessionIDs = append(sessionIDs, sessionID)
		}
		if p.attached != nil {
			alreadyTracked := false
			for _, sessionID := range sessionIDs {
				if sessionID == p.attached.ID {
					alreadyTracked = true
					break
				}
			}
			if !alreadyTracked {
				sessionIDs = append(sessionIDs, p.attached.ID)
			}
		}
		return sessionIDs, agentSessionIDs, controlSessionID
	}
	p.closeFlag = true
	p.closeReason = reason
	p.screenMu.Lock()
	p.screenSessions = nil
	p.screenGeneration++
	p.screenMu.Unlock()
	if p.rosterCancel != nil {
		p.rosterCancel()
		p.rosterCancel = nil
	}
	sessionIDs := make([]string, 0, len(p.outputs)+1)
	for sessionID := range p.outputs {
		sessionIDs = append(sessionIDs, sessionID)
	}
	if p.attached != nil {
		alreadyTracked := false
		for _, sessionID := range sessionIDs {
			if sessionID == p.attached.ID {
				alreadyTracked = true
				break
			}
		}
		if !alreadyTracked {
			sessionIDs = append(sessionIDs, p.attached.ID)
		}
	}
	close(p.closed)
	if p.controlOutbound != nil {
		close(p.controlOutbound)
	}
	if p.outbound != nil {
		close(p.outbound)
	}
	attachedID := ""
	if p.attached != nil {
		attachedID = p.attached.ID
	}
	p.logInfo("peer closed",
		"reason", reason,
		"queue", p.outboundLengthLocked(),
		"controlQueue", p.controlOutboundLengthLocked(),
		"outputs", len(p.outputs),
		"attached", attachedID,
	)
	return sessionIDs, p.agentSessionIDsLocked(), p.controlSession
}

// agentSessionIDsLocked must be called with enqueueMu held.
func (p *wsPeer) agentSessionIDsLocked() []string {
	sessionIDs := make([]string, 0, len(p.agentStreams))
	for sessionID := range p.agentStreams {
		sessionIDs = append(sessionIDs, sessionID)
	}
	return sessionIDs
}

func (p *wsPeer) outboundLengthLocked() int {
	if p.outbound == nil {
		return 0
	}
	return len(p.outbound)
}

func (p *wsPeer) controlOutboundLengthLocked() int {
	if p.controlOutbound == nil {
		return 0
	}
	return len(p.controlOutbound)
}

func (p *wsPeer) writeJSON(value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return p.writeText(data)
}

func (p *wsPeer) writeText(data []byte) error {
	if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
		return errors.New("outbound queue overflow")
	}
	return nil
}

func (p *wsPeer) enqueueBinary(data []byte) bool {
	return p.enqueue(outboundMessage{kind: websocket.BinaryMessage, data: data})
}

// enqueueDroppableBinary sends a message that is safe to drop when the peer
// cannot keep up.
//
// The outbound queue treats overflow as a per-client failure and closes the
// peer, which is right for terminal output — the client reconnects and replays
// from its anchor — and wrong for a screencast frame. A viewer that paused, or a
// machine that slept, would have its whole connection torn down, taking every
// terminal subscription on the same socket with it, to deliver frames that carry
// no state the next frame does not also carry.
func (p *wsPeer) enqueueDroppableBinary(data []byte) bool {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	if p.closed == nil {
		return false
	}
	select {
	case <-p.closed:
		return false
	default:
	}
	select {
	case p.outbound <- outboundMessage{kind: websocket.BinaryMessage, data: data}:
		return true
	default:
		return false
	}
}

func (p *wsPeer) enqueueControlBinary(data []byte) bool {
	if !p.enqueue(outboundMessage{kind: websocket.BinaryMessage, data: data, control: true}) {
		return false
	}
	return true
}

func (p *wsPeer) enqueueAtomicState(
	sessionID string,
	epoch, sequence uint64,
	format string,
	payload []byte,
) error {
	encoded, err := output.EncodeAtomicState(sessionID, epoch, sequence, format, payload)
	if err != nil {
		return err
	}
	if !p.enqueueControlBinary(encoded) {
		return errors.New("outbound queue overflow during atomic recovery")
	}
	return nil
}

func (p *wsPeer) enqueueAttached(sessionID string, epoch, sequence uint64, reanchor bool) error {
	attachmentID := p.attachmentID(sessionID)
	if attachmentID == "" {
		return fmt.Errorf("terminal attachment is not registered: %s", sessionID)
	}
	return p.writeJSON(map[string]any{
		"t": "attached", "session": sessionID,
		"epoch": epoch, "sequence": sequence,
		"reanchor": reanchor, "attachmentId": attachmentID,
	})
}

func (p *wsPeer) enqueueSynced(sessionID string, epoch, sequence uint64) error {
	return p.writeJSON(map[string]any{
		"t": "synced", "session": sessionID, "epoch": epoch, "sequence": sequence,
	})
}

func (p *wsPeer) enqueueCanonicalAgentEvents(streamID, executionID string, events []api.CanonicalAgentEvent) error {
	if len(events) == 0 {
		return nil
	}
	return p.writeJSON(api.CanonicalAgentEventsMessage{
		Type:        "agent.events",
		StreamID:    streamID,
		ExecutionID: executionID,
		Events:      events,
	})
}

func (p *wsPeer) enqueueExited(sessionID string) error {
	return p.writeJSON(map[string]any{"t": "exited", "session": sessionID})
}

func (p *wsPeer) writeResult(id string, result any) error {
	return p.writeJSON(api.Response{Type: "response", ID: id, OK: true, Result: result})
}
func (p *wsPeer) writeError(id string, err error) error {
	return p.writeJSON(api.Response{Type: "response", ID: id, OK: false, Error: err.Error()})
}

type canonicalProtocolError struct {
	code    string
	message string
	details any
}

func (e *canonicalProtocolError) Error() string {
	if e == nil {
		return "canonical protocol error"
	}
	return e.message
}

func (p *wsPeer) writeCanonicalError(id string, err error) error {
	code := "invalid_command"
	var details any
	var protocolErr *canonicalProtocolError
	if errors.As(err, &protocolErr) {
		code = protocolErr.code
		details = protocolErr.details
	}
	var boundary *store.CanonicalHistoryBoundary
	if protocolErr == nil && errors.As(err, &boundary) {
		code = "history_boundary"
		details = map[string]any{
			"streamId":             boundary.StreamID,
			"retainedFromSequence": boundary.RetainedFromSequence,
			"headSequence":         boundary.HeadSequence,
			"checkpointSequence":   boundary.CheckpointSequence,
			"checkpoint":           boundary.Checkpoint,
		}
	} else if protocolErr == nil && strings.Contains(strings.ToLower(err.Error()), "capability") {
		code = "capability_unavailable"
	} else if protocolErr == nil && errors.Is(err, store.ErrCanonicalCommandPending) {
		code = "command_pending"
	} else if protocolErr == nil && errors.Is(err, store.ErrCanonicalCommandUnknown) {
		code = "command_indeterminate"
	} else if protocolErr == nil && (errors.Is(err, store.ErrCanonicalCommandConflict) || strings.Contains(strings.ToLower(err.Error()), "idempotency")) {
		code = "command_conflict"
	} else if protocolErr == nil && (strings.Contains(strings.ToLower(err.Error()), "version") || strings.Contains(strings.ToLower(err.Error()), "stale")) {
		code = "stale_version"
	}
	return p.writeJSON(api.Response{Type: "response", ID: id, OK: false, Error: err.Error(), Code: code, Details: details})
}
