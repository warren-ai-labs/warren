package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
