# Terminal Experience Progress

Status: implementation review complete; release-readiness verification in progress
Date: 2026-08-27
Branch: `feat/persistent-warm-runtime`
HEAD: `b0bd4d8 refactor: own the Ghostty embedding dependency`

This document is the working evidence record for the new terminal experience.
It describes the current checkout, including its uncommitted changes, and is
not a release note.

## Executive assessment

The core architecture and the main native macOS path are implemented:

- visited terminal sessions can remain warm, consume output in the background,
  and be promoted without replaying or clearing the visible grid;
- cold recovery has an atomic terminal-state boundary and a presentation gate;
- output, input, focus, and resize ownership are separated;
- Web and CLI clients use the protocol-2 recovery path, with ANSI replay where
  a native Ghostty snapshot is unavailable.

The branch is now in integration and release-closure work, not at the start of
the feature. Protocol 2 is an intentional hard cutover with an explicit
minimum-client error, Web subscription cleanup and payload limits are covered,
and deterministic multi-peer recovery tests are in place. Real GUI/device
acceptance and final branch/worktree review remain before calling it released.

## Intended user-visible behavior

1. A normal tab switch promotes an already-current native surface without
   attach, replay, snapshot, or clear.
2. Background sessions continue consuming output while their native surfaces
   are warm and hidden.
3. A cold recovery installs one atomic terminal state behind a presentation
   gate, then presents at the matching cursor boundary.
4. Only the focused session owns input, focus, and resize; passive viewers do
   not resize the shared PTY.

## Repository snapshot

- `main...HEAD`: re-check immediately before release; this checkout contains
  uncommitted work from the feature series.
- Working tree: feature implementation and verification changes span Headless,
  Protocol, Transport, GhosttyAdapter, the macOS model, Web, Onboarding, and
  documentation.
- The changes span Headless, Protocol, Transport, GhosttyAdapter, the macOS
  application model, Web, Onboarding, scripts, and terminal documentation.
- Recent commits form a coherent sequence around Ghostline-only runtime
  convergence, atomic recovery, presentation gating, attach races, and
  Ghostty embedding ownership.

## Evidence ledger

### Headless runtime and output transport

Implemented path:

- `Headless/cmd/warren-headless/main.go` selects Ghostline as the only runtime;
  the production tmux runtime and spool watcher are removed. A separate
  `--ghostline-serve` process owns PTYs so control-plane restarts do not
  terminate sessions. Settings reject an explicit removed `tmux` value.
- `Service.outputSession` owns a bounded `output.Ring` and one shared Ghostline
  cursor reader. `ensureOutput` adopts a persisted opaque cursor, obtains a
  checkpoint when the cursor is missing or invalid, and starts the reader.
  `recordCursorOutput` appends bytes before advancing and persisting the cursor,
  providing a bounded at-least-once recovery boundary after a daemon crash.
- `Service.peerOutputs` gives each subscribed peer/session its own cursor reader.
  `session.subscribe` can keep several sessions live on one WebSocket;
  `session.unsubscribe` removes only one. Legacy `session.attach` still swaps a
  single implicit subscription, while `output:false` swaps only the control
  lease.
- `prepareAttach` serializes per-session recovery, stops and joins the shared
  reader, then holds the broadcast lock. `reanchorAtomicOutput` captures one
  Ghostline native snapshot (`ghostty-vt-snapshot-v1`) or ANSI checkpoint
  (`ghostline-vt-replay-v1`), pairs it with the ring boundary, sends
  `attached -> atomic-state -> synced`, and starts the peer reader from the
  returned cursor before releasing the boundary.
- `broadcastFrame` skips peers with a direct recovery reader, preserving the
  snapshot/live ordering. Queue overflow closes only the affected peer and
  cleans every terminal subscription. Focus and resize remain a separate
  lease; passive subscribers cannot resize the shared PTY.

Evidence: `Headless/internal/server/service.go`,
`Headless/internal/server/http.go`, `Headless/internal/output/ring.go`, and
`Headless/internal/server/ghostline_cursor_test.go`.

Covered by tests:

- multiple subscriptions, independent output, unsubscribe isolation, passive
  resize protection, control-only attach, legacy single-subscription behavior,
  and cleanup on peer close;
- native atomic recovery ordering (resize before snapshot), ANSI fallback
  payloads, and a two-peer test preventing duplicate output around a snapshot
  captured while the runtime is producing bytes.

The deterministic `TestMultiplePeersKeepOrderedOutputAcrossRepeatedReanchors`
scenario exercises three peers, continuous output, repeated unsubscribe/
subscribe reanchors, one peer disconnect, monotonic anchors, exact snapshot
prefixes, and complete live tails. `TestUnsubscribeCancelsBlockedSubscriptionBeforeReturning`
also proves that a blocked recovery is cancellable and leaves no pending
subscription behind.

### Protocol and binary frames

Protocol 2 is implemented as a hard terminal recovery boundary:

- `api.Version` is `2.0`. WebSocket auth requires the exact version and at
  least one negotiated terminal-state format; missing or older clients receive
  an explicit error before roster data is exposed.
- The DENB envelope keeps output and input framing and adds `KindAtomicState`.
  Its header carries session, epoch, sequence, format, and payload length;
  decoders reject direction, length, and format errors.
- The preferred format is native Ghostty state, with
  `ghostline-vt-replay-v1` as the ANSI fallback. The Go CLI advertises ANSI and
  can consume either output or atomic-state frames.
- Host and Swift transport accept atomic states up to 64 MiB; ordinary output
  remains capped at 8 MiB. Desktop raises its WebSocket message limit to 128
  MiB.

Evidence: `Headless/internal/api/types.go`,
`Headless/internal/server/http.go`, `Headless/internal/output/wire.go`,
`Packages/Protocol`, and `Packages/Transport`.

Compatibility is intentionally not transparent: protocol 1 and clients that
do not advertise a state format are rejected. A coordinated rollout policy or
an explicit minimum-client requirement is the rollout policy: deployed
Desktop/Web/mobile clients must speak protocol 2 and negotiate at least one
terminal-state format. The server rejects older or incomplete handshakes
before exposing roster data.

### macOS Ghostty surface lifecycle

The native implementation contains the main persistent-warm experience:

 - `TerminalSurfaceRetentionPolicy` tracks `active`, `warm`, and `cold` residency
  with an LRU policy, a default maximum of 8 warm surfaces, and an estimated
  1 GiB warm-surface byte budget.
- `TerminalSurfaceManager` keeps one AppKit host, reparents the selected view,
  hides warm views without destroying their native Ghostty surface, guards
  transitions with generations, and cancels stale present/focus commands.
  Warm promotion now jumps to latest: the surface is kept current by a live
  background subscription while hidden, so entering reveals the current frame
  in one display tick (~16ms) without replaying the backlog visibly.
  Resize is debounced (50ms coalesce + 250ms hidden defer) so an actively
  outputting shell settles at the new width before reveal, avoiding 1-2s of
  missing background color blocks.
- Recovery is gated until the view is presentable, the native surface exists,
  and the native grid has a positive viewport. This prevents a snapshot from
  being consumed by a nil or zero-sized renderer.
- `WarrenGhosttyOutputWriter` drains live output off the main actor, tracks
  `(epoch, sequence)`, serializes snapshot installation with live writes, and
  drops stale in-flight slices. Native snapshots are restored directly into
  Ghostty; ANSI frames use the background VT drain. During a resize the writer
  continues buffering; promotion does not wait for the full backlog.
- Warm reattachment captures and compares a viewport anchor, resynchronizing
  only when the retained viewport moved (jump to bottom without animation;
  scrollback stays intact for upward scroll after the jump). Scrollback
  compression is disabled so retained history remains visible after
  reparenting; the configured scrollback limit still bounds logical history.
- Pending disposal avoids waiting for an output drain while tearing down a
  surface, removing the observed background-drain/teardown deadlock.

Evidence: `Packages/GhosttyAdapter/Sources/GhosttyAdapter/TerminalSurfaceManager.swift`,
`GhosttySurface.swift`, and `WarrenGhosttyOutputWriter.swift`.

The GhosttyAdapter suite now passes, including warm park/reattach, a single
host under rapid tab switching, the recovery gate, background drain ordering,
native snapshot restore, pinned viewport preservation, and viewport resync.
An earlier `testReattachPreservesPinnedViewport` failure was reproduced and is
now passing; it is not a current blocker.

Warm surfaces are not proactively created for every live tab. They are created
for visited sessions and retained subject to the manager's count and memory
budgets, which keeps startup and steady-state memory bounded.

### Desktop application model

`Sources/Warren/WarrenRemoteApplicationModel.swift` now has two explicit paths:

Cold session path:

1. Create or reuse the native surface and begin recovery.
2. Wait for the host, native Ghostty surface, and positive viewport to be ready.
3. Send `session.subscribe`, optionally claiming control only when this view
   actually owns focus in the key window.
4. Use `session.attach` with `output:false` to swap the control lease without
   replaying output.
5. Install the atomic state and end the presentation gate only at the matching
   `synced` marker.

Warm session path:

- `promoteRetainedSession` logs `tab_promote_local`, swaps the control lease,
  reparents/presents the retained surface with a jump to latest (no visible
  replay, no Zeno target chase). Background shells use the same path: their
  grid is kept current while hidden, so entering never fast-forwards; missing
  output while hidden is covered by the next snapshot rather than a visible
  stream.
- Output subscriptions remain per retained session, so background surfaces
  stay current. Resize is debounced (50ms) and promotion defers 250ms after
  resize; only the focused session may claim resize. This prevents color-block
  flicker on actively outputting shells.
- A failed control swap falls back to the cold path instead of leaving a blank
  or non-interactive pane.

Evidence: `Sources/Warren/WarrenRemoteApplicationModel.swift` and
`Tests/WarrenTests/WarrenRemoteModelTests.swift`.

### Web and onboarding clients

Web remains a single-xterm compatibility client rather than a native warm
surface client:

- It authenticates as protocol 2 and advertises only
  `ghostline-vt-replay-v1`.
- It accepts `KindAtomicState`, holds the payload opaque until `synced`, stages
  live frames at the same `(epoch, sequence)` boundary, writes the snapshot and
  staged tail in order, and releases a neutral overlay only after xterm has
  consumed and painted the state.
- Tab changes clear the one xterm instance and start a new `session.subscribe`;
  resize is debounced and focus-gated. This is a correct cold recovery path,
  not persistent native warm promotion.

Web now tracks one subscription generation, cancels the previous session
before switching, drops stale callbacks and frames, and clears recovery state
on reconnect/dispose/deletion. Ordinary output remains capped at 8 MiB while
atomic state uses the shared 64 MiB limit; Web's decoder and tests enforce the
same distinction. Passive subscriptions can explicitly reclaim focus after a
background handoff without changing runtime geometry until focus is granted.

`Onboarding/src/TerminalDemo.jsx` is a fake-host Ghostty WASM interaction demo,
not a real remote terminal client. Its copy now describes Ghostline-only
runtime and explicitly distinguishes the real Web client (xterm.js). Onboarding
unit tests and its production build pass after `npm ci` in the self-contained
`Onboarding/` package. The README records the Node.js 22+/npm prerequisite and
keeps `node_modules/` out of version control.

### Tests and verification

Passing checks recorded for this checkout:

- root Swift package: 73 tests;
- GhosttyAdapter: 34 tests;
- Protocol: 8 tests;
- Transport: 15 tests;
- StateStore: 24 tests;
- Web: 137 tests and Vite build;
- Onboarding: 3 tests;
- `go test ./Headless/...`;
- `go test -race -count=1 ./Headless/internal/server`;
- cloudflared fake-tunnel unit tests;
- `git diff --check`.

The Onboarding production build also passes after `npm ci`; no current
automated build failure is known. Full Go runs include an existing,
timing-sensitive temporary-directory rename test, so that case is rerun in
isolation when it reports a cleanup race.

## Review by release-readiness dimension

Business intrusiveness:

- The runtime is now Ghostline-only and protocol 2 is a hard cutover. This is
  an intentional product/runtime change; the documented minimum-client policy
  requires protocol 2 plus a negotiated terminal-state format.

Interaction impact:

- Native recovery stays covered until the atomic state is synced, while input
  can be queued and accepted as soon as the subscription is acknowledged.
- Warm promotion avoids a visible replay flash. Focus and resize are limited
  to the focused/key-window session.
- Real GUI acceptance is still missing for rapid tab switching, background
  output, cold recovery, window reattachment, resize races, and cross-client
  viewing.

Performance impact:

- Warm count and byte budgets bound native memory; output readers use bounded
  rings and per-peer queues.
- Snapshot installation bypasses the ANSI parser on native Ghostty and keeps
  live output off the main actor.
- Web subscription generations cancel stale recovery work before replacement;
  ordinary output and atomic-state payloads use the same 8 MiB/64 MiB limits
  as the Host and Swift transport. The remaining performance question is real
  GUI measurement under sustained output, not an outstanding protocol gap.

Out-of-the-box usability:

- The checked-in Swift, Go, Web, and Onboarding paths pass after documented
  lockfile installs (`npm ci` in each self-contained JavaScript package).

Functional coupling:

- Native Ghostty snapshot and ANSI replay are explicit negotiated formats.
  Desktop, Web, and CLI each choose a format they can render, and recovery is
  kept behind protocol boundaries rather than sharing renderer internals.
- The dual native/xterm paths are deliberate, but both must remain covered by
  protocol and end-to-end acceptance tests.

## Remaining work before calling this release-ready

1. Run real macOS GUI/device acceptance across the interaction matrix above:
   first cold entry, zero viewport, recovery resize, first input, warm
   promotion, and stale recovery after rapid tab switching.
2. Reconcile the dirty worktree and branch divergence before release review;
   this progress document records the feature checkout but does not decide
   which unrelated historical changes should be published.

## Current conclusion

The new terminal experience is substantially implemented and its native main
path is covered by focused tests. The work is best described as **core path
complete, integration and release closure pending**. Automated protocol,
Web-lifecycle, payload-limit, multi-peer, and Onboarding checks are closed;
real GUI acceptance and final dirty-branch review remain before a
release-ready claim.
