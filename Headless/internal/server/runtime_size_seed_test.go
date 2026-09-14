package server

import (
	"context"
	"testing"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

// sizedRecordingRuntime records resize calls and reports a fixed current size,
// standing in for a Ghostline runtime whose sessions survived a daemon restart.
type sizedRecordingRuntime struct {
	memoryRuntime
	size    ghostline.Size
	resizes []recordedResize
}

func (runtime *sizedRecordingRuntime) Resize(_ context.Context, _ string, columns, rows int) error {
	runtime.mu.Lock()
	runtime.resizes = append(runtime.resizes, recordedResize{columns: columns, rows: rows})
	runtime.mu.Unlock()
	return nil
}

func (runtime *sizedRecordingRuntime) Size(context.Context, string) (ghostline.Size, error) {
	return runtime.size, nil
}

func TestSeedRuntimeSizeSkipsUnchangedFocusResize(t *testing.T) {
	runtime := &sizedRecordingRuntime{size: ghostline.Size{Columns: 120, Rows: 40}}
	service := &Service{Runtimes: map[string]Runtime{settings.RuntimeGhostline: runtime}}
	session := api.Session{
		ID:          "session-1",
		Runtime:     "warren_session_1",
		RuntimeKind: settings.RuntimeGhostline,
		Lifecycle:   "running",
	}

	service.seedRuntimeSize(context.Background(), session)
	if _, known := service.runtimeSizeFor(session.ID); !known {
		t.Fatal("runtime size was not seeded")
	}

	resized, err := service.resizeRuntime(context.Background(), session, 120, 40)
	if err != nil {
		t.Fatal(err)
	}
	if resized {
		t.Fatal("an unchanged size must skip the runtime resize")
	}
	if len(runtime.resizes) != 0 {
		t.Fatalf("unexpected resize calls: %#v", runtime.resizes)
	}

	resized, err = service.resizeRuntime(context.Background(), session, 100, 30)
	if err != nil {
		t.Fatal(err)
	}
	if !resized {
		t.Fatal("a changed size must resize the runtime")
	}
	if len(runtime.resizes) != 1 || runtime.resizes[0].columns != 100 || runtime.resizes[0].rows != 30 {
		t.Fatalf("resizes = %#v", runtime.resizes)
	}
}
