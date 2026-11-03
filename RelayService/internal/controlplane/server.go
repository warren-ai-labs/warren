package controlplane

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
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
	// EnrollmentKeyTTL and EnrollmentKeyMaxUses are the defaults used by the
	// administrator batch key endpoint when a request omits those fields.
	EnrollmentKeyTTL     time.Duration
	EnrollmentKeyMaxUses int
	AccessTTL            time.Duration
	AllowedOrigin        string
	TunnelBaseDomain     string
	// RefreshTTL controls optional expiry. Zero means the capability remains
	// valid until its device association or Host is explicitly revoked, which
	// also means the used/revoked bookkeeping can never be pruned. Both the
	// policy and the deferred sweep are recorded in docs/backlog.md.
	RefreshTTL   time.Duration
	MaxBodyBytes int64
	// RateLimitWindow and the operation limits are fixed-window admission
	// controls. A zero operation limit selects the secure default; negative
	// values are rejected rather than silently disabling abuse protection.
	RateLimitWindow  time.Duration
	PairingRateLimit int
	ClientRateLimit  int
	PublicRateLimit  int
	UpgradeRateLimit int
	// HostPresenceWait bounds how long a client socket waits for an absent Host
	// before it is told the Host is offline. Zero selects hostPresenceWait.
	HostPresenceWait time.Duration
	// HostLossConfirmation is how long a dropped Host tunnel is given to come
	// back before the clients attached to it are told the Host is gone. Zero
	// selects hostLossConfirmation.
	HostLossConfirmation time.Duration
	// ReadDeadline bounds silence on a Host tunnel or client socket. Every
	// inbound frame refreshes it, so it is a silence budget rather than a cap on
	// connection lifetime. Zero selects relayReadDeadline.
	ReadDeadline time.Duration
	Logger       *slog.Logger
}

// clientProtocolVersion is the logical Warren control protocol carried inside
// a Relay client stream. It is independent from BRLY/2, which remains the
// transport framing between the Relay and an enrolled Host.
const clientProtocolVersion = "4.0"

// How long a client socket waits for an absent Host before it is told the Host
// is offline. Long enough to cover a wake, a daemon restart, or a Relay restart
// with the Host's own reconnect backoff; short enough that a genuinely offline
// Mac still produces an answer the user can act on. It must stay below every
// client's welcome deadline (Web 25s, native 30s) so a Host that returns inside
// this window is not cut off by the client that was waiting for it.
const hostPresenceWait = 15 * time.Second

// maxHostPresenceWait keeps a configured wait below the shortest client welcome
// deadline (Web 25s, native 30s) with room for the Host's own welcome exchange.
const maxHostPresenceWait = 20 * time.Second

// How long a refusal may spend getting its reason onto the wire. Generous
// enough for a slow mobile link, bounded so an unresponsive peer cannot hold
// the handler open.
const relayRefusalWriteBudget = 5 * time.Second

// How long a dropped Host tunnel is given to come back before its clients are
// told the Host is gone. Mirrors the clients' settle grace
// (`connectionSettleGraceMs` / `warrenConnectionSettleGrace`); see
// hostLossConfirmation for why the two values are the same.
const hostLossConfirmation = 3 * time.Second

// How long connectClient may wait for its downstream goroutine to finish
// delivering a terminal reason and closing the stream. The downstream path can
// spend the client write budget, then the tunnel writer's budget on the window
// update that follows, then the notice's own budget on the close handshake; the
// sum bounds the wait so a stuck peer cannot pin the handler.
const downstreamSettleBudget = 25 * time.Second

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
	refreshRetries  map[string]refreshRetry
	revokedFamilies map[string]bool
	pairingLimiter  *rateLimiter
	clientLimiter   *rateLimiter
	publicLimiter   *rateLimiter
	upgradeLimiter  *rateLimiter
	liveActivityMu  sync.RWMutex
	liveActivities  map[string]map[string]liveActivityRegistration
	apns            *apnsSender
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
	if config.EnrollmentKeyTTL == 0 {
		config.EnrollmentKeyTTL = defaultEnrollmentKeyTTL
	}
	if config.EnrollmentKeyTTL < 0 {
		return nil, errors.New("enrollment key TTL must be positive")
	}
	if config.EnrollmentKeyMaxUses == 0 {
		config.EnrollmentKeyMaxUses = defaultEnrollmentKeyUses
	}
	if config.EnrollmentKeyMaxUses < 0 || config.EnrollmentKeyMaxUses > maxEnrollmentKeyUses {
		return nil, fmt.Errorf("enrollment key uses must be between 1 and %d", maxEnrollmentKeyUses)
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
	if config.HostPresenceWait < 0 {
		return nil, errors.New("host presence wait must not be negative")
	}
	// A wait at or above a client's welcome deadline turns the courtesy wait into
	// the very stall it exists to prevent: the client gives up and reconnects
	// while Relay is still holding its socket.
	if config.HostPresenceWait > maxHostPresenceWait {
		return nil, fmt.Errorf("host presence wait must not exceed %s", maxHostPresenceWait)
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
		refreshRetries:  make(map[string]refreshRetry),
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
	server.mux.HandleFunc("POST /v1/admin/enrollment-keys", server.createEnrollmentKeys)
	server.mux.HandleFunc("POST /v1/hosts/claim", server.claimHost)
	server.mux.HandleFunc("GET /v1/host/connect", server.connectHost)
	server.mux.HandleFunc("POST /v1/hosts/{hostID}/pairing", server.beginPairing)
	server.mux.HandleFunc("DELETE /v1/hosts/{hostID}", server.revokeHost)
	server.mux.HandleFunc("GET /v1/hosts/{hostID}", server.getHost)
	server.mux.HandleFunc("POST /v1/pair", server.pair)
	server.mux.HandleFunc("POST /invite/{inviteID}/v1/session/exchange", server.exchangeSession)
	server.mux.HandleFunc("POST /v1/session/refresh", server.refreshSession)
	server.mux.HandleFunc("GET /v1/hosts/{hostID}/devices", server.listDevices)
	server.mux.HandleFunc("DELETE /v1/hosts/{hostID}/devices/{deviceID}", server.revokeDevice)
	server.mux.HandleFunc("POST /invite/{inviteID}/v1/session/refresh", server.refreshSession)
	server.mux.HandleFunc("POST /h/{hostID}/v1/session/refresh", server.refreshSession)
	server.mux.HandleFunc("GET /h/{hostID}/v1/relay/devices", server.listDevices)
	server.mux.HandleFunc("DELETE /h/{hostID}/v1/relay/devices/{deviceID}", server.revokeDevice)
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
