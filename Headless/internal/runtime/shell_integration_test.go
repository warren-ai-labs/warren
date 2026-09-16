package runtime

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteShellIntegrationMaterializesScripts(t *testing.T) {
	dir := t.TempDir()
	if err := WriteShellIntegration(dir); err != nil {
		t.Fatalf("WriteShellIntegration: %v", err)
	}
	for _, relative := range []string{
		filepath.Join("zsh", ".zshenv"),
		filepath.Join("fish", "vendor_conf.d", "warren.fish"),
	} {
		if _, err := os.Stat(filepath.Join(dir, relative)); err != nil {
			t.Fatalf("missing %s: %v", relative, err)
		}
	}
}

func TestApplyShellIntegrationForZsh(t *testing.T) {
	dir := t.TempDir()
	t.Setenv(ShellIntegrationDirEnv, dir)
	t.Setenv("ZDOTDIR", "")

	plan := ApplyShellIntegration("/bin/zsh", []string{"HOME=/tmp/home", "ZDOTDIR=/custom/zsh"})
	if got := lookupEnvironment(plan.Env, "ZDOTDIR"); got != filepath.Join(dir, "zsh") {
		t.Fatalf("ZDOTDIR = %q, want the integration dir", got)
	}
	if got := lookupEnvironment(plan.Env, "WARREN_ZSH_ZDOTDIR"); got != "/custom/zsh" {
		t.Fatalf("WARREN_ZSH_ZDOTDIR = %q, want the original ZDOTDIR", got)
	}
	if got := lookupEnvironment(plan.Env, "HOME"); got != "/tmp/home" {
		t.Fatalf("HOME = %q, want the session value", got)
	}
	if got := lookupEnvironment(plan.Env, "XDG_DATA_DIRS"); got == "" {
		t.Fatal("zsh plan must also advertise the fish integration directory")
	}
	if len(plan.Args) != 1 || plan.Args[0] != "-il" {
		t.Fatalf("args = %#v, want [-il]", plan.Args)
	}
}

func TestApplyShellIntegrationForFish(t *testing.T) {
	dir := t.TempDir()
	t.Setenv(ShellIntegrationDirEnv, dir)

	plan := ApplyShellIntegration("/opt/homebrew/bin/fish", []string{"XDG_DATA_DIRS=/opt/share"})
	want := dir + string(os.PathListSeparator) + "/opt/share"
	if got := lookupEnvironment(plan.Env, "XDG_DATA_DIRS"); got != want {
		t.Fatalf("XDG_DATA_DIRS = %q, want %q", got, want)
	}
	if got := lookupEnvironment(plan.Env, ShellIntegrationDirEnv); got != dir {
		t.Fatalf("%s = %q, want %q", ShellIntegrationDirEnv, got, dir)
	}
	if got := lookupEnvironment(plan.Env, "ZDOTDIR"); got != filepath.Join(dir, "zsh") {
		t.Fatalf("fish plan must also advertise the zsh integration directory, got %q", got)
	}
}

func TestApplyShellIntegrationLeavesUnsupportedShellAlone(t *testing.T) {
	t.Setenv(ShellIntegrationDirEnv, t.TempDir())
	env := []string{"HOME=/tmp/home"}
	plan := ApplyShellIntegration("/bin/tcsh", env)
	if len(plan.Env) != 1 || plan.Env[0] != env[0] {
		t.Fatalf("environment changed for an unsupported shell: %#v", plan.Env)
	}
	if len(plan.Args) != 1 || plan.Args[0] != "-il" {
		t.Fatalf("args = %#v, want the default login args", plan.Args)
	}
}

func TestSetEnvironmentReplacesEveryDuplicate(t *testing.T) {
	env := setEnvironment([]string{"A=1", "B=2", "A=3"}, "A", "4")
	if len(env) != 2 || env[0] != "A=4" || env[1] != "B=2" {
		t.Fatalf("setEnvironment = %#v", env)
	}
}
