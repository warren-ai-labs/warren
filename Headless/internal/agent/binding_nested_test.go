package agent

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The managed hook belongs to the agent CLI its Session runs, but the bind
// environment is inherited by every descendant of the Session's shell. A CLI
// that another agent starts -- a scripted `codex exec`, a delegated run, a test
// harness -- therefore fires the hook inside the Session it was started from.
// These tests build the process ancestries that decide the outcome instead of
// relying on whatever spawned the test binary.

const (
	hookHelperEnv     = "WARREN_BIND_HOOK_HELPER"
	hookHelperScript  = "WARREN_BIND_HOOK_HELPER_SCRIPT"
	hookHelperPayload = "WARREN_BIND_HOOK_HELPER_PAYLOAD"
	hookHelperEntry   = "WARREN_BIND_HOOK_HELPER_ENTRY"
)

// TestBindHookHelperProcess is not a test: it is the process a chain below
// invokes when the hook must sit under a process that is neither a shell nor an
// agent, which is what the daemon that allocates a Session's PTY looks like. The
// test binary's own name provides that boundary.
func TestBindHookHelperProcess(t *testing.T) {
	if os.Getenv(hookHelperEnv) == "" {
		t.Skip("helper process invoked by TestBindHookNested*")
	}
	script := os.Getenv(hookHelperScript)
	payload := os.Getenv(hookHelperPayload)
	command := exec.Command("bash", script, hookCommandMarker, "codex")
	// A boundary sometimes has to run a chain instead of the hook itself, so a
	// test can put a script between the Session's own CLI and the boundary.
	if entry := os.Getenv(hookHelperEntry); entry != "" {
		command = exec.Command(entry)
	}
	command.Stdin = strings.NewReader(payload)
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		t.Fatalf("run hook in helper process: %v", err)
	}
}

// writeAgentWrapper writes an executable whose process name is an agent CLI, so
// the hook's ancestry walk recognizes it. A shell script named `codex` runs as
// `/bin/sh .../codex`, which is how these CLIs also appear.
func writeAgentWrapper(t *testing.T, directory, name, body string) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// writeInterpreterHop writes an executable script and a launcher that wears an
// interpreter's process name and takes that script as its first argument, so
// the hook's ancestry walk sees exactly what `node probe.mjs` looks like.
func writeInterpreterHop(t *testing.T, directory, scriptName, body string) string {
	t.Helper()
	script := filepath.Join(directory, scriptName)
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return writeAgentWrapper(t, directory, "node",
		"exec bash -c 'exec -a node /bin/sh \"$1\"' _ '"+script+"'")
}

func sessionStartPayload() string {
	return `{"hook_event_name":"SessionStart","session_id":"codex-1","transcript_path":"/tmp/rollout.jsonl","cwd":"/tmp"}`
}

// bindHookChain sets up one ancestry and returns the paths the hook writes.
type bindHookChain struct {
	script    string
	bindPath  string
	statePath string
	chainDir  string
}

func newBindHookChain(t *testing.T) bindHookChain {
	t.Helper()
	t.Setenv("WARREN_DATA_DIR", t.TempDir())
	if _, err := EnsureCodexBindHook(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	return bindHookChain{
		script:    filepath.Join(configDir(), "hooks", "agent-bind.sh"),
		bindPath:  filepath.Join(t.TempDir(), "bind.json"),
		statePath: filepath.Join(t.TempDir(), "bind.state"),
		chainDir:  t.TempDir(),
	}
}

func (chain bindHookChain) env(extra ...string) []string {
	entries := append(os.Environ(),
		BindEnvFile+"="+chain.bindPath,
		BindEnvState+"="+chain.statePath,
		BindEnvSession+"=warren-1",
	)
	return append(entries, extra...)
}

func (chain bindHookChain) run(t *testing.T, payload string, entry string, extra ...string) {
	t.Helper()
	command := exec.Command(entry)
	command.Env = chain.env(append(extra, hookHelperPayload+"="+payload)...)
	out, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("run %s: %v\n%s", filepath.Base(entry), err, out)
	}
}

func (chain bindHookChain) bindingWritten() bool {
	info, err := os.Stat(chain.bindPath)
	return err == nil && info.Size() > 0
}

func (chain bindHookChain) anyWrite() bool {
	if chain.bindingWritten() {
		return true
	}
	_, err := os.Stat(chain.statePath)
	return err == nil
}

// TestBindHookRefusesToBindInsideAnotherAgent is the reported bug: a Pi Session
// whose nested `codex exec` overwrote the Session's binding, so the Session
// switched provider and transcript under the user and its icon followed.
func TestBindHookRefusesToBindInsideAnotherAgent(t *testing.T) {
	chain := newBindHookChain(t)
	// codex is the CLI that fired the hook; pi is the agent that started it.
	codex := writeAgentWrapper(t, chain.chainDir, "codex",
		"printf '%s' \"$"+hookHelperPayload+"\" | bash '"+chain.script+"' "+hookCommandMarker+" codex")
	pi := writeAgentWrapper(t, chain.chainDir, "pi", codex)

	chain.run(t, sessionStartPayload(), pi)
	if chain.bindingWritten() {
		t.Fatalf("a nested agent took the Session over: %s", readFileOrEmpty(chain.bindPath))
	}
	// A nested agent's exit must not report the outer Session as exited either:
	// that clears the projection of an agent that is still running.
	chain.run(t, `{"hook_event_name":"SessionEnd","session_id":"codex-1"}`, pi)
	if chain.anyWrite() {
		t.Fatalf("a nested agent wrote Session state: binding=%v state=%s",
			chain.bindingWritten(), readFileOrEmpty(chain.statePath))
	}
}

// TestBindHookBindsThroughAnInterpreterLauncher covers the launcher npm ships
// for codex: `node /opt/homebrew/bin/codex` spawns the native binary, so the
// same CLI name appears on two consecutive hops. That is one CLI reaching
// itself, and refusing it left every such Session a plain shell -- which is
// what took the Codex icon, activity, and title away.
func TestBindHookBindsThroughAnInterpreterLauncher(t *testing.T) {
	chain := newBindHookChain(t)
	native := writeAgentWrapper(t, chain.chainDir, "codex",
		"printf '%s' \"$"+hookHelperPayload+"\" | bash '"+chain.script+"' "+hookCommandMarker+" codex")
	npmDirectory := filepath.Join(chain.chainDir, "npm")
	if err := os.MkdirAll(npmDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	shim := writeAgentWrapper(t, npmDirectory, "codex", "/bin/sh '"+native+"'")
	// The launcher wears the interpreter's process name and takes the CLI it
	// starts as its own first argument, so the walk sees `node .../codex` sitting
	// directly above `.../codex` -- npm's shape, twice over.
	launcher := writeAgentWrapper(t, chain.chainDir, "launch",
		"exec bash -c 'exec -a node /bin/sh \"$1\"' _ '"+shim+"'")

	chain.run(t, sessionStartPayload(), launcher)
	if !chain.bindingWritten() {
		t.Fatal("a CLI reached through its interpreter launcher must still bind")
	}
	if !strings.Contains(readFileOrEmpty(chain.bindPath), `"provider":"codex"`) {
		t.Fatalf("binding = %s", readFileOrEmpty(chain.bindPath))
	}
}

// TestBindHookRefusesACodexStartedByAnotherCodex keeps the launcher exception
// narrow: the same name on two hops is one CLI only when the upper hop is an
// interpreter. A codex that another codex started directly still loses.
func TestBindHookRefusesACodexStartedByAnotherCodex(t *testing.T) {
	chain := newBindHookChain(t)
	inner := writeAgentWrapper(t, chain.chainDir, "codex",
		"printf '%s' \"$"+hookHelperPayload+"\" | bash '"+chain.script+"' "+hookCommandMarker+" codex")
	outerDirectory := filepath.Join(chain.chainDir, "outer")
	if err := os.MkdirAll(outerDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	outer := writeAgentWrapper(t, outerDirectory, "codex", "/bin/sh '"+inner+"'")

	chain.run(t, sessionStartPayload(), outer)
	if chain.bindingWritten() {
		t.Fatalf("a codex started by another codex took the Session over: %s",
			readFileOrEmpty(chain.bindPath))
	}
}

// TestBindHookBindsWhenNoAgentIsAboveTheShellLayer keeps the guard from
// refusing a Session that is legitimately its own: the test binary plays the
// daemon that allocated the PTY, so the agent CLIs are separated from the hook
// by a process that is neither a shell nor an agent.
func TestBindHookBindsWhenNoAgentIsAboveTheShellLayer(t *testing.T) {
	chain := newBindHookChain(t)
	boundary := writeAgentWrapper(t, chain.chainDir, "codex",
		hookHelperEnv+"=1 "+hookHelperScript+"='"+chain.script+"' '"+os.Args[0]+"' -test.run=TestBindHookHelperProcess")
	pi := writeAgentWrapper(t, chain.chainDir, "pi", boundary)

	chain.run(t, sessionStartPayload(), pi,
		hookHelperEnv+"=1", hookHelperScript+"="+chain.script)
	if !chain.bindingWritten() {
		t.Fatal("a Session whose CLI is not nested must still bind")
	}
	if !strings.Contains(readFileOrEmpty(chain.bindPath), `"provider":"codex"`) {
		t.Fatalf("binding = %s", readFileOrEmpty(chain.bindPath))
	}
}

// TestBindHookRefusesAProviderTheSessionWasNotCreatedFor covers the cheap
// rejection: a Session created for one provider says so in its environment, so
// another provider's hook running there is nested without walking anything.
func TestBindHookRefusesAProviderTheSessionWasNotCreatedFor(t *testing.T) {
	chain := newBindHookChain(t)
	command := exec.Command("bash", chain.script, hookCommandMarker, "codex")
	command.Env = chain.env(BindEnvKind + "=claude")
	command.Stdin = strings.NewReader(sessionStartPayload())
	if out, err := command.CombinedOutput(); err != nil {
		t.Fatalf("run hook: %v\n%s", err, out)
	}
	if chain.anyWrite() {
		t.Fatalf("a foreign provider wrote into a claude Session: binding=%v state=%s",
			chain.bindingWritten(), readFileOrEmpty(chain.statePath))
	}
}

// TestBindHookRefusesAnAgentStartedByAScript covers the shape a probe script
// produces: the agent that fired the hook is a direct child of an interpreter
// running a file, and that interpreter is a child of the agent whose Session is
// being taken over. Treating the interpreter hop as the boundary let a
// `node probe.mjs` that an agent ran rebind the Session to the agent the probe
// started -- reported as a Claude Session in the `vireo` project whose icon
// became Pi after a nested probe.
func TestBindHookRefusesAnAgentStartedByAScript(t *testing.T) {
	chain := newBindHookChain(t)
	codex := writeAgentWrapper(t, chain.chainDir, "codex",
		"printf '%s' \"$"+hookHelperPayload+"\" | bash '"+chain.script+"' "+hookCommandMarker+" codex")
	probe := writeInterpreterHop(t, chain.chainDir, "probe.mjs", "/bin/sh '"+codex+"'")
	shellHop := writeAgentWrapper(t, chain.chainDir, "shellhop", "/bin/sh '"+probe+"'")
	pi := writeAgentWrapper(t, chain.chainDir, "pi", "/bin/sh '"+shellHop+"'")

	chain.run(t, sessionStartPayload(), pi)
	if chain.bindingWritten() {
		t.Fatalf("an agent a nested script started took the Session over: %s",
			readFileOrEmpty(chain.bindPath))
	}
}

// TestBindHookBindsThroughAScriptWhenNoAgentIsAbove keeps the walk from ending
// at the script: a probe run at the Session's prompt is its own CLI to bind, and
// the daemon above the shell is still the boundary.
func TestBindHookBindsThroughAScriptWhenNoAgentIsAbove(t *testing.T) {
	chain := newBindHookChain(t)
	codex := writeAgentWrapper(t, chain.chainDir, "codex",
		"printf '%s' \"$"+hookHelperPayload+"\" | bash '"+chain.script+"' "+hookCommandMarker+" codex")
	probe := writeInterpreterHop(t, chain.chainDir, "probe.mjs", "/bin/sh '"+codex+"'")
	// The test binary plays the daemon that allocated the PTY, one hop above the
	// script the Session's shell started.
	boundary := writeAgentWrapper(t, chain.chainDir, "session-shell",
		hookHelperEntry+"='"+probe+"' '"+os.Args[0]+"' -test.run=TestBindHookHelperProcess")

	chain.run(t, sessionStartPayload(), boundary,
		hookHelperEnv+"=1", hookHelperScript+"="+chain.script)
	if !chain.bindingWritten() {
		t.Fatal("a Session whose CLI is reached through a script must still bind")
	}
	if !strings.Contains(readFileOrEmpty(chain.bindPath), `"provider":"codex"`) {
		t.Fatalf("binding = %s", readFileOrEmpty(chain.bindPath))
	}
}

func readFileOrEmpty(path string) string {
	data, _ := os.ReadFile(path)
	return strings.TrimSpace(string(data))
}
