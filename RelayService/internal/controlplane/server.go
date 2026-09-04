package controlplane

import (
	"bufio"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	relayassets "github.com/abcdlsj/warren"
	"github.com/gorilla/websocket"
)

type Config struct {
	PublicURL  string
	AdminToken string
	SigningKey []byte
	// APNs provider credentials are optional. When configured, the Relay can
	// forward Host-published Live Activity snapshots to ActivityKit push
	// tokens registered by authorized clients.
	APNsKeyID      string
	APNsTeamID     string
	APNsBundleID   string
	APNsPrivateKey []byte
	APNsProduction bool
	APNsEndpoint   string
	APNsHTTPClient *http.Client
	DataURL        string
	// PairingTTL controls how long a Host pairing code remains valid. The
	// code is deliberately reusable during this window so one generated link
	// can provision more than one client.
	PairingTTL time.Duration
	// PairingTicketTTL controls how long the client-facing pairing link remains
	// valid after the code is exchanged. A ticket can be exchanged repeatedly
	// during this window; each exchange gets its own refresh-capability family.
	PairingTicketTTL time.Duration
	AccessTTL        time.Duration
	AllowedOrigin    string
	TunnelBaseDomain string
	RefreshTTL       time.Duration
	MaxBodyBytes     int64
	// RateLimitWindow and the operation limits are fixed-window admission
	// controls. A zero operation limit selects the secure default; negative
	// values are rejected rather than silently disabling abuse protection.
	RateLimitWindow  time.Duration
	PairingRateLimit int
	ClientRateLimit  int
	PublicRateLimit  int
	UpgradeRateLimit int
	Logger           *slog.Logger
}

type Server struct {
	config          Config
	basePath        string
	registry        *registry
	signer          *tokenSigner
	web             fs.FS
	upgrader        websocket.Upgrader
	mux             *http.ServeMux
	sessionMu       sync.Mutex
	refreshTokens   map[string]refreshRecord
	usedRefresh     map[string]string
	revokedFamilies map[string]bool
	pairingLimiter  *rateLimiter
	clientLimiter   *rateLimiter
	publicLimiter   *rateLimiter
	upgradeLimiter  *rateLimiter
	liveActivityMu  sync.RWMutex
	liveActivities  map[string]map[string]liveActivityRegistration
	apns            *apnsSender
}

type refreshRecord struct {
	Family     string
	HostID     string
	Generation uint64
	ClientID   string
	Expires    time.Time
}

type persistedSessions struct {
	RefreshTokens   map[string]refreshRecord `json:"refresh_tokens"`
	UsedRefresh     map[string]string        `json:"used_refresh,omitempty"`
	RevokedFamilies map[string]bool          `json:"revoked_families,omitempty"`
}

type httpHeadersMessage struct {
	Status    int         `json:"status,omitempty"`
	Method    string      `json:"method,omitempty"`
	Scheme    string      `json:"scheme,omitempty"`
	Authority string      `json:"authority,omitempty"`
	Path      string      `json:"path,omitempty"`
	BodyLimit int64       `json:"body_limit,omitempty"`
	Headers   [][2]string `json:"headers,omitempty"`
	Trailers  [][2]string `json:"trailers,omitempty"`
}

type httpErrorMessage struct {
	Code    string `json:"code"`
	Message string `json:"message,omitempty"`
}

var webStaticResources = map[string]string{
	"apple-touch-icon.png":   "image/png",
	"icon-192.png":           "image/png",
	"icon-512.png":           "image/png",
	"icon.svg":               "image/svg+xml",
	"preset-antigravity.svg": "image/svg+xml",
	"preset-claude.svg":      "image/svg+xml",
	"preset-codex-white.svg": "image/svg+xml",
	"preset-codex.svg":       "image/svg+xml",
	"preset-opencode.svg":    "image/svg+xml",
	"preset-pi.svg":          "image/svg+xml",
	"preset-qoder.svg":       "image/svg+xml",
	"preset-shell.svg":       "image/svg+xml",
	"preset-trae.svg":        "image/svg+xml",
}

func NewServer(config Config) (*Server, error) {
	if config.AdminToken == "" {
		return nil, errors.New("admin bootstrap token is required")
	}
	if strings.TrimSpace(config.AllowedOrigin) == "" {
		return nil, errors.New("allowed origin is required")
	}
	config.AllowedOrigin = strings.TrimSpace(config.AllowedOrigin)
	if config.PairingTTL == 0 {
		config.PairingTTL = 7 * 24 * time.Hour
	}
	if config.PairingTTL < 0 {
		return nil, errors.New("pairing TTL must be positive")
	}
	if config.PairingTicketTTL == 0 {
		config.PairingTicketTTL = config.PairingTTL
	}
	if config.PairingTicketTTL < 0 {
		return nil, errors.New("pairing ticket TTL must be positive")
	}
	if config.AccessTTL == 0 {
		config.AccessTTL = 15 * time.Minute
	}
	if config.AccessTTL < 0 {
		return nil, errors.New("access TTL must be positive")
	}
	if config.AccessTTL > time.Hour {
		config.AccessTTL = time.Hour
	}
	if config.RefreshTTL == 0 {
		config.RefreshTTL = 30 * 24 * time.Hour
	}
	if config.RefreshTTL < 0 {
		return nil, errors.New("refresh TTL must be positive")
	}
	if config.MaxBodyBytes == 0 {
		config.MaxBodyBytes = 64 * 1024 * 1024
	}
	if config.MaxBodyBytes < 0 {
		return nil, errors.New("maximum body size must be positive")
	}
	if config.RateLimitWindow == 0 {
		config.RateLimitWindow = time.Minute
	}
	if config.RateLimitWindow < 0 {
		return nil, errors.New("rate limit window must be positive")
	}
	if config.PairingRateLimit == 0 {
		config.PairingRateLimit = 10
	}
	if config.ClientRateLimit == 0 {
		config.ClientRateLimit = 30
	}
	if config.PublicRateLimit == 0 {
		config.PublicRateLimit = 120
	}
	if config.UpgradeRateLimit == 0 {
		config.UpgradeRateLimit = 30
	}
	if config.PairingRateLimit < 0 || config.ClientRateLimit < 0 || config.PublicRateLimit < 0 || config.UpgradeRateLimit < 0 {
		return nil, errors.New("rate limits must not be negative")
	}
	if config.TunnelBaseDomain == "" {
		config.TunnelBaseDomain = "tunnel.local"
	}
	if config.Logger == nil {
		config.Logger = slog.Default()
	}
	signer, err := newTokenSigner(config.SigningKey)
	if err != nil {
		return nil, err
	}
	web, err := fs.Sub(relayassets.Web, "Web/dist")
	if err != nil {
		return nil, err
	}
	registry, err := newRegistry(config.DataURL)
	if err != nil {
		return nil, err
	}
	server := &Server{
		config:          config,
		basePath:        relayPathPrefix(config.PublicURL),
		registry:        registry,
		signer:          signer,
		web:             web,
		upgrader:        websocket.Upgrader{EnableCompression: true, Subprotocols: []string{"brly/2"}, CheckOrigin: func(*http.Request) bool { return true }},
		mux:             http.NewServeMux(),
		refreshTokens:   make(map[string]refreshRecord),
		usedRefresh:     make(map[string]string),
		revokedFamilies: make(map[string]bool),
		pairingLimiter:  newRateLimiter(config.PairingRateLimit, config.RateLimitWindow),
		clientLimiter:   newRateLimiter(config.ClientRateLimit, config.RateLimitWindow),
		publicLimiter:   newRateLimiter(config.PublicRateLimit, config.RateLimitWindow),
		upgradeLimiter:  newRateLimiter(config.UpgradeRateLimit, config.RateLimitWindow),
		liveActivities:  make(map[string]map[string]liveActivityRegistration),
	}
	if err := server.loadSessions(); err != nil {
		return nil, err
	}
	apns, err := newAPNsSender(config)
	if err != nil {
		return nil, err
	}
	server.apns = apns
	server.routes()
	return server, nil
}

func (server *Server) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.Header().Set("Referrer-Policy", "no-referrer")
	server.mux.ServeHTTP(response, request)
}

func (server *Server) routes() {
	server.mux.HandleFunc("GET /healthz", server.health)
	server.mux.HandleFunc("POST /v1/hosts", server.provisionHost)
	server.mux.HandleFunc("POST /v1/hosts/{hostID}/enroll", server.enrollHost)
	server.mux.HandleFunc("GET /v1/host/connect", server.connectHost)
	server.mux.HandleFunc("POST /v1/hosts/{hostID}/pairing", server.beginPairing)
	server.mux.HandleFunc("DELETE /v1/hosts/{hostID}", server.revokeHost)
	server.mux.HandleFunc("GET /v1/hosts/{hostID}", server.getHost)
	server.mux.HandleFunc("POST /v1/pair", server.pair)
	server.mux.HandleFunc("POST /v1/session/exchange", server.exchangeSession)
	server.mux.HandleFunc("POST /invite/{inviteID}/v1/session/exchange", server.exchangeSession)
	server.mux.HandleFunc("POST /v1/session/refresh", server.refreshSession)
	server.mux.HandleFunc("POST /invite/{inviteID}/v1/session/refresh", server.refreshSession)
	server.mux.HandleFunc("POST /h/{hostID}/v1/session/exchange", server.exchangeSession)
	server.mux.HandleFunc("POST /h/{hostID}/v1/session/refresh", server.refreshSession)
	server.mux.HandleFunc("POST /h/{hostID}/v1/live-activities", server.registerLiveActivity)
	server.mux.HandleFunc("DELETE /h/{hostID}/v1/live-activities", server.unregisterLiveActivity)
	server.mux.HandleFunc("POST /v1/hosts/{hostID}/live-activities", server.publishLiveActivity)
	server.mux.HandleFunc("GET /v1/client/connect", server.connectClient)
	server.mux.HandleFunc("GET /h/{hostID}/v1/client/connect", server.connectClient)
	server.mux.HandleFunc("POST /v1/hosts/{hostID}/route", server.configureRoute)
	server.mux.HandleFunc("GET /v1/hosts/{hostID}/route", server.getRoute)
	server.mux.HandleFunc("DELETE /v1/hosts/{hostID}/route", server.disableRoute)
	server.mux.HandleFunc("GET /h/{hostID}/", server.webPage)
	server.mux.HandleFunc("GET /invite/{inviteID}", server.invitePage)
	server.mux.HandleFunc("GET /invite/{inviteID}/", server.invitePage)
	server.mux.HandleFunc("GET /h/{hostID}/manifest.webmanifest", server.hostManifest)
	server.mux.HandleFunc("GET /invite/{inviteID}/manifest.webmanifest", server.inviteManifest)
	server.mux.HandleFunc("GET /h/{hostID}/service-worker.js", server.hostServiceWorker)
	server.mux.HandleFunc("GET /invite/{inviteID}/service-worker.js", server.inviteServiceWorker)
	server.mux.HandleFunc("GET /h/{hostID}/assets/{name}", server.asset)
	server.mux.HandleFunc("GET /invite/{inviteID}/assets/{name}", server.asset)
	server.mux.HandleFunc("GET /manifest.webmanifest", server.webResource("manifest.webmanifest", "application/manifest+json"))
	server.mux.HandleFunc("GET /service-worker.js", server.webResource("service-worker.js", "text/javascript; charset=utf-8"))
	server.mux.HandleFunc("GET /assets/{name}", server.asset)
	for name, contentType := range webStaticResources {
		handler := server.webResource(name, contentType)
		server.mux.HandleFunc("GET /"+name, handler)
		server.mux.HandleFunc("GET /h/{hostID}/"+name, handler)
		server.mux.HandleFunc("GET /invite/{inviteID}/"+name, handler)
	}
	// Public routes are selected by exact Host/SNI and are deliberately last;
	// all control-plane patterns above retain their normal authentication
	// boundary.
	server.mux.HandleFunc("/", server.publicRoute)
}

func (server *Server) health(response http.ResponseWriter, _ *http.Request) {
	writeJSON(response, http.StatusOK, map[string]any{"ok": true})
}

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
	tunnel := newHostTunnel(connection)
	if err := server.hostHandshake(connection, hostID, credential); err != nil {
		tunnel.close()
		return
	}
	if !server.registry.connectHost(hostID, strings.TrimSpace(request.URL.Query().Get("name")), credential, tunnel) {
		tunnel.close()
		return
	}
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
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
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

func relayID(publicURL string) string {
	digest := sha256.Sum256([]byte(publicURL))
	return base64.RawURLEncoding.EncodeToString(digest[:8])
}

func relayPathPrefix(publicURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(publicURL))
	if err != nil {
		return ""
	}
	prefix := strings.TrimRight(parsed.EscapedPath(), "/")
	if prefix == "" || prefix == "." || prefix == "/" || !strings.HasPrefix(prefix, "/") {
		return ""
	}
	return prefix
}

func relayPublicOrigin(publicURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(publicURL))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return strings.TrimRight(strings.TrimSpace(publicURL), "/")
	}
	parsed.Path = ""
	parsed.RawPath = ""
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return strings.TrimRight(parsed.String(), "/")
}

func (server *Server) publicPath(value string) string {
	value = "/" + strings.TrimLeft(value, "/")
	return strings.TrimRight(server.basePath, "/") + value
}

func canonicalChallenge(challenge relayChallenge, hostID string) string {
	return strings.Join([]string{challenge.Version, challenge.RelayID, challenge.Nonce, hostID, strings.Join(challenge.Capabilities, ",")}, "|")
}

func (server *Server) provisionHost(response http.ResponseWriter, request *http.Request) {
	if !secureEqual(bearerToken(request), server.config.AdminToken) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	hostID, err := server.registry.provisionGeneratedHost(strings.TrimSpace(body.Name))
	if err != nil {
		http.Error(response, "provision failed", http.StatusInternalServerError)
		return
	}
	ticket, expires, _ := server.registry.enrollmentTicket(hostID)
	keyID, publicKey := server.signer.currentPublicKey()
	settingsURL := server.relaySettingsURL(hostID, ticket, keyID, publicKey)
	writeJSON(response, http.StatusCreated, map[string]any{
		"host_id":           hostID,
		"enrollment_ticket": ticket,
		"expires_at":        expires.UTC().Format(time.RFC3339),
		"relay_key_id":      keyID,
		"relay_public_key":  base64.RawStdEncoding.EncodeToString(publicKey),
		// The setup link contains only the one-time enrollment ticket and
		// public Relay metadata. It never carries the Host Secret.
		"settings_url": settingsURL,
	})
}

// NewSetupLink creates the initial operator setup link for a Relay. The first
// pending Host is reused across restarts; once a Host has enrolled, no second
// implicit Host is created and the empty string is returned. Additional Hosts
// are provisioned through the Relay service's administrative API.
func (server *Server) NewSetupLink(name string) (string, error) {
	hostID, ticket, _, created, err := server.registry.bootstrapHost(strings.TrimSpace(name))
	if err != nil || !created {
		return "", err
	}
	keyID, publicKey := server.signer.currentPublicKey()
	return server.relaySettingsURL(hostID, ticket, keyID, publicKey), nil
}

// relaySettingsURL builds the canonical Warren desktop setup link. The
// configured PublicURL may include a reverse-proxy path prefix; preserve that
// prefix while dropping query and fragment components so deployment metadata
// can never accidentally smuggle a secret into the link.
func (server *Server) relaySettingsURL(hostID, enrollmentTicket, keyID string, publicKey []byte) string {
	base := strings.TrimRight(relayPublicOrigin(server.config.PublicURL), "/") + strings.TrimRight(server.basePath, "/")
	values := url.Values{}
	values.Set("section", "relay")
	values.Set("relayUrl", base)
	values.Set("hostId", hostID)
	values.Set("enrollmentTicket", enrollmentTicket)
	values.Set("relayKeyId", keyID)
	values.Set("relayPublicKey", base64.RawStdEncoding.EncodeToString(publicKey))
	return (&url.URL{Scheme: "warren", Host: "settings", RawQuery: values.Encode()}).String()
}

func (server *Server) enrollHost(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	if !server.pairingLimiter.allow("enroll-ip:"+requestClientIP(request), "enroll-host:"+hostID) {
		writeRateLimit(response, server.config.RateLimitWindow)
		return
	}
	var body struct {
		EnrollmentTicket string `json:"enrollment_ticket"`
		HostSecret       string `json:"host_secret"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	secret := strings.TrimSpace(body.HostSecret)
	generation, err := server.registry.enrollment(hostID, body.EnrollmentTicket, secret)
	if err != nil {
		http.Error(response, "invalid enrollment", http.StatusUnauthorized)
		return
	}
	server.clearLiveActivityRegistrations(hostID)
	keyID, publicKey := server.signer.currentPublicKey()
	writeJSON(response, http.StatusOK, map[string]any{"host_id": hostID, "generation": generation, "enrolled": true, "relay_key_id": keyID, "relay_public_key": base64.RawStdEncoding.EncodeToString(publicKey)})
}

func (server *Server) revokeHost(response http.ResponseWriter, request *http.Request) {
	if !secureEqual(bearerToken(request), server.config.AdminToken) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	if err := server.registry.revokeHost(request.PathValue("hostID")); err != nil {
		if errors.Is(err, errHostNotFound) {
			http.Error(response, "not found", http.StatusNotFound)
		} else {
			http.Error(response, "revoke failed", http.StatusInternalServerError)
		}
		return
	}
	server.revokeRefreshFamilies(request.PathValue("hostID"))
	server.clearLiveActivityRegistrations(request.PathValue("hostID"))
	response.WriteHeader(http.StatusNoContent)
}

func (server *Server) revokeRefreshFamilies(hostID string) {
	server.sessionMu.Lock()
	defer server.sessionMu.Unlock()
	for hash, entry := range server.refreshTokens {
		if entry.HostID == hostID {
			server.revokedFamilies[entry.Family] = true
			delete(server.refreshTokens, hash)
		}
	}
}

func (server *Server) beginPairing(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	credential := bearerToken(request)
	if !secureEqual(credential, server.config.AdminToken) && !server.registry.authenticateHost(hostID, credential) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	if !server.pairingLimiter.allow("ip:"+requestClientIP(request), "host:"+hostID) {
		writeRateLimit(response, server.config.RateLimitWindow)
		return
	}
	code, err := server.registry.beginPairing(hostID, server.config.PairingTTL)
	if err != nil {
		http.Error(response, err.Error(), http.StatusConflict)
		return
	}
	writeJSON(response, http.StatusCreated, map[string]any{
		"host_id":      hostID,
		"pairing_code": code,
		"expires_in":   int(server.config.PairingTTL.Seconds()),
	})
}

func (server *Server) pair(response http.ResponseWriter, request *http.Request) {
	if !originAllowed(server.config.AllowedOrigin, request.Header.Get("Origin")) {
		http.Error(response, "origin not allowed", http.StatusForbidden)
		return
	}
	var body struct {
		HostID string `json:"host_id"`
		Code   string `json:"pairing_code"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	if !server.pairingLimiter.allow("ip:"+requestClientIP(request), "host:"+strings.TrimSpace(body.HostID)) {
		writeRateLimit(response, server.config.RateLimitWindow)
		return
	}
	hostID := strings.TrimSpace(body.HostID)
	generation, pairingVersion, err := server.registry.consumePairing(hostID, strings.TrimSpace(body.Code))
	if err != nil {
		http.Error(response, err.Error(), http.StatusUnauthorized)
		return
	}
	token, err := server.signer.issue(hostID, "control", generation, server.config.AccessTTL)
	if err != nil {
		http.Error(response, "token issue failed", http.StatusInternalServerError)
		return
	}
	invite, inviteExpires, err := server.registry.createPairingInvite(hostID, generation, pairingVersion, server.config.PairingTicketTTL)
	if err != nil {
		http.Error(response, "invite issue failed", http.StatusInternalServerError)
		return
	}
	base := relayPublicOrigin(server.config.PublicURL)
	inviteURL := base + server.publicPath("/invite/"+url.PathEscape(invite)+"/")
	result := map[string]any{
		"host_id":      hostID,
		"access_token": token,
		// The browser and native clients receive an opaque invite URL. It does
		// not disclose the Host ID; Relay resolves the invite server-side during
		// the exchange and returns the scoped Host identity in the response.
		"pairing_ticket": invite,
		"invite_id":      invite,
		"web_url":        inviteURL,
		"pairing_url":    inviteURL,
		// Keep expires_in compatible with older clients that interpreted it as
		// the access capability lifetime. New clients should use the explicit
		// pairing_expires_in field for the QR/link lifetime.
		"expires_in":         int(server.config.AccessTTL.Seconds()),
		"pairing_expires_in": int(server.config.PairingTicketTTL.Seconds()),
		"pairing_expires_at": inviteExpires.UTC().Format(time.RFC3339),
	}
	if route, ok := server.registry.route(hostID); ok {
		if tunnelToken, tunnelErr := server.signer.issueCapability(tokenClaims{HostID: hostID, Scope: []string{"tunnel"}, Generation: generation, RouteID: route.ID, Expiry: time.Now().Add(server.config.AccessTTL).Unix()}); tunnelErr == nil {
			result["tunnel_token"] = tunnelToken
		}
	}
	writeJSON(response, http.StatusCreated, result)
}

func (server *Server) exchangeSession(response http.ResponseWriter, request *http.Request) {
	if !originAllowed(server.config.AllowedOrigin, request.Header.Get("Origin")) {
		http.Error(response, "origin not allowed", http.StatusForbidden)
		return
	}
	var body struct {
		PairingTicket string `json:"pairing_ticket"`
		InviteID      string `json:"invite_id"`
		ClientID      string `json:"client_id"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	ticket := strings.TrimSpace(body.PairingTicket)
	if inviteID := strings.TrimSpace(request.PathValue("inviteID")); inviteID != "" {
		if ticket != "" && ticket != inviteID {
			http.Error(response, "invalid pairing ticket", http.StatusUnauthorized)
			return
		}
		ticket = inviteID
	}
	if inviteID := strings.TrimSpace(body.InviteID); inviteID != "" {
		if ticket != "" && ticket != inviteID {
			http.Error(response, "invalid pairing ticket", http.StatusUnauthorized)
			return
		}
		ticket = inviteID
	}
	entry, ok := server.registry.pairingInvite(ticket)
	if !ok || ticket == "" {
		http.Error(response, "invalid pairing ticket", http.StatusUnauthorized)
		return
	}
	if hostID := strings.TrimSpace(request.PathValue("hostID")); hostID != "" && hostID != entry.HostID {
		http.Error(response, "invalid pairing ticket", http.StatusUnauthorized)
		return
	}
	if generation, exists := server.registry.generation(entry.HostID); !exists || generation != entry.Generation {
		http.Error(response, "invalid pairing ticket", http.StatusUnauthorized)
		return
	}
	if pairingVersion, exists := server.registry.pairingVersion(entry.HostID); !exists || pairingVersion != entry.PairingVersion {
		http.Error(response, "invalid pairing ticket", http.StatusUnauthorized)
		return
	}
	access, err := server.signer.issueCapability(tokenClaims{HostID: entry.HostID, Scope: []string{"control"}, Generation: entry.Generation, ClientID: strings.TrimSpace(body.ClientID), Expiry: time.Now().Add(server.config.AccessTTL).Unix()})
	if err != nil {
		http.Error(response, "token issue failed", http.StatusInternalServerError)
		return
	}
	refresh, err := server.newRefresh(entry.HostID, entry.Generation, strings.TrimSpace(body.ClientID))
	if err != nil {
		http.Error(response, "refresh issue failed", http.StatusInternalServerError)
		return
	}
	server.setRefreshCookie(response, request, entry.HostID, refresh)
	result := map[string]any{"host_id": entry.HostID, "access_token": access, "expires_in": int(server.config.AccessTTL.Seconds()), "refresh_token": refresh}
	if route, ok := server.registry.route(entry.HostID); ok {
		if tunnelToken, tunnelErr := server.signer.issueCapability(tokenClaims{HostID: entry.HostID, Scope: []string{"tunnel"}, Generation: entry.Generation, RouteID: route.ID, Expiry: time.Now().Add(server.config.AccessTTL).Unix()}); tunnelErr == nil {
			result["tunnel_token"] = tunnelToken
			server.setTunnelCookie(response, request, tunnelToken)
		}
	}
	writeJSON(response, http.StatusOK, result)
}

func (server *Server) refreshSession(response http.ResponseWriter, request *http.Request) {
	if !originAllowed(server.config.AllowedOrigin, request.Header.Get("Origin")) {
		http.Error(response, "origin not allowed", http.StatusForbidden)
		return
	}
	var body struct {
		RefreshToken string `json:"refresh_token"`
	}
	if request.Body != nil {
		decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&body); err != nil && err != io.EOF {
			http.Error(response, "invalid request", http.StatusBadRequest)
			return
		}
	}
	refresh := strings.TrimSpace(body.RefreshToken)
	if refresh == "" {
		if cookie, err := request.Cookie("warren_refresh"); err == nil {
			refresh = cookie.Value
		}
	}
	hash := hashRefresh(refresh)
	server.sessionMu.Lock()
	entry, ok := server.refreshTokens[hash]
	if ok {
		delete(server.refreshTokens, hash)
		server.usedRefresh[hash] = entry.Family
	}
	if !ok {
		if family, reused := server.usedRefresh[hash]; reused {
			server.revokedFamilies[family] = true
		}
	}
	familyRevoked := ok && server.revokedFamilies[entry.Family]
	if ok && server.revokedFamilies[entry.Family] {
		familyRevoked = true
	}
	server.sessionMu.Unlock()
	_ = server.persistSessions()
	if !ok || familyRevoked || refresh == "" || time.Now().After(entry.Expires) {
		http.Error(response, "invalid refresh capability", http.StatusUnauthorized)
		return
	}
	if generation, exists := server.registry.generation(entry.HostID); !exists || generation != entry.Generation {
		http.Error(response, "invalid refresh capability", http.StatusUnauthorized)
		return
	}
	access, err := server.signer.issueCapability(tokenClaims{HostID: entry.HostID, Scope: []string{"control"}, Generation: entry.Generation, ClientID: entry.ClientID, Expiry: time.Now().Add(server.config.AccessTTL).Unix()})
	if err != nil {
		http.Error(response, "token issue failed", http.StatusInternalServerError)
		return
	}
	next, err := server.newRefreshInFamily(entry.HostID, entry.Generation, entry.Family, entry.ClientID)
	if err != nil {
		http.Error(response, "refresh issue failed", http.StatusInternalServerError)
		return
	}
	server.setRefreshCookie(response, request, entry.HostID, next)
	result := map[string]any{"host_id": entry.HostID, "access_token": access, "expires_in": int(server.config.AccessTTL.Seconds()), "refresh_token": next}
	if route, ok := server.registry.route(entry.HostID); ok {
		if tunnelToken, tunnelErr := server.signer.issueCapability(tokenClaims{HostID: entry.HostID, Scope: []string{"tunnel"}, Generation: entry.Generation, RouteID: route.ID, Expiry: time.Now().Add(server.config.AccessTTL).Unix()}); tunnelErr == nil {
			result["tunnel_token"] = tunnelToken
			server.setTunnelCookie(response, request, tunnelToken)
		}
	}
	writeJSON(response, http.StatusOK, result)
}

func hashRefresh(value string) string {
	digest := sha256.Sum256([]byte(value))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}

func (server *Server) newRefresh(hostID string, generation uint64, clientID ...string) (string, error) {
	family, err := randomToken(16)
	if err != nil {
		return "", err
	}
	id := ""
	if len(clientID) > 0 {
		id = clientID[0]
	}
	return server.newRefreshInFamily(hostID, generation, family, id)
}

func (server *Server) newRefreshInFamily(hostID string, generation uint64, family string, clientID ...string) (string, error) {
	value, err := randomToken(32)
	if err != nil {
		return "", err
	}
	server.sessionMu.Lock()
	id := ""
	if len(clientID) > 0 {
		id = clientID[0]
	}
	server.refreshTokens[hashRefresh(value)] = refreshRecord{Family: family, HostID: hostID, Generation: generation, ClientID: id, Expires: time.Now().Add(server.config.RefreshTTL)}
	server.sessionMu.Unlock()
	_ = server.persistSessions()
	return value, nil
}

func (server *Server) sessionsPath() string {
	if strings.TrimSpace(server.config.DataURL) == "" {
		return ""
	}
	return server.config.DataURL + ".sessions"
}

func (server *Server) loadSessions() error {
	p := server.sessionsPath()
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var state persistedSessions
	if err := json.Unmarshal(b, &state); err != nil {
		return err
	}
	server.refreshTokens = state.RefreshTokens
	if server.refreshTokens == nil {
		server.refreshTokens = make(map[string]refreshRecord)
	}
	server.usedRefresh = state.UsedRefresh
	if server.usedRefresh == nil {
		server.usedRefresh = make(map[string]string)
	}
	server.revokedFamilies = state.RevokedFamilies
	if server.revokedFamilies == nil {
		server.revokedFamilies = make(map[string]bool)
	}
	return nil
}

func (server *Server) persistSessions() error {
	p := server.sessionsPath()
	if p == "" {
		return nil
	}
	server.sessionMu.Lock()
	state := persistedSessions{RefreshTokens: server.refreshTokens, UsedRefresh: server.usedRefresh, RevokedFamilies: server.revokedFamilies}
	data, err := json.Marshal(state)
	server.sessionMu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func (server *Server) setRefreshCookie(response http.ResponseWriter, request *http.Request, hostID, value string) {
	secure := request.TLS != nil || strings.HasPrefix(strings.ToLower(server.config.PublicURL), "https://")
	cookiePath := "/"
	// The host-scoped Web alias keeps the refresh cookie within one host
	// namespace. Native clients use the unscoped endpoint and must be able to
	// rotate the cookie at /v1/session/refresh, so do not issue a cookie whose
	// Path excludes that endpoint.
	if validHostID(hostID) && strings.TrimSpace(request.PathValue("hostID")) != "" {
		cookiePath = server.publicPath("/h/" + url.PathEscape(hostID) + "/")
	}
	http.SetCookie(response, &http.Cookie{Name: "warren_refresh", Value: value, Path: cookiePath, HttpOnly: true, Secure: secure, SameSite: http.SameSiteStrictMode, MaxAge: int(server.config.RefreshTTL.Seconds())})
}

func (server *Server) setTunnelCookie(response http.ResponseWriter, request *http.Request, value string) {
	secure := request.TLS != nil || strings.HasPrefix(strings.ToLower(server.config.PublicURL), "https://")
	http.SetCookie(response, &http.Cookie{
		Name:     "warren_tunnel",
		Value:    value,
		Path:     "/",
		HttpOnly: true,
		Secure:   secure,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(server.config.AccessTTL.Seconds()),
	})
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
	_ = client.SetReadDeadline(time.Now().Add(10 * time.Second))
	messageType, authPayload, err := client.ReadMessage()
	var auth struct {
		Type        string `json:"t"`
		AccessToken string `json:"access_token"`
		ClientID    string `json:"client_id"`
		Version     string `json:"version"`
	}
	if err != nil || messageType != websocket.TextMessage || json.Unmarshal(authPayload, &auth) != nil || auth.Type != "auth" || auth.Version != "2.0" || strings.TrimSpace(auth.AccessToken) == "" {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "unauthorized"})
		return
	}
	claims, err := server.signer.verify(auth.AccessToken, requestedHostID, "control")
	if err != nil {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "unauthorized"})
		return
	}
	hostID := claims.HostID
	if requestedHostID != "" && requestedHostID != hostID {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "unauthorized"})
		return
	}
	if claims.ClientID != "" && (auth.ClientID == "" || auth.ClientID != claims.ClientID) {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "unauthorized"})
		return
	}
	if !server.clientLimiter.allow("host:" + hostID) {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "rate limit exceeded"})
		return
	}
	tunnel := server.registry.authorizedTunnel(hostID, claims.Generation)
	if tunnel == nil {
		_ = client.WriteJSON(map[string]string{"t": "error", "message": "host offline"})
		return
	}
	_ = client.SetReadDeadline(time.Now().Add(75 * time.Second))
	client.SetPongHandler(func(string) error {
		return client.SetReadDeadline(time.Now().Add(75 * time.Second))
	})
	connectionID, route, err := tunnel.openStream(&streamOpen{Class: "control", Version: "2.0", HostID: hostID, ClientID: claims.ClientID, Token: auth.AccessToken})
	if err != nil {
		return
	}
	if err := tunnel.send(relayFrame{Kind: frameText, ConnectionID: connectionID, Payload: authPayload}); err != nil {
		tunnel.removeClient(connectionID)
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
	go func() {
		for {
			messageType, data, err := client.ReadMessage()
			if err != nil {
				clientErrors <- err
				return
			}
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
			if client.WriteMessage(messageType, frame.Payload) != nil {
				return
			}
			if frame.Kind == frameText || frame.Kind == frameBinary {
				if tunnel.send(relayFrame{Kind: frameWindowUpdate, ConnectionID: connectionID, Payload: encodeWindowCredit(uint64(len(frame.Payload)))}) != nil {
					return
				}
			}
		case <-route.done:
			return
		case frame := <-clientFrames:
			if tunnel.sendStream(connectionID, frame) != nil {
				return
			}
		case <-clientErrors:
			return
		}
	}
}

func originAllowed(configured, origin string) bool {
	if strings.TrimSpace(origin) == "" {
		// Native clients and Host connectors do not send a browser Origin.
		return true
	}
	for _, allowed := range strings.Split(configured, ",") {
		if strings.TrimSpace(allowed) != "" && secureEqual(strings.TrimSpace(allowed), origin) {
			return true
		}
	}
	return false
}

func (server *Server) configureRoute(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	credential := bearerToken(request)
	if !secureEqual(credential, server.config.AdminToken) && !server.registry.authenticateHost(hostID, credential) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body struct {
		PublicHostname   string   `json:"public_hostname"`
		PathPrefix       string   `json:"path_prefix"`
		AuthMode         string   `json:"auth_mode"`
		Enabled          *bool    `json:"enabled"`
		AllowedMethods   []string `json:"allowed_methods"`
		AllowedPaths     []string `json:"allowed_paths"`
		AllowCredentials *bool    `json:"allow_credentials"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(response, request.Body, 64*1024)).Decode(&body); err != nil && err != io.EOF {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	generation, ok := server.registry.generation(hostID)
	if !ok {
		http.Error(response, "not found", http.StatusNotFound)
		return
	}
	route, exists := server.registry.route(hostID)
	if !exists {
		routeID, err := randomToken(16)
		if err != nil {
			http.Error(response, "route issue failed", http.StatusInternalServerError)
			return
		}
		// Raw URL base64 may contain '_' or a leading/trailing '-' which are not
		// valid in a DNS label. Keep route IDs URL-safe while making the
		// generated default hostname valid without requiring a caller-provided
		// public hostname.
		routeID = "r" + strings.NewReplacer("_", "-", "=", "").Replace(routeID) + "r"
		hostname := strings.ToLower(strings.TrimSpace(body.PublicHostname))
		pathPrefix := "/"
		if hostname == "" {
			hostname, pathPrefix = server.defaultRouteAddress(routeID)
		} else if hostnameUsesPathFallback(hostname) {
			// An IP/port Relay has no wildcard DNS to allocate a hostname for
			// every Host. Keep the route on the configured authority and use an
			// opaque path segment as the route discriminator instead.
			pathPrefix = "/t/" + routeID
		}
		route = routeRecord{ID: routeID, PublicHostname: hostname, HostID: hostID, Generation: generation, PathPrefix: pathPrefix, AuthMode: "owner", Enabled: true}
		exists = true
	}
	if body.PublicHostname != "" {
		route.PublicHostname = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(body.PublicHostname), "."))
		if body.PathPrefix == "" && hostnameUsesPathFallback(route.PublicHostname) && route.PathPrefix == "/" {
			route.PathPrefix = "/t/" + route.ID
		}
	}
	if !validRouteHostname(route.PublicHostname) {
		http.Error(response, "invalid public_hostname", http.StatusBadRequest)
		return
	}
	if body.PathPrefix != "" {
		if !strings.HasPrefix(body.PathPrefix, "/") {
			http.Error(response, "invalid path_prefix", http.StatusBadRequest)
			return
		}
		route.PathPrefix = path.Clean(body.PathPrefix)
	}
	if body.AuthMode != "" {
		if body.AuthMode != "public" && body.AuthMode != "owner" {
			http.Error(response, "invalid auth_mode", http.StatusBadRequest)
			return
		}
		route.AuthMode = body.AuthMode
	}
	if body.Enabled != nil {
		route.Enabled = *body.Enabled
	}
	if body.AllowedMethods != nil {
		route.AllowedMethods = normalizePolicyValues(body.AllowedMethods)
	}
	if body.AllowedPaths != nil {
		route.AllowedPaths = normalizePolicyValues(body.AllowedPaths)
	}
	if body.AllowCredentials != nil {
		route.AllowCredentials = *body.AllowCredentials
	}
	route.Generation = generation
	if err := server.registry.setRoute(hostID, &route); err != nil {
		if errors.Is(err, errRouteConflict) {
			http.Error(response, "route hostname already owned", http.StatusConflict)
		} else {
			http.Error(response, "route update failed", http.StatusInternalServerError)
		}
		return
	}
	writeJSON(response, http.StatusOK, route)
}

// defaultRouteAddress returns the route authority and path for a newly
// created route. Domain deployments keep the historical per-route hostname;
// IP/localhost deployments use the Relay authority and an opaque path so a
// single listener can host multiple routes without wildcard DNS.
func (server *Server) defaultRouteAddress(routeID string) (string, string) {
	parsed, err := url.Parse(strings.TrimSpace(server.config.PublicURL))
	if err == nil && parsed.Hostname() != "" {
		hostname := normalizeRouteHostname(parsed.Hostname())
		if hostnameUsesPathFallback(hostname) {
			return hostname, "/t/" + routeID
		}
	}
	base := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(server.config.TunnelBaseDomain)), ".")
	if base == "" {
		base = "tunnel.local"
	}
	return routeID + "." + base, "/"
}

func hostnameUsesPathFallback(hostname string) bool {
	hostname = normalizeRouteHostname(hostname)
	return net.ParseIP(hostname) != nil || strings.EqualFold(hostname, "localhost")
}

func validRouteHostname(hostname string) bool {
	hostname = normalizeRouteHostname(hostname)
	if hostname == "" || len(hostname) > 253 || strings.ContainsAny(hostname, "/@") {
		return false
	}
	if net.ParseIP(hostname) != nil {
		return true
	}
	if strings.Contains(hostname, ":") || strings.HasPrefix(hostname, "[") || strings.HasSuffix(hostname, "]") {
		return false
	}
	for _, label := range strings.Split(strings.ToLower(hostname), ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return false
		}
		for _, character := range label {
			if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' {
				continue
			}
			return false
		}
	}
	return true
}

func normalizePolicyValues(values []string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			result = append(result, value)
		}
	}
	return result
}

func (server *Server) getRoute(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	credential := bearerToken(request)
	if !secureEqual(credential, server.config.AdminToken) && !server.registry.authenticateHost(hostID, credential) && !server.authorizeAccess(credential, hostID) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	route, ok := server.registry.route(hostID)
	if !ok {
		http.Error(response, "not found", http.StatusNotFound)
		return
	}
	writeJSON(response, http.StatusOK, route)
}

func (server *Server) disableRoute(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	credential := bearerToken(request)
	if !secureEqual(credential, server.config.AdminToken) && !server.registry.authenticateHost(hostID, credential) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	route, ok := server.registry.route(hostID)
	if !ok {
		http.Error(response, "not found", http.StatusNotFound)
		return
	}
	route.Enabled = false
	if err := server.registry.setRoute(hostID, &route); err != nil {
		http.Error(response, "route update failed", http.StatusInternalServerError)
		return
	}
	response.WriteHeader(http.StatusNoContent)
}

func (server *Server) publicRoute(response http.ResponseWriter, request *http.Request) {
	// Public application routes never become a backdoor into Relay or the
	// daemon control API, even when the route policy is public.
	if request.URL.Path == "/v1" || strings.HasPrefix(request.URL.Path, "/v1/") ||
		request.URL.Path == "/h" || strings.HasPrefix(request.URL.Path, "/h/") {
		http.NotFound(response, request)
		return
	}
	hostname := requestHostname(request.Host)
	route, ok := server.registry.findRoute(hostname, request.URL.Path)
	if !ok {
		http.NotFound(response, request)
		return
	}
	forwardRequest := request
	if strippedPath, stripped := stripRoutePath(route, request.URL.Path); stripped {
		clone := request.Clone(request.Context())
		clone.URL.Path = strippedPath
		clone.URL.RawPath = ""
		forwardRequest = clone
	}
	if !routeAllows(route, forwardRequest) {
		http.Error(response, "route policy denied", http.StatusForbidden)
		return
	}
	upgrade := isUpgradeRequest(request)
	limiter := server.publicLimiter
	if upgrade {
		limiter = server.upgradeLimiter
	}
	if !limiter.allow("ip:"+requestClientIP(request), "host:"+route.HostID) {
		writeRateLimit(response, server.config.RateLimitWindow)
		return
	}
	if err := validateRequestHeaders(request, upgrade); err != nil {
		http.Error(response, err.Error(), http.StatusBadRequest)
		return
	}
	if route.AuthMode == "owner" {
		token := bearerToken(request)
		if token == "" {
			if cookie, cookieErr := request.Cookie("warren_tunnel"); cookieErr == nil {
				token = cookie.Value
			}
		}
		claims, err := server.verifyScopedAccess(token, route.HostID, "tunnel", route.ID)
		if err != nil || claims.RouteID != route.ID || claims.Generation != route.Generation {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
	}
	if upgrade {
		server.forwardUpgrade(response, forwardRequest, route)
		return
	}
	server.forwardHTTP(response, forwardRequest, route)
}

func requestHostname(raw string) string {
	raw = strings.TrimSpace(raw)
	if host, _, err := net.SplitHostPort(raw); err == nil {
		return normalizeRouteHostname(host)
	}
	return normalizeRouteHostname(raw)
}

func stripRoutePath(route routeRecord, requestPath string) (string, bool) {
	prefix := path.Clean(strings.TrimSpace(route.PathPrefix))
	if prefix == "." || prefix == "/" || !routeUsesPathFallback(route) {
		return requestPath, false
	}
	if requestPath == prefix {
		return "/", true
	}
	if strings.HasPrefix(requestPath, prefix+"/") {
		trimmed := strings.TrimPrefix(requestPath, prefix)
		if trimmed == "" {
			trimmed = "/"
		}
		return trimmed, true
	}
	return requestPath, false
}

func routeUsesPathFallback(route routeRecord) bool {
	prefix := path.Clean(strings.TrimSpace(route.PathPrefix))
	expected := path.Clean("/t/" + strings.TrimSpace(route.ID))
	return route.ID != "" && prefix == expected
}

func routeAllows(route routeRecord, request *http.Request) bool {
	if len(route.AllowedMethods) > 0 {
		allowed := false
		for _, method := range route.AllowedMethods {
			if strings.EqualFold(method, request.Method) {
				allowed = true
				break
			}
		}
		if !allowed {
			return false
		}
	}
	if len(route.AllowedPaths) > 0 {
		allowed := false
		for _, prefix := range route.AllowedPaths {
			if routePathMatches(prefix, request.URL.Path) {
				allowed = true
				break
			}
		}
		if !allowed {
			return false
		}
	}
	return true
}

func isUpgradeRequest(request *http.Request) bool {
	return strings.EqualFold(request.Method, http.MethodGet) &&
		headerTokenContains(request.Header.Values("Connection"), "upgrade") &&
		strings.EqualFold(request.Header.Get("Upgrade"), "websocket")
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

func validateRequestHeaders(request *http.Request, upgrade bool) error {
	total := 0
	for name, values := range request.Header {
		if !validHeaderName(name) || len(name) > 8*1024 {
			return errors.New("header name too large")
		}
		for _, value := range values {
			if len(value) > 8*1024 || strings.ContainsAny(value, "\r\n\x00") {
				return errors.New("header value too large")
			}
			total += len(name) + len(value)
		}
	}
	if total > 64*1024 {
		return errors.New("header block too large")
	}
	if len(request.Header.Values("Transfer-Encoding")) > 0 {
		return errors.New("transfer-encoding is not allowed")
	}
	contentLengths := request.Header.Values("Content-Length")
	if len(contentLengths) > 1 {
		return errors.New("duplicate content-length headers")
	}
	connectionUpgrade := headerTokenContains(request.Header.Values("Connection"), "upgrade")
	upgradeHeader := strings.TrimSpace(request.Header.Get("Upgrade"))
	if connectionUpgrade != upgrade || (upgradeHeader != "" && !strings.EqualFold(upgradeHeader, "websocket")) {
		return errors.New("invalid upgrade headers")
	}
	if upgrade {
		if !strings.EqualFold(request.Header.Get("Sec-WebSocket-Version"), "13") {
			return errors.New("unsupported websocket version")
		}
		if !strings.EqualFold(request.Method, http.MethodGet) {
			return errors.New("websocket upgrade requires GET")
		}
		keys := request.Header.Values("Sec-WebSocket-Key")
		if len(keys) != 1 || !validWebSocketKey(keys[0]) {
			return errors.New("invalid websocket key")
		}
		// The first release forwards raw post-101 bytes and deliberately does
		// not negotiate per-message compression at the public edge.
		if strings.TrimSpace(request.Header.Get("Sec-WebSocket-Extensions")) != "" {
			return errors.New("websocket extensions are not supported")
		}
	}
	return nil
}

func validWebSocketKey(value string) bool {
	value = strings.TrimSpace(value)
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(value)
	}
	return err == nil && len(decoded) == 16
}

func validWebSocketAccept(key, accept string) bool {
	key = strings.TrimSpace(key)
	accept = strings.TrimSpace(accept)
	if !validWebSocketKey(key) || accept == "" {
		return false
	}
	digest := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	expected := base64.StdEncoding.EncodeToString(digest[:])
	return subtle.ConstantTimeCompare([]byte(expected), []byte(accept)) == 1
}

func filterHeaders(header http.Header, includeUpgrade bool) [][2]string {
	hop := map[string]bool{"connection": true, "keep-alive": true, "proxy-authenticate": true, "proxy-authorization": true, "te": true, "trailer": true, "transfer-encoding": true}
	if !includeUpgrade {
		hop["upgrade"] = true
	} else {
		// A WebSocket handshake is the one case where Connection and Upgrade
		// are end-to-end material: the in-process Host handler must see both
		// headers for net/http's upgrader to accept the request. The public
		// route validates the tokens before this function is called, so this
		// preserves only a bounded, syntactically valid handshake header.
		delete(hop, "connection")
	}
	result := make([][2]string, 0, len(header))
	for key, values := range header {
		lower := strings.ToLower(strings.TrimSpace(key))
		if hop[lower] || strings.HasPrefix(lower, "x-forwarded-") || strings.HasPrefix(lower, "x-warren-") || lower == "host" || lower == "content-length" {
			continue
		}
		for _, value := range values {
			if len(lower) > 8*1024 || len(value) > 8*1024 {
				continue
			}
			result = append(result, [2]string{lower, value})
		}
	}
	return result
}

func (server *Server) openHTTPStream(request *http.Request, route routeRecord, upgrade bool) (connectionID, *clientRoute, *hostTunnel, error) {
	tunnel := server.registry.authorizedTunnel(route.HostID, route.Generation)
	if tunnel == nil {
		return connectionID{}, nil, nil, errors.New("host offline")
	}
	requestID := strings.TrimSpace(request.Header.Get("X-Request-ID"))
	if requestID == "" || len(requestID) > 256 {
		requestID, _ = randomToken(16)
	}
	open := &streamOpen{Class: "http", Version: "2.0", RequestID: requestID, DeadlineMS: 60_000, RouteID: route.ID, HostID: route.HostID}
	if upgrade {
		open.Class = "upgrade"
	}
	capability, issueErr := server.signer.issueCapability(tokenClaims{HostID: route.HostID, Scope: []string{"tunnel"}, Generation: route.Generation, RouteID: route.ID, Expiry: time.Now().Add(time.Minute).Unix()})
	if issueErr != nil {
		return connectionID{}, nil, nil, errors.New("unable to issue route capability")
	}
	open.Token = capability
	id, stream, err := tunnel.openStream(open)
	if err != nil {
		return connectionID{}, nil, nil, err
	}
	filteredHeaders := filterHeaders(request.Header, upgrade)
	// Relay admission credentials are never application credentials by
	// default. This applies to owner routes as well as public routes: without
	// an explicit policy opt-in, do not forward the tunnel capability, refresh
	// cookie, or a caller's Authorization header to the Host handler.
	if !route.AllowCredentials {
		kept := filteredHeaders[:0]
		for _, header := range filteredHeaders {
			if header[0] != "authorization" && header[0] != "cookie" {
				kept = append(kept, header)
			}
		}
		filteredHeaders = kept
	}
	headers, _ := json.Marshal(httpHeadersMessage{Method: request.Method, Scheme: effectiveRequestScheme(request), Authority: request.Host, Path: request.URL.RequestURI(), BodyLimit: server.config.MaxBodyBytes, Headers: filteredHeaders})
	if err := tunnel.send(relayFrame{Kind: frameHTTPHeaders, ConnectionID: id, Payload: headers}); err != nil {
		tunnel.removeClient(id)
		return connectionID{}, nil, nil, err
	}
	return id, stream, tunnel, nil
}

func effectiveRequestScheme(request *http.Request) string {
	if request.TLS != nil || strings.EqualFold(request.Header.Get("X-Forwarded-Proto"), "https") {
		return "https"
	}
	return "http"
}

func (server *Server) forwardHTTP(response http.ResponseWriter, request *http.Request, route routeRecord) {
	if request.Body == nil {
		request.Body = http.NoBody
	}
	if request.Body != nil {
		request.Body = http.MaxBytesReader(response, request.Body, server.config.MaxBodyBytes)
	}
	id, stream, tunnel, err := server.openHTTPStream(request, route, false)
	if err != nil {
		if strings.Contains(err.Error(), "BRLY/2") {
			http.Error(response, "host requires BRLY/2", http.StatusUpgradeRequired)
			return
		}
		response.Header().Set("Retry-After", "5")
		http.Error(response, "host offline", http.StatusServiceUnavailable)
		return
	}
	defer func() { tunnel.removeClient(id); _ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: id}) }()
	buffer := make([]byte, 64*1024)
	for {
		count, readErr := request.Body.Read(buffer)
		if count > 0 {
			if err := tunnel.sendStreamContext(request.Context().Done(), id, relayFrame{Kind: frameData, ConnectionID: id, Payload: append([]byte(nil), buffer[:count]...)}); err != nil {
				_ = tunnel.send(relayFrame{Kind: frameError, ConnectionID: id, Payload: mustJSON(httpErrorMessage{Code: "backpressure", Message: "request stream window exhausted"})})
				http.Error(response, "request stream backpressure", http.StatusTooManyRequests)
				return
			}
		}
		if readErr == io.EOF {
			if err := tunnel.send(relayFrame{Kind: frameEnd, ConnectionID: id}); err != nil {
				http.Error(response, "host unavailable", http.StatusServiceUnavailable)
				return
			}
			break
		}
		if readErr != nil {
			code := http.StatusBadRequest
			message := "unable to read request body"
			if errors.As(readErr, new(*http.MaxBytesError)) {
				code = http.StatusRequestEntityTooLarge
				message = "request body exceeds limit"
			}
			_ = tunnel.send(relayFrame{Kind: frameError, ConnectionID: id, Payload: mustJSON(httpErrorMessage{Code: "request_body", Message: message})})
			http.Error(response, message, code)
			return
		}
	}
	headerDeadline := time.NewTimer(10 * time.Second)
	defer headerDeadline.Stop()
	idleDeadline := time.NewTimer(60 * time.Second)
	defer idleDeadline.Stop()
	headersSent := false
	for {
		var timeout <-chan time.Time
		if headersSent {
			timeout = idleDeadline.C
		} else {
			timeout = headerDeadline.C
		}
		select {
		case frame := <-stream.frames:
			switch frame.Kind {
			case frameHTTPHeaders:
				if headersSent {
					_ = tunnel.send(relayFrame{Kind: frameError, ConnectionID: id, Payload: mustJSON(httpErrorMessage{Code: "duplicate_headers"})})
					return
				}
				var message httpHeadersMessage
				if json.Unmarshal(frame.Payload, &message) != nil {
					http.Error(response, "invalid host response", http.StatusBadGateway)
					return
				}
				if err := validateHeaderPairs(message.Headers); err != nil {
					http.Error(response, "invalid host response headers", http.StatusBadGateway)
					return
				}
				status := message.Status
				if status == 0 {
					status = http.StatusOK
				}
				if status < 100 || status > 999 {
					http.Error(response, "invalid host response status", http.StatusBadGateway)
					return
				}
				for _, header := range message.Headers {
					if strings.EqualFold(header[0], "trailer") {
						response.Header().Add("Trailer", header[1])
					}
				}
				for _, header := range filterResponseHeaders(message.Headers) {
					response.Header().Add(header[0], header[1])
				}
				response.WriteHeader(status)
				headersSent = true
				if !idleDeadline.Stop() {
					select {
					case <-idleDeadline.C:
					default:
					}
				}
				idleDeadline.Reset(60 * time.Second)
			case frameData:
				if !headersSent {
					http.Error(response, "host sent body before response headers", http.StatusBadGateway)
					return
				}
				if _, err := response.Write(frame.Payload); err != nil {
					return
				}
				if err := tunnel.send(relayFrame{Kind: frameWindowUpdate, ConnectionID: id, Payload: encodeWindowCredit(uint64(len(frame.Payload)))}); err != nil {
					return
				}
				if !idleDeadline.Stop() {
					select {
					case <-idleDeadline.C:
					default:
					}
				}
				idleDeadline.Reset(60 * time.Second)
			case frameEnd:
				if !headersSent {
					http.Error(response, "host ended before response headers", http.StatusBadGateway)
					return
				}
				var message httpHeadersMessage
				if len(frame.Payload) > 0 && json.Unmarshal(frame.Payload, &message) == nil {
					for _, header := range filterResponseHeaders(message.Trailers) {
						response.Header().Add(header[0], header[1])
					}
				}
				return
			case frameClose:
				if !headersSent {
					http.Error(response, "host closed before response headers", http.StatusBadGateway)
				}
				return
			case frameError:
				if !headersSent {
					status, message := relayErrorStatus(frame.Payload)
					http.Error(response, message, status)
				}
				return
			}
		case <-stream.done:
			if !headersSent {
				http.Error(response, "host closed before response headers", http.StatusBadGateway)
			}
			return
		case <-timeout:
			if headersSent {
				http.Error(response, "host response timeout", http.StatusGatewayTimeout)
			} else {
				http.Error(response, "host response headers timeout", http.StatusGatewayTimeout)
			}
			return
		}
	}
}

func relayErrorStatus(payload []byte) (int, string) {
	var message httpErrorMessage
	if json.Unmarshal(payload, &message) == nil {
		switch message.Code {
		case "request_body", "body_limit":
			if message.Message == "" {
				message.Message = "request body exceeds limit"
			}
			return http.StatusRequestEntityTooLarge, message.Message
		case "rate_limit", "backpressure":
			if message.Message == "" {
				message.Message = "stream rate limit exceeded"
			}
			return http.StatusTooManyRequests, message.Message
		case "timeout":
			if message.Message == "" {
				message.Message = "host stream timed out"
			}
			return http.StatusGatewayTimeout, message.Message
		}
		if message.Message != "" {
			return http.StatusBadGateway, message.Message
		}
	}
	return http.StatusBadGateway, "host stream failed"
}

func (server *Server) forwardUpgrade(response http.ResponseWriter, request *http.Request, route routeRecord) {
	id, stream, tunnel, err := server.openHTTPStream(request, route, true)
	if err != nil {
		if strings.Contains(err.Error(), "BRLY/2") {
			http.Error(response, "host requires BRLY/2", http.StatusUpgradeRequired)
			return
		}
		response.Header().Set("Retry-After", "5")
		http.Error(response, "host offline", http.StatusServiceUnavailable)
		return
	}
	cleanup := func() {
		tunnel.removeClient(id)
		_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: id})
	}
	readDeadline := time.NewTimer(10 * time.Second)
	defer readDeadline.Stop()
	var first relayFrame
	select {
	case first = <-stream.frames:
	case <-stream.done:
		http.Error(response, "host closed", http.StatusBadGateway)
		cleanup()
		return
	case <-readDeadline.C:
		http.Error(response, "host upgrade timeout", http.StatusGatewayTimeout)
		cleanup()
		return
	}
	if first.Kind != frameHTTPHeaders {
		http.Error(response, "host rejected upgrade", http.StatusBadGateway)
		cleanup()
		return
	}
	var headers httpHeadersMessage
	if json.Unmarshal(first.Payload, &headers) != nil || headers.Status != http.StatusSwitchingProtocols {
		status := headers.Status
		if status == 0 {
			status = http.StatusBadGateway
		}
		http.Error(response, http.StatusText(status), status)
		cleanup()
		return
	}
	if err := validateHeaderPairs(headers.Headers); err != nil {
		http.Error(response, "invalid host upgrade headers", http.StatusBadGateway)
		cleanup()
		return
	}
	for _, header := range filterResponseHeaders(headers.Headers) {
		response.Header().Add(header[0], header[1])
	}
	for _, header := range headers.Headers {
		if strings.EqualFold(header[0], "sec-websocket-protocol") && header[1] != "" {
			response.Header().Set("Sec-WebSocket-Protocol", header[1])
		}
	}
	if accept := strings.TrimSpace(headerValue(headers.Headers, "Sec-WebSocket-Accept")); accept == "" {
		http.Error(response, "host did not complete websocket handshake", http.StatusBadGateway)
		cleanup()
		return
	}
	if !validWebSocketAccept(request.Header.Get("Sec-WebSocket-Key"), headerValue(headers.Headers, "Sec-WebSocket-Accept")) {
		http.Error(response, "host returned an invalid websocket handshake", http.StatusBadGateway)
		cleanup()
		return
	}
	if protocol := strings.TrimSpace(headerValue(headers.Headers, "Sec-WebSocket-Protocol")); protocol != "" && !offeredSubprotocol(request, protocol) {
		http.Error(response, "host selected an unrequested websocket subprotocol", http.StatusBadGateway)
		cleanup()
		return
	}
	if hijacker, ok := response.(http.Hijacker); ok {
		connection, buffered, hijackErr := hijacker.Hijack()
		if hijackErr != nil {
			http.Error(response, "websocket upgrade unavailable", http.StatusBadGateway)
			cleanup()
			return
		}
		if err := writeRawUpgradeResponse(buffered, headers.Headers); err != nil {
			_ = connection.Close()
			cleanup()
			return
		}
		server.proxyRawUpgrade(connection, buffered, id, stream, tunnel)
		return
	}
	// A real HTTP/1.1 server response is hijackable. Falling back to a second
	// Gorilla WebSocket handshake would manufacture message boundaries and
	// violate BRLY/2's raw post-101 byte contract, so fail closed for adapters
	// that cannot expose the underlying connection.
	http.Error(response, "websocket upgrade unavailable", http.StatusBadGateway)
	cleanup()
}

// proxyRawUpgrade forwards the bytes after an HTTP/1.1 101 response without
// parsing or manufacturing WebSocket message boundaries. This is important
// for extensions and clients that use fragmented frames: BRLY/2 DATA is the
// only framing Relay is allowed to add.
func (server *Server) proxyRawUpgrade(connection net.Conn, buffered *bufio.ReadWriter, id connectionID, stream *clientRoute, tunnel *hostTunnel) {
	defer func() {
		_ = connection.Close()
		tunnel.removeClient(id)
		_ = tunnel.send(relayFrame{Kind: frameClose, ConnectionID: id})
	}()
	_ = connection.SetDeadline(time.Now().Add(60 * time.Second))
	clientEOF := make(chan struct{})
	clientErrors := make(chan error, 1)
	go func() {
		defer close(clientEOF)
		buffer := make([]byte, 64*1024)
		for {
			count, err := buffered.Read(buffer)
			if count > 0 {
				_ = connection.SetDeadline(time.Now().Add(60 * time.Second))
				if sendErr := tunnel.sendStream(id, relayFrame{Kind: frameData, ConnectionID: id, Payload: append([]byte(nil), buffer[:count]...)}); sendErr != nil {
					clientErrors <- sendErr
					return
				}
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					_ = tunnel.send(relayFrame{Kind: frameEnd, ConnectionID: id})
					return
				}
				clientErrors <- err
				return
			}
		}
	}()
	clientInputDone := (<-chan struct{})(clientEOF)
	hostOutputDone := false
	for {
		select {
		case frame := <-stream.frames:
			if frame.Kind == frameClose || frame.Kind == frameError {
				return
			}
			switch frame.Kind {
			case frameData, frameText, frameBinary:
				if _, err := buffered.Write(frame.Payload); err != nil || buffered.Flush() != nil {
					return
				}
				_ = connection.SetDeadline(time.Now().Add(60 * time.Second))
				if tunnel.send(relayFrame{Kind: frameWindowUpdate, ConnectionID: id, Payload: encodeWindowCredit(uint64(len(frame.Payload)))}) != nil {
					return
				}
			case frameEnd:
				halfCloseWrite(connection)
				hostOutputDone = true
			}
		case <-stream.done:
			return
		case <-clientInputDone:
			clientInputDone = nil
			if hostOutputDone {
				return
			}
		case <-clientErrors:
			return
		}
	}
}

func writeRawUpgradeResponse(buffered *bufio.ReadWriter, headers [][2]string) error {
	if _, err := buffered.WriteString("HTTP/1.1 101 Switching Protocols\r\n"); err != nil {
		return err
	}
	seenConnection, seenUpgrade := false, false
	for _, header := range filterResponseHeaders(headers) {
		name := strings.TrimSpace(header[0])
		value := strings.TrimSpace(header[1])
		if strings.EqualFold(name, "connection") {
			seenConnection = true
			continue
		}
		if strings.EqualFold(name, "upgrade") {
			seenUpgrade = true
			continue
		}
		if _, err := fmt.Fprintf(buffered, "%s: %s\r\n", name, value); err != nil {
			return err
		}
	}
	if !seenConnection {
		if _, err := buffered.WriteString("Connection: Upgrade\r\n"); err != nil {
			return err
		}
	}
	if !seenUpgrade {
		if _, err := buffered.WriteString("Upgrade: websocket\r\n"); err != nil {
			return err
		}
	}
	if _, err := buffered.WriteString("\r\n"); err != nil {
		return err
	}
	return buffered.Flush()
}

func halfCloseWrite(connection net.Conn) {
	if value, ok := connection.(interface{ CloseWrite() error }); ok {
		_ = value.CloseWrite()
	}
}

func offeredSubprotocol(request *http.Request, selected string) bool {
	for _, value := range request.Header.Values("Sec-WebSocket-Protocol") {
		for _, offered := range strings.Split(value, ",") {
			if strings.TrimSpace(offered) == selected {
				return true
			}
		}
	}
	return false
}

func mustJSON(value any) []byte { data, _ := json.Marshal(value); return data }

func filterResponseHeaders(headers [][2]string) [][2]string {
	hop := map[string]bool{"connection": true, "keep-alive": true, "proxy-authenticate": true, "proxy-authorization": true, "te": true, "trailer": true, "transfer-encoding": true, "upgrade": true, "content-length": true}
	result := make([][2]string, 0, len(headers))
	for _, header := range headers {
		name := strings.ToLower(strings.TrimSpace(header[0]))
		if name == "" || hop[name] || name == "sec-websocket-extensions" || strings.HasPrefix(name, "x-forwarded-") || strings.HasPrefix(name, "x-warren-") {
			continue
		}
		if len(name) > 8*1024 || len(header[1]) > 8*1024 {
			continue
		}
		result = append(result, [2]string{name, header[1]})
	}
	return result
}

func headerValue(headers [][2]string, wanted string) string {
	for _, header := range headers {
		if strings.EqualFold(strings.TrimSpace(header[0]), wanted) {
			return strings.TrimSpace(header[1])
		}
	}
	return ""
}

func validateHeaderPairs(headers [][2]string) error {
	total := 0
	seen := make(map[string]struct{}, len(headers))
	for _, header := range headers {
		name := strings.ToLower(strings.TrimSpace(header[0]))
		value := header[1]
		if !validHeaderName(name) || len(name) > 8*1024 || len(value) > 8*1024 || strings.ContainsAny(value, "\r\n\x00") {
			return errors.New("invalid header size")
		}
		total += len(name) + len(value)
		if total > 64*1024 {
			return errors.New("header block too large")
		}
		if name == "content-length" || name == "transfer-encoding" {
			if _, exists := seen[name]; exists {
				return errors.New("duplicate framing headers")
			}
			seen[name] = struct{}{}
		}
	}
	return nil
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

func (server *Server) authorizeAccess(token, hostID string) bool {
	claims, err := server.verifyAccess(token, hostID)
	if err != nil {
		return false
	}
	generation, ok := server.registry.generation(hostID)
	return ok && claims.Generation == generation
}

func (server *Server) verifyAccess(token, hostID string) (tokenClaims, error) {
	return server.signer.verify(token, hostID, "control")
}

func (server *Server) verifyScopedAccess(token, hostID, scope, routeID string) (tokenClaims, error) {
	claims, err := server.signer.verify(token, hostID, scope)
	if err != nil {
		return tokenClaims{}, err
	}
	if routeID != "" && claims.RouteID != routeID {
		return tokenClaims{}, errors.New("invalid route capability")
	}
	generation, ok := server.registry.generation(claims.HostID)
	if !ok || generation != claims.Generation {
		return tokenClaims{}, errors.New("stale capability")
	}
	return claims, nil
}

func (server *Server) webPage(response http.ResponseWriter, request *http.Request) {
	data, err := fs.ReadFile(server.web, "index.html")
	if err != nil {
		http.Error(response, "web unavailable", http.StatusInternalServerError)
		return
	}
	hostID, _ := json.Marshal(request.PathValue("hostID"))
	prefix := server.publicPath("/h/" + url.PathEscape(request.PathValue("hostID")))
	page := strings.Replace(string(data), "content=\"__WARREN_RELAY_HOST_ID__\"", fmt.Sprintf("content=%s", string(hostID)), 1)
	page = scopeWebPage(page, prefix)
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = response.Write([]byte(page))
}

// invitePage serves the same Web client from an opaque invite scope. The
// invite ID is injected into a dedicated meta tag; the client exchanges it
// over the matching scoped endpoint and learns the Host ID only in memory.
func (server *Server) invitePage(response http.ResponseWriter, request *http.Request) {
	inviteID := strings.TrimSpace(request.PathValue("inviteID"))
	if inviteID == "" {
		http.NotFound(response, request)
		return
	}
	data, err := fs.ReadFile(server.web, "index.html")
	if err != nil {
		http.Error(response, "web unavailable", http.StatusInternalServerError)
		return
	}
	encodedID, _ := json.Marshal(inviteID)
	prefix := server.publicPath("/invite/" + url.PathEscape(inviteID))
	page := strings.Replace(string(data), "content=\"__WARREN_RELAY_INVITE_ID__\"", fmt.Sprintf("content=%s", string(encodedID)), 1)
	page = scopeWebPage(page, prefix)
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = response.Write([]byte(page))
}

func scopeWebPage(page, prefix string) string {
	for _, attribute := range []string{"href", "src", "srcset"} {
		for _, assetPrefix := range []string{"/assets/", "./assets/"} {
			page = strings.ReplaceAll(page, attribute+"=\""+assetPrefix, attribute+"=\""+prefix+"/assets/")
		}
	}
	resources := []string{"manifest.webmanifest"}
	for resource := range webStaticResources {
		resources = append(resources, resource)
	}
	for _, resource := range resources {
		for _, attribute := range []string{"href", "src", "srcset"} {
			for _, resourcePrefix := range []string{"/", "./"} {
				page = strings.ReplaceAll(page, attribute+"=\""+resourcePrefix+resource+"\"", attribute+"=\""+prefix+"/"+resource+"\"")
			}
		}
	}
	return page
}

func (server *Server) hostManifest(response http.ResponseWriter, request *http.Request) {
	server.scopedManifest(response, request, "/h/"+url.PathEscape(request.PathValue("hostID")))
}

func (server *Server) inviteManifest(response http.ResponseWriter, request *http.Request) {
	server.scopedManifest(response, request, "/invite/"+url.PathEscape(request.PathValue("inviteID")))
}

func (server *Server) scopedManifest(response http.ResponseWriter, request *http.Request, scope string) {
	data, err := fs.ReadFile(server.web, "manifest.webmanifest")
	if err != nil {
		http.NotFound(response, request)
		return
	}
	var manifest map[string]any
	if json.Unmarshal(data, &manifest) != nil {
		http.Error(response, "invalid manifest", http.StatusInternalServerError)
		return
	}
	prefix := server.publicPath(scope)
	manifest["start_url"] = prefix + "/"
	manifest["scope"] = prefix + "/"
	manifest["icons"] = []map[string]any{{"src": prefix + "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any maskable"}}
	writeJSON(response, http.StatusOK, manifest)
}

func (server *Server) hostServiceWorker(response http.ResponseWriter, request *http.Request) {
	host := url.PathEscape(request.PathValue("hostID"))
	server.scopedServiceWorker(response, request, "/h/"+host, host)
}

func (server *Server) inviteServiceWorker(response http.ResponseWriter, request *http.Request) {
	invite := url.PathEscape(request.PathValue("inviteID"))
	server.scopedServiceWorker(response, request, "/invite/"+invite, invite)
}

func (server *Server) scopedServiceWorker(response http.ResponseWriter, request *http.Request, scope, cacheID string) {
	prefix := server.publicPath(scope)
	shell := []string{prefix + "/", prefix + "/manifest.webmanifest", prefix + "/assets/app.js", prefix + "/assets/app.css"}
	for name := range webStaticResources {
		shell = append(shell, prefix+"/"+name)
	}
	encodedShell, _ := json.Marshal(shell)
	script := fmt.Sprintf(`const CACHE="warren-relay-%s-v1";
const SHELL=%s;
self.addEventListener("install",e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)));self.skipWaiting()});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x.startsWith("warren-relay-")&&x!==CACHE).map(x=>caches.delete(x)))));self.clients.claim()});
self.addEventListener("fetch",e=>{const p=new URL(e.request.url).pathname;if(e.request.method!=="GET"||p.includes("/v1/client/connect"))return;e.respondWith(fetch(e.request).catch(()=>caches.match(e.request)))})`, cacheID, encodedShell)
	response.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	response.Header().Set("Service-Worker-Allowed", prefix+"/")
	response.Header().Set("Cache-Control", "no-cache")
	_, _ = response.Write([]byte(script))
}

func (server *Server) webResource(name, contentType string) http.HandlerFunc {
	return func(response http.ResponseWriter, _ *http.Request) {
		data, err := fs.ReadFile(server.web, name)
		if err != nil {
			http.NotFound(response, nil)
			return
		}
		response.Header().Set("Content-Type", contentType)
		response.Header().Set("Cache-Control", "no-cache")
		_, _ = response.Write(data)
	}
}

func (server *Server) asset(response http.ResponseWriter, request *http.Request) {
	server.serveAsset(response, request.PathValue("name"))
}

func (server *Server) serveAsset(response http.ResponseWriter, name string) {
	if strings.Contains(name, "/") || strings.Contains(name, "..") {
		http.NotFound(response, nil)
		return
	}
	data, err := fs.ReadFile(server.web, "assets/"+name)
	if err != nil {
		http.NotFound(response, nil)
		return
	}
	contentType := mime.TypeByExtension(path.Ext(name))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	response.Header().Set("Content-Type", contentType)
	response.Header().Set("Cache-Control", "no-cache")
	_, _ = response.Write(data)
}

func bearerToken(request *http.Request) string {
	return strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")
}

func secureEqual(left, right string) bool {
	return len(left) == len(right) && subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
