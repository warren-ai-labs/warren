package main

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// ghostlineSupervisorInterval bounds how stale the daemon's view of the
	// Ghostline server process can get.
	ghostlineSupervisorInterval = time.Second
	// A route must stay unreachable this long before the supervisor replaces
	// it. A starting server and an in-flight handoff are allowed to be briefly
	// unreachable without being treated as dead.
	ghostlineSupervisorGrace = 5 * time.Second
)

// ghostlineSupervisor owns the supervision half of the Ghostline child
// lifecycle. The daemon spawns the server once at startup, then the detached
// process has no parent waiting for it. This loop notices that the recorded pid
// is gone, or that the route stayed unreachable, and starts a fresh target on a
// new socket path before atomically swapping the stable symlink. It never
// rebinds the stale path and never starts a second server while the recorded
// pid answers.
type ghostlineSupervisor struct {
	config    ghostlineMigrationConfig
	logger    *slog.Logger
	interval  time.Duration
	grace     time.Duration
	now       func() time.Time
	start     func(context.Context, string) (*ghostline.Client, error)
	onRestart func(*ghostline.Client)

	unreachableSince time.Time
}

func newGhostlineSupervisor(config ghostlineMigrationConfig) *ghostlineSupervisor {
	if config.logger == nil {
		config.logger = slog.Default()
	}
	supervisor := &ghostlineSupervisor{
		config:   config,
		logger:   config.logger,
		interval: ghostlineSupervisorInterval,
		grace:    ghostlineSupervisorGrace,
		now:      time.Now,
	}
	supervisor.start = func(ctx context.Context, target string) (*ghostline.Client, error) {
		return startGhostline(config, target, v1GhostlineSpawn(config))
	}
	return supervisor
}

// maintainGhostlineServer runs the supervisor until the daemon stops. The
// first check happens on the first tick because startup already ensured one
// server.
func maintainGhostlineServer(ctx context.Context, supervisor *ghostlineSupervisor) {
	ticker := time.NewTicker(supervisor.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			supervisor.check(ctx)
		}
	}
}

func (s *ghostlineSupervisor) check(ctx context.Context) {
	if s.handoffInProgress(s.now()) {
		// A handoff owns both the child and the route until it commits or
		// fails. Starting another server meanwhile would split PTY ownership.
		s.unreachableSince = time.Time{}
		return
	}
	stable := s.config.stableSocket
	route := ghostlineResolvedRoute(stable)
	if ghostlineSocketReady(stable) ||
		ghostlineSocketReady(route) ||
		ghostlineSocketReady(route+".admin") {
		s.unreachableSince = time.Time{}
		return
	}
	if pid, ok := ghostlineRecordedPID(stable); ok && ghostlineProcessAlive(pid) {
		// The recorded owner is still running. Never start a second server
		// against the same sessions, even while it is not accepting yet.
		s.unreachableSince = time.Time{}
		return
	}
	now := s.now()
	if s.unreachableSince.IsZero() {
		s.unreachableSince = now
		return
	}
	if now.Sub(s.unreachableSince) < s.grace {
		return
	}
	s.restart(ctx)
}

func (s *ghostlineSupervisor) restart(ctx context.Context) {
	target := nextGhostlineSocket(s.config.stableSocket)
	restartContext, cancel := context.WithTimeout(ctx, ghostlineMigrationTimeout)
	defer cancel()
	client, err := s.start(restartContext, target)
	if err != nil {
		// A failed spawn is retried after another grace window instead of on
		// every tick, so a broken executable does not log or fork per second.
		s.unreachableSince = s.now()
		s.logger.Warn("unable to restart ghostline server", "target", target, "error", err)
		return
	}
	if err := replaceWithSymlink(s.config.stableSocket, target); err != nil {
		_ = stopGhostlineServer(target)
		s.unreachableSince = s.now()
		s.logger.Warn("unable to route restarted ghostline server", "target", target, "error", err)
		return
	}
	if s.onRestart != nil {
		s.onRestart(client)
	}
	s.unreachableSince = time.Time{}
	s.logger.Info("ghostline server restarted after exit", "target", target, "pid", client.PID())
}

// handoffInProgress reports whether a rolling version handoff is still inside
// its own timeout window. An older journal record is a stale diagnostic from a
// failed start, not active work, and must not block supervision forever.
func (s *ghostlineSupervisor) handoffInProgress(now time.Time) bool {
	if s.config.state == nil {
		return false
	}
	migration := s.config.state.Snapshot().GhostlineMigration
	if migration == nil || migration.Phase == api.GhostlineMigrationRetired {
		return false
	}
	return now.Sub(migration.UpdatedAt) < ghostlineMigrationTimeout
}

// ghostlineResolvedRoute follows the stable socket to the per-migration target.
// A dangling link still names the target that used to serve it, which is where
// the pid file lives after an unclean exit.
func ghostlineResolvedRoute(socket string) string {
	if resolved, err := filepath.EvalSymlinks(socket); err == nil {
		return resolved
	}
	if link, err := os.Readlink(socket); err == nil {
		if !filepath.IsAbs(link) {
			link = filepath.Join(filepath.Dir(socket), link)
		}
		return link
	}
	return socket
}

// ghostlineRecordedPID reads the pid written by the detached serve process for
// the current route. Servers predating per-socket pid files used one shared
// marker, and the stable path may itself be the bound socket.
func ghostlineRecordedPID(socket string) (int, bool) {
	route := ghostlineResolvedRoute(socket)
	candidates := []string{
		route + ".pid",
		socket + ".pid",
		filepath.Join(filepath.Dir(socket), "ghostline.pid"),
	}
	for _, candidate := range candidates {
		if pid, ok := readGhostlinePID(candidate); ok {
			return pid, true
		}
	}
	return 0, false
}
