package server

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	warrenruntime "github.com/abcdlsj/warren/Headless/internal/runtime"
)

func startGhostlineRuntime(t *testing.T) (*GhostlineRuntime, *ghostline.Client) {
	return startGhostlineRuntimeWithOptions(t, ghostline.Options{OutputDir: t.TempDir()})
}

func startGhostlineRuntimeWithOptions(t *testing.T, options ghostline.Options) (*GhostlineRuntime, *ghostline.Client) {
	t.Helper()
	socketDir, err := os.MkdirTemp("", "ghostline-")
	if err != nil {
		t.Fatalf("socket dir: %v", err)
	}
	socket := filepath.Join(socketDir, "ghostline.sock")
	server, err := ghostline.NewServer(options)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = server.Serve(context.Background(), socket)
	}()
	client := ghostline.NewClient(socket)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if client.Check(context.Background()) == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := client.Check(context.Background()); err != nil {
		t.Fatalf("server not ready: %v", err)
	}
	t.Cleanup(func() {
		_ = server.Shutdown(context.Background())
		<-done
		_ = os.RemoveAll(socketDir)
	})
	return NewGhostlineRuntime(client), client
}

func waitGhostlineOutput(t *testing.T, runtime *GhostlineRuntime, name, needle string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		snapshot, err := runtime.Capture(context.Background(), name)
		if err == nil && bytes.Contains(snapshot, []byte(needle)) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("ghostline output missing %q", needle)
}

func TestGhostlineRuntimeLifecycle(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	ctx := context.Background()
	if err := runtime.Create(ctx, "warren_ghost_test", t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if !runtime.Exists(ctx, "warren_ghost_test") {
		t.Fatal("session should exist after Create")
	}
	if err := runtime.Input(ctx, "warren_ghost_test", []byte("echo adapter-ok\r")); err != nil {
		t.Fatalf("Input: %v", err)
	}
	waitGhostlineOutput(t, runtime, "warren_ghost_test", "adapter-ok")
	if err := runtime.Resize(ctx, "warren_ghost_test", 100, 30); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	sessions, err := runtime.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if !sessions["warren_ghost_test"] {
		t.Fatalf("List missing session: %v", sessions)
	}
	if size, err := runtime.SpoolSize(ctx, "warren_ghost_test"); err != nil || size <= 0 {
		t.Fatalf("SpoolSize = %d, %v", size, err)
	}
	if path := runtime.SpoolPath("warren_ghost_test"); path == "" {
		t.Fatal("SpoolPath returned empty")
	}
	if err := runtime.Kill(ctx, "warren_ghost_test"); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	if runtime.Exists(ctx, "warren_ghost_test") {
		t.Fatal("session should not exist after Kill")
	}
}

func TestGhostlineRuntimeUsesSanitizedEnvironment(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	warrenruntime.SanitizeEnvironment()
	runtime, _ := startGhostlineRuntime(t)
	ctx := context.Background()
	if err := runtime.Create(ctx, "warren_ghost_color", t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := runtime.Input(ctx, "warren_ghost_color", []byte("echo NO_COLOR=[$NO_COLOR]\r")); err != nil {
		t.Fatalf("Input: %v", err)
	}
	waitGhostlineOutput(t, runtime, "warren_ghost_color", "NO_COLOR=[]")
}

func TestGhostlineRuntimeMetadataDisabledByDefault(t *testing.T) {
	runtime, _ := startGhostlineRuntime(t)
	ctx := context.Background()
	if err := runtime.Create(ctx, "warren_ghost_meta", t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("Create: %v", err)
	}
	metadata, err := runtime.Metadata(ctx, "warren_ghost_meta")
	if err != nil {
		t.Fatalf("Metadata: %v", err)
	}
	if metadata.Process != "" || metadata.Directory != "" {
		t.Fatalf("Metadata = %+v, want empty when probing is disabled", metadata)
	}
}

func TestGhostlineRuntimeMetadataProbesForeground(t *testing.T) {
	runtime, _ := startGhostlineRuntimeWithOptions(t, ghostline.Options{
		OutputDir:       t.TempDir(),
		ProbeForeground: true,
	})
	ctx := context.Background()
	directory := t.TempDir()
	if err := runtime.Create(ctx, "warren_ghost_meta_on", directory, "sh", nil); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := runtime.Input(ctx, "warren_ghost_meta_on", []byte("cd "+directory+" && exec sleep 30\r")); err != nil {
		t.Fatalf("Input: %v", err)
	}
	wantDirectory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		metadata, err := runtime.Metadata(ctx, "warren_ghost_meta_on")
		if err == nil && strings.Contains(metadata.Process, "sleep") {
			if gotDirectory, resolveErr := filepath.EvalSymlinks(metadata.Directory); resolveErr == nil && gotDirectory == wantDirectory {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("runtime metadata did not converge for ghostline session")
}

// TestGhostlineRuntimeAdoptsAfterRestart simulates a daemon restart: a fresh
// adapter instance re-adopts the session from the same server.
func TestGhostlineRuntimeAdoptsAfterRestart(t *testing.T) {
	runtime, client := startGhostlineRuntime(t)
	ctx := context.Background()
	if err := runtime.Create(ctx, "warren_ghost_adopt", t.TempDir(), "sh", nil); err != nil {
		t.Fatalf("Create: %v", err)
	}
	restarted := NewGhostlineRuntime(client)
	if !restarted.Exists(ctx, "warren_ghost_adopt") {
		t.Fatal("session should be re-adopted after a daemon restart")
	}
	if err := restarted.Input(ctx, "warren_ghost_adopt", []byte("echo adopt-ok\r")); err != nil {
		t.Fatalf("Input after restart: %v", err)
	}
	waitGhostlineOutput(t, restarted, "warren_ghost_adopt", "adopt-ok")
}
