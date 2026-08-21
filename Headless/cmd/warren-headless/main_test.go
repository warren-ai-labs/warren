package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGhostlineAdoptionFatalOnlyBeforeCommit(t *testing.T) {
	adoptErr := errors.New("old server closed before retirement response")
	tests := []struct {
		name    string
		adopted int
		err     error
		fatal   bool
	}{
		{name: "pre-commit failure", adopted: 0, err: adoptErr, fatal: true},
		{name: "committed retirement failure", adopted: 1, err: adoptErr, fatal: false},
		{name: "successful empty adoption", adopted: 0, err: nil, fatal: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ghostlineAdoptionFatal(tt.adopted, tt.err); got != tt.fatal {
				t.Fatalf("ghostlineAdoptionFatal(%d, %v) = %t, want %t", tt.adopted, tt.err, got, tt.fatal)
			}
		})
	}
}

func TestLoadOrCreateTokenRepairsDeletedParentDirectory(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".warren", "token")

	first, err := loadOrCreateToken(path)
	if err != nil {
		t.Fatalf("create token: %v", err)
	}
	if first == "" {
		t.Fatal("created an empty token")
	}

	if err := os.RemoveAll(filepath.Dir(path)); err != nil {
		t.Fatalf("remove token directory: %v", err)
	}
	if err := ensureTokenFile(path, first); err != nil {
		t.Fatalf("repair token: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read repaired token: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != first {
		t.Fatalf("repaired token = %q, want %q", got, first)
	}
}

func TestEnsureTokenFileRestoresOwnedTokenAfterReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := writeTokenFile(path, "owned-token"); err != nil {
		t.Fatalf("write initial token: %v", err)
	}
	if err := os.WriteFile(path, []byte("other-token\n"), 0o600); err != nil {
		t.Fatalf("replace token: %v", err)
	}

	if err := ensureTokenFile(path, "owned-token"); err != nil {
		t.Fatalf("restore owned token: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read restored token: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != "owned-token" {
		t.Fatalf("restored token = %q, want owned-token", got)
	}
}

func TestReplaceWithSymlinkPointsStableAtTarget(t *testing.T) {
	dir := t.TempDir()
	stable := filepath.Join(dir, "ghostline.sock")
	target := filepath.Join(dir, "ghostline-1.sock")
	if err := os.WriteFile(stable, nil, 0o600); err != nil {
		t.Fatalf("create old socket path: %v", err)
	}
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatalf("create target path: %v", err)
	}
	if err := replaceWithSymlink(stable, target); err != nil {
		t.Fatalf("replaceWithSymlink: %v", err)
	}
	info, err := os.Lstat(stable)
	if err != nil {
		t.Fatalf("lstat stable: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("stable is not a symlink: %v", info.Mode())
	}
	resolved, err := filepath.EvalSymlinks(stable)
	if err != nil {
		t.Fatalf("eval symlink: %v", err)
	}
	targetResolved, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatalf("eval target: %v", err)
	}
	if resolved != targetResolved {
		t.Fatalf("stable resolves to %q, want %q", resolved, targetResolved)
	}
}

func TestValidateGhostlinePaths(t *testing.T) {
	dir := t.TempDir()
	defaults := struct {
		state  string
		output string
		socket string
	}{
		state: filepath.Join(dir, "state.json"), output: filepath.Join(dir, "output"), socket: filepath.Join(dir, "ghostline.sock"),
	}
	tests := []struct {
		name           string
		state, output  string
		socket         string
		socketExplicit bool
		wantErr        bool
	}{
		{name: "defaults", state: defaults.state, output: defaults.output, socket: defaults.socket},
		{name: "custom state requires socket", state: filepath.Join(dir, "probe", "state.json"), output: defaults.output, socket: defaults.socket, wantErr: true},
		{name: "custom output requires socket", state: defaults.state, output: filepath.Join(dir, "probe", "output"), socket: defaults.socket, wantErr: true},
		{name: "explicit default socket is rejected", state: filepath.Join(dir, "probe", "state.json"), output: defaults.output, socket: defaults.socket, socketExplicit: true, wantErr: true},
		{name: "empty socket is rejected", state: filepath.Join(dir, "probe", "state.json"), output: defaults.output, socket: "", socketExplicit: true, wantErr: true},
		{name: "dedicated socket allowed", state: filepath.Join(dir, "probe", "state.json"), output: filepath.Join(dir, "probe", "output"), socket: filepath.Join(dir, "probe", "ghostline.sock"), socketExplicit: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateGhostlinePaths(dir, tt.state, tt.output, tt.socket, tt.socketExplicit)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateGhostlinePaths() error = %v, wantErr %t", err, tt.wantErr)
			}
		})
	}
}

func TestBundledGnarPathOnlyAcceptsWarrenAppResource(t *testing.T) {
	root := t.TempDir()
	executable := filepath.Join(root, "Warren.app", "Contents", "MacOS", "warren-headless")
	resource := filepath.Join(root, "Warren.app", "Contents", "Resources", "gnar")
	if err := os.MkdirAll(filepath.Dir(executable), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(resource), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(resource, []byte("gnar"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := bundledGnarPathFor(executable); got != resource {
		t.Fatalf("bundled gnar path = %q, want %q", got, resource)
	}

	outside := filepath.Join(root, "build", "warren-headless")
	if err := os.MkdirAll(filepath.Dir(outside), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := bundledGnarPathFor(outside); got != "" {
		t.Fatalf("non-app executable selected bundled gnar %q", got)
	}
}
