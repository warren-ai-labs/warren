package agent

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runBindHook runs the managed hook the way an engine does: the payload on
// stdin, the provider and event as arguments, and the session's environment.
func runBindHook(t *testing.T, env []string, payload string) Binding {
	t.Helper()
	dir := t.TempDir()
	bindPath := filepath.Join(dir, "bind.json")
	scriptPath := filepath.Join(dir, "agent-bind.sh")
	if err := os.WriteFile(scriptPath, []byte(agentBindHookScript), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", scriptPath, hookCommandMarker, "antigravity", "PreInvocation")
	cmd.Stdin = strings.NewReader(payload)
	cmd.Env = append([]string{
		"HOME=" + dir,
		BindEnvSession + "=warren-1",
		BindEnvFile + "=" + bindPath,
		BindEnvState + "=" + filepath.Join(dir, "state.json"),
		BindEnvKind + "=antigravity",
	}, env...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("hook failed: %v: %s", err, out)
	}
	data, err := os.ReadFile(bindPath)
	if err != nil {
		t.Fatalf("hook wrote no binding: %v", err)
	}
	var binding Binding
	if err := json.Unmarshal(data, &binding); err != nil {
		t.Fatalf("binding is not JSON: %v\n%s", err, data)
	}
	return binding
}

const agyPayload = `{"conversationId":"conv-1","transcriptPath":"/tmp/agy-work/antigravity-cli/brain/conv-1/.system_generated/logs/transcript.jsonl","workspacePaths":["/w"]}`

// The launcher states a relocated home in one variable; the hook carries it
// into the binding, which is how the daemon learns where the session keeps its
// engine state.
func TestBindHookRecordsAgentHome(t *testing.T) {
	binding := runBindHook(t, []string{EnvAgentHome + "=/tmp/agy-work"}, agyPayload)
	if binding.Home != "/tmp/agy-work" {
		t.Fatalf("home = %q", binding.Home)
	}
	if binding.SessionID != "conv-1" || binding.Provider != "antigravity" {
		t.Fatalf("binding = %+v", binding)
	}
}

// An engine that states its directory natively binds the same way, so a session
// started by hand reads like one a launcher created.
func TestBindHookFallsBackToNativeHome(t *testing.T) {
	for _, key := range []string{"CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "QODER_CONFIG_DIR"} {
		binding := runBindHook(t, []string{key + "=/tmp/native-home"}, agyPayload)
		if binding.Home != "/tmp/native-home" {
			t.Errorf("%s: home = %q", key, binding.Home)
		}
	}
}

// A launcher's variable wins over an engine variable inherited from elsewhere,
// or a session could be reported under its parent's directory.
func TestBindHookPrefersLauncherHome(t *testing.T) {
	binding := runBindHook(t, []string{
		EnvAgentHome + "=/tmp/launcher",
		"CODEX_HOME=/tmp/inherited",
	}, agyPayload)
	if binding.Home != "/tmp/launcher" {
		t.Fatalf("home = %q", binding.Home)
	}
}

// On the shared home nothing is reported, and the daemon's own defaults apply.
func TestBindHookOmitsHomeForSharedConfig(t *testing.T) {
	binding := runBindHook(t, nil, agyPayload)
	if binding.Home != "" {
		t.Fatalf("home = %q, want none", binding.Home)
	}
}

// Learning a home is what lets the next session bind exactly: the shared
// installation only covers the engine's default directory.
func TestEnsureBindHookForHome(t *testing.T) {
	cases := map[string]string{
		"claude":      "settings.json",
		"codex":       "hooks.json",
		"antigravity": filepath.Join("config", "hooks.json"),
		"qoder":       "settings.json",
	}
	for kind, want := range cases {
		home := t.TempDir()
		installed, err := EnsureBindHookForHome(kind, home)
		if err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		if !installed {
			t.Fatalf("%s: nothing installed", kind)
		}
		path := filepath.Join(home, want)
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		if !strings.Contains(string(data), hookCommandMarker) {
			t.Errorf("%s: %s does not name Warren's hook", kind, path)
		}
	}
}

// pi and opencode install one hook for the whole engine, not one per home.
func TestEnsureBindHookForHomeSkipsSharedEngines(t *testing.T) {
	for _, kind := range []string{"pi", "opencode", "unknown"} {
		installed, err := EnsureBindHookForHome(kind, t.TempDir())
		if err != nil || installed {
			t.Errorf("%s: installed=%v err=%v", kind, installed, err)
		}
	}
}

// A path that is not a directory is refused rather than written into.
func TestEnsureBindHookForHomeRejectsRelative(t *testing.T) {
	if _, err := EnsureBindHookForHome("codex", "relative/home"); err == nil {
		t.Error("a relative home was accepted")
	}
}

// A session that runs in a gemini_dir of its own keeps its conversations there,
// inside the product directory agy creates under it, and the binding says which
// gemini_dir that is.
func TestFindAntigravityTranscriptIn(t *testing.T) {
	const conversation = "conv-1"
	writeTranscript := func(t *testing.T, dir string) string {
		t.Helper()
		path := filepath.Join(dir, "brain", conversation, ".system_generated", "logs", "transcript.jsonl")
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}

	// The CLI's product directory under the gemini_dir.
	geminiDir := t.TempDir()
	want := writeTranscript(t, filepath.Join(geminiDir, "antigravity-cli"))
	if got := FindAntigravityTranscriptIn(geminiDir, conversation, ""); got != want {
		t.Errorf("cli layout: transcript = %q, want %q", got, want)
	}

	// The desktop build's conversations are another product's, even when they
	// sit in the same gemini_dir.
	desktopDir := t.TempDir()
	writeTranscript(t, filepath.Join(desktopDir, "antigravity"))
	if got := FindAntigravityTranscriptIn(desktopDir, conversation, ""); got != "" {
		t.Errorf("desktop layout: transcript = %q, want none", got)
	}

	// A directory that is already the product directory is taken as it is.
	productDir := t.TempDir() + "/antigravity-cli"
	want = writeTranscript(t, productDir)
	if got := FindAntigravityTranscriptIn(productDir, conversation, ""); got != want {
		t.Errorf("product dir: transcript = %q, want %q", got, want)
	}

	// The daemon's own home does not hold this conversation, so no default
	// lookup can stand in for the reported directory.
	if got := FindAntigravityTranscriptIn(t.TempDir(), conversation, ""); got != "" {
		t.Errorf("unrelated directory found %q", got)
	}
}

// A desktop build's conversations live under another product name in the same
// gemini_dir. They belong to that product, not to a CLI session running in the
// same workspace, so they are never a candidate.
func TestAntigravityTranscriptRootsSkipAnotherProduct(t *testing.T) {
	geminiDir := t.TempDir()
	desktop := filepath.Join(geminiDir, "antigravity")
	if err := os.MkdirAll(filepath.Join(desktop, "brain"), 0o700); err != nil {
		t.Fatal(err)
	}
	roots := AntigravityTranscriptRoots(geminiDir)
	if len(roots) != 1 || roots[0] != filepath.Join(geminiDir, "antigravity-cli") {
		t.Fatalf("roots = %q, want only the CLI product directory", roots)
	}
	// Pointed at directly, the CLI product directory is used as it is.
	if got := AntigravityTranscriptRoots(filepath.Join(geminiDir, "antigravity-cli")); len(got) != 1 || got[0] != filepath.Join(geminiDir, "antigravity-cli") {
		t.Errorf("product dir roots = %q", got)
	}
}

// A path that cannot go into the binding's JSON safely is left out, so the
// binding itself stays readable: a session without a directory binds as it did
// before, one with a corrupt binding binds not at all.
func TestBindHookDropsUnsafeHome(t *testing.T) {
	for _, home := range []string{`/tmp/with"quote`, "/tmp/with\nnewline"} {
		binding := runBindHook(t, []string{EnvAgentHome + "=" + home}, agyPayload)
		if binding.Home != "" {
			t.Errorf("%q: home = %q, want none", home, binding.Home)
		}
		if binding.SessionID != "conv-1" {
			t.Errorf("%q: the binding was lost", home)
		}
	}
}

// The hook goes into a directory the engine already uses. A path that is not
// there yet is skipped rather than created, since any process in the session
// can name it.
func TestEnsureBindHookForHomeRequiresTheDirectory(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "not-created")
	installed, err := EnsureBindHookForHome("claude", missing)
	if err != nil || installed {
		t.Fatalf("installed=%v err=%v", installed, err)
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Error("the directory was created")
	}
}
