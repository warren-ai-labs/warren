package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
	// RuntimeEnv overrides environment variables inherited by ghostline
	// runtime children. It is applied after the
	// daemon's built-in environment sanitization, so explicit values win;
	// an empty value unsets the variable instead of passing an empty string.
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

// ApplyRuntimeEnv applies RuntimeEnv to the current process environment so
// runtime children inherit the configured values. Empty values unset the
// variable, which matters for tools that treat an empty override (for
// example GIT_PAGER=) as "disable paging" rather than "use the default".
func (s Settings) ApplyRuntimeEnv() {
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
	return value, nil
}

// Save persists settings atomically.
func Save(path string, value Settings) error {
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
