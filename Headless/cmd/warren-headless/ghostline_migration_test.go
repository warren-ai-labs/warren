package main

import (
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func TestGhostlineMigrationJournalPersistsPhases(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "state.json")
	state, err := store.Open(statePath, "test-host")
	if err != nil {
		t.Fatalf("open state: %v", err)
	}
	record, err := createGhostlineMigration(state, "/tmp/source.sock", "/tmp/target.sock", "1.0.0", "warren-v1")
	if err != nil {
		t.Fatalf("create migration: %v", err)
	}
	if err := setGhostlineMigrationPhase(state, record.SessionID, api.GhostlineMigrationCommitted); err != nil {
		t.Fatalf("mark committed: %v", err)
	}

	reopened, err := store.Open(statePath, "test-host")
	if err != nil {
		t.Fatalf("reopen state: %v", err)
	}
	got, ok := pendingGhostlineMigration(reopened.Snapshot())
	if !ok {
		t.Fatal("missing migration journal record")
	}
	if got.SessionID != record.SessionID || got.Phase != api.GhostlineMigrationCommitted {
		t.Fatalf("journal record = %#v, want committed record %q", got, record.SessionID)
	}
	if !ghostlinePhaseAtLeast(got.Phase, api.GhostlineMigrationCommitted) {
		t.Fatal("committed phase did not compare as committed")
	}
	if ghostlinePhaseAtLeast("unknown", api.GhostlineMigrationPreparing) {
		t.Fatal("unknown phase must not compare as valid")
	}
}

func TestResumeCommittedMigrationRoutesTargetBeforeFreshStart(t *testing.T) {
	directory := shortGhostlineTempDir(t)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatalf("open state: %v", err)
	}
	stable := filepath.Join(directory, "ghostline.sock")
	target := filepath.Join(directory, "ghostline-next.sock")
	listener, err := net.Listen("unix", target)
	if err != nil {
		t.Fatalf("listen on target: %v", err)
	}
	defer listener.Close()
	record, err := createGhostlineMigration(state, filepath.Join(directory, "ghostline-old.sock"), target, "1.0.0", "warren-v1")
	if err != nil {
		t.Fatalf("create migration: %v", err)
	}
	if err := setGhostlineMigrationPhase(state, record.SessionID, api.GhostlineMigrationCommitted); err != nil {
		t.Fatalf("mark committed: %v", err)
	}

	config := ghostlineMigrationConfig{
		stableSocket: stable,
		state:        state,
		logger:       slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	if err := resumeGhostlineMigration(config); err != nil {
		t.Fatalf("resume committed migration: %v", err)
	}
	if got := currentGhostlineRoute(stable); got != currentGhostlineRoute(target) {
		t.Fatalf("stable route = %q, want target %q", got, currentGhostlineRoute(target))
	}
	if got, ok := pendingGhostlineMigration(state.Snapshot()); ok {
		t.Fatalf("migration remained pending after resume: %#v", got)
	}
}

func TestReplaceWithSymlinkReplacesUnixSocket(t *testing.T) {
	directory := shortGhostlineTempDir(t)
	stable := filepath.Join(directory, "ghostline.sock")
	target := filepath.Join(directory, "ghostline-next.sock")
	listener, err := net.Listen("unix", stable)
	if err != nil {
		t.Fatalf("listen on stable socket: %v", err)
	}
	defer listener.Close()
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatalf("create target: %v", err)
	}

	if err := replaceWithSymlink(stable, target); err != nil {
		t.Fatalf("replace stable socket: %v", err)
	}
	info, err := os.Lstat(stable)
	if err != nil {
		t.Fatalf("stat stable route: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("stable route mode = %v, want symlink", info.Mode())
	}
	targetRoute, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatalf("resolve target: %v", err)
	}
	if got := currentGhostlineRoute(stable); got != targetRoute {
		t.Fatalf("stable route = %q, want %q", got, targetRoute)
	}
}

func TestConsumeForceGhostlineHandoffIsOneShot(t *testing.T) {
	directory := shortGhostlineTempDir(t)
	config := ghostlineMigrationConfig{
		stableSocket: filepath.Join(directory, "ghostline.sock"),
	}
	marker := filepath.Join(directory, "force-ghostline-handoff")
	if err := os.WriteFile(marker, nil, 0o600); err != nil {
		t.Fatalf("write force marker: %v", err)
	}
	if !consumeForceGhostlineHandoff(config) {
		t.Fatal("first force marker read was not consumed")
	}
	if consumeForceGhostlineHandoff(config) {
		t.Fatal("force marker was consumed more than once")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("force marker still exists, stat error = %v", err)
	}
}

func TestConsumeForceGhostlineHandoffClearsEnvironment(t *testing.T) {
	config := ghostlineMigrationConfig{stableSocket: filepath.Join(t.TempDir(), "ghostline.sock")}
	t.Setenv("WARREN_GHOSTLINE_FORCE_HANDOFF", "1")
	if !consumeForceGhostlineHandoff(config) {
		t.Fatal("environment force signal was not consumed")
	}
	if forceGhostlineHandoffRequestedFor(config) {
		t.Fatal("environment force signal leaked after consumption")
	}
}

func TestGhostlineMigrationSkippedReportsUnrecoveredSessions(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test-host")
	if err != nil {
		t.Fatalf("open state: %v", err)
	}
	if err := state.Update(func(value *api.State) error {
		value.GhostlineMigration = &api.GhostlineMigration{
			Phase:           api.GhostlineMigrationRetired,
			SkippedSessions: []string{"session-1"},
		}
		return nil
	}); err != nil {
		t.Fatalf("seed migration: %v", err)
	}
	if !ghostlineMigrationSkipped(state) {
		t.Fatal("skipped migration was not detected")
	}
	if err := state.Update(func(value *api.State) error {
		value.GhostlineMigration.SkippedSessions = nil
		return nil
	}); err != nil {
		t.Fatalf("clear migration skips: %v", err)
	}
	if ghostlineMigrationSkipped(state) {
		t.Fatal("cleared migration still reports skipped sessions")
	}
}

func shortGhostlineTempDir(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "wg-")
	if err != nil {
		t.Fatalf("create short temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}

func TestResolveGhostlineExecutableCreatesSymlink(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "warren-headless")
	if err := os.WriteFile(original, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("create original executable: %v", err)
	}

	got := resolveGhostlineExecutable(original, nil)
	want := filepath.Join(tempDir, ghostlineExecutableAlias)
	if got != want {
		t.Fatalf("resolveGhostlineExecutable = %q, want %q", got, want)
	}

	info, err := os.Lstat(got)
	if err != nil {
		t.Fatalf("stat resolved alias: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("resolved alias is not a symlink: %v", info.Mode())
	}
	target, err := os.Readlink(got)
	if err != nil {
		t.Fatalf("readlink alias: %v", err)
	}
	if target != "warren-headless" {
		t.Fatalf("symlink target = %q, want %q", target, "warren-headless")
	}

	// Reusing existing alias
	reused := resolveGhostlineExecutable(original, nil)
	if reused != want {
		t.Fatalf("reused resolveGhostlineExecutable = %q, want %q", reused, want)
	}
}

func TestResolveGhostlineExecutableRepairsBrokenSymlink(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "warren-headless")
	if err := os.WriteFile(original, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("create original executable: %v", err)
	}

	alias := filepath.Join(tempDir, ghostlineExecutableAlias)
	if err := os.Symlink("non-existent-target", alias); err != nil {
		t.Fatalf("create broken symlink: %v", err)
	}

	got := resolveGhostlineExecutable(original, nil)
	if got != alias {
		t.Fatalf("resolveGhostlineExecutable = %q, want %q", got, alias)
	}
	target, err := os.Readlink(alias)
	if err != nil {
		t.Fatalf("readlink repaired alias: %v", err)
	}
	if target != "warren-headless" {
		t.Fatalf("repaired target = %q, want %q", target, "warren-headless")
	}
}

func TestResolveGhostlineExecutableAlreadyAlias(t *testing.T) {
	alias := filepath.Join(t.TempDir(), ghostlineExecutableAlias)
	if got := resolveGhostlineExecutable(alias, nil); got != alias {
		t.Fatalf("resolveGhostlineExecutable on alias = %q, want %q", got, alias)
	}
}

func TestResolveGhostlineExecutableEmpty(t *testing.T) {
	if got := resolveGhostlineExecutable("", nil); got != "" {
		t.Fatalf("resolveGhostlineExecutable(\"\") = %q, want empty", got)
	}
}

func TestResolveGhostlineExecutableReadOnlyFallback(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "warren-headless")
	if err := os.WriteFile(original, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("create original executable: %v", err)
	}
	if err := os.Chmod(tempDir, 0o555); err != nil {
		t.Fatalf("chmod read-only: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(tempDir, 0o755) })

	got := resolveGhostlineExecutable(original, nil)
	if got != original {
		t.Fatalf("resolveGhostlineExecutable in read-only dir = %q, want fallback %q", got, original)
	}
}

func TestV1GhostlineSpawnUsesAlias(t *testing.T) {
	config := ghostlineMigrationConfig{
		stableSocket:    "/tmp/ghostline.sock",
		outputDir:       "/tmp/output",
		probeForeground: true,
	}
	spawn := v1GhostlineSpawn(config)
	if len(spawn) == 0 {
		t.Fatal("v1GhostlineSpawn returned empty slice")
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	expectedBase := ghostlineExecutableAlias
	// If the current executable's directory is writable, spawn[0] will be warren-ghostline.
	// Otherwise it falls back to filepath.Base(executable).
	if filepath.Base(spawn[0]) != expectedBase && filepath.Base(spawn[0]) != filepath.Base(executable) {
		t.Fatalf("spawn executable base = %q, want %q or %q", filepath.Base(spawn[0]), expectedBase, filepath.Base(executable))
	}
	joined := strings.Join(spawn, " ")
	for _, expectedArg := range []string{"--ghostline-serve", "--ghostline-socket", "{socket}", "--output-dir /tmp/output", "--ghostline-probe-foreground=true"} {
		if !strings.Contains(joined, expectedArg) {
			t.Fatalf("spawn command %q missing %q", joined, expectedArg)
		}
	}
}
