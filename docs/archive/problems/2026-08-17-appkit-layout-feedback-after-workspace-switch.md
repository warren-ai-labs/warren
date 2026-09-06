# Warren Desktop Freeze: AppKit Layout Feedback After Workspace Switching

- Recorded: 2026-08-17 (Asia/Shanghai)
- Status: Suspected; no code change made in this incident
- Affected build: Warren `0.1.0`, PID `24616`

## Symptom

After switching among the migrated workspaces, Warren shows the spinner and stops
responding. The process remains alive and consumes approximately 35--42% CPU.
The headless session continues to run, so the terminal sessions themselves are
not lost.

## Evidence captured

- `sample 24616 5` (`/tmp/warren-hang-20260817.sample.txt`) spends most main-thread
  samples in `NSDisplayCycleFlush` -> `NSWindow.layoutIfNeeded` ->
  `NSView.layoutSubtreeIfNeeded` -> `NSHostingView.layout` -> SwiftUI
  `ViewGraphRootValueUpdater.render`.
- No `pthread_mutex_wait`, `__ulock_wait2`, or Ghostty surface-lock wait appears
  in the sampled main-thread hot path. This is therefore not the previously
  identified AppKit/Ghostty lock-order deadlock.
- `terminal-diagnostics.log` contains 114 `roster_apply` events in the last 500
  lines. The events continue after the last explicit workspace/tab action, while
  the roster remains at 17 tabs and the retained surface count stays at 8--9.
  `roster_apply` is evidence of repeated roster processing, not by itself proof
  that every pass publishes a changed projection.

## Current hypothesis

The strongest concrete candidate is a layout-to-layout feedback loop in the
vendored Ghostty AppKit view:

1. `AppTerminalView.layout()` calls `core.fitToSize()`,
   `core.requestImmediateTick()`, and schedules a deferred settle resync on
   every layout pass.
2. The deferred `resyncAfterLayoutSettle()` calls
   `layoutSubtreeIfNeeded()` and performs another fit/tick.
3. Repeated workspace/surface attachment and roster-driven SwiftUI updates can
   keep invalidating the host while these deferred resyncs are still queued.
4. AppKit then repeatedly enters the display-cycle layout path, matching the
   captured sample and leaving the UI spinning at elevated CPU.

The repeated `roster_apply` events are a second contributing signal: even an
unchanged daemon roster may be traversing the full projection/surface path often
enough to keep the view tree invalidated. This needs a separate equality/publication
check before it can be called a root cause.

## Scope and safety

No session data was changed and no process was terminated. Restarting only the
Warren GUI is safe for the current headless sessions; the headless service keeps
the session state.

## Follow-up

When implementing the fix, first make settle resync conditional on an actual
bounds change and do not force `layoutSubtreeIfNeeded()` from the resync itself.
Then verify that identical roster frames do not publish or re-run surface
retention, and add a regression test that repeatedly switches a multi-workspace
roster without accumulating layout work.

