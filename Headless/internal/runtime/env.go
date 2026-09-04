package runtime

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strings"
)

// DefaultTerm is the terminal type Warren uses when the daemon is launched
// without a usable TERM (agent/CI shells often inherit TERM=dumb).
// xterm-ghostty carries Tc (truecolor) and is bundled in Support/terminfo
// so no external Ghostty install is required.
const DefaultTerm = "xterm-ghostty"

// terminalEnvironmentKeys are the host-level values that define the baseline
// of a Warren terminal. Warren configuration, provider configuration, session
// identity, task-runner state, and credentials deliberately do not appear
// here: those values belong to the daemon or to an individual session.
var terminalEnvironmentKeys = map[string]struct{}{
	"DISPLAY":                  {},
	"WAYLAND_DISPLAY":          {},
	"DBUS_SESSION_BUS_ADDRESS": {},
	"XAUTHORITY":               {},
	"XDG_CONFIG_HOME":          {},
	"XDG_DATA_HOME":            {},
	"XDG_CACHE_HOME":           {},
	"XDG_RUNTIME_DIR":          {},
}

// daemonEnvironmentKeys are configuration and executable-path overrides that
// may be inherited by Warren-owned control-plane processes. They are never
// used as the Ghostline or PTY baseline; the Ghostline serve entry point
// applies TerminalEnvironment before constructing its server.
var daemonEnvironmentKeys = map[string]struct{}{
	"WARREN_CONFIG":                     {},
	"CODEX_HOME":                        {},
	"CLAUDE_CONFIG_DIR":                 {},
	"WARREN_DATA_DIR":                   {},
	"WARREN_OPENCODE_DATA_DIR":          {},
	"WARREN_OPENCODE_PLUGIN_PATH":       {},
	"WARREN_WEB_ROOT":                   {},
	"WARREN_GHOSTLINE_FORCE_HANDOFF":    {},
	"WARREN_FORCE_HANDOFF":              {},
	"WARREN_LISTEN":                     {},
	"WARREN_LAN_HTTPS":                  {},
	"WARREN_TLS_DIR":                    {},
	"WARREN_STATE":                      {},
	"WARREN_TOKEN_FILE":                 {},
	"WARREN_HOST_NAME":                  {},
	"WARREN_RUNTIME":                    {},
	"WARREN_GHOSTLINE_SOCKET":           {},
	"WARREN_GHOSTLINE_PROBE_FOREGROUND": {},
	"WARREN_SETTINGS_FILE":              {},
	"WARREN_LOG_FILE":                   {},
	"WARREN_WORKTREE_ROOT":              {},
	"WARREN_OUTPUT_DIR":                 {},
	"WARREN_RELAY_URL":                  {},
	"WARREN_RELAY_HOST_ID":              {},
	"WARREN_RELAY_KEY_ID":               {},
	"WARREN_RELAY_KEY":                  {},
}

var supportedShellNames = map[string]struct{}{
	"bash": {},
	"fish": {},
	"sh":   {},
	"zsh":  {},
}

// CleanEnvironment builds the terminal baseline inherited by Ghostline and
// new PTYs. It intentionally starts from an allowlist: project/task state and
// Warren/provider control variables are supplied by the daemon or session
// boundary instead of leaking from the launching terminal.
func CleanEnvironment(source []string) []string {
	values := environmentMap(source)
	home := strings.TrimSpace(values["HOME"])
	if home == "" {
		home, _ = os.UserHomeDir()
	}

	result := make(map[string]string, len(terminalEnvironmentKeys)+12)
	copyNonEmpty := func(key string) {
		if value := strings.TrimSpace(values[key]); value != "" {
			result[key] = values[key]
		}
	}
	if home != "" {
		result["HOME"] = home
	}
	copyNonEmpty("USER")
	copyNonEmpty("LOGNAME")
	if result["USER"] == "" {
		if current, err := user.Current(); err == nil && current.Username != "" {
			result["USER"] = current.Username
		}
	}
	if result["LOGNAME"] == "" && result["USER"] != "" {
		result["LOGNAME"] = result["USER"]
	}
	if values["TMPDIR"] != "" {
		result["TMPDIR"] = values["TMPDIR"]
	} else if temporary := os.TempDir(); temporary != "" {
		result["TMPDIR"] = temporary
	}
	copyNonEmpty("LANG")
	copyNonEmpty("TZ")
	for key, value := range values {
		if strings.HasPrefix(key, "LC_") && validEnvironmentKey(key) && strings.TrimSpace(value) != "" {
			result[key] = value
		}
	}

	result["SHELL"] = canonicalShell(values["SHELL"])
	result["PATH"] = StablePath(home)
	result["TERM"] = DefaultTerm
	result["COLORTERM"] = "truecolor"
	for key := range terminalEnvironmentKeys {
		if value := strings.TrimSpace(values[key]); value != "" {
			result[key] = values[key]
		}
	}
	if socket := strings.TrimSpace(values["SSH_AUTH_SOCK"]); validUnixSocket(socket) {
		result["SSH_AUTH_SOCK"] = socket
	}

	return encodeEnvironment(result)
}

// TerminalEnvironment is the explicit name for CleanEnvironment at process
// boundaries that own a terminal. Keep CleanEnvironment as the short,
// backwards-compatible API used by existing callers and tests.
func TerminalEnvironment(source []string) []string {
	return CleanEnvironment(source)
}

// DaemonEnvironment builds the environment for Warren's control-plane
// processes. It retains Warren/provider configuration needed by the daemon,
// while keeping the terminal baseline itself deterministic.
func DaemonEnvironment(source []string) []string {
	values := environmentMap(source)
	result := environmentMap(TerminalEnvironment(source))
	for key := range daemonEnvironmentKeys {
		if value := strings.TrimSpace(values[key]); value != "" {
			result[key] = values[key]
		}
	}
	return encodeEnvironment(result)
}

// ApplyCleanEnvironment replaces the current process environment with the
// terminal baseline. Call ApplyDaemonEnvironment for a Warren control-plane
// process and ApplyTerminalEnvironment for a Ghostline serve process.
func ApplyCleanEnvironment() {
	ApplyTerminalEnvironment()
}

// ApplyDaemonEnvironment installs the clean daemon environment while
// retaining explicit Warren/provider configuration used by control-plane
// code.
func ApplyDaemonEnvironment() {
	ReplaceEnvironment(DaemonEnvironment(os.Environ()))
}

// ApplyTerminalEnvironment removes daemon-only configuration from the current
// process before it constructs a Ghostline server. Ghostline v1 merges its
// own os.Environ() with per-session overrides, so this boundary is required
// even when the parent supplied an explicit terminal environment to Spawn.
func ApplyTerminalEnvironment() {
	ReplaceEnvironment(TerminalEnvironment(os.Environ()))
}

// ReplaceEnvironment installs an explicit environment without logging any
// values. It is kept small so tests and subprocess entry points can share the
// same boundary behavior.
func ReplaceEnvironment(environment []string) {
	wanted := environmentMap(environment)
	for key := range environmentMap(os.Environ()) {
		if _, ok := wanted[key]; !ok {
			_ = os.Unsetenv(key)
		}
	}
	for key, value := range wanted {
		_ = os.Setenv(key, value)
	}
}

// StablePath returns a host-level PATH. Project-specific shims (mise,
// direnv, virtualenv and similar) are intentionally absent; a login shell in
// the session rebuilds those paths in the selected workspace.
func StablePath(home string) string {
	entries := []string{}
	if home != "" {
		entries = append(entries,
			filepath.Join(home, ".local", "bin"),
			filepath.Join(home, "go", "bin"),
			filepath.Join(home, ".cargo", "bin"),
		)
	}
	entries = append(entries,
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"/usr/bin",
		"/bin",
		"/usr/sbin",
		"/sbin",
	)
	seen := make(map[string]struct{}, len(entries))
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry == "" {
			continue
		}
		if _, ok := seen[entry]; ok {
			continue
		}
		seen[entry] = struct{}{}
		result = append(result, entry)
	}
	return strings.Join(result, string(os.PathListSeparator))
}

// LoginShellPath returns a validated interactive shell path for new PTYs.
// The caller's SHELL is only accepted when it points at a known shell binary;
// otherwise Warren falls back to the platform's standard shells.
func LoginShellPath() string {
	values := environmentMap(os.Environ())
	return canonicalShell(values["SHELL"])
}

// LoginShellArgs are passed directly to the shell so its startup files load
// mise/direnv and other user project tooling inside the new session.
func LoginShellArgs() []string { return []string{"-il"} }

// ShellCommandWithUnsets returns a safe bootstrap command for the rare case
// where a session explicitly requests variables to be unset. Ghostline's v1
// environment API can override values but cannot remove keys from its own
// process environment, so the login shell performs the final unsets.
func ShellCommandWithUnsets(shell string, keys []string) (string, error) {
	if shell == "" {
		shell = LoginShellPath()
	}
	if !isSupportedShellPath(shell) {
		return "", fmt.Errorf("unsupported login shell %q", shell)
	}
	unique := make(map[string]struct{}, len(keys))
	ordered := make([]string, 0, len(keys))
	for _, key := range keys {
		if !validEnvironmentKey(key) {
			return "", fmt.Errorf("invalid environment key %q", key)
		}
		if _, ok := unique[key]; ok {
			continue
		}
		unique[key] = struct{}{}
		ordered = append(ordered, key)
	}
	sort.Strings(ordered)
	if len(ordered) == 0 {
		return "", nil
	}
	return "unset " + strings.Join(ordered, " ") + "; exec " + shellQuote(shell) + " -il", nil
}

func environmentMap(environment []string) map[string]string {
	values := make(map[string]string, len(environment))
	for _, entry := range environment {
		separator := strings.IndexByte(entry, '=')
		if separator <= 0 {
			continue
		}
		values[entry[:separator]] = entry[separator+1:]
	}
	return values
}

func encodeEnvironment(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]string, 0, len(keys))
	for _, key := range keys {
		result = append(result, key+"="+values[key])
	}
	return result
}

func canonicalShell(value string) string {
	candidates := []string{strings.TrimSpace(value), "/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh"}
	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if candidate == "" || !filepath.IsAbs(candidate) {
			continue
		}
		if _, ok := seen[candidate]; ok {
			continue
		}
		seen[candidate] = struct{}{}
		if isSupportedShellPath(candidate) {
			return candidate
		}
	}
	return "/bin/sh"
}

func isSupportedShellPath(path string) bool {
	base := filepath.Base(path)
	if _, ok := supportedShellNames[base]; !ok {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}

func validUnixSocket(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.Mode()&os.ModeSocket != 0
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

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

// SanitizeEnvironment removes launcher-only environment semantics that would
// make Warren terminal sessions behave like non-interactive pipelines:
// PAGER/GIT_PAGER/GH_PAGER set to cat or empty suppress pagers, a dumb TERM
// makes TUIs and pagers degrade, and an ambient NO_COLOR disables interactive
// TUI colors. It mutates the current process environment so ghostline
// children inherit a real terminal environment; user-specified values are
// applied afterwards by settings.
func SanitizeEnvironment() {
	for _, key := range []string{"GIT_PAGER", "PAGER", "GH_PAGER"} {
		if pagerDisabled(os.Getenv(key)) {
			_ = os.Unsetenv(key)
		}
	}
	// NO_COLOR is presence-sensitive for the color detection libraries used by
	// interactive TUIs: NO_COLOR= is still an opt-out. Remove the ambient
	// launcher value instead of replacing it with an empty entry.
	_ = os.Unsetenv("NO_COLOR")
	if term := os.Getenv("TERM"); strings.TrimSpace(term) == "" || term == "dumb" {
		_ = os.Setenv("TERM", DefaultTerm)
	}
	if strings.TrimSpace(os.Getenv("COLORTERM")) == "" {
		_ = os.Setenv("COLORTERM", "truecolor")
	}
	ensureGhosttyTerminfo()
}

func pagerDisabled(value string) bool {
	value = strings.TrimSpace(value)
	return value == "" || strings.EqualFold(value, "cat")
}

func ensureGhosttyTerminfo() {
	if os.Getenv("TERM") != "xterm-ghostty" {
		return
	}
	// If the host already has xterm-ghostty (e.g. Ghostty is installed),
	// nothing to do.
	if err := exec.Command("infocmp", "xterm-ghostty").Run(); err == nil {
		return
	}
	// Try to find bundled terminfo and install to ~/.terminfo for the user.
	candidates := []string{}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "..", "Resources", "terminfo", "78", "xterm-ghostty"))
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "terminfo", "78", "xterm-ghostty"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, ".warren", "terminfo", "78", "xterm-ghostty"))
	}
	// Dev checkout fallback.
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates, filepath.Join(wd, "Support", "terminfo", "78", "xterm-ghostty"))
	}
	var src string
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			src = c
			break
		}
	}
	if src == "" {
		// No bundled file found; generate a minimal one from xterm-256color + Tc.
		generateMinimalGhosttyTerminfo()
		return
	}
	if home, err := os.UserHomeDir(); err == nil {
		dst := filepath.Join(home, ".terminfo", "78", "xterm-ghostty")
		if _, err := os.Stat(dst); err == nil {
			return
		}
		_ = os.MkdirAll(filepath.Dir(dst), 0755)
		if data, err := os.ReadFile(src); err == nil {
			_ = os.WriteFile(dst, data, 0644)
		}
	}
}

func generateMinimalGhosttyTerminfo() {
	// Create a minimal xterm-ghostty that is xterm-256color + Tc via tic.
	tmpDir, err := os.MkdirTemp("", "warren-terminfo-*")
	if err != nil {
		return
	}
	defer os.RemoveAll(tmpDir)
	tiPath := filepath.Join(tmpDir, "xterm-ghostty.ti")
	content := "xterm-ghostty|xterm-ghostty with truecolor,\n\tuse=xterm-256color,\n\tTc,\n"
	if err := os.WriteFile(tiPath, []byte(content), 0644); err != nil {
		return
	}
	outDir := filepath.Join(tmpDir, "out")
	_ = os.MkdirAll(outDir, 0755)
	if err := exec.Command("tic", "-x", "-o", outDir, tiPath).Run(); err != nil {
		return
	}
	src := compiledTerminfoPath(outDir)
	if src == "" {
		return
	}
	if home, err := os.UserHomeDir(); err == nil {
		dst := filepath.Join(home, ".terminfo", "78", "xterm-ghostty")
		if _, err := os.Stat(dst); err == nil {
			return
		}
		_ = os.MkdirAll(filepath.Dir(dst), 0755)
		if data, err := os.ReadFile(src); err == nil {
			_ = os.WriteFile(dst, data, 0644)
		}
	}
}

// compiledTerminfoPath resolves the first-character directory used by tic.
// macOS commonly uses hexadecimal directories (78 for 'x'), while ncurses on
// Linux uses the literal initial (x).
func compiledTerminfoPath(root string) string {
	for _, path := range []string{
		filepath.Join(root, "78", "xterm-ghostty"),
		filepath.Join(root, "x", "xterm-ghostty"),
	} {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return ""
}

// BundledTerminfoDir returns the directory that contains the bundled
// xterm-ghostty terminfo for ghostline children. Empty if not found or not
// needed (host already has it).
func BundledTerminfoDir() string {
	if err := exec.Command("infocmp", "xterm-ghostty").Run(); err == nil {
		return ""
	}
	candidates := []string{}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "..", "Resources", "terminfo"))
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "terminfo"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, ".warren", "terminfo"))
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates, filepath.Join(wd, "Support", "terminfo"))
	}
	for _, c := range candidates {
		if _, err := os.Stat(filepath.Join(c, "78", "xterm-ghostty")); err == nil {
			return c
		}
		if _, err := os.Stat(c); err == nil {
			// Check if c itself is the terminfo dir containing 78/
			if _, err := os.Stat(filepath.Join(c, "78")); err == nil {
				return c
			}
		}
	}
	return ""
}
