# RFC 0002: One-way desktop rendering and terminal lifecycle

- Status: Implemented
- Owner: Warren desktop client
- Created: 2026-08-17
- Implemented: 2026-08-17
- Supersedes: [RFC 0001](0001-terminal-surface-retention.md) view-layer
  retention design

## Summary

Warren will use a one-way desktop rendering architecture.

- SwiftUI describes application state and layout.
- One AppKit host mounts the active terminal view.
- One surface manager owns every Ghostty lifecycle transition.
- Geometry never updates state that changes the geometry being measured.
- Production diagnostics do not participate in layout.
- Terminal retention follows a bounded active/warm/cold policy.

The design keeps terminal state across common tab switches without keeping
every terminal inside the SwiftUI view tree.

## Context

The current desktop path has three competing lifecycle owners:

- SwiftUI mounts, hides, focuses, and sizes terminal views.
- AppKit changes window attachment, first responder, and layout.
- Ghostty creates surfaces, reports metrics, and schedules rendering.

The integration repairs timing differences with preference callbacks,
`Task { @MainActor }`, delayed focus retries, settle resizes, and repeated
present calls. These mechanisms do not form one state machine. They can run in
different orders after a tab or workspace switch.

Two failure families have already occurred:

- SwiftUI layout and preference feedback loops;
- AppKit and Ghostty lock-order inversion during native view attachment.

Retaining every visited surface in a SwiftUI ZStack also makes UI update cost,
memory, and renderer work grow with the number of visited sessions.

## Goals

- Define one owner for terminal lifecycle, focus, visibility, resize, and
  rendering.
- Keep SwiftUI view evaluation free of native renderer side effects.
- Preserve fast tab switching with a strict resource budget.
- Make every transition cancelable, idempotent, and testable.
- Remove geometry feedback loops from the production UI.
- Keep domain and daemon state independent from renderer implementation.

## Non-goals

- Replacing SwiftUI or AppKit.
- Forking Ghostty rendering internals.
- Retaining every open terminal surface without a memory limit.
- Making terminal pixel or grid metrics part of global application state.

## Decision

### 1. Use one-way control flow

The desktop will use this control path:

```text
Daemon events -> Application store -> Immutable UI projection -> SwiftUI
                                                                  |
                                                                  v
                                                    Terminal presentation intent
                                                                  |
                                                                  v
                                                  Terminal surface manager
                                                                  |
                                                                  v
                                                     AppKit host -> Ghostty
```

Native callbacks return to the surface manager. They do not write SwiftUI
state directly.

```text
Ghostty/AppKit callback -> Surface manager -> Coalesced domain/control event
```

Only user-visible, stable values may return to the application store. Grid
metrics, focus retries, visibility, and render requests remain private to the
surface manager.

### 2. Introduce a terminal surface manager

Add one `@MainActor` service owned by the composition root. It is ignored by
Swift Observation and has no SwiftUI property wrappers.

The manager owns:

- the native `AppTerminalView` and `TerminalViewState` for each retained
  session;
- AppKit window attachment and detachment;
- Ghostty surface creation and disposal;
- focus and first-responder changes;
- viewport synchronization;
- visibility, occlusion, and render scheduling;
- output routing and output anchors;
- cancellation generations for every delayed operation.

SwiftUI submits an immutable intent. It does not call Ghostty methods.

```swift
struct TerminalPresentationIntent: Equatable {
    let activeSessionID: TerminalSessionID?
    let viewportSize: CGSize
    let wantsTerminalFocus: Bool
}

@MainActor
protocol TerminalSurfaceManaging: AnyObject {
    func submit(_ intent: TerminalPresentationIntent)
    func reconcile(_ sessions: [TerminalSessionDescriptor])
}
```

`submit` records the latest intent and schedules one reconciliation after the
current SwiftUI/AppKit update cycle. A newer intent replaces older pending
work.

### 3. Mount one terminal view in one AppKit host

Replace the per-surface SwiftUI ZStack with one stable
`TerminalHostRepresentable`.

- `makeNSView` creates a neutral container.
- `updateNSView` only submits the current host and presentation intent to its
  coordinator.
- `updateNSView` does not create a Ghostty surface, move focus, resize, draw,
  or publish state.
- The surface manager attaches the selected native terminal view after the
  current view update has completed.
- The previous terminal view is detached and returned to the registry.

The native terminal view is retained by the registry, not by the SwiftUI view
tree. Detaching a warm view stops its render scheduling without destroying its
surface.

### 4. Use an active/warm/cold retention policy

Each session has one lifecycle state:

```text
cold -> warming -> active -> warm -> active
                    |          |
                    v          v
                  closing <- evicting
```

- `active`: attached to the AppKit host, visible, and allowed to own focus and
  runtime resize.
- `warm`: native surface retained but detached from a window. It consumes
  output, remains occluded, and never draws or schedules display ticks.
- `cold`: no native surface. The daemon output anchor is retained for bounded
  replay when the session becomes active.
- `closing`: rejects new work and disposes native resources exactly once.

The active surface is never evicted. Warm surfaces use an LRU budget defined
by both count and estimated memory: one active surface, plus warm surfaces
bounded by count and estimated memory. The limits were eight and 1 GiB when this
RFC was written, and are 32 and 3 GiB as of 2026-09-15
(`docs/decisions/2026-08-17-warm-surface-memory.md`). The budget may become
configurable after measurement.

Promotion and demotion are serialized. Only the active session may claim
focus, send input, or resize the runtime.

This policy replaces RFC 0001's proposal to keep every live surface mounted
and rendering in the SwiftUI hierarchy.

### 5. Make rendering visibility explicit

The surface manager must apply all visibility changes as one transition.

When a surface becomes warm, it must:

1. clear Ghostty focus;
2. set Ghostty occlusion to hidden;
3. stop render scheduling;
4. cancel pending fit, focus, refresh, and present work;
5. detach the native view from the host.

When a surface becomes active, it must:

1. attach the native view;
2. apply the final viewport once layout has settled;
3. clear occlusion;
4. request one render;
5. claim focus if the latest intent still requests it.

Every delayed operation carries the session ID and transition generation.
Stale work exits before touching AppKit or Ghostty.

### 6. Remove geometry-to-layout feedback

Layout inputs may produce presentation values. They must not change the
geometry that produced those inputs.

#### Tab overflow

Tab overflow is derived directly from available width and the known tab-track
width during layout. It is not stored through a `PreferenceKey`.

Chevron space remains structurally stable. Visibility changes opacity and hit
testing only; it does not change the measured track width or view hierarchy.

#### Scroll edge fades

Scroll offsets come from one AppKit scroll coordinator or a platform scroll
geometry API. The coordinator emits only edge booleans after bounds changes.
Fades are overlays and never affect scroll content or viewport geometry.

#### Sidebar drag frames

Row geometry is collected only while a drag session is active. The drag
coordinator owns those frames. Normal sidebar rendering has no row-frame
preference tree.

#### Semantic observation

Semantic geometry is installed only when a recorder is explicitly injected by
UIProbe. A production app with no recorder has accessibility identifiers but
no semantic `GeometryReader`, preference key, or preference observer.

### 7. Narrow observable application state

`WarrenRemoteApplicationModel` remains the application store, but renderer
objects and control-plane details are observation-ignored.

- Compare a new projection with the current projection before publishing it.
- Split unrelated endpoint, web, navigation, and roster state when one update
  would otherwise invalidate the entire desktop.
- Do not expose `TerminalViewState` as an observed dependency of the desktop
  root.
- Route resize and focus through the surface manager without publishing them
  to SwiftUI.
- Publish terminal metadata only after equality checks and event coalescing.

Periodic roster events must not trigger a full desktop layout when the UI
projection is unchanged.

### 8. Keep diagnostics passive

Production diagnostics may record lifecycle counters and transition events.
They must not add layout readers or preference observers.

Required counters include:

- active, warm, and cold surface counts;
- surface transition generation;
- stale command cancellation count;
- surface creation and disposal count;
- hidden render attempt count;
- projection publication count.

Hot render paths use counters or rate-limited signposts instead of synchronous
file writes.

## Required invariants

The implementation must maintain these invariants:

1. Exactly one surface may be active in a window.
2. Only the active surface may be visible, focused, rendered, or resized.
3. `body`, layout callbacks, and `updateNSView` never perform Ghostty work or
   publish application state.
4. Geometry observation never changes the geometry being observed.
5. Every asynchronous native command is cancelable by generation.
6. Surface memory is bounded independently from the number of open sessions.
7. An unchanged daemon projection produces no SwiftUI publication.
8. Production semantic observation adds no layout nodes.

## Rejected alternatives

### Keep all surfaces in a SwiftUI ZStack

This preserves renderer state but makes layout, memory, and native view work
grow with session history. Hidden native views also remain coupled to SwiftUI
reconciliation. The architecture is rejected.

### Recreate the active surface on every switch

This gives the UI one native view but causes replay, first-frame delay, and
loss of renderer-local state. It remains the fallback for cold sessions, not
the normal switching path.

### Fix each callback with another asynchronous hop

An executor hop is not a SwiftUI frame boundary. Independent retries also
create ordering races and stale work. Scheduling belongs to one state machine.

### Keep PreferenceKey measurement and add more equality checks

Equality checks reduce publications but do not remove circular layout
dependencies or unstable coordinate-space identity. The layout decision must
be derived without a feedback loop.

## Migration plan

### Phase 1: Contain current feedback loops

- Disable semantic geometry when no recorder is injected.
- Replace tab overflow preference state with pure width derivation.
- Collect sidebar row frames only during drag.
- Cancel stale focus, fit, refresh, and present tasks.
- Apply Ghostty visibility and occlusion when a surface is hidden.
- Skip equal projection publications.

### Phase 2: Add the surface registry and state machine

- Move surface ownership out of `WarrenRemoteApplicationModel` and SwiftUI.
- Implement active/warm/cold transitions with pure state-machine tests.
- Route output and anchors through the registry.
- Preserve the existing UI while the registry initially uses the current host.

### Phase 3: Replace the surface ZStack with one host

- Add `TerminalHostRepresentable`.
- Attach only the active native view.
- Park warm views outside the window.
- Remove per-surface `FocusState`, window probes, and independent retry loops.

### Phase 4: Enforce resource budgets

- Add LRU eviction by count and measured memory.
- Validate cold-session replay from the stored output anchor.
- Tune the default warm budget from Instruments data.

## Implementation

The desktop now uses this design.

- `TerminalSurfaceManager` is created at the composition root and excluded
  from Swift Observation.
- `TerminalHostRepresentable` owns one stable AppKit container. Its update
  method submits intent only; reconciliation runs on a later main-loop turn.
- The manager retains one active surface and up to eight warm surfaces. It also
  enforces a count and estimated warm-surface budget using triple-buffered BGRA
  viewport cost.
- Warm views are occluded, unfocused, detached from their window, and kept by
  the manager registry. LRU eviction disposes their renderer resources.
- Production semantic observation installs no geometry readers unless UIProbe
  injects a recorder.
- Tab overflow uses a structurally stable track and AppKit scroll-edge
  observation. Sidebar row geometry exists only while a drag is prepared or
  active.
- Equal desktop projections are discarded before observation publication.
- Automated tests cover native active/warm reattachment, count and memory
  eviction, deferred host mutation, and 500 consecutive native switches.

## Verification

### Automated checks

- State-machine tests cover every valid transition and reject stale
  generations.
- An `NSHostingView` integration test switches sessions and resizes across the
  tab-overflow threshold without unbounded updates.
- A native host test proves `updateNSView` performs no Ghostty operation.
- Projection tests prove identical rosters do not publish.
- UIProbe tests prove semantic geometry exists only with an injected recorder.
- A stress test performs at least 500 workspace and tab switches.

The stress run fails on any of these unified-log messages:

- `Publishing changes from within view updates`;
- `Bound preference ... tried to update multiple times per frame`;
- `onChange(of: CGSize) action tried to update multiple times per frame`.

### Runtime acceptance

- Hidden render attempts remain zero.
- Warm surface count never exceeds the configured budget.
- Main-thread work returns to idle after a switch settles.
- Surface memory remains bounded while opening and visiting more sessions.
- A sampled switch contains no repeated `ViewGraph` update loop and no
  Ghostty call under AppKit view-tree attachment.

## Consequences

The design adds a dedicated manager and explicit state machine. This is more
code than the current view-local approach, but it removes timing ownership
from SwiftUI and makes native transitions deterministic.

Most switches remain instant while the resource cost is bounded. A session
evicted to cold state may require bounded replay, which is an explicit and
measurable trade-off instead of unbounded background rendering.
