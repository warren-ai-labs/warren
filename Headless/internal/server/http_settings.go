package server

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/settings"
)

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
		_ = json.NewEncoder(writer).Encode(s.settingsProjection())
	case http.MethodPut:
		var body struct {
			DefaultRuntime     string                         `json:"defaultRuntime"`
			RuntimeEnv         map[string]string              `json:"runtimeEnv"`
			AutoOpenShell      *bool                          `json:"autoOpenShell"`
			AutoStartAI        *bool                          `json:"autoStartAI"`
			OpenAIBaseURL      *string                        `json:"openaiBaseURL"`
			OpenAIModel        *string                        `json:"openaiModel"`
			OpenAIKey          *string                        `json:"openaiKey"`
			OpenAITitleEnabled *bool                          `json:"openaiTitleEnabled"`
			Relay              *settings.RelaySettings        `json:"relay"`
			PublicTunnel       *settings.PublicTunnelSettings `json:"publicTunnel"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(writer, request.Body, 16*1024)).Decode(&body); err != nil {
			http.Error(writer, "invalid settings", http.StatusBadRequest)
			return
		}
		current := s.Service.SettingsSnapshot()
		runtimeEnv := body.RuntimeEnv
		if runtimeEnv == nil {
			runtimeEnv = current.RuntimeEnv
		}
		if err := s.Service.UpdateSettings(body.DefaultRuntime, runtimeEnv); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
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
		if body.OpenAIBaseURL != nil {
			s.Service.Settings.OpenAIBaseURL = strings.TrimSpace(*body.OpenAIBaseURL)
		}
		if body.OpenAIModel != nil {
			s.Service.Settings.OpenAIModel = strings.TrimSpace(*body.OpenAIModel)
		}
		if body.OpenAIKey != nil {
			s.Service.Settings.OpenAIKey = strings.TrimSpace(*body.OpenAIKey)
		}
		if body.OpenAITitleEnabled != nil {
			s.Service.Settings.OpenAITitleEnabled = *body.OpenAITitleEnabled
		}
		if body.OpenAIBaseURL != nil || body.OpenAIModel != nil || body.OpenAIKey != nil || body.OpenAITitleEnabled != nil {
			if s.Service.SettingsPath != "" {
				if err := settings.Save(s.Service.SettingsPath, s.Service.Settings); err != nil {
					http.Error(writer, err.Error(), http.StatusBadRequest)
					return
				}
			}
		}
		if body.Relay != nil {
			if err := s.Service.UpdateRelaySettings(*body.Relay); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
		}
		if body.PublicTunnel != nil {
			if err := s.Service.UpdatePublicTunnelSettings(*body.PublicTunnel); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
		}
		if err := s.syncRelayLifecycle(); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(writer).Encode(s.settingsProjection())
	default:
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *HTTPServer) syncRelayLifecycle() error {
	if s.Service == nil {
		return nil
	}
	value := s.Service.SettingsSnapshot()
	enabled := value.Relay.Enabled || value.PublicTunnel.Enabled
	if enabled {
		if s.RelayStart != nil {
			return s.RelayStart()
		}
		return nil
	}
	if s.RelayStop != nil {
		s.RelayStop()
	}
	return nil
}

// resetRelayEnrollment tears down the local Relay lifecycle and clears the
// Host's enrollment metadata. A configured public route is disabled first when
// the Relay is reachable; the Host record itself is deliberately retained and
// can only be revoked with an explicit Relay administrator operation.
func (s *HTTPServer) resetRelayEnrollment(ctx context.Context) error {
	if s.publicAccess != nil {
		if _, err := s.publicAccess.Reset(ctx); err != nil {
			return err
		}
	} else if err := s.Service.UpdatePublicTunnelSettings(settings.PublicTunnelSettings{}); err != nil {
		return err
	}
	if s.RelayStop != nil {
		s.RelayStop()
	}
	if s.RelayReset != nil {
		if err := s.RelayReset(); err != nil {
			return err
		}
	}
	return s.Service.UpdateRelaySettings(settings.RelaySettings{})
}

func (s *HTTPServer) settingsProjection() map[string]any {
	value := s.Service.SettingsSnapshot()
	s.pairingMu.Lock()
	pairing := s.pairingStatusLocked(time.Now())
	s.pairingMu.Unlock()
	return map[string]any{
		"defaultRuntime":     value.DefaultRuntime,
		"runtimeEnv":         value.RuntimeEnv,
		"autoOpenShell":      value.AutoOpenShell,
		"autoStartAI":        value.AutoStartAI,
		"openaiBaseURL":      value.OpenAIBaseURL,
		"openaiModel":        value.OpenAIModel,
		"openaiTitleEnabled": value.OpenAITitleEnabled,
		"relay":              value.Relay,
		"publicTunnel":       value.PublicTunnel,
		"pairing":            pairing,
	}
}
