# Terminal Experience Progress

Status: implementation review complete; release readiness is not established
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
the feature. It cannot yet be called release-ready because protocol rollout is
a hard cutover, Web has two lifecycle/size gaps, GUI acceptance is incomplete,
and the checkout is dirty and behind `main`.

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

- `main...HEAD`: 10 commits only on `main`, 18 commits only on this branch.
- Working tree: 56 changed paths, including 54 modifications and 2 deletions.
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

Remaining Headless concern: there is no explicit stress test proving the full
global `epoch + sequence` invariant across several peers and repeated
reanchors. The implementation pauses the shared reader while taking the
snapshot and reads the ring boundary atomically, but this boundary still needs
that stress/consistency test before it is considered fully closed.

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
an explicit minimum-client requirement is still needed for deployed
Desktop/Web/mobile versions.

### macOS Ghostty surface lifecycle

The native implementation contains the main persistent-warm experience:

- `TerminalSurfaceRetentionPolicy` tracks `active`, `warm`, and `cold` residency
  with an LRU policy, a default maximum of 8 warm surfaces, and an estimated
  1 GiB warm-surface byte budget.
- `TerminalSurfaceManager` keeps one AppKit host, reparents the selected view,
  hides warm views without destroying their native Ghostty surface, guards
  transitions with generations, and cancels stale present/focus commands.
- Recovery is gated until the view is presentable, the native surface exists,
  and the native grid has a positive viewport. This prevents a snapshot from
  being consumed by a nil or zero-sized renderer.
- `WarrenGhosttyOutputWriter` drains live output off the main actor, tracks
  `(epoch, sequence)`, serializes snapshot installation with live writes, and
  drops stale in-flight slices. Native snapshots are restored directly into
  Ghostty; ANSI frames use the background VT drain.
- Warm reattachment captures and compares a viewport anchor, resynchronizing
  only when the retained viewport moved. Scrollback compression is disabled so
  retained history remains visible after reparenting; the configured scrollback
  limit still bounds logical history.
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
  reparents/presents the retained surface, and performs no replay, snapshot, or
  clear.
- Output subscriptions remain per retained session, so background surfaces
  stay current. Resize is debounced and only the focused session may claim it.
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

Two Web issues remain open:

1. The tab-change path starts a new `session.subscribe` but has no matching
   `session.unsubscribe` for the previous session. Headless permits one peer to
   subscribe to multiple sessions, so an old subscription may continue to
   consume output and eventually waste queue/reader resources. The next fix
   should explicitly unsubscribe before switching (or prove an equivalent
   lifecycle cleanup).
2. `Web/src/wire.js` still rejects payloads above 8 MiB, while a legal atomic
   state may be up to 64 MiB. An 8--64 MiB snapshot accepted by Host/Desktop can
   therefore be rejected by Web. No large-payload end-to-end test currently
   covers this mismatch.

`Onboarding/src/TerminalDemo.jsx` is a fake-host Ghostty WASM interaction demo,
not a real remote terminal client. Its copy now describes Ghostline-only
runtime and explicitly distinguishes the real Web client (xterm.js). Onboarding
unit tests pass; its production build is currently blocked because this
checkout has no installed `vite` package (`node_modules` is absent), which is
an environment/setup gap rather than a reported source compilation error.

### Tests and verification

Passing checks recorded for this checkout:

- root Swift package: 73 tests;
- GhosttyAdapter: 34 tests;
- Protocol: 7 tests;
- Transport: 14 tests;
- StateStore: 24 tests;
- Web: 135 tests and Vite build;
- Onboarding: 3 tests;
- `go test ./Headless/...`;
- `go test -race -count=1 ./Headless/internal/server` (passed in 56.488s);
- cloudflared fake-tunnel unit tests;
- `git diff --check`.

The Onboarding Vite build is the only recorded build failure, and it is due to
the missing local dependency described above. No current GhosttyAdapter test
failure is known.

## Review by release-readiness dimension

Business intrusiveness:

- The runtime is now Ghostline-only and protocol 2 is a hard cutover. This is
  an intentional product/runtime change, but it changes compatibility and
  requires a coordinated client/daemon rollout or a documented minimum-client
  version.

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
- Web stale subscriptions and the payload-limit mismatch are unresolved
  resource/latency risks; they need measurement after lifecycle cleanup.

Out-of-the-box usability:

- The checked-in Swift, Go, and Web test/build paths pass. A fresh Onboarding
  build still needs dependency installation, which is not currently encoded in
  this checkout's runnable state.

Functional coupling:

- Native Ghostty snapshot and ANSI replay are explicit negotiated formats.
  Desktop, Web, and CLI each choose a format they can render, and recovery is
  kept behind protocol boundaries rather than sharing renderer internals.
- The dual native/xterm paths are deliberate, but both must remain covered by
  protocol and end-to-end acceptance tests.

## Remaining work before calling this release-ready

1. Add a multi-peer, repeated-reanchor stress test for the global
   `epoch + sequence` invariant.
2. Fix or formally close Web unsubscribe lifecycle and align Web's atomic-state
   payload limit with the negotiated 64 MiB protocol limit (with large-payload
   tests).
3. Document and validate the protocol-2 rollout/minimum-client policy.
4. Run real macOS GUI acceptance across the interaction matrix above.
5. Make the Onboarding build prerequisite reproducible/documented, then rerun
   the production build.
6. Reconcile the dirty worktree and branch divergence before release review;
   this progress document intentionally does not stage or submit the unrelated
   feature changes.

## Current conclusion

The new terminal experience is substantially implemented and its native main
path is covered by focused tests. The work is best described as **core path
complete, integration and release closure pending**. The two concrete Web
resource/size gaps, hard protocol cutover, missing GUI acceptance, and dirty
branch state are the blockers to a release-ready claim.
