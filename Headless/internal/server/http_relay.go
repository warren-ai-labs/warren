package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/relay"
	"github.com/gorilla/websocket"
)

type relayControlPeer struct {
	peer          *wsPeer
	open          relay.StreamOpen
	stateMu       sync.Mutex
	authenticated bool
	ctx           context.Context
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
		peer.clientID = auth.ClientID
		// Relay control already carries a capability minted by the Host/Relay
		// trust boundary. Preserve its historical settings access.
		peer.ownerAuthenticated = true
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
		backgroundContext := backgroundRequestContext(ctx, command.Method)
		go func(backgroundContext context.Context) {
			if err := peer.handle(backgroundContext, command); err != nil {
				_ = peer.writeError(command.ID, err)
			}
		}(backgroundContext)
		return nil
	}
	if key := orderedRequestKey(command); key != "" {
		if !s.ordered.submit(key, func() {
			if err := peer.handle(ctx, command); err != nil {
				_ = peer.writeError(command.ID, err)
			}
		}) {
			return peer.writeError(command.ID, errTooManyQueuedRequests)
		}
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
	entry.peer.closeWithReason("relay_disconnect")
}
