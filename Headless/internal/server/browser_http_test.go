package server

import (
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/store"
	"github.com/gorilla/websocket"
)

// The viewer page is JavaScript, so the two things a person feels immediately
// when they are wrong -- where a click lands and which way the wheel scrolls --
// are outside the reach of a Go assertion. The page is served to a web view and
// never compiled, so its script is run here against a minimal DOM instead: a
// socket that records what the page sends is the assertion surface, and the
// actions are what crosses the boundary to the Host.
//
// The stub is deliberately not a DOM. Anything the page does not read at load
// time is absent, so a stub that has to grow is a page that started needing
// more of a browser than it should have.
const viewerPageStub = `
globalThis.window = globalThis;
const handlers = {};
const rects = {stage: {width: 0, height: 0, left: 0, top: 0}, frame: {width: 0, height: 0, left: 0, top: 0}};
const elements = {};
function element(id) {
  if (elements[id]) { return elements[id]; }
  elements[id] = {
    id: id, value: '', textContent: '', style: {}, disabled: false, src: '',
    naturalWidth: 0, naturalHeight: 0, onload: null,
    addEventListener: function (type, fn) { handlers[id + ':' + type] = fn; },
    getBoundingClientRect: function () { return rects[id] || {width: 0, height: 0, left: 0, top: 0}; },
  };
  return elements[id];
}
globalThis.document = {activeElement: null, getElementById: element};
const sockets = [];
class StubSocket {
  constructor(url) { this.url = url; this.sent = []; this.readyState = 1; sockets.push(this); }
  send(data) { this.sent.push(data); }
  close() { this.readyState = 3; }
}
StubSocket.OPEN = 1;
globalThis.WebSocket = StubSocket;
globalThis.location = {hash: '', protocol: 'http:', host: '127.0.0.1:1'};
globalThis.sessionStorage = {getItem: function () { return null; }, setItem: function () {}};
globalThis.ResizeObserver = class { observe() {} };
globalThis.addEventListener = function (type, fn) { handlers['window:' + type] = fn; };
// The page's keepalive is an interval, and a test cannot wait a minute for it.
// Recording the interval is what puts the ping itself under test.
const intervals = [];
globalThis.setInterval = function (fn, ms) {
  const handle = {fn: fn, ms: ms, cleared: false};
  intervals.push(handle);
  return handle;
};
globalThis.clearInterval = function (handle) { if (handle) { handle.cleared = true; } };
`

const viewerPageAssertions = `
const problems = [];
function check(name, actual, expected) {
  if (String(actual) !== String(expected)) { problems.push(name + ': got ' + actual + ', want ' + expected); }
}
function lastSocket() { return sockets[sockets.length - 1]; }
function sentActions(socket) {
  return socket.sent
    .map(function (raw) { return JSON.parse(raw); })
    .filter(function (message) { return message.t === 'action'; })
    .map(function (message) { return message.action; });
}
function lastAction(socket, name) {
  const found = sentActions(socket).filter(function (action) { return action.action === name; });
  return found[found.length - 1];
}
function viewportCount(socket) {
  return sentActions(socket).filter(function (action) { return action.action === 'viewport'; }).length;
}

// The stage is 1000x600 CSS pixels under a 40px header, and the frame fills it:
// one image pixel is one CSS pixel.
rects.stage = {width: 1000, height: 600, left: 0, top: 40};
rects.frame = {width: 1000, height: 600, left: 0, top: 40};
elements.frame.naturalWidth = 1000;
elements.frame.naturalHeight = 600;

elements.token.value = 'test-token';
connect();
const viewerSocket = sockets[0];
viewerSocket.onopen();
check('auth envelope', viewerSocket.sent[0], JSON.stringify({t: 'auth', token: 'test-token'}));
check('stream names the session', viewerSocket.url.indexOf('session=test-session') >= 0, true);

// The Host's ready is when the page tells it how big it is and how dense the
// display is. The density is what the Host renders a still at; it never changes
// the layout.
viewerSocket.onmessage({data: JSON.stringify({t: 'ready'})});
check('viewport width', lastAction(viewerSocket, 'viewport').width, 1000);
check('viewport height', lastAction(viewerSocket, 'viewport').height, 600);
check('viewport density', lastAction(viewerSocket, 'viewport').deviceScaleFactor, 1);
check('notice hidden once connected', elements.notice.style.display, 'none');
check('frame shown once connected', elements.frame.style.display, 'block');

// A 1x frame: a pointer at (250, 190) is 150 CSS pixels below the stage top.
handlers['frame:pointerdown']({clientX: 250, clientY: 190, preventDefault: function () {}});
check('1x click x', lastAction(viewerSocket, 'click').x, 250);
check('1x click y', lastAction(viewerSocket, 'click').y, 150);

// A still carries the display's density, so its image is twice the layout. The
// same pointer has to land in the same place on the page and not at twice the
// offset, which is what a page that assumed 1:1 image pixels would send.
elements.frame.naturalWidth = 2000;
elements.frame.naturalHeight = 1200;
handlers['frame:pointerdown']({clientX: 250, clientY: 190, preventDefault: function () {}});
check('still click x', lastAction(viewerSocket, 'click').x, 250);
check('still click y', lastAction(viewerSocket, 'click').y, 150);

// The wheel reaches the Host with the deltas the page gave it, so a downward
// wheel scrolls the embedded browser down.
handlers['frame:wheel']({clientX: 250, clientY: 190, deltaX: 0, deltaY: 120, preventDefault: function () {}});
flushWheel();
check('wheel x', lastAction(viewerSocket, 'scroll').x, 250);
check('wheel y', lastAction(viewerSocket, 'scroll').y, 150);
check('wheel dx', lastAction(viewerSocket, 'scroll').dx, 0);
check('wheel dy', lastAction(viewerSocket, 'scroll').dy, 120);

// A person watching a page sends nothing, and the Host reaps a read that stays
// silent for five minutes, so the page has to say something on its own.
const keepalive = intervals.filter(function (handle) { return !handle.cleared; }).pop();
check('keepalive interval exists', Boolean(keepalive), true);
check('keepalive interval is a minute', keepalive && keepalive.ms, 60000);
viewerSocket.sent.length = 0;
keepalive.fn();
check('keepalive is not an action', viewerSocket.sent[0], JSON.stringify({t: 'ping'}));

// A stream that ends has to come back by itself: this is the pane that used to
// sit on "paste the Host token" until the app was restarted.
viewerSocket.onclose();
check('nav disabled while reconnecting', elements.back.disabled, true);
check('frame stays up while reconnecting', elements.notice.style.display, 'none');
check('reconnect is announced', elements.status.textContent, 'reconnecting in 1s');
await new Promise(function (resolve) { setTimeout(resolve, 800); });
check('a second attempt was made', sockets.length, 2);
const retried = lastSocket();
retried.onopen();
check('reconnect re-authenticates', retried.sent[0], JSON.stringify({t: 'auth', token: 'test-token'}));
retried.onmessage({data: JSON.stringify({t: 'ready'})});
// The size and density are re-asserted: the Host may have been restarted since,
// and appliedViewport would otherwise dedupe the repeat away.
check('reconnect re-sends the viewport', viewportCount(retried), 1);
check('connected again', elements.status.textContent, 'connected');
check('notice hidden again', elements.notice.style.display, 'none');

// Before the stream is up, an error is the Host refusing this viewer. Retrying
// cannot fix a token it does not accept, so the page stops and says so.
retried.onclose();
await new Promise(function (resolve) { setTimeout(resolve, 1200); });
check('third attempt was made', sockets.length, 3);
const refused = lastSocket();
refused.onopen();
refused.onmessage({data: JSON.stringify({t: 'error', error: 'unauthorized'})});
check('refusal is reported', elements.notice.textContent, 'Cannot watch this browser: unauthorized');
check('refusal is shown', elements.notice.style.display, 'block');
await new Promise(function (resolve) { setTimeout(resolve, 800); });
check('a refused viewer is not retried', sockets.length, 3);

if (problems.length) {
  console.error('viewer page assertions failed:\n' + problems.join('\n'));
  process.exit(1);
}
console.log('viewer page assertions passed');
`

// TestViewerPagePointerWheelAndReconnect covers the viewer page's own behavior:
// the layout-size mapping that makes a click land where the user aimed, the
// wheel deltas that decide which way the embedded browser scrolls, and the
// connection that has to put itself back after a stream ends.
func TestViewerPagePointerWheelAndReconnect(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skipf("no node to run the viewer page script: %v", err)
	}
	page := browserViewerPage(`"test-session"`)
	opening := strings.Index(page, "<script>")
	closing := strings.Index(page, "</script>")
	if opening < 0 || closing < opening {
		t.Fatal("the viewer page has no script to run")
	}
	script := page[opening+len("<script>") : closing]
	combined := viewerPageStub + "\n" + script + "\n" + viewerPageAssertions
	path := filepath.Join(t.TempDir(), "viewer.mjs")
	if err := os.WriteFile(path, []byte(combined), 0o644); err != nil {
		t.Fatalf("write the viewer script: %v", err)
	}
	output, err := exec.Command(node, path).CombinedOutput()
	if err != nil {
		t.Fatalf("the viewer page script failed:\n%s", output)
	}
}

// A viewer page runs in WebKit, and WebKit offers permessage-deflate. Accepting
// that offer is what broke the pane: WebKit closed the socket with "close 1002
// (protocol error)" about 0.2s after the first large frame, once a second,
// forever — measured with Safari against a running Host, which is the same
// engine the pane renders in. Chromium and Go clients do not negotiate the
// extension, which is why a browser-based check of the same page looked healthy
// and why this is pinned at the handshake instead of through a frame.
//
// The control dials the daemon's other stream, where the offer *is* accepted:
// without it a client that never sent the extension would pass the assertion
// above and prove nothing.
func TestBrowserStreamUpgradesWithoutCompression(t *testing.T) {
	state, err := store.Open(filepath.Join(t.TempDir(), "state.json"), "browser-stream-compression-test")
	if err != nil {
		t.Fatal(err)
	}
	service := &Service{Store: state, Runtime: &memoryRuntime{sessions: map[string][]byte{}}}
	server := httptest.NewServer(NewHTTPServer(service, "secret", slog.New(slog.NewTextHandler(io.Discard, nil))).Handler())
	defer server.Close()
	base := "ws" + strings.TrimPrefix(server.URL, "http")

	extensions := func(path string) string {
		t.Helper()
		dialer := websocket.Dialer{EnableCompression: true}
		connection, response, err := dialer.Dial(base+path, nil)
		if err != nil {
			t.Fatalf("dial %s: %v", path, err)
		}
		defer connection.Close()
		// Answer the stream's first read so the handler finishes instead of
		// waiting out its authentication deadline.
		_ = connection.WriteMessage(websocket.TextMessage, []byte(`{"t":"auth","token":"secret"}`))
		return response.Header.Get("Sec-WebSocket-Extensions")
	}

	if got := extensions("/v1/browser/stream?session=probe"); strings.Contains(got, "permessage-deflate") {
		t.Fatalf("the browser stream negotiated %q; WebKit rejects the compressed frames with a protocol error", got)
	}
	if got := extensions("/v1/ws"); !strings.Contains(got, "permessage-deflate") {
		t.Fatalf("the control stream negotiated %q; the client's offer is not being accepted, so the assertion above proves nothing", got)
	}
}
