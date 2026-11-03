package controlplane

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type persistedSessions struct {
	RefreshTokens   map[string]refreshRecord `json:"refresh_tokens"`
	UsedRefresh     map[string]string        `json:"used_refresh,omitempty"`
	RevokedFamilies map[string]bool          `json:"revoked_families,omitempty"`
}

func (server *Server) sessionsPath() string {
	if strings.TrimSpace(server.config.DataURL) == "" {
		return ""
	}
	return server.config.DataURL + ".sessions"
}

func (server *Server) loadSessions() error {
	p := server.sessionsPath()
	if p == "" {
		return nil
	}
	b, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var state persistedSessions
	if err := json.Unmarshal(b, &state); err != nil {
		return err
	}
	server.refreshTokens = state.RefreshTokens
	if server.refreshTokens == nil {
		server.refreshTokens = make(map[string]refreshRecord)
	}
	if server.config.RefreshTTL == 0 {
		for hash, entry := range server.refreshTokens {
			entry.Expires = time.Time{}
			server.refreshTokens[hash] = entry
		}
	}
	server.usedRefresh = state.UsedRefresh
	if server.usedRefresh == nil {
		server.usedRefresh = make(map[string]string)
	}
	server.revokedFamilies = state.RevokedFamilies
	if server.revokedFamilies == nil {
		server.revokedFamilies = make(map[string]bool)
	}
	return nil
}

func (server *Server) persistSessions() error {
	p := server.sessionsPath()
	if p == "" {
		return nil
	}
	server.sessionMu.Lock()
	state := persistedSessions{RefreshTokens: server.refreshTokens, UsedRefresh: server.usedRefresh, RevokedFamilies: server.revokedFamilies}
	data, err := json.Marshal(state)
	server.sessionMu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}
