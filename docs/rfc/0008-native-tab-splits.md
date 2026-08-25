# RFC 0008: Native split panes within a client Tab

- Status: Deferred
- Owner: Warren Client Core, Desktop, Ghostty Adapter, and Headless
- Created: 2026-08-25
- Priority: Low; no target release
- Scope: device-local split layout for multiple Warren Terminal Sessions

## Summary

Warren may add native split panes inside one client Tab. A split Tab is a
device-local layout container whose leaf Panes each reference a distinct
Warren Terminal Session. Every referenced Session keeps its existing Host
ownership, Runtime Binding, PTY, output recovery stream, and lifecycle.

```text
Client Tab
└── Split (left/right)
    ├── Pane -> Warren Terminal Session A -> PTY A
    └── Split (top/bottom)
        ├── Pane -> Warren Terminal Session B -> PTY B
        └── Pane -> Warren Terminal Session C -> PTY C
```

Two Panes do not share one PTY, and Warren does not expose tmux windows or
panes as Warren domain resources. Rendering one PTY twice would be mirroring,
not splitting: both views would compete over terminal size, focus, input, and
cursor state.

This RFC records the intended boundary so a later implementation does not
grow an accidental second terminal model. The feature is deliberately
deferred. The current workaround is to run tmux as the foreground application
inside a ghostline-backed Warren Shell Session.

## Status and scheduling

`Deferred` means:

- no implementation is scheduled;
- the RFC does not reserve a release or create a compatibility commitment;
- current clients continue to present one Session per Tab;
- implementations must not partially expose the models or protocol described
  here without first moving the RFC back to `Proposed` and reviewing it
  against the then-current architecture.

Native splits are a convenience feature, not a prerequisite for durable
Sessions, remote access, Agent workflows, or terminal correctness. The tmux
workaround covers the immediate interactive need well enough that retention,
recovery, correctness, and performance work take precedence.

## Current workaround: tmux inside ghostline

Use the default and recommended `ghostline` runtime for the Warren Session,
then start a normal interactive tmux client inside that Shell:

```sh
tmux new-session -A -s warren
```

With the default tmux prefix:

- `Control-b %` creates a left/right split;
- `Control-b "` creates a top/bottom split;
- `Control-b` plus an arrow key changes the active tmux pane;
- `Control-b d` detaches while leaving tmux processes running.

This workaround is intentionally an application inside one Warren PTY.
Warren sees one Session, one foreground tmux client, one output stream, and
one terminal viewport. tmux owns the nested pane layout and process lifecycle.

Warren's alternative `tmux` runtime is not the same workaround. That adapter
maps one Warren Session to one tmux session and intentionally streams only its
first pane. Native Warren splits must not depend on discovering or projecting
the adapter's internal tmux panes. Running a nested interactive tmux client is
therefore recommended only in a ghostline-backed Warren Session.

Known limitations of the workaround are acceptable while this RFC is
deferred:

- Warren cannot name, focus, close, recover, or observe individual tmux panes;
- Agent activity and terminal metadata remain Session-level;
- Desktop and Web receive tmux's composed terminal screen, not a structured
  split tree;
- tmux configuration and key bindings remain the user's responsibility.

## Motivation

Tabs are efficient for switching between full terminal contexts. They are
less efficient when two or more processes must remain visible together, for
example:

- an editor or Agent beside a test runner;
- a service log beside an interactive shell;
- two independent Agents operating in the same Workspace;
- a build, debugger, and Git inspection shell shown at once.

A native split would let Warren preserve per-Pane titles, activity, focus,
viewport size, recovery, and lifecycle while keeping the processes visually
grouped in one Tab. It would also avoid requiring tmux knowledge for a basic
client layout operation.

The feature is not a request to split one Shell process. A Shell is a process
inside a PTY; a native split creates another Session and another PTY.

## Goals

- Represent a recursive left/right and top/bottom Pane layout inside a Tab.
- Bind every leaf Pane to exactly one Warren Terminal Session.
- Preserve the existing one Session to one Runtime Binding and PTY invariant.
- Keep Tab, Pane, split ratio, and focused-Pane state device-local.
- Allow all Panes in the selected Tab to render and recover independently.
- Route keyboard input, search, focus, and resize to the intended Pane only.
- Create a new Shell Session in the same Session Scope when the user splits a
  Pane.
- Collapse redundant split nodes deterministically after a Pane closes.
- Keep unsplit Tabs and other Warren clients behaviorally compatible.
- Bound visible Pane count and rendering cost before enabling the feature by
  default.

## Non-goals

- Exposing tmux sessions, windows, or panes as Warren Pane resources.
- Sharing one PTY, Runtime Session, terminal emulator, or Agent Conversation
  between multiple Panes.
- Synchronizing split geometry, focused Pane, or divider position across
  devices.
- Allowing Panes from different Workspaces or Terminal Groups in one Tab in
  the first implementation.
- Dragging an existing Tab into a split in the first implementation.
- Restoring a child Shell by inferring or replaying `cd` commands.
- Changing Runtime persistence or making a split Tab a Host-owned resource.
- Implementing native splits in Desktop and Web simultaneously.
- Removing or deprecating the tmux runtime or the nested tmux workaround.

## Ownership and invariants

The ownership boundary is:

| Resource | Owner | Shared across clients |
| --- | --- | --- |
| Project, Workspace, Terminal Group | Host | Yes |
| Warren Terminal Session | Host | Yes |
| Runtime Binding and PTY | Host Runtime | Yes |
| Tab, Pane tree, split ratio | Client Window Layout | No |
| Focused Pane | Client Window Layout | No |
| Attachment and viewport authority | Host protocol, per Session | Temporary |

The following invariants are mandatory:

1. One Pane leaf references one Session ID.
2. One Session appears at most once in one Window's visible Pane tree.
3. Every Pane in a Tab belongs to the same Workspace or Terminal Group.
4. A split mutation never changes a Session's Host scope or Runtime Binding.
5. A layout mutation cannot create, terminate, or move a Runtime implicitly;
   the corresponding typed Host operation must succeed first.
6. A missing or ended Session cannot remain an interactive Pane.
7. Only one Pane in a Window receives local keyboard focus.
8. Output and recovery anchors remain keyed by Session ID, never Pane ID.

Pane ID is presentation identity. Session ID remains execution identity. A
Pane may be replaced without changing a Session, while a new Shell always
gets a new Session ID and Pane binding.

## Client layout model

The current `ClientPane` placeholder is a flat Workspace-level array and the
current `ClientTab` directly stores a Session ID. Native splits require the
layout root to belong to the Tab:

```swift
public struct ClientTab: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var root: ClientPaneNode
}

public struct ClientPane: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var sessionID: TerminalSessionID
}

public indirect enum ClientPaneNode: Codable, Hashable, Sendable {
    case leaf(ClientPane)
    case split(
        id: String,
        axis: ClientSplitAxis,
        ratio: Double,
        first: ClientPaneNode,
        second: ClientPaneNode
    )
}

public enum ClientSplitAxis: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}
```

Axis names describe the divider: a vertical divider creates left/right
children and a horizontal divider creates top/bottom children. User-facing
commands should use `Split Right` and `Split Down` to avoid that ambiguity.

The persisted ratio is the first child's share of available space. Decoding
normalizes non-finite or out-of-range values to `0.5`; interaction clamps the
ratio according to the minimum Pane size instead of a fixed percentage.

### Migration

An existing Tab with `sessionID = S` migrates to:

```text
Tab(root: leaf(Pane(sessionID: S)))
```

Existing Workspace-level `panes` arrays are not evidence of a valid split
tree and must not be guessed into one. Empty legacy arrays decode as an
unsplit layout; non-empty legacy data must be validated and migrated through
one explicit schema version.

The migration must be atomic and idempotent. An older client that cannot
decode the new layout schema must preserve or reject it, not overwrite it with
an unsplit layout.

## Roster and Tab reconciliation

Host rosters contain Sessions, not Tabs or Panes. The client reconciler uses
these rules:

1. A running Session already referenced by a local Pane is not also projected
   as a separate Tab.
2. A running Session not referenced by local layout becomes a new unsplit Tab.
   This covers Sessions created by CLI, Web, another Desktop, or an older
   client.
3. An ended or removed Session turns its Pane into a non-interactive ended
   presentation when durable Session memory is available; otherwise the Pane
   is removed and its parent split collapses.
4. If an external operation moves one Pane's Session to another scope, the
   client removes that leaf from the source Tab and creates an unsplit Tab in
   the destination scope. A Tab never silently spans scopes.
5. Reconciliation preserves stable Pane and Tab IDs for unaffected nodes.

Session creation for a split carries an idempotent request ID and a pending
local placement. A roster event may arrive before the creation response; the
pending placement prevents the new Session from briefly appearing as a
second Tab.

## Split and close operations

### Split Right and Split Down

Splitting the focused Pane is a coordinated operation:

```text
capture focused Pane, Tab, scope, and request ID
-> request a new Shell Session in that captured scope
-> wait for the Host result
-> replace the focused leaf with a 50/50 split
-> bind the new leaf to the returned Session ID
-> attach and focus the new Pane
-> persist the Client Window Layout
```

If Session creation fails, the layout remains unchanged. A completion never
derives its target from the user's later selection.

The first implementation starts the new Shell at the Workspace path or
Terminal Group home, matching ordinary Session creation. Inheriting the
active Pane's current directory requires a future typed `cwd` launch field
validated by Headless. Clients must not send `cd`, synthesize keystrokes, or
interpolate runtime metadata into a shell command.

### Close Pane

Closing a Pane retains Warren's current destructive close semantics:

```text
terminate referenced Session
-> confirm the Host lifecycle transition
-> remove the leaf
-> replace its parent split with the surviving sibling
-> select the nearest surviving Pane
-> persist layout
```

If termination fails, the Pane stays in place and presents the error. Closing
the last Pane closes the Tab. A separate `Close Tab` action attempts to
terminate every live Session in the Tab; successfully ended Panes disappear,
but any failed Pane keeps the Tab open so partial failure is visible.

A future detachable layout may add `Remove Pane without terminating`, but it
is not part of this RFC.

## Desktop presentation and interaction

The Desktop recursively renders the Pane tree. Each leaf keeps the existing
Pane header and terminal presentation. Each split owns one draggable divider
and enforces the design system's minimum terminal width and height.

Recommended commands are:

| Command | Default shortcut |
| --- | --- |
| Split Right | `Command+D` |
| Split Down | `Shift+Command+D` |
| Focus Pane Left/Right/Up/Down | `Option+Command+Arrow` |
| Close Pane | `Command+W` |
| Close Tab | no destructive default until interaction review |

Shortcuts remain subject to a conflict audit against Ghostty, macOS, search,
and Agent input behavior before implementation. Menu commands and command
palette actions are authoritative; key bindings are conveniences.

Interaction requirements:

- clicking a Pane gives only that Pane the local first responder;
- focus movement uses geometric neighbors, not tree traversal order;
- an active Pane has a non-color-only focus indicator;
- dividers are keyboard adjustable and expose accessibility values;
- loading, reconnecting, ended, and failed states render per Pane;
- a Pane below minimum size does not create a zero-column or zero-row PTY;
- Tab title fallback uses the focused Pane's effective Session title;
- terminal search opens in and searches only the focused Pane.

The first implementation should cap one Tab at four Panes. Raising the cap
requires performance evidence rather than a settings-only change.

## Attachments, input, output, and viewport

The current Desktop and WebSocket peer each track one attached Session. A
native split requires several visible Sessions to receive output concurrently.

The client should introduce a `TerminalChannel` boundary keyed by Session ID.
Each channel owns:

- attachment and control state;
- pending ordered input;
- output recovery anchor;
- latest-wins resize buffering;
- reconnect and error state.

The initial implementation may use one control/roster WebSocket plus one
terminal WebSocket per visible Pane. That works with the current one-attached-
Session peer contract, limits protocol risk, and bounds connection count with
the four-Pane cap. Hidden Tabs detach their terminal channels while retaining
bounded warm render surfaces and recovery anchors.

The `TerminalChannel` interface must not expose the one-WebSocket-per-Pane
choice. A later protocol may multiplex explicitly addressed attach, input,
focus, resize, and detach messages over one connection. Binary input and
output envelopes already carry Session identity; raw implicit-session input
must not be extended as the multiplexed contract.

Every visible Pane has an independent Runtime viewport because it references
a distinct Session. Only the focused Pane accepts local keyboard input. Host
viewport authority remains per Session, so visible local Panes do not compete
with one another; another client observing the same Session may still own its
canonical viewport. The implementation review must define how inactive local
Panes represent a remotely owned viewport without stealing control merely
because a split Tab became visible.

## Terminal surface management

`TerminalSurfaceManager` must evolve from one active Session and one host view
to a set of visible placements:

```swift
struct TerminalSurfacePlacement {
    let paneID: String
    let sessionID: TerminalSessionID
    let host: TerminalHostContainerView
    let viewportSize: CGSize
    let wantsKeyboardFocus: Bool
}
```

The manager retains one Ghostty surface and AppKit view per Session, attaches
every visible placement, and keeps exactly one local first responder. Visible
surfaces are not counted against the warm hidden-surface limit. A Session may
not be mounted into two hosts in the same Window.

Reconciliation remains one-way: SwiftUI submits immutable placement intent;
the manager performs AppKit mount, hide, focus, and disposal operations on a
later main-loop turn. Split layout callbacks must not synchronously tear down
Ghostty views. This preserves the rendering and deadlock protections defined
by RFC 0002 and the terminal runbooks.

## Failure and recovery behavior

- Failure to attach one Pane does not disconnect or blank its siblings.
- Output backpressure or channel failure is isolated per terminal connection.
- Reconnect uses that Pane's Session-keyed recovery anchor.
- A stale attach, resize, or creation completion validates Pane, Session,
  scope, and operation generation before mutating layout.
- Switching Tabs detaches hidden terminal channels without ending Runtimes.
- Host restart rebuilds visible channels independently and reconciles missing
  Sessions before restoring focus.
- Client restart restores the Pane tree, then treats the Host roster as the
  authority for Session existence and lifecycle.

## Compatibility and rollout

The first implementation is Desktop-only and capability-gated. Headless does
not persist Pane layout and does not advertise tmux panes. Web and CLI continue
to show every Host Session independently; a Session grouped into a Desktop
split may therefore appear as an ordinary Tab or list item elsewhere.

Rollout order, after this RFC is reactivated, is:

1. Client layout schema, migration, normalization, and tree mutation tests.
2. Roster-to-layout reconciliation and pending split placement.
3. Per-Session terminal channels and simultaneous attachment tests.
4. Multi-placement Ghostty surface management.
5. Recursive Desktop layout, commands, accessibility, and error states.
6. Performance qualification and opt-in release.

No server-side Runtime or state migration is required for the core model.
Protocol multiplexing, if later selected, requires its own versioned change.

## Performance expectations

Native splits add work to rendering and output paths. Qualification must
measure, with one and four visible Panes:

- steady-state and burst output latency;
- main-thread and renderer CPU;
- Ghostty surface, grid, scrollback, and GPU memory;
- WebSocket count, output traffic, and reconnect time;
- divider-drag responsiveness and resize request rate;
- battery impact during continuous background output.

The implementation must preserve latest-wins resize buffering and bounded
surface retention. It must not perform persistence writes, tree encoding, or
full-roster reconciliation on every PTY output frame.

## Security and privacy

Pane layout stores only local presentation IDs, ratios, and Host Session IDs.
It does not duplicate PTY output, commands, environment variables, transcript
paths, credentials, or working-directory metadata into the Client Layout
Store.

A Session ID received from persisted layout is validated against the active
Host roster and scope before attachment. A layout restored for one endpoint
must never bind the same textual ID against another endpoint without an
endpoint-scoped Client Layout identity.

## Acceptance criteria

The RFC may move from `Deferred` to `Proposed` only when an implementation plan
can demonstrate all of the following:

1. Existing unsplit Tabs migrate without changing Session or Runtime
   lifecycle.
2. A split creates a distinct Session and PTY in the captured scope.
3. Four visible Panes receive simultaneous output without cross-routing,
   truncation, duplication, or global disconnect on one Pane's failure.
4. Input, search, local focus, and title fallback follow the focused Pane.
5. Each Session receives resize events derived only from its own Pane and
   canonical viewport authority.
6. Closing one Pane terminates only its Session and collapses the tree
   deterministically.
7. External Session creation, removal, ending, and scope movement reconcile
   without duplicate Tabs or mixed-scope split trees.
8. Client and Host restart recover every surviving Pane from its own output
   anchor.
9. Keyboard, pointer, accessibility, loading, error, empty, and reconnecting
   states pass interaction review.
10. Four-Pane performance stays within documented CPU, memory, I/O, network,
    and battery budgets.
11. Fresh installations retain the existing one-Session-per-Tab behavior
    until the user invokes a split command.
12. Web and CLI behavior remains compatible without understanding client Pane
    trees.

## Alternatives considered

### Keep using nested tmux indefinitely

This is the chosen near-term behavior. It is mature, immediately available,
and keeps Warren implementation complexity at zero. It does not provide
native per-Pane identity, recovery, Agent activity, or client interaction.

### Expose tmux panes as Warren Panes

Rejected. It would make the UI domain depend on one optional Runtime adapter,
give ghostline a different resource model, and blur Runtime Binding with
Warren Session identity.

### Mirror one Warren Session into several Panes

Rejected. A PTY has one canonical row and column size and one ordered input
stream. Multiple independently sized interactive surfaces cannot own it
without conflicting behavior.

### Make Pane layout Host-owned

Rejected for the first implementation. Desktop and Web have different screen
sizes and interaction models. Synchronizing geometry would require conflict
resolution without improving Runtime durability.

### Multiplex every Pane on the existing WebSocket immediately

Deferred separately. It may be the long-term transport shape, but it expands
the daemon peer lifecycle, control routing, teardown, and compatibility risk.
The `TerminalChannel` abstraction allows the UI feature to begin with bounded
per-Session connections and change transport later.
