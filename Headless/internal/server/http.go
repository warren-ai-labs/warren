package server

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
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

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/output"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/tunnel"
	"github.com/gorilla/websocket"
)

const (
	// High-throughput TUI output (codex, long-running builds) can fill a
	// small per-peer queue before a mobile or hidden browser drains it. The
	// queue is deliberately generous: memory is cheap and the only fallback
	// is closing the peer, which today means a visible reanchor.
	outboundQueueCapacity = 8192
	outboundWriteTimeout  = 30 * time.Second
	slowMutationTimeout   = 30 * time.Second
)

type HTTPServer struct {
	Service      *Service
	Token        string
	Logger       *slog.Logger
	Tunnels      *tunnel.Manager
	BuildVersion string
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
}

type rosterMessage struct {
	Type  string    `json:"t"`
	State api.State `json:"state"`
}

func NewHTTPServer(service *Service, token string, logger *slog.Logger) *HTTPServer {
	server := &HTTPServer{
		Service: service,
		Token:   token,
		Logger:  logger,
		peers:   make(map[*wsPeer]struct{}),
		upgrader: websocket.Upgrader{
			ReadBufferSize: 256 * 1024, WriteBufferSize: 256 * 1024,
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
// termination by cloudflared or Tailscale Serve.
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
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"ok":                  true,
			"version":             api.Version,
			"build":               s.BuildVersion,
			"ghostlineVersion":    rpcVersion,
			"ghostlineRPCVersion": rpcVersion,
			"ghostlineTagVersion": s.GhostlineTagVersion,
		})
	})
	mux.HandleFunc("GET /v1/state", s.handleState)
	mux.HandleFunc("GET /v1/ws", s.handleWebSocket)
	mux.HandleFunc("GET /v1/settings", s.handleSettings)
	mux.HandleFunc("PUT /v1/settings", s.handleSettings)
	mux.HandleFunc("POST /v1/maintenance", s.handleMaintenance)
	mux.HandleFunc("GET /v1/tunnels", s.handleTunnels)
	mux.HandleFunc("POST /v1/tunnels/start", s.handleTunnelStart)
	mux.HandleFunc("POST /v1/tunnels/stop", s.handleTunnelStop)
	mux.HandleFunc("GET /v1/public-access", s.handlePublicAccess)
	mux.HandleFunc("POST /v1/public-access/enable", s.handlePublicAccessEnable)
	mux.HandleFunc("POST /v1/public-access/disable", s.handlePublicAccessDisable)
	mux.HandleFunc("POST /v1/public-access/restart", s.handlePublicAccessRestart)
	mux.HandleFunc("GET /", s.handleWebAsset)
	mux.HandleFunc("GET /service-worker.js", s.handleWebAsset)
	mux.HandleFunc("GET /manifest.webmanifest", s.handleWebAsset)
	mux.HandleFunc("GET /assets/", s.handleWebAsset)
	mux.HandleFunc("GET /preset-", s.handleWebAsset)
	mux.HandleFunc("GET /icon", s.handleWebAsset)
	mux.HandleFunc("GET /apple-touch-icon.png", s.handleWebAsset)
	mux.HandleFunc("GET /tls/ca.pem", s.handleCACert)
	return mux
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
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"defaultRuntime":        s.Service.DefaultRuntime,
			"runtimeEnv":            s.Service.Settings.RuntimeEnv,
			"gnarEdge":              safeEdgeURL(s.Service.Settings.GnarEdge),
			"gnarDefaultEdge":       safeEdgeURL(s.gnarDefaultEdge()),
			"gnarEffectiveEdge":     safeEdgeURL(s.gnarEffectiveEdge()),
			"gnarAccount":           s.Service.EffectiveGnarAccount(),
			"gnarConfiguredAccount": s.Service.ConfiguredGnarAccount(),
			"autoOpenShell":         s.Service.Settings.AutoOpenShell,
			"autoStartAI":           s.Service.Settings.AutoStartAI,
		})
	case http.MethodPut:
		var body struct {
			DefaultRuntime string            `json:"defaultRuntime"`
			RuntimeEnv     map[string]string `json:"runtimeEnv"`
			GnarEdge       *string           `json:"gnarEdge"`
			GnarAccount    *string           `json:"gnarAccount"`
			AutoOpenShell  *bool             `json:"autoOpenShell"`
			AutoStartAI    *bool             `json:"autoStartAI"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024)).Decode(&body); err != nil {
			http.Error(writer, "invalid settings", http.StatusBadRequest)
			return
		}
		runtimeEnv := body.RuntimeEnv
		if runtimeEnv == nil {
			runtimeEnv = s.Service.Settings.RuntimeEnv
		}
		gnarEdge := s.Service.Settings.GnarEdge
		if body.GnarEdge != nil {
			gnarEdge = *body.GnarEdge
		}
		var normalizedAccount string
		if body.GnarAccount != nil {
			var err error
			normalizedAccount, err = settings.NormalizeConfiguredGnarAccount(*body.GnarAccount)
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
		}
		if err := s.Service.UpdateSettings(body.DefaultRuntime, runtimeEnv, gnarEdge); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		if body.GnarAccount != nil {
			s.Service.Settings.GnarAccount = normalizedAccount
			if s.Service.SettingsPath != "" {
				if err := settings.Save(s.Service.SettingsPath, s.Service.Settings); err != nil {
					http.Error(writer, err.Error(), http.StatusBadRequest)
					return
				}
			}
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
		if s.Tunnels != nil {
			s.Tunnels.SetGnarEdgeOverride(s.Service.Settings.GnarEdge)
		}
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"defaultRuntime":        s.Service.DefaultRuntime,
			"runtimeEnv":            s.Service.Settings.RuntimeEnv,
			"gnarEdge":              safeEdgeURL(s.Service.Settings.GnarEdge),
			"gnarDefaultEdge":       safeEdgeURL(s.gnarDefaultEdge()),
			"gnarEffectiveEdge":     safeEdgeURL(s.gnarEffectiveEdge()),
			"gnarAccount":           s.Service.EffectiveGnarAccount(),
			"gnarConfiguredAccount": s.Service.ConfiguredGnarAccount(),
			"autoOpenShell":         s.Service.Settings.AutoOpenShell,
			"autoStartAI":           s.Service.Settings.AutoStartAI,
		})
	default:
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *HTTPServer) handleTunnels(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(tunnelResponse(s.Tunnels.Status(), s.Token))
}

func (s *HTTPServer) handleTunnelStart(writer http.ResponseWriter, request *http.Request) {
	s.handleTunnelControl(writer, request, true)
}

func (s *HTTPServer) handleTunnelStop(writer http.ResponseWriter, request *http.Request) {
	s.handleTunnelControl(writer, request, false)
}

func (s *HTTPServer) handleTunnelControl(writer http.ResponseWriter, request *http.Request, start bool) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	var body struct {
		Kind string `json:"kind"`
	}
	if json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024)).Decode(&body) != nil {
		http.Error(writer, "invalid request", http.StatusBadRequest)
		return
	}
	var err error
	if start {
		_, err = s.Tunnels.Start(body.Kind)
	} else {
		err = s.Tunnels.Stop(body.Kind)
	}
	if err != nil {
		http.Error(writer, err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.Service.UpdateTunnelEnabled(body.Kind, start); err != nil {
		http.Error(writer, err.Error(), http.StatusBadRequest)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(tunnelResponse(s.Tunnels.Status(), s.Token))
}

func (s *HTTPServer) handlePublicAccess(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) handlePublicAccessEnable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	var body api.PublicAccessEnableRequest
	if err := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024)).Decode(&body); err != nil {
		s.writePublicAccessError(writer, http.StatusBadRequest, errors.New("invalid public access request"))
		return
	}
	edge := strings.TrimSpace(s.Service.Settings.GnarEdge)
	if body.EdgeURL != nil {
		edge = strings.TrimSpace(*body.EdgeURL)
	}
	if edge != "" {
		if err := tunnel.ValidateEdgeURL(edge); err != nil {
			s.writePublicAccessError(writer, http.StatusBadRequest, err)
			return
		}
	}
	approvalKey := body.ApprovalKey
	if strings.TrimSpace(approvalKey) == "" {
		// enrollmentKey is the legacy JSON spelling for an approval key.
		approvalKey = body.EnrollmentKey
	}
	inviteKey := body.InviteKey
	keyKind := tunnel.LoginKeyKind("")
	keyValue := ""
	if strings.TrimSpace(approvalKey) != "" {
		keyKind = tunnel.LoginKeyApproval
		keyValue = approvalKey
	} else if strings.TrimSpace(inviteKey) != "" {
		keyKind = tunnel.LoginKeyInvite
		keyValue = inviteKey
	}
	if keyValue != "" && s.gnarEffectiveEdge() == "" && edge == "" {
		s.writePublicAccessError(writer, http.StatusBadRequest, errors.New("an Edge URL is required when enrolling gnar"))
		return
	}
	configuredAccount := s.Service.Settings.GnarAccount
	if body.AccountName != nil {
		configuredAccount = *body.AccountName
	}
	normalizedAccount := settings.ConfiguredGnarAccount(configuredAccount)
	if body.AccountName != nil {
		var err error
		normalizedAccount, err = settings.NormalizeConfiguredGnarAccount(configuredAccount)
		if err != nil {
			s.writePublicAccessError(writer, http.StatusBadRequest, err)
			return
		}
	}
	account := settings.EffectiveGnarAccount(normalizedAccount, s.Service.HostName)
	previousEdge := strings.TrimSpace(s.Service.Settings.GnarEdge)
	previousAccount := s.Service.EffectiveGnarAccount()
	if err := s.Service.UpdatePublicAccessConfig(edge, normalizedAccount); err != nil {
		s.writePublicAccessError(writer, http.StatusBadRequest, err)
		return
	}
	if err := s.Service.UpdateTunnelEnabled(tunnel.KindGnar, true); err != nil {
		s.writePublicAccessError(writer, http.StatusBadRequest, err)
		return
	}
	// Keep the effective launcher/release fallback in the manager when the
	// request explicitly clears the persisted override.
	if body.EdgeURL != nil {
		// An explicit empty edge clears the persisted override and returns to
		// the release/launcher default. An omitted edge keeps the current
		// configured override for compatibility with existing callers.
		s.Tunnels.SetGnarEdgeOverride(edge)
	} else if edge != "" {
		s.Tunnels.SetGnarEdge(edge)
	}
	// Re-enrollment or a changed non-secret configuration must not leave an
	// older gnar process serving the previous account or Edge URL.
	if keyValue != "" || previousEdge != edge || previousAccount != account {
		if current, ok := s.Tunnels.Status()[tunnel.KindGnar]; ok && current.Running {
			if err := s.Tunnels.Stop(tunnel.KindGnar); err != nil {
				s.writePublicAccessError(writer, http.StatusBadRequest, err)
				return
			}
		}
	}
	key := []byte(keyValue)
	// Do not retain the request string after converting it to the private
	// stdin buffer. The manager clears this byte slice after login returns.
	body.InviteKey = ""
	body.ApprovalKey = ""
	body.EnrollmentKey = ""
	status, err := s.Tunnels.StartPublicAccessWithKey(edge, account, keyKind, key)
	if err != nil {
		projected := s.publicAccessStatus()
		projected.Error = err.Error()
		if status.Error != "" {
			projected.Error = status.Error
		}
		s.writePublicAccessStatus(writer, http.StatusBadGateway, projected)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) handlePublicAccessDisable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	if err := s.Tunnels.Stop(tunnel.KindGnar); err != nil {
		s.writePublicAccessError(writer, http.StatusBadRequest, err)
		return
	}
	if err := s.Service.UpdateTunnelEnabled(tunnel.KindGnar, false); err != nil {
		s.writePublicAccessError(writer, http.StatusBadRequest, err)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) handlePublicAccessRestart(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.Tunnels == nil {
		http.Error(writer, "tunnel manager unavailable", http.StatusServiceUnavailable)
		return
	}
	edge := s.gnarEffectiveEdge()
	if edge != "" {
		if err := tunnel.ValidateEdgeURL(edge); err != nil {
			s.writePublicAccessError(writer, http.StatusBadRequest, errors.New("Public Access is not configured: "+err.Error()))
			return
		}
	}
	account := s.Service.EffectiveGnarAccount()
	if err := s.Tunnels.Stop(tunnel.KindGnar); err != nil {
		s.writePublicAccessError(writer, http.StatusBadRequest, err)
		return
	}
	if err := s.Service.UpdateTunnelEnabled(tunnel.KindGnar, true); err != nil {
		s.writePublicAccessError(writer, http.StatusBadRequest, err)
		return
	}
	status, err := s.Tunnels.StartPublicAccess(edge, account, nil)
	if err != nil {
		projected := s.publicAccessStatus()
		projected.Error = err.Error()
		if status.Error != "" {
			projected.Error = status.Error
		}
		s.writePublicAccessStatus(writer, http.StatusBadGateway, projected)
		return
	}
	s.writePublicAccessStatus(writer, http.StatusOK, s.publicAccessStatus())
}

func (s *HTTPServer) publicAccessStatus() api.PublicAccessStatus {
	edge := s.gnarEffectiveEdge()
	configuredEdge := strings.TrimSpace(s.Service.Settings.GnarEdge)
	defaultEdge := s.gnarDefaultEdge()
	status := api.PublicAccessStatus{
		EdgeURL:               edge,
		ConfiguredEdgeURL:     configuredEdge,
		DefaultEdgeURL:        defaultEdge,
		UsingDefaultEdge:      configuredEdge == "",
		AccountName:           s.Service.EffectiveGnarAccount(),
		ConfiguredAccountName: s.Service.ConfiguredGnarAccount(),
		UsingDefaultAccount:   s.Service.ConfiguredGnarAccount() == "",
		Enabled:               s.Service.PublicAccessEnabled(),
	}
	if status.EdgeURL != "" {
		if err := tunnel.ValidateEdgeURL(status.EdgeURL); err != nil {
			status.Error = err.Error()
			// Do not echo an invalid Edge URL: it may contain userinfo or other
			// material that must never cross the Public Access API boundary.
			status.EdgeURL = ""
		}
	}
	if status.ConfiguredEdgeURL != "" {
		if err := tunnel.ValidateEdgeURL(status.ConfiguredEdgeURL); err != nil {
			// Never echo a malformed or credential-bearing override through the
			// status API, but retain an actionable configuration error.
			status.ConfiguredEdgeURL = ""
			if status.Error == "" {
				status.Error = err.Error()
			}
		}
	}
	if status.DefaultEdgeURL != "" {
		if err := tunnel.ValidateEdgeURL(status.DefaultEdgeURL); err != nil {
			status.DefaultEdgeURL = ""
			if status.Error == "" {
				status.Error = err.Error()
			}
		}
	}
	if s.Tunnels == nil {
		return status
	}
	if value, ok := s.Tunnels.Status()[tunnel.KindGnar]; ok {
		status.Running = value.Running && value.URL != ""
		if status.Running {
			status.PublicEndpoint = value.URL
		}
		if value.Error != "" {
			status.Error = value.Error
		}
	}
	return status
}

func (s *HTTPServer) gnarDefaultEdge() string {
	if s.Tunnels != nil {
		if edge := s.Tunnels.GnarDefaultEdge(); edge != "" {
			return edge
		}
	}
	return settings.BuiltInGnarEdge()
}

func (s *HTTPServer) gnarEffectiveEdge() string {
	if s.Tunnels != nil {
		if edge := s.Tunnels.GnarEdge(); edge != "" || strings.TrimSpace(s.Service.Settings.GnarEdge) == "" {
			return edge
		}
	}
	return strings.TrimSpace(s.Service.Settings.GnarEdge)
}

func safeEdgeURL(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || tunnel.ValidateEdgeURL(value) != nil {
		return ""
	}
	return value
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

func tunnelResponse(status map[string]tunnel.Status, token string) map[string]any {
	result := make(map[string]any, len(status))
	for kind, value := range status {
		item := map[string]any{"running": value.Running}
		if value.URL != "" {
			item["url"] = value.URL
			item["web_url"] = value.URL + "#t=" + token
		}
		if value.Error != "" {
			item["error"] = value.Error
		}
		result[kind] = item
	}
	return map[string]any{"tunnels": result}
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
	if err := connection.ReadJSON(&envelope); err != nil || envelope.Type != "auth" || !s.authorized(envelope.Token) {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	s.registerPeer(peer)
	if envelope.Version != "" && !compatibleProtocolVersion(envelope.Version, api.Version) {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: fmt.Sprintf(
			"incompatible protocol version: client=%s server=%s", envelope.Version, api.Version,
		)})
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	state, revision := s.Service.RosterVersion(request.Context())
	if err := peer.writeJSON(map[string]any{"t": "welcome", "version": api.Version, "host": state.Host}); err != nil {
		return
	}
	_ = peer.writeJSON(makeRoster(state))
	peer.startRoster(request.Context(), state, revision)
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
		if err := peer.handle(request.Context(), command); err != nil {
			_ = peer.writeError(command.ID, err)
		}
	}
}

func isSlowMutation(method string) bool {
	switch method {
	case "project.remove", "workspace.remove":
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

func compatibleProtocolVersion(client, server string) bool {
	clientMajor := strings.SplitN(client, ".", 2)[0]
	serverMajor := strings.SplitN(server, ".", 2)[0]
	return clientMajor != "" && clientMajor == serverMajor
}

func (s *HTTPServer) authorized(value string) bool {
	return value != "" && subtle.ConstantTimeCompare([]byte(value), []byte(s.Token)) == 1
}

type outboundMessage struct {
	kind int
	data []byte
}

// wsPeer owns an independent outbound queue and writer goroutine. A slow
// client only fills its own queue; overflow or a write timeout closes exactly
// this peer, and the client reconnects from its last Recovery Anchor.
type wsPeer struct {
	server     *HTTPServer
	connection *websocket.Conn
	outbound   chan outboundMessage

	enqueueMu      sync.Mutex
	closed         chan struct{}
	closeFlag      bool
	attached       *api.Session
	controlSession string
	agentSession   string
	rosterCancel   context.CancelFunc
}

func (p *wsPeer) logInfo(message string, args ...any) {
	if p.server.Logger != nil {
		p.server.Logger.Info(message, args...)
	}
}

func newWSPeer(server *HTTPServer, connection *websocket.Conn) *wsPeer {
	peer := &wsPeer{
		server:     server,
		connection: connection,
		outbound:   make(chan outboundMessage, outboundQueueCapacity),
		closed:     make(chan struct{}),
	}
	go peer.writeLoop()
	return peer
}

func (p *wsPeer) close() {
	p.enqueueMu.Lock()
	sessionID, agentSessionID := p.closeLocked()
	p.enqueueMu.Unlock()
	if sessionID != "" {
		p.server.Service.detachPeer(p, sessionID)
	}
	if agentSessionID != "" {
		p.server.Service.detachAgentPeer(p, agentSessionID)
	}
}

func (p *wsPeer) writeLoop() {
	for item := range p.outbound {
		_ = p.connection.SetWriteDeadline(time.Now().Add(outboundWriteTimeout))
		if err := p.connection.WriteMessage(item.kind, item.data); err != nil {
			p.close()
			return
		}
	}
	// The channel closed after a peer teardown; let the writer flush the
	// already-queued final messages (for example the auth error) before
	// releasing the socket.
	_ = p.connection.Close()
}

func (p *wsPeer) enqueue(item outboundMessage) bool {
	p.enqueueMu.Lock()
	select {
	case <-p.closed:
		p.enqueueMu.Unlock()
		return false
	default:
	}
	select {
	case p.outbound <- item:
		p.enqueueMu.Unlock()
		return true
	default:
		// Queue overflow is a per-client failure: close only this peer. The
		// client reconnects with its Recovery Anchor and Host re-serves the
		// retained tail from the ring.
		sessionID, agentSessionID := p.closeLocked()
		p.enqueueMu.Unlock()
		if sessionID != "" {
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
// exactly once.
// closeLocked must be called with enqueueMu held. It returns terminal and
// agent-only subscription IDs so the caller can unregister after releasing
// the lock, keeping registry lock ordering acyclic.
func (p *wsPeer) closeLocked() (string, string) {
	if p.closeFlag {
		agentSessionID := p.agentSession
		if p.attached != nil {
			return p.attached.ID, agentSessionID
		}
		return "", agentSessionID
	}
	p.closeFlag = true
	if p.rosterCancel != nil {
		p.rosterCancel()
		p.rosterCancel = nil
	}
	sessionID := ""
	if p.attached != nil {
		sessionID = p.attached.ID
	}
	close(p.closed)
	close(p.outbound)
	return sessionID, p.agentSession
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

func (p *wsPeer) enqueueAgentEvents(sessionID string, events []api.AgentEvent) error {
	return p.writeJSON(api.AgentMessage{
		Type:    "agent",
		Session: sessionID,
		Epoch:   p.server.Service.currentAgentEpoch(),
		Events:  events,
	})
}

func (p *wsPeer) enqueueAgentActivity(sessionID string, activity api.AgentActivity) error {
	return p.writeJSON(api.AgentActivityMessage{
		Type:     "agent.activity",
		Session:  sessionID,
		Epoch:    p.server.Service.currentAgentEpoch(),
		Activity: activity,
	})
}

func (p *wsPeer) enqueueAgentTurn(sessionID string, turn api.AgentTurn) error {
	return p.writeJSON(api.AgentTurnMessage{
		Type:    "agent.turn",
		Session: sessionID,
		Epoch:   p.server.Service.currentAgentEpoch(),
		Turn:    turn.ID,
		Status:  turn.Status,
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

func (p *wsPeer) startRoster(parent context.Context, initial api.State, initialRevision uint64) {
	ctx, cancel := context.WithCancel(parent)
	p.rosterCancel = cancel
	go func() {
		ticker := time.NewTicker(750 * time.Millisecond)
		defer ticker.Stop()
		state := initial
		revision := initialRevision
		var last []byte
		for {
			data, _ := json.Marshal(makeRoster(state))
			if !bytes.Equal(data, last) {
				last = append(last[:0], data...)
				if !p.enqueue(outboundMessage{kind: websocket.TextMessage, data: data}) {
					p.close()
					return
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-p.server.Service.Store.ChangesSince(revision):
				state, revision = p.server.Service.RosterVersion(ctx)
			case <-ticker.C:
				state, revision = p.server.Service.RosterVersion(ctx)
			}
		}
	}()
}

func makeRoster(state api.State) rosterMessage {
	return rosterMessage{Type: "roster", State: state}
}

func (p *wsPeer) handle(ctx context.Context, command api.Envelope) error {
	if command.Type != "request" {
		return fmt.Errorf("unsupported message type: %s", command.Type)
	}
	params := command.Params
	switch command.Method {
	case "roster":
		return p.writeResult(command.ID, p.server.Service.Roster(ctx))
	case "agent.history":
		sessionID := stringParam(params, "session")
		if sessionID == "" {
			return fmt.Errorf("session parameter required")
		}
		before, _ := uint64Param(params, "before")
		limit := intParam(params, "limit")
		return p.writeResult(command.ID, p.server.Service.agentHistoryPage(sessionID, before, limit))
	case "agent.snapshot":
		sessionID := stringParam(params, "session")
		if sessionID == "" {
			return fmt.Errorf("session parameter required")
		}
		return p.writeResult(command.ID, p.server.Service.agentSnapshot(sessionID))
	case "agent.turn.events":
		sessionID := stringParam(params, "session")
		if sessionID == "" {
			return fmt.Errorf("session parameter required")
		}
		turn, _ := uint64Param(params, "turn")
		if turn == 0 {
			return fmt.Errorf("turn parameter required")
		}
		return p.writeResult(command.ID, p.server.Service.agentTurnEvents(sessionID, turn))
	case "agent.subscribe":
		sessionID := stringParam(params, "session")
		session, ok := p.server.Service.Session(sessionID)
		if !ok {
			return fmt.Errorf("session not found: %s", sessionID)
		}
		if session.Lifecycle != "running" {
			return fmt.Errorf("session is not running: %s", sessionID)
		}
		entry, err := p.server.Service.ensureAgent(ctx, session)
		if err != nil {
			return err
		}
		if entry == nil {
			return fmt.Errorf("session is not bound to an agent: %s", sessionID)
		}
		if err := p.server.Service.waitAgentReady(ctx, sessionID); err != nil {
			return err
		}
		lock := p.server.Service.broadcastLock(sessionID)
		if err := lock.LockContext(ctx); err != nil {
			return err
		}
		snapshot := p.server.Service.agentSnapshot(sessionID)
		err = p.subscribeAgent(sessionID)
		lock.Unlock()
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, api.AgentSubscriptionResult{Session: session, Snapshot: snapshot})
	case "settings.get":
		return p.writeResult(command.ID, map[string]any{
			"defaultRuntime":        p.server.Service.DefaultRuntime,
			"runtimeEnv":            p.server.Service.Settings.RuntimeEnv,
			"gnarEdge":              safeEdgeURL(p.server.Service.Settings.GnarEdge),
			"gnarDefaultEdge":       safeEdgeURL(p.server.gnarDefaultEdge()),
			"gnarEffectiveEdge":     safeEdgeURL(p.server.gnarEffectiveEdge()),
			"gnarAccount":           p.server.Service.EffectiveGnarAccount(),
			"gnarConfiguredAccount": p.server.Service.ConfiguredGnarAccount(),
			"autoOpenShell":         p.server.Service.Settings.AutoOpenShell,
			"autoStartAI":           p.server.Service.Settings.AutoStartAI,
		})
	case "settings.put":
		runtimeEnv := stringMapParam(params, "runtimeEnv")
		if runtimeEnv == nil {
			runtimeEnv = p.server.Service.Settings.RuntimeEnv
		}
		gnarEdge := p.server.Service.Settings.GnarEdge
		if _, specified := params["gnarEdge"]; specified {
			gnarEdge = stringParam(params, "gnarEdge")
		}
		var normalizedAccount string
		if _, specified := params["gnarAccount"]; specified {
			var err error
			normalizedAccount, err = settings.NormalizeConfiguredGnarAccount(stringParam(params, "gnarAccount"))
			if err != nil {
				return err
			}
		}
		if err := p.server.Service.UpdateSettings(stringParam(params, "defaultRuntime"), runtimeEnv, gnarEdge); err != nil {
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
		if p.server.Tunnels != nil {
			p.server.Tunnels.SetGnarEdgeOverride(p.server.Service.Settings.GnarEdge)
		}
		if _, specified := params["gnarAccount"]; specified {
			p.server.Service.Settings.GnarAccount = normalizedAccount
			if p.server.Service.SettingsPath != "" {
				if err := settings.Save(p.server.Service.SettingsPath, p.server.Service.Settings); err != nil {
					return err
				}
			}
		}
		return p.writeResult(command.ID, map[string]any{
			"defaultRuntime":        p.server.Service.DefaultRuntime,
			"runtimeEnv":            p.server.Service.Settings.RuntimeEnv,
			"gnarEdge":              safeEdgeURL(p.server.Service.Settings.GnarEdge),
			"gnarDefaultEdge":       safeEdgeURL(p.server.gnarDefaultEdge()),
			"gnarEffectiveEdge":     safeEdgeURL(p.server.gnarEffectiveEdge()),
			"gnarAccount":           p.server.Service.EffectiveGnarAccount(),
			"gnarConfiguredAccount": p.server.Service.ConfiguredGnarAccount(),
			"autoOpenShell":         p.server.Service.Settings.AutoOpenShell,
			"autoStartAI":           p.server.Service.Settings.AutoStartAI,
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
		value, err := p.server.Service.CreateWorkspace(stringParam(params, "project"), stringParam(params, "branch"), stringParam(params, "name"), stringParam(params, "path"))
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
			value, err = p.server.Service.CreateGroupSession(
				ctx,
				groupID,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
			)
		} else if workspaceID != "" {
			value, err = p.server.Service.CreateSession(
				ctx,
				workspaceID,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
			)
		} else {
			value, err = p.server.Service.CreateDefaultGroupSession(
				ctx,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
			)
		}
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "session.delete":
		id := stringParam(params, "id")
		if err := p.server.Service.DeleteSession(ctx, id); err != nil {
			return err
		}
		if p.attached != nil && p.attached.ID == id {
			p.detach()
		}
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
		return p.writeResult(command.ID, value)
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
		return p.writeResult(command.ID, value)
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
		return p.writeResult(command.ID, value)
	case "session.undo":
		value, err := p.server.Service.UndoSessionMove(stringParam(params, "operation"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "session.attach":
		id := stringParam(params, "id")
		session, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		if session.Lifecycle != "running" {
			return fmt.Errorf("session is not running: %s", id)
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
		// A passive attach (focused=false) still carries the client's viewport
		// size. When nobody owns focus, resize the shared runtime before the
		// reanchor snapshot so soft-wrapped history is captured at the same
		// width Ghostty will replay it. If another endpoint owns focus, leave
		// the runtime alone and let that endpoint's focus handoff resize later.
		if specified && focusSpecified && !focused && !p.server.Service.hasFocusedPeer(session.ID) {
			if _, err := p.server.Service.resizeRuntime(ctx, session, columns, rows); err != nil {
				lock.Unlock()
				resume()
				p.detach()
				return err
			}
		}
		p.logInfo("attach: resize done", "session", id)
		if err := p.writeResult(command.ID, session); err != nil {
			lock.Unlock()
			resume()
			p.detach()
			return err
		}
		p.logInfo("attach: result sent", "session", id)
		anchor := anchorFromParams(params)
		if err := p.server.Service.attachOutputLocked(ctx, p, session, anchor); err != nil {
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
	case "session.focus":
		if p.attached == nil {
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
			*p.attached,
			focused,
			columns,
			rows,
			resizeSpecified && focused,
		)
		if err != nil {
			return err
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
		if p.attached == nil {
			return fmt.Errorf("no attached session")
		}
		columns := intParam(params, "cols")
		rows := intParam(params, "rows")
		if columns <= 0 || rows <= 0 {
			return fmt.Errorf("invalid terminal size")
		}
		resized, err := p.server.Service.resizeFocused(ctx, p, *p.attached, columns, rows)
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

func (p *wsPeer) requireControl() error {
	if p.attached == nil {
		return fmt.Errorf("no attached session")
	}
	if p.controlSession != p.attached.ID {
		return fmt.Errorf("control lease required")
	}
	return nil
}

func (p *wsPeer) input(ctx context.Context, data []byte) error {
	if err := p.requireControl(); err != nil {
		return err
	}
	payload := data
	if len(data) >= len(output.BinaryMagic) && bytes.Equal(data[:len(output.BinaryMagic)], output.BinaryMagic) {
		metadata, decoded, err := output.DecodeInput(data)
		if err != nil {
			return err
		}
		if metadata.SessionID != "" && metadata.SessionID != p.attached.ID {
			return fmt.Errorf("input session mismatch")
		}
		payload = decoded
	}
	if err := p.server.Service.runtimeFor(*p.attached).Input(ctx, p.attached.Runtime, payload); err != nil {
		return err
	}
	p.server.Service.PingOutput(p.attached.ID)
	return nil
}

// attach only changes the peer's local projection and takes the Control
// Lease for the session. It never touches the tmux session lifetime; detach
// later only unsubscribes output.
func (p *wsPeer) attach(session api.Session) {
	p.detach()
	p.attached = &session
	p.controlSession = session.ID
}

func (p *wsPeer) subscribeAgent(sessionID string) error {
	p.enqueueMu.Lock()
	if p.closeFlag {
		p.enqueueMu.Unlock()
		return errors.New("connection is closed")
	}
	previous := p.agentSession
	p.agentSession = sessionID
	p.enqueueMu.Unlock()
	if previous != "" && previous != sessionID {
		p.server.Service.detachAgentPeer(p, previous)
	}
	p.server.Service.registerAgentPeer(sessionID, p)

	// A writer failure can close the peer between the local assignment and
	// registry insertion. Recheck and remove the late registration if needed.
	p.enqueueMu.Lock()
	closed := p.closeFlag || p.agentSession != sessionID
	p.enqueueMu.Unlock()
	if closed {
		p.server.Service.detachAgentPeer(p, sessionID)
		return errors.New("connection closed while subscribing to agent")
	}
	return nil
}

func (p *wsPeer) detach() {
	if p.attached != nil {
		p.server.Service.detachPeer(p, p.attached.ID)
	}
	p.attached = nil
	p.controlSession = ""
}

func stringParam(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return strings.TrimSpace(value)
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
