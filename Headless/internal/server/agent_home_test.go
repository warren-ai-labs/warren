package server

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// fakeEngine writes a program that sleeps, named after an engine, and starts it
// with env: the process a launcher would leave behind.
func fakeEngine(t *testing.T, name string, env ...string) int {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nsleep 30\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(path)
	cmd.Env = append(append([]string{"HOME=" + dir, "PATH=/usr/bin:/bin"}, env...), "WARREN_TEST_SLEEP=1")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	// ps needs a moment to see the process's environment.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, home, ok := engineHomeOf(cmd.Process.Pid); ok && home != "" {
			return cmd.Process.Pid
		}
		time.Sleep(20 * time.Millisecond)
	}
	return cmd.Process.Pid
}

// A launcher states a relocated home in the session's environment. Linux lets
// another process of the same user read it; macOS does not, and there the
// engine's own arguments are the only pre-launch answer.
func TestEngineHomeOfReadsLauncherEnv(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("macOS does not expose another process's environment")
	}
	for _, c := range []struct{ program, key, kind string }{
		{"claude", "WARREN_AGENT_HOME", "claude"},
		{"claude", "CLAUDE_CONFIG_DIR", "claude"},
		{"codex", "CODEX_HOME", "codex"},
	} {
		home := t.TempDir()
		pid := fakeEngine(t, c.program, c.key+"="+home)
		kind, got, ok := engineHomeOf(pid)
		if !ok {
			t.Fatalf("%s/%s: no home found", c.program, c.key)
		}
		if kind != c.kind || got != home {
			t.Errorf("%s/%s: kind=%q home=%q, want %q/%q", c.program, c.key, kind, got, c.kind, home)
		}
	}
}

// macOS answers with the path and arguments of another process, which is
// enough for the engine that states its directory as a flag.
func TestEngineHomeOfUsesArguments(t *testing.T) {
	home := t.TempDir()
	dir := t.TempDir()
	path := filepath.Join(dir, "agy")
	script := "#!/bin/sh\nsleep 30\n"
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(path, "--gemini_dir", home)
	cmd.Env = []string{"PATH=/usr/bin:/bin"}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if kind, got, ok := engineHomeOf(cmd.Process.Pid); ok {
			if kind != "antigravity" || got != home {
				t.Fatalf("kind=%q home=%q", kind, got)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("argv home was not found")
}

// agy states its directory as a flag, which no environment variable can
// replace.
func TestEngineHomeOfReadsGeminiDirFlag(t *testing.T) {
	home := t.TempDir()
	if got := geminiDirFlag("/usr/local/bin/agy --gemini_dir " + home + " --model m"); got != home {
		t.Errorf("separate argument: %q", got)
	}
	if got := geminiDirFlag("agy --gemini_dir=" + home); got != home {
		t.Errorf("equals form: %q", got)
	}
	if got := geminiDirFlag("agy --model m"); got != "" {
		t.Errorf("no flag: %q", got)
	}
}

// A process that is not an engine, or says nothing about a directory, is not a
// home: guessing one would arm the wrong directory.
func TestEngineHomeOfIgnoresOtherProcesses(t *testing.T) {
	if _, _, ok := engineHomeOf(os.Getpid()); ok {
		t.Error("the test process was taken for an engine")
	}
	pid := fakeEngine(t, "claude")
	if _, home, ok := engineHomeOf(pid); ok {
		t.Errorf("engine without a home reported %q", home)
	}
}

// Creating a shell Session scans the process table, so the cwds of the
// candidates are resolved together: one pid that has already exited must not
// cost a subprocess, nor lose the directories of the rest.
func TestEngineCwdsResolveEveryPidInOneScan(t *testing.T) {
	want, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	cwds := engineCwds([]int{os.Getpid(), 999999})
	if got, ok := cwds[os.Getpid()]; !ok || !samePath(got, want) {
		t.Fatalf("engine cwd = %q, want %q", got, want)
	}
	if cwd, ok := cwds[999999]; ok {
		t.Fatalf("exited process reported cwd %q", cwd)
	}
}

// Learning arms the hook where the engine keeps its files, which is what makes
// the next turn bind exactly instead of falling back to cwd and mtime.
func TestLearnAgentHomesArmsTheHook(t *testing.T) {
	workspace := t.TempDir()
	home := t.TempDir()
	// agy names its directory on the command line, which both platforms can
	// read, so this covers the learning path everywhere.
	pid := agyInWorkspace(t, workspace, home)
	if !processRunning(pid) {
		t.Fatal("workspace engine did not start")
	}

	s := &Service{}
	homes := s.learnAgentHomes(workspace)
	if len(homes) != 1 || homes[0] != home {
		t.Fatalf("homes = %q, want %q", homes, home)
	}
	if _, err := os.Stat(filepath.Join(home, "config", "hooks.json")); err != nil {
		t.Fatalf("hook was not installed: %v", err)
	}
	// The slot bounds how often a workspace is inspected; a second call in the
	// same window must not repeat the work.
	if again := s.learnAgentHomes(workspace); len(again) != 0 {
		t.Errorf("second call in the same window returned %q", again)
	}
}

// agyInWorkspace starts a fake agy with its cwd in the workspace and its
// gemini_dir on the command line: the process a launcher leaves behind.
func agyInWorkspace(t *testing.T, workspace, home string) int {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "agy")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nsleep 30\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(path, "--gemini_dir", home)
	cmd.Dir = workspace
	cmd.Env = []string{"PATH=/usr/bin:/bin"}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	time.Sleep(150 * time.Millisecond)
	return cmd.Process.Pid
}

// processRunning reports whether a pid is still alive.
func processRunning(pid int) bool {
	return processAlive(pid)
}

// A directory already known answers before the process table is read at all,
// and the order is the one Warren learned it in: the daemon's own first, then
// each reported directory once.
func TestHomesForKeepsDiscoveryOrder(t *testing.T) {
	s := &Service{}
	ambient := ambientHome("antigravity")
	if ambient == "" {
		t.Skip("no ambient antigravity home in this environment")
	}
	first, second := t.TempDir(), t.TempDir()
	s.rememberHome("antigravity", first)
	s.rememberHome("antigravity", second)
	// Learning the same directory twice must not duplicate it.
	s.rememberHome("antigravity", first)

	got := s.homesFor("antigravity")
	want := []string{ambient, first, second}
	if len(got) != len(want) {
		t.Fatalf("homes = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("homes = %q, want %q", got, want)
		}
	}
}

// Learning appends to that order, so the next session tries the new directory
// without asking the process table again.
func TestLearnAgentHomesRemembersTheDirectory(t *testing.T) {
	workspace := t.TempDir()
	home := t.TempDir()
	pid := agyInWorkspace(t, workspace, home)
	if !processRunning(pid) {
		t.Fatal("workspace engine did not start")
	}

	s := &Service{}
	if learned := s.learnAgentHomes(workspace); len(learned) != 1 {
		t.Fatalf("learned = %q", learned)
	}
	remembered := false
	for _, candidate := range s.homesFor("antigravity") {
		remembered = remembered || candidate == home
	}
	if !remembered {
		t.Errorf("homes = %q, want %q among them", s.homesFor("antigravity"), home)
	}
}

// Two sessions in one workspace, neither with a hook: the conversation a
// directory holds is picked by workspace and time, so the first to claim it
// keeps it and the other waits for its own hook instead of sharing it.
func TestAntigravityTranscriptIsNotSharedByTwoSessions(t *testing.T) {
	s := &Service{}
	state := api.State{Sessions: []api.Session{{ID: "first", Lifecycle: "running", TranscriptPath: "/tmp/conv/transcript.jsonl"}}}
	if s.claimable(state, "second", "/tmp/conv/transcript.jsonl") {
		t.Error("a conversation another running session holds was claimed")
	}
	if !s.claimable(state, "first", "/tmp/conv/transcript.jsonl") {
		t.Error("a session was refused the transcript it already holds")
	}
	// A session that has stopped holding it does not block the next one.
	stopped := api.State{Sessions: []api.Session{{ID: "first", Lifecycle: "exited", TranscriptPath: "/tmp/conv/transcript.jsonl"}}}
	if !s.claimable(stopped, "second", "/tmp/conv/transcript.jsonl") {
		t.Error("a stopped session still held its transcript")
	}
	if !s.claimable(state, "second", "/tmp/conv/other.jsonl") {
		t.Error("a free conversation was refused")
	}
	if s.claimable(state, "second", "") {
		t.Error("an empty path was claimed")
	}
}

// The directory search runs on its own cadence: reading every candidate's
// conversation summaries on each reconcile tick would be wasted work.
func TestHomeScanIsThrottled(t *testing.T) {
	s := &Service{}
	if !s.homeScanDue("session-1") {
		t.Fatal("the first search was refused")
	}
	if s.homeScanDue("session-1") {
		t.Error("the second search in the same window ran")
	}
	if !s.homeScanDue("session-2") {
		t.Error("a different session was throttled by another's search")
	}
}

// The learned list keeps its discovery order and drops the oldest, so a
// directory nobody uses any more cannot grow the search forever.
func TestRememberHomeBoundsTheList(t *testing.T) {
	s := &Service{}
	first := "/tmp/home-0"
	s.rememberHome("claude", first)
	for i := 1; i < maxLearnedHomes+4; i++ {
		s.rememberHome("claude", fmt.Sprintf("/tmp/home-%d", i))
	}
	order := s.agentHomes.order["claude"]
	if len(order) != maxLearnedHomes {
		t.Fatalf("kept %d homes, want %d", len(order), maxLearnedHomes)
	}
	for _, home := range order {
		if home == first {
			t.Error("the oldest home was kept")
		}
	}
	if last := order[len(order)-1]; last != fmt.Sprintf("/tmp/home-%d", maxLearnedHomes+3) {
		t.Errorf("last = %q, want the most recent", last)
	}
}
