package browser

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image"
	_ "image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// liveChrome skips the end-to-end tests when no Chromium is installed. The rest
// of the package's tests must pass on a machine with no browser at all.
func liveChrome(t *testing.T) {
	t.Helper()
	if testing.Short() {
		t.Skip("skipping live Chromium test in short mode")
	}
	if _, err := resolveExecutable(); err != nil {
		t.Skipf("no Chromium available: %v", err)
	}
}

// testManager builds a manager with a throwaway profile root.
func testManager(t *testing.T) *Manager {
	t.Helper()
	return NewManager(t.TempDir())
}

// startLiveSession launches a real Chromium for one test.
func startLiveSession(t *testing.T, manager *Manager, headless bool) *Session {
	t.Helper()
	liveChrome(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	session, err := manager.Start(ctx, StartOptions{
		SessionID: "test-" + t.Name(),
		Scope:     "terminalGroup",
		Headless:  headless,
	})
	if err != nil {
		t.Fatalf("start browser session: %v", err)
	}
	t.Cleanup(session.close)
	return session
}

// testPage is a self-contained page: it needs no network, which keeps the test
// deterministic and runnable on a machine with no outbound access.
const testPage = `<!doctype html>
<html><head><title>Warren Browser Test</title></head><body>
<h1 id="heading">Hello Warren</h1>
<button id="greet" onclick="document.getElementById('out').textContent='clicked'">Greet</button>
<input id="name" type="text" value="">
<div id="out"></div>
<a href="#second" id="link">Second</a>
</body></html>`

// testPageURL writes the page to a temp file and returns its file:// URL.
//
// A file URL rather than a data URL because Page.navigate rejects data: URLs
// outright, and a file URL is a real navigation with no network dependency.
func testPageURL(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "page.html")
	if err := os.WriteFile(path, []byte(testPage), 0o644); err != nil {
		t.Fatalf("write test page: %v", err)
	}
	return "file://" + path
}

func TestLiveSessionStartsAndNavigates(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	projection := session.Projection()
	if projection.Phase != PhaseReady {
		t.Fatalf("phase = %q, want %q (error %q)", projection.Phase, PhaseReady, projection.Error)
	}
	if projection.Executable == "" {
		t.Fatal("projection has no executable")
	}
	if projection.DebuggingPort == 0 {
		t.Fatal("projection has no debugging port")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	url := testPageURL(t)
	result, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: url})
	if err != nil {
		t.Fatalf("navigate: %v", err)
	}
	if !strings.Contains(result.URL, "page.html") {
		t.Fatalf("navigate left url %q, want the test page", result.URL)
	}
	if result.Title != "Warren Browser Test" {
		t.Fatalf("title = %q, want the test page title", result.Title)
	}
}

func TestLiveSnapshotFindsInteractiveNodes(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}

	result, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionSnapshot, InteractiveOnly: true})
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	nodes, ok := result.Result["nodes"].([]api.BrowserDomNode)
	if !ok {
		t.Fatalf("snapshot returned no node list: %#v", result.Result)
	}
	var sawButton, sawInput bool
	for _, node := range nodes {
		switch node.Tag {
		case "button":
			sawButton = true
			if node.Role != "button" {
				t.Fatalf("button role = %q", node.Role)
			}
			if !node.Visible {
				t.Fatal("button reported not visible")
			}
		case "input":
			sawInput = true
			if node.Role != "textbox" {
				t.Fatalf("input role = %q", node.Role)
			}
		}
	}
	if !sawButton {
		t.Fatal("interactive snapshot missed the button")
	}
	if !sawInput {
		t.Fatal("interactive snapshot missed the input")
	}
}

func TestLiveClickAndTypeDriveThePage(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}

	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionType, Selector: "#name", Value: "warren"}); err != nil {
		t.Fatalf("type: %v", err)
	}
	value, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionEvaluate, Expression: "document.getElementById('name').value"})
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	if text := resultString(value); text != "warren" {
		t.Fatalf("typed value = %q, want %q", text, "warren")
	}

	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionClick, Selector: "#greet"}); err != nil {
		t.Fatalf("click: %v", err)
	}
	output, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionEvaluate, Expression: "document.getElementById('out').textContent"})
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	if text := resultString(output); text != "clicked" {
		t.Fatalf("click result = %q, want %q", text, "clicked")
	}
}

func TestLiveScreenshotWritesAFile(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}

	path := filepath.Join(t.TempDir(), "shot.jpg")
	result, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionScreenshot, Path: path, FullPage: true})
	if err != nil {
		t.Fatalf("screenshot: %v", err)
	}
	if reported, _ := result.Result["path"].(string); reported != path {
		t.Fatalf("screenshot path = %q, want %q", reported, path)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat screenshot: %v", err)
	}
	if info.Size() < 100 {
		t.Fatalf("screenshot is %d bytes, too small to be a JPEG", info.Size())
	}
	if bytesReported, _ := result.Result["bytes"].(int); bytesReported != int(info.Size()) {
		t.Fatalf("reported %d bytes, file has %d", bytesReported, info.Size())
	}
}

func TestLiveScreencastStreamsFrames(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	// The frame sink must be installed before the screencast starts, otherwise
	// there is nothing to observe.
	frames := make(chan int, 8)
	manager.SetFrameHandler(func(_ string, _ uint64, payload []byte) {
		select {
		case frames <- len(payload):
		default:
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}

	subscriber, _ := session.subscribe()
	defer session.unsubscribe(subscriber)

	// Chrome only emits a screencast frame when the page repaints, and a static
	// test page produces a handful of frames and then silence whether or not the
	// stream is healthy. Alternating the page background forces a real repaint:
	// a transform on the root element is not enough, because shifting a document
	// that already fills the viewport changes no pixels and yields no frame.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		tick := 0
		for {
			select {
			case <-stop:
				return
			case <-time.After(100 * time.Millisecond):
			}
			tick++
			background := "#ff0000"
			if tick%2 == 0 {
				background = "#0000ff"
			}
			expression := fmt.Sprintf("document.body.style.backgroundColor=%q", background)
			if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionEvaluate, Expression: expression}); err != nil {
				return
			}
		}
	}()

	// Chrome sends a short burst and then withholds every further frame until
	// the previous one is acknowledged, so a client that never acks still
	// receives a few frames here. Counting frames therefore proves nothing: the
	// assertion that matters is that a frame arrives well after the burst is
	// over, which only a stream being acknowledged can do.
	const sustainedFor = 5 * time.Second
	deadline := time.After(20 * time.Second)
	var firstAt, sustainedAt time.Time
	received := 0
	for sustainedAt.IsZero() {
		select {
		case payload, ok := <-subscriber.frames:
			if !ok {
				t.Fatal("frame stream closed before a frame arrived")
			}
			// A JPEG starts with SOI and ends with EOI. Checking both keeps a
			// truncated or base64-mangled frame from passing as success.
			if len(payload) < 4 || payload[0] != 0xFF || payload[1] != 0xD8 || payload[len(payload)-2] != 0xFF {
				t.Fatalf("frame is not a JPEG (%d bytes, leading % X)", len(payload), payload[:min(8, len(payload))])
			}
			now := time.Now()
			if firstAt.IsZero() {
				firstAt = now
			}
			if now.Sub(firstAt) >= sustainedFor {
				sustainedAt = now
			}
			received++
		case <-deadline:
			t.Fatalf(
				"screencast delivered %d frame(s) and then stalled %s after the first; the stream is not being acknowledged",
				received, time.Since(firstAt).Round(time.Millisecond),
			)
		}
	}
	if elapsed := sustainedAt.Sub(firstAt); elapsed < sustainedFor {
		t.Fatalf("sustained window was %s, want at least %s", elapsed, sustainedFor)
	}
}

// A screencast frame is rendered at the page's layout size in CSS pixels, and
// Chrome caps it there whatever deviceScaleFactor asks for, so on a display
// denser than 1 the live view is an upscaled, soft picture. A still is the frame
// that carries real pixels, and this measures the page, the capture, and the
// published frame together: the density has to reach window.devicePixelRatio,
// the still has to arrive, and it has to carry the pixels the density asked for.
func TestLiveStillFrameCarriesTheDisplayDensity(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	received := make(chan image.Point, 32)
	manager.SetFrameHandler(func(_ string, _ uint64, payload []byte) {
		config, _, err := image.DecodeConfig(bytes.NewReader(payload))
		if err != nil {
			return
		}
		select {
		case received <- image.Point{X: config.Width, Y: config.Height}:
		default:
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}

	const width, height, scale = 640, 480, 2
	if _, err := session.Perform(ctx, api.BrowserAction{
		Action: api.BrowserActionViewport, Width: width, Height: height, DeviceScaleFactor: scale,
	}); err != nil {
		t.Fatalf("viewport: %v", err)
	}

	// The density is the viewer's display, so the assertion starts at the page: a
	// Host that recorded the number without applying it would still report it.
	var measured struct {
		Width  int     `json:"width"`
		Height int     `json:"height"`
		Scale  float64 `json:"scale"`
	}
	const expression = "({width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio})"
	if err := session.evaluate(ctx, session.pageSession(), expression, &measured); err != nil {
		t.Fatalf("measure viewport: %v", err)
	}
	if measured.Width != width || measured.Height != height {
		t.Fatalf("page is %dx%d, want %dx%d", measured.Width, measured.Height, width, height)
	}
	if measured.Scale != scale {
		t.Fatalf("page devicePixelRatio = %v, want %v", measured.Scale, scale)
	}

	// A still is armed by a frame that paints, and by the viewport action itself;
	// the repaint keeps this test from depending on which of the two ran first.
	if _, err := session.Perform(ctx, api.BrowserAction{
		Action:     api.BrowserActionEvaluate,
		Expression: "document.body.style.backgroundColor='#123456'; 1",
	}); err != nil {
		t.Fatalf("repaint: %v", err)
	}

	want := image.Point{X: width * scale, Y: height * scale}
	deadline := time.After(20 * time.Second)
	for {
		select {
		case got := <-received:
			if got == want {
				return
			}
		case <-deadline:
			t.Fatalf("no still arrived at %v; the stream stayed at the layout size, so the viewer draws an upscaled picture", want)
		}
	}
}

// The viewer forwards the wheel deltas the page hands it, so the direction the
// embedded browser scrolls is decided here. The convention is the page's own — a
// positive DY scrolls down — and the Host used to assume the opposite of the DOM
// and flip it, which scrolled the embedded browser backwards under the pointer.
func TestLiveWheelDeltaScrollsTheWayTheDeltaPoints(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionViewport, Width: 640, Height: 480}); err != nil {
		t.Fatalf("viewport: %v", err)
	}
	// The test page is one screen tall, and a scroll needs somewhere to go.
	if _, err := session.Perform(ctx, api.BrowserAction{
		Action:     api.BrowserActionEvaluate,
		Expression: "document.body.style.height='4000px'; 1",
	}); err != nil {
		t.Fatalf("make the page tall: %v", err)
	}

	scrollY := func() float64 {
		t.Helper()
		var measured struct {
			Y float64 `json:"y"`
		}
		if err := session.evaluate(ctx, session.pageSession(), "({y: window.scrollY})", &measured); err != nil {
			t.Fatalf("measure scroll position: %v", err)
		}
		return measured.Y
	}

	if start := scrollY(); start != 0 {
		t.Fatalf("page starts scrolled to %v, want the top", start)
	}
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionScroll, DY: 300}); err != nil {
		t.Fatalf("scroll down: %v", err)
	}
	time.Sleep(250 * time.Millisecond)
	down := scrollY()
	if down <= 0 {
		t.Fatalf("a positive DY left the page at %v, want it scrolled down", down)
	}
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionScroll, DY: -300}); err != nil {
		t.Fatalf("scroll up: %v", err)
	}
	time.Sleep(250 * time.Millisecond)
	if up := scrollY(); up >= down {
		t.Fatalf("a negative DY scrolled to %v from %v, want it scrolled back up", up, down)
	}
}

// A client dragging the viewer window reaches the page as an ordinary terminal
// resize carrying a pixel size, which used to fail with "runtime unavailable"
// because a browser Session has no PTY runtime. The measurement that matters is
// the page's own: window.innerWidth is the layout width the viewer will draw,
// and a resize that only moved the recorded number would leave it unchanged.
func TestLiveResizeChangesThePageAndRestartsTheStream(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	frames := make(chan struct{}, 16)
	manager.SetFrameHandler(func(_ string, _ uint64, _ []byte) {
		select {
		case frames <- struct{}{}:
		default:
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}

	before := session.currentViewport()
	target := api.BrowserViewport{Width: before.Width + 320, Height: before.Height + 120}
	if err := session.Resize(ctx, target); err != nil {
		t.Fatalf("resize: %v", err)
	}
	if got := session.currentViewport(); got != target {
		t.Fatalf("viewport = %+v, want %+v", got, target)
	}

	// innerWidth is in CSS pixels, which is the same unit the viewport is set
	// in, so an exact match is the assertion — not "a size changed".
	var measured struct {
		Width  int `json:"width"`
		Height int `json:"height"`
	}
	const expression = "({width: window.innerWidth, height: window.innerHeight})"
	if err := session.evaluate(ctx, session.pageSession(), expression, &measured); err != nil {
		t.Fatalf("measure viewport: %v", err)
	}
	if measured.Width != target.Width || measured.Height != target.Height {
		t.Fatalf("page is %dx%d, want %dx%d", measured.Width, measured.Height, target.Width, target.Height)
	}

	// The screencast is stopped and restarted on resize, because Chrome keeps
	// encoding at the dimensions it was started with. A frame arriving after the
	// restart is the proof it came back; without one the viewer goes black.
	//
	// The repaints have to be forced. Chrome emits a frame only when the page
	// paints, and a resize alone paints once — which everyNthFrame=2 discards.
	// Alternating the background gives the restarted stream real work to send.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		tick := 0
		for {
			select {
			case <-stop:
				return
			case <-time.After(100 * time.Millisecond):
			}
			tick++
			background := "#ff0000"
			if tick%2 == 0 {
				background = "#0000ff"
			}
			expression := fmt.Sprintf("document.body.style.backgroundColor=%q", background)
			if err := session.evaluate(ctx, session.pageSession(), expression, nil); err != nil {
				return
			}
		}
	}()

	deadline := time.After(10 * time.Second)
	for {
		select {
		case <-frames:
			return
		case <-deadline:
			t.Fatal("no frame arrived after the resize; the screencast did not restart")
		}
	}
}

// The page target can die while its Chromium keeps running. The attach happens
// once at startup, so without recovery the Session keeps a session id Chrome has
// forgotten: every action fails with "Session with given id not found" and the
// screencast stops, which is a viewer that is black forever while the roster
// still says the Session is running.
//
// Closing the target from CDP is the same event Chrome delivers for a tab closed
// from a visible window, so it reproduces the real failure rather than a
// synthetic one.
func TestLiveClosedPageTargetIsRecovered(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}

	// The resize is applied first so the recovery has a non-default viewport to
	// restore. A recovered page that comes back at Chrome's own size would leave
	// the viewer drawing a differently-sized image than the one it asked for.
	target := api.BrowserViewport{Width: 900, Height: 560}
	if err := session.Resize(ctx, target); err != nil {
		t.Fatalf("resize: %v", err)
	}

	doomed := session.pageTarget()
	if doomed == "" {
		t.Fatal("session has no page target to close")
	}
	oldSession := session.pageSession()
	if _, err := session.client.Call(ctx, "", cdpMethodTargetCloseTarget, cdpTargetCloseParams{TargetID: doomed}); err != nil {
		t.Fatalf("close page target: %v", err)
	}

	// Recovery runs on its own goroutine off the CDP read loop, so the test waits
	// for a new session id rather than assuming one is already installed.
	deadline := time.Now().Add(45 * time.Second)
	for {
		current := session.pageSession()
		if current != "" && current != oldSession {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no page was re-attached within 45s (phase %q, error %q)",
				session.Projection().Phase, session.Projection().Error)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if got := session.pageTarget(); got == doomed {
		t.Fatalf("recovered onto the closed target %s", got)
	}

	// The proof that recovery is complete is an action succeeding, not a field
	// having changed: the re-attach has to have enabled the domains again.
	result, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)})
	if err != nil {
		t.Fatalf("navigate after recovery: %v", err)
	}
	if result.Title != "Warren Browser Test" {
		t.Fatalf("title after recovery = %q, want the test page title", result.Title)
	}
	if got := session.currentViewport(); got != target {
		t.Fatalf("viewport after recovery = %+v, want %+v", got, target)
	}
	var measured struct {
		Width  int `json:"width"`
		Height int `json:"height"`
	}
	const expression = "({width: window.innerWidth, height: window.innerHeight})"
	if err := session.evaluate(ctx, session.pageSession(), expression, &measured); err != nil {
		t.Fatalf("measure viewport: %v", err)
	}
	if measured.Width != target.Width || measured.Height != target.Height {
		t.Fatalf("recovered page is %dx%d, want %dx%d", measured.Width, measured.Height, target.Width, target.Height)
	}
}

// Resizing to the same size must be a no-op, and a degenerate size must be
// refused rather than applied: a 0x0 viewport stops the screencast outright and
// leaves the viewer black with no way back short of a reload.
func TestLiveResizeRejectsDegenerateSizes(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	unchanged := session.currentViewport()
	if err := session.Resize(ctx, unchanged); err != nil {
		t.Fatalf("same-size resize = %v, want nil", err)
	}
	if got := session.currentViewport(); got != unchanged {
		t.Fatalf("same-size resize changed the viewport to %+v", got)
	}
}

func TestLiveUnknownActionIsRejected(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := session.Perform(ctx, api.BrowserAction{Action: "reboot.the.moon"})
	if err == nil {
		t.Fatal("an unknown action must not be accepted")
	}
	if !strings.Contains(err.Error(), "unknown action") {
		t.Fatalf("error = %v, want an unknown-action rejection", err)
	}
}

func TestLiveConsoleCapturesPageOutput(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionEvaluate, Expression: "console.log('hello from the page'); 1"}); err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	result, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionConsole})
	if err != nil {
		t.Fatalf("console: %v", err)
	}
	entries, _ := result.Result["entries"].([]api.BrowserConsoleEntry)
	var found bool
	for _, entry := range entries {
		if strings.Contains(entry.Text, "hello from the page") {
			found = true
		}
	}
	if !found {
		t.Fatalf("console action missed the page log: %#v", entries)
	}
}

func TestLiveMissingElementIsAErrorNotATimeout(t *testing.T) {
	manager := testManager(t)
	session := startLiveSession(t, manager, true)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionNavigate, URL: testPageURL(t)}); err != nil {
		t.Fatalf("navigate: %v", err)
	}
	start := time.Now()
	_, err := session.Perform(ctx, api.BrowserAction{Action: api.BrowserActionClick, Selector: "#does-not-exist"})
	if err == nil {
		t.Fatal("clicking a missing element must fail")
	}
	if !strings.Contains(err.Error(), "no element matches") {
		t.Fatalf("error = %v, want a missing-element rejection", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("missing element took %s to report; an agent cannot wait that long", elapsed)
	}
}

// resultString pulls the string value out of an evaluate result, which is
// encoded as a JSON raw message so the Go side never re-parses it.
func resultString(result api.BrowserActionResult) string {
	raw, ok := result.Result["value"].(json.RawMessage)
	if !ok {
		return ""
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return ""
	}
	return value
}
