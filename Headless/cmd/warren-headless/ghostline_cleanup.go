package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/ghostline"
)

// Stale artifacts are unusual and the cleanup is deliberately low frequency;
// the daemon does not scan its Ghostline directory during startup.
const ghostlineArtifactCleanupInterval = 6 * time.Hour

// maintainGhostlineArtifactCleanup removes artifacts left by Ghostline
// servers that exited without running their deferred socket and pid cleanup.
// Live servers are identified by either a responsive socket or a live pid and
// are always left untouched.
func maintainGhostlineArtifactCleanup(ctx context.Context, socketPath string, logger *slog.Logger) {
	cleanup := func() {
		removed, err := cleanupStaleGhostlineArtifacts(socketPath)
		if err != nil {
			logger.Warn("unable to clean stale ghostline artifacts", "directory", filepath.Dir(socketPath), "error", err)
			return
		}
		if removed > 0 {
			logger.Info("cleaned stale ghostline artifacts", "count", removed, "directory", filepath.Dir(socketPath))
		}
	}

	ticker := time.NewTicker(ghostlineArtifactCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleanup()
		}
	}
}

// cleanupStaleGhostlineArtifacts removes only known Ghostline socket and pid
// artifacts whose public and admin sockets are unreachable and whose recorded
// owner is no longer alive. The stable socket may be a symlink; os.Remove
// removes only that link and never follows it.
func cleanupStaleGhostlineArtifacts(socketPath string) (int, error) {
	socketPath = filepath.Clean(socketPath)
	directory := filepath.Dir(socketPath)
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("read ghostline directory: %w", err)
	}

	legacyPIDPath := filepath.Join(directory, "ghostline.pid")
	legacyPIDValue, legacyPIDOK := readGhostlinePID(legacyPIDPath)
	legacyPIDAlive := legacyPIDOK && ghostlineProcessAlive(legacyPIDValue)
	candidates := map[string]struct{}{socketPath: {}}
	for _, entry := range entries {
		name := entry.Name()
		if name == "ghostline.sock" ||
			(strings.HasPrefix(name, "ghostline-") && strings.HasSuffix(name, ".sock")) {
			candidates[filepath.Join(directory, name)] = struct{}{}
			continue
		}
		for _, suffix := range []string{".sock.admin", ".sock.pid"} {
			if strings.HasPrefix(name, "ghostline-") && strings.HasSuffix(name, suffix) {
				artifact := filepath.Join(directory, strings.TrimSuffix(name, suffix))
				candidates[artifact] = struct{}{}
				break
			}
		}
	}

	removed := 0
	for candidate := range candidates {
		count, err := cleanupGhostlineCandidate(candidate, socketPath, legacyPIDAlive)
		if err != nil {
			return removed, err
		}
		removed += count
	}

	// Servers predating per-socket pid files used this shared marker. It is
	// independent of the stable socket candidate so a dead legacy marker can
	// be removed even while a newer stable server is serving requests.
	if count, err := cleanupGhostlineLegacyPID(legacyPIDPath); err != nil {
		return removed, err
	} else {
		removed += count
	}
	return removed, nil
}

func cleanupGhostlineCandidate(socketPath, stableSocketPath string, legacyPIDAlive bool) (int, error) {
	if ghostline.Ping(socketPath) || ghostline.Ping(socketPath+".admin") {
		return 0, nil
	}
	if socketPath == stableSocketPath && legacyPIDAlive {
		return 0, nil
	}
	if pid, ok := readGhostlinePID(socketPath + ".pid"); ok && ghostlineProcessAlive(pid) {
		return 0, nil
	}

	removed := 0
	for _, path := range []string{socketPath, socketPath + ".admin", socketPath + ".pid"} {
		count, err := removeGhostlineArtifact(path)
		if err != nil {
			return removed, err
		}
		removed += count
	}
	return removed, nil
}

func cleanupGhostlineLegacyPID(path string) (int, error) {
	if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
		return 0, nil
	} else if err != nil {
		return 0, fmt.Errorf("stat legacy ghostline pid %s: %w", path, err)
	}
	if pid, ok := readGhostlinePID(path); ok && ghostlineProcessAlive(pid) {
		return 0, nil
	}
	return removeGhostlineArtifact(path)
}

func removeGhostlineArtifact(path string) (int, error) {
	if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
		return 0, nil
	} else if err != nil {
		return 0, fmt.Errorf("stat ghostline artifact %s: %w", path, err)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return 0, fmt.Errorf("remove ghostline artifact %s: %w", path, err)
	}
	return 1, nil
}

func readGhostlinePID(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

func ghostlineProcessAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
