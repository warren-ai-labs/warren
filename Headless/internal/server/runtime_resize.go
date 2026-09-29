package server

import (
	"context"
	"fmt"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

// resizeRuntime applies a new viewport to the shared runtime and records the
// size we last applied. Ghostline sends SIGWINCH to the child on every
// Resize, even when the dimensions are unchanged, so repeated claims of the
// same viewport (roster-driven focus requests, duplicate browser callbacks)
// make TUIs redraw and flicker. The recorded size also lets the server
// answer same-size focus/resize requests as accurate no-ops.
//
// A browser Session has no PTY runtime, so it cannot answer a resize through
// Runtimes; its viewport is a pixel size on the Chromium page instead. The two
// are different units — columns and rows here, CSS pixels there — so a browser
// size is not recorded here: runtimeSizes stays a map of PTY grid sizes, which
// keeps the recovery log's size label meaningful. The dedupe that matters still
// happens, on the page: Session.Resize reads the size the Chromium is actually
// at and refuses an unchanged one, so a drag that re-reports the same size does
// not restart the screencast on every event.
func (s *Service) resizeRuntime(ctx context.Context, session api.Session, columns, rows int) (bool, error) {
	size := ghostline.Size{Columns: columns, Rows: rows}
	if current, known := s.runtimeSizeFor(session.ID); known && current == size {
		return false, nil
	}
	if session.Kind == sessionKindBrowser {
		return s.resizeBrowser(ctx, session, columns, rows)
	}
	if isACPSession(session) {
		return false, errSessionHasNoTerminal
	}
	adapter := s.runtimeFor(session)
	if adapter == nil {
		return false, fmt.Errorf("runtime %q is unavailable", s.runtimeKindFor(session))
	}
	if err := adapter.Resize(ctx, session.Runtime, columns, rows); err != nil {
		return false, err
	}
	s.rememberRuntimeSize(session.ID, size)
	s.updateResponderSize(session.ID, columns, rows)
	return true, nil
}

// resizeBrowser applies a client viewport to a browser Session.
//
// The client reports a pixel size, which is what the Chromium page wants
// directly: the viewer is drawn from the screencast, so its box size and the
// page size are the same measurement. A degenerate request — a pane collapsed
// to zero, or a size below the smallest layout worth rendering — is refused
// rather than applied, because a 0x0 viewport stops the screencast entirely
// and the viewer goes black with no way back short of a reload.
func (s *Service) resizeBrowser(ctx context.Context, session api.Session, columns, rows int) (bool, error) {
	if columns <= 0 || rows <= 0 {
		return false, nil
	}
	manager := s.browserManagerIfPresent()
	if manager == nil {
		return false, fmt.Errorf("browser session is not running: %s", session.ID)
	}
	chromium, ok := manager.Session(session.ID)
	if !ok {
		return false, fmt.Errorf("browser session is not running: %s", session.ID)
	}
	if err := chromium.Resize(ctx, api.BrowserViewport{Width: columns, Height: rows}); err != nil {
		return false, err
	}
	return true, nil
}

// enqueueResize records the latest requested viewport for a session and makes
// sure one worker is applying it. The caller has already validated ownership
// and that the size differs from the last applied size; this only schedules.
func (s *Service) enqueueResize(session api.Session, size ghostline.Size) {
	s.lazyInit()
	s.resizeMu.Lock()
	s.resizePending[session.ID] = size
	if !s.resizeActive[session.ID] {
		s.resizeActive[session.ID] = true
		s.resizeWorkers.Add(1)
		go s.runResizeWorker(session)
	}
	s.resizeMu.Unlock()
}

// runResizeWorker applies the latest queued viewport for one session until the
// queue drains. Each application takes the session's broadcast lock so it can
// never interleave with a snapshot/capture, and latest-wins collapses a burst
// of layout callbacks into one or two PTY resizes.
func (s *Service) runResizeWorker(session api.Session) {
	defer s.resizeWorkers.Done()
	for {
		s.resizeMu.Lock()
		size, ok := s.resizePending[session.ID]
		if ok {
			delete(s.resizePending, session.ID)
			s.resizeMu.Unlock()
		} else {
			s.resizeActive[session.ID] = false
			s.resizeMu.Unlock()
			return
		}

		lock := s.broadcastLock(session.ID)
		ctx, cancel := context.WithTimeout(context.Background(), s.commandTimeout())
		if err := lock.LockContext(ctx); err != nil {
			cancel()
			// The session was busy past the command timeout. Keep the request
			// only if nothing newer arrived while we waited.
			s.resizeMu.Lock()
			if _, newer := s.resizePending[session.ID]; !newer {
				s.resizePending[session.ID] = size
			}
			s.resizeMu.Unlock()
			continue
		}
		if _, err := s.resizeRuntime(ctx, session, size.Columns, size.Rows); err != nil {
			s.logWarn("resize worker", "session", session.ID, "error", err.Error())
		}
		lock.Unlock()
		cancel()
	}
}

// flushResizes blocks until every queued viewport application has completed.
// Tests use it to assert the runtime calls a resize produced without waiting on
// wall-clock time.
func (s *Service) flushResizes() {
	s.resizeWorkers.Wait()
}

// runtimeSizeFor reports the last observed PTY grid size for a session.
func (s *Service) runtimeSizeFor(sessionID string) (ghostline.Size, bool) {
	s.lazyInit()
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	size, ok := s.runtimeSizes[sessionID]
	return size, ok
}

// rememberRuntimeSize caches the PTY grid size for a session. Seeding it from
// the runtime after a restart lets the first client focus skip a redundant
// resize, so the resize round trip cannot hold the session broadcast lock
// while the shared runtime is still warming up.
func (s *Service) rememberRuntimeSize(sessionID string, size ghostline.Size) {
	s.lazyInit()
	s.outputMu.Lock()
	s.runtimeSizes[sessionID] = size
	s.outputMu.Unlock()
}

// seedRuntimeSize records the runtime's current size when it is not yet known.
// It runs on the lifecycle loop, never on the client path, so a slow probe
// delays only the seed and is retried on the next reconcile tick.
func (s *Service) seedRuntimeSize(ctx context.Context, session api.Session) {
	if _, known := s.runtimeSizeFor(session.ID); known {
		return
	}
	provider, ok := s.runtimeFor(session).(RuntimeSizeProvider)
	if !ok {
		return
	}
	size, err := provider.Size(ctx, session.Runtime)
	if err != nil || size.Columns <= 0 || size.Rows <= 0 {
		return
	}
	s.rememberRuntimeSize(session.ID, size)
}

func (s *Service) updateResponderSize(sessionID string, columns, rows int) {
	s.outputMu.Lock()
	defer s.outputMu.Unlock()
	if outputSession := s.outputs[sessionID]; outputSession != nil {
		outputSession.responder.Resize(columns, rows)
	}
}
