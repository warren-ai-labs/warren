package browser

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// Session phases. They mirror the Embedded Editor's phase names on purpose so
// the two components read the same way in a roster and in a client.
const (
	PhaseStarting    = "starting"
	PhaseReady       = "ready"
	PhaseUnavailable = "unavailable"
	PhaseFailed      = "failed"
	PhaseEnded       = "ended"
)

// Default viewport for a browser Session. 1280x800 is the smallest size that
// still renders a real desktop layout, which matters because a snapshot taken
// at a phone width hides elements the agent needs.
const (
	DefaultViewportWidth  = 1280
	DefaultViewportHeight = 800
)

// consoleRingSize bounds the captured console. An agent that reads the console
// after a long session needs the recent entries, not every entry ever emitted;
// unbounded growth would also leak page content into the Host's memory.
const consoleRingSize = 500

// Screencast policy. The frame stream is a live view for a human, not a source
// of truth: an agent that needs exact pixels takes a screenshot action, which
// returns the full-resolution image. Throttling the live stream therefore costs
// nobody correctness and saves the Host a great deal of JPEG encoding.
const (
	screencastMaxWidth      = 1280
	screencastMaxHeight     = 800
	screencastEveryNthFrame = 1
)

// Display density. Chromium lays the page out at the requested CSS size either
// way; the density only decides how many device pixels a captured frame holds.
const (
	defaultDeviceScaleFactor = 1
	// maxDeviceScaleFactor bounds what a client may ask for. Above 3 the still
	// is mostly JPEG artifacts of a page nobody can see at that density.
	maxDeviceScaleFactor = 3
)

// Still policy.
//
// Page.startScreencast answers at the page's layout size in CSS pixels — Chrome
// caps the frame there whatever deviceScaleFactor asks for — so on a display
// denser than 1 the live picture is an upscaled, soft one, and no screencast
// setting changes that. Page.captureScreenshot does honour the device scale
// factor, so a still is the only path to readable text.
//
// Stills are therefore opportunistic rather than continuous: a frame that
// paints arms one for stillSettleDelay later, never more often than
// stillMinimumInterval, and at that rate the higher quality is affordable.
// Motion stays on the screencast, which is the only source fast enough to look
// live.
const (
	stillQuality         = 90
	stillSettleDelay     = 200 * time.Millisecond
	stillMinimumInterval = time.Second
)

// recoveryTimeout bounds one re-attach after a page target dies. It is longer
// than a single CDP round trip because recovery may have to create a target and
// then enable four domains on it, and shorter than forever because a Chromium
// that cannot produce a page is a Session that should end rather than hang.
const recoveryTimeout = 45 * time.Second

// Session is one managed Chromium instance owned by a Warren Session record.
//
// The Warren Session record is the durable identity; this struct is the runtime
// projection and dies with the Chromium process.
type Session struct {
	manager         *Manager
	id              string
	workspaceID     string
	terminalGroupID string
	scope           string

	mu sync.RWMutex

	process       *launchedProcess
	client        *cdpClient
	pageSessionID string
	pageTargetID  string

	headless bool
	viewport api.BrowserViewport
	// viewportDeviceScaleFactor is the display density the page is rendered at:
	// 1 for an ordinary display, 2 for a Retina one. It is what makes a still
	// carry real pixels instead of an upscaled picture of them.
	viewportDeviceScaleFactor float64
	phase                     string
	failure                   string

	// recovering single-flights the re-attach after a page target dies. A crash
	// usually reports itself twice (a detach and a crash event), and two
	// concurrent attaches would race to write pageSessionID.
	recovering bool

	// pageURL and pageTitle describe the active tab. They are tracked from
	// Page.frameNavigated so a roster can show what a browser is on without an
	// agent having to spend an action on it.
	pageURL   string
	pageTitle string

	console []api.BrowserConsoleEntry

	// navigation is the back/forward stack, mirrored from
	// Page.getNavigationHistory so back and forward do not need a round trip to
	// decide whether they can move.
	history      []cdpHistoryEntry
	historyIndex int

	loadGate chan struct{}

	// stillMu guards the still capture. The timer is armed from the CDP read
	// loop and fires on its own goroutine, off that loop by necessity: a capture
	// takes tens of milliseconds and every action on this Session would wait
	// behind it.
	stillMu     sync.Mutex
	stillTimer  *time.Timer
	lastStillAt time.Time
	// stillRunning is true while a capture is in flight and stillWanted records
	// that a change landed while it was. Two captures must never overlap: they
	// would double the encode cost to publish one of the two images anyway.
	stillRunning bool
	stillWanted  bool
	// lastScreencastFrame is the encoded last screencast frame. It is read and
	// written only from the CDP read loop.
	lastScreencastFrame string

	subscriberMu sync.Mutex
	subscribers  map[*frameSubscriber]struct{}
	sequence     uint64

	done      chan struct{}
	closeOnce sync.Once
}

// frameSubscriber receives screencast frames. The channel is buffered and
// dropped rather than blocked: a slow viewer must not stall the CDP read loop,
// which would freeze every action on this Session.
type frameSubscriber struct {
	frames chan []byte
}

// newSession builds the runtime projection. It does not launch Chromium; Start
// does.
func newSession(manager *Manager, id, workspaceID, terminalGroupID, scope string, headless bool, viewport api.BrowserViewport) *Session {
	if viewport.Width <= 0 || viewport.Height <= 0 {
		viewport = api.BrowserViewport{Width: DefaultViewportWidth, Height: DefaultViewportHeight}
	}
	return &Session{
		manager:                   manager,
		id:                        id,
		workspaceID:               workspaceID,
		terminalGroupID:           terminalGroupID,
		scope:                     scope,
		headless:                  headless,
		viewport:                  viewport,
		viewportDeviceScaleFactor: defaultDeviceScaleFactor,
		phase:                     PhaseStarting,
		subscribers:               make(map[*frameSubscriber]struct{}),
		done:                      make(chan struct{}),
	}
}

// Start launches Chromium, attaches to the initial page, and installs the event
// handlers. It is idempotent-guarded by the phase under the lock.
func (s *Session) Start(ctx context.Context) error {
	executable, err := resolveExecutable()
	if err != nil {
		s.fail(err)
		return err
	}
	userDataDir, err := s.manager.userDataDir(s.id)
	if err != nil {
		s.fail(err)
		return err
	}
	process, err := launch(ctx, executable, userDataDir, s.headless)
	if err != nil {
		s.fail(err)
		return err
	}

	client, err := dialCDP(ctx, process.wsURL)
	if err != nil {
		terminate(process.cmd)
		s.fail(err)
		return err
	}

	s.mu.Lock()
	if s.phase != PhaseStarting {
		s.mu.Unlock()
		terminate(process.cmd)
		client.Close()
		return fmt.Errorf("browser session %s already started", s.id)
	}
	s.process = process
	s.client = client
	s.loadGate = make(chan struct{})
	s.mu.Unlock()

	client.onClose = func() {
		s.fail(fmt.Errorf("browser session %s lost its Chromium connection", s.id))
		s.close()
	}
	s.installHandlers(client)

	if err := s.attachInitialPage(ctx, client); err != nil {
		client.Close()
		terminate(process.cmd)
		s.fail(err)
		return err
	}

	s.mu.Lock()
	s.phase = PhaseReady
	s.failure = ""
	s.mu.Unlock()
	return nil
}

// installHandlers wires the CDP events the runtime depends on.
func (s *Session) installHandlers(client *cdpClient) {
	client.On(cdpEventScreencastFrame, func(sessionID string, params json.RawMessage) {
		if sessionID != s.pageSession() {
			return
		}
		var frame cdpScreencastFrame
		if err := json.Unmarshal(params, &frame); err != nil || frame.Data == "" {
			return
		}
		// Acknowledge before publishing. Chrome withholds every further frame
		// until the last one it sent is acked, so an unacknowledged stream looks
		// exactly like a black viewer: a few images, then nothing. A write
		// failure means the socket is gone, so publishing is pointless.
		if err := client.AckScreencastFrame(sessionID, frame.SessionID); err != nil {
			return
		}
		// Taking a still makes Chrome re-capture the surface, which arrives as a
		// screencast frame holding the same page. Publishing it would put the
		// soft copy back on top of the still, and arming a still for it would
		// make a page nobody changed re-capture itself forever. Identical bytes
		// mean identical pixels, which is the whole test.
		if !s.acceptScreencastFrame(frame.Data) {
			return
		}
		s.publishFrame(frame.Data)
		s.scheduleStill()
	})
	client.On(cdpEventRuntimeConsoleAPICalled, func(_ string, params json.RawMessage) {
		var event cdpConsoleAPICalled
		if err := json.Unmarshal(params, &event); err != nil {
			return
		}
		s.recordConsole(event.Type, event.Args, event.Timestamp)
	})
	client.On(cdpEventRuntimeExceptionThrown, func(_ string, params json.RawMessage) {
		var event cdpExceptionThrown
		if err := json.Unmarshal(params, &event); err != nil {
			return
		}
		s.recordConsole("error", []cdpRemoteObject{{Type: "string", Value: json.RawMessage(jsonQuote(event.ExceptionDetails.Text))}}, event.Timestamp)
	})
	client.On(cdpEventFrameStoppedLoading, func(sessionID string, _ json.RawMessage) {
		if sessionID != s.pageSession() {
			return
		}
		s.signalLoad()
	})
	client.On(cdpEventFrameNavigated, func(sessionID string, params json.RawMessage) {
		if sessionID != s.pageSession() {
			return
		}
		var event cdpFrameNavigated
		if err := json.Unmarshal(params, &event); err != nil {
			return
		}
		// Only the main frame is the page. A subframe navigating is an ad or a
		// sandboxed iframe, and reporting its URL as the page's would be wrong.
		if event.Frame.URL == "" || strings.HasPrefix(event.Frame.URL, "about:") {
			return
		}
		s.mu.Lock()
		s.pageURL = event.Frame.URL
		s.mu.Unlock()
	})
	// The page target can die while the Chromium it lives in keeps running: a
	// crashed renderer, a tab closed from the window, or a target Chrome tore
	// down on its own. The attach happens once at startup, so without these two
	// handlers the session keeps a session id Chrome has forgotten — every action
	// then fails with "Session with given id not found" and the screencast stops,
	// which presents as a viewer that is black forever while the roster still
	// reports the Session as running.
	client.On(cdpEventTargetDetachedFromTarget, func(_ string, params json.RawMessage) {
		var event cdpTargetDetached
		if err := json.Unmarshal(params, &event); err != nil {
			return
		}
		if event.SessionID != s.pageSession() {
			return
		}
		s.scheduleRecovery("the page target detached")
	})
	client.On(cdpEventInspectorTargetCrashed, func(sessionID string, _ json.RawMessage) {
		if sessionID != s.pageSession() {
			return
		}
		s.scheduleRecovery("the page renderer crashed")
	})
	client.On(cdpEventJavascriptDialogOpening, func(sessionID string, _ json.RawMessage) {
		if sessionID != s.pageSession() {
			return
		}
		// A dialog the agent cannot see would block every later action until
		// the CDP timeout expires. Dismissing it here keeps the page usable;
		// Page.handleJavaScriptDialogs is what would surface it to a human.
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, _ = s.client.Call(ctx, sessionID, "Page.handleJavaScriptDialog", map[string]any{"accept": false})
		}()
	})
}

// attachInitialPage finds the first page target and attaches to it flattened.
//
// A managed Chromium opens with one blank tab. Attaching to it rather than
// creating a target keeps the tab count at one, which is what a client renders
// and what an agent reasons about.
func (s *Session) attachInitialPage(ctx context.Context, client *cdpClient) error {
	var targets cdpTargets
	deadline := time.Now().Add(10 * time.Second)
	for {
		raw, err := client.Call(ctx, "", cdpMethodTargetGetTargets, nil)
		if err != nil {
			return err
		}
		if err := json.Unmarshal(raw, &targets); err != nil {
			return fmt.Errorf("decode Target.getTargets: %w", err)
		}
		for _, target := range targets.TargetInfos {
			if target.Type == "page" && !target.Attached {
				return s.attachPage(ctx, client, target.TargetID)
			}
		}
		if time.Now().After(deadline) {
			return errors.New("no page target appeared within 10s")
		}
		select {
		case <-time.After(100 * time.Millisecond):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// scheduleRecovery re-attaches to a page after the old one died.
//
// It runs on its own goroutine because it is called from the CDP read loop, and
// recovery issues CDP methods whose replies only that loop can deliver. Doing
// the work inline would deadlock the connection.
//
// Recovery is single-flighted: a crash typically arrives as both a detach and a
// crash event, and two concurrent attaches would race to write pageSessionID and
// leave one screencast running against a session nobody reads.
func (s *Session) scheduleRecovery(reason string) {
	s.mu.Lock()
	if s.phase == PhaseEnded || s.phase == PhaseFailed || s.recovering {
		s.mu.Unlock()
		return
	}
	s.recovering = true
	// The dead session id is cleared now rather than after the re-attach, so the
	// handlers that filter on it stop accepting events for a target that is gone
	// and an action racing the recovery fails fast instead of on a CDP timeout.
	s.pageSessionID = ""
	s.mu.Unlock()

	go func() {
		defer func() {
			s.mu.Lock()
			s.recovering = false
			s.mu.Unlock()
		}()
		ctx, cancel := context.WithTimeout(context.Background(), recoveryTimeout)
		defer cancel()
		if err := s.recoverPage(ctx); err != nil {
			// Nothing was recoverable, so the Session is reported as failed and
			// closed. A Session left running with no page is the black viewer this
			// recovery exists to prevent.
			s.fail(fmt.Errorf("browser session %s could not recover after %s: %w", s.id, reason, err))
			s.close()
		}
	}()
}

// recoverPage attaches to a live page target, opening one if none is left.
//
// Chrome may already have another page (the window still has tabs), in which
// case adopting it keeps the user's browser rather than replacing it. When the
// last page is gone a blank one is created, which is the same state a fresh
// Session starts in.
func (s *Session) recoverPage(ctx context.Context) error {
	s.mu.RLock()
	client := s.client
	s.mu.RUnlock()
	if client == nil {
		return errNoPage
	}

	raw, err := client.Call(ctx, "", cdpMethodTargetGetTargets, nil)
	if err != nil {
		return err
	}
	var targets cdpTargets
	if err := json.Unmarshal(raw, &targets); err != nil {
		return fmt.Errorf("decode %s: %w", cdpMethodTargetGetTargets, err)
	}
	for _, target := range targets.TargetInfos {
		if target.Type != "page" {
			continue
		}
		if err := s.attachPage(ctx, client, target.TargetID); err == nil {
			return nil
		}
	}

	created, err := client.Call(ctx, "", cdpMethodTargetCreateTarget, cdpTargetCreateParams{URL: "about:blank"})
	if err != nil {
		return err
	}
	var result cdpTargetCreateResult
	if err := json.Unmarshal(created, &result); err != nil {
		return fmt.Errorf("decode %s: %w", cdpMethodTargetCreateTarget, err)
	}
	return s.attachPage(ctx, client, result.TargetID)
}

// attachPage attaches to one page target flattened and enables the domains the
// action surface needs.
func (s *Session) attachPage(ctx context.Context, client *cdpClient, targetID string) error {
	raw, err := client.Call(ctx, "", cdpMethodTargetAttachToTarget, cdpTargetAttachParams{TargetID: targetID, Flatten: true})
	if err != nil {
		return err
	}
	var attached cdpTargetAttachResult
	if err := json.Unmarshal(raw, &attached); err != nil {
		return fmt.Errorf("decode Target.attachToTarget: %w", err)
	}
	if attached.SessionID == "" {
		return fmt.Errorf("Target.attachToTarget returned no session for %s", targetID)
	}

	// The domains the action surface reads from. Each is enabled by calling it;
	// none of their results are used.
	for _, method := range []string{cdpMethodPageEnable, cdpMethodRuntimeEnable, cdpMethodDOMEnable, cdpMethodNetworkEnable} {
		if _, err := client.Call(ctx, attached.SessionID, method, nil); err != nil {
			return fmt.Errorf("%s: %w", method, err)
		}
	}

	// Seed the viewport so the screencast and a screenshot agree. It is read
	// under the lock because a re-attach after a crash runs concurrently with a
	// client resize, and the size the recovered page comes back at must be the
	// one the viewer is currently drawing.
	viewport := s.currentViewport()
	if err := s.applyViewport(ctx, attached.SessionID, viewport, s.currentDeviceScaleFactor()); err != nil {
		return err
	}
	s.resetLoadGate()

	// The session id is published here: after the domains and the viewport, so an
	// action racing a recovery cannot run against a page that is not laid out yet
	// and get an answer at the wrong size; and before the screencast, because the
	// frame handler recognises frames by this id and has to acknowledge the first
	// one. An unacknowledged frame stops the stream for good, so a frame arriving
	// before the id is published would be a permanently black viewer.
	s.mu.Lock()
	s.pageSessionID = attached.SessionID
	s.pageTargetID = targetID
	s.mu.Unlock()
	return s.startScreencast(ctx, attached.SessionID)
}

// applyViewport sets the page size in CSS pixels.
func (s *Session) applyViewport(ctx context.Context, sessionID string, viewport api.BrowserViewport, deviceScaleFactor float64) error {
	_, err := s.client.Call(ctx, sessionID, cdpMethodEmulationSetDeviceMetricsOverride, cdpEmulationSetDeviceMetricsParams{
		Width:             viewport.Width,
		Height:            viewport.Height,
		DeviceScaleFactor: deviceScaleFactor,
		Mobile:            false,
	})
	return err
}

// clampDeviceScaleFactor keeps a client-supplied density inside the range a
// display can actually have. A zero arrives from a viewer that predates the
// field, which means "unchanged" rather than "no density".
func clampDeviceScaleFactor(scale float64) float64 {
	switch {
	case scale <= 0:
		return defaultDeviceScaleFactor
	case scale < 1:
		return 1
	case scale > maxDeviceScaleFactor:
		return maxDeviceScaleFactor
	default:
		return scale
	}
}

// startScreencast begins JPEG frame delivery for the active page.
//
// The stream is throttled by policy rather than by demand. Every compositor
// commit produces a frame, which on a page with a CSS animation is dozens a
// second for a full-region JPEG — work the Host pays even when nobody is
// watching. The max dimensions cap the payload, so a viewer that reconnects
// after a network gap is not handed a backlog of oversized frames to catch up
// on.
func (s *Session) startScreencast(ctx context.Context, sessionID string) error {
	// The caps follow the page size rather than being a fixed 1280x800: a fixed
	// cap silently scaled every larger viewer down, which is the softness a
	// viewer sees after the window grows past it. The frame is therefore never
	// larger than the page the viewer is looking at.
	viewport := s.currentViewport()
	maxWidth := screencastMaxWidth
	maxHeight := screencastMaxHeight
	if viewport.Width > 0 && viewport.Height > 0 {
		maxWidth = viewport.Width
		maxHeight = viewport.Height
	}
	_, err := s.client.Call(ctx, sessionID, cdpMethodPageStartScreencast, cdpPageStartScreencastParams{
		Format:        "jpeg",
		Quality:       80,
		MaxWidth:      maxWidth,
		MaxHeight:     maxHeight,
		EveryNthFrame: screencastEveryNthFrame,
	})
	return err
}

// Refresh renders one frame onto the screencast.
//
// Chrome emits a screencast frame only when the page paints, so a viewer that
// attaches to a page that has already settled receives nothing: the frame it
// needed was published before it subscribed, and a static page will not paint
// again on its own. A capture is a paint the page does not see — it renders the
// surface without changing it, and the screencast taps the same output. The
// image it returns is discarded; only the side effect is wanted.
func (s *Session) Refresh(ctx context.Context) error {
	s.mu.RLock()
	client := s.client
	s.mu.RUnlock()
	sessionID := s.pageSession()
	if client == nil || sessionID == "" {
		return errNoPage
	}
	_, err := client.Call(ctx, sessionID, cdpMethodPageCaptureScreenshot, cdpPageCaptureScreenshotParams{
		Format:  "jpeg",
		Quality: 1,
		// A throttled or not-yet-painted renderer answers with an error rather
		// than an empty image without it.
		FromSurface: true,
	})
	if err != nil {
		return err
	}
	// The viewer is watching now, and this frame is what it will draw. A still
	// is the only frame that can be sharper than the display lets the live
	// stream be, and a settled page will not paint again to ask for one.
	s.scheduleStill()
	return nil
}

func (s *Session) pageSession() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.pageSessionID
}

func (s *Session) pageTarget() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.pageTargetID
}

// resetLoadGate installs a fresh gate so the next navigation can wait on it.
func (s *Session) resetLoadGate() {
	s.mu.Lock()
	s.loadGate = make(chan struct{})
	s.mu.Unlock()
}

func (s *Session) signalLoad() {
	s.mu.RLock()
	gate := s.loadGate
	s.mu.RUnlock()
	if gate == nil {
		return
	}
	select {
	case <-gate:
	default:
		close(gate)
	}
}

// awaitLoad waits for the current navigation to finish, bounded by the timeout.
// A page that never fires frameStoppedLoading (a hang, or a page that keeps
// loading resources) must not block the action forever.
func (s *Session) awaitLoad(ctx context.Context, timeout time.Duration) {
	s.mu.RLock()
	gate := s.loadGate
	s.mu.RUnlock()
	if gate == nil {
		return
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-gate:
	case <-timer.C:
	case <-ctx.Done():
	}
}

// fail records why the runtime is unavailable. The message is surfaced to
// clients verbatim, so it must name the cause and not just "failed".
func (s *Session) fail(err error) {
	if err == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.phase == PhaseFailed || s.phase == PhaseEnded {
		return
	}
	s.phase = PhaseFailed
	s.failure = err.Error()
}

// close ends the runtime: stop the screencast, close the CDP connection, and
// terminate Chromium.
func (s *Session) close() {
	s.closeOnce.Do(func() {
		close(s.done)
	})
	s.mu.Lock()
	launched := s.process
	client := s.client
	s.process = nil
	s.client = nil
	if s.phase != PhaseFailed {
		s.phase = PhaseEnded
	}
	s.mu.Unlock()
	s.stillMu.Lock()
	if s.stillTimer != nil {
		s.stillTimer.Stop()
		s.stillTimer = nil
	}
	s.stillMu.Unlock()
	if client != nil {
		client.Close()
	}
	if launched != nil {
		terminate(launched.cmd)
	}
	s.dropSubscribers()
	s.manager.remove(s.id)
}

// Done reports when the runtime has ended.
func (s *Session) Done() <-chan struct{} { return s.done }

// Close ends the runtime. It is the exported form of close so the Host, which
// owns the Session record, can end a Chromium it no longer wants.
func (s *Session) Close() { s.close() }

// Projection renders the runtime state as the API type a client reads.
func (s *Session) Projection() api.BrowserSession {
	s.mu.RLock()
	defer s.mu.RUnlock()
	projection := api.BrowserSession{
		ID:              s.id,
		Scope:           s.scope,
		WorkspaceID:     s.workspaceID,
		TerminalGroupID: s.terminalGroupID,
		Phase:           s.phase,
		Error:           s.failure,
		Headless:        s.headless,
		Viewport:        s.viewport,
		URL:             s.pageURL,
		PageTitle:       s.pageTitle,
	}
	if s.process != nil {
		projection.Executable = s.process.executable
		projection.DebuggingPort = s.process.port
		projection.UserDataDir, _ = s.manager.userDataDir(s.id)
	}
	return projection
}

// setPageState records the active tab's location and title.
//
// It is written by both the navigation event and the action result: the event
// keeps the roster current for a page that redirects on its own, and the action
// result catches a title Chrome has not yet committed an event for.
func (s *Session) setPageState(url, title string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if url != "" {
		s.pageURL = url
	}
	if title != "" {
		s.pageTitle = title
	}
}

// recordConsole appends one entry, dropping the oldest past the ring bound.
func (s *Session) recordConsole(level string, args []cdpRemoteObject, timestamp float64) {
	text := renderConsoleArgs(args)
	entry := api.BrowserConsoleEntry{
		Level:     level,
		Text:      text,
		Timestamp: int64(timestamp),
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.console = append(s.console, entry)
	if len(s.console) > consoleRingSize {
		s.console = append([]api.BrowserConsoleEntry(nil), s.console[len(s.console)-consoleRingSize:]...)
	}
}

// consoleEntries returns the captured console, filtered by level.
func (s *Session) consoleEntries(level string, limit int) []api.BrowserConsoleEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entries := make([]api.BrowserConsoleEntry, 0, len(s.console))
	for i := len(s.console) - 1; i >= 0; i-- {
		entry := s.console[i]
		if level != "" && entry.Level != level {
			continue
		}
		entries = append(entries, entry)
		if limit > 0 && len(entries) >= limit {
			break
		}
	}
	return entries
}

// renderConsoleArgs flattens CDP console arguments into one line. A structured
// argument is kept as JSON rather than stringified, because an agent reading a
// console line wants the object, not "[object Object]".
func renderConsoleArgs(args []cdpRemoteObject) string {
	parts := make([]string, 0, len(args))
	for _, arg := range args {
		if len(arg.Value) == 0 {
			parts = append(parts, arg.Subtype)
			continue
		}
		var value any
		if err := json.Unmarshal(arg.Value, &value); err != nil {
			parts = append(parts, strings.Trim(string(arg.Value), `"`))
			continue
		}
		switch typed := value.(type) {
		case string:
			parts = append(parts, typed)
		default:
			encoded, err := json.Marshal(typed)
			if err != nil {
				parts = append(parts, fmt.Sprint(typed))
				continue
			}
			parts = append(parts, string(encoded))
		}
	}
	return strings.Join(parts, " ")
}

// jsonQuote JSON-encodes a string so it can be embedded as a remote object
// value without building one by hand at every call site.
func jsonQuote(value string) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		return `""`
	}
	return string(encoded)
}
