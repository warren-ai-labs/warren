# Warm Reattach Shows Truncated Scrollback Until Resize

- Recorded: 2026-08-17 (Asia/Shanghai)
- Status: Fix applied; pending verification on a long warm-tab session
- Affected build: Warren `0.1.0`, PID `34085`

## Symptom

After switching to a tab whose surface was already mounted (warm reattach),
only the most recent portion of terminal history is reachable: scrolling up
stops after a small amount, and the older lines "appear" only after the user
resizes the window. A blank session also recurred after a workspace switch
while this was being investigated.

The desktop diagnostics show every reattach completing with a high rendered
sequence (`present_complete` with multi-megabyte sequences), so this is not
lost output bytes and not a present-wait stall.

## Investigation

- Warren keeps up to eight warm `GhosttySurface`s; switching tabs demotes the
  old view (occluded, removed from the window) and later reattaches the same
  native Ghostty surface.
- The reattach path (`TerminalSurfaceManager.attach`) unhides the view, calls
  `setSurfaceVisible(true)` and `fitToSize()`, then presents — but it never
  touches Ghostty's viewport/page-list state.
- The vendored libghostty (upstream commit `35e1a0160`, which includes the
  scrollback page compression feature) compresses cold history pages while a
  terminal is idle and restores them lazily. A resize is what pulls compressed
  history back into the active area; that matches the user-visible
  "only resize recovers" behavior.
- A same-size `ghostty_surface_set_size` is ignored by Ghostty, so the normal
  reattach metric sync cannot force the reflow that a manual resize performs.
- An isolated probe test that hides/reattaches a surface and reads the full
  scrollback passes: the underlying history survives. The truncation is in
  the reachable/restored viewport state, which only the real renderer idle
  path exercises.

## Fix

Two changes in `Packages/GhosttyAdapter`:

1. `TerminalSurfaceManager.demote()` captures the current viewport text as a
   reattach anchor. On the next `attach()`, `GhosttySurface.resyncIfNeeded()`
   compares the viewport to that anchor: a normal reattach returns to the same
   content and keeps the user's scroll position untouched; only a mismatch
   (stale pin, clamped offset, or blank resume) forces `resyncForActivation()`
   — pin the viewport to the live bottom (`scroll_to_bottom`) and draw
   immediately.
2. `scrollback-compression` is disabled in the surface configuration so idle
   compression never leaves history lazily restored in the first place.

## Tradeoff

Disabling compression keeps scrollback resident, so physical memory grows by
roughly the uncompressed page memory per surface. Logical history is still
bounded by `scrollback-limit-bytes`. Revisit this setting when the vendored
Ghostty build fixes restore-on-scroll, or if warm-surface memory becomes a
measured problem (see `docs/decisions/2026-08-17-warm-surface-memory.md`).
