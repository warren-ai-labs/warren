package server

import (
	cryptorand "crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/settings"
)

type lanPairingWindow struct {
	pin       string
	expiresAt time.Time
}

type lanPairingStatus struct {
	Enabled   bool      `json:"enabled"`
	PIN       string    `json:"pin,omitempty"`
	ExpiresAt time.Time `json:"expiresAt,omitempty"`
	ExpiresIn int       `json:"expiresIn,omitempty"`
}

// PairingOpen reports whether the explicit Host-side pairing window is armed.
// Discovery uses this callback to update the non-secret `pair` TXT flag.
func (s *HTTPServer) PairingOpen() bool {
	s.pairingMu.Lock()
	defer s.pairingMu.Unlock()
	return s.pairingWindow != nil && time.Now().Before(s.pairingWindow.expiresAt)
}

func (s *HTTPServer) pairingStatusLocked(now time.Time) lanPairingStatus {
	if s.pairingWindow == nil || !now.Before(s.pairingWindow.expiresAt) {
		s.pairingWindow = nil
		return lanPairingStatus{}
	}
	seconds := int(s.pairingWindow.expiresAt.Sub(now).Round(time.Second) / time.Second)
	if seconds < 1 {
		seconds = 1
	}
	return lanPairingStatus{
		Enabled:   true,
		PIN:       s.pairingWindow.pin,
		ExpiresAt: s.pairingWindow.expiresAt,
		ExpiresIn: seconds,
	}
}

func (s *HTTPServer) writePairingStatus(writer http.ResponseWriter, status lanPairingStatus) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(writer).Encode(status)
}

// handlePairingEnable arms one short-lived PIN window. It is intentionally
// authenticated with the Host token and never enabled from discovery.
func (s *HTTPServer) handlePairingEnable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	status, err := s.armPairing()
	if err != nil {
		http.Error(writer, "unable to create pairing PIN", http.StatusInternalServerError)
		return
	}
	s.writePairingStatus(writer, status)
}

func (s *HTTPServer) handlePairingStatus(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.pairingMu.Lock()
	status := s.pairingStatusLocked(time.Now())
	s.pairingMu.Unlock()
	s.writePairingStatus(writer, status)
}

func (s *HTTPServer) handlePairingDisable(writer http.ResponseWriter, request *http.Request) {
	if !s.authorized(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.disarmPairing()
	s.writePairingStatus(writer, lanPairingStatus{})
}

func (s *HTTPServer) armPairing() (lanPairingStatus, error) {
	pin, err := newLANPairingPIN()
	if err != nil {
		return lanPairingStatus{}, err
	}
	s.pairingMu.Lock()
	s.pairingWindow = &lanPairingWindow{pin: pin, expiresAt: time.Now().Add(lanPairingWindowTTL)}
	status := s.pairingStatusLocked(time.Now())
	s.pairingMu.Unlock()
	return status, nil
}

func (s *HTTPServer) disarmPairing() {
	s.pairingMu.Lock()
	s.pairingWindow = nil
	s.pairingMu.Unlock()
}

// handlePairingRequest is the only unauthenticated endpoint in the pairing
// flow. It accepts a PIN solely while the Host-side window is armed, then
// returns a new scoped bearer token once. The token hash is the only value
// persisted by the Host.
func (s *HTTPServer) handlePairingRequest(writer http.ResponseWriter, request *http.Request) {
	var body struct {
		HostID     string `json:"host_id"`
		ClientID   string `json:"client_id"`
		ClientName string `json:"client_name"`
		PIN        string `json:"pin"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		http.Error(writer, "invalid pairing request", http.StatusBadRequest)
		return
	}
	hostID := strings.TrimSpace(body.HostID)
	clientID := strings.TrimSpace(body.ClientID)
	clientName := strings.TrimSpace(body.ClientName)
	pin := strings.TrimSpace(body.PIN)
	if hostID == "" || clientID == "" || len(clientID) > 256 || len(pin) != 6 || !allASCIIDigits(pin) {
		http.Error(writer, "invalid pairing request", http.StatusBadRequest)
		return
	}
	if s.Service == nil || s.Service.Store == nil {
		http.Error(writer, "Host is unavailable", http.StatusServiceUnavailable)
		return
	}
	if expected := strings.TrimSpace(s.Service.Store.Snapshot().Host.ID); expected == "" || !strings.EqualFold(expected, hostID) {
		http.Error(writer, "unknown Host", http.StatusNotFound)
		return
	}

	// Serialize validation and issuance so two simultaneous requests cannot
	// race a window expiry or replace the same client credential unexpectedly.
	s.pairingMu.Lock()
	status := s.pairingStatusLocked(time.Now())
	if !status.Enabled || subtle.ConstantTimeCompare([]byte(pin), []byte(status.PIN)) != 1 {
		s.pairingMu.Unlock()
		http.Error(writer, "pairing is closed or the PIN is invalid", http.StatusConflict)
		return
	}
	token, err := newLANPairingToken()
	if err != nil {
		s.pairingMu.Unlock()
		http.Error(writer, "unable to create pairing token", http.StatusInternalServerError)
		return
	}
	hash := hashLANPairingToken(token)
	clients := s.Service.PairedClientsSnapshot()
	updated := false
	for index := range clients {
		if clients[index].ClientID == clientID {
			clients[index] = settings.PairedClient{
				ClientID: clientID, Name: clientName, TokenHash: hash, CreatedAt: time.Now().UTC(),
			}
			updated = true
			break
		}
	}
	if !updated {
		clients = append(clients, settings.PairedClient{
			ClientID: clientID, Name: clientName, TokenHash: hash, CreatedAt: time.Now().UTC(),
		})
	}
	if err := s.Service.UpdatePairedClients(clients); err != nil {
		s.pairingMu.Unlock()
		http.Error(writer, "unable to persist pairing", http.StatusInternalServerError)
		return
	}
	s.pairingMu.Unlock()

	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(writer).Encode(map[string]any{
		"paired":    true,
		"host_id":   hostID,
		"client_id": clientID,
		"token":     token,
	})
}

func allASCIIDigits(value string) bool {
	for index := 0; index < len(value); index++ {
		if value[index] < '0' || value[index] > '9' {
			return false
		}
	}
	return true
}

func newLANPairingPIN() (string, error) {
	value, err := cryptorand.Int(cryptorand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", value.Int64()), nil
}

func newLANPairingToken() (string, error) {
	value := make([]byte, 32)
	if _, err := cryptorand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func hashLANPairingToken(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}
