package sshclient

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveHostReadsAliasAndUserOverride(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte(`
Host *
    User wildcard
    IdentityFile ~/.ssh/id_default
Host staging
    HostName 192.0.2.10
    User deploy
    Port 2201
    IdentityFile ~/.ssh/id_staging
    IdentitiesOnly yes
`), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("operator@staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.Host != "192.0.2.10" || host.User != "operator" || host.Port != 2201 || !host.IdentitiesOnly {
		t.Fatalf("unexpected host config: %+v", host)
	}
	if len(host.IdentityFile) != 2 || filepath.Base(host.IdentityFile[0]) != "id_default" || filepath.Base(host.IdentityFile[1]) != "id_staging" {
		t.Fatalf("unexpected identity files: %+v", host.IdentityFile)
	}
}

func TestReadSSHConfigIncludesFiles(t *testing.T) {
	directory := t.TempDir()
	includePath := filepath.Join(directory, "included")
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(includePath, []byte("Host included\n    HostName 198.51.100.4\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, []byte("Include included\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("included", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.Host != "198.51.100.4" {
		t.Fatalf("unexpected included host: %+v", host)
	}
}

func TestResolveHostAcceptsEqualsSyntax(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host=staging\n    HostName = 192.0.2.10\n    User=deploy\n    Port=2201\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.Host != "192.0.2.10" || host.User != "deploy" || host.Port != 2201 {
		t.Fatalf("unexpected equals-syntax host: %+v", host)
	}
}

func TestReadSSHConfigPreservesHostContextAroundInclude(t *testing.T) {
	directory := t.TempDir()
	includePath := filepath.Join(directory, "included")
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(includePath, []byte("Host other\n    HostName 198.51.100.5\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, []byte(`
Host staging
    User deploy
    Include included
    Port 2201
`), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.User != "deploy" || host.Port != 2201 {
		t.Fatalf("host context was lost around Include: %+v", host)
	}
}

func TestListHostsReportsUnsupportedProxyAndSkipsWildcards(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte(`
Host *
    User wildcard
Host staging production
    HostName 192.0.2.10
Host proxied
    ProxyJump bastion
`), 0o600); err != nil {
		t.Fatal(err)
	}
	entries, err := ListHosts(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 {
		t.Fatalf("entries = %#v, want three concrete aliases", entries)
	}
	if entries[0].Name != "staging" || entries[1].Name != "production" {
		t.Fatalf("unexpected aliases: %#v", entries)
	}
	if entries[0].Config.Host != "192.0.2.10" || entries[0].Config.User != "wildcard" {
		t.Fatalf("unexpected resolved staging host: %+v", entries[0].Config)
	}
	if entries[2].Name != "proxied" || entries[2].Error == "" {
		t.Fatalf("proxied host should carry an actionable error: %#v", entries[2])
	}
}

func TestListHostsIncludesBareAliases(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host bare\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	entries, err := ListHosts(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name != "bare" {
		t.Fatalf("entries = %#v, want the bare alias", entries)
	}
	if entries[0].Config.Host != "bare" || entries[0].Config.Port != 22 {
		t.Fatalf("unexpected bare alias config: %+v", entries[0].Config)
	}
}

func TestResolveHostReadsMultipleKnownHostsFiles(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte(`
Host staging
    UserKnownHostsFile ~/.ssh/known_hosts ~/.ssh/known_hosts2
`), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.KnownHostsFiles) != 2 {
		t.Fatalf("known hosts files = %#v, want two paths", host.KnownHostsFiles)
	}
	if host.KnownHosts != host.KnownHostsFiles[0] {
		t.Fatalf("legacy KnownHosts path = %q, want first path %q", host.KnownHosts, host.KnownHostsFiles[0])
	}
}

func TestResolveHostUsesOpenSSHDefaultIdentityFiles(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    HostName 192.0.2.10\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(host.IdentityFile) != 4 {
		t.Fatalf("default identities = %#v, want four OpenSSH defaults", host.IdentityFile)
	}
	if filepath.Base(host.IdentityFile[0]) != "id_ed25519" {
		t.Fatalf("default identities = %#v, expected ed25519 first", host.IdentityFile)
	}
}
