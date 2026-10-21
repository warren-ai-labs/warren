package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func newTestGhostlineSupervisor(t *testing.T, directory string, state *store.Store) *ghostlineSupervisor {
	t.Helper()
	return newGhostlineSupervisor(ghostlineMigrationConfig{
		stableSocket: filepath.Join(directory, "ghostline.sock"),
		outputDir:    filepath.Join(directory, "output"),
		state:        state,
		logger:       slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
}

func writeTestPIDFile(t *testing.T, socket string, pid int) {
	t.Helper()
	if err := os.WriteFile(socket+".pid", []byte(strconv.Itoa(pid)+"\n"), 0o600); err != nil {
		t.Fatalf("write pid for %s: %v", socket, err)
	}
}

func TestGhostlineSupervisorRestartsDeadServer(t *testing.T) {
	directory := shortGhostlineTempDir(t)
	supervisor := newTestGhostlineSupervisor(t, directory, nil)
	stable := supervisor.config.stableSocket
	deadTarget := filepath.Join(directory, "ghostline-dead.sock")
	if err := os.Symlink(filepath.Base(deadTarget), stable); err != nil {
		t.Fatalf("create stable symlink: %v", err)
	}
	writeTestPIDFile(t, deadTarget, deadGhostlineTestPID(t))

	now := time.Unix(1_700_000_000, 0)
	supervisor.now = func() time.Time { return now }
	started := 0
	var startedTarget string
	var restarted *ghostline.Client
	supervisor.start = func(_ context.Context, target string) (*ghostline.Client, error) {
		started++
		startedTarget = target
		listener, err := net.Listen("unix", target)
		if err != nil {
			return nil, err
		}
		t.Cleanup(func() { _ = listener.Close() })
		writeTestPIDFile(t, target, os.Getpid())
		return ghostline.NewClient(target), nil
	}
	supervisor.onRestart = func(client *ghostline.Client) { restarted = client }

	supervisor.check(context.Background())
	if started != 0 {
		t.Fatalf("supervisor restarted before the grace window: %d", started)
	}
	now = now.Add(supervisor.grace + time.Second)
	supervisor.check(context.Background())
	if started != 1 {
		t.Fatalf("supervisor restarts = %d, want 1", started)
	}
	if restarted == nil {
		t.Fatal("supervisor did not publish the restarted client")
	}
	resolved, err := filepath.EvalSymlinks(stable)
	if err != nil {
		t.Fatalf("resolve restarted route: %v", err)
	}
	wantTarget, err := filepath.EvalSymlinks(startedTarget)
	if err != nil {
		t.Fatalf("resolve restarted target: %v", err)
	}
	if resolved != wantTarget {
		t.Fatalf("stable route = %s, want %s", resolved, wantTarget)
	}
	// A ready route is not restarted again.
	now = now.Add(supervisor.grace + time.Second)
	supervisor.check(context.Background())
	if started != 1 {
		t.Fatalf("supervisor restarted a healthy route: %d", started)
	}
}

func TestGhostlineSupervisorKeepsServerWithLivePID(t *testing.T) {
	directory := shortGhostlineTempDir(t)
	supervisor := newTestGhostlineSupervisor(t, directory, nil)
	stable := supervisor.config.stableSocket
	liveTarget := filepath.Join(directory, "ghostline-live.sock")
	if err := os.Symlink(filepath.Base(liveTarget), stable); err != nil {
		t.Fatalf("create stable symlink: %v", err)
	}
	writeTestPIDFile(t, liveTarget, os.Getpid())

	now := time.Unix(1_700_000_000, 0)
	supervisor.now = func() time.Time { return now }
	started := 0
	supervisor.start = func(_ context.Context, target string) (*ghostline.Client, error) {
		started++
		return ghostline.NewClient(target), nil
	}

	for attempt := 0; attempt < 5; attempt++ {
		now = now.Add(supervisor.grace + time.Second)
		supervisor.check(context.Background())
	}
	if started != 0 {
		t.Fatalf("supervisor started a second server while the pid was alive: %d", started)
	}
	link, err := os.Readlink(stable)
	if err != nil {
		t.Fatalf("read stable route: %v", err)
	}
	if link != filepath.Base(liveTarget) {
		t.Fatalf("supervisor replaced a live route: %s", link)
	}
}

func TestGhostlineSupervisorWaitsForVersionHandoff(t *testing.T) {
	directory := shortGhostlineTempDir(t)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatalf("open state: %v", err)
	}
	supervisor := newTestGhostlineSupervisor(t, directory, state)
	stable := supervisor.config.stableSocket
	deadTarget := filepath.Join(directory, "ghostline-dead.sock")
	if err := os.Symlink(filepath.Base(deadTarget), stable); err != nil {
		t.Fatalf("create stable symlink: %v", err)
	}
	writeTestPIDFile(t, deadTarget, deadGhostlineTestPID(t))

	record, err := createGhostlineMigration(state, "/tmp/source.sock", "/tmp/target.sock", "1.0.0", "warren-v1")
	if err != nil {
		t.Fatalf("create migration: %v", err)
	}
	if err := setGhostlineMigrationPhase(state, record.SessionID, api.GhostlineMigrationPrepared); err != nil {
		t.Fatalf("mark prepared: %v", err)
	}

	now := time.Now()
	supervisor.now = func() time.Time { return now }
	started := 0
	supervisor.start = func(_ context.Context, target string) (*ghostline.Client, error) {
		started++
		return ghostline.NewClient(target), nil
	}

	now = now.Add(supervisor.grace + time.Second)
	supervisor.check(context.Background())
	if started != 0 {
		t.Fatalf("supervisor restarted during a handoff: %d", started)
	}
	// Still inside the handoff timeout, even though the route is unreachable.
	now = now.Add(ghostlineMigrationTimeout / 2)
	supervisor.check(context.Background())
	if started != 0 {
		t.Fatalf("supervisor restarted inside the handoff timeout: %d", started)
	}

	if err := setGhostlineMigrationPhase(state, record.SessionID, api.GhostlineMigrationRetired); err != nil {
		t.Fatalf("mark retired: %v", err)
	}
	now = time.Now()
	supervisor.now = func() time.Time { return now }
	supervisor.check(context.Background())
	now = now.Add(supervisor.grace + time.Second)
	supervisor.check(context.Background())
	if started != 1 {
		t.Fatalf("supervisor did not restart after the handoff retired: %d", started)
	}
}

func TestGhostlineSupervisorIgnoresStaleHandoffJournal(t *testing.T) {
	directory := shortGhostlineTempDir(t)
	state, err := store.Open(filepath.Join(directory, "state.json"), "test-host")
	if err != nil {
		t.Fatalf("open state: %v", err)
	}
	supervisor := newTestGhostlineSupervisor(t, directory, state)
	stable := supervisor.config.stableSocket
	deadTarget := filepath.Join(directory, "ghostline-dead.sock")
	if err := os.Symlink(filepath.Base(deadTarget), stable); err != nil {
		t.Fatalf("create stable symlink: %v", err)
	}
	writeTestPIDFile(t, deadTarget, deadGhostlineTestPID(t))
	if err := state.Update(func(value *api.State) error {
		value.GhostlineMigration = &api.GhostlineMigration{
			SessionID: "stale",
			Phase:     api.GhostlineMigrationPrepared,
			UpdatedAt: time.Now().UTC().Add(-2 * ghostlineMigrationTimeout),
		}
		return nil
	}); err != nil {
		t.Fatalf("write stale journal: %v", err)
	}

	now := time.Now()
	supervisor.now = func() time.Time { return now }
	started := 0
	supervisor.start = func(_ context.Context, target string) (*ghostline.Client, error) {
		started++
		return ghostline.NewClient(target), nil
	}

	supervisor.check(context.Background())
	now = now.Add(supervisor.grace + time.Second)
	supervisor.check(context.Background())
	if started != 1 {
		t.Fatalf("stale handoff journal blocked supervision: %d", started)
	}
}
