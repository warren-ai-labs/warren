package server

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
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
	// GhostlineVersion is the legacy health field and aliases the RPC version.
	GhostlineVersion string
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
	// routeMu serializes route configuration persistence with lifecycle calls.
	routeMu sync.Mutex
}

type rosterMessage struct {
	Type  string    `json:"t"`
	State api.State `json:"state"`
}

type relayControlPeer struct {
	peer          *wsPeer
	open          relay.StreamOpen
	stateMu       sync.Mutex
	authenticated bool
	ctx           context.Context
}

func NewHTTPServer(service *Service, token string, logger *slog.Logger) *HTTPServer {
	server := &HTTPServer{
		Service:       service,
		Token:         token,
		AccessScopeID: "scope-owner",
		Logger:        logger,
		peers:         make(map[*wsPeer]struct{}),
		relayPeers:    make(map[relay.ConnectionID]*relayControlPeer),
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
		if rpcVersion == "" {
			rpcVersion = s.GhostlineVersion
		}
		skippedSessions := 0
		migrationPhase := ""
		if s.Service != nil && s.Service.Store != nil {
			if migration := s.Service.Store.Snapshot().GhostlineMigration; migration != nil {
				skippedSessions = len(migration.SkippedSessions)
				migrationPhase = migration.Phase
			}
		}
		storeStatus := api.HealthUnavailable
		if s.Service != nil && s.Service.Store != nil {
			storeStatus = api.HealthReady
		}
		migrationsStatus := api.HealthCleared
		if migrationPhase != "" && migrationPhase != api.GhostlineMigrationRetired {
			migrationsStatus = api.HealthPending
		}
		relayHealth := api.RelayHealth{State: api.HealthUnconfigured}
		if s.RelayState != nil {
			relayHealth = s.RelayState()
		}
		ready := storeStatus == api.HealthReady &&
			migrationsStatus == api.HealthCleared &&
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
			"ok":                       true,
			"ready":                    ready,
			"version":                  api.Version,
			"host_id":                  hostID,
			"host_name":                hostName,
			"build":                    s.BuildVersion,
			"revision":                 s.BuildRevision,
			"dirty":                    s.BuildDirty,
			"ghostlineVersion":         rpcVersion,
			"ghostlineRPCVersion":      rpcVersion,
			"ghostlineTagVersion":      s.GhostlineTagVersion,
			"ghostlineSkippedSessions": skippedSessions,
			"status": api.HealthSubsystems{
				Store:                    storeStatus,
				Migrations:               migrationsStatus,
				GhostlineSkippedSessions: skippedSessions,
				Relay:                    relayHealth,
			},
		})
	})
	mux.HandleFunc("GET /v1/state", s.handleState)
	mux.HandleFunc("GET /v1/ws", s.handleWebSocket)
	mux.HandleFunc("GET /v1/settings", s.handleSettings)
	mux.HandleFunc("PUT /v1/settings", s.handleSettings)
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

var gzipWriterPool = sync.Pool{
	New: func() any {
		w, _ := gzip.NewWriterLevel(io.Discard, gzip.DefaultCompression)
		return w
	},
}

func isUncompressibleType(ct string) bool {
	if ct == "" {
		return false
	}
	ct = strings.ToLower(ct)
	return strings.HasPrefix(ct, "image/png") ||
		strings.HasPrefix(ct, "image/jpeg") ||
		strings.HasPrefix(ct, "image/webp") ||
		strings.HasPrefix(ct, "image/gif") ||
		strings.HasPrefix(ct, "application/zip") ||
		strings.HasPrefix(ct, "application/gzip") ||
		strings.HasPrefix(ct, "application/x-gzip")
}

type gzipResponseWriter struct {
	http.ResponseWriter
	writer       *gzip.Writer
	wroteHeader  bool
	compressible bool
}

func (g *gzipResponseWriter) WriteHeader(code int) {
	if g.wroteHeader {
		return
	}
	g.wroteHeader = true
	if code == http.StatusNoContent || code == http.StatusNotModified {
		g.compressible = false
		g.ResponseWriter.WriteHeader(code)
		return
	}
	ct := g.Header().Get("Content-Type")
	if g.Header().Get("Content-Encoding") != "" || isUncompressibleType(ct) {
		g.compressible = false
		g.ResponseWriter.WriteHeader(code)
		return
	}
	g.compressible = true
	g.Header().Set("Content-Encoding", "gzip")
	g.Header().Del("Content-Length")
	g.ResponseWriter.WriteHeader(code)
}

func (g *gzipResponseWriter) Write(b []byte) (int, error) {
	if !g.wroteHeader {
		if g.Header().Get("Content-Type") == "" {
			g.Header().Set("Content-Type", http.DetectContentType(b))
		}
		g.WriteHeader(http.StatusOK)
	}
	if g.compressible {
		if g.writer == nil {
			gz := gzipWriterPool.Get().(*gzip.Writer)
			gz.Reset(g.ResponseWriter)
			g.writer = gz
		}
		return g.writer.Write(b)
	}
	return g.ResponseWriter.Write(b)
}

func (g *gzipResponseWriter) Close() error {
	if g.writer != nil {
		err := g.writer.Close()
		gzipWriterPool.Put(g.writer)
		g.writer = nil
		return err
	}
	return nil
}

func (g *gzipResponseWriter) Flush() {
	if g.writer != nil {
		_ = g.writer.Flush()
	}
	if flusher, ok := g.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (g *gzipResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hijacker, ok := g.ResponseWriter.(http.Hijacker); ok {
		return hijacker.Hijack()
	}
	return nil, nil, http.ErrNotSupported
}

func gzipMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") ||
			strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
			strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Add("Vary", "Accept-Encoding")
		gzw := &gzipResponseWriter{ResponseWriter: w}
		defer gzw.Close()
		next.ServeHTTP(gzw, r)
	})
}

// handleRelayJoin asks the daemon-owned Relay supervisor to claim a Host
// identity using a short-lived enrollment key. The daemon token authenticates
// this local API call; the supervisor sends it only to the configured Relay
// origin over the validated transport.
func (s *HTTPServer) handleRelayJoin(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.RelayEnroll == nil {
		http.Error(writer, "Relay enrollment is unavailable", http.StatusServiceUnavailable)
		return
	}
	var body struct {
		RelayURL      string `json:"relayUrl"`
		EnrollmentKey string `json:"enrollmentKey"`
		HostName      string `json:"hostName"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		http.Error(writer, "invalid request", http.StatusBadRequest)
		return
	}
	relayURL := strings.TrimSpace(body.RelayURL)
	enrollmentKey := strings.TrimSpace(body.EnrollmentKey)
	if relayURL == "" || enrollmentKey == "" {
		http.Error(writer, "invalid request", http.StatusBadRequest)
		return
	}
	if err := s.RelayEnroll(request.Context(), relayURL, enrollmentKey, strings.TrimSpace(body.HostName)); err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "relay url") {
			http.Error(writer, err.Error(), http.StatusBadRequest)
		} else {
			http.Error(writer, "Relay enrollment failed", http.StatusBadGateway)
		}
		return
	}
	value := s.Service.RelaySettingsSnapshot()
	if err := s.syncRelayLifecycle(); err != nil {
		http.Error(writer, "Relay connector could not start", http.StatusBadGateway)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(writer).Encode(map[string]any{
		"enrolled":     true,
		"relay":        value,
		"relay_key_id": value.RelayKeyID,
	})
}

// handleRelayPairing is the local, token-protected entry point used by
// automation and older clients. Desktop normally reaches the same operation
// through the authenticated WebSocket RPC below.
func (s *HTTPServer) handleRelayPairing(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.RelayPairing == nil {
		http.Error(writer, "Relay pairing is unavailable", http.StatusServiceUnavailable)
		return
	}
	value, err := s.RelayPairing(request.Context())
	if err != nil {
		http.Error(writer, "Relay pairing failed", http.StatusBadGateway)
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(writer).Encode(value)
}

func normalizeRelayEnrollmentURL(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" || parsed.RawQuery != "" || parsed.Opaque != "" {
		return "", errors.New("invalid Relay URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", errors.New("Relay URL must use http or https")
	}
	if strings.ContainsAny(parsed.Host, "\r\n\x00") || strings.HasPrefix(parsed.Path, "//") || strings.ContainsAny(parsed.Path, "\r\n\x00") {
		return "", errors.New("invalid Relay URL")
	}
	for _, segment := range strings.Split(parsed.Path, "/") {
		if segment == "." || segment == ".." {
			return "", errors.New("Relay URL path traversal is not allowed")
		}
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	parsed.RawPath = ""
	return strings.TrimRight(parsed.String(), "/"), nil
}

func decodeRelayPublicKey(value string) ([]byte, error) {
	data, err := base64.RawStdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil {
		data, err = base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	}
	if err != nil || len(data) != 32 {
		return nil, errors.New("invalid Relay public key")
	}
	return data, nil
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

// handleSettings reads or updates headless daemon settings. Runtime selection
// is a headless-side decision: the default engine only affects sessions
// created afterwards; existing sessions keep their own runtime.
func (s *HTTPServer) handleSettings(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	switch request.Method {
	case http.MethodGet:
		_ = json.NewEncoder(writer).Encode(s.settingsProjection())
	case http.MethodPut:
		var body struct {
			DefaultRuntime     string                         `json:"defaultRuntime"`
			RuntimeEnv         map[string]string              `json:"runtimeEnv"`
			AutoOpenShell      *bool                          `json:"autoOpenShell"`
			AutoStartAI        *bool                          `json:"autoStartAI"`
			OpenAIBaseURL      *string                        `json:"openaiBaseURL"`
			OpenAIModel        *string                        `json:"openaiModel"`
			OpenAIKey          *string                        `json:"openaiKey"`
			OpenAITitleEnabled *bool                          `json:"openaiTitleEnabled"`
			Relay              *settings.RelaySettings        `json:"relay"`
			PublicTunnel       *settings.PublicTunnelSettings `json:"publicTunnel"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024)).Decode(&body); err != nil {
			http.Error(writer, "invalid settings", http.StatusBadRequest)
			return
		}
		current := s.Service.SettingsSnapshot()
		runtimeEnv := body.RuntimeEnv
		if runtimeEnv == nil {
			runtimeEnv = current.RuntimeEnv
		}
		if err := s.Service.UpdateSettings(body.DefaultRuntime, runtimeEnv); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		if body.AutoOpenShell != nil {
			if err := s.Service.SetAutoOpenShell(*body.AutoOpenShell); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
		}
		if body.AutoStartAI != nil {
			if err := s.Service.SetAutoStartAI(*body.AutoStartAI); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
		}
		if body.OpenAIBaseURL != nil {
			s.Service.Settings.OpenAIBaseURL = strings.TrimSpace(*body.OpenAIBaseURL)
		}
		if body.OpenAIModel != nil {
			s.Service.Settings.OpenAIModel = strings.TrimSpace(*body.OpenAIModel)
		}
		if body.OpenAIKey != nil {
			s.Service.Settings.OpenAIKey = strings.TrimSpace(*body.OpenAIKey)
		}
		if body.OpenAITitleEnabled != nil {
			s.Service.Settings.OpenAITitleEnabled = *body.OpenAITitleEnabled
		}
		if body.OpenAIBaseURL != nil || body.OpenAIModel != nil || body.OpenAIKey != nil || body.OpenAITitleEnabled != nil {
			if s.Service.SettingsPath != "" {
				if err := settings.Save(s.Service.SettingsPath, s.Service.Settings); err != nil {
					http.Error(writer, err.Error(), http.StatusBadRequest)
					return
				}
			}
		}
		if body.Relay != nil {
			if err := s.Service.UpdateRelaySettings(*body.Relay); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
		}
		if body.PublicTunnel != nil {
			if err := s.Service.UpdatePublicTunnelSettings(*body.PublicTunnel); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
		}
		if err := s.syncRelayLifecycle(); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(writer).Encode(s.settingsProjection())
	default:
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *HTTPServer) syncRelayLifecycle() error {
	if s.Service == nil {
		return nil
	}
	value := s.Service.SettingsSnapshot()
	enabled := value.Relay.Enabled || value.PublicTunnel.Enabled
	if enabled {
		if s.RelayStart != nil {
			return s.RelayStart()
		}
		return nil
	}
	if s.RelayStop != nil {
		s.RelayStop()
	}
	return nil
}

// resetRelayEnrollment tears down the local Relay lifecycle and clears the
// Host's enrollment metadata. A configured public route is disabled first when
// the Relay is reachable; the Host record itself is deliberately retained and
// can only be revoked with an explicit Relay administrator operation.
func (s *HTTPServer) resetRelayEnrollment(ctx context.Context) error {
	s.routeMu.Lock()
	defer s.routeMu.Unlock()

	if client, err := s.routeClient(); err == nil {
		if disableErr := client.Disable(ctx); disableErr != nil && !errors.Is(disableErr, relay.ErrRouteNotFound) {
			return disableErr
		}
	}
	if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{}); err != nil {
		return err
	}
	if s.RelayStop != nil {
		s.RelayStop()
	}
	if s.RelayReset != nil {
		if err := s.RelayReset(); err != nil {
			return err
		}
	}
	return s.Service.UpdateRelaySettings(settings.RelaySettings{})
}

func (s *HTTPServer) settingsProjection() map[string]any {
	value := s.Service.SettingsSnapshot()
	return map[string]any{
		"defaultRuntime":     value.DefaultRuntime,
		"runtimeEnv":         value.RuntimeEnv,
		"autoOpenShell":      value.AutoOpenShell,
		"autoStartAI":        value.AutoStartAI,
		"openaiBaseURL":      value.OpenAIBaseURL,
		"openaiModel":        value.OpenAIModel,
		"openaiTitleEnabled": value.OpenAITitleEnabled,
		"relay":              value.Relay,
		"publicTunnel":       value.PublicTunnel,
	}
}

func (s *HTTPServer) handlePublicAccess(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) handlePublicAccessEnable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body api.PublicAccessEnableRequest
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		s.writePublicAccessError(writer, http.StatusBadRequest, errors.New("invalid public access request"))
		return
	}
	s.routeMu.Lock()
	defer s.routeMu.Unlock()
	client, err := s.routeClient()
	if err != nil {
		s.writePublicAccessError(writer, http.StatusServiceUnavailable, err)
		return
	}
	if s.RelayStart != nil {
		if err := s.RelayStart(); err != nil {
			s.writePublicAccessError(writer, http.StatusBadGateway, err)
			return
		}
	}
	current := s.Service.PublicTunnelSettingsSnapshot()
	route := relay.Route{
		ID:             current.RouteID,
		PublicHostname: current.PublicHostname,
		PathPrefix:     current.PathPrefix,
		AuthMode:       "public",
		Enabled:        true,
	}
	if body.PublicHostname != nil {
		route.PublicHostname = strings.TrimSpace(*body.PublicHostname)
	}
	if body.PathPrefix != nil {
		route.PathPrefix = strings.TrimSpace(*body.PathPrefix)
	}
	configured, err := client.Configure(request.Context(), route)
	if err != nil {
		s.writePublicAccessError(writer, http.StatusBadGateway, err)
		return
	}
	if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{
		Enabled:        true,
		RouteID:        configured.ID,
		Owner:          configured.HostID,
		PublicHostname: configured.PublicHostname,
		PathPrefix:     configured.PathPrefix,
		AuthMode:       configured.AuthMode,
	}); err != nil {
		s.writePublicAccessError(writer, http.StatusInternalServerError, err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

// handlePublicAccessTest validates the Relay route configuration without
// changing the user's enabled intent.
func (s *HTTPServer) handlePublicAccessTest(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body api.PublicAccessTestRequest
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		s.writePublicAccessError(writer, http.StatusBadRequest, errors.New("invalid public access test request"))
		return
	}
	s.routeMu.Lock()
	defer s.routeMu.Unlock()
	client, err := s.routeClient()
	if err != nil {
		s.writePublicAccessError(writer, http.StatusServiceUnavailable, err)
		return
	}
	current := s.Service.PublicTunnelSettingsSnapshot()
	route := relay.Route{
		ID:             current.RouteID,
		PublicHostname: current.PublicHostname,
		PathPrefix:     current.PathPrefix,
		AuthMode:       "public",
		Enabled:        current.Enabled,
	}
	if body.PublicHostname != nil {
		route.PublicHostname = strings.TrimSpace(*body.PublicHostname)
	}
	if body.PathPrefix != nil {
		route.PathPrefix = strings.TrimSpace(*body.PathPrefix)
	}
	// A test only reads the current route. If the caller supplied a new
	// hostname/prefix, validate it by asking Relay to configure it disabled;
	// the user's enabled intent remains unchanged.
	if body.PublicHostname != nil || body.PathPrefix != nil {
		route.Enabled = false
		configured, configureErr := client.Configure(request.Context(), route)
		if configureErr != nil {
			s.writePublicAccessError(writer, http.StatusBadGateway, configureErr)
			return
		}
		route = configured
	} else {
		route, err = client.Get(request.Context())
		if err != nil {
			s.writePublicAccessError(writer, http.StatusBadGateway, err)
			return
		}
	}
	if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{
		Enabled:        current.Enabled,
		RouteID:        route.ID,
		Owner:          route.HostID,
		PublicHostname: route.PublicHostname,
		PathPrefix:     route.PathPrefix,
		AuthMode:       route.AuthMode,
	}); err != nil {
		s.writePublicAccessError(writer, http.StatusInternalServerError, err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) handlePublicAccessDisable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.routeMu.Lock()
	defer s.routeMu.Unlock()
	client, err := s.routeClient()
	if err != nil {
		s.writePublicAccessError(writer, http.StatusServiceUnavailable, err)
		return
	}
	if err := client.Disable(request.Context()); err != nil && !errors.Is(err, relay.ErrRouteNotFound) {
		s.writePublicAccessError(writer, http.StatusBadGateway, err)
		return
	}
	current := s.Service.PublicTunnelSettingsSnapshot()
	current.Enabled = false
	if err := s.Service.UpdatePublicTunnelSettings(current); err != nil {
		s.writePublicAccessError(writer, http.StatusInternalServerError, err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

// handlePublicAccessReset disables the Relay route and clears Warren's local
// route metadata. The Relay Host record remains enrolled for later use.
func (s *HTTPServer) handlePublicAccessReset(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.routeMu.Lock()
	defer s.routeMu.Unlock()
	if client, err := s.routeClient(); err == nil {
		if disableErr := client.Disable(request.Context()); disableErr != nil && !errors.Is(disableErr, relay.ErrRouteNotFound) {
			s.writePublicAccessError(writer, http.StatusBadGateway, disableErr)
			return
		}
	}
	if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{}); err != nil {
		s.writePublicAccessError(writer, http.StatusInternalServerError, err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) handlePublicAccessRestart(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.routeMu.Lock()
	defer s.routeMu.Unlock()
	client, err := s.routeClient()
	if err != nil {
		s.writePublicAccessError(writer, http.StatusServiceUnavailable, err)
		return
	}
	current := s.Service.PublicTunnelSettingsSnapshot()
	route := relay.Route{ID: current.RouteID, PublicHostname: current.PublicHostname, PathPrefix: current.PathPrefix, AuthMode: "public", Enabled: true}
	configured, err := client.Configure(request.Context(), route)
	if err != nil {
		s.writePublicAccessError(writer, http.StatusBadGateway, err)
		return
	}
	if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{
		Enabled: true, RouteID: configured.ID, Owner: configured.HostID,
		PublicHostname: configured.PublicHostname, PathPrefix: configured.PathPrefix,
		AuthMode: configured.AuthMode,
	}); err != nil {
		s.writePublicAccessError(writer, http.StatusInternalServerError, err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

// publicAccessRPC exposes the same Relay-owned route lifecycle to clients
// connected through the Relay control WebSocket. The daemon performs route
// mutations with its locally held Host Secret; neither that secret nor the
// Relay route capability is placed on the control stream.
func (s *HTTPServer) publicAccessRPC(ctx context.Context, action, publicHostname, pathPrefix string) (api.PublicAccessStatus, error) {
	if action == "status" {
		return s.publicAccessStatus(), nil
	}
	s.routeMu.Lock()
	defer s.routeMu.Unlock()

	current := s.Service.PublicTunnelSettingsSnapshot()
	switch action {
	case "enable":
		client, err := s.routeClient()
		if err != nil {
			return api.PublicAccessStatus{}, err
		}
		if s.RelayStart != nil {
			if err := s.RelayStart(); err != nil {
				return api.PublicAccessStatus{}, err
			}
		}
		route := relay.Route{
			ID:             current.RouteID,
			PublicHostname: current.PublicHostname,
			PathPrefix:     current.PathPrefix,
			AuthMode:       "public",
			Enabled:        true,
		}
		if strings.TrimSpace(publicHostname) != "" {
			route.PublicHostname = strings.TrimSpace(publicHostname)
		}
		if strings.TrimSpace(pathPrefix) != "" {
			route.PathPrefix = strings.TrimSpace(pathPrefix)
		}
		configured, err := client.Configure(ctx, route)
		if err != nil {
			return api.PublicAccessStatus{}, err
		}
		if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{
			Enabled:        true,
			RouteID:        configured.ID,
			Owner:          configured.HostID,
			PublicHostname: configured.PublicHostname,
			PathPrefix:     configured.PathPrefix,
			AuthMode:       configured.AuthMode,
		}); err != nil {
			return api.PublicAccessStatus{}, err
		}
	case "test":
		client, err := s.routeClient()
		if err != nil {
			return api.PublicAccessStatus{}, err
		}
		route := relay.Route{
			ID:             current.RouteID,
			PublicHostname: current.PublicHostname,
			PathPrefix:     current.PathPrefix,
			AuthMode:       "public",
			Enabled:        current.Enabled,
		}
		provided := strings.TrimSpace(publicHostname) != "" || strings.TrimSpace(pathPrefix) != ""
		if strings.TrimSpace(publicHostname) != "" {
			route.PublicHostname = strings.TrimSpace(publicHostname)
		}
		if strings.TrimSpace(pathPrefix) != "" {
			route.PathPrefix = strings.TrimSpace(pathPrefix)
		}
		if provided {
			route.Enabled = false
			route, err = client.Configure(ctx, route)
		} else {
			route, err = client.Get(ctx)
		}
		if err != nil {
			return api.PublicAccessStatus{}, err
		}
		if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{
			Enabled:        current.Enabled,
			RouteID:        route.ID,
			Owner:          route.HostID,
			PublicHostname: route.PublicHostname,
			PathPrefix:     route.PathPrefix,
			AuthMode:       route.AuthMode,
		}); err != nil {
			return api.PublicAccessStatus{}, err
		}
	case "disable":
		client, err := s.routeClient()
		if err != nil {
			return api.PublicAccessStatus{}, err
		}
		if err := client.Disable(ctx); err != nil && !errors.Is(err, relay.ErrRouteNotFound) {
			return api.PublicAccessStatus{}, err
		}
		current.Enabled = false
		if err := s.Service.UpdatePublicTunnelSettings(current); err != nil {
			return api.PublicAccessStatus{}, err
		}
	case "reset":
		if client, err := s.routeClient(); err == nil {
			if disableErr := client.Disable(ctx); disableErr != nil && !errors.Is(disableErr, relay.ErrRouteNotFound) {
				return api.PublicAccessStatus{}, disableErr
			}
		}
		if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{}); err != nil {
			return api.PublicAccessStatus{}, err
		}
	case "restart":
		client, err := s.routeClient()
		if err != nil {
			return api.PublicAccessStatus{}, err
		}
		route := relay.Route{ID: current.RouteID, PublicHostname: current.PublicHostname, PathPrefix: current.PathPrefix, AuthMode: "public", Enabled: true}
		configured, err := client.Configure(ctx, route)
		if err != nil {
			return api.PublicAccessStatus{}, err
		}
		if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{
			Enabled:        true,
			RouteID:        configured.ID,
			Owner:          configured.HostID,
			PublicHostname: configured.PublicHostname,
			PathPrefix:     configured.PathPrefix,
			AuthMode:       configured.AuthMode,
		}); err != nil {
			return api.PublicAccessStatus{}, err
		}
	default:
		return api.PublicAccessStatus{}, fmt.Errorf("unknown public access action: %s", action)
	}
	return s.publicAccessStatus(), nil
}

func (s *HTTPServer) publicAccessStatus() api.PublicAccessStatus {
	current := s.Service.SettingsSnapshot()
	status := api.PublicAccessStatus{
		RelayURL:       current.Relay.URL,
		HostID:         current.Relay.HostID,
		RouteID:        current.PublicTunnel.RouteID,
		PublicHostname: current.PublicTunnel.PublicHostname,
		PathPrefix:     current.PublicTunnel.PathPrefix,
		AuthMode:       current.PublicTunnel.AuthMode,
		Enabled:        current.PublicTunnel.Enabled,
	}
	if s.RelayRouteClient == nil {
		return status
	}
	client, err := s.RelayRouteClient()
	if err != nil {
		if status.Enabled {
			status.Error = err.Error()
		}
		return status
	}
	route, err := client.Get(context.Background())
	if err != nil {
		if !errors.Is(err, relay.ErrRouteNotFound) {
			status.Error = err.Error()
		}
		return status
	}
	status.Authenticated = true
	status.RouteID = route.ID
	status.PublicHostname = route.PublicHostname
	status.PathPrefix = route.PathPrefix
	status.AuthMode = route.AuthMode
	status.Running = route.Enabled
	if route.Enabled {
		if endpoint, endpointErr := route.PublicURL(current.Relay.URL); endpointErr == nil {
			status.PublicEndpoint = endpoint
		} else {
			status.Error = endpointErr.Error()
			status.Running = false
		}
	}
	return status
}

func (s *HTTPServer) routeClient() (*relay.RouteClient, error) {
	if s.RelayRouteClient == nil {
		return nil, errors.New("Relay route is not configured")
	}
	return s.RelayRouteClient()
}

func (s *HTTPServer) writePublicAccessStatus(writer http.ResponseWriter, code int, status api.PublicAccessStatus) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(code)
	_ = json.NewEncoder(writer).Encode(status)
}

func (s *HTTPServer) writePublicAccessError(writer http.ResponseWriter, code int, err error) {
	status := s.publicAccessStatus()
	status.Error = err.Error()
	s.writePublicAccessStatus(writer, code, status)
}

func (s *HTTPServer) handleWebSocket(writer http.ResponseWriter, request *http.Request) {
	connection, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	peer := newWSPeer(s, connection)
	defer func() {
		s.unregisterPeer(peer)
		peer.close()
	}()
	_ = connection.SetReadDeadline(time.Now().Add(10 * time.Second))
	var envelope api.Envelope
	publicRelayWebSocket := relay.IsPublicRoute(request.Context()) && request.URL.Path == "/v1/ws"
	if err := connection.ReadJSON(&envelope); err != nil || envelope.Type != "auth" ||
		(!s.authorized(envelope.Token) && !(publicRelayWebSocket && strings.TrimSpace(envelope.Token) == "")) {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	s.registerPeer(peer)
	// Protocol 3 changes terminal recovery from a replayable byte stream to an
	// atomically installable terminal state.  A missing version is therefore not
	// an older-but-compatible client: it is an unauthenticated protocol shape
	// that must be rejected before any roster or session data is exposed.
	if envelope.Version != api.Version {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: fmt.Sprintf(
			"incompatible protocol version: client=%s server=%s", envelope.Version, api.Version,
		)})
		return
	}
	peer.terminalStateFormat = selectTerminalStateFormat(envelope.TerminalStateFormats)
	if peer.terminalStateFormat == "" {
		_ = peer.writeJSON(api.Response{
			Type:  "error",
			OK:    false,
			Error: "upgrade required: client does not support a compatible atomic terminal state format",
		})
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	peer.accessScopeID = s.accessScopeID("")
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
			go func(command api.Envelope) {
				if err := peer.handle(request.Context(), command); err != nil {
					_ = peer.writeError(command.ID, err)
				}
			}(command)
			continue
		}
		if err := peer.handle(request.Context(), command); err != nil {
			_ = peer.writeError(command.ID, err)
		}
	}
}

// HandleRelayControl adapts one BRLY/2 control stream to the daemon's normal
// wsPeer protocol. The Relay has already authenticated the client capability;
// the Host still validates the stream metadata and never forwards its Host
// Secret back across the transport. send is Connector.Send for the owning
// stream and is kept as a callback to avoid coupling this package to relay's
// connection state.
func (s *HTTPServer) HandleRelayControl(
	ctx context.Context,
	open relay.StreamOpen,
	value relay.Frame,
	send func(relay.Frame) error,
) error {
	if open.Class != "control" {
		return fmt.Errorf("unsupported Relay control class: %s", open.Class)
	}
	if send == nil {
		return errors.New("Relay control transport is unavailable")
	}
	transport := func(item outboundMessage) bool {
		kind := relay.FrameText
		if item.kind == websocket.BinaryMessage {
			kind = relay.FrameBinary
		}
		return send(relay.Frame{Kind: kind, ID: value.ID, Payload: append([]byte(nil), item.data...)}) == nil
	}

	s.relayPeersMu.Lock()
	entry := s.relayPeers[value.ID]
	if value.Kind == relay.FrameOpen {
		if entry != nil {
			s.relayPeersMu.Unlock()
			return errors.New("duplicate Relay control stream")
		}
		entry = &relayControlPeer{peer: newRelayPeer(s, transport), open: open, ctx: ctx}
		s.relayPeers[value.ID] = entry
	}
	s.relayPeersMu.Unlock()
	if entry == nil {
		return errors.New("unknown Relay control stream")
	}

	peer := entry.peer
	if value.Kind == relay.FrameClose || value.Kind == relay.FrameError || value.Kind == relay.FrameEnd {
		s.removeRelayControl(value.ID, entry)
		return nil
	}
	if value.Kind != relay.FrameText && value.Kind != relay.FrameBinary {
		return nil
	}
	entry.stateMu.Lock()
	authenticated := entry.authenticated
	entry.stateMu.Unlock()
	if !authenticated {
		if value.Kind != relay.FrameText {
			return errors.New("Relay control authentication must be text")
		}
		var auth struct {
			Type         string   `json:"t"`
			AccessToken  string   `json:"access_token"`
			ClientID     string   `json:"client_id"`
			Version      string   `json:"version"`
			Capabilities []string `json:"capabilities"`
			Formats      []string `json:"terminalStateFormats"`
		}
		if err := json.Unmarshal(value.Payload, &auth); err != nil || auth.Type != "auth" || auth.Version != api.Version {
			return errors.New("invalid Relay control authentication")
		}
		if auth.AccessToken == "" || open.Token == "" || auth.AccessToken != open.Token {
			return errors.New("Relay control capability mismatch")
		}
		if open.ClientID != "" && auth.ClientID != open.ClientID {
			return errors.New("Relay control client mismatch")
		}
		peer.terminalStateFormat = selectTerminalStateFormat(auth.Formats)
		if peer.terminalStateFormat == "" {
			return errors.New("Relay control has no compatible terminal state format")
		}
		// The local wsPeer implementation expects the daemon token in its
		// envelope. This substitution happens entirely inside Headless; the
		// Host Secret is never put on the Relay wire.
		entry.stateMu.Lock()
		entry.authenticated = true
		entry.stateMu.Unlock()
		s.registerPeer(peer)
		peer.accessScopeID = s.accessScopeID(auth.ClientID)
		peer.setCapabilities(api.NegotiateCapabilities(s.Service.AgentViewCapabilities(), auth.Capabilities))
		state, revision := s.Service.RosterVersion(ctx)
		state = projectRosterCapabilities(state, peer.capabilitiesList())
		if err := peer.writeJSON(api.WelcomeMessage{
			Type: "welcome", Version: api.Version, Host: state.Host,
			AccessScopeID: peer.accessScopeID, Capabilities: peer.capabilitiesList(),
		}); err != nil {
			s.removeRelayControl(value.ID, entry)
			return err
		}
		if err := peer.writeJSON(makeRoster(state)); err != nil {
			s.removeRelayControl(value.ID, entry)
			return err
		}
		peer.startRoster(ctx, state, revision, supportsRosterDeltas(auth.Capabilities))
		return nil
	}

	if value.Kind == relay.FrameBinary {
		return peer.input(ctx, value.Payload)
	}
	var command api.Envelope
	if err := json.Unmarshal(value.Payload, &command); err != nil {
		return peer.writeError("", fmt.Errorf("invalid request: %w", err))
	}
	if command.Type == "ping" {
		if peer.supportsCapability(api.CapabilityAppHeartbeat) {
			return peer.writeJSON(map[string]any{"t": "pong", "id": command.ID})
		}
		return nil
	}
	if command.Type != "request" {
		return peer.writeError(command.ID, errors.New("unsupported message type"))
	}
	if isSlowMutation(command.Method) {
		go func() {
			// Keep accepted lifecycle mutations bounded and independent from the
			// Relay stream lifetime, matching the local WebSocket path.
			mutationContext, cancel := context.WithTimeout(
				context.WithoutCancel(ctx), slowMutationTimeout,
			)
			defer cancel()
			if err := peer.handle(mutationContext, command); err != nil {
				_ = peer.writeError(command.ID, err)
			}
		}()
		return nil
	}
	if isBackgroundRequest(command.Method) {
		go func() {
			if err := peer.handle(ctx, command); err != nil {
				_ = peer.writeError(command.ID, err)
			}
		}()
		return nil
	}
	return peer.handle(ctx, command)
}

func (s *HTTPServer) removeRelayControl(id relay.ConnectionID, entry *relayControlPeer) {
	s.relayPeersMu.Lock()
	if current := s.relayPeers[id]; current == entry {
		delete(s.relayPeers, id)
	}
	s.relayPeersMu.Unlock()
	entry.stateMu.Lock()
	authenticated := entry.authenticated
	entry.authenticated = false
	entry.stateMu.Unlock()
	if authenticated {
		s.unregisterPeer(entry.peer)
	}
	entry.peer.close()
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

func isBackgroundRequest(method string) bool {
	switch method {
	case "git.panel", "git.diff", "session.subscribe", "settings.testOpenAI":
		return true
	default:
		return false
	}
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
	// Manual Refresh Runtime from the menu bar. For now it acknowledges the
	// request so the UI can refresh versions; new sessions already inherit
	// truecolor via sessionEnv. A full ghostline handoff for existing
	// sessions will be added here and will return a JSON error on failure
	// so the menu bar can show the reason (handoffFailed).
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
	// outbound is the bounded terminal-output lane. Text/control traffic uses
	// controlOutbound so a burst of binary output cannot delay a response,
	// heartbeat, or recovery marker.
	outbound        chan outboundMessage
	controlOutbound chan outboundMessage
	// transport is set for a Relay control peer. It bypasses the WebSocket
	// socket but is still owned by the peer's writer goroutine, preserving the
	// same bounded queue and service lifecycle.
	transport func(outboundMessage) bool

	enqueueMu sync.Mutex
	closed    chan struct{}
	closeFlag bool
	attached  *api.Session
	// outputs tracks every terminal session this peer subscribed to for
	// output. A desktop client keeps one subscription per retained warm
	// surface so background sessions keep consuming output; legacy web and
	// mobile clients keep exactly the one implicit subscription created by
	// their attach. Guarded by enqueueMu.
	outputs               map[string]struct{}
	controlSession        string
	agentSession          string
	canonicalAgentStreams map[string]struct{}
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
	p.enqueueMu.Lock()
	sessionIDs, agentSessionID := p.closeLocked()
	p.enqueueMu.Unlock()
	p.cancelAllPendingSubscriptions()
	for _, sessionID := range sessionIDs {
		p.server.Service.detachPeer(p, sessionID)
	}
	if agentSessionID != "" {
		p.server.Service.detachAgentPeer(p, agentSessionID)
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
				p.close()
				return
			}
			continue
		}
		_ = p.connection.SetWriteDeadline(time.Now().Add(outboundWriteTimeout))
		if err := p.connection.WriteMessage(item.kind, item.data); err != nil {
			p.close()
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
		sessionIDs, agentSessionID := p.closeLocked()
		p.enqueueMu.Unlock()
		p.cancelAllPendingSubscriptions()
		for _, sessionID := range sessionIDs {
			p.server.Service.detachPeer(p, sessionID)
		}
		if agentSessionID != "" {
			p.server.Service.detachAgentPeer(p, agentSessionID)
		}
		return false
	}
}

// closeLocked must be called with enqueueMu held. It is idempotent so both
// the writer's error path and queue overflow can tear down the same peer
// exactly once. It returns every terminal subscription ID and the
// agent-only subscription ID so the caller can unregister after releasing
// the lock, keeping registry lock ordering acyclic.

func (p *wsPeer) closeLocked() ([]string, string) {
	if p.closeFlag {
		agentSessionID := p.agentSession
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
		return sessionIDs, agentSessionID
	}
	p.closeFlag = true
	if p.rosterCancel != nil {
		p.rosterCancel()
		p.rosterCancel = nil
	}
	sessionIDs := make([]string, 0, len(p.outputs)+1)
	for sessionID := range p.outputs {
		sessionIDs = append(sessionIDs, sessionID)
	}
	if p.attached != nil && p.outputs[p.attached.ID] == struct{}{} {
		sessionIDs = append(sessionIDs, p.attached.ID)
	}
	close(p.closed)
	if p.controlOutbound != nil {
		close(p.controlOutbound)
	}
	if p.outbound != nil {
		close(p.outbound)
	}
	return sessionIDs, p.agentSession
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

func (p *wsPeer) writeBinary(data []byte) error {
	if !p.enqueue(outboundMessage{kind: websocket.BinaryMessage, data: data}) {
		return errors.New("outbound queue overflow")
	}
	return nil
}

func (p *wsPeer) enqueueBinary(data []byte) bool {
	return p.enqueue(outboundMessage{kind: websocket.BinaryMessage, data: data})
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
	return p.writeJSON(map[string]any{
		"t": "attached", "session": sessionID,
		"epoch": epoch, "sequence": sequence,
		"reanchor": reanchor,
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
	} else if protocolErr == nil && (errors.Is(err, store.ErrCanonicalCommandConflict) || strings.Contains(strings.ToLower(err.Error()), "idempotency")) {
		code = "command_conflict"
	} else if protocolErr == nil && (strings.Contains(strings.ToLower(err.Error()), "version") || strings.Contains(strings.ToLower(err.Error()), "stale")) {
		code = "stale_version"
	}
	return p.writeJSON(api.Response{Type: "response", ID: id, OK: false, Error: err.Error(), Code: code, Details: details})
}

func (p *wsPeer) startRoster(parent context.Context, initial api.State, initialRevision uint64, useDeltas bool) {
	ctx, cancel := context.WithCancel(parent)
	p.rosterCancel = cancel
	go func() {
		ticker := time.NewTicker(750 * time.Millisecond)
		defer ticker.Stop()
		state := initial
		deliveredRevision := initial.Revision
		observedRevision := initialRevision
		last, _ := json.Marshal(makeRoster(initial))
		changes := p.server.Service.Store.ChangesSince(observedRevision)
		var batchTimer *time.Timer
		var batch <-chan time.Time
		defer func() {
			if batchTimer != nil {
				batchTimer.Stop()
			}
		}()

		publish := func(next api.State, revision uint64) bool {
			if useDeltas {
				delta := makeRosterDelta(state, next, deliveredRevision, revision)
				if !delta.hasChanges() {
					return true
				}
				data, err := json.Marshal(delta)
				if err != nil {
					return true
				}
				if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
					p.close()
					return false
				}
				state = next
				deliveredRevision = revision
				return true
			}

			data, err := json.Marshal(makeRoster(next))
			if err != nil {
				return true
			}
			if bytes.Equal(data, last) {
				return true
			}
			last = append(last[:0], data...)
			if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
				p.close()
				return false
			}
			state = next
			deliveredRevision = revision
			return true
		}
		refresh := func() bool {
			next, storeRevision := p.server.Service.RosterVersion(ctx)
			next = projectRosterCapabilities(next, p.capabilitiesList())
			observedRevision = storeRevision
			return publish(next, next.Revision)
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-changes:
				if !useDeltas {
					if !refresh() {
						return
					}
					changes = p.server.Service.Store.ChangesSince(observedRevision)
					continue
				}
				if batchTimer == nil {
					batchTimer = time.NewTimer(rosterDeltaBatchDelay)
					batch = batchTimer.C
				}
				changes = nil
			case <-batch:
				batchTimer = nil
				batch = nil
				if !refresh() {
					return
				}
				changes = p.server.Service.Store.ChangesSince(observedRevision)
			case <-ticker.C:
				if !refresh() {
					return
				}
				changes = p.server.Service.Store.ChangesSince(observedRevision)
			}
		}
	}()
}

func makeRoster(state api.State) rosterMessage {
	return rosterMessage{Type: "roster", State: state}
}

// projectRosterCapabilities applies the connection-level negotiation to the
// Host-computed Session capability set. The durable/observer roster retains
// provider capabilities; each WebSocket receives only the intersection it can
// actually decode and execute.
func projectRosterCapabilities(state api.State, connection []string) api.State {
	for index := range state.Sessions {
		values := state.Sessions[index].AgentCapabilities
		if values == nil {
			// A roster produced by an older embedded Service has no Session-level
			// field. Treat it as unknown and preserve the established connection
			// capability fallback instead of denying every control.
			values = api.AgentViewCapabilities
		}
		allowed := make([]string, 0, len(values))
		for _, value := range values {
			if api.SupportsCapability(connection, value) {
				allowed = append(allowed, value)
			}
		}
		state.Sessions[index].AgentCapabilities = api.NormalizeCapabilityList(allowed)
	}
	return state
}

func publicSession(session api.Session) api.Session {
	session.OutputCursor = ""
	if session.AgentCapabilities == nil {
		session.AgentCapabilities = []string{}
	}
	return session
}

func publicSessionMovePreflight(value api.SessionMovePreflight) api.SessionMovePreflight {
	value.Session = publicSession(value.Session)
	return value
}

func (p *wsPeer) handle(ctx context.Context, command api.Envelope) error {
	if command.Type != "request" {
		return fmt.Errorf("unsupported message type: %s", command.Type)
	}
	params := command.Params
	switch command.Method {
	case "roster":
		return p.writeResult(command.ID, p.server.Service.Roster(ctx))
	case "agent.execution.get":
		executionID := stringParam(params, "executionId")
		if executionID == "" {
			return p.writeCanonicalError(command.ID, errors.New("executionId is required"))
		}
		if session, ok := p.server.Service.sessionForCanonicalStream(executionID); ok {
			if execution, exists := p.server.Service.canonicalExecutionForSession(session.ID); exists {
				return p.writeResult(command.ID, execution)
			}
		}
		if p.server.Service.AgentStore != nil {
			execution, found, err := p.server.Service.AgentStore.CanonicalExecution(ctx, executionID)
			if err != nil {
				return p.writeCanonicalError(command.ID, err)
			}
			if found {
				return p.writeResult(command.ID, execution)
			}
		}
		return p.writeCanonicalError(command.ID, fmt.Errorf("agent execution not found: %s", executionID))
	case "agent.events.history":
		request, err := decodeAgentParams[api.AgentEventsHistoryRequest](params)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		request.StreamID = strings.TrimSpace(request.StreamID)
		if request.StreamID == "" {
			return p.writeCanonicalError(command.ID, errors.New("streamId is required"))
		}
		result, queryErr := p.server.Service.canonicalHistoryPage(ctx, request.StreamID, request.AfterSequence, request.BeforeSequence, int(request.Limit))
		if queryErr != nil {
			return p.writeCanonicalError(command.ID, queryErr)
		}
		return p.writeResult(command.ID, result)
	case "agent.events.subscribe":
		request, err := decodeAgentParams[api.AgentEventsSubscriptionRequest](params)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		request.StreamID = strings.TrimSpace(request.StreamID)
		if request.StreamID == "" {
			return p.writeCanonicalError(command.ID, errors.New("streamId is required"))
		}
		session, ok := p.server.Service.sessionForCanonicalStream(request.StreamID)
		if !ok {
			return p.writeCanonicalError(command.ID, fmt.Errorf("agent execution not found: %s", request.StreamID))
		}
		lock := p.server.Service.broadcastLock(session.ID)
		if err := lock.LockContext(ctx); err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		result, queryErr := p.server.Service.canonicalHistoryPage(ctx, request.StreamID, request.AfterSequence, 0, int(request.Limit))
		if queryErr != nil {
			lock.Unlock()
			return p.writeCanonicalError(command.ID, queryErr)
		}
		// The delivery limit is a page hint, never a checkpoint cursor. Hold
		// the broadcast lock until every pre-live event has been collected.
		for result.HasMore && len(result.Events) > 0 {
			after, before := result.NextAfterSequence, uint64(0)
			if request.AfterSequence == 0 {
				after, before = 0, result.Events[0].Sequence
			}
			page, err := p.server.Service.canonicalHistoryPage(ctx, request.StreamID, after, before, int(request.Limit))
			if err != nil {
				lock.Unlock()
				return p.writeCanonicalError(command.ID, err)
			}
			if request.AfterSequence == 0 {
				result.Events = append(page.Events, result.Events...)
			} else {
				result.Events = append(result.Events, page.Events...)
			}
			result.HasMore, result.NextAfterSequence = page.HasMore, page.NextAfterSequence
			if len(page.Events) == 0 {
				break
			}
		}
		checkpoint := p.server.Service.canonicalProjectionCheckpoint(session.ID, result.HeadSequence)
		if err := p.subscribeCanonicalAgent(session.ID, request.StreamID); err != nil {
			lock.Unlock()
			return p.writeCanonicalError(command.ID, err)
		}
		value := api.AgentEventsSubscriptionResult{
			StreamID: request.StreamID, ExecutionID: result.ExecutionID,
			Checkpoint: checkpoint, Events: result.Events, Live: true,
		}
		writeErr := p.writeResult(command.ID, value)
		lock.Unlock()
		if writeErr != nil {
			p.server.Service.detachAgentPeer(p, session.ID)
		}
		return writeErr
	case "agent.execution.resume":
		return p.handleCanonicalExecutionResume(ctx, command)
	case "agent.turn.start":
		return p.handleCanonicalTurnStart(ctx, command)
	case "agent.turn.steer":
		return p.handleCanonicalTurnSteer(ctx, command)
	case "agent.turn.cancel":
		return p.handleCanonicalTurnCancel(ctx, command)
	case "agent.interaction.resolve":
		return p.handleCanonicalInteractionResolve(ctx, command)
	case "agent.attachment.prepare":
		return p.handleCanonicalAttachmentPrepare(ctx, command)
	case "agent.attachment.chunk":
		return p.handleCanonicalAttachmentChunk(ctx, command)
	case "agent.attachment.complete":
		return p.handleCanonicalAttachmentComplete(ctx, command)
	case "agent.attachment.abort":
		return p.handleCanonicalAttachmentAbort(ctx, command)
	case "relay.pairing":
		if p.server.RelayPairing == nil {
			return errors.New("Relay pairing is unavailable")
		}
		value, err := p.server.RelayPairing(ctx)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "relay.devices.list":
		if p.server.RelayRouteClient == nil {
			return errors.New("Relay device management is unavailable")
		}
		client, err := p.server.RelayRouteClient()
		if err != nil {
			return err
		}
		devices, err := client.Devices(ctx)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]any{"devices": devices})
	case "relay.devices.revoke":
		if p.server.RelayRouteClient == nil {
			return errors.New("Relay device management is unavailable")
		}
		client, err := p.server.RelayRouteClient()
		if err != nil {
			return err
		}
		if err := client.RevokeDevice(ctx, stringParam(params, "deviceID")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"revoked": true})
	case "settings.get":
		value := p.server.Service.SettingsSnapshot()
		return p.writeResult(command.ID, map[string]any{
			"defaultRuntime":     value.DefaultRuntime,
			"runtimeEnv":         value.RuntimeEnv,
			"autoOpenShell":      value.AutoOpenShell,
			"autoStartAI":        value.AutoStartAI,
			"openaiBaseURL":      value.OpenAIBaseURL,
			"openaiModel":        value.OpenAIModel,
			"openaiTitleEnabled": value.OpenAITitleEnabled,
			"relay":              value.Relay,
			"publicTunnel":       value.PublicTunnel,
		})
	case "relay.reset":
		if err := p.server.resetRelayEnrollment(ctx); err != nil {
			return err
		}
		value := p.server.Service.SettingsSnapshot()
		return p.writeResult(command.ID, map[string]any{
			"reset":        true,
			"relay":        value.Relay,
			"publicTunnel": value.PublicTunnel,
		})
	case "public-access.status", "public-access.enable", "public-access.test", "public-access.disable", "public-access.reset", "public-access.restart":
		action := strings.TrimPrefix(command.Method, "public-access.")
		value, err := p.server.publicAccessRPC(ctx, action, stringParam(params, "publicHostname"), stringParam(params, "pathPrefix"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "settings.testOpenAI":
		if err := p.server.Service.TestOpenAITitle(
			ctx,
			stringParam(params, "openaiBaseURL"),
			stringParam(params, "openaiModel"),
			stringParam(params, "openaiKey"),
		); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"ok": true})
	case "settings.put":
		current := p.server.Service.SettingsSnapshot()
		runtimeEnv := stringMapParam(params, "runtimeEnv")
		if runtimeEnv == nil {
			runtimeEnv = current.RuntimeEnv
		}
		if err := p.server.Service.UpdateSettings(stringParam(params, "defaultRuntime"), runtimeEnv); err != nil {
			return err
		}
		if _, specified := params["autoOpenShell"]; specified {
			if err := p.server.Service.SetAutoOpenShell(boolParam(params, "autoOpenShell")); err != nil {
				return err
			}
		}
		if _, specified := params["autoStartAI"]; specified {
			if err := p.server.Service.SetAutoStartAI(boolParam(params, "autoStartAI")); err != nil {
				return err
			}
		}
		if _, specified := params["openaiBaseURL"]; specified {
			p.server.Service.Settings.OpenAIBaseURL = strings.TrimSpace(stringParam(params, "openaiBaseURL"))
		}
		if _, specified := params["openaiModel"]; specified {
			p.server.Service.Settings.OpenAIModel = strings.TrimSpace(stringParam(params, "openaiModel"))
		}
		if _, specified := params["openaiKey"]; specified {
			p.server.Service.Settings.OpenAIKey = strings.TrimSpace(stringParam(params, "openaiKey"))
		}
		if _, specified := params["openaiTitleEnabled"]; specified {
			p.server.Service.Settings.OpenAITitleEnabled = boolParam(params, "openaiTitleEnabled")
		}
		if _, specified := params["openaiBaseURL"]; specified || params["openaiModel"] != nil || params["openaiKey"] != nil || params["openaiTitleEnabled"] != nil {
			if p.server.Service.SettingsPath != "" {
				if err := settings.Save(p.server.Service.SettingsPath, p.server.Service.Settings); err != nil {
					return err
				}
			}
		}
		if value, specified := params["relay"]; specified {
			data, err := json.Marshal(value)
			var relayValue settings.RelaySettings
			if err != nil || json.Unmarshal(data, &relayValue) != nil {
				return errors.New("invalid relay settings")
			}
			if err := p.server.Service.UpdateRelaySettings(relayValue); err != nil {
				return err
			}
		}
		if value, specified := params["publicTunnel"]; specified {
			data, err := json.Marshal(value)
			var tunnelValue settings.PublicTunnelSettings
			if err != nil || json.Unmarshal(data, &tunnelValue) != nil {
				return errors.New("invalid public tunnel settings")
			}
			if err := p.server.Service.UpdatePublicTunnelSettings(tunnelValue); err != nil {
				return err
			}
		}
		if err := p.server.syncRelayLifecycle(); err != nil {
			return err
		}
		value := p.server.Service.SettingsSnapshot()
		return p.writeResult(command.ID, map[string]any{
			"defaultRuntime":     value.DefaultRuntime,
			"runtimeEnv":         value.RuntimeEnv,
			"autoOpenShell":      value.AutoOpenShell,
			"autoStartAI":        value.AutoStartAI,
			"openaiBaseURL":      value.OpenAIBaseURL,
			"openaiModel":        value.OpenAIModel,
			"openaiTitleEnabled": value.OpenAITitleEnabled,
			"relay":              value.Relay,
			"publicTunnel":       value.PublicTunnel,
		})
	case "project.add":
		value, err := p.server.Service.AddProjectWithOptions(
			stringParam(params, "path"),
			stringParam(params, "name"),
			boolParam(params, "autoImportGitWorktrees"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "task.create":
		value, err := p.server.Service.CreateTaskWithRequestID(
			stringParam(params, "name"),
			stringParam(params, "source"),
			stringParam(params, "externalID"),
			stringParam(params, "url"),
			stringParam(params, "requestId"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "task.remove":
		if err := p.server.Service.RemoveTask(stringParam(params, "id")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "task.rename":
		if err := p.server.Service.RenameTask(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "task.pin":
		if err := p.server.Service.SetTaskPinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "task.move":
		if err := p.server.Service.MoveTask(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "task.attach":
		if err := p.server.Service.AttachWorkspaceToTask(stringParam(params, "id"), stringParam(params, "workspace")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"attached": true})
	case "task.detach":
		if err := p.server.Service.DetachWorkspaceFromTask(stringParam(params, "id"), stringParam(params, "workspace")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"detached": true})
	case "project.worktrees":
		value, err := p.server.Service.ListProjectWorktrees(stringParam(params, "project"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "project.worktrees.import":
		value, err := p.server.Service.ImportProjectWorktrees(
			stringParam(params, "project"),
			stringSliceParam(params, "paths"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]any{"workspaces": value})
	case "project.autoImportGitWorktrees":
		value, err := p.server.Service.SetProjectAutoImportGitWorktrees(
			stringParam(params, "project"),
			boolParam(params, "enabled"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "project.setupScript":
		value, err := p.server.Service.SetProjectSetupScript(
			stringParam(params, "project"),
			stringParam(params, "script"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "project.remove":
		if err := p.server.Service.RemoveProject(stringParam(params, "id"), boolParam(params, "force")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "project.rename":
		if err := p.server.Service.RenameProject(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "project.pin":
		if err := p.server.Service.SetProjectPinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "project.move":
		if err := p.server.Service.MoveProject(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "workspace.create":
		setupArgs := stringSliceParam(params, "setupArgs")
		runSetupScript := boolParam(params, "runSetupScript")
		value, err := p.server.Service.CreateTaskWorkspaceWithSetup(
			stringParam(params, "project"), stringParam(params, "task"),
			stringParam(params, "branch"), stringParam(params, "name"),
			stringParam(params, "path"), stringParam(params, "requestId"),
			runSetupScript, setupArgs,
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "workspace.remove":
		removeWorktree := true
		if value, specified, err := optionalBoolParam(params, "remove_worktree"); err != nil {
			return err
		} else if specified {
			removeWorktree = value
		}
		if err := p.server.Service.RemoveWorkspace(ctx, stringParam(params, "id"), RemoveWorkspaceOptions{
			Force:          boolParam(params, "force"),
			RemoveWorktree: removeWorktree,
		}); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "workspace.rename":
		if err := p.server.Service.RenameWorkspace(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "workspace.pin":
		if err := p.server.Service.SetWorkspacePinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "workspace.move":
		if err := p.server.Service.MoveWorkspace(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "terminal-group.create":
		value, err := p.server.Service.CreateTerminalGroup(stringParam(params, "name"), stringParam(params, "home"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "terminal-group.remove":
		if err := p.server.Service.RemoveTerminalGroup(ctx, stringParam(params, "id"), boolParam(params, "force")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "terminal-group.rename":
		if err := p.server.Service.RenameTerminalGroup(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "terminal-group.home":
		if err := p.server.Service.SetTerminalGroupHome(stringParam(params, "id"), stringParam(params, "path")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"updated": true})
	case "terminal-group.move":
		if err := p.server.Service.MoveTerminalGroup(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "session.create":
		var value api.Session
		var err error
		groupID := stringParam(params, "group")
		workspaceID := stringParam(params, "workspace")
		if groupID != "" && workspaceID != "" {
			return errors.New("workspace and terminal group are mutually exclusive")
		}
		if groupID != "" {
			value, err = p.server.Service.CreateGroupSessionWithHandler(
				ctx,
				groupID,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
				stringParam(params, "agentHandler"),
			)
		} else if workspaceID != "" {
			value, err = p.server.Service.CreateSessionWithHandler(
				ctx,
				workspaceID,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
				stringParam(params, "agentHandler"),
			)
		} else {
			value, err = p.server.Service.CreateDefaultGroupSessionWithHandler(
				ctx,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
				stringParam(params, "agentHandler"),
			)
		}
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSession(value))
	case "session.delete":
		id := stringParam(params, "id")
		if err := p.server.Service.DeleteSession(ctx, id); err != nil {
			return err
		}
		p.detachIfAttached(id)
		return p.writeResult(command.ID, map[string]bool{"deleted": true})
	case "session.delete.preflight":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session ID is required")
		}
		value, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		return p.writeResult(command.ID, map[string]any{
			"allowed": true, "resource": "session", "id": value.ID,
			"workspace": value.WorkspaceID, "terminalGroup": value.TerminalGroupID,
			"agentSessionId": value.AgentSessionID, "transcriptPath": value.TranscriptPath,
			"lifecycle": value.Lifecycle,
		})
	case "session.current":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session ID is required")
		}
		value, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		return p.writeResult(command.ID, publicSession(value))
	case "session.rename":
		if err := p.server.Service.RenameSession(stringParam(params, "id"), stringParam(params, "title")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "session.pin":
		if err := p.server.Service.SetSessionPinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "session.move":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session parameter required")
		}
		workspaceID := stringParam(params, "workspace")
		groupID := stringParam(params, "group")
		if workspaceID != "" && groupID != "" {
			return errors.New("workspace and terminal group are mutually exclusive")
		}
		expectations := sessionMoveExpectations(params)
		value, err := p.server.Service.MoveSessionWithExpectations(ctx, id, workspaceID, groupID, expectations)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSession(value))
	case "session.move.preflight":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session parameter required")
		}
		workspaceID := stringParam(params, "workspace")
		groupID := stringParam(params, "group")
		if workspaceID != "" && groupID != "" {
			return errors.New("workspace and terminal group are mutually exclusive")
		}
		value, err := p.server.Service.PreflightSessionMove(id, workspaceID, groupID, sessionMoveExpectations(params))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSessionMovePreflight(value))
	case "session.undo":
		value, err := p.server.Service.UndoSessionMove(stringParam(params, "operation"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSession(value))
	case "session.attach":
		id := stringParam(params, "id")
		session, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		if session.Lifecycle != "running" {
			return fmt.Errorf("session is not running: %s", id)
		}
		// Control-only claims carry no output intent: the desktop promotes a
		// retained warm surface by swapping its control lease without any
		// replay, snapshot, or runtime I/O. Legacy clients omit the flag and
		// get the historical attach behavior below.
		if outputOnly, outputSpecified, err := optionalBoolParam(params, "output"); err == nil && outputSpecified && !outputOnly {
			p.claimControl(session)
			return p.writeResult(command.ID, publicSession(session))
		}
		columns, rows, specified, err := attachSizeFromParams(params)
		if err != nil {
			return err
		}
		focused, focusSpecified, err := optionalBoolParam(params, "focused")
		if err != nil {
			return err
		}
		p.logInfo("attach: begin", "session", id, "size", fmt.Sprintf("%dx%d", columns, rows), "specified", specified, "focused", focused, "focusSpecified", focusSpecified)
		p.attach(session)
		lock, resume, err := p.server.Service.prepareAttach(ctx, session)
		if err != nil {
			p.detach()
			return err
		}
		p.logInfo("attach: prepared", "session", id)
		if p.server.Service.cursorOutputRuntimeFor(session) != nil {
			p.server.Service.reservePeerCursorOutput(p, session.ID)
		}
		// Register before claiming focus so a disconnect cannot leave a stale
		// focus owner behind while the initial snapshot is being prepared.
		p.server.Service.registerPeer(session.ID, p)
		p.logInfo("attach: registered", "session", id)
		// Older clients did not send a focus flag. Let the first such attach
		// claim the empty focus slot for compatibility, while every updated
		// client explicitly sends focused=false until its terminal is focused.
		if !focusSpecified {
			focused = !p.server.Service.hasFocusedPeer(session.ID)
		}
		if focused || focusSpecified {
			_, err := p.server.Service.focusPeerLocked(ctx, p, session, focused, columns, rows, specified && focused)
			if err != nil {
				lock.Unlock()
				resume()
				p.detach()
				return err
			}
		}
		p.logInfo("attach: focus done", "session", id)
		// A passive attach deliberately ignores the carried viewport and
		// never resizes: resizing here would SIGWINCH the child program and
		// its redraw bytes would race the checkpoint below, so the client would
		// never receive them and full-screen TUIs (Codex composer, vim
		// statusline) keep repainting regions the terminal never saw.
		// Viewport ownership belongs to the focus handoff, which resizes
		// only after the snapshot has been delivered.
		if err := p.writeResult(command.ID, publicSession(session)); err != nil {
			lock.Unlock()
			resume()
			p.detach()
			return err
		}
		p.logInfo("attach: result sent", "session", id)
		anchor := anchorFromParams(params)
		if err := p.server.Service.attachOutputLocked(ctx, p, session, anchor, "session.attach"); err != nil {
			lock.Unlock()
			resume()
			p.detach()
			return err
		}
		p.logInfo("attach: output attached", "session", id)
		lock.Unlock()
		resume()
		return nil
	case "session.detach":
		p.detach()
		return p.writeResult(command.ID, map[string]bool{"detached": true})
	case "session.subscribe":
		// Output-only subscription for one session. A peer may hold many at
		// once; focus, resize, and input ownership are untouched so several
		// endpoints can observe the same terminal without fighting over its
		// shared runtime size.
		id := stringParam(params, "id")
		subscriptionContext, finishSubscription := p.beginPendingSubscription(ctx, id)
		defer finishSubscription()
		ctx = subscriptionContext
		if err := ctx.Err(); err != nil {
			return err
		}
		session, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		if session.Lifecycle != "running" {
			return fmt.Errorf("session is not running: %s", id)
		}
		anchor := anchorFromParams(params)
		anchorLabel := "none"
		if anchor != nil {
			anchorLabel = fmt.Sprintf("epoch=%d sequence=%d", anchor.Epoch, anchor.Sequence)
		}
		claimControl, claimSpecified, claimErr := optionalBoolParam(params, "claim")
		if claimErr != nil {
			return claimErr
		}
		columns, rows, sizeSpecified, sizeErr := attachSizeFromParams(params)
		if sizeErr != nil {
			return sizeErr
		}
		p.logInfo("subscribe: begin", "session", id, "anchor", anchorLabel,
			"claim", claimControl, "claimSpecified", claimSpecified,
			"size", fmt.Sprintf("%dx%d", columns, rows), "specified", sizeSpecified)
		stepStart := time.Now()
		markStep := func(step string) {
			p.logInfo("subscribe: step", "session", id, "step", step, "ms", time.Since(stepStart).Milliseconds())
		}
		lock, resume, err := p.server.Service.prepareAttach(ctx, session)
		if err != nil {
			return err
		}
		markStep("prepareAttach")
		if p.server.Service.cursorOutputRuntimeFor(session) != nil {
			p.server.Service.reservePeerCursorOutput(p, session.ID)
		}
		markStep("reservePeerCursorOutput")
		if err := ctx.Err(); err != nil {
			lock.Unlock()
			resume()
			p.server.Service.detachPeer(p, session.ID)
			return err
		}
		p.server.Service.registerPeer(session.ID, p)
		if claimControl {
			if _, focusErr := p.server.Service.focusPeerLocked(ctx, p, session, true, columns, rows, sizeSpecified); focusErr != nil {
				lock.Unlock()
				resume()
				p.server.Service.detachPeer(p, session.ID)
				return focusErr
			}
			p.claimControl(session)
		}
		markStep("registerAndClaim")
		if err := ctx.Err(); err != nil {
			lock.Unlock()
			resume()
			p.detach()
			return err
		}
		// Passive subscribers never mutate the shared runtime. A selected
		// desktop attach may explicitly claim control; in that case the resize
		// above runs while the session output lock is held, before checkpoint.
		// A subscription response is deliberately acknowledged before replaying
		// the recovery payload. Desktop can claim the control lease and keep
		// input responsive while the staged terminal output drains in the
		// background; the `synced` marker remains the presentation boundary.
		if err := p.writeResult(command.ID, map[string]bool{"subscribed": true}); err != nil {
			lock.Unlock()
			resume()
			p.server.Service.detachPeer(p, session.ID)
			return err
		}
		markStep("writeSubscribed")
		if err := p.server.Service.attachOutputLocked(ctx, p, session, anchor, "session.subscribe"); err != nil {
			lock.Unlock()
			resume()
			p.server.Service.detachPeer(p, session.ID)
			return err
		}
		markStep("attachOutputLocked")
		lock.Unlock()
		resume()
		return nil
	case "session.unsubscribe":
		id := stringParam(params, "id")
		p.cancelPendingSubscription(id)
		p.server.Service.detachPeer(p, id)
		if p.attachedSessionID() == id {
			p.detach()
		}
		return p.writeResult(command.ID, map[string]bool{"unsubscribed": true})
	case "session.focus":
		attached, ok := p.attachedSession()
		requestedSessionID := stringParam(params, "id")
		if requestedSessionID != "" {
			// Web can subscribe passively while hidden, so it has no attached
			// control pointer yet. Allow an explicit focus target only when this
			// peer already owns an output subscription for that session; a random
			// id must never become an input or resize lease.
			if attached.ID != requestedSessionID || !ok {
				session, found := p.server.Service.Session(requestedSessionID)
				if !found {
					return fmt.Errorf("session not found: %s", requestedSessionID)
				}
				if !p.hasOutput(requestedSessionID) {
					return fmt.Errorf("session is not subscribed: %s", requestedSessionID)
				}
				attached, ok = session, true
			}
		}
		if !ok {
			return fmt.Errorf("no attached session")
		}
		focused, specified, err := optionalBoolParam(params, "focused")
		if err != nil {
			return err
		}
		if !specified {
			focused = true
		}
		columns, rows, resizeSpecified, err := attachSizeFromParams(params)
		if err != nil {
			return err
		}
		isFocused, resized, err := p.server.Service.focusPeer(
			ctx,
			p,
			attached,
			focused,
			columns,
			rows,
			resizeSpecified && focused,
		)
		if err != nil {
			return err
		}
		if focused {
			if isFocused {
				// Keep the target attached for subsequent focus/resize/input
				// requests. This is a control-lease promotion, not a new output
				// subscription.
				p.claimControl(attached)
			}
		} else {
			p.releaseControl(attached.ID)
		}
		return p.writeResult(command.ID, map[string]bool{
			"focused": isFocused,
			"resized": resized,
		})
	case "session.input":
		encoded := stringParam(params, "data")
		value, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return err
		}
		if err := p.input(ctx, value); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"sent": true})
	case "session.resize":
		attached, ok := p.attachedSession()
		if !ok {
			return fmt.Errorf("no attached session")
		}
		columns := intParam(params, "cols")
		rows := intParam(params, "rows")
		if columns <= 0 || rows <= 0 {
			return fmt.Errorf("invalid terminal size")
		}
		resized, err := p.server.Service.resizeFocused(ctx, p, attached, columns, rows)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"resized": resized})
	case "git.panel":
		panel, err := p.server.Service.GitPanel(ctx, stringParam(params, "workspace"), boolParam(params, "fetch"), boolParam(params, "force"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, panel)
	case "git.diff":
		diff, err := p.server.Service.GitDiff(ctx, stringParam(params, "workspace"), stringParam(params, "path"), boolParam(params, "staged"), stringParam(params, "commit"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, diff)
	case "git.checkout":
		result, err := p.server.Service.GitCheckout(ctx, stringParam(params, "workspace"), stringParam(params, "branch"), boolParam(params, "create"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.pull":
		result, err := p.server.Service.GitPull(ctx, stringParam(params, "workspace"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.push":
		result, err := p.server.Service.GitPush(ctx, stringParam(params, "workspace"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.commit":
		message := strings.TrimSpace(stringParam(params, "message"))
		if message == "" {
			return fmt.Errorf("commit message is required")
		}
		result, err := p.server.Service.GitCommit(ctx, stringParam(params, "workspace"), message)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.pr.create":
		title := strings.TrimSpace(stringParam(params, "title"))
		if title == "" {
			return fmt.Errorf("pull request title is required")
		}
		result, err := p.server.Service.GitCreatePullRequest(ctx, stringParam(params, "workspace"), title, stringParam(params, "body"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	default:
		return fmt.Errorf("unknown method: %s", command.Method)
	}
}

func (p *wsPeer) canonicalCommandSession(ctx context.Context, command api.AgentCommand) (api.Session, api.AgentExecution, error) {
	if strings.TrimSpace(command.CommandID) == "" || strings.TrimSpace(command.ExecutionID) == "" {
		return api.Session{}, api.AgentExecution{}, errors.New("commandId and executionId are required")
	}
	session, ok := p.server.Service.sessionForCanonicalStream(command.ExecutionID)
	if !ok {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("agent execution not found: %s", command.ExecutionID)
	}
	execution, ok := p.server.Service.canonicalExecutionForSession(session.ID)
	if !ok || execution.ID != command.ExecutionID {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("agent execution not found: %s", command.ExecutionID)
	}
	if err := p.requireAgentControl(session.ID); err != nil {
		return api.Session{}, api.AgentExecution{}, err
	}
	admitted, err := p.server.Service.canonicalCommandAdmitted(ctx, command.ExecutionID, command.CommandID)
	if err != nil {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("load canonical command admission: %w", err)
	}
	if !admitted && command.ExpectedVersion > 0 && command.ExpectedVersion != execution.HeadSequence {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("stale expectedVersion: got %d, current %d", command.ExpectedVersion, execution.HeadSequence)
	}
	return session, execution, nil
}

func (p *wsPeer) handleCanonicalExecutionResume(ctx context.Context, command api.Envelope) error {
	base, err := decodeCanonicalCommand(command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, base)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, base.ExecutionID, base.CommandID, base,
		func() (any, error) {
			_, err := p.server.Service.ensureAgent(ctx, session)
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: base.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalTurnStart(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentTurnStartCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			result, err := p.server.Service.sendAgentMessage(ctx, api.AgentMessageSendRequest{
				Session: session.ID, ClientMessageID: request.CommandID,
				Text: request.Text, Attachments: request.Attachments,
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: result.Accepted}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalTurnSteer(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentTurnSteerCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	if request.TurnID == "" {
		return p.writeCanonicalError(command.ID, errors.New("turnId is required"))
	}
	turnID, parseErr := strconv.ParseUint(request.TurnID, 10, 64)
	if parseErr != nil || turnID == 0 {
		return p.writeCanonicalError(command.ID, errors.New("turnId must be a positive integer"))
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			_, err := p.server.Service.interruptAgentTurn(ctx, api.AgentTurnInterruptRequest{
				Session: session.ID, Turn: turnID, Reason: "send_now",
				Replacement: &api.AgentMessageSendRequest{
					Session: session.ID, ClientMessageID: request.CommandID,
					Text: request.Text, Attachments: request.Attachments,
				},
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalTurnCancel(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentTurnCancelCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	turnID, parseErr := strconv.ParseUint(strings.TrimSpace(request.TurnID), 10, 64)
	if parseErr != nil || turnID == 0 {
		return p.writeCanonicalError(command.ID, errors.New("turnId must be a positive integer"))
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			_, err := p.server.Service.interruptAgentTurn(ctx, api.AgentTurnInterruptRequest{
				CommandID: request.CommandID, Session: session.ID, Turn: turnID, Reason: "cancel",
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalInteractionResolve(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentInteractionResolveCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	if strings.TrimSpace(request.InteractionID) == "" || request.Version == 0 {
		return p.writeCanonicalError(command.ID, errors.New("interactionId and version are required"))
	}
	interaction, found := p.server.Service.canonicalInteraction(session.ID, request.InteractionID)
	if !found {
		return p.writeCanonicalError(command.ID, fmt.Errorf("interaction not found: %s", request.InteractionID))
	}
	if request.Version != interaction.version {
		return p.writeCanonicalError(command.ID, &canonicalProtocolError{
			code:    "stale_interaction",
			message: fmt.Sprintf("interaction %s is version %d, not %d", request.InteractionID, interaction.version, request.Version),
			details: map[string]any{"interactionId": request.InteractionID, "currentVersion": interaction.version, "state": interaction.state},
		})
	}
	if interaction.state != "" && interaction.state != "pending" && interaction.state != "submitting" {
		return p.writeCanonicalError(command.ID, &canonicalProtocolError{
			code:    "stale_interaction",
			message: fmt.Sprintf("interaction %s is %s", request.InteractionID, interaction.state),
			details: map[string]any{"interactionId": request.InteractionID, "currentVersion": interaction.version, "state": interaction.state},
		})
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			_, err := p.server.Service.respondAgentInteraction(ctx, api.AgentInteractionResponse{
				CommandID: request.CommandID, Session: session.ID, RequestID: request.InteractionID,
				Kind: interaction.kind, Response: request.Resolution,
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) canonicalAttachmentSession(ctx context.Context, command api.AgentCommand) (api.Session, error) {
	session, _, err := p.canonicalCommandSession(ctx, command)
	if err != nil {
		return api.Session{}, err
	}
	if !p.server.Service.sessionSupportsCapability(session.ID, CapabilityAttachments) {
		return api.Session{}, fmt.Errorf("capability %s is not available for session %s", api.CapabilityAgentAttachments, session.ID)
	}
	return session, nil
}

func (p *wsPeer) handleCanonicalAttachmentPrepare(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentPrepareCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			return p.server.Service.prepareAgentAttachment(ctx, session.ID, api.AgentAttachmentPrepareRequest{
				Session: session.ID, Name: request.Name, MIME: request.MIME, Size: request.Size, SHA256: request.SHA256,
			})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalAttachmentChunk(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentChunkCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			return p.server.Service.putAgentAttachmentChunk(ctx, api.AgentAttachmentChunkRequest{
				Session: session.ID, UploadID: request.UploadID, Sequence: request.Chunk,
				Length: request.Length, SHA256: request.SHA256, Data: request.Data,
			})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalAttachmentComplete(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentCompleteCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			return p.server.Service.completeAgentAttachment(ctx, api.AgentAttachmentCompleteRequest{
				Session: session.ID, UploadID: request.UploadID, Length: request.Length, SHA256: request.SHA256,
			})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalAttachmentAbort(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentAbortCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			return p.server.Service.abortAgentAttachment(ctx, api.AgentAttachmentAbortRequest{Session: session.ID, UploadID: request.UploadID})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) input(ctx context.Context, data []byte) error {
	attached, err := p.controlledSession()
	if err != nil {
		return err
	}
	payload := data
	if len(data) >= len(output.BinaryMagic) && bytes.Equal(data[:len(output.BinaryMagic)], output.BinaryMagic) {
		metadata, decoded, err := output.DecodeInput(data)
		if err != nil {
			return err
		}
		if metadata.SessionID != "" && metadata.SessionID != attached.ID {
			return fmt.Errorf("input session mismatch")
		}
		payload = decoded
	}
	if err := p.server.Service.runtimeFor(attached).Input(ctx, attached.Runtime, payload); err != nil {
		return err
	}
	p.server.Service.PingOutput(attached.ID)
	return nil
}

// attach is the legacy single-subscription attach: it swaps the control
// lease and implicitly unsubscribes the previously attached session so a
// web or mobile client that switches terminals stops receiving the old
// session's frames. Desktop clients use subscribe plus claimControl instead,
// keeping one output subscription per retained warm surface.
func (p *wsPeer) attach(session api.Session) {
	p.detach()
	p.enqueueMu.Lock()
	p.attached = &session
	p.controlSession = session.ID
	p.enqueueMu.Unlock()
}

// claimControl swaps the control lease without touching output
// subscriptions. The desktop keeps its per-surface subscriptions alive
// across tab switches; only input, focus, and resize ownership follow this
// pointer.
func (p *wsPeer) claimControl(session api.Session) {
	p.enqueueMu.Lock()
	p.attached = &session
	p.controlSession = session.ID
	p.enqueueMu.Unlock()
}

func (p *wsPeer) subscribeCanonicalAgent(sessionID, streamID string) error {
	p.enqueueMu.Lock()
	if p.closeFlag {
		p.enqueueMu.Unlock()
		return errors.New("connection is closed")
	}
	previous := p.agentSession
	p.agentSession = sessionID
	if p.canonicalAgentStreams == nil {
		p.canonicalAgentStreams = make(map[string]struct{})
	}
	p.canonicalAgentStreams[streamID] = struct{}{}
	p.enqueueMu.Unlock()
	if previous != "" && previous != sessionID {
		p.server.Service.detachAgentPeer(p, previous)
	}
	p.server.Service.registerAgentPeer(sessionID, p)
	p.enqueueMu.Lock()
	closed := p.closeFlag || p.agentSession != sessionID
	p.enqueueMu.Unlock()
	if closed {
		p.server.Service.detachAgentPeer(p, sessionID)
		return errors.New("connection closed while subscribing to agent")
	}
	return nil
}

func (p *wsPeer) hasCanonicalAgentStream(streamID string) bool {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	_, ok := p.canonicalAgentStreams[streamID]
	return ok
}

func (p *wsPeer) detach() {
	p.enqueueMu.Lock()
	attached := p.attached
	p.attached = nil
	p.controlSession = ""
	p.enqueueMu.Unlock()
	if attached != nil {
		p.server.Service.detachPeer(p, attached.ID)
	}
}

// detachIfAttached releases the control lease only when it still belongs to
// the requested session. Slow lifecycle mutations run concurrently with
// attach/focus requests, so a separate check followed by detach could remove
// a newer session's lease.
func (p *wsPeer) detachIfAttached(sessionID string) {
	p.enqueueMu.Lock()
	if p.attached == nil || p.attached.ID != sessionID {
		p.enqueueMu.Unlock()
		return
	}
	p.attached = nil
	p.controlSession = ""
	p.enqueueMu.Unlock()
	p.server.Service.detachPeer(p, sessionID)
}

func (p *wsPeer) attachedSession() (api.Session, bool) {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	if p.attached == nil {
		return api.Session{}, false
	}
	return *p.attached, true
}

func (p *wsPeer) attachedSessionID() string {
	session, ok := p.attachedSession()
	if !ok {
		return ""
	}
	return session.ID
}

func (p *wsPeer) controlledSession() (api.Session, error) {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	if p.attached == nil {
		return api.Session{}, fmt.Errorf("no attached session")
	}
	if p.controlSession != p.attached.ID {
		return api.Session{}, fmt.Errorf("control lease required")
	}
	return *p.attached, nil
}

// requireAgentControl keeps all mutating Agent View requests behind the same
// per-session control lease as terminal input and resize. Agent subscriptions
// are intentionally passive, so merely seeing a transcript must never grant a
// client the ability to answer an interaction or submit a message.
func (p *wsPeer) requireAgentControl(sessionID string) error {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		// Let the Service return its canonical validation error for malformed
		// requests; no provider call can be made without a session identity.
		return nil
	}
	attached, err := p.controlledSession()
	if err != nil {
		return err
	}
	if attached.ID != sessionID {
		return fmt.Errorf("control lease required for session: %s", sessionID)
	}
	// A focus handoff can replace the service-level owner while the previous
	// peer still has its local attached pointer. Consult the authoritative
	// owner map as well so a stale socket cannot mutate Agent state after the
	// lease moved to another client.
	if p.server != nil && p.server.Service != nil && !p.server.Service.isFocused(p, attached.ID) {
		return fmt.Errorf("control lease required for session: %s", sessionID)
	}
	return nil
}

func (p *wsPeer) addOutput(sessionID string) {
	p.enqueueMu.Lock()
	if p.outputs == nil {
		p.outputs = map[string]struct{}{}
	}
	p.outputs[sessionID] = struct{}{}
	p.enqueueMu.Unlock()
}

func (p *wsPeer) removeOutput(sessionID string) {
	p.enqueueMu.Lock()
	delete(p.outputs, sessionID)
	p.enqueueMu.Unlock()
}

func (p *wsPeer) hasOutput(sessionID string) bool {
	p.enqueueMu.Lock()
	defer p.enqueueMu.Unlock()
	_, ok := p.outputs[sessionID]
	return ok
}

// releaseControl keeps the output subscription alive while dropping the
// control lease. A later explicit session.focus can promote the same target
// again without replaying the terminal state.
func (p *wsPeer) releaseControl(sessionID string) {
	p.enqueueMu.Lock()
	if p.attached != nil && p.attached.ID == sessionID {
		p.controlSession = ""
	}
	p.enqueueMu.Unlock()
}

func stringParam(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return strings.TrimSpace(value)
}

// decodeAgentParams deliberately goes through JSON so requests received from
// WebSocket clients and requests assembled by the Go client share one wire
// shape. It also keeps the legacy string-valued parameter helpers untouched.
func decodeAgentParams[T any](values map[string]any) (T, error) {
	var result T
	data, err := json.Marshal(values)
	if err != nil {
		return result, fmt.Errorf("invalid request parameters: %w", err)
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return result, fmt.Errorf("invalid request parameters: %w", err)
	}
	return result, nil
}

func decodeCanonicalCommand(values map[string]any) (api.AgentCommand, error) {
	command, err := decodeAgentParams[api.AgentCommand](values)
	if err != nil {
		return command, err
	}
	command.CommandID = strings.TrimSpace(command.CommandID)
	command.ExecutionID = strings.TrimSpace(command.ExecutionID)
	command.LeaseID = strings.TrimSpace(command.LeaseID)
	if command.CommandID == "" || command.ExecutionID == "" {
		return command, errors.New("commandId and executionId are required")
	}
	return command, nil
}

func sessionMoveExpectations(values map[string]any) SessionMoveExpectations {
	var result SessionMoveExpectations
	if value, ok := firstParam(values, "expectedWorkspace", "expectedWorkspaceId", "expected-workspace"); ok {
		parsed := strings.TrimSpace(fmt.Sprint(value))
		result.WorkspaceID = &parsed
	}
	if value, ok := firstParam(values, "expectedAgentSession", "expectedAgentSessionId", "expected-agent-session"); ok {
		parsed := strings.TrimSpace(fmt.Sprint(value))
		result.AgentSessionID = &parsed
	}
	return result
}

func firstParam(values map[string]any, keys ...string) (any, bool) {
	for _, key := range keys {
		if value, ok := values[key]; ok {
			return value, true
		}
	}
	return nil, false
}

func stringMapParam(values map[string]any, key string) map[string]string {
	raw, ok := values[key].(map[string]any)
	if !ok {
		return nil
	}
	result := make(map[string]string, len(raw))
	for entryKey, entry := range raw {
		value, ok := entry.(string)
		if !ok {
			continue
		}
		result[entryKey] = value
	}
	return result
}

func stringSliceParam(values map[string]any, key string) []string {
	raw, ok := values[key]
	if !ok {
		return nil
	}
	switch value := raw.(type) {
	case []any:
		result := make([]string, 0, len(value))
		for _, entry := range value {
			if item, ok := entry.(string); ok {
				result = append(result, item)
			}
		}
		return result
	case []string:
		return append([]string(nil), value...)
	case string:
		var result []string
		if json.Unmarshal([]byte(value), &result) == nil {
			return result
		}
	}
	return nil
}

func boolParam(values map[string]any, key string) bool {
	switch value := values[key].(type) {
	case bool:
		return value
	case string:
		parsed, err := strconv.ParseBool(value)
		return err == nil && parsed
	default:
		return false
	}
}

func optionalBoolParam(values map[string]any, key string) (value, specified bool, err error) {
	raw, specified := values[key]
	if !specified {
		return false, false, nil
	}
	switch value := raw.(type) {
	case bool:
		return value, true, nil
	case string:
		parsed, parseErr := strconv.ParseBool(strings.TrimSpace(value))
		if parseErr != nil {
			return false, true, fmt.Errorf("invalid boolean parameter %q", key)
		}
		return parsed, true, nil
	default:
		return false, true, fmt.Errorf("invalid boolean parameter %q", key)
	}
}

func intParam(values map[string]any, key string) int {
	switch value := values[key].(type) {
	case int:
		return value
	case int64:
		return int(value)
	case uint64:
		return int(value)
	case float64:
		return int(value)
	case string:
		result, _ := strconv.Atoi(value)
		return result
	}
	return 0
}

func anchorFromParams(values map[string]any) *output.Anchor {
	epoch, hasEpoch := uint64Param(values, "epoch")
	sequence, hasSequence := uint64Param(values, "sequence")
	if !hasEpoch || !hasSequence {
		return nil
	}
	return &output.Anchor{Epoch: epoch, Sequence: sequence}
}

func uint64Param(values map[string]any, key string) (uint64, bool) {
	switch value := values[key].(type) {
	case int:
		return uint64(value), true
	case int64:
		return uint64(value), true
	case uint64:
		return value, true
	case float64:
		return uint64(value), true
	case string:
		parsed, err := strconv.ParseUint(value, 10, 64)
		return parsed, err == nil
	default:
		return 0, false
	}
}

func attachSizeFromParams(values map[string]any) (columns, rows int, specified bool, err error) {
	_, hasColumns := values["cols"]
	_, hasRows := values["rows"]
	if !hasColumns && !hasRows {
		return 0, 0, false, nil
	}
	columns = intParam(values, "cols")
	rows = intParam(values, "rows")
	if columns <= 0 || rows <= 0 {
		return 0, 0, false, fmt.Errorf("invalid terminal size")
	}
	return columns, rows, true, nil
}
