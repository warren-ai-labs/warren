package settings

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/releaseconfig"
)

// Runtime kinds supported by the headless daemon.
const (
	RuntimeGhostline = "ghostline"
	RuntimeTmux      = "tmux"
)

// DefaultRuntimeKind is used when neither the settings file nor --runtime
// selects one.
const DefaultRuntimeKind = RuntimeGhostline

// DefaultGnarAccount is used when Public Access is enabled without an
// explicit account name. It is a label only; gnar owns the account token.
const DefaultGnarAccount = "warren"

// BuiltInGnarEdge returns the Edge URL injected into the current Warren
// release. It is not persisted in settings, so upgrading Warren can change
// the default for users who have not configured an override.
func BuiltInGnarEdge() string {
	return strings.TrimSpace(releaseconfig.DefaultGnarEdge)
}

// Settings is the headless daemon configuration. Runtime selection is a
// headless-side decision: it controls which engine owns newly created
// sessions, not what clients render.
type Settings struct {
	// DefaultRuntime is the engine used for sessions created without an
	// explicit runtimeKind. Supported: ghostline, tmux.
	DefaultRuntime string `json:"defaultRuntime"`
	// RuntimeEnv overrides environment variables inherited by terminal
	// runtime children (ghostline/tmux sessions). It is applied after the
	// daemon's built-in environment sanitization, so explicit values win;
	// an empty value unsets the variable instead of passing an empty string.
	RuntimeEnv map[string]string `json:"runtimeEnv,omitempty"`
	// GnarEdge is the optional user-selected gnar Edge URL used for Public
	// Access. Empty selects Warren's release/launcher default, or lets gnar
	// use its own default for source builds without one.
	GnarEdge string `json:"gnarEdge,omitempty"`
	// GnarAccount is the non-secret account label passed to gnar login.
	GnarAccount string `json:"gnarAccount,omitempty"`
	// TunnelEnabled records which reachability adapters the user wants
	// running. The daemon restores them after a restart so Public Access
	// recovers until the user explicitly disables it.
	TunnelEnabled map[string]bool `json:"tunnelEnabled,omitempty"`
	// AutoOpenShell controls whether opening an empty workspace creates a
	// default Shell session. Explicit New Session/Shell actions are unaffected.
	AutoOpenShell bool `json:"autoOpenShell"`
	// AutoStartAI controls whether entering an empty workspace starts the first
	// AI preset. Explicit session actions are unaffected.
	AutoStartAI bool `json:"autoStartAI"`
}

// NormalizedGnarAccount returns a safe account label for the gnar CLI.
// Account names are not credentials, but rejecting control characters keeps
// logs and child-process diagnostics unambiguous.
func NormalizedGnarAccount(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return DefaultGnarAccount
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return DefaultGnarAccount
		}
	}
	return value
}

// Normalized returns the effective default runtime kind.
func (s Settings) Normalized() string {
	switch s.DefaultRuntime {
	case RuntimeGhostline, RuntimeTmux:
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
