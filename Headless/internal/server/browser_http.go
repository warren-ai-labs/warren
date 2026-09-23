package server

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/gorilla/websocket"
)

// browserStreamAuthTimeout bounds how long an unauthenticated stream may stay
// open. The first message must be an auth envelope, exactly as on /v1/ws.
const browserStreamAuthTimeout = 10 * time.Second

// browserStreamIdleTimeout bounds one read. A viewer that stops sending input
// keeps its stream: the deadline is per read, not for the connection's life.
const browserStreamIdleTimeout = 5 * time.Minute

// handleBrowserView serves the standalone viewer page.
//
// The page itself carries no Host state — it is a canvas, a token field, and a
// WebSocket — so it is served without authentication, the same way the web
// client's index.html is. Everything the page can actually show arrives over
// /v1/browser/stream, which is authenticated.
func (s *HTTPServer) handleBrowserView(writer http.ResponseWriter, request *http.Request) {
	sessionID := strings.TrimSpace(request.URL.Query().Get("session"))
	if sessionID == "" {
		http.Error(writer, "session is required", http.StatusBadRequest)
		return
	}
	if _, err := s.Service.BrowserSession(sessionID); err != nil {
		http.Error(writer, "browser session not found", http.StatusNotFound)
		return
	}
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	// The session ID is embedded so the page does not have to re-parse the URL,
	// and it is escaped as a JSON string literal rather than interpolated into
	// markup: a session ID arrives from a query parameter.
	encoded, err := json.Marshal(sessionID)
	if err != nil {
		http.Error(writer, "unable to render viewer", http.StatusInternalServerError)
		return
	}
	_, _ = writer.Write([]byte(browserViewerPage(string(encoded))))
}

// handleBrowserStream upgrades one viewer connection.
//
// Frames travel down as the same DENB browserFrame envelopes /v1/ws carries, so
// a client that already decodes browser frames needs no second decoder. Input
// travels up as normalized actions — the same api.BrowserAction shape the RPC
// surface takes — which keeps one action implementation instead of two.
func (s *HTTPServer) handleBrowserStream(writer http.ResponseWriter, request *http.Request) {
	sessionID := strings.TrimSpace(request.URL.Query().Get("session"))
	if sessionID == "" {
		http.Error(writer, "session is required", http.StatusBadRequest)
		return
	}
	// The viewer page runs in WebKit, which offers permessage-deflate: accepting it
	// is what broke the pane. WebKit closed the socket with "close 1002 (protocol
	// error)" about 0.2s after the first large frame, once a second, forever —
	// measured with Safari against a running Host, and it is the same engine the
	// pane runs. Chromium and Go clients do not negotiate the extension, which is
	// why a browser-based check of the same page looked healthy.
	//
	// This stream therefore upgrades without compression. The daemon's own
	// upgrader keeps it for the endpoints that are not rendered by WebKit.
	upgrader := s.upgrader
	upgrader.EnableCompression = false
	connection, err := upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	peer := newWSPeer(s, connection)
	defer func() {
		s.Service.detachPeer(peer, sessionID)
		peer.closeWithReason("viewer_disconnect")
	}()

	_ = connection.SetReadDeadline(time.Now().Add(browserStreamAuthTimeout))
	var envelope api.Envelope
	if err := connection.ReadJSON(&envelope); err != nil || envelope.Type != "auth" {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	if _, authenticated := s.authenticatedClient(envelope.Token); !authenticated {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "unauthorized"})
		return
	}
	s.Service.registerPeer(sessionID, peer)
	if _, err := s.Service.BrowserSession(sessionID); err != nil {
		_ = peer.writeJSON(api.Response{Type: "error", OK: false, Error: "browser session not found"})
		return
	}
	// A settled page paints only when something changes it, so a viewer that
	// attaches to an idle page is handed nothing at all until it does. Rendering
	// one frame here is what makes the viewer show the page it just opened.
	s.Service.refreshBrowserFrame(sessionID)
	_ = peer.writeJSON(map[string]any{"t": "ready", "session": sessionID})

	for {
		_ = connection.SetReadDeadline(time.Now().Add(browserStreamIdleTimeout))
		messageType, payload, readErr := connection.ReadMessage()
		if readErr != nil {
			return
		}
		if messageType != websocket.TextMessage {
			continue
		}
		var message struct {
			Type   string           `json:"t"`
			Action api.BrowserAction `json:"action"`
		}
		if err := json.Unmarshal(payload, &message); err != nil || message.Type != "action" {
			continue
		}
		actionContext, cancel := context.WithTimeout(request.Context(), 60*time.Second)
		result, performErr := s.Service.PerformBrowserAction(actionContext, sessionID, message.Action)
		cancel()
		if performErr != nil {
			_ = peer.writeJSON(map[string]any{"t": "error", "error": performErr.Error()})
			continue
		}
		_ = peer.writeJSON(map[string]any{"t": "result", "result": result})
	}
}

// browserViewerPage renders the viewer document.
//
// It is deliberately plain: no build step, no framework, no dependency on the
// web client bundle. The viewer is part of the browser runtime, so it ships with
// the Host rather than with a client.
//
// The page is a mirror plus a remote control. It paints the screencast frames it
// receives and forwards the pointer and keyboard back as normalized actions —
// the same api.BrowserAction shape the RPC surface takes — so there is one action
// implementation rather than two (RFC 0022 §8.3).
func browserViewerPage(sessionIDJSON string) string {
	return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Warren Browser</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font: 13px/1.5 -apple-system, system-ui, sans-serif;
         display: flex; flex-direction: column; height: 100vh; background: #111; }
  header { display: flex; gap: 6px; align-items: center; padding: 6px 8px;
           background: #1c1c1e; color: #eee; }
  header button { padding: 3px 8px; border-radius: 4px; border: 1px solid #444;
                  background: #2c2c2e; color: #eee; cursor: pointer; }
  header button:disabled { opacity: 0.4; cursor: default; }
  header input { flex: 1; padding: 4px 6px; border-radius: 4px;
                 border: 1px solid #444; background: #222; color: #eee; }
  header input#token { flex: 0 1 12rem; }
  header span { color: #999; max-width: 18rem; overflow: hidden;
                text-overflow: ellipsis; white-space: nowrap; }
  #stage { flex: 1; display: flex; align-items: center; justify-content: center;
           overflow: hidden; background: #000; }
  #frame { max-width: 100%; max-height: 100%; object-fit: contain; display: none; }
  #notice { color: #888; padding: 24px; text-align: center; }
</style></head><body>
<header>
  <button id="back" title="Back">&#8592;</button>
  <button id="forward" title="Forward">&#8594;</button>
  <button id="reload" title="Reload">&#8635;</button>
  <input id="address" type="text" placeholder="Address" autocomplete="off" spellcheck="false">
  <button id="go">Go</button>
  <span id="status">disconnected</span>
  <input id="token" type="password" placeholder="Host token" autocomplete="off">
  <button id="connect">Connect</button>
</header>
<div id="stage">
  <img id="frame" alt="browser frame" draggable="false">
  <div id="notice">Paste the Host token and connect to watch this browser.</div>
</div>
<script>
const sessionID = ` + sessionIDJSON + `;const frame = document.getElementById('frame');
const stage = document.getElementById('stage');
const notice = document.getElementById('notice');
const status = document.getElementById('status');
const tokenField = document.getElementById('token');
const address = document.getElementById('address');
const navButtons = ['back', 'forward', 'reload'].map(id => document.getElementById(id));

// A native client puts the Host token in the fragment, the same convention the
// web client uses: a fragment is never sent to a server, so it can carry a
// bearer credential without appearing in a request line or a referrer.
const fragmentToken = new URLSearchParams(location.hash.replace(/^#/, '')).get('t');
if (fragmentToken) { tokenField.value = fragmentToken; }
else { tokenField.value = sessionStorage.getItem('warren-browser-token') || ''; }

let socket = null;
function setStatus(text) { status.textContent = text; }
function setNavEnabled(enabled) { navButtons.forEach(button => { button.disabled = !enabled; }); }
function showNotice(text) { notice.textContent = text; notice.style.display = 'block'; frame.style.display = 'none'; }
function hideNotice() { notice.style.display = 'none'; frame.style.display = 'block'; }
setNavEnabled(false);

// A viewer's stream is pushed, not requested: the Host sends frames for as long
// as the page is watched, so the page has to put the stream back after anything
// that ends it -- a daemon restart (which every app update performs), a window
// that was off screen, a laptop that slept. Without this the pane sat on "paste
// the Host token" forever, because a viewer that had lost its socket and one
// that had never been given a token looked exactly the same.
let reconnectTimer = null;
let reconnectAttempt = 0;
let connected = false;
const reconnectBaseMs = 500;
const reconnectMaxMs = 4000;
// The Host reaps a read that has been silent for five minutes, and a person
// watching a page sends nothing at all, so the page speaks up.
const keepaliveMs = 60000;
let keepaliveTimer = null;

function stopKeepalive() {
  if (keepaliveTimer) { clearInterval(keepaliveTimer); keepaliveTimer = null; }
}

function startKeepalive() {
  stopKeepalive();
  keepaliveTimer = setInterval(() => { write({t: 'ping'}); }, keepaliveMs);
}

// Half a second doubling to four: a blip comes back at once, and a Host that is
// restarting is picked up within a few seconds of being ready.
function scheduleReconnect() {
  if (reconnectTimer || !tokenField.value) { return; }
  const delay = Math.min(reconnectBaseMs * Math.pow(2, reconnectAttempt), reconnectMaxMs);
  reconnectAttempt++;
  setStatus('reconnecting in ' + Math.round(delay / 1000) + 's');
  reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, delay);
}

function connect() {
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  // The close of a socket this page is deliberately replacing is not a
  // disconnect to react to, and leaving the handler on would schedule one
  // reconnect per attempt.
  if (socket) { socket.onclose = null; socket.onerror = null; socket.close(); socket = null; }
  stopKeepalive();
  sessionStorage.setItem('warren-browser-token', tokenField.value);
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  socket = new WebSocket(scheme + '//' + location.host + '/v1/browser/stream?session=' + encodeURIComponent(sessionID));
  socket.binaryType = 'arraybuffer';
  // The auth envelope is the same one /v1/ws takes: the type field is "t", not
  // "type". Sending "type" decodes to an empty type on the Host and the stream
  // is rejected as unauthorized before a single frame is read.
  socket.onopen = () => {
    // A reconnected viewer is a fresh subscription, and the size and density it
    // reports are cheap to repeat and wrong to assume: the Host may have been
    // restarted since, and the pane may have been resized while it was away.
    appliedViewport = {width: 0, height: 0, scale: 0};
    socket.send(JSON.stringify({t: 'auth', token: tokenField.value}));
  };
  socket.onclose = () => {
    stopKeepalive();
    connected = false;
    setNavEnabled(false);
    setStatus('disconnected');
    // The last frame stays on screen: it is still the page the user was looking
    // at, and the notice is for a viewer that has never shown one.
    if (!frame.naturalWidth) {
      showNotice(tokenField.value
        ? 'Disconnected. Reconnecting to the browser...'
        : 'Paste the Host token and connect to watch this browser.');
    }
    scheduleReconnect();
  };
  socket.onerror = () => setStatus('error');
  socket.onmessage = (event) => {
    if (typeof event.data === 'string') {
      const message = JSON.parse(event.data);
      if (message.t === 'ready') {
        connected = true;
        reconnectAttempt = 0;
        startKeepalive();
        setStatus('connected'); hideNotice();
        setNavEnabled(true);
        // The page has to be the size of the box it is drawn in before the
        // first frame is read, or the first clicks are mapped through the
        // letterbox (see toViewport).
        sendViewport(true);
        // There is no read-only "where am I" action, and tabs.list answers it:
        // the address bar has to show the page the agent is already on.
        send({action: 'tabs.list'});
      }
      if (message.t === 'error') {
        setStatus(message.error);
        // A size the Host refused is retried on the next layout change rather
        // than remembered as applied.
        appliedViewport = {width: 0, height: 0, scale: 0};
        // Before the stream is up, an error is the Host refusing this viewer:
        // a token it does not accept, or a Session that is gone. Retrying
        // cannot fix either, so the page stops and hands it to the person, who
        // is the one holding the token field.
        if (!connected) {
          stopKeepalive();
          if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
          showNotice('Cannot watch this browser: ' + message.error);
        }
      }
      if (message.t === 'result' && message.result) {
        if (message.result.url) {
          setStatus(message.result.url);
          if (document.activeElement !== address) { address.value = message.result.url; }
        }
        const active = (message.result.tabs || []).find(tab => tab.active);
        if (active && document.activeElement !== address) { address.value = active.url || ''; }
      }
      return;
    }
    // The frame envelope is DENB: a fixed prefix, then a JSON header naming the
    // session and sequence, then the JPEG payload. The client trusts the Host's
    // session binding, so only the payload is needed to paint.
    const bytes = new Uint8Array(event.data);
    const headerLength = (bytes[7] << 24) | (bytes[8] << 16) | (bytes[9] << 8) | bytes[10];
    const payloadStart = 15 + headerLength;
    const jpeg = bytes.subarray(payloadStart);
    const previous = frame.src;
    const url = URL.createObjectURL(new Blob([jpeg], {type: 'image/jpeg'}));
    frame.onload = () => { if (previous.startsWith('blob:')) { URL.revokeObjectURL(previous); } };
    frame.src = url;
  };
}

// The browser page follows the box it is drawn in.
//
// The screencast is drawn at the page's own size and then fitted to the stage,
// so a page smaller than the box is both soft and letterboxed -- and every
// pointer coordinate has to be mapped through the margin. Sizing the page to
// the stage removes the margin: the frame is 1:1 with the box, and toViewport
// below degenerates to a translation.
//
// The stage's device pixel ratio goes with the size. It does not change the
// layout -- the Host lays the page out at the CSS size either way -- but it is
// how many pixels the Host should put in a still, which is the only frame that
// can be sharper than the display's own density allows the live stream to be.
//
// The send is debounced because a window drag emits a resize per frame, and
// every accepted size restarts the screencast on the Host.
let appliedViewport = {width: 0, height: 0, scale: 0};
let viewportTimer = null;
function sendViewport(immediate) {
  if (viewportTimer) { clearTimeout(viewportTimer); viewportTimer = null; }
  const apply = () => {
    const rect = stage.getBoundingClientRect();
    const width = Math.round(rect.width);
    const height = Math.round(rect.height);
    const scale = window.devicePixelRatio || 1;
    if (width <= 0 || height <= 0) { return; }
    if (width === appliedViewport.width && height === appliedViewport.height && scale === appliedViewport.scale) { return; }
    appliedViewport = {width: width, height: height, scale: scale};
    send({action: 'viewport', width: width, height: height, deviceScaleFactor: scale});
  };
  if (immediate) { apply(); return; }
  viewportTimer = setTimeout(apply, 120);
}
if (typeof ResizeObserver === 'function') {
  new ResizeObserver(() => sendViewport(false)).observe(stage);
}
window.addEventListener('resize', () => sendViewport(false));

// One writer for both shapes the stream takes: an action the Host performs, and
// the keepalive that only proves this viewer is still here.
function write(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) { return; }
  socket.send(JSON.stringify(message));
}
function send(action) { write({t: 'action', action}); }

document.getElementById('connect').addEventListener('click', connect);
// A native client passes its token in the fragment so the credential never
// reaches a server log; the page has everything it needs to connect itself.
// Making the user press Connect would leave the region on an empty stage, which
// is indistinguishable from a browser that failed to start. An empty token
// still waits for the field.
if (tokenField.value) { connect(); }
document.getElementById('go').addEventListener('click', () => {
  let url = address.value.trim();
  if (!url) { return; }
  if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) { url = 'https://' + url; }
  send({action: 'navigate', url});
});
address.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') { document.getElementById('go').click(); }
  // The address field owns these keys; the page must not forward them to the
  // browser as well.
  event.stopPropagation();
});
document.getElementById('back').addEventListener('click', () => send({action: 'back'}));
document.getElementById('forward').addEventListener('click', () => send({action: 'forward'}));
document.getElementById('reload').addEventListener('click', () => send({action: 'reload'}));

// Maps a pointer event to CSS pixels of the page the Host laid out.
//
// Two ratios stand between the pointer and the page. The image is letterboxed
// by object-fit: contain, so the pointer position is first scaled by the ratio
// actually drawn and offset by the letterbox margin. The image is also not
// necessarily the layout's own pixels: a still on a dense display carries
// deviceScaleFactor pixels per CSS pixel, and a frame delivered around a resize
// carries the count of the size the page had then. The layout size the Host was
// asked for is what converts image pixels back into the CSS pixels an action is
// expressed in.
//
// Returning null before the first frame means a click during startup is dropped
// rather than sent as (0, 0), which would hit whatever sits in the corner.
function toViewport(event) {
  const rect = frame.getBoundingClientRect();
  if (!frame.naturalWidth || !frame.naturalHeight) { return null; }
  const drawn = Math.min(rect.width / frame.naturalWidth, rect.height / frame.naturalHeight);
  const drawnWidth = frame.naturalWidth * drawn;
  const drawnHeight = frame.naturalHeight * drawn;
  // With no applied layout size there is nothing to convert against. 1:1 is
  // then the only guess left, and it is the right one for a 1x display.
  const cssPerImagePixel = appliedViewport.width > 0 ? appliedViewport.width / frame.naturalWidth : 1;
  const x = (event.clientX - rect.left - (rect.width - drawnWidth) / 2) / drawn * cssPerImagePixel;
  const y = (event.clientY - rect.top - (rect.height - drawnHeight) / 2) / drawn * cssPerImagePixel;
  return {x, y};
}

let hoverPending = null;
frame.addEventListener('pointermove', (event) => {
  const point = toViewport(event);
  if (!point) { return; }
  // A hover per pointermove would flood the action channel; the frame rate is
  // low enough that the last position is the only one worth sending.
  hoverPending = point;
  if (hoverPending.timer) { return; }
  hoverPending.timer = setTimeout(() => {
    hoverPending.timer = null;
    const pending = hoverPending;
    hoverPending = null;
    if (pending) { send({action: 'hover', x: pending.x, y: pending.y}); }
  }, 60);
});
frame.addEventListener('pointerdown', (event) => {
  const point = toViewport(event);
  if (!point) { return; }
  send({action: 'click', x: point.x, y: point.y});
  event.preventDefault();
});
// Wheel deltas are accumulated and flushed once per frame.
//
// A trackpad emits wheel events faster than the Host can apply them: one scroll
// action is a CDP round trip that waits for the compositor to commit the scroll,
// and the stream applies actions in order. One action per event therefore builds
// a queue that grows for as long as the user keeps scrolling, which is exactly
// what "it lags further behind the longer I scroll" means. Collapsing a burst
// into one action per frame bounds that queue to one in flight, and the wheel
// carries the pointer so the Host does not need a separate hover action.
let wheelPending = {x: 0, y: 0, dx: 0, dy: 0, has: false};
let wheelTimer = null;
function flushWheel() {
  wheelTimer = null;
  if (!wheelPending.has) { return; }
  const pending = wheelPending;
  wheelPending = {x: 0, y: 0, dx: 0, dy: 0, has: false};
  send({action: 'scroll', x: pending.x, y: pending.y, dx: pending.dx, dy: pending.dy});
}
frame.addEventListener('wheel', (event) => {
  const point = toViewport(event);
  if (!point) { return; }
  // The DOM deltas go through unchanged: a positive deltaY scrolls the page
  // down, and the Host's mouseWheel takes the same sign. Negating them (which
  // this page used to do) scrolls the embedded browser the wrong way under the
  // pointer.
  wheelPending.x = point.x;
  wheelPending.y = point.y;
  wheelPending.dx += event.deltaX;
  wheelPending.dy += event.deltaY;
  wheelPending.has = true;
  if (wheelTimer === null) { wheelTimer = setTimeout(flushWheel, 16); }
  event.preventDefault();
}, {passive: false});

// Keys are forwarded as press for the named keys and as type for printable
// characters, which is what lets Chrome compose IME and dead keys instead of
// receiving a synthetic char per keystroke (RFC 0022 §8.3).
const NAMED_KEYS = {
  Enter: 'Enter', Tab: 'Tab', Backspace: 'Backspace', Delete: 'Delete',
  Escape: 'Escape', ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight',
  ArrowUp: 'ArrowUp', ArrowDown: 'ArrowDown', Home: 'Home', End: 'End',
  PageUp: 'PageUp', PageDown: 'PageDown', ' ': 'Space'
};
window.addEventListener('keydown', (event) => {
  if (event.target === tokenField || event.target === address) { return; }
  if (event.metaKey || event.ctrlKey || event.altKey) { return; }
  const named = NAMED_KEYS[event.key];
  if (named) { send({action: 'press', key: named}); event.preventDefault(); return; }
  if (event.key.length === 1) {
    send({action: 'type', value: event.key});
    event.preventDefault();
  }
});
</script>
</body></html>`
}
