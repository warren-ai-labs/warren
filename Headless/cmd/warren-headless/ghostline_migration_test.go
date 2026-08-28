package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
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
	record, err := createGhostlineMigration(state, "/tmp/source.sock", "/tmp/target.sock", "0.8.0", ghostlineV0ToV1Handoff)
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

func TestProbeLegacyGhostlineVersion(t *testing.T) {
	socketPath := filepath.Join(shortGhostlineTempDir(t), "legacy.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	done := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer connection.Close()
		var request struct {
			ID     int64  `json:"id"`
			Method string `json:"method"`
		}
		if err := json.NewDecoder(bufio.NewReader(connection)).Decode(&request); err != nil {
			done <- err
			return
		}
		if request.Method != "version" {
			done <- fmt.Errorf("legacy request method = %q, want version", request.Method)
			return
		}
		done <- json.NewEncoder(connection).Encode(struct {
			ID     int64 `json:"id"`
			Result struct {
				Version    string `json:"version"`
				TagVersion string `json:"tagVersion"`
			} `json:"result"`
		}{
			ID: request.ID,
			Result: struct {
				Version    string `json:"version"`
				TagVersion string `json:"tagVersion"`
			}{Version: "0.7.0", TagVersion: "v0.7.0"},
		})
	}()

	version, err := probeLegacyGhostlineVersion(context.Background(), socketPath)
	if err != nil {
		t.Fatalf("probe legacy version: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("serve legacy version: %v", err)
	}
	if version.ProtocolVersion != "0.7.0" || version.TagVersion != "v0.7.0" {
		t.Fatalf("legacy version = %#v", version)
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
	record, err := createGhostlineMigration(state, filepath.Join(directory, "ghostline-old.sock"), target, "0.8.0", ghostlineV0ToV1Handoff)
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

func shortGhostlineTempDir(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "wg-")
	if err != nil {
		t.Fatalf("create short temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}
