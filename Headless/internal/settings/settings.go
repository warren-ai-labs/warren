package settings

import (
	"encoding/json"
	"errors"
	"fmt"
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

// DefaultGnarAccount is the last-resort account label used when the host name
// cannot be converted to a gnar v1.7 account name. It is a label only; gnar
// owns the account token.
const DefaultGnarAccount = "warren"

// MaxGnarAccountLength is enforced by gnar v1.7 for account names.
const MaxGnarAccountLength = 16

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

// NormalizedGnarAccount returns a safe account label for the gnar CLI. Empty
// or malformed values retain the historical safe fallback; callers handling
// explicit user input should use NormalizeConfiguredGnarAccount so invalid
// values can be reported instead of silently changed.
func NormalizedGnarAccount(value string) string {
	normalized, err := NormalizeConfiguredGnarAccount(value)
	if err != nil || normalized == "" {
		return DefaultGnarAccount
	}
	return normalized
}

// NormalizeConfiguredGnarAccount validates an explicitly configured account
// name against gnar v1.7's contract. gnar lowercases names itself, so Warren
// accepts uppercase input and stores the canonical lowercase form. Empty
// means that no user override is configured.
func NormalizeConfiguredGnarAccount(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", nil
	}
	normalized := strings.ToLower(value)
	if len(normalized) > MaxGnarAccountLength || len(normalized) == 0 {
		return "", fmt.Errorf("gnar account name must be 1 to %d lowercase letters, numbers, or hyphens", MaxGnarAccountLength)
	}
	for index, character := range normalized {
		if (character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') || character == '-' {
			if (index == 0 || index == len(normalized)-1) && character == '-' {
				return "", fmt.Errorf("gnar account name must start and end with a letter or number")
			}
			continue
		}
		return "", fmt.Errorf("gnar account name must be 1 to %d lowercase letters, numbers, or hyphens", MaxGnarAccountLength)
	}
	return normalized, nil
}

// ConfiguredGnarAccount returns only the persisted user override. It never
// substitutes the system-name default, which lets callers distinguish an
// omitted account from an explicit override.
func ConfiguredGnarAccount(value string) string {
	normalized, err := NormalizeConfiguredGnarAccount(value)
	if err != nil {
		return ""
	}
	return normalized
}

// DefaultGnarAccountForHost converts a Warren Host/system name into the
// account syntax accepted by gnar v1.7. Non-ASCII and punctuation runs become
// a single hyphen; the result is trimmed and capped at 16 characters.
func DefaultGnarAccountForHost(hostName string) string {
	var builder strings.Builder
	for _, character := range strings.ToLower(strings.TrimSpace(hostName)) {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') {
			builder.WriteRune(character)
			continue
		}
		if builder.Len() > 0 && !strings.HasSuffix(builder.String(), "-") {
			builder.WriteByte('-')
		}
	}
	normalized := strings.Trim(builder.String(), "-")
	if len(normalized) > MaxGnarAccountLength {
		normalized = strings.TrimRight(normalized[:MaxGnarAccountLength], "-")
	}
	if normalized == "" {
		return DefaultGnarAccount
	}
	return normalized
}

// EffectiveGnarAccount resolves a persisted override first, then the Warren
// Host/system name, and finally the safe fallback. HostName may be empty in
// embedded/test callers; os.Hostname supplies the platform value then.
func EffectiveGnarAccount(configured, hostName string) string {
	if account := ConfiguredGnarAccount(configured); account != "" {
		return account
	}
	if strings.TrimSpace(hostName) == "" {
		hostName, _ = os.Hostname()
	}
	return DefaultGnarAccountForHost(hostName)
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
