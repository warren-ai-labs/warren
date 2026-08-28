package runtime

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// DefaultTerm is the terminal type Warren uses when the daemon is launched
// without a usable TERM (agent/CI shells often inherit TERM=dumb).
// xterm-ghostty carries Tc (truecolor) and is bundled in Support/terminfo
// so no external Ghostty install is required.
const DefaultTerm = "xterm-ghostty"

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
