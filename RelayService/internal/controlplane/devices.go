package controlplane

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

type relayDevice struct {
	ID         string    `json:"id"`
	ClientID   string    `json:"client_id,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
	LastSeenAt time.Time `json:"last_seen_at"`
}

func (server *Server) createEnrollmentKeys(response http.ResponseWriter, request *http.Request) {
	if !secureEqual(bearerToken(request), server.config.AdminToken) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body struct {
		Count   int    `json:"count"`
		TTL     string `json:"ttl"`
		MaxUses int    `json:"max_uses"`
		Label   string `json:"label"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	if body.Count == 0 {
		body.Count = 1
	}
	if strings.TrimSpace(body.TTL) == "" {
		body.TTL = server.config.EnrollmentKeyTTL.String()
	}
	ttl, err := time.ParseDuration(strings.TrimSpace(body.TTL))
	if err != nil {
		http.Error(response, "invalid enrollment key TTL", http.StatusBadRequest)
		return
	}
	if body.MaxUses == 0 {
		body.MaxUses = server.config.EnrollmentKeyMaxUses
	}
	keys, err := server.registry.createEnrollmentKeys(body.Count, ttl, body.MaxUses, body.Label)
	if err != nil {
		http.Error(response, err.Error(), http.StatusBadRequest)
		return
	}
	values := make([]map[string]any, 0, len(keys))
	for _, key := range keys {
		values = append(values, map[string]any{
			"id":           key.ID,
			"key":          key.Code,
			"label":        key.Label,
			"created_at":   key.CreatedAt.UTC().Format(time.RFC3339),
			"expires_at":   key.ExpiresAt.UTC().Format(time.RFC3339),
			"max_uses":     key.MaxUses,
			"used_uses":    key.UsedUses,
			"settings_url": server.relaySettingsURL(key.Code),
		})
	}
	// The response contains bearer enrollment keys and matching settings URLs;
	// prevent intermediary caches from retaining them beyond this request.
	response.Header().Set("Cache-Control", "no-store")
	writeJSON(response, http.StatusCreated, map[string]any{"keys": values})
}

// relaySettingsURL builds a Warren Desktop shortcut containing only the
// Relay origin and a short-lived enrollment key. It never carries a Host ID,
// daemon token, or Relay administrator credential.
func (server *Server) relaySettingsURL(enrollmentKey string) string {
	base := strings.TrimRight(relayPublicOrigin(server.config.PublicURL), "/") + strings.TrimRight(server.basePath, "/")
	values := url.Values{}
	values.Set("section", "relay")
	values.Set("relayUrl", base)
	values.Set("enrollmentKey", enrollmentKey)
	return (&url.URL{Scheme: "warren", Host: "settings", RawQuery: values.Encode()}).String()
}

func (server *Server) claimHost(response http.ResponseWriter, request *http.Request) {
	var body struct {
		EnrollmentKey string `json:"enrollment_key"`
		HostSecret    string `json:"host_secret"`
		Name          string `json:"name"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	keyDigest := hashCredential(strings.TrimSpace(body.EnrollmentKey))
	if !server.pairingLimiter.allow("claim-ip:"+requestClientIP(request), "claim-key:"+keyDigest) {
		writeRateLimit(response, server.config.RateLimitWindow)
		return
	}
	secret := strings.TrimSpace(body.HostSecret)
	hostID, generation, err := server.registry.claimHost(body.EnrollmentKey, secret, body.Name)
	if err != nil {
		http.Error(response, "invalid enrollment", http.StatusUnauthorized)
		return
	}
	server.clearLiveActivityRegistrations(hostID)
	keyID, publicKey := server.signer.currentPublicKey()
	writeJSON(response, http.StatusOK, map[string]any{
		"host_id":          hostID,
		"generation":       generation,
		"enrolled":         true,
		"relay_key_id":     keyID,
		"relay_public_key": base64.RawStdEncoding.EncodeToString(publicKey),
	})
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
	for hash, entry := range server.refreshTokens {
		if entry.HostID == hostID {
			server.revokedFamilies[entry.Family] = true
			delete(server.refreshTokens, hash)
		}
	}
	server.sessionMu.Unlock()
	_ = server.persistSessions()
}

func (server *Server) authorizeHost(request *http.Request, hostID string) bool {
	credential := bearerToken(request)
	return secureEqual(credential, server.config.AdminToken) || server.registry.authenticateHost(hostID, credential)
}

func deviceIDForFamily(family string) string {
	digest := sha256.Sum256([]byte("warren-device:" + family))
	return hex.EncodeToString(digest[:8])
}

func (server *Server) listDevices(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	if !server.authorizeHost(request, hostID) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	server.sessionMu.Lock()
	devices := make([]relayDevice, 0)
	seen := make(map[string]struct{})
	for _, entry := range server.refreshTokens {
		if entry.HostID != hostID || server.revokedFamilies[entry.Family] {
			continue
		}
		id := deviceIDForFamily(entry.Family)
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		created := entry.CreatedAt
		if created.IsZero() {
			created = entry.LastSeenAt
		}
		lastSeen := entry.LastSeenAt
		if lastSeen.IsZero() {
			lastSeen = created
		}
		devices = append(devices, relayDevice{ID: id, ClientID: entry.ClientID, CreatedAt: created, LastSeenAt: lastSeen})
	}
	server.sessionMu.Unlock()
	sort.Slice(devices, func(i, j int) bool { return devices[i].LastSeenAt.After(devices[j].LastSeenAt) })
	writeJSON(response, http.StatusOK, map[string]any{"devices": devices})
}

func (server *Server) revokeDevice(response http.ResponseWriter, request *http.Request) {
	hostID := request.PathValue("hostID")
	if !server.authorizeHost(request, hostID) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	deviceID := strings.TrimSpace(request.PathValue("deviceID"))
	if deviceID == "" {
		http.Error(response, "device not found", http.StatusNotFound)
		return
	}
	server.sessionMu.Lock()
	found := false
	for hash, entry := range server.refreshTokens {
		if entry.HostID == hostID && deviceIDForFamily(entry.Family) == deviceID {
			server.revokedFamilies[entry.Family] = true
			delete(server.refreshTokens, hash)
			found = true
		}
	}
	server.sessionMu.Unlock()
	if !found {
		http.Error(response, "device not found", http.StatusNotFound)
		return
	}
	if err := server.persistSessions(); err != nil {
		http.Error(response, "device revoke failed", http.StatusInternalServerError)
		return
	}
	response.WriteHeader(http.StatusNoContent)
}
