package controlplane

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// refreshReuseGrace is how long a consumed refresh capability may be presented
// again before it counts as reuse. A phone that loses the rotation response on
// a weak link only ever holds the previous capability; revoking the family for
// that retry locked the device out until it was paired again. Within the grace,
// and only while the successor has never been used, the retry is answered with
// a fresh successor and the undelivered one is withdrawn, so the family still
// has exactly one live capability.
const refreshReuseGrace = time.Minute

// refreshRetry maps a just-consumed refresh capability to the successor it was
// rotated into. Kept in memory only: a Relay restart simply ends the grace.
type refreshRetry struct {
	Successor string
	Until     time.Time
}

type refreshRecord struct {
	Family     string
	HostID     string
	Generation uint64
	ClientID   string
	CreatedAt  time.Time
	LastSeenAt time.Time
	Expires    time.Time
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
		// Clients open or encode pairing_url. The invite is opaque: Relay
		// resolves it during the exchange and returns the scoped Host identity
		// in the response, so the link never discloses the Host ID.
		"invite_id":          invite,
		"pairing_url":        inviteURL,
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

// exchangeSession trades an opaque invite for a short-lived access capability.
// The invite is the path segment the pairing link carried; it is the only
// pairing credential the Relay accepts, so a QR code never has to disclose the
// Host's record id.
func (server *Server) exchangeSession(response http.ResponseWriter, request *http.Request) {
	if !originAllowed(server.config.AllowedOrigin, request.Header.Get("Origin")) {
		http.Error(response, "origin not allowed", http.StatusForbidden)
		return
	}
	var body struct {
		ClientID string `json:"client_id"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	ticket := strings.TrimSpace(request.PathValue("inviteID"))
	entry, ok := server.registry.pairingInvite(ticket)
	if !ok || ticket == "" {
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
	// The device being paired names the Host after this, the same name the
	// Host reports and Relay already quotes when it is offline.
	if host, ok := server.registry.host(entry.HostID); ok && host.Name != "" {
		result["host_name"] = host.Name
	}
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
	now := time.Now()
	server.sessionMu.Lock()
	server.pruneRefreshRetriesLocked(now)
	entry, ok := server.refreshTokens[hash]
	if ok {
		delete(server.refreshTokens, hash)
		server.usedRefresh[hash] = entry.Family
	}
	if !ok && refresh != "" {
		if retry, retried := server.refreshRetries[hash]; retried && now.Before(retry.Until) {
			if successor, unused := server.refreshTokens[retry.Successor]; unused {
				// The client never received the successor. Withdraw it without
				// recording it as used, so it is merely unknown if it does turn
				// up, and rotate from the same record instead.
				delete(server.refreshTokens, retry.Successor)
				entry, ok = successor, true
			}
		}
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
	if !ok || familyRevoked || refresh == "" || (!entry.Expires.IsZero() && time.Now().After(entry.Expires)) {
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
	server.sessionMu.Lock()
	server.refreshRetries[hash] = refreshRetry{Successor: hashRefresh(next), Until: now.Add(refreshReuseGrace)}
	if nextEntry, ok := server.refreshTokens[hashRefresh(next)]; ok {
		nextEntry.CreatedAt = entry.CreatedAt
		if nextEntry.CreatedAt.IsZero() {
			nextEntry.CreatedAt = time.Now()
		}
		nextEntry.LastSeenAt = time.Now()
		server.refreshTokens[hashRefresh(next)] = nextEntry
	}
	server.sessionMu.Unlock()
	_ = server.persistSessions()
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

func (server *Server) pruneRefreshRetriesLocked(now time.Time) {
	for hash, retry := range server.refreshRetries {
		if !now.Before(retry.Until) {
			delete(server.refreshRetries, hash)
		}
	}
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
	now := time.Now()
	expires := time.Time{}
	if server.config.RefreshTTL > 0 {
		expires = now.Add(server.config.RefreshTTL)
	}
	hash := hashRefresh(value)
	server.refreshTokens[hash] = refreshRecord{Family: family, HostID: hostID, Generation: generation, ClientID: id, CreatedAt: now, LastSeenAt: now, Expires: expires}
	server.sessionMu.Unlock()
	if err := server.persistSessions(); err != nil {
		server.sessionMu.Lock()
		delete(server.refreshTokens, hash)
		server.sessionMu.Unlock()
		return "", err
	}
	return value, nil
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
	maxAge := int(server.config.RefreshTTL.Seconds())
	if server.config.RefreshTTL == 0 {
		// A zero Relay refresh TTL means revocation-controlled lifetime. Keep
		// the browser credential across restarts with a long-lived HttpOnly
		// cookie; native clients persist the same capability in Keychain.
		maxAge = 10 * 365 * 24 * 60 * 60
	}
	http.SetCookie(response, &http.Cookie{Name: "warren_refresh", Value: value, Path: cookiePath, HttpOnly: true, Secure: secure, SameSite: http.SameSiteStrictMode, MaxAge: maxAge})
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
