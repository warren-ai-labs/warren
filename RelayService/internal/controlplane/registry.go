package controlplane

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

var hostIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var errHostNotFound = errors.New("host not found")
var errRouteConflict = errors.New("route hostname already owned")

type hostRecord struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	Online          bool      `json:"online"`
	ConnectedAt     time.Time `json:"connected_at,omitempty"`
	LastSeenAt      time.Time `json:"last_seen_at,omitempty"`
	CredentialHash  string    `json:"credential_hash,omitempty"`
	Generation      uint64    `json:"generation"`
	PairingToken    string    `json:"-"`
	PairingUntil    time.Time `json:"-"`
	EnrollmentToken string    `json:"-"`
	EnrollmentUntil time.Time `json:"-"`
	// PairingVersion fences invites issued by an older code when a new code is
	// generated. The version is persisted so a shareable invite remains valid
	// across Relay restarts while still being invalidated by rotation.
	PairingVersion uint64       `json:"pairing_version,omitempty"`
	Route          *routeRecord `json:"route,omitempty"`
	Tunnel         *hostTunnel  `json:"-"`
}

// pairingInviteRecord stores only a digest of the bearer value embedded in a
// shareable URL. The clear-text invite is returned once to the caller and is
// never written to disk, logs, or the Host registry projection.
type pairingInviteRecord struct {
	IDHash         string    `json:"id_hash"`
	HostID         string    `json:"host_id"`
	Generation     uint64    `json:"generation"`
	PairingVersion uint64    `json:"pairing_version"`
	Expires        time.Time `json:"expires_at"`
}

type routeRecord struct {
	ID               string   `json:"route_id"`
	PublicHostname   string   `json:"public_hostname"`
	HostID           string   `json:"host_id"`
	Generation       uint64   `json:"generation"`
	PathPrefix       string   `json:"path_prefix"`
	AuthMode         string   `json:"auth_mode"`
	Enabled          bool     `json:"enabled"`
	AllowCredentials bool     `json:"allow_credentials,omitempty"`
	AllowedMethods   []string `json:"allowed_methods,omitempty"`
	AllowedPaths     []string `json:"allowed_paths,omitempty"`
}

type persistedRegistry struct {
	Hosts   []*hostRecord          `json:"hosts"`
	Invites []*pairingInviteRecord `json:"invites,omitempty"`
}

type registry struct {
	mu      sync.RWMutex
	hosts   map[string]*hostRecord
	invites map[string]pairingInviteRecord
	now     func() time.Time
	dataURL string
}

func newRegistry(dataURL string) (*registry, error) {
	registry := &registry{
		hosts:   make(map[string]*hostRecord),
		invites: make(map[string]pairingInviteRecord),
		now:     time.Now,
		dataURL: dataURL,
	}
	if dataURL == "" {
		return registry, nil
	}
	data, err := os.ReadFile(dataURL)
	if errors.Is(err, os.ErrNotExist) {
		return registry, nil
	}
	if err != nil {
		return nil, err
	}
	var stored persistedRegistry
	if err := json.Unmarshal(data, &stored); err != nil {
		return nil, err
	}
	for _, record := range stored.Hosts {
		if record == nil {
			continue
		}
		record.ID = strings.ToLower(strings.TrimSpace(record.ID))
		if !validHostID(record.ID) {
			continue
		}
		record.Online = false
		record.Tunnel = nil
		record.PairingToken = ""
		record.PairingUntil = time.Time{}
		record.EnrollmentToken = ""
		record.EnrollmentUntil = time.Time{}
		if record.Route != nil {
			route := *record.Route
			route.AllowedMethods = append([]string(nil), route.AllowedMethods...)
			route.AllowedPaths = append([]string(nil), route.AllowedPaths...)
			record.Route = &route
		}
		registry.hosts[record.ID] = record
	}
	now := registry.now()
	for _, invite := range stored.Invites {
		if invite == nil {
			continue
		}
		invite.HostID = strings.ToLower(strings.TrimSpace(invite.HostID))
		if strings.TrimSpace(invite.IDHash) == "" || !validHostID(invite.HostID) || invite.Generation == 0 || invite.PairingVersion == 0 || invite.Expires.IsZero() || !now.Before(invite.Expires) {
			continue
		}
		registry.invites[invite.IDHash] = *invite
	}
	return registry, nil
}

func (registry *registry) provisionHost(id, name string) error {
	if !validHostID(id) {
		return errors.New("invalid host ID")
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	previous := registry.hosts[id]
	record := &hostRecord{ID: id}
	if previous != nil {
		copy := *previous
		record = &copy
	}
	previousTunnel := record.Tunnel
	record.Name = name
	record.Online = false
	record.Tunnel = nil
	record.Generation++
	record.CredentialHash = ""
	var err error
	record.EnrollmentToken, err = randomToken(32)
	if err != nil {
		return err
	}
	record.EnrollmentUntil = registry.now().Add(10 * time.Minute)
	record.PairingToken = ""
	record.PairingUntil = time.Time{}
	record.PairingVersion = 0
	registry.hosts[id] = record
	if err := registry.persistLocked(); err != nil {
		if previous == nil {
			delete(registry.hosts, id)
		} else {
			registry.hosts[id] = previous
		}
		return err
	}
	if previousTunnel != nil {
		previousTunnel.close()
	}
	return nil
}

func (registry *registry) enrollment(id, ticket, secret string) (uint64, error) {
	if strings.TrimSpace(secret) == "" || strings.TrimSpace(ticket) == "" {
		return 0, errors.New("invalid enrollment")
	}
	registry.mu.Lock()
	record := registry.hosts[id]
	if record == nil || record.EnrollmentToken == "" || registry.now().After(record.EnrollmentUntil) ||
		!secureEqual(record.EnrollmentToken, ticket) {
		registry.mu.Unlock()
		return 0, errors.New("invalid enrollment")
	}
	previous := *record
	previousTunnel := record.Tunnel
	record.CredentialHash = hashCredential(secret)
	record.EnrollmentToken = ""
	record.EnrollmentUntil = time.Time{}
	record.Generation++
	record.Online = false
	record.Tunnel = nil
	record.PairingVersion = 0
	if err := registry.persistLocked(); err != nil {
		registry.hosts[id] = &previous
		registry.mu.Unlock()
		return 0, err
	}
	generation := record.Generation
	registry.mu.Unlock()
	if previousTunnel != nil {
		previousTunnel.close()
	}
	return generation, nil
}

func (registry *registry) enrollmentTicket(id string) (string, time.Time, bool) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil || record.EnrollmentToken == "" {
		return "", time.Time{}, false
	}
	return record.EnrollmentToken, record.EnrollmentUntil, true
}

func validHostID(id string) bool { return hostIDPattern.MatchString(id) }

func (registry *registry) authenticateHost(id, credential string) bool {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	return authenticateHostRecord(registry.hosts[id], credential)
}

func authenticateHostRecord(record *hostRecord, credential string) bool {
	if record == nil || record.CredentialHash == "" {
		return false
	}
	provided, err := base64.RawURLEncoding.DecodeString(record.CredentialHash)
	if err != nil {
		return false
	}
	actual := sha256.Sum256([]byte(credential))
	return subtle.ConstantTimeCompare(provided, actual[:]) == 1
}

func (registry *registry) revokeHost(id string) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil {
		return errHostNotFound
	}
	previous := record
	copy := *record
	record = &copy
	previousTunnel := record.Tunnel
	record.Tunnel = nil
	record.Online = false
	record.Generation++
	record.CredentialHash = ""
	record.PairingToken = ""
	record.PairingUntil = time.Time{}
	record.PairingVersion = 0
	record.EnrollmentToken = ""
	record.EnrollmentUntil = time.Time{}
	record.Route = nil
	registry.hosts[id] = record
	if err := registry.persistLocked(); err != nil {
		registry.hosts[id] = previous
		return err
	}
	if previousTunnel != nil {
		previousTunnel.close()
	}
	return nil
}

func (registry *registry) setRoute(id string, route *routeRecord) error {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil {
		return errHostNotFound
	}
	previous := *record
	if route != nil {
		for otherID, other := range registry.hosts {
			if otherID != id && other.Route != nil &&
				normalizeRouteHostname(other.Route.PublicHostname) == normalizeRouteHostname(route.PublicHostname) &&
				routePrefixesOverlap(other.Route.PathPrefix, route.PathPrefix) {
				return errRouteConflict
			}
		}
		copy := *route
		copy.HostID = id
		copy.Generation = record.Generation
		if copy.PathPrefix == "" {
			copy.PathPrefix = "/"
		}
		if copy.AuthMode == "" {
			copy.AuthMode = "owner"
		}
		copy.AllowedMethods = append([]string(nil), copy.AllowedMethods...)
		copy.AllowedPaths = append([]string(nil), copy.AllowedPaths...)
		route = &copy
	}
	record.Route = route
	if err := registry.persistLocked(); err != nil {
		registry.hosts[id] = &previous
		return err
	}
	return nil
}

func (registry *registry) route(id string) (routeRecord, bool) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil || record.Route == nil {
		return routeRecord{}, false
	}
	copy := *record.Route
	copy.AllowedMethods = append([]string(nil), copy.AllowedMethods...)
	copy.AllowedPaths = append([]string(nil), copy.AllowedPaths...)
	return copy, true
}

func (registry *registry) findRoute(hostname, requestPath string) (routeRecord, bool) {
	hostname = normalizeRouteHostname(hostname)
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	var matched routeRecord
	matchedLength := -1
	for _, record := range registry.hosts {
		if record.Route == nil || normalizeRouteHostname(record.Route.PublicHostname) != hostname ||
			!record.Route.Enabled || record.Route.HostID != record.ID || record.Route.Generation != record.Generation {
			continue
		}
		prefix := record.Route.PathPrefix
		if prefix == "" {
			prefix = "/"
		}
		if !routePathMatches(prefix, requestPath) {
			continue
		}
		if len(prefix) < matchedLength {
			continue
		}
		copy := *record.Route
		copy.AllowedMethods = append([]string(nil), copy.AllowedMethods...)
		copy.AllowedPaths = append([]string(nil), copy.AllowedPaths...)
		matched = copy
		matchedLength = len(prefix)
	}
	return matched, matchedLength >= 0
}

func normalizeRouteHostname(hostname string) string {
	hostname = strings.TrimSpace(hostname)
	if strings.HasPrefix(hostname, "[") && strings.HasSuffix(hostname, "]") {
		hostname = strings.TrimSuffix(strings.TrimPrefix(hostname, "["), "]")
	}
	return strings.TrimSuffix(strings.ToLower(hostname), ".")
}

func routePrefixesOverlap(left, right string) bool {
	left = path.Clean(strings.TrimSpace(left))
	right = path.Clean(strings.TrimSpace(right))
	if left == "." {
		left = "/"
	}
	if right == "." {
		right = "/"
	}
	return routePathMatches(left, right) || routePathMatches(right, left)
}

func routePathMatches(prefix, requestPath string) bool {
	if prefix == "" || prefix == "/" {
		return true
	}
	if !strings.HasPrefix(prefix, "/") {
		prefix = "/" + prefix
	}
	return requestPath == prefix || strings.HasPrefix(requestPath, strings.TrimSuffix(prefix, "/")+"/")
}

func (registry *registry) connectHost(id, name, credential string, tunnel *hostTunnel) bool {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now().UTC()
	record := registry.hosts[id]
	// Authentication is repeated under the same lock that publishes the
	// tunnel. A credential can be rotated while the HTTP upgrade is in flight;
	// an earlier preflight check must not let that old socket replace the new
	// Host connection.
	if !authenticateHostRecord(record, credential) {
		return false
	}
	if record.Tunnel != nil && record.Tunnel != tunnel {
		record.Tunnel.close()
	}
	if name != "" {
		record.Name = name
	}
	record.Online = true
	record.ConnectedAt = now
	record.LastSeenAt = now
	record.Tunnel = tunnel
	_ = registry.persistLocked()
	return true
}

func (registry *registry) touchHost(id string, tunnel *hostTunnel) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if record := registry.hosts[id]; record != nil && record.Tunnel == tunnel {
		record.LastSeenAt = registry.now().UTC()
	}
}

func (registry *registry) disconnectHost(id string, tunnel *hostTunnel) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if record := registry.hosts[id]; record != nil && record.Tunnel == tunnel {
		record.Online = false
		record.LastSeenAt = registry.now().UTC()
		record.Tunnel = nil
		_ = registry.persistLocked()
	}
}

func (registry *registry) beginPairing(id string, ttl time.Duration) (string, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil || !record.Online || record.Tunnel == nil {
		return "", errors.New("host offline")
	}
	code, err := randomToken(9)
	if err != nil {
		return "", err
	}
	previous := *record
	record.PairingVersion++
	if record.PairingVersion == 0 {
		// Keep zero reserved for a Host that has never issued a pairing code;
		// wrapping is practically unreachable but should not revive an older
		// ticket if a process is kept alive for an extreme number of rotations.
		record.PairingVersion = 1
	}
	record.PairingToken = code
	record.PairingUntil = registry.now().Add(ttl)
	if err := registry.persistLocked(); err != nil {
		*record = previous
		return "", err
	}
	return code, nil
}

func (registry *registry) consumePairing(id, code string) (uint64, uint64, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil || !record.Online || record.Tunnel == nil {
		return 0, 0, errors.New("host offline")
	}
	if registry.now().After(record.PairingUntil) || record.PairingToken == "" || !secureEqual(record.PairingToken, code) {
		return 0, 0, errors.New("invalid pairing code")
	}
	// Pairing codes are bearer credentials intended for sharing with more than
	// one client. Keep the code valid until PairingUntil; generating a new code
	// replaces the previous one, and Host re-enrollment/revocation clears it.
	return record.Generation, record.PairingVersion, nil
}

// createPairingInvite issues a reusable client-facing bearer value after a
// pairing code has been consumed. Only its hash is persisted; the clear-text
// value is returned to the caller for inclusion in the one-time share action.
func (registry *registry) createPairingInvite(id string, generation, pairingVersion uint64, ttl time.Duration) (string, time.Time, error) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	record := registry.hosts[id]
	if record == nil || !record.Online || record.Tunnel == nil || record.Generation != generation || record.PairingVersion != pairingVersion || pairingVersion == 0 {
		return "", time.Time{}, errors.New("host offline")
	}
	value, err := randomToken(32)
	if err != nil {
		return "", time.Time{}, err
	}
	expires := registry.now().Add(ttl)
	digest := hashCredential(value)
	previous, existed := registry.invites[digest]
	registry.invites[digest] = pairingInviteRecord{
		IDHash:         digest,
		HostID:         id,
		Generation:     generation,
		PairingVersion: pairingVersion,
		Expires:        expires,
	}
	if err := registry.persistLocked(); err != nil {
		if existed {
			registry.invites[digest] = previous
		} else {
			delete(registry.invites, digest)
		}
		return "", time.Time{}, err
	}
	return value, expires, nil
}

// pairingInvite validates an opaque invite and returns its routing metadata.
// The Host must be online and the generation/version must still match, which
// makes re-enrollment, revocation, and pairing rotation invalidate old links.
func (registry *registry) pairingInvite(value string) (pairingInviteRecord, bool) {
	digest := hashCredential(strings.TrimSpace(value))
	if strings.TrimSpace(value) == "" {
		return pairingInviteRecord{}, false
	}
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	invite, ok := registry.invites[digest]
	if !ok || !registry.now().Before(invite.Expires) {
		return pairingInviteRecord{}, false
	}
	record := registry.hosts[invite.HostID]
	if record == nil || !record.Online || record.Tunnel == nil || record.Generation != invite.Generation || record.PairingVersion != invite.PairingVersion {
		return pairingInviteRecord{}, false
	}
	return invite, true
}

func (registry *registry) authorizedTunnel(id string, generation uint64) *hostTunnel {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil || !record.Online || record.Generation != generation {
		return nil
	}
	return record.Tunnel
}

func (registry *registry) generation(id string) (uint64, bool) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil {
		return 0, false
	}
	return record.Generation, true
}

func (registry *registry) pairingVersion(id string) (uint64, bool) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil {
		return 0, false
	}
	return record.PairingVersion, true
}

func (registry *registry) host(id string) (hostRecord, bool) {
	registry.mu.RLock()
	defer registry.mu.RUnlock()
	record := registry.hosts[id]
	if record == nil {
		return hostRecord{}, false
	}
	copy := *record
	copy.Tunnel = nil
	copy.PairingToken = ""
	copy.PairingUntil = time.Time{}
	copy.EnrollmentToken = ""
	copy.EnrollmentUntil = time.Time{}
	if copy.Route != nil {
		route := *copy.Route
		route.AllowedMethods = append([]string(nil), route.AllowedMethods...)
		route.AllowedPaths = append([]string(nil), route.AllowedPaths...)
		copy.Route = &route
	}
	copy.CredentialHash = ""
	return copy, true
}

func (registry *registry) persistLocked() error {
	if registry.dataURL == "" {
		return nil
	}
	stored := persistedRegistry{
		Hosts:   make([]*hostRecord, 0, len(registry.hosts)),
		Invites: make([]*pairingInviteRecord, 0, len(registry.invites)),
	}
	for _, record := range registry.hosts {
		copy := *record
		copy.Online = false
		copy.Tunnel = nil
		copy.PairingToken = ""
		copy.PairingUntil = time.Time{}
		copy.EnrollmentToken = ""
		copy.EnrollmentUntil = time.Time{}
		if copy.Route != nil {
			route := *copy.Route
			route.AllowedMethods = append([]string(nil), route.AllowedMethods...)
			route.AllowedPaths = append([]string(nil), route.AllowedPaths...)
			copy.Route = &route
		}
		stored.Hosts = append(stored.Hosts, &copy)
	}
	for _, invite := range registry.invites {
		copy := invite
		stored.Invites = append(stored.Invites, &copy)
	}
	data, err := json.MarshalIndent(stored, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(registry.dataURL), 0o700); err != nil {
		return err
	}
	temporary := registry.dataURL + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(temporary, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, registry.dataURL)
}

func hashCredential(credential string) string {
	digest := sha256.Sum256([]byte(credential))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}
