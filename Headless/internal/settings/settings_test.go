package settings

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/releaseconfig"
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
		DefaultRuntime: RuntimeTmux,
		RuntimeEnv:     map[string]string{"GIT_PAGER": "less", "TERM": "xterm-256color"},
		GnarEdge:       "https://gnar.example.com",
		GnarAccount:    "personal",
		TunnelEnabled:  map[string]bool{"gnar": true},
		AutoOpenShell:  true,
		AutoStartAI:    true,
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
	if loaded.GnarAccount != "personal" {
		t.Fatalf("loaded gnarAccount = %q", loaded.GnarAccount)
	}
	if !loaded.TunnelEnabled["gnar"] {
		t.Fatalf("loaded tunnelEnabled = %#v, want gnar restored", loaded.TunnelEnabled)
	}
	if !loaded.AutoOpenShell {
		t.Fatal("loaded autoOpenShell = false, want true")
	}
	if !loaded.AutoStartAI {
		t.Fatal("loaded autoStartAI = false, want true")
	}
}

func TestNormalizedGnarAccountUsesSafeDefault(t *testing.T) {
	if got := NormalizedGnarAccount(""); got != DefaultGnarAccount {
		t.Fatalf("empty gnar account = %q, want %q", got, DefaultGnarAccount)
	}
	if got := NormalizedGnarAccount("  "); got != DefaultGnarAccount {
		t.Fatalf("blank gnar account = %q, want %q", got, DefaultGnarAccount)
	}
	if got := NormalizedGnarAccount("personal"); got != "personal" {
		t.Fatalf("account = %q", got)
	}
	if got := NormalizedGnarAccount("bad\naccount"); got != DefaultGnarAccount {
		t.Fatalf("control character account = %q, want %q", got, DefaultGnarAccount)
	}
}

func TestBuiltInGnarEdgeReadsReleaseInjectedValueWithoutPersistingIt(t *testing.T) {
	previous := releaseconfig.DefaultGnarEdge
	t.Cleanup(func() { releaseconfig.DefaultGnarEdge = previous })
	releaseconfig.DefaultGnarEdge = "  https://release.example.com/  "
	if got := BuiltInGnarEdge(); got != "https://release.example.com/" {
		t.Fatalf("built-in gnar edge = %q", got)
	}
	if (Settings{}).GnarEdge != "" {
		t.Fatal("release default must not become a persisted settings override")
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
