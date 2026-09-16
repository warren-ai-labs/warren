# Warren engineering lessons

High-value pitfalls and the architectural context around them, categorized and numbered in the order they were recorded. Each entry captures: symptom, root cause, what we learned, and the current state.

## Index & Categories

| ID | Title | Domain | Key Invariant |
| :--- | :--- | :--- | :--- |
| **001** | [tmux is a deprecated legacy runtime](#001---tmux-is-a-deprecated-legacy-runtime-and-why-ghostline-exists) | Terminal Runtime | Ghostline with server-side libghostty-vt is the single authoritative PTY runtime. |
| **002** | [Ghostty open-url fallback flooded os_log](#002---ghostty-open-url-fallback-flooded-os_log-and-pegged-a-core) | Native Integration | Embedders must handle open-url explicitly; never fall back to unbounded unhandled spawning. |
| **003** | [Black terminal pane on empty workspace transition](#003---black-terminal-pane-after-empty-workspace---populated-workspace) | UI Lifecycle | Keep expensive render surfaces mounted across transient UI state transitions. |
| **004** | [Idle output observers consumed interactive-path CPU](#004---idle-output-observers-consumed-interactive-path-cpu) | Resource Scaling | Observer costs must scale with active mutations, not total retained session count. |
| **005** | [Warm TUI reattach viewport size divergence](#005---warm-tui-reattach-can-leave-the-viewport-misaligned-until-a-second-switch) | Viewport Geometry | Surface display size must reconcile on every reattach, decoupled from input focus. |

> [!NOTE]
> Detailed historical single-issue postmortems are archived in [docs/archive/problems/](archive/problems/).

## 001 - tmux is a deprecated legacy runtime (and why ghostline exists)

### Historical symptom

With the tmux runtime, agent TUIs (Codex, Claude Code, etc.) show misaligned
background-color blocks on soft-wrapped colored history. A tab switch or
attach replays the full tmux history and the color blocks no longer line up
with the text.

### Root cause

tmux is a middle layer that re-parses program output and emits its own
rendering sequence. Warren captures that rendering (`capture-pane`) and
replays it into Ghostty. Replaying a full snapshot can break background color
blocks on soft-wrapped history because of Ghostty's BCE (background color
erase) handling - upstream issues
[ghostty#12497](https://github.com/ghostty-org/ghostty/issues/12497) and
[ghostty#12505](https://github.com/ghostty-org/ghostty/issues/12505).

Two adjacent traps made it worse:

- Hidden AppKit terminal views report their intrinsic 50x17 grid to tmux
  unless every mounted renderer is forced to the same pane-sized viewport;
  otherwise switching tabs visibly reflows the agent before it expands again.
- An invalid font size/typography preference can make Ghostty or the web
  terminal construct an unusable grid, so preferences are clamped at the
  boundary.

### The struggle (from git log)

The color-block problem is exactly what pushed Warren away from tmux:

- `e333fb1` / `e5f902b`: use ghostline for the PTY runtime (ghostline became
  the default).
- `ccec0ba`: render PTY snapshots with libghostty-vt instead of tmux capture.
- `fc13cfb`: restore colors and avoid black screen on PTY reattach.
- `f505ef8`: preserve the TUI cursor in ghostline snapshots.
- ghostline `10825d0`: resize the emulator before the PTY so redraws are not
  parsed at the old size; `7a6f71b`: restore cursor and terminal modes in VT
  snapshots.
- `d6b3f5e` / `d0f21b2`: keep tmux as a supported alternative runtime with
  ghostline/tmux coexistence.
- `fde9aea` / `e906e57`: document the BCE limitation and its live-scroll
  caveats.

### Current state

ghostline is the only active runtime target: the server owns the PTY and
emulates it server-side with libghostty-vt, so the client parses the original
PTY bytes once instead of tmux's re-rendered output. tmux is deprecated and is
kept only for existing legacy sessions; no new rendering work, bug fixes, or
experience guarantees are planned for it. All current and future terminal UX
work belongs in ghostline's checkpoint, output cursor, resize, and surface
presentation paths.

## 002 - Ghostty open-url fallback flooded os_log and pegged a core

### Symptom

The fan spins up and Warren.app holds one thread at ~90-97% CPU for 20+
minutes. `logd` sits at 60%+ CPU. The unified log contains 3,965,343 copies
of one message in under two seconds:

```
[com.mitchellh.ghostty:os-open] os-open: open stderr=
```

After the burst, the firehose starts throttling and drops messages, but the
thread keeps burning CPU on formatting and retry waits.

### Root cause

One click on a file path rendered by an agent TUI
(`/Headless/internal/server/ghostline.go`):

1. Ghostty detects the link and calls `Surface.processLinks` -> `openUrl`
   (`src/Surface.zig`).
2. The previous embedded apprt did not consume the action:
   its C action callback always returns `false`, so Ghostty believes the
   embedder did not handle it.
3. Ghostty falls back to `internal_os.open` and spawns `/usr/bin/open`, then
   `openThread` reads stderr and logs every line
   (`src/os/open.zig`, `open stderr=`).
4. That one runaway `open` produced millions of stderr lines. Release builds
   keep info logging enabled, and the macOS os_log backend formats every
   message, so the thread saturates a core and logd.

What it was NOT: page-capacity expansion logs. Measured with libghostty-vt on
the same core: a real 5MB Codex stream produces 0 capacity logs; crafted
style/hyperlink stress streams produce ~53-530 per pass; only a zero-width
character flood reaches 210k logs per 400KB (a different message).

### Fix

Warren owns the open semantics instead of letting Ghostty fall back:

- Implement the terminal open-url handler: only non-empty URLs with a known
  scheme (`http`, `https`, `mailto`, `tel`, `file`) or existing absolute
  paths are opened, via `NSWorkspace`; missing paths and empty targets are
  silently ignored.
- Make Warren's maintained Ghostty embedding callback return `true` when the
  embedder installed an open-url handler, so Ghostty never spawns
  `/usr/bin/open`.

### Debugging notes

- `ps -M` shows one thread with ~90% CPU and ~12 minutes of user time while
  every other thread is idle.
- `sample` pins the hot thread inside `zig_os_log_with_type` ->
  `_os_log_impl_flatten_and_send`, with the
  `__FIREHOSE_CLIENT_THROTTLED_DUE_TO_HEAVY_LOGGING__` marker.
- Use `/usr/bin/log show ... --predicate 'process == "Warren"'`; plain `log`
  in zsh is the math builtin and fails with "too many arguments".

## 003 - Black terminal pane after empty workspace -> populated workspace

### Symptom

Switching from a workspace with no tabs to a workspace with tabs leaves the
desktop terminal pane black or blank (sometimes only the TUI status bar is
visible). A resize, tab switch, or new output recovers it.

The daemon side is healthy: the output spool contains the full history and a
fresh snapshot contains all content. The problem is entirely on the desktop
client.

### Root cause

The failure is structural, not a rendering timing bug:

1. `WarrenDesktopWorkspaceContent` only mounted the terminal pane while
   `tab != nil`. During a workspace switch the roster can temporarily publish
   the new workspace before its tabs, so `tab` flips to `nil`, the PaneView is
   replaced by the empty-workspace view, and the terminal `NSView` is
   destroyed. When the tab arrives a new view is created — and diagnostics
   showed this happening several times in under a second
   (`terminal_view_appear` repeatedly fired).
2. Each `AppTerminalView` owns its own `TerminalSurfaceCoordinator` and native
   Ghostty surface, while `TerminalViewState.surface` is shared. A stale view
   deinit after a newer surface had already been installed called
   `terminalDidDetachSurface()` unconditionally, clearing the shared
   `surface` to `nil`.
3. Once `state.surface == nil`, every later `presentNow()` returns `false`.
   Delayed presents cannot help: there is no surface to draw.

Earlier "present later" fixes were red herrings. The diagnostics that mattered
were `surfaceReady` on `probe_apply_hidden` / `managed_present_delayed`:
`surfaceReady` was `true` right after the snapshot, then `false` half a second
later.

### Fixes

- Keep the terminal surface mounted across transient nil tabs. A workspace
  with a value always renders the PaneView; when no tab exists yet, a
  placeholder tab keeps the view alive and the empty-state panel is drawn as
  an overlay (`dd22463`, `4f77b2d`).
- Make stale teardown identity-aware: `TerminalSurfaceCoordinator` only calls
  `terminalDidDetachSurface()` when the surface being torn down is still the
  one published on `TerminalViewState` (`9313d12`). The check is a plain
  property read before the existing `surface.free()`; it adds no Ghostty calls
  and does not reintroduce the AppKit view-lock inversion fixed by `72fb1ee`.
- Add lifecycle probes so the next occurrence is diagnosable from logs:
  `workspace_switch`, `terminal_view_appear`, `managed_active_change`,
  `probe_window_available`, `probe_apply_hidden` with `surfaceReady`, and
  `probe_surface_rebuild` (`6f8e249`).
- Supporting fixes from the same investigation: defer color-scheme
  publication out of SwiftUI view updates (`2cc0348`), present the first
  attach snapshot only after the output writer has consumed it (`05b01bb`),
  and add later settle presents for freshly recreated views (`af12ff3`).

### Engineering lessons

- **Log before guessing.** The first few theories (spool cap, ghostline
  snapshot, delayed present timing) were all wrong. The decisive evidence was
  `surfaceReady` flipping from `true` to `false` after the snapshot.
- **"Refresh fixes it" is a fork in the road.** It can mean a stale
  framebuffer (needs one more present) or a missing surface (needs a rebuild,
  or better, no teardown). Check which one the logs report before adding more
  presents.
- **Component harnesses can pass without reproducing the bug.** The first
  remove-and-readd harness passed even with the fix removed because it did not
  model the transient nil tab that actually destroys the view. A red-green
  test must reproduce the real state transition, not just the happy path.
- **Shared resources need identity-aware teardown.** When multiple views can
  share one logical resource, a stale owner's deinit must not clear a newer
  owner's reference. Compare identity before mutating shared state.
- **Keep expensive render surfaces mounted across structural UI transitions.**
  Destroying and recreating `NSView`s on transient state changes turns a
  one-frame glitch into a lifecycle race.
- **Deferred work still needs ordering.** Moving Ghostty lifecycle off the
  AppKit view lock fixes lock inversion, but async rebuilds from multiple view
  generations can still tear down each other's surfaces. Both the deferral and
  the ownership guard are required.
- **Prefer probes in the product over asking users to reproduce.** Once the
  app logs `surfaceReady` and lifecycle events at the right points, one
  manual workspace switch gives enough data to trace the whole sequence.
## 004 - Idle output observers consumed interactive-path CPU

### Symptom

Terminal creation slowed down as the number of running Sessions grew, while
the Headless process remained near one saturated CPU core even when most
Sessions were idle.

### Root cause

Every Session had a spool watcher that called `file.Stat()` every 10 ms. This
made idle cost proportional to Session count: 69 running Sessions produced
about 6,900 metadata syscalls per second before any output encoding or
broadcast work. Roster refresh separately repeated runtime probes per observer,
adding more work to the same process during create.

### Resolution boundary

- Warren roster projection is cache-only; liveness probing stays in the single
  lifecycle loop.
- Session creation records phase durations so a future slowdown can distinguish
  runtime launch, persistence, output adoption, agent discovery, roster, and
  attach.
- Event-driven Ghostline watching remains isolated from `main` while its output
  cadence and callback semantics are reviewed independently.

### Engineering lesson

Observer cost must scale with changes, not with retained object count. A cheap
syscall becomes a process-wide bottleneck when multiplied by hundreds of idle
resources and an interactive polling frequency. Put reusable change detection
in the owning library; keep product policy and diagnostics in the product.
## 005 - Warm TUI reattach can leave the viewport misaligned until a second switch

### Symptom

A pi (or any full-screen/diff-rendering TUI) tab occasionally shows content
that is present but visually misarranged — characters appear reordered or
duplicated across rows. The pane does not repair itself; switching away and
back restores it. Reported on the desktop app while rapidly switching between
workspaces/tabs, no repro on demand so far.

### Working hypothesis (not yet confirmed with a repro)

`TerminalSurfaceManager` keeps a demoted surface warm: its Ghostty native
surface stays alive and hidden output keeps draining. When the surface is
reattached, `attach()` calls `view.fitToSize()` and then installs the current
daemon snapshot. The TUI client (pi) renders with its own idea of the
terminal width, and only re-lays-out on a SIGWINCH/full redraw:

- `WarrenRemoteApplicationModel.resize(_:)` guards on
  `selectedSessionID == sessionID && attachedSessionID == sessionID`
  (`Sources/Warren/WarrenRemoteApplicationModel.swift:3430`). During the
  attach window `attachedSessionID` is nil until `attach_complete`, and a warm
  (non-selected) session's resize is dropped entirely.
- `ownsTerminalFocus` requires a key window whose first responder is the
  terminal view, so an attach that lands while the window is not key (click on
  the tab bar, switching apps, etc.) does not claim control and does not
  forward the measured size to the daemon (`seedSessionSubscription` passes
  `size: nil`).
- If Ghostty's pixel/grid size changed while the TUI was warm (window drag,
  zoom, split) and the new size never reaches the PTY, the TUI keeps emitting
  rows for the old width while Ghostty wraps them at the new width — rows
  visually reorder/duplicate. The diff renderer believes the screen matches
  its `previousLines`, so it never full-redraws on its own.

`docs/lessons.md` 001 has a related earlier instance of TUI misalignment
(tmux color blocks on soft-wrapped history); this one is about the client
view/PTY size agreement after warm reattach rather than history replay.

### Status

- **Open — not yet reproduced on demand.** Diagnostics added in
  `Headless/internal/server/http.go` (`subscribe: step`) and the join bounds
  in `service.go` (`stopCursorOutputWithin`) help rule out a subscribe stall
  as the trigger; the misalignment itself is a rendering/size agreement issue,
  not a stall.
- Candidate fix (deferred until repro): after `attach_complete`, forward the
  surface's measured size to the daemon with `session.resize` even when the
  view is not focused. The daemon already no-ops identical sizes
  (`resizeRuntime` returns early when `runtimeSizes[session] == size`), so
  unfocused reattaches with an unchanged size cause no SIGWINCH and no TUI
  churn; a changed size gets the one WINCH that re-aligns the diff renderer.

### Engineering lesson

A retained warm surface can diverge from the PTY's idea of size when resize
ownership is coupled to focus and attach state. Size is display state that
must be reconciled on every reattach, independent of input focus; focus should
decide who may resize, not whether the size is known.

## 006 - Promotion can end in a permanently black pane, and the default grid resizes the PTY

### Symptom

Two symptoms survived the "promote every retained surface" change
(`187fc495`, `8bc2b736`), reproduced by switching back and forth between tabs:

1. A pane sometimes comes back black and stays black. Switching away and back
   does not repair it; only a later, unrelated reconciliation does.
2. A pane shows a history replay right after being attached: the running
   program reflows at the wrong width and then back.

### Root causes

**Black pane.** `demote()` deliberately removes the AppKit view from its host
and keeps only the native surface warm. Re-mounting that view happens in
`reconcile -> attach`; nothing else adds it back. A promotion whose view is
parked therefore depends on a reconciliation, and when the promotion does not
change the requested active set no SwiftUI layout update arrives, so no
reconciliation is scheduled. `schedulePresent`'s task then exits on its
`isCurrent` check (`entry.view.superview === host`,
`entry.transitionGeneration == transitionGeneration`) before drawing, and
`requestPresent` had already returned. The pane is black with no pending work.

The log told the whole story once the branch was identified: session
`c165582b` was demoted at 13:43:46, then promoted at 13:44:06, 13:44:09, and
13:44:12 with **zero** `present_complete` and **zero** `attach_start`, while a
sibling demoted at the same time presented 28 ms after its own promotion.

The first attempt at a client-side fallback (`8bc2b736` follow-up) could never
have worked, for two independent reasons:

- It treated `surfaceManager.isPresentable` as "has drawn". That predicate
  describes AppKit view visibility, not whether `presentNow()` ever ran, so it
  reported success for an undrawn pane.
- Its fallback called `attachSelectedSession()`, whose guard requires
  `selectedSessionID != sessionID || attachedSessionID != sessionID`. A
  promotion sets both to the promoted Session, so the call returned
  immediately and never re-attached anything.

**History replay.** Every Ghostty surface is created at a default size
(640x480) and reports that grid (50x17 here) before the view drives a real
size. The report reaches the client asynchronously through
`onResize -> Task { @MainActor }`, so by the time it is delivered the view
already matches its host; a gate that only checks the view geometry
(`isLaidOutToPane`) accepts it. The stale grid then reaches the PTY through the
passive resize path, which is active for the selected pane while its focus
claim is still confirming (`focusedSessionID != sessionID`), so the program
reflows at 50 columns and the pane looks like it replays history. The correct
size had already been sent by the attach/focus path, so this was a purely
spurious correction.

### Fixes

- `requestPresent` treats "the retained view is not attached to its host" (or a
  stale `transitionGeneration`) as a signal to `scheduleReconciliation`, the
  same path a cold attach uses, and logs `present_request_reattach`. This is
  the smallest causal fix: the promotion re-mounts the view instead of
  scheduling a present that cannot run.
- A bounded presentation watchdog (`present_watchdog_retry`, max 5 consecutive
  retries) reconciles when a hidden promotion has not drawn after 2.5 s (longer than the presentation task's own 2 s output-stall deadline), so any
  future dead end of the same shape self-heals instead of staying black.
- `acceptsReportedGrid` replaces the geometry-only gate: it derives the grid
  the current view geometry implies from the surface's cell metrics and
  rejects a report that does not match. Cell size is fixed per font, so a
  mismatch means the report was produced for a different viewport.

### Engineering lessons

- **View visibility is not presentation.** "The view is on screen" and "we
  drew the current output" are different states. A readiness check must
  observe the thing it claims to observe; here, an actual `presentNow()`, not
  `terminalViewIsPresentable`.
- **A fallback must be able to act.** Reusing `attachSelectedSession()` looked
  natural but its guard exists to make repeated attach requests idempotent, and
  a promotion has already satisfied those preconditions. Check what the
  recovery call actually does for the state you are in before relying on it.
- **Parked + active is a real state.** A surface can keep its residency while
  its view is detached. Any path that assumes promotion implies a layout
  update is wrong; re-mounting must be explicit.
- **Validate asynchronous reports against current geometry, not arrival-time
  geometry.** A resize captured before layout and delivered after it cannot be
  rejected by comparing the view to its host; compare the value to what the
  current geometry implies.
- **Bound watches.** A retry loop that can re-trigger itself needs a streak
  counter, or an unrecoverable surface reconciles forever.

## 007 - Ghostty applies config changes on its I/O thread, not on the caller's

### Symptom

`GhosttyAdapterTests.testNativeSnapshotRestoreReplacesViewportAndContinuesAtCursor`
failed roughly one run in three, on every machine and every branch, with
`rgb:0000/0000/0000` where Warren's configured `rgb:eaea/e8e8/e6e6` /
`rgb:1515/1111/1010` was expected. Both replies have the same byte length, so
the test's "wait until N bytes" loop exited on the first (stale) reply and the
equality assertion caught it.

### Root cause

The test asserted a guarantee the native layer does not provide.

- `ghostty_surface_update_config` does not apply colors inline. `Surface.updateConfig`
  builds a `Termio.DerivedConfig` and hands it to the I/O thread with
  `queueIo(.change_config, ...)`.
- `ghostty_surface_write_buffer` processes its bytes **synchronously on the
  calling thread** (`Termio.processOutput`), which is where the OSC 10/11 query
  is answered from `terminal.colors`.

So after `restoreSnapshot` returns, the terminal is replaced but the re-applied
colors may still be queued. Whether the I/O thread drains that mailbox before
the caller writes the next query is a scheduling coin flip, which is exactly
the ~50% failure rate. The product is fine: the window is a few milliseconds
and the renderer gets its own config message, so no wrong frame is painted; only
a program querying colors in that same instant can see the pre-restore values.

### Fix

`restoreSnapshotAndReapplyRuntimeConfig` keeps re-applying the config (that part
was already right). The test now re-queries until the configured colors land and
fails only if the deadline expires, which still catches a reapply that never
happens.

### Engineering lesson

- **Know which native mutations are synchronous.** Writing output and reading a
  terminal property from the same thread is synchronous; changing the config is
  a mailbox hop. A single sample after a config change encodes an ordering the
  layer never promised.
- **A flaky assertion can be a wrong assertion.** The fix was not a longer
  sleep or a retry of the whole test, but asserting the property the system
  actually guarantees (eventual reapply) instead of same-tick consistency.
- **Same-length responses hide the failure.** Waiting on byte count let the
  stale reply satisfy the loop; compare content, not length.

## 008 - A promotion can stall with no diagnostic at all

### Symptom

A pane came back black and stayed black for about two minutes. The log showed
the new recovery paths working and then stopping short:

```
15:56:17.529 tab_promote              193356e6
15:56:17.529 present_request_reattach attached=false gen 18/24
15:56:20.058 present_watchdog_retry   streak 1
15:56:20.088 terminal_focus_claim     trigger=presentDeferred   <- attach ran
15:56:22.607 present_watchdog_retry   streak 2
...streak 5, then the watchdog stopped...
15:58:16.596 recovery_anchor          reanchor=true            <- daemon re-anchor healed it
```

Six promotions and five watchdog retries over two minutes, and not one
`present_complete`.

### Root cause

The presentation task was alive and looping, but every gate between
`schedulePresent` and `presentNow()` is silent, so nothing recorded why:

- `isCurrent` failure only bumps `staleCommandCancellationCount`.
- `viewReady` (`terminalViewIsPresentable`) and `terminalSurfaceIsReady`
  failures just loop.
- `present_wait_timeout` covers only "output boundary not reached", which was
  not the case here.

Decisive evidence was an absence: `present_now` is logged whenever it returns
false, and the log had **zero** occurrences, so `presentNow()` was never even
called. The task was stuck on `viewReady` or `terminalSurfaceIsReady` — a
stopped AppKit view or a cleared native renderer. The two were
indistinguishable from the log, which is itself the bug in the diagnostics.

Two secondary faults made it permanent:

- The watchdog capped retries at five and then stopped, so after 15:57:37
  nothing retried at all. Recovery came from an unrelated daemon re-anchor.
- The watchdog's `attached` field compared `entry.view.superview === activeHost(sessionID)`,
  which reports `true` when both are nil. Evidence that can be wrong is worse
  than no evidence.

### Fixes

- `present_wait_state` (non-verbose, once per presentation task) records
  `viewAttached` / `viewHidden` / `viewVisible` / `viewFrame` / `hostBounds` /
  `surfaceReady` / `viewportValid` / `outputReady` / `displayVisible` /
  `recoveryPhase`, so the next occurrence names the gate.
- `onPresentStalled` hands the Session back to the client, which clears its
  attach marker and runs the cold path (`attachSelectedSession`: re-subscribe
  and install a snapshot). That is the same recovery the daemon re-anchor
  eventually triggered, now deterministic and about two seconds instead of two
  minutes.
- The watchdog retries for as long as the pane is unpresentable and caps only
  its log volume; the `attached` field requires a non-nil host.

### Engineering lesson

- **Absence of evidence is evidence.** `present_now` never appearing was the
  single most useful fact in the log: it located the stall above that call
  without any verbose logging.
- **A waiting loop with silent gates needs a bounded report.** Any loop that can
  wait forever on several conditions must say which condition held it, or the
  next report will be as opaque as this one.
- **Do not let a retry cap become a give-up cap.** Five retries then silence
  turned a recoverable pane into a two-minute outage. Cap the noise, not the
  healing.
- **Escalate rather than spin.** The manager cannot rebuild a native renderer or
  re-mount a view on its own; only the client's recovery path can. Reporting the
  stall across that boundary is what makes the failure self-healing.

### 008 follow-up - The stall report named the wrong gate, and the real one was never armed

The first `present_wait_state` reports came back with every field healthy:
`viewVisible=true`, `surfaceReady=true`, `outputReady=true`, `viewportValid=true`,
host and view sizes matching. So the stall was not in the two silent gates the
diagnostic was built to separate.

That left the third silent exit inside `presentNow()`: while a synchronized
output block (`ESC[?2026h`) is open, it returns `false` without a draw. That
path is supposed to be bounded — `isSyncStalled` forces the draw once the block
has been pending for 50ms, precisely "to avoid a permanently black warm
promotion when the closing sequence is split across Data boundaries or never
arrives".

It never fired, because `syncEnteredAt` was **never assigned**. The scanner
tracked `syncDepth` and the property read `syncEnteredAt`, but nothing recorded
when the block was entered, so:

```swift
guard syncDepth > 0, let entered = syncEnteredAt else { return false }
```

always took the `nil` branch. A promotion that landed inside a synchronized
block therefore deferred until the block closed — seconds of black for a TUI
that holds blocks open across frames, and the reason switching away and back
"fixed" it (the redraw landed outside a block).

Fixes: `updateSyncDepth` records the entry instant when the depth goes 0 to 1
and clears it at 0; `present_wait_state` now reports `syncPending`/`syncStalled`
so the next stall names this case directly; a test drives the writer through
`ESC[?2026h`, asserts the escape does not fire early, and asserts it does fire
while the block stays open.

Lesson: **an escape hatch that is never armed looks exactly like no escape
hatch.** `isSyncStalled` read as a working bound in the code and in its comment;
only its own test showed it could never be true. Bounds that exist purely to
break a stall deserve a direct test, not just a comment explaining them.

## 009 - One stall deadline served two different reasons

### Symptom

Five black panes, each lasting **2.063 / 2.083 / 2.074 / 2.085 / 2.074 s**, and each
ending in a full snapshot recovery that itself took only **61-69 ms**. The pane
was black for two seconds and the repair took sixty milliseconds.

### Root cause

`schedulePresent` had a single 2 s stall deadline, but two unrelated reasons to
wait:

- **Waiting for the output boundary.** Legitimate, and it deserves a generous
  bound: drawing before the writer has applied a burst exposes a half-applied
  TUI frame.
- **Not being able to draw at all.** A stopped AppKit view, a cleared native
  surface, or an open synchronized-output block. These have no such excuse, and
  the pane is black for the entire window before anything happens.

Both waited 2 s, so the cheap case paid the expensive case's price. Two smaller
faults made it worse:

- The resize wait (`resizingUntil`, refreshed to `now + 250 ms` by *every*
  geometry change) sat in front of the draw path with a `continue`, so a
  sustained stream of geometry changes skipped the stall check entirely and the
  black window had no bound at all. 62 of 103 logged geometry changes followed
  another within 300 ms, so that was not hypothetical.
- When the grid was already correct, the only missing step was a draw, yet the
  escalation paid for a full re-subscribe plus snapshot install (and that
  install is what makes the pane visibly repaint end to end).

### Fixes

- The output-pending wait keeps its 2 s bound; the draw itself gets a 200 ms
  deadline (`drawStallDeadline`).
- At that deadline the promotion first tries `presentNow(forceDraw: true)`,
  which bypasses the synchronized-output deferral because the block's bytes are
  already in the grid this would draw. Only if that fails does it report and
  hand the Session to the client for recovery.
- The resize wait is capped at the stall deadline, so it can no longer starve
  the draw path.
- The presentation success path moved into `finishPresentation` so the normal
  draw and the forced draw cannot drift apart.

### Engineering lesson

- **One deadline for two reasons hides the cheap fix.** Splitting the bound by
  *why* the wait is happening took the user-visible delay from two seconds to
  about 200 ms without weakening the bound that actually protects the frame.
- **A `continue` above a deadline makes the deadline unenforceable.** Any loop
  guard that skips the stall check belongs inside the bound it protects.
- **Prefer the cheapest repair that matches the state.** A correct grid with a
  missing draw needs a draw; re-subscribing the Session and installing a
  snapshot is a much more expensive answer to the same problem, and it is the
  one the user sees as a full replay.

## 010 - An opaque cursor forced a byte-at-a-time catch-up, and the gap set the attach latency

### Symptom

A first visit to a Session could take seconds before its content appeared (the
"replay" a TUI paints when a full state is installed), while most visits took
0.1-0.3 s. The daemon's own instrumentation put the whole delay inside one
attach step: `attachOutputLocked` had p50 10 ms, p90 80 ms, p99 487 ms and a
max of 10 345 ms.

### Root cause

Phase timings (`reanchor: phases`) and a dedicated line (`reanchor: catchUp`)
named it in one run:

```
reanchor: catchUp session=83fb67bf bytes=2842 rounds=2842 ms=1414
reanchor: phases   captureMs=140 catchUpMs=1415 enqueueMs=1 readerMs=12
```

`catchUpOutputCursor` records output that arrived between pausing the shared
reader and capturing the checkpoint. It read **one byte per round trip**,
deliberately: `localOutputSource.Read` only stops at the end of the current
segment file, never at the checkpoint, so a larger read would consume bytes the
live stream still delivers and duplicate them in the pane. The cursor could only
be compared for equality, so the loop could not know how far the gap extended.

Cost per byte was not the read; it was everything around it. Every iteration
called `recordOutputWithCursorMode` with one byte, which takes `outputMu`, then
`outputSession.mu`, splits the payload into frames, and appends to the ring.
2842 iterations at roughly 0.5 ms each is the 1.4 s. The gap grows with output
volume (it is whatever arrived while the reader was paused), so busy Sessions
were the slow ones, and a 20 KB gap would have been ~10 s.

### Fix

- Ghostline gained `Cursor.Distance(to) (uint64, bool)`, which reports the span
  when both cursors share an output generation and are ordered, and `false`
  otherwise (zero cursor, generation boundary, reversed pair). Released as
  v1.4.0 and pinned.
- `catchUpReadBuffer` sizes each read from that span, capped at 64 KiB, and
  falls back to a single byte when the span is unknown. The safety property is
  unchanged: the read can never pass the checkpoint cursor.
- `reanchor: catchUp` keeps reporting bytes, rounds and milliseconds, so the
  batching cannot silently regress into a byte walk.

### Engineering lesson

- **An opaque handle can force a quadratic-in-bytes protocol.** Comparing
  cursors for equality was enough for correctness and insufficient for
  performance; the missing operation was a distance, not a smarter loop.
- **The expensive part may be the bookkeeping, not the I/O.** The read was a
  cached local file read; the per-byte ring append and two lock acquisitions
  were the 0.5 ms. Batching fixed both at once.
- **Instrument by phase before optimising.** One total (10 ms median, 10 s max)
  could not distinguish a slow snapshot from a slow reader; the phase line made
  the answer unambiguous in a single run.

## 011 - The last replay was the first visit, and only pre-seeding removes it

### Symptom

After the promotion and recovery paths were fixed, a user still saw a full
repaint ("replay") occasionally, most visibly on a `pi` pane, and correlation
with output volume suggested something in the output path.

### What the logs said

Every `atomic_recovery_installed` in the newest runs was preceded by an
`attach_start` and/or a user action — none happened while the user was just
watching. In one five-minute process, six Sessions were attached and each was
attached exactly once, all with `existing=false`:

| Session | Snapshot |
|---|---:|
| 193356e6 (pi) | 850 KB |
| a1923994 | 808 KB |
| 83fb67bf | 336 KB |
| da86da55 | 123 KB |
| 6775560f | 19 KB |
| dc3da257 | 1.4 KB |

So the remaining replay was the **first visit to a Tab in a process**. It has no
retained surface, so the daemon answers the subscribe with a complete atomic
state, and installing it replaces the grid — which a full-screen TUI repaints end
to end. Snapshot size tracks output volume, which is why `pi` was the obvious
one: a fresh shell installs 1.4 KB, a busy agent TUI installs ~850 KB.

The warm budget cannot help here (it only covers revisits), and the daemon side
was already fast by then: `reanchor: phases` showed `captureMs` 0-82 ms with
`catchUpMs=0`.

### Fix

`scheduleWarmPrefetch` seeds the Tabs of the current workspace or group in the
background, ordered outward from the selected Tab, capped at 12, one every
250 ms, starting 700 ms after a selection so it never competes with the pane the
user is looking at. Each seed reuses `attachBackgroundSession`, so the snapshot
transfer and the repaint happen while the Tab is off screen, and the click that
follows is a reparent (no snapshot, no repaint).

### Engineering lesson

- **Distinguish "the lifecycle is broken" from "the first visit is expensive".**
  The earlier fixes removed genuine defects; what remained was the inherent cost
  of creating a surface that does not exist yet, and no amount of promotion work
  could remove it.
- **Snapshot size is a proxy for output volume.** Ranking Sessions by payload
  size predicted exactly which pane the user would single out.
- **Move unavoidable work off the critical moment.** The transfer and repaint are
  unavoidable; doing them while the Tab is off screen is what makes the click
  feel instant.

## 012 - Chrome that comes and goes with live metadata moves every pane

### Symptom

A pane reloaded its whole screen ("replay") repeatedly while the user stayed in
one Session and its agent streamed output. No switching, no state install: the
logs showed no `atomic_recovery_installed` for that Session in the window, and
no `recovery_anchor` beyond the attach.

### Root cause

The pane's measured height oscillated by exactly 28 pt, and 28 pt is
`WarrenLayoutMetrics.paneHeaderHeight`:

```
19:58:48.730 tab_promote 193356e6 -> present_complete   (no geometry change)
19:58:51.751 roster_apply
19:58:51.826 roster_apply                                <- metadata updated
19:58:51.531 GEOM 1148x869 -> 1148x841                  <- header gone, -28 pt
19:58:51.572 resize_request 143x49                       <- SIGWINCH
```

The header was rendered as `if showsPaneHeader, !displayTitle.isEmpty`.
`showsPaneHeader` is stable (`currentTree.count > 1 || paneBarListsEverySession`,
and compact mode makes the second clause true), but `displayTitle` is rendered
from live Session metadata (`runtimeProcess`, `runtimeCommandLine`,
`workingDirectory`, `title`). While an agent streams, roster deltas rewrite that
metadata, and a render can transiently be empty. Empty hid the 28 pt header,
which grew the terminal, which resized the PTY, which sent SIGWINCH, which made
the full-screen TUI repaint from the top. The next roster update restored the
title, hid nothing, and resized it back — a second SIGWINCH and a second repaint.
Output volume drives metadata churn, which is why pi reproduced it so well.

### Fix

The header renders whenever `showsPaneHeader` and its label falls back from the
rendered title to the Session title and then to the kind name, so the pane's
height never depends on live metadata. `stablePaneHeaderTitle` is exposed and
unit tested for that invariant.

### Engineering lesson

- **Fixed-size chrome must not be gated on volatile data.** The gate looked
  harmless — "don't draw an empty title bar" — but the bar's height was part of
  the layout, so its presence was a resize.
- **A resize is a visible event to a TUI.** Two terminal rows of movement is
  enough to make a full-screen agent repaint everything, which users read as a
  replay rather than as a layout change.
- **`|Δrows| == 2` is a useful shibboleth.** Sizes that differ by exactly one or
  two rows and flip back within seconds point at 28 pt of chrome, not at the
  terminal pipeline.

### 011 follow-up - The pre-seed was superseded, and installing both repainted twice

The first version of the pre-seed did not do what it promised. A background seed
runs while its pane is unmounted, so the manager cannot prepare a surface for it
and the daemon's snapshot is deferred:

```
20:24:05.100 atomic_recovery_deferred 83fb67bf bytes=334872 surfaceReady=false
20:25:40.982 attach_start              83fb67bf existing=false   <- still a cold attach
20:25:41.129 atomic_recovery_installed 83fb67bf bytes=334872 retry=true
20:25:41.227 atomic_recovery_installed 83fb67bf bytes=334872
```

Two things are wrong with that pair. The seed never installed anything off
screen, so the click still cold-attached (`existing=false`) — it added work and
one subscription without removing the visible install. And the attach then
delivered the same state that the deferred retry was still holding, so the pane
replaced its grid twice and repainted twice for one state. The pre-seed was
reverted for that reason.

The double installs were a real defect regardless of the pre-seed: the retry
captures its payload, awaits surface readiness, and installs whatever it captured
even if a newer state already landed. Two fixes:

- `installAtomicRecovery` drops a deferred payload for the Session when the
  incoming state is the same age or newer (`atomic_recovery_superseded`), and
  cancels its retry.
- The retry re-checks that the pending payload is still the one it captured
  after its readiness awaits, and returns if it is not.

Lesson: **a wait before an install invalidates whatever was captured before the
wait.** Re-read the source of truth after every await that can let newer work
run, especially when the action is "replace the whole grid".

## 013 - A repaint that only one agent shows after a resize is the agent's own replay

### Symptom

Splitting a pane made the Session that was already on screen look as if it
replayed itself: the `pi` agent redrew its whole interface from the top, while
`codex` in the same layout did not. A split is a resize for the pane being split
— it gives up the space the new pane takes, and it gains the 28 pt pane header a
lone pane does not draw — so the question was whether Warren re-created the
terminal or the application redrew it.

### What the logs said

The pane that was split appears in exactly one place after the split, and it is
neither a view nor an attach:

```
11:17:44  terminal_view_appear  f59851cc   <- only the pane this split created
11:17:44  resize_request        f3935387   <- the pane that was on screen, once
```

No `terminal_view_appear`, no `attach_start`, no `atomic_recovery_installed` for
`f3935387`: its surface was never re-created and no state was installed into it.
One `resize_request` reached the daemon, for the grid the pane genuinely has now.

Two Warren-side causes had already been removed before that reading. The content
used to choose between a lone-pane view and a split view for the same Session, so
the first split re-built the terminal the user was looking at; both cases now go
through `WarrenDesktopSplitTreeView` (see 012 for the other one, chrome whose
presence moved the pane's height). The layout is also flattened into one frame
per pane, so a new sibling no longer rebuilds the panes that were already there.

### Root cause

`pi` repaints its interface, history included, when its terminal reports a new
size. A resize is not a Warren event to suppress: the pane really is smaller, the
PTY has to know, and a full-screen TUI is entitled to redraw at its new grid.
`codex` reflows in place for the same signal, which is what makes the difference
visible.

### Lesson

**A repaint that follows a resize and only one application shows is that
application's behavior.** Before touching the renderer, read the log for the pane
that appears to replay: `terminal_view_appear`, `attach_start`, or
`atomic_recovery_installed` means Warren re-created a view or installed a state;
a single `resize_request` with none of those means the pane was resized and the
application decided what to draw.
