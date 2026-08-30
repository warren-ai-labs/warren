package sshclient

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func TestResolveHostUnbracketsIPv6Target(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host *\n    User deploy\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("deploy@[::1]", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.Host != "::1" || host.Port != 22 {
		t.Fatalf("IPv6 target = %+v, want unbracketed ::1:22", host)
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

func TestResolveHostDoesNotEchoProxyCommandCredentials(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    ProxyCommand sshpass -p super-secret nc %h %p\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := resolveHost("staging", configPath)
	if err == nil {
		t.Fatal("resolveHost unexpectedly accepted ProxyCommand")
	}
	if strings.Contains(err.Error(), "super-secret") {
		t.Fatalf("proxy credential leaked in error: %v", err)
	}
	if !strings.Contains(err.Error(), "ssh -L 8789:127.0.0.1:8789") {
		t.Fatalf("error lacks actionable external-forward fallback: %v", err)
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
	if len(host.KnownHostsFiles) < 2 {
		t.Fatalf("known hosts files = %#v, want the two configured user paths", host.KnownHostsFiles)
	}
	if host.KnownHostsFiles[0] != filepath.Join(userHomeDirectory(), ".ssh", "known_hosts") ||
		host.KnownHostsFiles[1] != filepath.Join(userHomeDirectory(), ".ssh", "known_hosts2") {
		t.Fatalf("configured known hosts paths were not retained: %#v", host.KnownHostsFiles)
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

func TestResolveHostRejectsKnownHostsNoneWithoutPanicking(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    UserKnownHostsFile none\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !host.KnownHostsDisabled || len(host.KnownHostsFiles) != 2 || host.KnownHosts != host.KnownHostsFiles[0] {
		t.Fatalf("UserKnownHostsFile none was not preserved while retaining system defaults: %+v", host)
	}

	allDisabledPath := filepath.Join(directory, "all-disabled")
	if err := os.WriteFile(allDisabledPath, []byte("Host staging\n    UserKnownHostsFile none\n    GlobalKnownHostsFile none\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	allDisabled, err := resolveHost("staging", allDisabledPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(allDisabled.KnownHostsFiles) != 0 {
		t.Fatalf("all known_hosts sources were not disabled: %+v", allDisabled)
	}
	if _, _, err := clientConfig(allDisabled, time.Second); err == nil || !strings.Contains(err.Error(), "strict host-key verification") {
		t.Fatalf("clientConfig error = %v, want strict verification error", err)
	}
}

func TestResolveHostExpandsIdentityAgentEnvironmentReference(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    IdentityAgent SSH_AUTH_SOCK\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	previous := os.Getenv("SSH_AUTH_SOCK")
	t.Cleanup(func() { _ = os.Setenv("SSH_AUTH_SOCK", previous) })
	if err := os.Setenv("SSH_AUTH_SOCK", filepath.Join(directory, "agent.sock")); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.IdentityAgent != filepath.Join(directory, "agent.sock") {
		t.Fatalf("identity agent = %q, want environment socket", host.IdentityAgent)
	}
}

func TestResolveHostExpandsHostNameAndIdentityAgentTokensAfterDefaults(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    User deploy\n    Port 2201\n    HostName %h.internal\n    IdentityAgent "+filepath.Join(directory, "%r-%p.sock")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.Host != "staging.internal" {
		t.Fatalf("hostname = %q, want staging.internal", host.Host)
	}
	if host.IdentityAgent != filepath.Join(directory, "deploy-2201.sock") {
		t.Fatalf("identity agent = %q, want expanded user/port path", host.IdentityAgent)
	}
}

func TestResolveHostPreservesHostKeyAliasAndGlobalKnownHosts(t *testing.T) {
	directory := t.TempDir()
	knownHosts := filepath.Join(directory, "global-known-hosts")
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    HostKeyAlias bastion-key\n    GlobalKnownHostsFile "+knownHosts+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if host.HostKeyAlias != "bastion-key" {
		t.Fatalf("host key alias = %q, want bastion-key", host.HostKeyAlias)
	}
	if len(host.KnownHostsFiles) != 3 || host.KnownHostsFiles[2] != knownHosts {
		t.Fatalf("known hosts files = %#v, want user defaults plus %q", host.KnownHostsFiles, knownHosts)
	}
}

func TestResolveHostHonorsGlobalKnownHostsNoneWithoutDisablingUserDefaults(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    GlobalKnownHostsFile none\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !host.GlobalKnownHostsDisabled {
		t.Fatalf("GlobalKnownHostsFile none was not preserved: %+v", host)
	}
	if len(host.KnownHostsFiles) != 2 {
		t.Fatalf("known hosts files = %#v, want only user defaults", host.KnownHostsFiles)
	}
	for _, path := range host.KnownHostsFiles {
		if strings.HasPrefix(path, "/etc/ssh/") {
			t.Fatalf("system known_hosts was reintroduced after GlobalKnownHostsFile none: %#v", host.KnownHostsFiles)
		}
	}
}

func TestResolveHostDisablesConfiguredIdentityAgent(t *testing.T) {
	directory := t.TempDir()
	configPath := filepath.Join(directory, "config")
	if err := os.WriteFile(configPath, []byte("Host staging\n    IdentityAgent none\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	host, err := resolveHost("staging", configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !host.AgentDisabled || host.IdentityAgent != "" {
		t.Fatalf("identity agent none was not preserved: %+v", host)
	}
}
