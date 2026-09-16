package runtime

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// ShellIntegrationDirEnv relocates the generated shell integration scripts.
// Tests and embedders set it; the default lives beside Warren's other runtime
// state so it survives a daemon restart.
const ShellIntegrationDirEnv = "WARREN_SHELL_INTEGRATION_DIR"

// shellIntegrationFiles embeds the scripts. `all:` is required because the zsh
// entry point is a dotfile.
//
//go:embed all:shellintegration
var shellIntegrationFiles embed.FS

// ShellIntegrationDir is the directory that holds the generated shell
// integration scripts.
func ShellIntegrationDir() string {
	if value := strings.TrimSpace(os.Getenv(ShellIntegrationDirEnv)); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".warren", "shell-integration")
}

// WriteShellIntegration materializes the embedded scripts under dir. It
// overwrites existing files so a daemon upgrade refreshes them, and is safe to
// call on every start.
func WriteShellIntegration(dir string) error {
	if strings.TrimSpace(dir) == "" {
		return fmt.Errorf("shell integration directory is empty")
	}
	return fs.WalkDir(shellIntegrationFiles, "shellintegration", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel("shellintegration", path)
		if err != nil {
			return err
		}
		target := filepath.Join(dir, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := shellIntegrationFiles.ReadFile(path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
}

// ShellIntegration is the launch adjustment for one shell.
type ShellIntegration struct {
	// Env is the session environment with the integration variables applied.
	Env []string
	// Args are the arguments the login shell starts with.
	Args []string
}

// ApplyShellIntegration adds Warren's OSC 7 shell integration for the shells
// that can load a prompt hook. Unsupported shells keep the default login
// arguments and rely on the launch-directory fallback.
//
// It advertises every supported mechanism at once. A variable another shell
// ignores is harmless, and a login shell may `exec` a different one (a common
// zsh setup ends in `exec fish`), so the shell that finally runs must still
// find its hook.
func ApplyShellIntegration(shell string, env []string) ShellIntegration {
	args := LoginShellArgs()
	dir := ShellIntegrationDir()
	if dir == "" {
		return ShellIntegration{Env: env, Args: args}
	}
	if _, ok := supportedShellNames[filepath.Base(shell)]; !ok {
		return ShellIntegration{Env: env, Args: args}
	}
	// Preserve a user-configured ZDOTDIR so the zsh wrapper can hand it back.
	original := lookupEnvironment(env, "ZDOTDIR")
	if original == "" {
		original = strings.TrimSpace(os.Getenv("ZDOTDIR"))
	}
	if original != "" {
		env = setEnvironment(env, "WARREN_ZSH_ZDOTDIR", original)
	}
	existing := lookupEnvironment(env, "XDG_DATA_DIRS")
	if existing == "" {
		// The terminal baseline drops XDG_DATA_DIRS; restoring the spec default
		// keeps system vendor configuration loadable.
		existing = "/usr/local/share:/usr/share"
	}
	env = setEnvironment(env, "XDG_DATA_DIRS", dir+string(os.PathListSeparator)+existing)
	env = setEnvironment(env, ShellIntegrationDirEnv, dir)
	env = setEnvironment(env, "ZDOTDIR", filepath.Join(dir, "zsh"))
	return ShellIntegration{Env: env, Args: args}
}

func lookupEnvironment(env []string, key string) string {
	prefix := key + "="
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			return entry[len(prefix):]
		}
	}
	return ""
}

// setEnvironment replaces every entry for key with one value, appending when
// the key is absent.
func setEnvironment(env []string, key, value string) []string {
	prefix := key + "="
	result := make([]string, 0, len(env)+1)
	replaced := false
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			if !replaced {
				result = append(result, prefix+value)
				replaced = true
			}
			continue
		}
		result = append(result, entry)
	}
	if !replaced {
		result = append(result, prefix+value)
	}
	return result
}
