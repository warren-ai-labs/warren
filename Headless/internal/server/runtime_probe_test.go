package server

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

type failingListRuntime struct {
	memoryRuntime
	err   error
	probe RuntimeProbeResult
}

func (runtime *failingListRuntime) List(context.Context) (map[string]bool, error) {
	return nil, runtime.err
}

func (runtime *failingListRuntime) Probe(context.Context, string) RuntimeProbeResult {
	return runtime.probe
}

func TestReconcilePreservesSessionWhenRuntimeListIsUnknown(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	runtime := &failingListRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{"runtime-live": {}}},
		err:           errors.New("ghostline unavailable"),
		probe:         RuntimeProbeResult{State: RuntimeProbeUnknown, Evidence: "status_timeout", Err: errors.New("status timeout")},
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{{
			ID: "session", Runtime: "runtime-live", Lifecycle: "running", CreatedAt: time.Now().UTC(),
		}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	service := &Service{Store: state, Runtime: runtime}
	service.reconcile(context.Background())

	session := state.Snapshot().Sessions[0]
	if session.Lifecycle != "running" {
		t.Fatalf("unknown runtime probe ended session: %#v", session)
	}
}

func TestProbeRuntimeUsesTypedResultBeforeLegacyExists(t *testing.T) {
	runtime := &failingListRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{}},
		probe:         RuntimeProbeResult{State: RuntimeProbeUnknown, Evidence: "transport_error"},
	}
	result := (&Service{}).probeRuntime(context.Background(), runtime, "missing")
	if result.State != RuntimeProbeUnknown || result.Evidence != "transport_error" {
		t.Fatalf("probe result = %#v, want typed unknown", result)
	}
}
