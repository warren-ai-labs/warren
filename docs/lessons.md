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
