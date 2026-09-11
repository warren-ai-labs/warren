package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestDisplayConfigRoundTripsAndComputesEffectiveSet(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	value := Config{
		Current: "dev",
		Endpoints: map[string]Endpoint{
			"dev":  {Name: "dev", URL: "https://dev.example", Token: "dev-token"},
			"prod": {Name: "prod", URL: "https://prod.example", Token: "prod-token"},
		},
		Display: &DisplayConfig{
			Version:   DisplayConfigVersion,
			Endpoints: []string{"local", "dev", "prod"},
			Names:     map[string]string{"local": "Office Mac", "prod": "Production"},
		},
	}
	if err := Save(path, value); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	aliases, err := loaded.EffectiveDisplay()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := aliases, []string{"local", "dev", "prod"}; !equalStrings(got, want) {
		t.Fatalf("effective display = %v, want %v", got, want)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["display"]; !ok {
		t.Fatalf("display section missing from config: %s", data)
	}
	if got := loaded.Display.Names["local"]; got != "Office Mac" {
		t.Fatalf("local display name = %q, want Office Mac", got)
	}
}

func TestLoadMigratesLegacySidebarToDisplay(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	legacy := []byte(`{
  "current": "dev",
  "endpoints": {
    "dev": {"name": "dev", "url": "https://dev.example", "token": "dev-token"}
  },
  "sidebar": {"version": 1, "endpoints": ["local", "dev"]}
}`)
	if err := os.WriteFile(path, legacy, 0o600); err != nil {
		t.Fatal(err)
	}

	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	want := &DisplayConfig{
		Version:   DisplayConfigVersion,
		Endpoints: []string{"local", "dev"},
	}
	if got := loaded.Display; !reflect.DeepEqual(got, want) {
		t.Fatalf("display = %#v, want %#v", got, want)
	}
	if err := Save(path, loaded); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["display"]; !ok {
		t.Fatalf("display section missing from migrated config: %s", data)
	}
	if _, ok := raw["sidebar"]; ok {
		t.Fatalf("legacy sidebar section persisted after migration: %s", data)
	}
}

func TestDisplayUpdatePreservesEndpointRouteMetadata(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	value := Config{
		Current: "prod",
		Endpoints: map[string]Endpoint{
			"prod": {
				Name:            "prod",
				URL:             "https://relay.example",
				Token:           "access-token",
				Type:            "relay",
				HostID:          "host-1",
				RouteID:         "route-1",
				ClientID:        "client-1",
				RefreshToken:    "refresh-token",
				DirectURL:       "https://prod.example",
				RelayURL:        "https://relay.example",
				RoutePreference: "auto",
			},
		},
		Display: &DisplayConfig{
			Version:   DisplayConfigVersion,
			Endpoints: []string{"local", "prod"},
			Names:     map[string]string{"prod": "Production"},
		},
	}
	if err := Save(path, value); err != nil {
		t.Fatal(err)
	}
	if err := Update(path, func(settings *Config) error {
		settings.Display.Endpoints = []string{"prod", "local"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	endpoint := loaded.Endpoints["prod"]
	if endpoint.ClientID != "client-1" || endpoint.RefreshToken != "refresh-token" ||
		endpoint.DirectURL != "https://prod.example" || endpoint.RelayURL != "https://relay.example" ||
		endpoint.RoutePreference != "auto" {
		t.Fatalf("display update dropped endpoint metadata: %+v", endpoint)
	}
	if got := loaded.Display.Names["prod"]; got != "Production" {
		t.Fatalf("display update dropped custom name: %q", got)
	}
}

func TestNormalizeDisplayDeduplicatesAndKeepsCurrentIndependent(t *testing.T) {
	value := Config{
		Current: "prod",
		Endpoints: map[string]Endpoint{
			"dev":  {Name: "dev"},
			"prod": {Name: "prod"},
		},
		Display: &DisplayConfig{Endpoints: []string{"dev", "dev", "local"}},
	}
	if err := value.NormalizeDisplay(); err != nil {
		t.Fatal(err)
	}
	if value.Display.Version != DisplayConfigVersion {
		t.Fatalf("version = %d, want %d", value.Display.Version, DisplayConfigVersion)
	}
	if got, want := value.Display.Endpoints, []string{"dev", "local"}; !equalStrings(got, want) {
		t.Fatalf("normalized aliases = %v, want %v", got, want)
	}
	if value.Current != "prod" {
		t.Fatalf("current = %q, want independent prod endpoint", value.Current)
	}
}

func TestNormalizeDisplayRejectsUnknownCurrentEndpoint(t *testing.T) {
	value := Config{
		Current: "missing",
		Endpoints: map[string]Endpoint{
			"dev": {Name: "dev"},
		},
		Display: &DisplayConfig{Endpoints: []string{"dev"}},
	}
	if err := value.NormalizeDisplay(); err == nil || !strings.Contains(err.Error(), "endpoint not found") {
		t.Fatalf("NormalizeDisplay error = %v, want unknown current endpoint", err)
	}
}

func TestNormalizeDisplayTrimsCurrentMarker(t *testing.T) {
	value := Config{
		Current: "  dev  ",
		Endpoints: map[string]Endpoint{
			"dev": {Name: "dev"},
		},
		Display: &DisplayConfig{Endpoints: []string{"dev"}},
	}
	if err := value.NormalizeDisplay(); err != nil {
		t.Fatal(err)
	}
	if value.Current != "dev" {
		t.Fatalf("current = %q, want canonical alias dev", value.Current)
	}
}

func TestEffectiveDisplayRejectsUnknownAndEmptyAliases(t *testing.T) {
	for name, display := range map[string]*DisplayConfig{
		"unknown": {Version: DisplayConfigVersion, Endpoints: []string{"remote"}},
		"empty":   {Version: DisplayConfigVersion, Endpoints: []string{}},
	} {
		t.Run(name, func(t *testing.T) {
			value := Config{Endpoints: map[string]Endpoint{}, Display: display}
			if _, err := value.EffectiveDisplay(); err == nil {
				t.Fatal("EffectiveDisplay unexpectedly accepted malformed aliases")
			}
		})
	}
}

func TestSaveRejectsUnknownAndEmptyDisplay(t *testing.T) {
	for name, display := range map[string]*DisplayConfig{
		"unknown": {Version: DisplayConfigVersion, Endpoints: []string{"missing"}},
		"empty":   {Version: DisplayConfigVersion, Endpoints: []string{}},
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			value := Config{
				Current:   "local",
				Endpoints: map[string]Endpoint{},
				Display:   display,
			}
			if err := Save(path, value); err == nil {
				t.Fatal("Save unexpectedly accepted malformed display")
			}
		})
	}
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func TestUpdateCreatesAndPreservesEndpointCatalog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := Update(path, func(value *Config) error {
		value.Current = "ssh-vps"
		value.Endpoints["ssh-vps"] = Endpoint{
			Name:      "ssh-vps",
			SSH:       "vps",
			SSHRemote: "127.0.0.1:9000",
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	value, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if value.Current != "ssh-vps" || value.Endpoints["ssh-vps"].SSHRemote != "127.0.0.1:9000" {
		t.Fatalf("unexpected catalog: %+v", value)
	}
	if mode := fileMode(t, path); mode != 0o600 {
		t.Fatalf("config mode = %#o, want 0600", mode)
	}
}

func TestLoadRejectsRemovedSSHRuntimeCredentials(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	data := []byte(`{"current":"vps","endpoints":{"vps":{"name":"vps","url":"http://127.0.0.1:12345","token":"secret","ssh":"vps"}}}`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil || !strings.Contains(err.Error(), "state_reset_required") {
		t.Fatalf("Load error = %v, want state_reset_required", err)
	}
}

func TestSaveNeverWritesRuntimeCredentialsForSSHEndpoints(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	value := Config{
		Current: "vps",
		Endpoints: map[string]Endpoint{
			"vps": {
				Name:  "vps",
				URL:   "http://127.0.0.1:12345",
				Token: "secret",
				SSH:   "vps",
			},
		},
	}
	if err := Save(path, value); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "12345") || strings.Contains(string(data), "secret") {
		t.Fatalf("unexpected legacy SSH credentials in config: %s", data)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Endpoints["vps"].URL != "" || loaded.Endpoints["vps"].Token != "" {
		t.Fatalf("saved SSH runtime values were not scrubbed: %+v", loaded.Endpoints["vps"])
	}
}

func TestSaveNormalizesNilEndpointMap(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := Save(path, Config{}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), `"endpoints": null`) {
		t.Fatalf("nil endpoint map was serialized as null: %s", data)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Endpoints == nil {
		t.Fatal("loaded endpoint map is nil")
	}
}

func fileMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode().Perm()
}
