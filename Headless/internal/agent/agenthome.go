package agent

import (
	"errors"
	"os"
	"path/filepath"
)

// EnvAgentHome is how a launcher states that a session keeps its engine's state
// in a directory of its own: a claude config_dir, a codex_home, an agy
// gemini_dir. One variable, whichever engine — a watcher then reads one thing
// instead of knowing which engine hides its directory in which variable or
// which command-line flag.
//
// Warren reads it from a session's hook (BindEnvHome carries the same name) and
// from a session's process environment, so it learns a relocated home before
// the engine has written anything into it.
const EnvAgentHome = BindEnvHome

// EnsureBindHookForHome installs Warren's hook into the engine home a session
// reported, so that home binds exactly from the next session on: the default
// installation covers the shared home only.
//
// The kind is the one the engine reported, so nothing here has to guess what a
// directory holds. Engines whose hooks are not per home (pi, opencode) install
// once and are skipped.
func EnsureBindHookForHome(kind, home string) (installed bool, err error) {
	home = filepath.Clean(home)
	if home == "." || home == "/" || !filepath.IsAbs(home) {
		return false, errors.New("agent home must be an absolute directory")
	}
	// The hook belongs in a directory the engine already uses. Anything else
	// would have Warren create a tree somewhere on the strength of a variable
	// any process in the session can set; a directory that is not there yet is
	// reported again once the engine has made it.
	if info, err := os.Stat(home); err != nil || !info.IsDir() {
		return false, nil
	}
	switch kind {
	case "claude":
		_, err = EnsureClaudeBindHook(home)
	case "codex":
		_, err = EnsureCodexBindHook(home)
	case "antigravity":
		// agy keeps hooks beside its shared config, inside the gemini_dir.
		_, err = EnsureAntigravityBindHook(filepath.Join(home, "config"))
	case "qoder":
		_, err = EnsureQoderBindHook(home)
	default:
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}
