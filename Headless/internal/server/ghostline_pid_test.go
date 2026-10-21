package server

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func deadTestPID(t *testing.T) int {
	t.Helper()
	for pid := os.Getpid() + 1; pid < os.Getpid()+10000; pid++ {
		if !ghostlineProcessAlive(pid) {
			return pid
		}
	}
	t.Fatal("could not find a dead test pid")
	return 0
}

func writeTestGhostlinePID(t *testing.T, socket string, pid int) {
	t.Helper()
	if err := os.WriteFile(socket+".pid", []byte(strconv.Itoa(pid)+"\n"), 0o600); err != nil {
		t.Fatalf("write pid for %s: %v", socket, err)
	}
}

func TestGhostlineRuntimeProbeReportsDeadServerPID(t *testing.T) {
	directory := t.TempDir()
	stable := filepath.Join(directory, "ghostline.sock")
	target := filepath.Join(directory, "ghostline-target.sock")
	if err := os.Symlink(filepath.Base(target), stable); err != nil {
		t.Fatalf("create stable symlink: %v", err)
	}
	writeTestGhostlinePID(t, target, deadTestPID(t))

	runtime := NewGhostlineRuntime(ghostline.NewClient(stable))
	result := runtime.Probe(context.Background(), "warren_missing")
	if result.State != RuntimeProbeDead || result.Evidence != "server_pid_gone" {
		t.Fatalf("probe result = %#v, want dead server_pid_gone", result)
	}
}

func TestGhostlineRuntimeProbeKeepsUnknownForLiveServerPID(t *testing.T) {
	directory := t.TempDir()
	stable := filepath.Join(directory, "ghostline.sock")
	target := filepath.Join(directory, "ghostline-target.sock")
	if err := os.Symlink(filepath.Base(target), stable); err != nil {
		t.Fatalf("create stable symlink: %v", err)
	}
	writeTestGhostlinePID(t, target, os.Getpid())

	runtime := NewGhostlineRuntime(ghostline.NewClient(stable))
	result := runtime.Probe(context.Background(), "warren_missing")
	if result.State != RuntimeProbeUnknown || result.Evidence != "session_get_failed" {
		t.Fatalf("probe result = %#v, want unknown session_get_failed", result)
	}
}

func TestRunningSessionsReportsDeadWhenServerPIDIsGone(t *testing.T) {
	directory := t.TempDir()
	socket := filepath.Join(directory, "ghostline.sock")
	writeTestGhostlinePID(t, socket, deadTestPID(t))

	runtime := NewGhostlineRuntime(ghostline.NewClient(socket))
	service := &Service{
		Runtimes:       map[string]Runtime{settings.RuntimeGhostline: runtime},
		DefaultRuntime: settings.RuntimeGhostline,
	}
	probe := service.runningSessions(context.Background())(api.Session{
		ID:          "session",
		Runtime:     "warren_session",
		RuntimeKind: settings.RuntimeGhostline,
		Lifecycle:   "running",
	})
	if probe.State != RuntimeProbeDead || probe.Evidence != "server_pid_gone" {
		t.Fatalf("list probe = %#v, want dead server_pid_gone", probe)
	}
}

func TestRunningSessionsKeepsUnknownForLiveServerPID(t *testing.T) {
	directory := t.TempDir()
	socket := filepath.Join(directory, "ghostline.sock")
	writeTestGhostlinePID(t, socket, os.Getpid())

	runtime := NewGhostlineRuntime(ghostline.NewClient(socket))
	service := &Service{
		Runtimes:       map[string]Runtime{settings.RuntimeGhostline: runtime},
		DefaultRuntime: settings.RuntimeGhostline,
	}
	probe := service.runningSessions(context.Background())(api.Session{
		ID:          "session",
		Runtime:     "warren_session",
		RuntimeKind: settings.RuntimeGhostline,
		Lifecycle:   "running",
	})
	if probe.State != RuntimeProbeUnknown || probe.Evidence != "list_failed" {
		t.Fatalf("list probe = %#v, want unknown list_failed", probe)
	}
}

type pidAwareListRuntime struct {
	memoryRuntime
	alive bool
	known bool
}

func (runtime *pidAwareListRuntime) List(context.Context) (map[string]bool, error) {
	return nil, errors.New("connect ghostline server: connection refused")
}

func (runtime *pidAwareListRuntime) ServerProcessAlive() (bool, bool) {
	return runtime.alive, runtime.known
}

func (runtime *pidAwareListRuntime) Probe(context.Context, string) RuntimeProbeResult {
	if runtime.known && !runtime.alive {
		return RuntimeProbeResult{State: RuntimeProbeDead, Evidence: "server_pid_gone"}
	}
	return RuntimeProbeResult{State: RuntimeProbeUnknown, Evidence: "session_get_failed"}
}

func TestReconcileEndsSessionWhenServerPIDIsGone(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &pidAwareListRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{}},
		alive:         false,
		known:         true,
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "warren_session", RuntimeKind: settings.RuntimeGhostline,
			Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{Store: state, Runtime: runtime}
	service.reconcile(context.Background())

	session := state.Snapshot().Sessions[0]
	if session.Lifecycle != "ended" {
		t.Fatalf("dead server pid preserved session: %#v", session)
	}
}

func TestReconcilePreservesSessionWhenServerPIDIsAlive(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &pidAwareListRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{}},
		alive:         true,
		known:         true,
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "warren_session", RuntimeKind: settings.RuntimeGhostline,
			Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{Store: state, Runtime: runtime}
	service.reconcile(context.Background())

	session := state.Snapshot().Sessions[0]
	if session.Lifecycle != "running" {
		t.Fatalf("live server pid ended session: %#v", session)
	}
}
