# RFC 0001: Retain terminal surfaces across tab switches

- Status: Superseded by [RFC 0002](0002-one-way-desktop-rendering.md)
- Owner: Warren desktop client
- Created: 2026-08-15

This RFC is historical. Its `session.attach`/`session.detach` examples belong
to the pre-4.0 protocol and are not supported by the current contract; use
`session.subscribe`/`session.focus`/`session.unsubscribe` as documented by the
current architecture and RFC 0016.

## Motivation

Switching back to a previously visited tab replays buffered terminal output at
full speed. The host keeps a bounded output ring (default 256 frames,
`OutputRing.capacity`) and the renderer drains it through
`WarrenGhosttyOutputWriter` at a fixed budget (128 KB per 8 ms). Because the
desktop client destroys the Ghostty surface when the tab loses focus and
creates a fresh one on return, the entire retained ring tail is fed into the
new surface as fast as the writer allows. Users perceive this as an
accelerated fast-forward replay, even after a short tab switch.

This RFC proposes an opt-in setting that keeps one Ghostty surface per open
tab. Hidden surfaces stay subscribed to live output so they never fall behind,
making tab switches instant without replay.

## Current behavior

### Desktop render path

The desktop app always renders through the daemon:

- `WarrenCompositionRoot` uses `WarrenRemoteApplicationModel` for both
  Local and Server endpoints.
- `WarrenRemoteApplicationModel` mounts at most one surface:
  - `apply(_ roster:)` prunes `mountedSurfaces` to sessions that still have a
    live tab (`liveTabSessionIDs`).
  - `attachSelectedSession()` creates a new `GhosttySurface` for the selected
    session and attaches it.
- `feedOutput` only feeds the surface matching `selectedSessionID`; hidden
  tabs receive no output.
- On return, `session.attach` asks the daemon to replay the retained ring tail
  from the client's anchor. `WarrenGhosttyOutputWriter` drains it as fast as
  its 128 KB / 8 ms budget allows, which produces the visible fast-forward.

### Daemon limitation

`wsPeer` supports exactly one attached session:

- `wsPeer.attach(session)` calls `p.detach()` first, replacing the previous
  output subscription.
- Input and focus are bound to the single `p.attached` session via
  `requireControl()`.
- `session.detach` detaches everything.

The output subscription registry is already keyed by session
(`Service.peers[sessionID]`), so one peer can structurally appear in multiple
session maps. The single-attachment model is a protocol choice, not a data
structure limitation.

### View layer

`WarrenTerminalSurfaceView` already renders multiple surfaces in a ZStack
and keeps hidden siblings alive (`.opacity(0)` plus the underlying NSView
`isHidden`). The view layer is ready for retained surfaces.

## Goals

- Add a settings toggle (default off) that preserves current behavior when
  disabled.
- When enabled, keep one `GhosttySurface` per open tab across tab and
  workspace switches.
- Hidden surfaces stay subscribed to daemon output and render in the
  background, so switching back requires no replay.
- Only the active tab may send input, claim focus, or resize the runtime,
  preserving the existing control-lease semantics.
- Closed sessions detach and dispose their surface.

## Non-goals

- Replaying output at real-time speed. Retained surfaces avoid replay entirely;
  the existing catch-up behavior stays in place for reconnects and for users
  who disable the setting.
- Retaining surfaces across client restarts. A reconnect still rebuilds
  surfaces and reattaches from the persisted anchor.
- Changing the headless Web client behavior.

## Design

### 1. Preference

Add `terminalRetainSurfaces` (default `false`) to `WarrenPreferenceKey` in
`Packages/Domain/Sources/WarrenDomain/TerminalDisplayTitle.swift`.

Expose it in `WarrenDesktopSettingsView` as a Terminal section toggle:
"Keep terminal state when switching tabs", with a note that it uses more
memory. Include it in the "Restore Terminal Defaults" reset.

`WarrenCompositionRoot` reads the value with `@AppStorage` and calls
`WarrenRemoteApplicationModel.setSurfaceRetention(enabled:)` on change.

### 2. Daemon: multi-session output subscription per peer

This is the prerequisite for keeping hidden surfaces current.

- Add a per-peer set of output subscriptions (e.g.
  `subscribed map[string]*api.Session`).
- `session.attach` adds the session to the subscription set instead of
  detaching the previous subscription. The existing single control/focus
  target (`p.attached` / `controlSession`) remains for input, focus, and
  resize.
- `session.detach` accepts an optional session `id` to remove one
  subscription; without `id` it keeps the current behavior of detaching
  everything.
- `session.focus` operates on an explicitly identified session.
- `session.delete` removes the deleted session from every peer subscription
  set.
- Peer teardown (`closeLocked`, queue overflow, write failure) removes the
  peer from all subscribed sessions, not just one.

The existing `Service.peers[sessionID]` map already supports this; no
broadcast-path changes are expected.

### 3. Client: `WarrenRemoteApplicationModel`

- Replace the single `attachedSessionID` with a set of subscribed sessions
  (or keep `selectedAttachedSessionID` plus `subscribedSessionIDs`).
- `feedOutput` routes every frame to the mounted surface matching
  `frame.header.sessionID`; drop the `targetSessionID == selectedSessionID`
  guard. `outputAnchors` and `suppressFramedAnchorUpdates` are already keyed
  by session.
- Retention enabled:
  - `apply(_ roster:)` creates/keeps surfaces for every live tab and prunes
    only sessions whose tab/session disappeared.
  - Attach every retained session with `focused: false` and the shared
    viewport size (all surfaces share the same pane size).
  - Input, resize, and focus stay gated on the active tab.
- Retention disabled:
  - Preserve current single-surface behavior exactly.
- Toggling at runtime:
  - Off → on: mount and attach all live tabs.
  - On → off: dispose all surfaces except the active tab and detach the
    others.
- Reconnect: keep the current full reset; after reconnect, rebuild according
  to the toggle state.

### 4. View layer

No structural change needed. Verify that `GhosttyManagedSurface` still calls
`presentNow()` / display refresh when a retained surface becomes active.

## Edge cases and risks

- Hidden surfaces must keep the same viewport size as the active surface or
  the runtime receives wrong resize events. The current ZStack already enforces a
  shared frame; keep that invariant.
- Multi-session subscriptions increase per-peer outbound pressure. The
  existing "queue overflow disconnects only this peer" semantics remain, but
  teardown must clean up every subscription.
- Runtime toggle transitions must attach/detach in a consistent order so a
  tab never briefly falls back to replay or leaves an orphaned daemon
  subscription.
- Memory: each retained surface adds GPU texture, grid, and scrollback cost
  (rough estimate 10-50 MB per surface). Default off; measure after
  implementation.

## Verification

- Go server tests: one peer attaches two sessions and receives output for
  both; detaching one leaves the other intact; peer close removes all
  subscriptions.
- Swift unit tests: updated `WarrenRemoteTerminalProtocol` helpers; retention
  mode routes `feedOutput` to a non-active mounted surface.
- Manual check: with the toggle on, rapid tab switching shows no fast-forward;
  with the toggle off, behavior is unchanged.
- Memory profiling with Instruments to quantify per-surface cost.

## Implementation order

1. Daemon multi-session output subscriptions with tests.
2. Client retention logic in `WarrenRemoteApplicationModel`.
3. Settings UI and preference wiring.
