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
	if (Settings{DefaultRuntime: RuntimeGhostline}).Normalized() != RuntimeGhostline {
		t.Fatal("ghostline setting not preserved")
	}
	if (Settings{DefaultRuntime: "bogus"}).Normalized() != RuntimeGhostline {
		t.Fatal("invalid setting must fall back to ghostline")
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	value := Settings{
		DefaultRuntime: RuntimeGhostline,
		RuntimeEnv:     map[string]string{"GIT_PAGER": "less", "TERM": "xterm-256color"},
		Relay: RelaySettings{
			Enabled:    true,
			URL:        "https://relay.example.com",
			HostID:     "00000000-0000-4000-8000-000000000001",
			RouteID:    "route-1",
			RelayKeyID: "key-1",
			RelayKey:   "public-key",
		},
		PublicTunnel: PublicTunnelSettings{
			Enabled:        true,
			RouteID:        "route-1",
			Owner:          "host",
			PublicHostname: "public.example.com",
			AuthMode:       "public",
		},
		AutoOpenShell:      true,
		AutoStartAI:        true,
		OpenAIBaseURL:      "https://api.openai.com/v1",
		OpenAIModel:        "gpt-4.1-mini",
		OpenAIKey:          "test-key",
		OpenAITitleEnabled: true,
	}
	if err := Save(path, value); err != nil {
		t.Fatalf("Save: %v", err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.DefaultRuntime != RuntimeGhostline || loaded.RuntimeEnv["GIT_PAGER"] != "less" {
		t.Fatalf("loaded runtime settings = %#v", loaded)
	}
	if !loaded.Relay.Enabled || loaded.Relay.RouteID != "route-1" || !loaded.PublicTunnel.Enabled || loaded.PublicTunnel.AuthMode != "public" {
		t.Fatalf("loaded relay settings = %#v", loaded)
	}
	if !loaded.AutoOpenShell || !loaded.AutoStartAI || !loaded.OpenAITitleEnabled || loaded.OpenAIKey != "test-key" {
		t.Fatalf("loaded optional settings = %#v", loaded)
	}
}

func TestLoadRejectsRemovedTmuxRuntime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte(`{"defaultRuntime":"tmux"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("Load accepted removed tmux runtime")
	}
}

func TestLoadIgnoresRemovedLegacyReachabilitySettings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte(`{"legacyEdge":"https://old.example","legacyAccount":"old","legacyTunnel":{"enabled":true}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Relay.Enabled || loaded.PublicTunnel.Enabled {
		t.Fatalf("removed reachability settings changed Relay state: %#v", loaded)
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

func TestValidateRuntimeEnvRejectsManagedBindings(t *testing.T) {
	for _, key := range []string{
		"WARREN_SESSION_ID",
		"WARREN_BIND_FILE",
		"WARREN_STATE_FILE",
		"WARREN_AGENT_KIND",
		"CODEX_SESSION_ID",
		"CODEX_THREAD_ID",
	} {
		if err := ValidateRuntimeEnv(map[string]string{key: "override"}); err == nil {
			t.Fatalf("ValidateRuntimeEnv accepted managed key %q", key)
		}
	}
}

func TestValidateRuntimeEnvRejectsInvalidNamesAndKeepsUnsetValues(t *testing.T) {
	for _, key := range []string{"", "1INVALID", "BAD-NAME", "HAS SPACE"} {
		if err := ValidateRuntimeEnv(map[string]string{key: "value"}); err == nil {
			t.Fatalf("ValidateRuntimeEnv accepted invalid key %q", key)
		}
	}
	if err := ValidateRuntimeEnv(map[string]string{"PAGER": ""}); err != nil {
		t.Fatalf("ValidateRuntimeEnv rejected an explicit unset: %v", err)
	}
	if err := ValidateRuntimeEnv(map[string]string{"VALUE": "bad\x00value"}); err == nil {
		t.Fatal("ValidateRuntimeEnv accepted a NUL-containing value")
	}
}

func TestLoadRejectsInvalidRuntimeEnvironment(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte(`{"runtimeEnv":{"WARREN_SESSION_ID":"foreign"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("Load accepted a managed runtime environment key")
	}
}
