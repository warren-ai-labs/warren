package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/abcdlsj/bolthole/kinds/wskind"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/remote"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/gorilla/websocket"
)

// remoteShareTTL bounds how long one remote share link can pair new devices.
// The link is a QR code shown on the owner's screen, so it is longer than the
// 60-second LAN PIN window but still short-lived.
const remoteShareTTL = 10 * time.Minute

// RemoteAccess is the Bolthole supervisor as seen by the HTTP layer.
type RemoteAccess interface {
	Status() remote.Status
	Start(relayURL string) error
	Stop()
	Rotate() error
	ConnString(relayURL string, extra url.Values) (string, error)
}

type remoteShareWindow struct {
	invite    string
	expiresAt time.Time
}

// RemoteShare is what Desktop renders as a QR code. Link holds the connect
// code and a pairing invite in its fragment and is a bearer credential until
// ExpiresAt.
type RemoteShare struct {
	Link      string    `json:"link"`
	RelayURL  string    `json:"relayURL"`
	ExpiresAt time.Time `json:"expiresAt"`
	ExpiresIn int       `json:"expiresIn"`
}

// pairedViaRemote marks clients paired through a remote share link.
const pairedViaRemote = "remote"

// RemoteState is the owner-facing remote access projection.
type RemoteState struct {
	remote.Status
	DefaultRelayURL string `json:"defaultRelayURL,omitempty"`
	ConfiguredURL   string `json:"configuredRelayURL,omitempty"`
	// RelaySource is "default" while the Host uses the build's relay and
	// "self-hosted" once it carries its own, so a client can say which one it
	// is on instead of showing a bare URL.
	RelaySource string `json:"relaySource"`
	Devices     int    `json:"devices"`
}

// relayDefaultValue is the explicit way to ask for the build's relay, which
// otherwise happens only when nothing is configured yet. Without it a Host
// that once used its own relay could never go back from the command line.
const relayDefaultValue = "default"

func isRelayDefaultValue(value string) bool {
	return strings.EqualFold(strings.TrimSpace(value), relayDefaultValue)
}

func relaySource(configured string) string {
	if strings.TrimSpace(configured) == "" {
		return "default"
	}
	return "self-hosted"
}

func (s *HTTPServer) remoteState() (RemoteState, error) {
	if s.Remote == nil {
		return RemoteState{}, errors.New("remote access is unavailable")
	}
	value := s.Service.RemoteSettingsSnapshot()
	devices := 0
	for _, client := range s.Service.PairedClientsSnapshot() {
		if client.Via == pairedViaRemote {
			devices++
		}
	}
	return RemoteState{
		Status:          s.Remote.Status(),
		DefaultRelayURL: s.RemoteDefaultRelayURL,
		ConfiguredURL:   value.RelayURL,
		RelaySource:     relaySource(value.RelayURL),
		Devices:         devices,
	}, nil
}

// remoteRelayURL picks the explicit URL, then the configured one, then the
// build's default relay. An explicit "default" skips the configured one.
func (s *HTTPServer) remoteRelayURL(explicit string) (string, error) {
	candidates := []string{explicit}
	if !isRelayDefaultValue(explicit) {
		candidates = append(candidates, s.Service.RemoteSettingsSnapshot().RelayURL)
	}
	candidates = append(candidates, s.RemoteDefaultRelayURL)
	for _, candidate := range candidates {
		if isRelayDefaultValue(candidate) {
			continue
		}
		if strings.TrimSpace(candidate) != "" {
			return remote.NormalizeRelayURL(candidate)
		}
	}
	return "", errors.New("no relay URL is configured")
}

func (s *HTTPServer) remoteEnable(relayURL string) (RemoteState, error) {
	if s.Remote == nil {
		return RemoteState{}, errors.New("remote access is unavailable")
	}
	resolved, err := s.remoteRelayURL(relayURL)
	if err != nil {
		return RemoteState{}, err
	}
	if err := s.Remote.Start(resolved); err != nil {
		return RemoteState{}, err
	}
	stored := ""
	if resolved != s.RemoteDefaultRelayURL {
		stored = resolved
	}
	if err := s.Service.UpdateRemoteSettings(settings.RemoteSettings{Enabled: true, RelayURL: stored}); err != nil {
		return RemoteState{}, err
	}
	return s.remoteState()
}

func (s *HTTPServer) remoteDisable() (RemoteState, error) {
	if s.Remote == nil {
		return RemoteState{}, errors.New("remote access is unavailable")
	}
	s.Remote.Stop()
	value := s.Service.RemoteSettingsSnapshot()
	value.Enabled = false
	if err := s.Service.UpdateRemoteSettings(value); err != nil {
		return RemoteState{}, err
	}
	s.closeRemoteShare()
	return s.remoteState()
}

// remoteRotate replaces the connect code and forgets every device paired
// through remote sharing, then closes their live sessions. LAN pairings are
// independent and untouched.
func (s *HTTPServer) remoteRotate() (RemoteState, error) {
	if s.Remote == nil {
		return RemoteState{}, errors.New("remote access is unavailable")
	}
	s.closeRemoteShare()
	s.pairingMu.Lock()
	clients := s.Service.PairedClientsSnapshot()
	kept := clients[:0:0]
	for _, client := range clients {
		if client.Via != pairedViaRemote {
			kept = append(kept, client)
		}
	}
	err := s.Service.UpdatePairedClients(kept)
	s.pairingMu.Unlock()
	if err != nil {
		return RemoteState{}, err
	}
	if err := s.Remote.Rotate(); err != nil {
		return RemoteState{}, err
	}
	return s.remoteState()
}

// remoteShare opens (or refreshes) the remote pairing window and returns the
// link to show as a QR code. Every device that scans it before it expires
// pairs as its own client with owner authority, matching what a Relay
// invite granted before. A link only reaches the Host through the relay it
// names, so sharing is refused while remote access is off: a link that cannot
// connect off-LAN reads as a broken Host rather than as a disabled feature.
func (s *HTTPServer) remoteShare(relayURL string) (RemoteShare, error) {
	if s.Remote == nil {
		return RemoteShare{}, errors.New("remote access is unavailable")
	}
	if !s.Remote.Status().Enabled {
		return RemoteShare{}, errors.New("remote access is off; enable it with 'warren remote enable' before sharing")
	}
	resolved, err := s.remoteRelayURL(relayURL)
	if err != nil {
		return RemoteShare{}, err
	}
	invite, err := newLANPairingToken()
	if err != nil {
		return RemoteShare{}, err
	}
	expiresAt := time.Now().Add(remoteShareTTL)
	snapshot := s.Service.Store.Snapshot()
	extra := url.Values{}
	extra.Set("host", snapshot.Host.ID)
	extra.Set("invite", invite)
	if name := strings.TrimSpace(snapshot.Host.Name); name != "" {
		extra.Set("name", name)
	}
	link, err := s.Remote.ConnString(resolved, extra)
	if err != nil {
		return RemoteShare{}, err
	}
	s.pairingMu.Lock()
	s.remoteShareWindow = &remoteShareWindow{invite: invite, expiresAt: expiresAt}
	s.pairingMu.Unlock()
	return RemoteShare{
		Link: link, RelayURL: resolved, ExpiresAt: expiresAt,
		ExpiresIn: int(remoteShareTTL / time.Second),
	}, nil
}

func (s *HTTPServer) closeRemoteShare() {
	s.pairingMu.Lock()
	s.remoteShareWindow = nil
	s.pairingMu.Unlock()
}

// remoteInviteValidLocked reports whether invite matches the open remote
// share window. The caller holds pairingMu.
func (s *HTTPServer) remoteInviteValidLocked(invite string, now time.Time) bool {
	window := s.remoteShareWindow
	if window == nil || !now.Before(window.expiresAt) {
		s.remoteShareWindow = nil
		return false
	}
	return subtle.ConstantTimeCompare([]byte(invite), []byte(window.invite)) == 1
}

func (s *HTTPServer) ownerRequest(writer http.ResponseWriter, request *http.Request) bool {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return false
	}
	return true
}

func writeRemoteJSON(writer http.ResponseWriter, value any, err error) {
	if err != nil {
		status := http.StatusBadRequest
		if strings.Contains(err.Error(), "unavailable") {
			status = http.StatusServiceUnavailable
		}
		http.Error(writer, err.Error(), status)
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(value)
}

func decodeRemoteRelayURL(writer http.ResponseWriter, request *http.Request) (string, error) {
	var body struct {
		RelayURL string `json:"relayUrl"`
	}
	if request.ContentLength == 0 {
		return "", nil
	}
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		return "", errors.New("invalid request")
	}
	return body.RelayURL, nil
}

func (s *HTTPServer) handleRemoteStatus(writer http.ResponseWriter, request *http.Request) {
	if !s.ownerRequest(writer, request) {
		return
	}
	value, err := s.remoteState()
	writeRemoteJSON(writer, value, err)
}

func (s *HTTPServer) handleRemoteEnable(writer http.ResponseWriter, request *http.Request) {
	if !s.ownerRequest(writer, request) {
		return
	}
	relayURL, err := decodeRemoteRelayURL(writer, request)
	if err != nil {
		writeRemoteJSON(writer, nil, err)
		return
	}
	value, err := s.remoteEnable(relayURL)
	writeRemoteJSON(writer, value, err)
}

func (s *HTTPServer) handleRemoteDisable(writer http.ResponseWriter, request *http.Request) {
	if !s.ownerRequest(writer, request) {
		return
	}
	value, err := s.remoteDisable()
	writeRemoteJSON(writer, value, err)
}

func (s *HTTPServer) handleRemoteRotate(writer http.ResponseWriter, request *http.Request) {
	if !s.ownerRequest(writer, request) {
		return
	}
	value, err := s.remoteRotate()
	writeRemoteJSON(writer, value, err)
}

func (s *HTTPServer) handleRemoteShare(writer http.ResponseWriter, request *http.Request) {
	if !s.ownerRequest(writer, request) {
		return
	}
	relayURL, err := decodeRemoteRelayURL(writer, request)
	if err != nil {
		writeRemoteJSON(writer, nil, err)
		return
	}
	value, err := s.remoteShare(relayURL)
	writeRemoteJSON(writer, value, err)
}

// handleRemoteDirect serves the Bolthole E2E entry point on the Host's own
// listener: the LAN/tailnet half of remote access. It is unauthenticated at
// the HTTP layer because the Noise handshake itself requires the connect
// code, and `/v1/ws` inside it still requires a paired token.
func (s *HTTPServer) handleRemoteDirect(writer http.ResponseWriter, request *http.Request) {
	if s.RemoteDirect == nil {
		http.NotFound(writer, request)
		return
	}
	s.RemoteDirect.ServeHTTP(writer, request)
}

// ServeRemoteWebSocket serves one `ws` stream from an end-to-end encrypted
// Bolthole session. Only `/v1/ws` is offered: the client authenticates with
// its paired token exactly as it would on a local socket, so holding the
// connect code alone grants nothing beyond pairing with an open invite.
func (s *HTTPServer) ServeRemoteWebSocket(ctx context.Context, conn *wskind.Conn, meta wskind.OpenMeta) {
	path := meta.Path
	if index := strings.IndexByte(path, '?'); index >= 0 {
		path = path[:index]
	}
	if path != "/v1/ws" {
		_ = conn.Close(1008, "unsupported path")
		return
	}
	peer := newStreamPeer(s, func(item outboundMessage) bool {
		op := wskind.OpText
		if item.kind == websocket.BinaryMessage {
			op = wskind.OpBinary
		}
		return conn.Write(op, item.data) == nil
	})
	var authTimer *time.Timer
	closeReason := s.servePeer(ctx, peer, peerTransport{
		read: func() (bool, []byte, error) {
			op, data, err := conn.Read()
			return op == wskind.OpBinary, data, err
		},
		authDeadline: func(deadline time.Time) {
			if authTimer != nil {
				authTimer.Stop()
				authTimer = nil
			}
			if !deadline.IsZero() {
				authTimer = time.AfterFunc(time.Until(deadline), func() {
					conn.Stream().Reset("timeout", "authentication timed out")
				})
			}
		},
	})
	if authTimer != nil {
		authTimer.Stop()
	}
	s.unregisterPeer(peer)
	peer.closeWithReason(closeReason)
	select {
	case <-peer.writerDone:
	case <-time.After(5 * time.Second):
	}
	_ = conn.Close(1000, "")
}

// remoteHealth maps the supervisor status onto the /healthz vocabulary.
func (s *HTTPServer) remoteHealth() api.RelayHealth {
	if s.Remote == nil {
		return api.RelayHealth{State: api.HealthUnconfigured}
	}
	status := s.Remote.Status()
	if !status.Enabled {
		return api.RelayHealth{State: api.HealthUnconfigured}
	}
	state := api.HealthDisconnected
	switch status.State {
	case "connected":
		state = api.HealthConnected
	case "error":
		state = api.HealthError
	}
	return api.RelayHealth{Configured: true, Connected: status.Connected, State: state, LastError: status.LastError}
}
