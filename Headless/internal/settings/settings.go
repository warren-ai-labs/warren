package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Runtime kinds supported by the headless daemon.
const (
	RuntimeGhostline = "ghostline"
)

// DefaultRuntimeKind is used when neither the settings file nor --runtime
// selects one.
const DefaultRuntimeKind = RuntimeGhostline

// Settings is the headless daemon configuration. Runtime selection is a
// headless-side decision: it controls which engine owns newly created
// sessions, not what clients render.
type Settings struct {
	// DefaultRuntime is the engine used for sessions created without an
	// explicit runtimeKind. Ghostline is the only supported runtime.
	DefaultRuntime string `json:"defaultRuntime"`
	// RuntimeEnv overrides environment variables for newly created session
	// shells. The daemon itself never applies these values to its process
	// environment. An empty value requests an unset in the session shell.
	RuntimeEnv map[string]string `json:"runtimeEnv,omitempty"`
	// Relay contains the non-secret Relay lifecycle and route metadata. The
	// canonical daemon token remains in token-file/platform credentials and is
	// never duplicated here.
	Relay        RelaySettings        `json:"relay,omitempty"`
	PublicTunnel PublicTunnelSettings `json:"publicTunnel,omitempty"`
	// AutoOpenShell controls whether opening an empty workspace creates a
	// default Shell session. Explicit New Session/Shell actions are unaffected.
	AutoOpenShell bool `json:"autoOpenShell"`
	// AutoStartAI controls whether entering an empty workspace starts the first
	// AI preset. Explicit session actions are unaffected.
	AutoStartAI bool `json:"autoStartAI"`
	// OpenAIBaseURL, OpenAIModel, and OpenAIKey configure the optional
	// capability used for automatic session titles. The key is never returned
	// by the settings APIs.
	OpenAIBaseURL      string `json:"openaiBaseURL,omitempty"`
	OpenAIModel        string `json:"openaiModel,omitempty"`
	OpenAIKey          string `json:"openaiKey,omitempty"`
	OpenAITitleEnabled bool   `json:"openaiTitleEnabled"`
	// PairedClients contains metadata for explicitly paired native clients.
	// Only a SHA-256 token hash is persisted; bearer tokens are returned once
	// over the temporary LAN pairing exchange and remain on the client.
	PairedClients []PairedClient `json:"pairedClients,omitempty"`
}

// PairedClient is a scoped client credential issued by the Host pairing
// window. ClientID is stable for the device, while TokenHash is never sent to
// clients or included in discovery metadata.
type PairedClient struct {
	ClientID  string    `json:"clientID"`
	Name      string    `json:"name,omitempty"`
	TokenHash string    `json:"tokenHash"`
	CreatedAt time.Time `json:"createdAt"`
}

var reservedRuntimeEnvKeys = map[string]struct{}{
	"WARREN_SESSION_ID": {},
	"WARREN_BIND_FILE":  {},
	"WARREN_STATE_FILE": {},
	"WARREN_AGENT_KIND": {},
	"CODEX_SESSION_ID":  {},
	"CODEX_THREAD_ID":   {},
}

// ValidateRuntimeEnv checks user-provided session overrides before they reach
// a PTY. Warren-owned binding variables must remain authoritative, and keys
// must follow the platform environment naming rules used by exec.Cmd.
func ValidateRuntimeEnv(runtimeEnv map[string]string) error {
	for key := range runtimeEnv {
		if !validEnvironmentKey(key) {
			return fmt.Errorf("invalid runtime environment key %q", key)
		}
		if _, reserved := reservedRuntimeEnvKeys[key]; reserved {
			return fmt.Errorf("runtime environment key %q is managed by Warren", key)
		}
	}
	for key, value := range runtimeEnv {
		if strings.IndexByte(value, 0) >= 0 {
			return fmt.Errorf("runtime environment value for %q contains NUL", key)
		}
	}
	return nil
}

func validEnvironmentKey(key string) bool {
	if key == "" {
		return false
	}
	for index, character := range key {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || character == '_' || (index > 0 && character >= '0' && character <= '9') {
			continue
		}
		return false
	}
	return true
}

type RelaySettings struct {
	Enabled    bool   `json:"enabled"`
	URL        string `json:"url,omitempty"`
	HostID     string `json:"hostID,omitempty"`
	RouteID    string `json:"routeID,omitempty"`
	RelayKeyID string `json:"relayKeyID,omitempty"`
	RelayKey   string `json:"relayKey,omitempty"`
	LastError  string `json:"lastError,omitempty"`
}

type PublicTunnelSettings struct {
	Enabled        bool   `json:"enabled"`
	RouteID        string `json:"routeID,omitempty"`
	Owner          string `json:"owner,omitempty"`
	PublicHostname string `json:"publicHostname,omitempty"`
	PathPrefix     string `json:"pathPrefix,omitempty"`
	AuthMode       string `json:"authMode,omitempty"`
}

// Normalized returns the effective default runtime kind.
func (s Settings) Normalized() string {
	switch s.DefaultRuntime {
	case RuntimeGhostline:
		return s.DefaultRuntime
	default:
		return DefaultRuntimeKind
	}
}

// ApplyRuntimeEnv applies RuntimeEnv to the current process environment for
// callers that explicitly own that process. The Warren daemon does not call
// this helper: session overrides are passed to the session boundary instead.
func (s Settings) ApplyRuntimeEnv() {
	if err := ValidateRuntimeEnv(s.RuntimeEnv); err != nil {
		return
	}
	for key, value := range s.RuntimeEnv {
		if value == "" {
			_ = os.Unsetenv(key)
			continue
		}
		_ = os.Setenv(key, value)
	}
}

// DefaultPath returns the conventional settings file location.
func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren", "settings.json")
}

// Load reads settings from path. A missing file yields defaults.
func Load(path string) (Settings, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Settings{}, nil
	}
	if err != nil {
		return Settings{}, err
	}
	var value Settings
	if err := json.Unmarshal(data, &value); err != nil {
		return Settings{}, err
	}
	if strings.TrimSpace(value.DefaultRuntime) != "" && value.DefaultRuntime != RuntimeGhostline {
		return Settings{}, fmt.Errorf("unsupported runtime %q; migrate settings to ghostline", value.DefaultRuntime)
	}
	if err := ValidateRuntimeEnv(value.RuntimeEnv); err != nil {
		return Settings{}, err
	}
	return value, nil
}

// Save persists settings atomically.
func Save(path string, value Settings) error {
	if err := ValidateRuntimeEnv(value.RuntimeEnv); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}
