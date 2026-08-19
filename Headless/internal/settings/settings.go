package settings

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// Runtime kinds supported by the headless daemon.
const (
	RuntimeGhostline = "ghostline"
	RuntimeTmux      = "tmux"
)

// DefaultRuntimeKind is used when neither the settings file nor --runtime
// selects one.
const DefaultRuntimeKind = RuntimeGhostline

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
	// GnarEdge is the gnar edge server used for public Web sharing. Empty
	// lets gnar use its own default (GNAR_EDGE or the single signed-in edge).
	GnarEdge string `json:"gnarEdge,omitempty"`
	// TunnelEnabled records which reachability adapters the user wants
	// running. The daemon restores them after a restart so a public URL
	// survives until the user explicitly stops sharing.
	TunnelEnabled map[string]bool `json:"tunnelEnabled,omitempty"`
	// ImportGitWorktrees controls project import: when enabled, adding a
	// project imports every Git worktree as a workspace; when disabled only
	// the main checkout is imported.
	ImportGitWorktrees bool `json:"importGitWorktrees"`
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
