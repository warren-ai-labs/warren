# Warren Desktop Freeze: Fullscreen Triggered Disconnect Teardown Deadlock

- Recorded: 2026-08-19 (Asia/Shanghai)
- Status: Fixed
- Affected build: Warren `0.1.1`, PID `20143`

## Symptom

Double-clicking the empty top chrome to enter full screen froze the GUI. The
process stayed alive, the diagnostics log stopped advancing, and the main
thread blocked in terminal teardown.

## Evidence

`sample 20143 3 1` shows:

- Main thread:
  `WarrenCompositionRoot.restoreEndpointSelection` ->
  `connectSelectedEndpoint` -> `remoteModel.disconnect()` ->
  `TerminalSurfaceManager.shutdown` -> `AppTerminalView.deinit` ->
  `TerminalSurfaceCoordinator.tearDownSurface` -> `clearSurface` ->
  `__psynch_mutexwait`.
- Utility drain thread:
  `WarrenGhosttyOutputWriter.drain` -> `InMemoryTerminalSession.receive` ->
  `ghostty_surface_write_buffer` -> `__ulock_wait2`.

The full-screen window transition restarts the root view's `.task`, which
calls `connectSelectedEndpoint()` again. The unconditional `disconnect()` then
tears down mounted surfaces while the background writer is inside a Ghostty
write that holds the in-memory session lock, producing the documented
teardown lock inversion.

## Fix

- `connect` and `connectSelectedEndpoint` are now idempotent for an already
  healthy endpoint, so a root `.task` restart does not disconnect and recreate
  surfaces.
- `TerminalSurfaceManager.dispose` keeps the entry in `pendingDisposals` until
  `outputWriter.shutdown(completion:)` confirms the drain has exited, then
  releases the native view on the main actor.
- `InMemoryTerminalSession` no longer calls `ghostty_surface_*` while holding
  its `NSLock`. `receive` snapshots the surface, writes outside the lock, and
  gates writes on `surfaceReady` so pre-surface bytes still precede live
  output.

## Verification

- `testShutdownDefersNativeViewReleaseUntilOutputDrainExits` covers the
  deferred release.
- `swift test --package-path Packages/GhosttyAdapter` passes (27 tests).
- `swift test` at the repo root passes (21 tests).
