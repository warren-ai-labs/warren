package main

import (
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestCleanupStaleGhostlineArtifactsRemovesDeadFiles(t *testing.T) {
	directory := t.TempDir()
	socket := filepath.Join(directory, "ghostline-123.sock")
	for _, path := range []string{socket, socket + ".admin"} {
		if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
			t.Fatalf("write stale artifact %s: %v", path, err)
		}
	}
	if err := os.WriteFile(socket+".pid", []byte(strconv.Itoa(deadGhostlineTestPID(t))+"\n"), 0o600); err != nil {
		t.Fatalf("write stale pid: %v", err)
	}
	legacyPID := filepath.Join(directory, "ghostline.pid")
	if err := os.WriteFile(legacyPID, []byte("not-a-pid\n"), 0o600); err != nil {
		t.Fatalf("write legacy pid: %v", err)
	}

	removed, err := cleanupStaleGhostlineArtifacts(filepath.Join(directory, "ghostline.sock"))
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if removed != 4 {
		t.Fatalf("removed %d artifacts, want 4", removed)
	}
	for _, path := range []string{socket, socket + ".admin", socket + ".pid", legacyPID} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Fatalf("artifact %s still exists, err=%v", path, err)
		}
	}
}

func TestCleanupStaleGhostlineArtifactsPreservesLiveSocket(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "wg-")
	if err != nil {
		t.Fatalf("create short temp dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	socket := filepath.Join(directory, "g.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	pidPath := socket + ".pid"
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		t.Fatalf("write live pid: %v", err)
	}
	adminPath := socket + ".admin"
	if err := os.WriteFile(adminPath, []byte("live marker"), 0o600); err != nil {
		t.Fatalf("write admin marker: %v", err)
	}

	removed, err := cleanupStaleGhostlineArtifacts(filepath.Join(directory, "ghostline.sock"))
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if removed != 0 {
		t.Fatalf("removed %d artifacts from live server, want 0", removed)
	}
	for _, path := range []string{socket, pidPath, adminPath} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("live artifact %s missing: %v", path, err)
		}
	}
}

func TestCleanupStaleGhostlineArtifactsPreservesLivePID(t *testing.T) {
	directory := t.TempDir()
	socket := filepath.Join(directory, "ghostline-789.sock")
	for _, path := range []string{socket, socket + ".admin"} {
		if err := os.WriteFile(path, []byte("not listening yet"), 0o600); err != nil {
			t.Fatalf("write artifact %s: %v", path, err)
		}
	}
	if err := os.WriteFile(socket+".pid", []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		t.Fatalf("write live pid: %v", err)
	}

	removed, err := cleanupStaleGhostlineArtifacts(filepath.Join(directory, "ghostline.sock"))
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if removed != 0 {
		t.Fatalf("removed %d artifacts for live pid, want 0", removed)
	}
}

func deadGhostlineTestPID(t *testing.T) int {
	t.Helper()
	for pid := os.Getpid() + 1; pid < os.Getpid()+10000; pid++ {
		if !ghostlineProcessAlive(pid) {
			return pid
		}
	}
	t.Fatal("could not find a dead test pid")
	return 0
}
