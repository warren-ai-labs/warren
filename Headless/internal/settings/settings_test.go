package settings

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizedDefaultsToGhostline(t *testing.T) {
	if (Settings{}).Normalized() != RuntimeGhostline {
		t.Fatalf("empty settings normalized = %q", (Settings{}).Normalized())
	}
	if (Settings{DefaultRuntime: RuntimeTmux}).Normalized() != RuntimeTmux {
		t.Fatal("tmux setting not preserved")
	}
	if (Settings{DefaultRuntime: "bogus"}).Normalized() != RuntimeGhostline {
		t.Fatal("invalid setting must fall back to ghostline")
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	value := Settings{
		DefaultRuntime:     RuntimeTmux,
		RuntimeEnv:         map[string]string{"GIT_PAGER": "less", "TERM": "xterm-256color"},
		GnarEdge:           "https://gnar.example.com",
		TunnelEnabled:      map[string]bool{"gnar": true},
		ImportGitWorktrees: true,
	}
	if err := Save(path, value); err != nil {
		t.Fatalf("Save: %v", err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.DefaultRuntime != RuntimeTmux {
		t.Fatalf("loaded default = %q", loaded.DefaultRuntime)
	}
	if loaded.RuntimeEnv["GIT_PAGER"] != "less" || loaded.RuntimeEnv["TERM"] != "xterm-256color" {
		t.Fatalf("loaded runtimeEnv = %#v", loaded.RuntimeEnv)
	}
	if loaded.GnarEdge != "https://gnar.example.com" {
		t.Fatalf("loaded gnarEdge = %q", loaded.GnarEdge)
	}
	if !loaded.TunnelEnabled["gnar"] {
		t.Fatalf("loaded tunnelEnabled = %#v, want gnar restored", loaded.TunnelEnabled)
	}
	if !loaded.ImportGitWorktrees {
		t.Fatal("loaded importGitWorktrees = false, want true")
	}
}

func TestLoadMissingFileYieldsDefaults(t *testing.T) {
	loaded, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatalf("Load missing: %v", err)
	}
	if loaded.Normalized() != RuntimeGhostline {
		t.Fatalf("missing file normalized = %q", loaded.Normalized())
	}
}

func TestApplyRuntimeEnvOverridesAndUnsets(t *testing.T) {
	t.Setenv("GIT_PAGER", "cat")
	t.Setenv("PAGER", "cat")
	t.Setenv("TERM", "dumb")

	value := Settings{RuntimeEnv: map[string]string{
		"GIT_PAGER": "less",
		"PAGER":     "",
		"TERM":      "xterm-256color",
	}}
	value.ApplyRuntimeEnv()

	if got := os.Getenv("GIT_PAGER"); got != "less" {
		t.Errorf("GIT_PAGER = %q, want less", got)
	}
	if got := os.Getenv("PAGER"); got != "" {
		t.Errorf("PAGER = %q, want unset", got)
	}
	if got := os.Getenv("TERM"); got != "xterm-256color" {
		t.Errorf("TERM = %q, want xterm-256color", got)
	}
}
