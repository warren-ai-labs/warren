# Problem Record: A Long Sidebar Can Enter a Stuck Native Drag Session

- Recorded: 2026-08-17 (Asia/Shanghai)
- Repository: `abcdlsj/warren`
- Branch: `main`
- Status: Diagnosed from the symptom-to-code path; exact event sequence that
  leaves the native drag session active still needs an instrumented reproduction
- Affected area: macOS desktop project and workspace sidebar

## Summary

Expanding or interacting with a sidebar whose content is taller than the
window can unexpectedly start the native sidebar reorder interaction. The
project list first collapses, an insertion line appears, and the application
then stops accepting clicks on the sidebar and tab bar.

The visible sequence matches Warren's project drag path exactly. A transparent
AppKit overlay intercepts a row press, marks the native drag session active,
collapses every expanded project, and draws a drop insertion line. Cleanup is
performed only by the native drag-session `endedAt` callback. The implementation
has no rollback for a failed or interrupted drag start and no cancellation
cleanup when the overlay leaves its window.

Long content makes this lifecycle unsafe. Collapsing all projects while a drag
is starting changes the lazy stack's height and the scroll offset underneath
the AppKit drag source. This produces a large source-view relayout during the
same mouse interaction that owns the drag session.

## Symptom

The reported sequence is:

1. The sidebar contains more rows than fit in one window.
2. The user attempts to expand or interact with the list.
3. The list collapses before it can remain expanded.
4. A short horizontal indicator resembling an insertion marker appears.
5. The sidebar no longer expands.
6. Clicking another terminal tab has no effect.

Restarting or otherwise ending the invalid interaction may restore input, but
it does not remove the underlying lifecycle defect.

## Expected Behavior

- Clicking a project row expands or collapses that project.
- Reordering starts only after the required modifier is held and the pointer
  moves beyond a drag threshold.
- Scrolling content may relayout without invalidating an active drag source.
- Cancelling, failing to start, or ending a drag always restores project
  expansion state and releases mouse input.
- Sidebar interactions never block terminal tab selection.

## Relevant Implementation Path

`WarrenDesktopSidebarRows` is rendered inside a vertical overflow scroll view.
The rows use a `LazyVStack`, and an `NSViewRepresentable` drag overlay is
attached to the complete row stack rather than to a stable viewport.

The interaction proceeds as follows:

1. Each realized project and workspace row publishes its frame through a
   preference key.
2. `WarrenDesktopSidebarDragOverlayView.hitTest` returns the transparent AppKit
   overlay when its cached Command state is true and a left mouse press lands
   on a recorded row.
3. `mouseDown` immediately marks the source row and invokes
   `onProjectDragBegan` for a project. It does not wait for pointer movement.
4. `beginProjectDrag` saves the current expansion set and replaces it with an
   empty set, collapsing every project with animation.
5. `mouseDown` marks the session active and calls `beginDraggingSession`.
6. Drag movement resolves the nearest drop zone and draws a 2.5-point
   insertion line.
7. Only `draggingSession(_:endedAt:operation:)` clears the source row, restores
   project expansions, marks the session inactive, and removes the insertion
   line.

When `session.isActive` is true, the overlay returns itself from hit testing.
The native AppKit dragging loop also owns mouse delivery while the operation is
active. This explains why the failure affects controls outside the project row,
including terminal tabs.

## Root Cause

The root cause is an unsafe boundary between SwiftUI list layout and an AppKit
native drag session.

Three implementation defects combine:

1. **Drag starts on mouse-down.** There is no movement threshold separating a
   click from a reorder gesture.
2. **The source layout is mutated before the drag session is established.** A
   project press calls `beginProjectDrag`, which collapses the complete project
   tree before `beginDraggingSession` runs.
3. **Cleanup has a single success-path owner.** Expansion restoration and
   `session.isActive = false` exist only in the native `endedAt` callback. There
   is no idempotent cleanup for cancellation, failed drag startup, source-view
   removal, or window detachment.

The Command gate is also unreliable. `WarrenDesktopSidebarDragSession` caches
modifier state from local `.flagsChanged` events. `hitTest` and `mouseDown`
trust that cache instead of validating `event.modifierFlags`. If the release
event is missed or delivered outside the monitor's lifetime, a later ordinary
click can be misclassified as a reorder press.

## Why Long Lists Expose the Failure

The same drag code exists for short lists, but a long list adds two material
layout changes:

- The row stack is larger than the scroll viewport and uses lazy realization.
- Collapsing expanded projects can reduce the stack from several viewport
  heights to less than one viewport, forcing SwiftUI to clamp the scroll offset
  and update the embedded AppKit overlay's geometry.

Those changes occur after the source row is chosen but before or during native
drag startup. The drag source, its row-frame map, and the scroll geometry can
therefore describe different list layouts within one mouse interaction.

## Confirmed vs. Unconfirmed

### Confirmed

- Project drag startup intentionally collapses every expanded project.
- The reported insertion-like marker is the native drag overlay's insertion
  line.
- The overlay marks its session active before calling
  `beginDraggingSession`.
- An active session causes the overlay to keep intercepting hit tests.
- Expansion restoration, source cleanup, insertion-line cleanup, and session
  deactivation all depend on the native `endedAt` callback.
- The current tests cover sidebar tree persistence and reorder actions, but do
  not exercise the native drag overlay, a list taller than its viewport, drag
  cancellation, or modifier-state loss.

### Unconfirmed

- Whether the first misclassified press is caused by stale cached Command
  state, a Command-click without pointer movement, or another AppKit event
  ordering edge case.
- Whether the stuck instance loses the native `endedAt` callback entirely or
  receives it after the SwiftUI state that owns the cleanup closures has been
  replaced.
- The minimum project and workspace count required to reproduce the problem
  across supported macOS versions and window sizes.

## Impact

- A routine sidebar interaction can make the desktop appear frozen.
- Project expansion state can remain collapsed after the failed interaction.
- Terminal sessions continue running, but the user may be unable to switch to
  another tab with the pointer.
- A restart may be required to recover input.
- The failure is more likely in real repositories with many projects or
  workspaces, so small preview fixtures do not represent the affected layout.

## Proposed Fix Work

The following work is recorded for a later repair and was not performed during
this investigation:

1. Start reordering from `mouseDragged` only after a defined movement
   threshold. Keep plain mouse-down and mouse-up available to SwiftUI buttons.
2. Validate the current event's modifier flags at drag startup instead of
   trusting only cached `.flagsChanged` state.
3. Do not collapse the source list before the native drag session is
   established. Prefer a stable drag snapshot and stable viewport geometry.
4. Centralize drag cleanup in one idempotent function and call it from normal
   completion, cancellation, failed startup, and view/window detachment.
5. Ensure cleanup restores expansions only for a project drag that actually
   saved them.
6. Add structured diagnostics for drag begin, native begin, move, cancel, end,
   overlay detachment, modifier state, content height, and scroll offset.
7. Add an AppKit integration test with sidebar content taller than the window,
   including click, Command-click without movement, reorder, Escape cancel,
   window detachment, and tab selection after every case.

## Acceptance Criteria

- A project in a sidebar taller than the window expands and remains expanded
  after a normal click.
- Command-click without pointer movement does not start a reorder operation.
- Reordering starts only after the pointer crosses the drag threshold.
- Cancelling a reorder restores the original expansion set and removes all
  drag visuals.
- A failed or interrupted drag leaves `session.isActive` false.
- Terminal tabs remain clickable after normal, cancelled, and failed sidebar
  interactions.
- Automated tests cover both short and overflowing sidebar content.

