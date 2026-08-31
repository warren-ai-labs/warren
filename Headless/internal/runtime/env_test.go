package runtime

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCleanEnvironmentFiltersLauncherContext(t *testing.T) {
	source := []string{
		"HOME=/home/test",
		"USER=test",
		"LOGNAME=test",
		"TMPDIR=/tmp/test",
		"LANG=en_US.UTF-8",
		"LC_CTYPE=UTF-8",
		"SHELL=/bin/sh",
		"PATH=/workspace/.mise/shims:/workspace/bin",
		"TERM=xterm-ghostty",
		"COLORTERM=truecolor",
		"TERM_PROGRAM=ghostty",
		"MISE_TASK=install",
		"DIRENV_DIFF=secret-diff",
		"CODEX_SESSION_ID=thread-from-installer",
		"CODEX_HOME=/home/test/.codex",
		"WARREN_SESSION_ID=foreign-session",
		"WARREN_STATE_FILE=/tmp/foreign.state",
		"WARREN_DATA_DIR=/home/test/.warren",
		"HTTP_PROXY=http://proxy.invalid",
		"OPENAI_API_KEY=must-not-cross",
		"NO_COLOR=1",
	}

	values := environmentMap(CleanEnvironment(source))
	for key, want := range map[string]string{
		"HOME":            "/home/test",
		"USER":            "test",
		"LOGNAME":         "test",
		"TMPDIR":          "/tmp/test",
		"LANG":            "en_US.UTF-8",
		"LC_CTYPE":        "UTF-8",
		"SHELL":           "/bin/sh",
		"TERM":            DefaultTerm,
		"COLORTERM":       "truecolor",
		"CODEX_HOME":      "/home/test/.codex",
		"WARREN_DATA_DIR": "/home/test/.warren",
	} {
		if values[key] != want {
			t.Errorf("%s = %q, want %q", key, values[key], want)
		}
	}
	if values["PATH"] != StablePath("/home/test") {
		t.Fatalf("PATH = %q, want stable host path %q", values["PATH"], StablePath("/home/test"))
	}
	for _, key := range []string{
		"TERM_PROGRAM", "MISE_TASK", "DIRENV_DIFF", "CODEX_SESSION_ID", "WARREN_SESSION_ID",
		"WARREN_STATE_FILE", "HTTP_PROXY", "OPENAI_API_KEY", "NO_COLOR",
	} {
		if _, ok := values[key]; ok {
			t.Errorf("%s leaked into clean environment", key)
		}
	}
}

func TestCleanEnvironmentKeepsOnlyValidSSHAgentSocket(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "warren-env-")
	if err != nil {
		t.Fatalf("create socket directory: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	socketPath := filepath.Join(directory, "agent.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix socket: %v", err)
	}
	defer listener.Close()

	values := environmentMap(CleanEnvironment([]string{
		"HOME=/home/test",
		"SHELL=/bin/sh",
		"SSH_AUTH_SOCK=" + socketPath,
		"SSH_AGENT_PID=1234",
	}))
	if values["SSH_AUTH_SOCK"] != socketPath {
		t.Fatalf("SSH_AUTH_SOCK = %q, want %q", values["SSH_AUTH_SOCK"], socketPath)
	}
	if _, ok := values["SSH_AGENT_PID"]; ok {
		t.Fatal("SSH_AGENT_PID leaked into clean environment")
	}

	values = environmentMap(CleanEnvironment([]string{
		"HOME=/home/test",
		"SHELL=/bin/sh",
		"SSH_AUTH_SOCK=" + filepath.Join(directory, "missing.sock"),
	}))
	if _, ok := values["SSH_AUTH_SOCK"]; ok {
		t.Fatal("invalid SSH_AUTH_SOCK was retained")
	}
}

func TestShellCommandWithUnsetsUsesLoginShell(t *testing.T) {
	command, err := ShellCommandWithUnsets("/bin/sh", []string{"CODEX_SESSION_ID", "PAGER", "CODEX_SESSION_ID"})
	if err != nil {
		t.Fatalf("ShellCommandWithUnsets: %v", err)
	}
	if want := "unset CODEX_SESSION_ID PAGER; exec '/bin/sh' -il"; command != want {
		t.Fatalf("command = %q, want %q", command, want)
	}
	if got := LoginShellArgs(); len(got) != 1 || got[0] != "-il" {
		t.Fatalf("LoginShellArgs = %#v, want [-il]", got)
	}
	if _, err := ShellCommandWithUnsets("/bin/sh", []string{"BAD-NAME"}); err == nil {
		t.Fatal("invalid unset key was accepted")
	}
}

func TestCleanEnvironmentSortsEntries(t *testing.T) {
	entries := CleanEnvironment([]string{"HOME=/home/test", "SHELL=/bin/sh"})
	if !strings.HasPrefix(entries[0], "COLORTERM=") {
		t.Fatalf("clean environment is not sorted: %#v", entries)
	}
}

func TestSanitizeEnvironmentRemovesAgentPagerOverrides(t *testing.T) {
	t.Setenv("GIT_PAGER", "cat")
	t.Setenv("PAGER", "cat")
	t.Setenv("GH_PAGER", "cat")
	t.Setenv("TERM", "dumb")
	t.Setenv("NO_COLOR", "1")

	SanitizeEnvironment()

	for _, key := range []string{"GIT_PAGER", "PAGER", "GH_PAGER"} {
		if got := os.Getenv(key); got != "" {
			t.Errorf("%s = %q, want unset", key, got)
		}
	}
	if got := os.Getenv("TERM"); got != DefaultTerm {
		t.Errorf("TERM = %q, want %q", got, DefaultTerm)
	}
	if _, ok := os.LookupEnv("NO_COLOR"); ok {
		t.Error("NO_COLOR remained set; want it unset")
	}
}

func TestSanitizeEnvironmentTreatsEmptyPagerAsDisabled(t *testing.T) {
	t.Setenv("GIT_PAGER", "")
	t.Setenv("PAGER", "")
	t.Setenv("GH_PAGER", "")
	t.Setenv("TERM", "")

	SanitizeEnvironment()

	for _, key := range []string{"GIT_PAGER", "PAGER", "GH_PAGER"} {
		if got := os.Getenv(key); got != "" {
			t.Errorf("%s = %q, want unset", key, got)
		}
	}
	if got := os.Getenv("TERM"); got != DefaultTerm {
		t.Errorf("TERM = %q, want %q", got, DefaultTerm)
	}
}

func TestSanitizeEnvironmentKeepsUserPagerAndTerm(t *testing.T) {
	t.Setenv("GIT_PAGER", "less -R")
	t.Setenv("PAGER", "less")
	t.Setenv("GH_PAGER", "less")
	t.Setenv("TERM", "xterm-ghostty")

	SanitizeEnvironment()

	for key, want := range map[string]string{
		"GIT_PAGER": "less -R",
		"PAGER":     "less",
		"GH_PAGER":  "less",
		"TERM":      "xterm-ghostty",
	} {
		if got := os.Getenv(key); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
}
