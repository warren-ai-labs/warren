package server

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

// A browser Session has no PTY runtime, so a client dragging the viewer window
// used to fail with `runtime "browser" is unavailable`: runtimeForKind resolved
// the Session's kind, found no adapter registered under it, and gave up before
// anyone looked at the Chromium.
//
// The regression is that the resize is answered at all — with a Chromium running
// the correct answer is to size the page, and with none running it is to say the
// browser is gone. Neither of those is "the runtime kind is unknown", and a PTY
// adapter must never see the request.
func TestBrowserSessionResizeDoesNotFallBackToThePTYRuntime(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "test")
	if err != nil {
		t.Fatal(err)
	}
	browserSession := api.Session{
		ID: store.NewID(), Kind: sessionKindBrowser, RuntimeKind: sessionKindBrowser,
		Lifecycle: "running", CreatedAt: time.Now().UTC(),
	}
	if err := state.Update(func(value *api.State) error {
		value.Sessions = []api.Session{browserSession}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	runtime := &recordingRuntime{
		memoryRuntime: memoryRuntime{sessions: map[string][]byte{browserSession.Runtime: []byte("prompt")}},
		captureSeen:   make(chan struct{}),
	}
	// Runtimes is populated the way the daemon populates it: Ghostline is
	// registered under its own kind, and nothing is registered for a browser.
	// Leaving it nil would let runtimeForKind fall back to the default adapter,
	// which hides the shape of the real failure.
	service := &Service{
		Store:    state,
		Runtime:  runtime,
		Runtimes: map[string]Runtime{settings.RuntimeGhostline: runtime},
	}

	// No Chromium is running here, so the expected answer is "the browser is
	// gone" — the point of the assertion is which error, not that it is one.
	_, err = service.resizeRuntime(context.Background(), browserSession, 640, 480)
	if err == nil {
		t.Fatal("resize of a browser with no Chromium unexpectedly succeeded")
	}
	if strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("browser resize reported the PTY runtime unavailable: %v", err)
	}
	if _, resizes := runtime.snapshotOrder(); len(resizes) != 0 {
		t.Fatalf("PTY runtime was resized for a browser session: %#v", resizes)
	}

	// A collapsed pane reports a zero size. It must be refused as a no-op
	// rather than applied, because a 0x0 viewport stops the screencast and the
	// viewer goes black with no way back short of a reload.
	zeroed, err := service.resizeRuntime(context.Background(), browserSession, 0, 0)
	if err != nil || zeroed {
		t.Fatalf("zero-sized browser resize = (%t, %v), want (false, nil)", zeroed, err)
	}
	if _, resizes := runtime.snapshotOrder(); len(resizes) != 0 {
		t.Fatalf("zero-sized resize reached the PTY runtime: %#v", resizes)
	}
}
