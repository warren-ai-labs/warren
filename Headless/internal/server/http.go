package server

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/gorilla/websocket"
)

const (
	// High-throughput TUI output (codex, long-running builds) can fill a
	// small per-peer queue before a mobile or hidden browser drains it. The
	// queue is deliberately generous: memory is cheap and the only fallback
	// is closing the peer, which today means a visible reanchor.
	outboundQueueCapacity        = 8192
	outboundControlQueueCapacity = 512
	outboundControlFairness      = 32
	outboundWriteTimeout         = 30 * time.Second
	slowMutationTimeout          = 30 * time.Second
	rosterDeltaBatchDelay        = 75 * time.Millisecond
	lanPairingWindowTTL          = 60 * time.Second
)

type HTTPServer struct {
	Service *Service
	Token   string
	// AccessScopeID is the stable, non-secret visibility scope for direct
	// authenticated clients. Relay clients receive a derived scope from their
	// stable client ID so local replicas cannot collide across sharing scopes.
	AccessScopeID string
	Logger        *slog.Logger
	// RelayStart and RelayStop are installed by the daemon entrypoint. Keeping
	// lifecycle hooks on the HTTP server lets settings.put toggle the supervised
	// connector without touching Session or PTY ownership; tests and embedded
	// callers may leave them nil.
	RelayStart func() error
	RelayStop  func()
	// RelayEnroll performs a Host-initiated Relay claim. The callback owns the
	// daemon's Host credential and persists only non-secret Relay metadata.
	RelayEnroll func(context.Context, string, string, string) error
	// RelayReset removes the local Relay identity in addition to clearing the
	// persisted Relay metadata.
	RelayReset func() error
	// RelayRouteClient creates an authenticated client for the Relay route API.
	// Route lifecycle uses the same Host Secret as the BRLY/2 connector.
	RelayRouteClient func() (*relay.RouteClient, error)
	// RelayPairing creates a safe client-facing invite. The callback owns the
	// Host Secret and returns only an opaque URL plus its expiry metadata.
	RelayPairing func(context.Context) (relay.PairingResult, error)
	// RelayState is queried by /healthz to surface the supervised connector's
	// current state. Optional: a nil callback reports an unconfigured relay.
	RelayState    func() api.RelayHealth
	BuildVersion  string
	BuildRevision string
	BuildDirty    bool
	// GhostlineRPCVersion is the protocol version reported by the running
	// Ghostline server.
	GhostlineRPCVersion string
	// GhostlineTagVersion is the Ghostline Go module version compiled into
	// Warren.
	GhostlineTagVersion string
	CACertPath          string
	upgrader            websocket.Upgrader

	peersMu sync.Mutex
	peers   map[*wsPeer]struct{}
	// relayPeers maps one authenticated BRLY control stream to the same
	// service peer implementation used by local WebSocket clients. The Relay
	// connector owns the transport; this map only carries lifecycle state.
	relayPeersMu sync.Mutex
	relayPeers   map[relay.ConnectionID]*relayControlPeer
	publicAccess *PublicAccessService
	// pairingMu protects the short-lived in-memory LAN pairing window. The
	// window is deliberately not persisted, so a daemon restart always closes
	// pairing and requires an explicit Host-side action again.
	pairingMu     sync.Mutex
	pairingWindow *lanPairingWindow
	// ordered runs per-session requests off the WebSocket reader without
	// reordering them. Shared by the local and Relay control paths so a session
	// keeps one ordering domain no matter which transport a client arrives on.
	ordered *orderedDispatcher
}

type rosterMessage struct {
	Type  string    `json:"t"`
	State api.State `json:"state"`
}

func NewHTTPServer(service *Service, token string, logger *slog.Logger) *HTTPServer {
	server := &HTTPServer{
		Service:       service,
		Token:         token,
		AccessScopeID: "scope-owner",
		Logger:        logger,
		peers:         make(map[*wsPeer]struct{}),
		relayPeers:    make(map[relay.ConnectionID]*relayControlPeer),
		ordered:       newOrderedDispatcher(),
		upgrader: websocket.Upgrader{
			EnableCompression: true,
			ReadBufferSize:    256 * 1024,
			WriteBufferSize:   256 * 1024,
			CheckOrigin: func(request *http.Request) bool {
				origin := request.Header.Get("Origin")
				return origin == "" || sameOrigin(request, origin)
			},
		},
	}
	if service != nil {
		service.ClientsActive = func() bool { return server.peerCount() > 0 }
	}
	server.publicAccess = newPublicAccessService(
		service,
		func() (*relay.RouteClient, error) { return server.routeClient() },
		func() error {
			if server.RelayStart == nil {
				return nil
			}
			return server.RelayStart()
		},
	)
	return server
}

// sameOrigin allows the Web UI served from any host/IP to open the WebSocket
// (for example a phone reaching the daemon over LAN), while still rejecting
// cross-site browser connections. Loopback prefixes are kept as a compatibility
// fallback for local clients that connect through a proxy with a different Host.
func sameOrigin(request *http.Request, origin string) bool {
	if strings.HasPrefix(origin, "http://127.0.0.1") ||
		strings.HasPrefix(origin, "http://localhost") ||
		strings.HasPrefix(origin, "http://[::1]") {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return false
	}
	scheme := effectiveScheme(request)
	if parsed.Scheme != scheme {
		return false
	}
	originHost := parsed.Hostname()
	originPort := parsed.Port()
	if originPort == "" {
		originPort = defaultPort(parsed.Scheme)
	}
	requestHost, requestPort := request.Host, ""
	if host, port, err := net.SplitHostPort(request.Host); err == nil {
		requestHost, requestPort = host, port
	}
	if requestPort == "" {
		requestPort = defaultPort(scheme)
	}
	return strings.EqualFold(requestHost, originHost) && requestPort == originPort
}

// effectiveScheme returns the scheme the browser actually used, honoring TLS
// termination by the Relay or another trusted reverse proxy.
func effectiveScheme(request *http.Request) string {
	if forwarded := request.Header.Get("X-Forwarded-Proto"); forwarded != "" {
		if fields := strings.Fields(forwarded); len(fields) > 0 {
			if scheme := fields[0]; scheme == "http" || scheme == "https" {
				return scheme
			}
		}
	}
	if request.TLS != nil {
		return "https"
	}
	return "http"
}

func defaultPort(scheme string) string {
	if scheme == "https" {
		return "443"
	}
	return "80"
}

func (s *HTTPServer) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		rpcVersion := s.GhostlineRPCVersion
		storeStatus := api.HealthUnavailable
		if s.Service != nil && s.Service.Store != nil {
			storeStatus = api.HealthReady
		}
		relayHealth := api.RelayHealth{State: api.HealthUnconfigured}
		if s.RelayState != nil {
			relayHealth = s.RelayState()
		}
		ready := storeStatus == api.HealthReady &&
			(relayHealth.State == api.HealthUnconfigured ||
				relayHealth.State == api.HealthConnected ||
				relayHealth.State == api.HealthDisconnected)
		hostID := ""
		hostName := ""
		if s.Service != nil && s.Service.Store != nil {
			snap := s.Service.Store.Snapshot()
			hostID = snap.Host.ID
			hostName = snap.Host.Name
		}
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"ok":                  true,
			"ready":               ready,
			"version":             api.Version,
			"host_id":             hostID,
			"host_name":           hostName,
			"build":               s.BuildVersion,
			"revision":            s.BuildRevision,
			"dirty":               s.BuildDirty,
			"ghostlineRPCVersion": rpcVersion,
			"ghostlineTagVersion": s.GhostlineTagVersion,
			"status": api.HealthSubsystems{
				Store: storeStatus,
				Relay: relayHealth,
			},
		})
	})
	mux.HandleFunc("GET /v1/state", s.handleState)
	mux.HandleFunc("GET /v1/ws", s.handleWebSocket)
	mux.HandleFunc("GET /v1/browser/view", s.handleBrowserView)
	mux.HandleFunc("GET /v1/browser/stream", s.handleBrowserStream)
	mux.HandleFunc("GET /v1/settings", s.handleSettings)
	mux.HandleFunc("PUT /v1/settings", s.handleSettings)
	mux.HandleFunc("POST /v1/pairing/enable", s.handlePairingEnable)
	mux.HandleFunc("GET /v1/pairing/status", s.handlePairingStatus)
	mux.HandleFunc("POST /v1/pairing/disable", s.handlePairingDisable)
	mux.HandleFunc("POST /v1/pairing/request", s.handlePairingRequest)
	mux.HandleFunc("POST /v1/relay/join", s.handleRelayJoin)
	mux.HandleFunc("POST /v1/relay/pairing", s.handleRelayPairing)
	mux.HandleFunc("POST /v1/maintenance", s.handleMaintenance)
	mux.HandleFunc("POST /v1/runtime/refresh", s.handleRuntimeRefresh)
	mux.HandleFunc("GET /v1/public-access", s.handlePublicAccess)
	mux.HandleFunc("POST /v1/public-access/enable", s.handlePublicAccessEnable)
	mux.HandleFunc("POST /v1/public-access/test", s.handlePublicAccessTest)
	mux.HandleFunc("POST /v1/public-access/disable", s.handlePublicAccessDisable)
	mux.HandleFunc("POST /v1/public-access/reset", s.handlePublicAccessReset)
	mux.HandleFunc("POST /v1/public-access/restart", s.handlePublicAccessRestart)
	mux.HandleFunc("GET /", s.handleWebAsset)
	mux.HandleFunc("GET /service-worker.js", s.handleWebAsset)
	mux.HandleFunc("GET /manifest.webmanifest", s.handleWebAsset)
	mux.HandleFunc("GET /assets/", s.handleWebAsset)
	mux.HandleFunc("GET /preset-", s.handleWebAsset)
	mux.HandleFunc("GET /icon", s.handleWebAsset)
	mux.HandleFunc("GET /apple-touch-icon.png", s.handleWebAsset)
	mux.HandleFunc("GET /tls/ca.pem", s.handleCACert)
	return gzipMiddleware(mux)
}

func (s *HTTPServer) handleCACert(writer http.ResponseWriter, request *http.Request) {
	if s.CACertPath == "" {
		http.Error(writer, "not found", http.StatusNotFound)
		return
	}
	data, err := os.ReadFile(s.CACertPath)
	if err != nil {
		http.Error(writer, "not found", http.StatusNotFound)
		return
	}
	writer.Header().Set("Content-Type", "application/x-x509-ca-cert")
	writer.Header().Set("Content-Disposition", `attachment; filename="warren-ca.crt"`)
	writer.Header().Set("Cache-Control", "no-store")
	_, _ = writer.Write(data)
}

func (s *HTTPServer) handleWebAsset(writer http.ResponseWriter, request *http.Request) {
	root := os.Getenv("WARREN_WEB_ROOT")
	if root == "" {
		root = filepath.Join(filepath.Dir(os.Args[0]), "..", "Resources")
	}
	name := strings.TrimPrefix(request.URL.Path, "/")
	if name == "" {
		name = "index.html"
	}
	if name == "index.html" {
		data, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			http.Error(writer, "Warren Web unavailable", http.StatusNotFound)
			return
		}
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		writer.Header().Set("Cache-Control", "no-store")
		_, _ = writer.Write(data)
		return
	}
	clean := filepath.Clean(name)
	if clean == "." || strings.HasPrefix(clean, "..") || filepath.IsAbs(clean) {
		http.Error(writer, "not found", http.StatusNotFound)
		return
	}
	data, err := os.ReadFile(filepath.Join(root, clean))
	if err != nil {
		http.Error(writer, "not found", http.StatusNotFound)
		return
	}
	writer.Header().Set("Content-Type", webContentType(clean))
	// Assets use fixed filenames (assets/app.js, assets/app.css), so a rebuilt
	// bundle must never be masked by a browser or service-worker cache. Force
	// revalidation; the payloads are small enough that the extra request is
	// cheaper than serving a stale client that renders DENB frames as text.
	writer.Header().Set("Cache-Control", "no-cache")
	_, _ = writer.Write(data)
}

func webContentType(path string) string {
	switch filepath.Ext(path) {
	case ".css":
		return "text/css; charset=utf-8"
	case ".js":
		return "text/javascript; charset=utf-8"
	case ".json", ".webmanifest":
		return "application/json"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	default:
		return "application/octet-stream"
	}
}

func (s *HTTPServer) handleState(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(s.Service.Roster(request.Context()))
}

func (s *HTTPServer) handleWebSocket(writer http.ResponseWriter, request *http.Request) {
	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	peer := newWSPeer(s, connection)
	closeReason := "client_disconnect"
	defer func() {
		s.unregisterPeer(peer)
		peer.closeWithReason(closeReason)
	}()
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	var envelope api.Envelope
	publicRelayWebSocket := relay.IsPublicRoute(request.Context()) && request.URL.Path == "/v1/ws"
	if err := connection.ReadJSON(&envelope); err != nil || envelope.Type != "auth" {
		closeReason = "auth_rejected"
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	clientID, authenticated := s.authenticatedClient(envelope.Token)
	if !authenticated && !(publicRelayWebSocket && strings.TrimSpace(envelope.Token) == "") {
		closeReason = "auth_rejected"
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	s.registerPeer(peer)
	peer.clientID = clientID
	// A public Relay route may intentionally arrive without a bearer token.
	// That anonymous transport is never an owner session, even though its
	// client ID is empty just like the static Host token's client ID.
	peer.ownerAuthenticated = authenticated && clientID == ""
	// Protocol 4 changes terminal recovery from a replayable byte stream to an
	// atomically installable terminal state.  A missing version is therefore not
	// an older-but-compatible client: it is an unauthenticated protocol shape
	// that must be rejected before any roster or session data is exposed.
	if envelope.Version != api.Version {
		closeReason = "protocol_rejected"
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: fmt.Sprintf(
			"incompatible protocol version: client=%s server=%s", envelope.Version, api.Version,
		)})
		return
	}
	peer.terminalStateFormat = selectTerminalStateFormat(envelope.TerminalStateFormats)
	if peer.terminalStateFormat == "" {
		closeReason = "terminal_format_rejected"
		_ = peer.writeJSON(api.Response{
			Type:  "error",
			OK:    false,
			Error: "upgrade required: client does not support a compatible atomic terminal state format",
		})
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	peer.accessScopeID = s.accessScopeID(clientID)
	peer.setCapabilities(api.NegotiateCapabilities(s.Service.AgentViewCapabilities(), envelope.Capabilities))
	state, revision := s.Service.RosterVersion(request.Context())
	state = projectRosterCapabilities(state, peer.capabilitiesList())
	if err := peer.writeJSON(api.WelcomeMessage{
		Type: "welcome", Version: api.Version, Host: state.Host,
		AccessScopeID: peer.accessScopeID, Capabilities: peer.capabilitiesList(),
	}); err != nil {
		return
	}
	_ = peer.writeJSON(makeRoster(state))
	peer.startRoster(request.Context(), state, revision, supportsRosterDeltas(envelope.Capabilities))
	for {
		messageType, data, err := connection.ReadMessage()
		if err != nil {
			closeReason = "read_error"
			return
		}
		if messageType == websocket.BinaryMessage {
			if err := peer.input(request.Context(), data); err != nil {
				_ = peer.writeError("", err)
			}
			continue
		}
		var command api.Envelope
		if err := json.Unmarshal(data, &command); err != nil {
			_ = peer.writeError("", fmt.Errorf("invalid request: %w", err))
			continue
		}
		if command.Type == "ping" {
			if peer.supportsCapability(api.CapabilityAppHeartbeat) {
				if err := peer.writeJSON(map[string]any{"t": "pong", "id": command.ID}); err != nil {
					return
				}
			}
			continue
		}
		if isSlowMutation(command.Method) {
			// Worktree and process cleanup can take several seconds. Do not hold
			// the WebSocket read loop while a destructive mutation runs: clients
			// may still need to create or close sessions on the same connection.
			go func(command api.Envelope) {
				// Once accepted, deletion should finish even if the initiating
				// client disconnects. Bound runtime cleanup independently of the
				// HTTP handler lifetime so a closed socket cannot strand state.
				mutationContext, cancel := context.WithTimeout(
					context.WithoutCancel(request.Context()), slowMutationTimeout,
				)
				defer cancel()
				if err := peer.handle(mutationContext, command); err != nil {
					_ = peer.writeError(command.ID, err)
				}
			}(command)
			continue
		}
		if isBackgroundRequest(command.Method) {
			// Git inspection can invoke network-backed fetches and filesystem
			// scans. Keep those reads off the WebSocket reader so terminal
			// attach, resize, and input remain responsive on the same client.
			backgroundContext := backgroundRequestContext(request.Context(), command.Method)
			go func(command api.Envelope, ctx context.Context) {
				if err := peer.handle(ctx, command); err != nil {
					_ = peer.writeError(command.ID, err)
				}
			}(command, backgroundContext)
			continue
		}
		if key := orderedRequestKey(command); key != "" {
			requestContext := request.Context()
			submitted := s.ordered.submit(key, func() {
				if err := peer.handle(requestContext, command); err != nil {
					_ = peer.writeError(command.ID, err)
				}
			})
			if !submitted {
				_ = peer.writeError(command.ID, errTooManyQueuedRequests)
			}
			continue
		}
		handleStartedAt := time.Now()
		if err := peer.handle(request.Context(), command); err != nil {
			_ = peer.writeError(command.ID, err)
		}
		if elapsed := time.Since(handleStartedAt); elapsed >= 500*time.Millisecond {
			// Synchronous commands run on the WebSocket reader, so a slow one
			// delays every later command on the same connection (including
			// session.subscribe, which would leave the terminal black).
			peer.logInfo("slow command", "method", command.Method, "duration", elapsed)
		}
	}
}

func isSlowMutation(method string) bool {
	switch method {
	case "project.remove", "workspace.remove",
		"session.create", "session.delete",
		"public-access.enable", "public-access.test", "public-access.disable",
		"public-access.reset", "public-access.restart":
		return true
	default:
		return false
	}
}

// orderedRequestKey names the ordering domain for a request that must run off
// the WebSocket reader but stay in order relative to its siblings. An empty
// string means the request is not eligible and runs inline as before.
//
// These are the requests that made a pong miss its deadline: a turn can sit
// inside the provider for seconds, and on the reader it delays every command
// behind it on the same connection. They cannot simply be backgrounded, because
// a CLI consumes injected input in arrival order — two turns that raced would
// reach the provider reversed.
func orderedRequestKey(command api.Envelope) string {
	switch command.Method {
	case "agent.turn.start", "agent.turn.steer", "agent.turn.cancel", "agent.config.set":
		// executionId identifies one Agent stream, and a stream belongs to
		// exactly one session, so it is already a per-session domain. A request
		// without one fails validation immediately and is cheap to run inline.
		if id := stringParam(command.Params, "executionId"); id != "" {
			return "execution:" + id
		}
	case "session.focus":
		if id := stringParam(command.Params, "id"); id != "" {
			return "session:" + id
		}
		if id := strings.TrimSpace(command.Session); id != "" {
			return "session:" + id
		}
	}
	return ""
}

func isBackgroundRequest(method string) bool {
	switch method {
	case "git.panel", "git.diff", "session.subscribe", "settings.testOpenAI",
		// A roster projection can walk Agent bindings and wait on lifecycle
		// locks for seconds during startup. Every client may request one on
		// connect, so keep it off the reader: otherwise it blocks the
		// session.subscribe that follows on the same connection and leaves the
		// freshly mounted terminal black until the roster finishes.
		"roster",
		// Agent reads hit the canonical journal (and the session broadcast
		// lock). They can take seconds while the journal is cold, so they must
		// not run on the WebSocket reader where they would delay the terminal
		// attach that follows on the same connection.
		"agent.execution.get", "agent.events.history", "agent.events.subscribe",
		// Relay device listing performs a control-plane network round trip and
		// must not hold up the reader while the desktop reconnects.
		"relay.devices.list",
		// Usage stats can refresh unit prices over the network and rescan the
		// whole rollup; rebuild can scan every retained transcript. Both belong
		// off the reader so terminal input stays responsive meanwhile.
		"usage.stats", "usage.rebuild":
		return true
	default:
		return false
	}
}

// backgroundRequestContext keeps a Host-owned maintenance rebuild alive when
// the initiating WebSocket goes away. Other background reads should retain the
// connection lifetime so their result is not produced after the caller leaves.
func backgroundRequestContext(parent context.Context, method string) context.Context {
	if method == "usage.rebuild" {
		return context.WithoutCancel(parent)
	}
	return parent
}

// registerPeer tracks an authenticated WebSocket client so server-initiated
// control messages (for example a maintenance announcement) can reach every
// client, attached or not.
func (s *HTTPServer) registerPeer(peer *wsPeer) {
	s.peersMu.Lock()
	s.peers[peer] = struct{}{}
	s.peersMu.Unlock()
}

func (s *HTTPServer) unregisterPeer(peer *wsPeer) {
	s.peersMu.Lock()
	delete(s.peers, peer)
	s.peersMu.Unlock()
}

func (s *HTTPServer) handleRuntimeRefresh(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	// Manual runtime refresh from the menu bar acknowledges the request so the
	// helper can refresh the reported daemon and Ghostline versions. Existing
	// sessions are intentionally left untouched.
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(map[string]any{"refreshed": true})
}

// handleMaintenance announces an operator-initiated maintenance window to all
// connected clients. The daemon is expected to restart shortly after; clients
// use the notice to show an update state instead of treating the disconnect as
// a connection failure.
func (s *HTTPServer) handleMaintenance(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body struct {
		Message string `json:"message"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024)).Decode(&body); err != nil {
		http.Error(writer, "invalid request", http.StatusBadRequest)
		return
	}
	s.broadcastMaintenance(body.Message)
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(map[string]any{
		"announced": true,
		"peers":     s.peerCount(),
	})
}

func (s *HTTPServer) broadcastMaintenance(message string) {
	payload, _ := json.Marshal(map[string]any{
		"t":       "maintenance",
		"state":   "starting",
		"message": message,
	})
	s.peersMu.Lock()
	peers := make([]*wsPeer, 0, len(s.peers))
	for peer := range s.peers {
		peers = append(peers, peer)
	}
	s.peersMu.Unlock()
	for _, peer := range peers {
		// A full queue tears the peer down; the client reconnects once the
		// daemon returns and misses only the maintenance banner.
		_ = peer.enqueue(outboundMessage{kind: websocket.TextMessage, data: payload})
	}
}

func (s *HTTPServer) peerCount() int {
	s.peersMu.Lock()
	defer s.peersMu.Unlock()
	return len(s.peers)
}

func supportsRosterDeltas(capabilities []string) bool {
	for _, capability := range capabilities {
		if capability == "roster-delta" {
			return true
		}
	}
	return false
}

const terminalStateFormatANSI = "ghostline-vt-replay-v1"

func selectTerminalStateFormat(formats []string) string {
	for _, preferred := range []string{ghostline.AtomicStateFormat, terminalStateFormatANSI} {
		for _, format := range formats {
			if format == preferred {
				return preferred
			}
		}
	}
	return ""
}

func (s *HTTPServer) authorized(value string) bool {
	return value != "" && subtle.ConstantTimeCompare([]byte(value), []byte(s.Token)) == 1
}

// authenticatedClient accepts either the daemon's owner token or one of the
// scoped tokens issued by the temporary LAN pairing window. The empty client
// ID identifies the owner token; paired clients receive their own access
// scope and are intentionally not treated as Host administrators.
func (s *HTTPServer) authenticatedClient(value string) (clientID string, ok bool) {
	if s.authorized(value) {
		return "", true
	}
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || s.Service == nil {
		return "", false
	}
	hash := hashLANPairingToken(trimmed)
	for _, client := range s.Service.PairedClientsSnapshot() {
		if client.TokenHash == "" || subtle.ConstantTimeCompare([]byte(hash), []byte(client.TokenHash)) != 1 {
			continue
		}
		if strings.TrimSpace(client.ClientID) == "" {
			continue
		}
		return client.ClientID, true
	}
	return "", false
}

func (p *wsPeer) requireOwner() error {
	if !p.ownerAuthenticated {
		return errors.New("Host owner authentication is required")
	}
	return nil
}

func (s *HTTPServer) accessScopeID(clientID string) string {
	if strings.TrimSpace(clientID) == "" {
		if value := strings.TrimSpace(s.AccessScopeID); value != "" {
			return value
		}
		return "scope-owner"
	}
	hash := sha256.Sum256([]byte("warren-access-scope\x00" + strings.TrimSpace(clientID)))
	return "scope-" + hex.EncodeToString(hash[:8])
}
