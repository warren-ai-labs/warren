# Terminal Rendering Comparison and Warren Direction

Date: 2026-08-26

Status: accepted

## User-visible requirement

Terminal navigation should satisfy three conditions:

1. Entering a session shows one stable page. There is no black frame, flash, or
   visible re-layout.
2. A session appears quickly, without replaying its entire history from top to
   bottom.
3. Resize and tab switching do not turn a presentation change into a terminal
   recovery.

The implementation should be judged by this experience first. A successful
attach message or a completed render request is not sufficient if an older
frame becomes visible before the final frame.

## What Superset does

Relevant implementation areas:

- `apps/desktop/src/renderer/lib/terminal/terminal-runtime-registry.ts`
- `apps/desktop/src/renderer/lib/terminal/terminal-runtime.ts`
- `apps/desktop/src/renderer/screens/main/components/WorkspaceView/ContentView/TabsContent/Terminal/hooks/useTerminalLifecycle.ts`
- `packages/host-service/src/terminal/terminal.ts`

Superset keeps an xterm runtime in a process-wide registry. The terminal DOM
wrapper is moved between its visible container and a parking container; the
xterm instance, parser state, WebSocket, and output consumer remain alive.
Therefore a normal tab switch is a DOM reparent/presentation operation, not a
new terminal attach.

While parked, the runtime continues consuming output. It does not accumulate a
visible replay backlog. A bounded parked-runtime LRU may evict a runtime for
memory, but that is an explicit cold-path decision.

The transport uses a sequence anchor and a bounded catch-up ring. An exact
anchor replays only the missing suffix. If the anchor cannot be recovered, the
client keeps its existing screen and asks the running program to repaint (for
example through `SIGWINCH`); it does not clear the screen and synthesize a full
scrollback replay in the visible path.

Resize is debounced and deduplicated. It is sent only for the focused peer and
does not implicitly perform a snapshot recovery.

## What cmux does

Relevant implementation areas:

- `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Renderer.swift`
- `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeLifecycle.swift`
- `Sources/TerminalPortalReconciliation.swift`
- `Sources/RemoteTmuxControlConnection+PaneSeed.swift`
- `Sources/RemoteTmuxControlConnection+Sizing.swift`

Each pane owns a long-lived Ghostty surface, terminal grid, PTY, and remote
connection. Switching tabs changes visibility, active state, and occlusion;
it does not destroy and recreate the surface. Reparenting is reconciled on the
next run-loop turn rather than synchronously from a SwiftUI/AppKit layout
callback, preventing lifecycle re-entry.

cmux may release the GPU renderer for an idle surface while retaining terminal
state. Rebuilding that renderer is a residency optimization, not a terminal
content recovery.

For remote tmux, `capture-pane` is used only for initial seeding, reconnect, or
an explicit repaint. Resize does not capture the entire pane again. It lets the
remote program receive `SIGWINCH` and emit an incremental redraw. When a seed is
needed, cmux uses a pause/snapshot/live-catch-up transaction so the snapshot
cannot overtake live output.

## Common principle

Superset and cmux differ in UI toolkit and transport, but their good behavior
comes from the same lifecycle rule:

> Keep the terminal runtime as the source of truth across ordinary navigation;
> make presentation local, and reserve replay/snapshot for exceptional recovery.

They do not solve the problem by making a full replay faster or by trying to
render terminal bytes backwards. ANSI terminal state is order-dependent: cursor
position, scroll regions, alternate screen, wrapping, and TUI redraws cannot be
reconstructed safely by prepending the newest page before history.

## Warren gap

Warren already has an active/warm/cold surface policy and a surface manager,
but the current behavior does not fully implement the intended warm semantics:

- background sessions do not continuously consume output into their retained
  surface;
- tab switching can call `session.subscribe` again;
- an unrecoverable anchor can enter the ghostline full-capture path;
- that path clears the surface and feeds a complete snapshot to the same
  surface that may already be visible.

The resulting user-visible chain is:

```text
tab switch -> attach -> anchor fallback -> full capture -> clear -> replay
```

This explains why only some sessions flash or scroll from the beginning: only
those sessions take the fallback path.

## Direction to choose

Choose a **persistent warm runtime/surface** design, combining Superset's
continuous output consumption with cmux's explicit surface/presentation
lifecycle.

### Normal path

- Keep one retained runtime/surface for each session within a bounded warm
  budget.
- Continue consuming and applying background output while the surface is
  hidden/occluded.
- On tab switch, only reparent/present the already-current surface.
- Do not call `session.subscribe`, replay a ring, or clear the screen for an
  ordinary switch.
- Only the active session may receive input, focus, or resize ownership.

### Recovery path

Treat reanchor as an exceptional transport/runtime recovery, not as navigation.
Prefer, in order:

1. keep the current Ghostty screen and re-anchor the byte position;
2. ask the live program to repaint through the PTY (`SIGWINCH` or equivalent);
3. if a snapshot is unavoidable, build it in a hidden staging surface and
   present it only after the staging surface is complete.

Never clear an already visible surface merely because an anchor is stale, and
never put full scrollback replay on the first-paint path.

### Resize path

- Send resize only for the active/focused session.
- Coalesce layout callbacks and suppress same-size requests.
- Apply one size after layout settles.
- Let the program's `SIGWINCH` redraw update the existing surface.
- Do not make resize call `Capture` or trigger a full recovery.

## Why this is the right trade-off

This directly targets the reported symptoms: the screen that becomes visible is
already the latest screen, so there is no old-frame flash; tab switching has no
history replay, so it is fast; and resize cannot accidentally turn into a
full-screen scroll.

The costs are explicit and controllable: retained surfaces consume memory and
background consumers consume CPU/network. Keep the existing count/byte LRU,
measure it, and evict to a cold path only when the budget requires it. A cold
reattach may still need recovery, but it must be hidden until its result is
ready and must not redefine the normal tab-switch experience.

## Implementation boundary

The first implementation slice should be the lifecycle/protocol boundary, in
this order:

1. make a peer/session subscription capable of feeding all retained sessions;
2. route every received frame to its matching retained surface and advance its
   per-session anchor in the background;
3. make tab selection a local promotion/reparent operation with no attach;
4. isolate reanchor and snapshot recovery from the visible surface;
5. make resize focused, coalesced, and recovery-free;
6. delete delayed hide/show and duplicate attach/replay branches once the new
   state machine owns these transitions.

Success is measured with the three user-visible requirements above, plus
diagnostics proving that an ordinary tab switch performs zero attach/replay and
that resize performs zero full capture.

## Scope decision

The implementation target is ghostline only. tmux is a deprecated legacy
runtime retained solely so existing sessions can be read or removed; it is not
part of the rendering design, compatibility target, or future bug-fix plan.
New sessions and all experience work should use ghostline's PTY, emulator,
checkpoint, and output cursor APIs.

The next implementation slice should therefore make the ghostline runtime and
surface lifecycle match the common principle above: retain the live surface,
consume output while parked, make tab promotion local, and keep checkpoint
recovery hidden from the visible surface.
