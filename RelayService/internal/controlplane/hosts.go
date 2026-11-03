package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

func (server *Server) connectHost(response http.ResponseWriter, request *http.Request) {
	if version := strings.TrimSpace(request.URL.Query().Get("version")); version != "" && version != "2.0" {
		http.Error(response, "unsupported relay version", http.StatusUpgradeRequired)
		return
	}
	if !hostWantsV2(request) {
		http.Error(response, "BRLY/2 is required", http.StatusUpgradeRequired)
		return
	}
	hostID := strings.TrimSpace(request.URL.Query().Get("host_id"))
	if !validHostID(hostID) {
		http.Error(response, "invalid host_id", http.StatusBadRequest)
		return
	}
	if len(request.URL.Query().Get("name")) > 256 {
		http.Error(response, "invalid host name", http.StatusBadRequest)
		return
	}
	credential := bearerToken(request)
	if !server.registry.authenticateHost(hostID, credential) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	connection, err := server.upgrader.Upgrade(response, request, nil)
	if err != nil {
		return
	}
	tunnel := newHostTunnel(connection, server.readDeadline(), func(dying *hostTunnel, routes []*clientRoute) {
		server.reportHostLoss(hostID, dying, routes)
	})
	if err := server.hostHandshake(connection, hostID, credential); err != nil {
		tunnel.close()
		return
	}
	if !server.registry.connectHost(hostID, strings.TrimSpace(request.URL.Query().Get("name")), credential, tunnel) {
		tunnel.close()
		return
	}
	// Release clients that are waiting for this Host to come back.
	server.registry.signalHostOnline(hostID)
	server.config.Logger.Info("host connected", "host_id", hostID)
	defer func() {
		server.registry.disconnectHost(hostID, tunnel)
		server.config.Logger.Info("host disconnected", "host_id", hostID)
	}()
	_ = tunnel.readLoop(func() { server.registry.touchHost(hostID, tunnel) })
}

func hostWantsV2(request *http.Request) bool {
	if strings.TrimSpace(request.URL.Query().Get("version")) == "2.0" {
		return true
	}
	for _, value := range request.Header.Values("Sec-WebSocket-Protocol") {
		for _, protocol := range strings.Split(value, ",") {
			if strings.TrimSpace(strings.ToLower(protocol)) == "brly/2" {
				return true
			}
		}
	}
	return false
}

type relayChallenge struct {
	Type         string   `json:"t"`
	Version      string   `json:"version"`
	Nonce        string   `json:"nonce"`
	RelayID      string   `json:"relay_id"`
	KeyID        string   `json:"key_id,omitempty"`
	Capabilities []string `json:"capabilities"`
}

type relayHello struct {
	Type         string   `json:"t"`
	Version      string   `json:"version"`
	HostID       string   `json:"host_id"`
	Capabilities []string `json:"capabilities"`
	Proof        string   `json:"proof"`
}

func (server *Server) hostHandshake(connection *websocket.Conn, hostID, credential string) error {
	nonce, err := randomToken(24)
	if err != nil {
		return err
	}
	challenge := relayChallenge{
		Type: "relay_challenge", Version: "2.0", Nonce: nonce,
		RelayID: relayID(server.config.PublicURL), KeyID: server.signer.currentKeyID(),
		Capabilities: []string{"control", "http", "upgrade", "p2p-signal"},
	}
	if err := connection.WriteJSON(challenge); err != nil {
		return err
	}
	_ = connection.SetReadDeadline(time.Now().Add(30 * time.Second))
	messageType, payload, err := connection.ReadMessage()
	if err != nil || messageType != websocket.TextMessage {
		return errors.New("invalid host hello")
	}
	var hello relayHello
	if json.Unmarshal(payload, &hello) != nil || hello.Type != "host_hello" || hello.Version != "2.0" || hello.HostID != hostID {
		return errors.New("invalid host hello")
	}
	if !hasAllCapabilities(hello.Capabilities, []string{"control", "http", "upgrade"}) {
		return errors.New("host capabilities do not satisfy relay")
	}
	canonical := canonicalChallenge(challenge, hostID)
	if !verifyChallengeProof(credential, canonical, hello.Proof) {
		return errors.New("invalid host challenge proof")
	}
	generation, ok := server.registry.generation(hostID)
	if !ok {
		return errHostNotFound
	}
	welcome := map[string]any{
		"t": "host_welcome", "version": "2.0", "generation": generation,
		"limits": map[string]any{"frame_bytes": maxRelayMessageBytes, "window_bytes": initialStreamWindow},
	}
	if route, ok := server.registry.route(hostID); ok {
		welcome["route"] = route
	}
	if err := connection.WriteJSON(welcome); err != nil {
		return err
	}
	_ = connection.SetReadDeadline(time.Time{})
	return nil
}

func hasAllCapabilities(advertised, required []string) bool {
	set := make(map[string]struct{}, len(advertised))
	for _, value := range advertised {
		set[strings.TrimSpace(value)] = struct{}{}
	}
	for _, value := range required {
		if _, ok := set[value]; !ok {
			return false
		}
	}
	return true
}

func (server *Server) getHost(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	credential := bearerToken(request)
	if !secureEqual(credential, server.config.AdminToken) &&
		!server.registry.authenticateHost(hostID, credential) &&
		!server.authorizeAccess(credential, hostID) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	host, ok := server.registry.host(hostID)
	if !ok {
		http.Error(response, "not found", http.StatusNotFound)
		return
	}
	writeJSON(response, http.StatusOK, host)
}

func (server *Server) connectClient(response http.ResponseWriter, request *http.Request) {
	if !originAllowed(server.config.AllowedOrigin, request.Header.Get("Origin")) {
		http.Error(response, "origin not allowed", http.StatusForbidden)
		return
	}
	if !server.clientLimiter.allow("ip:" + requestClientIP(request)) {
		writeRateLimit(response, server.config.RateLimitWindow)
		return
	}
	requestedHostID := ""
	if scopedHostID := strings.TrimSpace(request.PathValue("hostID")); scopedHostID != "" {
		if !validHostID(scopedHostID) {
			http.Error(response, "invalid host_id", http.StatusBadRequest)
			return
		}
		requestedHostID = scopedHostID
	}
	client, err := server.upgrader.Upgrade(response, request, nil)
	if err != nil {
		return
	}
	defer client.Close()
	client.SetReadLimit(maxRelayMessageBytes)
	_ = client.SetReadDeadline(time.Now().Add(30 * time.Second))
	messageType, authPayload, err := client.ReadMessage()
	var auth struct {
		Type        string `json:"t"`
		AccessToken string `json:"access_token"`
		ClientID    string `json:"client_id"`
		Version     string `json:"version"`
	}
	if err != nil || messageType != websocket.TextMessage || json.Unmarshal(authPayload, &auth) != nil || auth.Type != "auth" || auth.Version != clientProtocolVersion || strings.TrimSpace(auth.AccessToken) == "" {
		refuseClient(client, map[string]string{"t": "error", "error": "unauthorized", "message": "unauthorized"})
		return
	}
	claims, err := server.signer.verify(auth.AccessToken, requestedHostID, "control")
	if err != nil {
		refuseClient(client, map[string]string{"t": "error", "error": "unauthorized", "message": "unauthorized"})
		return
	}
	hostID := claims.HostID
	if requestedHostID != "" && requestedHostID != hostID {
		refuseClient(client, map[string]string{"t": "error", "error": "unauthorized", "message": "unauthorized"})
		return
	}
	if claims.ClientID != "" && (auth.ClientID == "" || auth.ClientID != claims.ClientID) {
		refuseClient(client, map[string]string{"t": "error", "error": "unauthorized", "message": "unauthorized"})
		return
	}
	if !server.clientLimiter.allow("host:" + hostID) {
		refuseClient(client, map[string]string{"t": "error", "error": "rate limit exceeded", "message": "rate limit exceeded"})
		return
	}
	tunnel := server.awaitAuthorizedTunnel(request.Context(), hostID, claims.Generation)
	if tunnel == nil {
		refuseClient(client, server.hostOfflinePayload(hostID))
		return
	}
	clientBudget := server.readDeadline()
	_ = client.SetReadDeadline(time.Now().Add(clientBudget))
	client.SetPongHandler(func(string) error {
		return client.SetReadDeadline(time.Now().Add(clientBudget))
	})
	connectionID, route, err := tunnel.openStream(&streamOpen{Class: "control", Version: "2.0", HostID: hostID, ClientID: claims.ClientID, Token: auth.AccessToken})
	if err != nil {
		return
	}
	if err := tunnel.send(relayFrame{Kind: frameText, ConnectionID: connectionID, Payload: authPayload}); err != nil {
		// The tunnel died between handing out the route and forwarding the auth
		// frame, so this client never got a reason and must not be dropped
		// silently. The Host is gone either way, which is exactly what the
		// offline payload says.
		tunnel.removeClient(connectionID)
		refuseClient(client, server.hostOfflinePayload(hostID))
		return
	}
	defer func() {
		tunnel.removeClient(connectionID)
		_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: connectionID})
	}()
	clientFrames := make(chan relayFrame, 64)
	clientErrors := make(chan error, 1)
	clientDone := make(chan struct{})
	defer close(clientDone)
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-clientDone:
				return
			case <-ticker.C:
				if client.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second)) != nil {
					return
				}
			}
		}
	}()
	clientReadDone := make(chan struct{})
	go func() {
		defer close(clientReadDone)
		for {
			messageType, data, err := client.ReadMessage()
			if err != nil {
				clientErrors <- err
				return
			}
			// A client that is sending input is alive. Requiring a pong here
			// disconnected phones mid-typing whenever one was dropped.
			_ = client.SetReadDeadline(time.Now().Add(clientBudget))
			kind := frameText
			if messageType == websocket.BinaryMessage {
				kind = frameBinary
			} else if messageType != websocket.TextMessage {
				continue
			}
			select {
			case clientFrames <- relayFrame{Kind: byte(kind), ConnectionID: connectionID, Payload: data}:
			case <-clientDone:
				return
			}
		}
	}()
	// Host output and client input are independent directions. A phone whose
	// socket drains slowly can hold a downstream WriteMessage for hundreds of
	// milliseconds, and a single loop would make every keystroke wait behind that
	// write plus its window update. Give the downstream direction its own
	// goroutine so input keeps flowing while output is still draining.
	downstreamDone := make(chan struct{})
	// The downstream goroutine owns the terminal write and the close handshake
	// when the Host dies under this route, so it has to finish before this
	// function's `defer client.Close()` drops the socket underneath it. Every
	// path out of that goroutine ends in a write or drain carrying its own
	// deadline; their sum bounds this wait so a stuck peer cannot pin the
	// handler.
	settleDownstream := func() {
		select {
		case <-downstreamDone:
		case <-time.After(downstreamSettleBudget):
		}
	}
	go func() {
		defer close(downstreamDone)
		for {
			select {
			case frame := <-route.frames:
				if frame.Kind == frameClose || frame.Kind == frameError {
					return
				}
				messageType := websocket.TextMessage
				if frame.Kind == frameBinary {
					messageType = websocket.BinaryMessage
				}
				_ = client.SetWriteDeadline(time.Now().Add(10 * time.Second))
				// Browsers negotiate permessage-deflate, so without this every
				// keystroke echo was deflated into something larger than the bytes
				// it carried. Safe from this goroutine: it owns every data write to
				// the client, and the heartbeat's WriteControl never consults the
				// compression flag.
				client.EnableWriteCompression(len(frame.Payload) >= compressionThreshold)
				err := client.WriteMessage(messageType, frame.Payload)
				if err != nil {
					return
				}
				// Return credit only when this route/frame combination consumed
				// body-window capacity. Control text/binary frames use the reserved
				// lane; public streams and control DATA remain flow-controlled.
				if routeFrameNeedsCredit(route, frame.Kind) {
					if tunnel.send(relayFrame{Kind: frameWindowUpdate, ConnectionID: connectionID, Payload: encodeWindowCredit(uint64(len(frame.Payload)))}) != nil {
						return
					}
				}
			case <-route.done:
				// The Host tunnel died under this route. Deliver the reason it
				// left on the route and close cleanly, so the client is told why
				// instead of watching a bare TCP close and rediscovering the
				// absence through its own backoff.
				if notice := route.takeNotice(); len(notice) > 0 {
					deliverClientNotice(client, notice, clientReadDone)
				}
				return
			case <-clientDone:
				return
			}
		}
	}()
	for {
		select {
		case frame := <-clientFrames:
			if tunnel.sendStream(connectionID, frame) != nil {
				// The tunnel is gone, so the route is closed and the downstream
				// goroutine is already writing the reason. Let it finish before
				// this function's `defer client.Close()` drops the socket.
				settleDownstream()
				return
			}
		case <-route.done:
			settleDownstream()
			return
		case <-downstreamDone:
			return
		case <-clientErrors:
			return
		}
	}
}

// reportHostLoss decides whether a dead Host tunnel means the Host is gone, and
// only then tells the clients that were attached to it. It owns closing them.
//
// A tunnel dying is not the same as a Host being away. A home uplink hiccup or a
// Wi-Fi roam drops the tunnel and the Host is back in under a second; reporting
// `host_offline` on the spot paints a red "Mac is offline" banner for that
// hiccup, and because an announced absence deliberately skips the client's
// settle grace, it is painted immediately. That is the failure this whole
// presentation contract exists to avoid.
//
// So the routes are held for a short confirmation window. A Host that comes back
// inside it takes the reason off the table: the routes are dropped without one,
// the client reconnects, and `awaitAuthorizedTunnel` hands it the new tunnel
// well inside its own grace, so nothing is shown. A Host that does not come back
// gets its absence announced with an accurate last-seen time.
func (server *Server) reportHostLoss(hostID string, dying *hostTunnel, routes []*clientRoute) {
	go func() {
		// Subscribe before the first check so a Host that reconnects between the
		// check and the wait cannot be missed.
		signal := server.registry.hostOnlineSignal(hostID)
		if !server.hostTunnelReplaced(hostID, dying) {
			timer := time.NewTimer(server.hostLossConfirmation())
			defer timer.Stop()
			select {
			case <-signal:
				// Only a signal, not proof: it fires for any connection from this
				// Host, including one that loses its own handshake. Re-check.
				if !server.hostTunnelReplaced(hostID, dying) {
					server.notifyHostGone(hostID, routes)
				}
			case <-timer.C:
				server.notifyHostGone(hostID, routes)
			}
		}
		for _, route := range routes {
			route.close()
		}
	}()
}

// hostTunnelReplaced reports whether some tunnel other than the dying one is now
// authorized for this Host. Comparing tunnels rather than reading the online flag
// keeps this correct regardless of whether `disconnectHost` has run yet: the
// dying tunnel's own teardown races this check.
func (server *Server) hostTunnelReplaced(hostID string, dying *hostTunnel) bool {
	record, ok := server.registry.host(hostID)
	if !ok {
		return false
	}
	current := server.registry.authorizedTunnel(hostID, record.Generation)
	return current != nil && current != dying
}

// notifyHostGone records the absence on every route. The payload is built once so
// all of them name the same Host and the same last-seen time.
func (server *Server) notifyHostGone(hostID string, routes []*clientRoute) {
	notice := mustJSON(server.hostOfflinePayload(hostID))
	for _, route := range routes {
		route.notify(notice)
	}
}

// hostLossConfirmation is how long Relay waits for a dropped Host before telling
// its clients it is gone.
//
// It has to outlast a Host reconnect: the connector's first retry is ~1s with
// ±20% jitter, plus TCP, the WebSocket upgrade and the BRLY/2 challenge. It also
// has to stay within the client's settle grace, because that is the budget the
// client has already committed to staying quiet — a reason that lands later is
// read as a reason for an interruption the user was already shown. Both ends use
// the same 3s, which is not a coincidence: it is the same question asked from
// two sides.
func (server *Server) hostLossConfirmation() time.Duration {
	if server.config.HostLossConfirmation > 0 {
		return server.config.HostLossConfirmation
	}
	return hostLossConfirmation
}

// awaitAuthorizedTunnel returns the Host tunnel, waiting briefly when the Host
// is not connected yet. A Mac that just woke, restarted its daemon, or is
// reconnecting after a Relay restart is usually back within seconds; making the
// client wait here keeps that gap invisible instead of reporting the Host as
// offline and leaving the client to rediscover it through its own backoff.
func (server *Server) awaitAuthorizedTunnel(ctx context.Context, hostID string, generation uint64) *hostTunnel {
	if tunnel := server.registry.authorizedTunnel(hostID, generation); tunnel != nil {
		return tunnel
	}
	timer := time.NewTimer(server.hostPresenceWait())
	defer timer.Stop()
	for {
		// Subscribe before the final check so a Host that connects during this
		// call cannot be missed between the check and the wait.
		signal := server.registry.hostOnlineSignal(hostID)
		if tunnel := server.registry.authorizedTunnel(hostID, generation); tunnel != nil {
			return tunnel
		}
		select {
		case <-signal:
			// A Host may connect with a different generation (re-enrollment) or
			// drop again immediately; loop until the deadline instead of trusting
			// the first wake-up.
		case <-timer.C:
			return nil
		case <-ctx.Done():
			return nil
		}
	}
}

// hostOfflinePayload keeps the historical `error`/`message` fields and adds the
// facts a client needs to explain the wait: a stable code, when the Host was
// last seen, and how long to wait before trying again.
func (server *Server) hostPresenceWait() time.Duration {
	if server.config.HostPresenceWait > 0 {
		return server.config.HostPresenceWait
	}
	return hostPresenceWait
}

// readDeadline is the silence budget for one hop. Inbound frames refresh it, so
// a busy connection never reaches it.
func (server *Server) readDeadline() time.Duration {
	if server.config.ReadDeadline > 0 {
		return server.config.ReadDeadline
	}
	return relayReadDeadline
}

// refuseClient tells a client why it cannot have a Host tunnel, and makes sure
// the explanation survives the disconnect.
//
// `WriteJSON` followed by a bare `Close()` drops the TCP connection without a
// close handshake, so the frame races a truncated stream: the peer reports an
// abnormal 1006 closure and browser/undici WebSockets discard whatever was
// still buffered. Measured against a real Relay, a Host that died mid-session
// left the client showing "Authenticating…" forever — it had reconnected,
// waited out the presence window, been told "host offline", and never seen it.
// Writing a close frame after the payload terminates the stream cleanly, which
// is what makes the preceding text frame deliverable.
func refuseClient(client *websocket.Conn, payload any) {
	_ = client.SetWriteDeadline(time.Now().Add(relayRefusalWriteBudget))
	_ = client.WriteJSON(payload)
	finishClientClose(client)
}

// finishClientClose sends a close frame and drains until the peer answers it, so
// a payload written moments ago survives the disconnect.
//
// The frame alone is not enough: the caller's `defer client.Close()` drops the
// TCP connection, and a peer that has not finished echoing the close still
// reports 1006 and discards its buffer. Measured with undici (the WebSocket the
// web client runs on), the payload only survived once the handshake completed.
// The drain is bounded so a silent client cannot pin the handler.
func finishClientClose(client *websocket.Conn) {
	_ = client.SetWriteDeadline(time.Now().Add(relayRefusalWriteBudget))
	_ = client.WriteControl(
		websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		time.Now().Add(relayRefusalWriteBudget),
	)
	_ = client.SetReadDeadline(time.Now().Add(relayRefusalWriteBudget))
	for {
		if _, _, err := client.ReadMessage(); err != nil {
			return
		}
	}
}

// deliverClientNotice writes a terminal reason to a client that did have a
// working connection, then terminates the stream cleanly. It is the mid-session
// counterpart to refuseClient: the socket was healthy, so the client has every
// reason to expect it to stay that way and deserves to be told what changed.
//
// Only one goroutine may read a WebSocket, and the client reader is already
// running. So this writes the reason and the close frame and then waits on the
// reader, which returns as soon as the peer echoes the close. Reading here
// instead would race it.
func deliverClientNotice(client *websocket.Conn, payload []byte, readerDone <-chan struct{}) {
	// Shorten the reader's budget first so it cannot hold the wait open: it is
	// otherwise armed for the full silence budget of a live connection.
	_ = client.SetReadDeadline(time.Now().Add(relayRefusalWriteBudget))
	_ = client.SetWriteDeadline(time.Now().Add(relayRefusalWriteBudget))
	if err := client.WriteMessage(websocket.TextMessage, payload); err != nil {
		return
	}
	_ = client.WriteControl(
		websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		time.Now().Add(relayRefusalWriteBudget),
	)
	select {
	case <-readerDone:
	case <-time.After(relayRefusalWriteBudget):
	}
}

func (server *Server) hostOfflinePayload(hostID string) map[string]any {
	payload := map[string]any{
		"t":              "error",
		"error":          "host offline",
		"message":        "host offline",
		"code":           "host_offline",
		"retry_after_ms": int64(server.hostPresenceWait() / time.Millisecond),
	}
	if host, ok := server.registry.host(hostID); ok {
		if !host.LastSeenAt.IsZero() {
			payload["last_seen_at"] = host.LastSeenAt.UTC().Format(time.RFC3339)
		}
		if host.Name != "" {
			payload["host_name"] = host.Name
		}
	}
	return payload
}

func relayStreamDeadline(upgrade bool) int64 {
	if upgrade {
		// Upgrade streams carry a long-lived WebSocket after the 101
		// handshake. The deadline is for HTTP request admission only and must
		// not cancel a healthy terminal connection one minute later.
		return 0
	}
	return int64((60 * time.Second) / time.Millisecond)
}
