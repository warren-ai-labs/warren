# RFC 0008: Desktop split windows for independent terminal Sessions

- Status: Implemented
- Owner: Warren Desktop, Ghostty Adapter, and Headless
- Created: 2026-08-25
- Scope: macOS Desktop presentation for Warren Terminal Sessions

## Summary

A Desktop split window is a client-local arrangement of independent Warren
Terminal Sessions. It is a window-level layout, not a second kind of Warren
Session and not a split nested inside one Host-owned Tab. Every leaf owns one
stable presentation Pane and displays one existing Desktop Tab, which in the
current projection maps one-to-one to a running Warren Session and its PTY.

```text
Desktop window, Workspace scope
└── Split (left/right, 50/50)
    ├── Pane -> Tab A -> Session A -> PTY A -> Ghostty surface A
    └── Split (top/bottom)
        ├── Pane -> Tab B -> Session B -> PTY B -> Ghostty surface B
        └── Pane -> Tab C -> Session C -> PTY C -> Ghostty surface C
```

Two leaves never mirror one PTY. A Session has one terminal viewport, input
stream, recovery anchor, and runtime lifecycle. A native split creates or
places another Session instead of trying to render one Session at two sizes.

The layout is local to one Desktop window and one Session scope. Headless
persists no Pane tree and does not need to understand the layout. Web and CLI
continue to see ordinary Host Sessions.

## Ownership and invariants

| Resource | Owner | Shared across clients |
| --- | --- | --- |
| Project, Workspace, Terminal Group | Headless Host | Yes |
| Warren Session, Runtime binding, and PTY | Headless Host/runtime | Yes |
| Tab projection | Desktop client model | No |
| Pane tree, ratios, and active Pane | Desktop window | No |
| Ghostty surface and AppKit host view | `TerminalSurfaceManager` | No |
| Screen-session report | Authenticated WebSocket peer | No |
| Output anchor and terminal viewport authority | Host protocol per Session | Per Session |

The implementation preserves these invariants:

1. Each leaf has one non-empty Pane ID and one unique Tab ID.
2. Every leaf in a tree belongs to the current Workspace or Terminal Group.
3. A leaf is attached only while its Session is running and present in the
   current Host roster.
4. A Session appears at most once in a window's visible tree.
5. Splitting and closing never silently moves a Session or changes its runtime.
6. Only the active Pane receives local keyboard focus and the control lease;
   sibling Panes receive passive output and recovery updates.
7. Output and recovery state is keyed by Session ID, never by Pane ID.
8. The visible tree contains at most four Panes.

## Layout model and persistence

`Packages/Desktop` stores an immutable recursive value:

```swift
indirect enum SplitLayoutTree {
    case leaf(SplitPaneItem)       // stable paneID + projected tabID
    case split(
        axis: SplitAxis,           // horizontal = left/right
        ratio: Double,             // first child share
        first: SplitLayoutTree,
        second: SplitLayoutTree
    )
}
```

The ratio is normalized when decoding and encoding. Interactive changes are
clamped to safe bounds and the renderer also derives minimum ratios from the
actual child geometry, so a divider cannot intentionally create a zero-column
or zero-row terminal. A divider is addressed by an immutable child path:
`false` descends to `first`, and `true` descends to `second`. Paths follow the
same tree-addressing idea as Ghostty's split tree and are not guessed from a
preorder index after a nested split is added.

Layouts are stored in device-local `UserDefaults` under
`warren.desktop.splitLayouts`. Keys include the selected endpoint and scope,
such as `endpoint-<endpoint>-workspace-<UUID>` and
`endpoint-<endpoint>-terminalGroup-<UUID>`, so a Session ID from one Host can
never be rebound to another Host's layout. Restoring a layout validates it
against the current scope's running Tabs, removes invalid or duplicate leaves,
collapses empty parents, normalizes ratios, and falls back to the selected
running Tab. Persisted output, commands, credentials, working directories,
and PTY state are never copied into the layout.

The endpoint prefix is a new namespace boundary. Older unprefixed layout keys
are intentionally not migrated or interpreted because their Host ownership is
unknown; the first restore after this change starts from the selected running
Tab and writes only the endpoint-scoped form.

Reconciliation also drops layouts whose Workspace or Terminal Group no longer
exists, so the store does not grow forever. Only the current endpoint's scopes
are evaluated: another endpoint's Workspaces are absent from this projection
and must not be read as deleted. Writes are coalesced over a short quiet
period, because a divider drag republishes a new ratio on every pointer event
and would otherwise run one JSON encode plus one `UserDefaults` write per frame.

Window minimum size follows the tree, but stops at two Panes per axis. Using
the exact four-Pane minimum would force the user's window to grow past a
comfortable size; divider clamps still use the exact per-subtree minimums.

The layout root belongs to the current window scope, not to a `ClientTab`.
Selecting a Tab already present in the tree focuses its Pane. Selecting an
unrelated Tab exits the current split and makes that Tab the sole Pane; this
prevents a newly selected Tab from appearing beside stale Sessions.

## Split, drag-and-drop, close, and focus semantics

### Split Right and Split Below

The command captures the current scope and active Pane, then requests a new
Shell Session in that same Workspace or Terminal Group. The tree is unchanged
while creation is pending. Once the roster confirms a newly created running
Tab (and the normal creation flow has selected it), the client inserts a 50/50
child split, focuses the new Pane, and lets the normal attachment pipeline
mount its Session. A failed or cancelled creation leaves the previous tree
intact; a bounded pending-operation timeout prevents a stuck command from
blocking later splits.

The request uses ordinary Host Session creation. The new process starts at the
Workspace path or Terminal Group home, just like any other new Shell Session;
the client does not synthesize `cd` commands or replay input.

### Drag and drop

Dragging an existing Tab onto a Pane can place it above, below, left, or right
of that Pane, or replace the Pane at the center target. The drop is accepted
only for a running Session in the current scope and never adds a duplicate
Tab/Session. Invalid, cross-scope, ended, or stale drops are ignored. A
directional drop changes only the local tree; it does not create or terminate
a Host Session.

### Close and maximize

Closing a Pane requests termination of that Pane's Session. The leaf remains
visible until the Host roster confirms that the Tab has disappeared, so a
failed delete cannot leave a hidden running process or falsely claim success.
The parent split then collapses to its surviving child and the nearest
surviving Pane is selected. A single remaining Pane follows the ordinary Close
Tab action. Maximize keeps the chosen leaf as the root without changing the
Session lifecycle. Pending close operations are bounded and are also
reconciled when the user changes scope.

`Cycle Pane Focus` walks the tree's stable leaf order. The layout model also
provides geometry-based nearest-Pane lookup with optional wrapping, so future
directional focus commands can use visual adjacency rather than tree order. The
directional lookup is currently a model capability only; no directional menu or
keyboard command is claimed as implemented by this RFC.

### Commands and key bindings

Every split command is a View menu item that posts a notification; the Desktop
root resolves the current scope and Pane when it receives one. The default
bindings are Command shortcuts, so no keystroke is taken away from the shell:
Split Right `⌘D`, Split Below `⇧⌘D`, Close Split Pane `⇧⌘W`, Maximize Pane
`⇧⌘↩`, Cycle Pane Focus `⌘]`.

The Emacs chords `C-x 2/3/0/1/o` are available as an opt-in preference
(Settings › Splits, `terminal.splitChordsEnabled`, off by default). They are
not on by default because the prefix is captured application-wide: while the
chord is enabled `C-x` never reaches the terminal, which would silently break
nano, an in-terminal emacs, and a tmux `C-x` prefix. `C-g` cancels a pending
chord and `C-x C-x` sends a literal `Ctrl-X`. The monitor also declines to
capture while an AppKit text control is first responder, and cancels any
pending chord in that case.

### Selecting a Pane by clicking it

Only the selected Pane owns the input router and the control lease, so a click
into a passive Pane must change that selection. Clicks inside a terminal are
routed by AppKit, not SwiftUI: the terminal view becomes first responder, and
`TerminalSurfaceManager` reports that through `onFocusRequested`. The owner
answers by selecting that Session's Tab, which moves the active Pane, the input
router, and the control lease together. Clicks in Pane chrome use a
simultaneous SwiftUI gesture so the same click still reaches the terminal.

Keyboard pane cycling takes the mirror-image path. Focus reconciliation refuses
to steal first-responder status from an unrelated responder, which would
otherwise make a command that moves focus between two mounted terminals a no-op:
the sibling still holds the responder. A peer terminal view in the same window
is therefore an allowed transfer, while SwiftUI and AppKit chrome stay
protected. Every reconciliation carries the reason that scheduled it — a new
visible set, an unmounted host, a deferred present, a recovery — so a focus
claim in a split window remains attributable in diagnostics.

The drop zones layered over a terminal must never take a hit-test shape. A
transparent-but-hit-testable overlay makes the SwiftUI host answer every click
over the terminal body, which breaks click-to-position, selection drags, and
terminal mouse reporting. A regression test pins this by hit-testing the
overlay against a hosted AppKit view.

## Desktop rendering

`WarrenDesktopSplitTreeView` recursively renders the tree with a
`GeometryReader`. A split allocates the first and second child from the
persisted ratio, inserts one draggable divider, and passes the divider's child
path to the resize callback. A leaf renders the existing pane header, focus
indicator, close/maximize controls, drag/drop overlay, and one terminal
surface. Divider values expose an accessibility percentage and an adjustable
action; dragging and keyboard adjustments use the same clamped ratio path.

A drag latches onto an even split within a pull radius measured in points, not
in ratio space, so the pull feels the same at any pane width. The radius is
small enough that a deliberate drag past it still tracks the pointer exactly.
A snap nobody can see is a snap that reads as a stuck divider, so the affordance
is shown rather than inferred: hovering the divider draws a dashed guide at each
reachable target, latching brightens that guide and widens the rule into a glow,
and the trackpad taps the system alignment feedback once as it catches. Targets
outside the divider's clamp range are dropped from both the guides and the
latch, since the divider could never come to rest there.

The split root is tagged with `SplitLayoutTree.structuralIdentity`, following
Ghostty's `TerminalSplitTreeView` convention. This identity includes each
leaf's Pane/Tab identity and every split axis, but deliberately excludes
ratios. Inserting, removing, replacing, or maximizing a leaf therefore rebuilds
the recursive SwiftUI structure, while a divider drag preserves the mounted
AppKit terminal hosts and only changes their frames.

The rendering model follows the useful properties of Ghostty's native
`SplitTree`:

- immutable tree transformations return a new tree rather than mutating
  sibling nodes in place;
- a leaf has presentation identity separate from the execution Session;
- split ratios describe the first child's share of the available rectangle;
- geometry is computed recursively, making spatial navigation independent of
  window size;
- removing a leaf collapses redundant parent nodes deterministically.

The Desktop cap of four visible Panes is a product and performance boundary,
not an arbitrary persistence limit. Raising it requires new rendering and
transport measurements.

## Terminal surfaces and output flow

`TerminalSurfaceManager` is the sole owner of AppKit terminal views. It keeps
one `GhosttySurface` and one terminal view per retained Session, while a
per-Session host map binds each visible Session to exactly one
`TerminalHostContainerView`. Those host references are weak: SwiftUI may drop a
pane without a final `disconnect`, and the manager must not become the last
owner of a dismantled host and its surface. Reconciliation is scheduled on a
later main-loop turn; SwiftUI's `body`, layout, and `updateNSView` only submit
immutable intent.

The manager supports a set of active Session IDs for a split window:

- the intent that explicitly wants keyboard focus is the primary Session;
- passive sibling intents cannot become primary merely because SwiftUI updates
  them later;
- a Session cannot be mounted into two hosts in one window;
- replacing a host for one Session does not demote or remount its siblings;
- warm surfaces retain bounded native state and are promoted without replaying
  a second Session's output;
- disposal invalidates the Session's host, intent, callbacks, and recovery
  resources.

The active set is explicit even while terminal hosts remain mounted under the
embedded editor. Entering editor mode parks those hosts as warm surfaces and
reports an empty screen set; returning to terminal mode reactivates the same
hosts without creating a second PTY viewport.

Warm promotion of a retained surface stays limited to remote endpoints, as
before this feature; a local endpoint keeps taking the cold seeding path. This
RFC does not change that boundary, and neither path duplicates the Session's
PTY.

Promoting a retained sibling has to claim the control lease, because siblings
were seeded without one. That claim is gated on the surface actually owning
keyboard focus in a key window, exactly like the cold seeding path: an unfocused
window switching panes must not take input and resize authority away from
another client viewing the same terminal. The claim is one `session.focus`, not
a control-only alias: the client tracks a single leased Session and replays that
claim (with its viewport) after a reconnect, so a lease taken outside `focus`
would let a reconnect reclaim the sibling that used to hold it and hand the
shared runtime the wrong geometry. A pane that gains keyboard focus only after
the promotion sends the same request from its parked focus report.

Each visible leaf receives output through the remote model's Session-keyed
subscription. The selected Session additionally requests the control lease and
local focus. Siblings use passive `session.subscribe` recovery with
`claimControl=false`; their snapshots, framed output, anchors, and rendering
fail independently. A promotion waits only briefly for an in-flight background
seed of the same Session and then falls through to the cold path, so a hung
seed cannot leave the selected pane unattached. A sibling failure must not disconnect or blank the
selected Pane. Terminal search is bound to the currently focused Session, not
shown simultaneously in every leaf.

When the workspace's embedded editor is selected, the terminal tree remains
mounted for fast return but no terminal Session is reported as screen-visible;
its surfaces become warm retained state until terminal mode is selected again.

## Session lifecycle and roster reconciliation

The Host roster remains authoritative. The Desktop reconciles the persisted
tree whenever Tabs change:

- a removed or ended Session is pruned from its leaf and its parent collapses;
- a Session moved to another Workspace or Terminal Group cannot remain in the
  old scope's tree;
- Sessions created by CLI, Web, another Desktop window, or an older client
  appear as ordinary unsplit Tabs until explicitly placed in this window;
- selecting a Tab outside the tree exits the split rather than silently
  replacing an arbitrary leaf;
- selected and sibling surfaces are retained only while their Session remains
  live in the projection.

The split creation and close paths deliberately wait for roster confirmation.
This keeps local presentation state and Host process lifecycle in lockstep
across delayed responses, reconnects, and another client's mutations.

## Per-peer screen reporting

The Desktop reports the sorted set of currently visible Session IDs through
`screen.report`. This is presentation telemetry, not a new Host resource. The
client retains the latest set and re-sends it after a new WebSocket is
authenticated, because a reconnect creates a fresh peer even when the visible
Session IDs did not change.

The daemon stores that list on the authenticated `wsPeer`, not on the global
HTTP server. Each report is deduplicated and accepts only Sessions that still
exist and have `Lifecycle == "running"`. Ended and deleted Sessions are removed
lazily on read, and closing a peer clears its screen state. Two Desktop windows
connected to one daemon therefore never overwrite one another's screen list.

Reads cross peers, because the client that asks is usually not the client that
reported. A CLI invoked inside a Session opens its own short-lived connection
and has no screen of its own, so answering from the asking peer would always say
"nowhere". `screen.panes` returns one entry per connected screen that displays
the queried Session, ordered most recently reported first and tie-broken by
client ID so repeated calls agree. Several windows may display one Session at
once, which is why the answer is a list rather than a single layout.

The two reads disclose different amounts on purpose. `session.current` carries
only `screenPosition` and `screenPaneCount` — where this Session's own output
sits — and never the sibling IDs, so a Session cannot enumerate what else is on
the user's screen as a side effect of asking about itself. Learning who shares
the screen is the separate, explicit `screen.panes` request.

The screen list has its own peer mutex rather than sharing the outbound queue's
lock, because reconciling it requires Session lookups that take the service
lock. Those lookups run outside the mutex, so the lazy write-back is guarded by
a generation counter: a concurrent `screen.report` bumps the generation and its
list wins over the stale filtered copy.

## Failure, recovery, and compatibility

- A pending split or close expires without changing a tree if the Host request
  fails or no confirming roster transition arrives.
- A missing/ended Session is never attached from restored layout data.
- Recovery anchors are independent per Session; a late marker for one Pane
  cannot reveal or reset another Pane.
- Warm split demotion deliberately preserves the native Ghostty viewport. The
  manager does not synchronously read grid text to create a reattach anchor,
  because that read can contend with the background output drain on the main
  actor; protocol recovery remains the authoritative resync path.
- A resize is derived from the owning Pane's measured host geometry. Only the
  focused Session may claim the shared runtime control lease.
- Desktop is the only client that renders this tree. Headless, Web, and CLI
  keep their existing Session-level behavior and do not persist Pane layout.
- The first render remains one ordinary terminal until the user invokes a
  split or places another existing Tab into the window.

The feature adds no protocol version solely for layout. Existing
`session.subscribe`, control-lease, recovery, and output envelopes remain
Session-addressed. A future transport can multiplex more explicitly, but it
must preserve the Session-keyed ownership and recovery boundaries above.

## Verification and performance boundary

The implementation is covered by focused tree, surface-manager, and
screen-report tests. These checks exercise the value model, AppKit lifecycle,
and protocol state transitions; they do not replace a running macOS AppKit
pixel/interaction capture of a real split window. Full validation should
include:

```sh
swift test --package-path Packages/Desktop
swift test --package-path Packages/GhosttyAdapter
go test ./Headless/...
```

Before raising the four-Pane cap, measure one- and four-Pane steady and burst
output latency, Ghostty/AppKit CPU and memory, output traffic, recovery time,
divider-drag responsiveness, and battery impact. The implementation must not
encode or persist the entire tree for every PTY frame, and passive sibling
subscriptions must remain bounded by the visible-Pane cap and normal surface
retention policy.

`screen.report` is presentation telemetry owned by each authenticated WebSocket
peer. It is not a durable Host resource and must not be used as the lifecycle
authority for Sessions or PTYs.
