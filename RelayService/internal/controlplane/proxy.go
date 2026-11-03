package controlplane

import (
	"bufio"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

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
	if routePathPrefixConflictsControlPlane(route.PathPrefix) {
		http.Error(response, "invalid path_prefix: conflicts with a Relay control path", http.StatusBadRequest)
		return
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

// routePathPrefixConflictsControlPlane reports prefixes that would be claimed
// by Relay's own ServeMux before the catch-all public route. Public routes must
// stay outside these namespaces so their page, assets, and WebSocket endpoint
// all reach the Host consistently.
func routePathPrefixConflictsControlPlane(raw string) bool {
	prefix := path.Clean("/" + strings.TrimSpace(raw))
	if prefix == "." || prefix == "/" {
		return false
	}
	reservedPaths := []string{
		"/healthz",
		"/v1",
		"/h",
		"/invite",
		"/assets",
		"/manifest.webmanifest",
		"/service-worker.js",
	}
	for resource := range webStaticResources {
		reservedPaths = append(reservedPaths, "/"+resource)
	}
	for _, reserved := range reservedPaths {
		if prefix == reserved || strings.HasPrefix(prefix, reserved+"/") {
			return true
		}
	}
	return false
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
	hostname := requestHostname(request.Host)
	route, ok := server.registry.findRoute(hostname, request.URL.Path)
	forwardPath := request.URL.Path
	if ok {
		if strippedPath, stripped := stripRoutePath(route, request.URL.Path); stripped {
			forwardPath = strippedPath
		}
	}
	// Public application routes never become a backdoor into Relay or the
	// daemon control API. The one exception is the exact WebSocket endpoint
	// used by the credential-free public Web UI; Relay has already selected a
	// live public route before it is allowed through.
	if forwardPath == "/v1" || strings.HasPrefix(forwardPath, "/v1/") ||
		forwardPath == "/h" || strings.HasPrefix(forwardPath, "/h/") {
		publicWebSocket := ok && route.AuthMode == "public" &&
			forwardPath == "/v1/ws" && isUpgradeRequest(request)
		if !publicWebSocket {
			http.NotFound(response, request)
			return
		}
	}
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
	// Keep the route root canonical. A public page served at "/t/id" (without
	// the trailing slash) makes the browser resolve its relative assets at
	// "/t/assets/...", outside the route namespace. Redirect only the exact
	// non-upgrade GET root after policy/auth checks so legacy bookmarks recover
	// without weakening owner-route authorization.
	if !upgrade && request.Method == http.MethodGet {
		prefix := path.Clean(strings.TrimSpace(route.PathPrefix))
		if prefix != "." && prefix != "/" && request.URL.Path == prefix {
			target := prefix + "/"
			if request.URL.RawQuery != "" {
				target += "?" + request.URL.RawQuery
			}
			http.Redirect(response, request, target, http.StatusPermanentRedirect)
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
	if prefix == "." || prefix == "/" {
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
		if hop[lower] || strings.HasPrefix(lower, "x-forwarded-") || strings.HasPrefix(lower, "x-warren-") || lower == "host" || lower == "content-length" || lower == "sec-websocket-extensions" {
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
	open := &streamOpen{
		Class:       "http",
		Version:     "2.0",
		RequestID:   requestID,
		DeadlineMS:  relayStreamDeadline(upgrade),
		RouteID:     route.ID,
		HostID:      route.HostID,
		PublicRoute: route.AuthMode == "public" && upgrade && request.URL.Path == "/v1/ws",
	}
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
