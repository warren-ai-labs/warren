package controlplane

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type liveActivityRegistration struct {
	SessionID string
	Token     string
	ClientID  string
	UpdatedAt time.Time
}

type liveActivityRegistrationRequest struct {
	SessionID string `json:"session_id"`
	PushToken string `json:"push_token"`
}

type liveActivityUnregistrationRequest struct {
	SessionID string `json:"session_id"`
	PushToken string `json:"push_token"`
}

type liveActivitySession struct {
	ID         string `json:"id"`
	Title      string `json:"title,omitempty"`
	Connection string `json:"connection"`
	Activity   string `json:"activity,omitempty"`
	Attention  bool   `json:"attention,omitempty"`
}

type liveActivitySnapshot struct {
	Connection            string                `json:"connection"`
	ActiveSessionCount    int                   `json:"activeSessionCount"`
	WorkingSessionCount   int                   `json:"workingSessionCount"`
	AttentionSessionCount int                   `json:"attentionSessionCount"`
	Sessions              []liveActivitySession `json:"sessions"`
	UpdatedAt             time.Time             `json:"updatedAt"`
}

func (server *Server) registerLiveActivity(response http.ResponseWriter, request *http.Request) {
	hostID := strings.ToLower(strings.TrimSpace(request.PathValue("hostID")))
	if !validHostID(hostID) {
		http.Error(response, "invalid host_id", http.StatusBadRequest)
		return
	}
	claims, err := server.verifyScopedAccess(strings.TrimSpace(bearerToken(request)), hostID, "control", "")
	if err != nil {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	if !server.clientLimiter.allow("ip:"+requestClientIP(request), "host:"+hostID) {
		writeRateLimit(response, server.config.RateLimitWindow)
		return
	}
	var body liveActivityRegistrationRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	sessionID := strings.TrimSpace(body.SessionID)
	pushToken := strings.ToLower(strings.TrimSpace(body.PushToken))
	if sessionID == "" || len(sessionID) > 256 || !validPushToken(pushToken) {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	registration := liveActivityRegistration{
		SessionID: sessionID,
		Token:     pushToken,
		ClientID:  claims.ClientID,
		UpdatedAt: time.Now().UTC(),
	}
	server.liveActivityMu.Lock()
	if server.liveActivities[hostID] == nil {
		server.liveActivities[hostID] = make(map[string]liveActivityRegistration)
	}
	server.liveActivities[hostID][pushToken] = registration
	server.liveActivityMu.Unlock()
	writeJSON(response, http.StatusOK, map[string]any{
		"registered": true,
		"session_id": sessionID,
	})
}

func (server *Server) unregisterLiveActivity(response http.ResponseWriter, request *http.Request) {
	hostID := strings.ToLower(strings.TrimSpace(request.PathValue("hostID")))
	if !validHostID(hostID) {
		http.Error(response, "invalid host_id", http.StatusBadRequest)
		return
	}
	claims, err := server.verifyScopedAccess(strings.TrimSpace(bearerToken(request)), hostID, "control", "")
	if err != nil {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	var body liveActivityUnregistrationRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	sessionID := strings.TrimSpace(body.SessionID)
	pushToken := strings.ToLower(strings.TrimSpace(body.PushToken))
	if sessionID == "" && pushToken == "" {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	if pushToken != "" && !validPushToken(pushToken) {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	removed := false
	server.liveActivityMu.Lock()
	registrations := server.liveActivities[hostID]
	for token, registration := range registrations {
		if pushToken != "" && token != pushToken {
			continue
		}
		if sessionID != "" && registration.SessionID != sessionID {
			continue
		}
		if registration.ClientID != "" && registration.ClientID != claims.ClientID {
			continue
		}
		delete(registrations, token)
		removed = true
	}
	if len(registrations) == 0 {
		delete(server.liveActivities, hostID)
	}
	server.liveActivityMu.Unlock()
	writeJSON(response, http.StatusOK, map[string]any{"unregistered": removed})
}

// publishLiveActivity accepts a complete Host snapshot authenticated with the
// Host Secret. Unlike client registration, this endpoint is not rate-limited:
// a daemon may publish one compact snapshot per second while an Agent runs.
func (server *Server) publishLiveActivity(response http.ResponseWriter, request *http.Request) {
	hostID := strings.ToLower(strings.TrimSpace(request.PathValue("hostID")))
	if !validHostID(hostID) || !server.registry.authenticateHost(hostID, strings.TrimSpace(bearerToken(request))) {
		http.Error(response, "unauthorized", http.StatusUnauthorized)
		return
	}
	var snapshot liveActivitySnapshot
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 512*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&snapshot); err != nil {
		http.Error(response, "invalid request", http.StatusBadRequest)
		return
	}
	if err := validateLiveActivitySnapshot(&snapshot); err != nil {
		http.Error(response, err.Error(), http.StatusBadRequest)
		return
	}
	sent, failed, removed := server.deliverLiveActivity(hostID, snapshot)
	writeJSON(response, http.StatusOK, map[string]any{
		"configured": server.apns != nil,
		"registered": server.liveActivityRegistrationCount(hostID),
		"sent":       sent,
		"failed":     failed,
		"removed":    removed,
	})
}

func validateLiveActivitySnapshot(snapshot *liveActivitySnapshot) error {
	if snapshot == nil {
		return errors.New("invalid request")
	}
	if snapshot.Connection == "" {
		snapshot.Connection = "connected"
	}
	switch snapshot.Connection {
	case "connecting", "connected", "reconnecting", "disconnected", "stopped":
	default:
		return fmt.Errorf("invalid connection state")
	}
	if snapshot.ActiveSessionCount < 0 || snapshot.WorkingSessionCount < 0 || snapshot.AttentionSessionCount < 0 ||
		snapshot.ActiveSessionCount > 10000 || snapshot.WorkingSessionCount > 10000 || snapshot.AttentionSessionCount > 10000 {
		return errors.New("invalid session counts")
	}
	seen := make(map[string]struct{}, len(snapshot.Sessions))
	for index := range snapshot.Sessions {
		session := &snapshot.Sessions[index]
		session.ID = strings.TrimSpace(session.ID)
		session.Title = strings.TrimSpace(session.Title)
		session.Connection = strings.TrimSpace(session.Connection)
		if session.ID == "" || len(session.ID) > 256 {
			return errors.New("invalid session")
		}
		if _, exists := seen[session.ID]; exists {
			return errors.New("duplicate session")
		}
		seen[session.ID] = struct{}{}
		if session.Connection == "" {
			session.Connection = snapshot.Connection
		}
		switch session.Connection {
		case "connecting", "connected", "reconnecting", "disconnected", "stopped":
		default:
			return errors.New("invalid session connection")
		}
	}
	if snapshot.UpdatedAt.IsZero() {
		snapshot.UpdatedAt = time.Now().UTC()
	}
	return nil
}

func (server *Server) deliverLiveActivity(hostID string, snapshot liveActivitySnapshot) (sent, failed, removed int) {
	server.liveActivityMu.RLock()
	registrations := make([]liveActivityRegistration, 0, len(server.liveActivities[hostID]))
	for _, registration := range server.liveActivities[hostID] {
		registrations = append(registrations, registration)
	}
	server.liveActivityMu.RUnlock()
	if len(registrations) == 0 || server.apns == nil {
		return 0, 0, 0
	}
	sessions := make(map[string]liveActivitySession, len(snapshot.Sessions))
	for _, session := range snapshot.Sessions {
		sessions[session.ID] = session
	}
	now := time.Now().UTC()
	for _, registration := range registrations {
		session, exists := sessions[registration.SessionID]
		connection := "stopped"
		event := "end"
		title := ""
		attention := false
		if exists {
			connection = session.Connection
			title = session.Title
			attention = session.Attention
			if connection != "stopped" {
				event = "update"
			}
		}
		state := apnsContentState{
			Connection:            connection,
			ActiveSessionCount:    snapshot.ActiveSessionCount,
			WorkingSessionCount:   snapshot.WorkingSessionCount,
			AttentionSessionCount: snapshot.AttentionSessionCount,
			CurrentSessionTitle:   title,
			UpdatedAt:             snapshot.UpdatedAt.Sub(time.Unix(appleReferenceUnix, 0)).Seconds(),
		}
		if state.UpdatedAt <= 0 {
			state.UpdatedAt = now.Sub(time.Unix(appleReferenceUnix, 0)).Seconds()
		}
		relevance := 0.5
		if attention || snapshot.AttentionSessionCount > 0 {
			relevance = 1
		}
		if err := server.apns.send(registration.Token, state, event, relevance, now); err != nil {
			if errors.Is(err, errAPNsTokenExpired) {
				server.removeLiveActivityRegistration(hostID, registration.Token)
				removed++
			} else {
				failed++
			}
			continue
		}
		sent++
	}
	return sent, failed, removed
}

func (server *Server) removeLiveActivityRegistration(hostID, token string) {
	server.liveActivityMu.Lock()
	if registrations := server.liveActivities[hostID]; registrations != nil {
		delete(registrations, token)
		if len(registrations) == 0 {
			delete(server.liveActivities, hostID)
		}
	}
	server.liveActivityMu.Unlock()
}

func (server *Server) liveActivityRegistrationCount(hostID string) int {
	server.liveActivityMu.RLock()
	defer server.liveActivityMu.RUnlock()
	return len(server.liveActivities[hostID])
}

func (server *Server) clearLiveActivityRegistrations(hostID string) {
	server.liveActivityMu.Lock()
	delete(server.liveActivities, hostID)
	server.liveActivityMu.Unlock()
}
