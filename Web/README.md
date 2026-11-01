# Warren Web

The responsive Web/PWA client uses React + Vite. React component source lives in `Web/src/`, and production build output is written to `Web/dist/`, which is embedded by both the Go daemon and the Go Relay Service.

## Development

```sh
npm --prefix Web install
mise run web:dev
```

The Vite dev server only serves frontend assets; React owns the UI component tree and client state, and xterm mounts onto the terminal node through a component ref. To connect to a local Warren WebSocket, keep using the daemon's 8789 port, or configure a temporary reverse proxy for Vite.

## Build and Verify

```sh
mise run web:build
mise run verify:web
```

Do not edit `Web/dist/` directly. It is Vite build output and is cleared and regenerated on every build.

Runtime parameters are injected through meta placeholders in `index.html`:

- `__WARREN_INJECTED_PARAMS__`: local Web host and token parameters.
- `__WARREN_RELAY_HOST_ID__`: Host ID injected when Relay renders a
  host-scoped Web page (the Host ID is allocated during Headless claim, not by
  this client).

SSH, the WebSocket protocol, and the Host resource model do not belong to the Vite project; they are maintained by the Go server side.

## Layout

The web client renders three layout tiers instead of compressing one desktop
layout onto phones:

- **Desktop (≥1024px)** — the Desktop app's Workbench: a black window with
  rounded cards on it. The sidebar card lists Projects, their worktrees and the
  Sessions in each on the Desktop's grid; beside it a header names the one
  Session this window holds, with its Terminal/Agent switch and one capsule of
  panels and "+", over the terminal's card. Colours and metrics come from
  `WarrenColorTokens.dark` and `WarrenDesktopSidebarMetrics`.
- **Compact (768–1023px)** — same desktop chrome, with the sidebar as an
  overlay drawer so the terminal keeps the width.
- **Mobile (<768px)** — an inbox of every Session (by status or by Project)
  that pushes a single-column Session view: a header naming the Session over
  its Project and branch, the agent Term/Chat toggle, a swipeable session pill
  strip, and a collapsible Ctrl key row. New sessions open from a bottom sheet, context
  menus render as bottom sheets, and the soft-keyboard inset applies to the
  main surface for both terminal and agent input.

## Installing on iPhone

Safari has no install prompt, so the client explains it itself: the Welcome
screen and a dismissible hint in a connected Safari tab point to Share › Add to
Home Screen. A Home Screen app keeps its own storage, separate from Safari, so
paste the Web link inside the installed app. Once installed, the app icon badge
shows how many Sessions are waiting on you (iOS 16.4+), and the service worker
opens the cached shell when the Host or the network is unreachable.
