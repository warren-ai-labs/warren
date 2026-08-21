package runtime

import (
	"os"
	"strings"
)

// DefaultTerm is the terminal type Warren uses when the daemon is launched
// without a usable TERM (agent/CI shells often inherit TERM=dumb).
const DefaultTerm = "xterm-256color"

// SanitizeEnvironment removes launcher-only environment semantics that would
// make Warren terminal sessions behave like non-interactive pipelines:
// PAGER/GIT_PAGER/GH_PAGER set to cat or empty suppress pagers, a dumb TERM
// makes TUIs and pagers degrade, and an ambient NO_COLOR disables interactive
// TUI colors. It mutates the current process environment so ghostline/tmux
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
}

func pagerDisabled(value string) bool {
	value = strings.TrimSpace(value)
	return value == "" || strings.EqualFold(value, "cat")
}
