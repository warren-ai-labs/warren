# RFC 0022: Warren Browser — an embedded Chromium runtime with an agent action surface

- Status: Draft
- Owner: Warren Host (Headless), Warren Desktop, Warren CLI
- Created: 2026-09-20
- Scope: add a Host-owned browser runtime controlled over the existing protocol, a
  Desktop surface that renders it, and a normalized action API agents can call
- Protocol baseline: Warren protocol 4.0, plus one new binary frame kind and one
  new capability
- Depends on: [RFC 0020](0020-host-owned-pane-groups.md) (Host-owned pane leaves
  must name a running Session) and the Embedded Editor section of
  [DESIGN.md](../../DESIGN.md) §10.1

## 1. Summary

Warren has no browser. The Embedded Editor is the only non-terminal surface, and
it is deliberately a client integration with no Session, no PTY and no Host
resource ([GLOSSARY.md](../../GLOSSARY.md)). This RFC adds a browser that is the
opposite: a **Host-owned runtime** with a Session, a durable record, an action
API, and a client surface that renders it.

Four pieces:

1. **A managed Chromium runtime.** Warren launches Chrome with an isolated
   user-data directory per browser session, bound to a loopback debugging port,
   and drives it over the Chrome DevTools Protocol. The runtime belongs to the
   Host, so it survives client disconnect and app quit the way a Ghostline PTY
   does.
2. **A normalized action surface.** One method, `browser.action`, carries a
   closed set of browser-use-style actions. The surface is intentionally smaller
   than CDP: agents address a page, not a protocol.
3. **A Desktop surface.** A `WKWebView` loads a Warren-served viewer page that
   mirrors the live tab and forwards pointer and keyboard input back to it. The
   viewer is one web view, exactly like the Embedded Editor's.
4. **A CLI.** `warren browser …` gives any agent with a shell the same surface
   the Desktop has, including writing a screenshot to a file it can then read.

The screen becomes:

```text
┌ Warren sidebar ┬─ Terminal ───┬─ Browser viewer ─────────────┐
│ Projects       │ $ swift …    │ ← → ⟳  https://…             │
│ Workspaces     │ █            │ ┌──────────────────────────┐ │
│ Sessions       │              │ │  live screencast frame   │ │
│  · browser:app │              │ │  (CDP Page.startScreencast)│ │
└────────────────┴──────────────┴─└──────────────────────────┘─┘
                                └──── one WKWebView ───────────┘
```

## 2. Problem and goals

### 2.1 Problems

1. An agent working in a Warren Session cannot look at a web page. It can
   `curl` a URL, which is not the same thing: no JavaScript, no login state, no
   rendering, no interaction.
2. Self-verification is therefore limited to what a shell can assert. "Open the
   app, click Sign in, check the dashboard renders" is not expressible.
3. The human cannot see what the agent did. A screenshot in a transcript is a
   still image detached from the live page.
4. Superset answers this with an Electron `<webview>` and a main-process
   `BrowserManager`. Warren is Swift and Go, has no Electron runtime, and its
   only web-content host is a `WKWebView` pointed at a loopback process. The
   embedding strategy has to be Warren's, not a port.

### 2.2 Goals

- Give an agent a browser it can navigate, click, type into, scroll, screenshot,
  and read the DOM of, from any Warren client and from the CLI.
- Keep the browser Host-owned: a client disconnecting must not end it.
- Isolate browser state per session. A browser session's cookies, localStorage
  and cache must never be shared with another session, with the Embedded
  Editor's code-server, or with the user's system Chrome.
- Render the live browser inside Warren so the human watches the same page the
  agent is driving.
- Make the runtime optional. Warren with no Chrome installed must build, run,
  and report the browser as unavailable rather than failing to launch.
- Reuse the existing WebSocket control channel and the existing DENB binary
  stream. No second transport.

### 2.3 Non-goals

- **A Chromium fork, an embedded framework, or a bundled browser binary.** Warren
  launches the Chrome the user already has. §4.1 records why.
- **Replacing the Embedded Editor.** The editor is code-server and stays
  code-server.
- **A second browser engine.** There is no WKWebView-as-browser path. §4.2
  records the alternatives that were rejected and why.
- **Per-tab Sessions.** One browser Session owns one or more tabs; a tab is not a
  Warren Session (§5.2).
- **Cross-endpoint browsing.** A browser runtime is local to the Host that owns
  it, like the Embedded Editor.
- **Profile import from the user's system Chrome.** Isolation is the point.
- **A Set-of-Mark annotated screenshot pipeline.** The DOM snapshot (§6.3) is the
  primitive that would feed it; the annotation layer is deferred.

## 3. Resource model

A browser is a Warren Session with a new kind. This is the load-bearing decision
in the RFC and §4.2 defends it.

```text
Session (kind = "browser")
├── BrowserSession record  (Host-owned, durable)
│   ├── id            = Warren Session ID
│   ├── scope         = workspace | terminalGroup
│   ├── executable    = resolved Chrome path
│   ├── userDataDir   = ~/Library/Application Support/Warren/Browser/<id>/
│   ├── debuggingPort = loopback, random
│   └── tabs          = []BrowserTab
└── Chromium process   (runtime, adopted on Host relaunch)
```

Because it is a Session:

- It appears in `session list`, `roster`, and `roster.delta` with no new
  collection to keep in sync.
- It is scoped to a Workspace or Terminal Group, exactly like a shell.
- It has a lifecycle (`running` / `ended`) and the existing recovery path.
- `session.delete` ends it and the existing teardown applies.

Because it is *not* a terminal Session, three things must be true and are called
out in §7:

- It carries **no PTY**, so it never enters the DENB input/output stream for
  terminal bytes.
- It is **not** a PaneGroup leaf, for the RFC 0020 reason the Embedded Editor
  already cites: a pane leaf names a running Session *with a terminal*. The
  browser region is composed at the content boundary beside the Terminal, the
  way `WarrenDesktopCentralSplit` already composes the editor region.
- `TerminalSessionKind` gains `browser`, and every consumer that switches over
  the kind must handle it. §7.1 enumerates them.

## 4. Architecture decisions

### 4.1 Why a managed Chrome instead of a WKWebView browser

The obvious Warren-native move is to point a `WKWebView` at pages and call that
the browser. It was rejected for four reasons.

1. **Control would live in the client.** `WKWebView` is an AppKit object in the
   Warren.app process. The Host could not drive it, so `warren browser navigate`
   from a shell, or an agent on another Endpoint, would have to round-trip
   through whichever Desktop client happened to be open. That inverts the
   authority model in [DESIGN.md](../../DESIGN.md) §4: the Host owns resources.
2. **The page would die with the app.** The Embedded Editor already has this
   property and RFC 0021 §2.3 accepts it for an editor. For a browser an agent
   is mid-task in, losing the page because the user closed the window is a
   correctness problem, not a convenience problem.
3. **`WKWebView` is not Chrome.** Warren's own acceptance work runs against
   Chrome. A WebKit render can pass where Chrome fails and vice versa; an agent
   verifying its own work in a browser that is not the browser the user will use
   is verifying the wrong thing.
4. **There is no CDP.** Chrome DevTools Protocol is the interface every browser
   automation tool speaks. Choosing an engine with no CDP means writing and
   maintaining the automation layer by hand.

The cost of managed Chrome is a real one: Warren spawns and supervises a
Chromium process and speaks a WebSocket protocol to it. §8 records the
mitigations.

### 4.2 Why a Session kind rather than a client region

The Embedded Editor is a client region, and the cheapest version of this feature
would have been a second client region. That was rejected because it puts the
browser outside the resource model: no `session list` entry, no lifecycle, no
scope, no recovery, and — the decisive part — no way for the CLI or another
Endpoint to reach it. An agent-driven browser that only exists while a
particular window is open cannot be driven by that agent.

The Session-kind choice costs three compatibility edits (§7.1). Those are
enumerated rather than discovered, which is why they are acceptable.

### 4.3 Why screencast rather than a second navigation

The Desktop surface could navigate its own `WKWebView` to the same URL. That
produces two browsers with two cookie jars and two JS contexts, where the human
watches a page the agent is not touching. Rejected.

The viewer instead receives CDP `Page.startScreencast` frames and forwards input
as CDP `Input.dispatch*` events. One browser, one page, one cookie jar, and the
human and the agent are provably looking at the same thing.

### 4.4 Why a viewer page rather than a native renderer

The frames are JPEG and the input is pointer and key events. Two ways to render:

- **Native**: an `NSView` in Warren.app, AppKit event plumbing, a new
  `NSViewRepresentable`.
- **A Warren-served page in a `WKWebView`**: a canvas, a WebSocket to the Host,
  and DOM event listeners.

The page is chosen because it is the architecture the Embedded Editor already
uses, it is the same code the Web client can load, and it keeps Warren out of
the business of a frame renderer. It also means the Web/PWA client can show the
browser with no new native surface at all.

## 5. Runtime

### 5.1 Launch

```text
browser.session.create(scope, url?)
→ resolve the Chrome executable (§5.2)
→ allocate a loopback port and a user-data directory
→ launch Chrome with the arguments in §5.3
→ poll http://127.0.0.1:<port>/json/version until it answers
→ attach to the browser-level target
→ create or attach the first page target
→ persist the Session and the BrowserSession record
→ return api.BrowserSession
```

Chrome is launched detached in its own process group, the way the Embedded
Editor's code-server is, so it is not killed when the Host's process group gets a
signal.

The page target is attached once at launch, but it can die while the Chromium
that owns it keeps running: a crashed renderer, a tab closed from a visible
window, or a target Chrome tore down itself. `Target.detachedFromTarget` and
`Inspector.targetCrashed` are therefore both subscribed, and either one re-runs
the attach: adopt another live page if the browser still has one, otherwise open
a blank one, then restore the viewport and the screencast. When nothing can be
attached the Session fails and closes rather than staying `running`, because a
Session with no page is a viewer that is black forever and an action surface
that answers every call with `Session with given id not found`.

### 5.2 Executable resolution

Ordered, first match wins, mirroring
`WarrenEmbeddedEditorExecutableResolver` so the two resolvers read the same way:

1. `WARREN_BROWSER_PATH`
2. `WARREN_BROWSER_EXECUTABLE` (alias, accepted for symmetry with
   `WARREN_CODE_SERVER_PATH`)
3. `PATH` entries named `Google Chrome` (the macOS app bundle is not on `PATH`)
4. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
5. `/Applications/Chromium.app/Contents/MacOS/Chromium`
6. `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge`
7. `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`
8. `google-chrome`, `google-chrome-stable`, `chromium`, `chromium-browser` on
   `PATH` (Linux)

Resolution is attempted at create time and cached on the record. A failure is
reported as `phase = unavailable` with the search list in the error, never as a
silent empty browser.

### 5.3 Chromium arguments

```
--user-data-dir=<isolated dir>          # per Session
--remote-debugging-port=<random loopback>
--remote-debugging-address=127.0.0.1
--no-first-run --no-default-browser-check
--disable-sync --disable-background-networking
--disable-component-update
--disable-features=IsolateOrigins,site-per-process   # see §5.5
--window-size=<viewport width,height>
--headless=new                          # default; omitted only for --window
```

The page is drawn inside Warren from the Session's frame stream, so Chromium runs
with no window of its own by default. A visible window is the opt-in (`--window`,
`window: true` on the RPC) and exists for debugging the browser runtime: it puts
the page somewhere Warren does not render, and the Session's own viewer then
shows a second copy of it.

`--remote-allow-origins` is deliberately **not** set to `*`. Warren connects
from a Go process with no `Origin` header, which Chrome accepts by default; the
flag is only needed for browser-based debuggers and widening it would let any
web page in the browser drive the debugger.

### 5.4 Isolation

Each browser Session gets its own `--user-data-dir` under
`~/Library/Application Support/Warren/Browser/<session-id>/`. Cookies,
localStorage, IndexedDB, the cache, and installed extensions are therefore per
Session and shared with nothing — not the Embedded Editor's code-server profile,
not another browser Session, not the user's Chrome.

Superset's browser shares one Electron partition across every pane and the host
window. That is a reasonable choice for a single-user Electron app and a wrong
one here: Warren browser Sessions are scoped to different Workspaces and
different Tasks, and a login in one must not leak into another.

### 5.5 Site isolation and the screencast

Chrome's default site isolation puts cross-origin iframes in separate renderer
processes, which makes `Page.captureScreenshot` and `Page.startScreencast` fail
on the *outer* frame with "Unable to capture screenshot". Disabling
`IsolateOrigins` and `site-per-process` is what every screencast-based tool does.
The trade-off is a weaker security boundary for the pages Warren renders, and it
is accepted for two reasons: the browser Sessions are already isolated per
Workspace, and the pages an agent drives in a dev workflow are the user's own.

This is recorded here rather than buried in the argument list because it is the
one flag in §5.3 with a security consequence.

### 5.6 Lifecycle

| Event | Behavior |
| --- | --- |
| Client disconnects | Nothing. The Chromium process and its tabs stay. |
| Host relaunch | The record is read back and the debugging port is re-probed. A live process is adopted; a dead one is marked `ended` and never left `connecting`. |
| `session.delete` | Terminate the process group, remove the user-data directory, mark `ended`. |
| Idle | Reaped after `idleTimeoutSeconds` (900, matching the Embedded Editor), unless the Session is pinned. |

Adoption on relaunch reuses the persisted `debuggingPort`. Chrome writes its
`DevToolsActivePort` file into the user-data directory, so the port is
recoverable even if the record is stale; the record is preferred and the file is
the fallback.

## 6. Action surface

### 6.1 The action set

One RPC, `browser.action`, carries `{session, action}` where `action` is a
discriminated object. The set is closed: an unknown action is a protocol error,
not a passthrough.

| Action | Arguments | Returns |
| --- | --- | --- |
| `navigate` | `url`, `waitUntil?` | `{url, title}` |
| `back` / `forward` / `reload` | `hard?` for reload | `{url, title}` |
| `click` | `selector?`, `text?`, `x?`, `y?`, `button?`, `clickCount?` | `{}` |
| `type` | `text`, `selector?`, `clearFirst?`, `delay?` | `{}` |
| `press` | `key`, `selector?` | `{}` |
| `hover` | `selector?`, `x?`, `y?` | `{}` |
| `scroll` | `dx?`, `dy?`, `selector?` | `{}` |
| `select` | `selector`, `values: string[]` | `{}` |
| `wait` | `selector?`, `text?`, `timeoutMs?`, `state?` | `{}` |
| `screenshot` | `path?`, `fullPage?`, `format?`, `quality?` | `{path?, bytes, format, fullPage}` |
| `snapshot` | `interactiveOnly?`, `maxNodes?` | `{nodes: DomNode[]}` |
| `evaluate` | `expression` | `{value}` |
| `tabs.list` / `tabs.new` / `tabs.close` / `tabs.select` | `url?`, `tabId?` | `{tabs: BrowserTab[]}` |
| `viewport` | `width`, `height`, `deviceScaleFactor?` | `{}` |
| `cookies` | `action: get\|set\|clear` | `{cookies}` |
| `console` | `limit?`, `level?` | `{entries}` |

The selector resolution order for `click`, `type`, `hover` and `scroll` is
`selector`, then `text`, then coordinates — the same precedence Superset's
removed `desktop-mcp` used, because it is the precedence an agent actually
wants: address by identity when it knows it, by label when it does not, by
position when neither is stable.

### 6.2 Why not expose CDP directly

CDP has hundreds of methods, per-domain versioning, and session-id plumbing for
out-of-process iframes. Exposing it would make Warren's protocol a proxy for
someone else's, which is the thing [DESIGN.md](../../DESIGN.md) §4 assigns to
the Host. `evaluate` is the deliberate escape hatch: it covers the long tail
without widening the contract, and it is the same escape hatch Superset's
`evaluateJS` provides.

### 6.3 The DOM snapshot

`snapshot` returns a flattened node list rather than a nested tree:

```json
{
  "selector": "button.primary",
  "tag": "button",
  "text": "Sign in",
  "role": "button",
  "interactive": true,
  "enabled": true,
  "visible": true,
  "checked": null,
  "rect": {"x": 812, "y": 430, "width": 96, "height": 32}
}
```

Flattened because an agent consuming a tree has to re-flatten it to find
anything, and because the node count is what a caller needs to bound its own
context. `maxNodes` caps it and the response reports the total so a caller knows
it was truncated.

`snapshot` is computed by a script injected through `Runtime.evaluate`, not by
CDP's `Accessibility.getFullAXTree`. The CDP accessibility tree is the more
correct source and the worse one in practice: it is Chrome-version sensitive, it
prunes nodes an agent needs, and it is large. The injected walker is the same
approach Superset's `dom-inspector.ts` used and it is inspectable.

### 6.4 Verification as a first-class action

The user's stated goal is that the agent can do its own verification. Two
properties make that work rather than merely possible:

1. **`screenshot` can write to a path.** An agent that can only receive base64
   must spend context on an image. An agent that can write
   `/tmp/verify-login.png` and then `Read` it spends a tool call instead.
2. **`wait` and `snapshot` are composable.** `wait` for a selector, `snapshot`
   to confirm it, `screenshot` to record it. No new primitives needed.

The saved screenshot is PNG and the live stream is JPEG, deliberately. A frame
the viewer paints is bandwidth and is allowed to be lossy; a file an agent writes
and then reads back is evidence and is not. `format` selects otherwise, and
`quality` applies only to a lossy format.

## 7. Protocol changes

### 7.1 What has to change, enumerated

Adding a Session kind touches every consumer of `TerminalSessionKind`:

| Site | Change |
| --- | --- |
| `Packages/Domain/.../Models.swift` | add `browser` to the enum |
| `Packages/Desktop/.../WarrenDesktopSessionPreset.swift` | add a `browser` preset |
| `Web/src/session.js` | add `browser` to the provider/kind list |
| `Headless/internal/server/service.go` | **refuse** `kind = "browser"` on `session.create`, with an error naming `browser.session.create` |
| `Headless/internal/server/agent_provider.go` | refuse `agent create` with `kind = "browser"` (it is not an agent provider) |

The `session.create` row is a refusal rather than an acceptance, which is the one
place this RFC changed its own mind while implementing it. A browser Session has
no PTY and no Ghostline runtime, so the terminal creation path would record a
Session that can never start — a Session stuck in `running` with nothing behind
it. Accepting the kind there would make `session.create` the wrong door to a
resource whose lifecycle is `browser.session.create`, so it names the right one
instead.

### 7.2 New RPC methods

```
browser.session.create   {workspace?|group?, url?, headless?, viewport?}  → api.BrowserSession
browser.session.list     {workspace?|group?}                               → api.BrowserSession[]
browser.session.get      {id}                                              → api.BrowserSession
browser.session.close    {id}                                              → void
browser.action           {id, action}                                      → api.BrowserActionResult
browser.subscribe        {id, cols?, rows?}                                → {subscribed, attachmentId}
```

`browser.action` is the only method that does work. The rest are resource
lifecycle, matching how `session.*` is split.

### 7.3 New binary frame kind

Browser frames are JPEG screencast frames. They are **not** terminal output and
must never reach a VT parser, which is the same reason `atomicState` exists as
its own kind.

```
kind = 4   browserFrame
  header: {sessionID, epoch, sequence, format, payloadLength}
  format: "browser-frame-jpeg-v1"
  direction: hostToClient
```

This is a wire change to the DENB envelope. It is additive — kinds 1–3 keep their
values and their meaning — and it is the schema-declared way to add a binary
message. Bumping `binaryEnvelope.wireVersion` is **not** required and is
deliberately not done: that is the hard break, and this is not one.

Bindings that change, all of which `protocol:check` verifies:

- `protocol/warren.schema.json` — add the kind, the capability, the RPC examples
- `Headless/internal/protocol/wire.go` — regenerate with `protocol:gen`
- `Packages/Protocol/.../BinaryFrameKind.swift` — add `browserFrame = 4`
- `Web/src/wire.js` — add `KIND_BROWSER_FRAME = 4`
- `Headless/internal/protocol/drift/drift_test.go` — assert the new kind in all
  three bindings

### 7.4 New capability

`browser-v1`. A client that does not advertise it never receives browser frames
and never sees the browser surface. This is what keeps a pre-browser client
working against a post-browser Host.

### 7.5 HTTP routes

```
GET  /v1/browser/view?session=ID     → the viewer page (HTML)
GET  /v1/browser/stream?session=ID   → WebSocket: frames down, input up
```

The viewer page is served by the Host, not shipped in `Web/dist`, because it is
part of the browser runtime rather than part of the client bundle.

## 8. Desktop surface

### 8.1 Mounting

The browser region composes beside the Terminal in the central content area, the
way `WarrenDesktopCentralSplit` composes the editor region. It is not a
PaneGroup leaf (§3).

There is deliberately **no** control in the top-right chrome row. Selecting a
browser Tab opens the region and selecting anything else closes it, which is the
one way in: a browser is a Session like any other, so the user reaches it the way
they reach a shell. A chrome-row toggle would have been a second, redundant door
to the same resource, and it would have needed an exact-count update in
`WarrenDesktopWorkspaceTabTrailingControl`. Closing the region takes the viewer
off screen; the browser Session keeps running and stays reachable as an ordinary
Tab, exactly like a closed pane (RFC 0020).

The region is gated on the `browser-v1` capability of the selected Host rather
than on a probe. A Host with no Chrome resolves the runtime as `unavailable`
rather than failing to launch (§5.2), so the capability is the honest signal.

The region has a readability floor rather than a rendering floor: it scales a
live screencast, so it is the region that absorbs a narrow window — the opposite
priority to the editor region, whose floor is a hard limit because code-server
clips its Explorer below it.

### 8.2 The viewer

```swift
struct WarrenBrowserViewerHost: NSViewRepresentable {
    let sessionID: String
    let viewerURL: URL
    // makeNSView builds a WKWebView with an isolated WKWebsiteDataStore keyed
    // by session ID and loads viewerURL; updateNSView only reloads on identity
    // change. Same shape as WarrenEmbeddedEditorWebViewHost.
}
```

The viewer page owns the canvas, the WebSocket, and the input forwarding.
Warren.app owns nothing but the web view, which is the same division of labor
the Embedded Editor already has.

### 8.3 What the viewer forwards

Pointer events (down, up, move, wheel) and key events, normalized to viewport
coordinates and sent over the stream WebSocket. The Host translates them to
`Input.dispatchMouseEvent` and `Input.dispatchKeyEvent`.

Text input is the case that needs care: a synthetic `char` event per keystroke
loses IME and dead keys. The viewer therefore sends `keyDown`/`keyUp` with the
resolved `text` field, which is what CDP's `dispatchKeyEvent` uses for
`Input.insertText`-equivalent behavior, and lets Chrome compose.

### 8.4 Focus

RFC 0021 §3.2 left focus routing to Warren and derived it from a pointer
boundary monitor, because a click on a `WKWebView`'s content view never reaches
the web view subclass's `becomeFirstResponder`. The browser viewer reuses that
monitor rather than inventing a second one: `WarrenEmbeddedEditorPointerBoundary`
generalizes to "a region holds keyboard focus", and the editor is one instance of
it.

### 8.5 What the viewer page actually became

The viewer is not only a mirror. It carries an address bar, back/forward/reload,
and forwards pointer and key events as normalized `api.BrowserAction` objects —
the same action vocabulary the agent uses, sent over the same stream. So the user
and the agent drive one browser through one protocol, and there is no second
input path to keep in step.

Two details that cost real debugging:

- **Letterboxed coordinates.** The frame is `object-fit: contain`, so a pointer
  at canvas coordinates is not a pointer at viewport coordinates. Mapping
  through the letterbox is what makes a click land where the user aimed.
- **The token travels in the fragment.** The viewer reads `#t=...` from its own
  URL and puts it on its WebSocket. A fragment is never sent to a server, so the
  credential stays out of request lines, logs, and referrers.

And one measurement that decides how the view looks:

- **The screencast answers in CSS pixels; a still does not.**
  `Page.startScreencast` renders at the layout size whatever `deviceScaleFactor`
  and the caps ask for, so on a display denser than 1 the live picture is an
  upscaled, soft one, and no screencast setting changes that.
  `Page.captureScreenshot` does honour the device scale factor, which is why the
  Host retires the settled page with one still at the density the viewer reports
  in its `viewport` action. The two frame sources are two image scales, so the
  viewer converts image pixels to the layout size it asked for instead of
  assuming 1:1, and the wheel deltas reach the Host with the sign the page gave
  them — CDP and the DOM agree, and flipping them scrolls the embedded browser
  backwards.

## 8.6 The viewer puts its stream back

A viewer's stream belongs to the page, not to a request: the Host pushes frames
for as long as the page is watched, and anything that ends the stream — a daemon
restart, which every app update performs, a window that was off screen, a slept
laptop — used to leave the pane on "Paste the Host token and connect to watch
this browser", because a viewer that had lost its socket and one that had never
been given a token looked exactly the same. The page therefore reconnects on its
own: half a second doubling to four, resetting the attempt counter on `ready`.

Two details make that reconnect correct rather than merely present:

- **The viewport is re-asserted, not assumed.** A reconnected viewer is a fresh
  subscription, and the Host may have been restarted or the pane resized in the
  meantime, so the page forgets what it had applied and re-sends the size and
the display density.
- **A refusal is not retried.** An error before the stream is up is the Host
  declining this viewer — a token it does not accept, a Session that is gone —
  and retrying cannot fix either. The page stops and says what the Host said,
  leaving the token field with the person who can act on it.

A viewer also has to prove it is still there. The Host reaps a read that stays
silent for five minutes, which is exactly what a person watching a page produces,
so the page sends one `{"t":"ping"}` a minute. The Host's action decoder ignores
it, and the read deadline is deferred, which is the whole point.

## 9. CLI

```
warren browser list [--workspace ID | --group ID] [--search TEXT] [--limit N] [-q]
warren browser create [--workspace ID | --group GROUP_ID] [--url URL] [--title T] [--window] [--width N] [--height N]
warren browser get SESSION_ID
warren browser close SESSION_ID
warren browser action SESSION_ID ACTION [--flag value ...]
```

`browser action` takes the action name positionally and maps flags to the action
object, so `warren browser action S1 click --text "Sign in"` needs no JSON on the
command line. Every verb in §6.1 is reached through that one command rather than
through a subcommand per verb: `screenshot`, `snapshot`, `console`, and `tabs.list`
are actions, not resources.

Two parser details are load-bearing:

- `--text` is a bare boolean for the transcript readers, so `browser action`
  passes parseFlags its own value-flag set. Without it, `--text "Sign in"` sets
  `text=true` and the string lands in the positionals.
- Flag values are converted, not asserted. parseFlags hands a value-taking flag a
  string even when the caller wrote `--timeout 5000`, so a bad value is an error
  (`--timeout must be a number`) rather than a panic.

`screenshot --path FILE` is the verification path: the agent writes the file, then
reads it. With no `--path` the frame comes back inline as `result.data` base64,
which is the expensive path and is why `--path` exists. The path is a Host-side
filesystem path and is trusted — it is the agent's own artifact, and it is the
one place Warren writes a file an agent asked for by absolute path.

## 10. Testing and verification

### 10.1 Go

- **Manager lifecycle** with a stub executable that writes a `DevToolsActivePort`
  file and serves a canned `/json/version`: launch, adopt on relaunch, terminate,
  idle reap, unavailable when no executable resolves.
- **CDP client**: method/response correlation by id, event fan-out, timeout on a
  method that never answers, reconnect after the WebSocket drops.
- **Action schema**: every action in §6.1 validates; an unknown action is
  rejected; `click` with neither selector, text, nor coordinates is rejected.
- **Server RPC** against the existing in-process test harness: create, list,
  action, close, and the refusal of both `session.create` and `agent create` with
  `kind = "browser"`.
- **CLI flag mapping**: `--text` is a value and not a bare boolean, numbers arrive
  as strings and still convert, a boolean flag does not swallow the next flag, and
  an unusable value errors instead of panicking.
- **Drift**: `protocol:check` fails if the new kind is missing from any binding.

### 10.2 Swift

- `browser` decodes from a roster payload and round-trips.
- `BinaryFrameKind.browserFrame` has raw value 4 and `hostToClient` direction.
- The session preset catalog exposes `browser`.
- A Desktop test asserting the browser region composes beside the Terminal
  without tearing down the terminal surface.

### 10.3 Web

- `decodeFrame` dispatches a browser frame and rejects one with a bad format.
- `encodeInput` is unchanged (browser frames are host-to-client only).

### 10.4 Real-artifact verification

Unit tests do not prove a browser works. The acceptance path is:

1. `go test -race ./Headless/...` — the whole daemon suite.
2. `mise run protocol:check` — bindings match the schema.
3. `mise run verify` — the full gate, including the app build.
4. A live end-to-end run against real Chrome: create a session pointed at a
   local HTML fixture, `navigate`, `click`, `type`, `wait`, `snapshot`,
   `screenshot --path`, and assert the screenshot is a non-empty PNG and the
   snapshot contains the expected node. This runs against the real binary, not
   a stub, and its output is the artifact the reviewer reads.

The live run is a script, not a test, because it needs a display and Chrome and
CI has neither. It lives in `scripts/browser-smoke.sh`.

## 11. Risks

| Risk | Mitigation |
| --- | --- |
| Chrome is not installed | §5.2 resolution order + `unavailable` phase. The rest of Warren is unaffected. |
| Chrome's CDP surface changes | Only ~20 stable methods are used, all pre-1.0-stable domains (`Page`, `Runtime`, `Input`, `Target`, `Browser`). `evaluate` absorbs surprises. |
| Screencast bandwidth | JPEG quality is capped and the frame rate is throttled to what the viewer can paint. A client that does not subscribe receives nothing. |
| A new Session kind breaks a consumer | §7.1 enumerates them and §10.2 tests the ones that are testable. |
| Site isolation disabled (§5.5) | Recorded as a decision with its reason; per-Session isolation is the compensating control. |
| Chromium memory | One process per Session, reaped when idle, and `session.delete` removes the profile directory. |

## 12. Rollout

1. Schema, codegen, and the three bindings. Nothing user-visible.
2. The Go runtime and the CDP client, behind `browser-v1`.
3. The RPC surface and the CLI.
4. The Desktop region and the viewer page.
5. The Web client's browser region, which needs no new native surface.
6. `DESIGN.md` §9 and §10, `GLOSSARY.md`, and this RFC's status → Implemented.
