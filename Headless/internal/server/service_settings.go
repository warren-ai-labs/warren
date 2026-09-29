package server

import (
	"fmt"

	"github.com/abcdlsj/warren/Headless/internal/settings"
)

// SetDefaultRuntime changes the engine used for newly created sessions while
// preserving the configured runtime environment overrides.
func (s *Service) SetDefaultRuntime(kind string) error {
	value := s.SettingsSnapshot()
	return s.UpdateSettings(kind, value.RuntimeEnv)
}

// SettingsSnapshot returns a detached copy suitable for concurrent readers.
// Maps are copied so a caller cannot mutate the service's live configuration.
func (s *Service) SettingsSnapshot() settings.Settings {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	value := s.Settings
	if value.DefaultRuntime == "" {
		value.DefaultRuntime = s.DefaultRuntime
	}
	value.RuntimeEnv = cloneStringMap(value.RuntimeEnv)
	value.PairedClients = clonePairedClients(value.PairedClients)
	return value
}

func cloneStringMap(value map[string]string) map[string]string {
	if value == nil {
		return nil
	}
	copy := make(map[string]string, len(value))
	for key, item := range value {
		copy[key] = item
	}
	return copy
}

// PairedClientsSnapshot returns detached pairing metadata. Token hashes are
// kept inside the Host service and are never projected to remote clients.
func (s *Service) PairedClientsSnapshot() []settings.PairedClient {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return clonePairedClients(s.Settings.PairedClients)
}

// UpdatePairedClients persists the current set of explicitly paired clients.
func (s *Service) UpdatePairedClients(values []settings.PairedClient) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.PairedClients = clonePairedClients(values)
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

func clonePairedClients(values []settings.PairedClient) []settings.PairedClient {
	if values == nil {
		return nil
	}
	return append([]settings.PairedClient(nil), values...)
}

// RelaySettingsSnapshot and PublicTunnelSettingsSnapshot are the lifecycle
// supervisor's narrow read surface; neither returns any Host Secret.
func (s *Service) RelaySettingsSnapshot() settings.RelaySettings {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return s.Settings.Relay
}

func (s *Service) PublicTunnelSettingsSnapshot() settings.PublicTunnelSettings {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return s.Settings.PublicTunnel
}

func (s *Service) UpdateRelaySettings(value settings.RelaySettings) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.Relay = value
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

func (s *Service) UpdatePublicTunnelSettings(value settings.PublicTunnelSettings) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.PublicTunnel = value
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// UpdateSettings changes the engine used for newly created sessions and the
// runtime environment overrides, persisting them when a settings file is
// configured. Existing sessions keep their own runtimeKind.
func (s *Service) UpdateSettings(kind string, runtimeEnv map[string]string) error {
	if err := settings.ValidateRuntimeEnv(runtimeEnv); err != nil {
		return err
	}
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	if kind == "" {
		kind = s.DefaultRuntime
	}
	if kind == "" {
		kind = s.Settings.Normalized()
	}
	if kind != settings.RuntimeGhostline {
		return fmt.Errorf("unsupported runtime %q (supported: ghostline)", kind)
	}
	if s.Runtimes[kind] == nil && s.Runtime == nil {
		return fmt.Errorf("runtime %q is not available on this host", kind)
	}
	s.DefaultRuntime = kind
	s.Settings.DefaultRuntime = kind
	s.Settings.RuntimeEnv = cloneStringMap(runtimeEnv)
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// PublicAccessEnabled reports the persisted public Relay route intent. This
// distinction lets recovery retry after a daemon restart without claiming
// that the route is already live.
func (s *Service) PublicAccessEnabled() bool {
	s.settingsMu.RLock()
	defer s.settingsMu.RUnlock()
	return s.Settings.PublicTunnel.Enabled
}

// SetAutoOpenShell records whether opening an empty workspace creates a Shell
// session by default. Explicit session actions are unaffected.
func (s *Service) SetAutoOpenShell(enabled bool) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.AutoOpenShell = enabled
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}

// SetAutoStartAI records whether entering an empty workspace starts the first
// AI preset. Explicit session actions are unaffected.
func (s *Service) SetAutoStartAI(enabled bool) error {
	s.settingsMu.Lock()
	defer s.settingsMu.Unlock()
	s.Settings.AutoStartAI = enabled
	if s.SettingsPath != "" {
		return settings.Save(s.SettingsPath, s.Settings)
	}
	return nil
}
