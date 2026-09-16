# RFC 0020: Host-owned Pane Groups for split terminal layouts

- Status: Draft
- Owner: Warren Headless, Desktop, CLI
- Created: 2026-09-16
- Scope: make a split terminal arrangement a durable Host resource that several
  groups can coexist in one Workspace or Terminal Group
- Protocol baseline: Warren protocol 4.0
- Supersedes: the ownership and persistence sections of [RFC 0008](0008-native-tab-splits.md)

---

## 1. Summary

A **Pane Group** is one whole-screen arrangement of running Sessions. It is a
Host resource: the Headless daemon stores its owner, name, order, pane tree, and
revision in `state.json` and projects it through the roster. Any number of Pane
Groups can exist in one Workspace or Terminal Group at the same time.

Exactly one group is *rendered* by a Desktop window at a time. Pane geometry is
defined relative to the whole content area, so two arrangements cannot be
composed into one screen without inventing a second geometry system; instead the
top bar lists the scope's groups and switching one swaps the whole screen.

```text
Host (durable)                          Desktop window (presentation only)
Workspace W                             ┌ top bar: [group 1] [group 2] [group 3]
├── PaneGroup 1  left/right  s1 | s2    │ active group 2, focused pane P3
├── PaneGroup 2  top/bottom  s3 / s4    │ screen = PaneGroup 2's tree
└── PaneGroup 3  single      s5        └ (group 1 and 3 are not rendered)

Terminal Group G
└── PaneGroup 4  left/right  s6 | s7
```

The client keeps only what is per-viewer: which group this window is looking at,
which pane has focus, terminal viewport/scroll state, and the "visit" state of a
Session selected outside the active group. Nothing about the viewer is written to
the Host.

## 2. Motivation

RFC 0008 made the split tree a Desktop-window value and kept it in device-local
`UserDefaults` under `warren.desktop.splitLayouts`, keyed by
`endpoint-<endpoint>-workspace-<UUID>` / `endpoint-<endpoint>-terminalGroup-<UUID>`.
That model has three limits:

1. **Shape is not Host state.** `session panes` cannot answer "how is this
   Session arranged" without a connected Desktop reporting it; the only durable
   pane-ish fact on the Host today is a per-peer, in-memory list of visible
   Session IDs.
2. **One arrangement per scope.** `splitTrees[scope]` holds a single tree, so a
   Workspace can host one split plus visits. A second arrangement cannot exist.
3. **Shape is per device.** The arrangement is invisible to the CLI, to another
   Desktop, and to the Web/iOS clients, and it cannot survive a Host-side
   recovery on its own terms.

The split feature has not shipped, so the layout format and its device-local
persistence can be replaced outright instead of migrated.

## 3. Ownership and invariants

| Resource | Owner | Shared across clients |
| --- | --- | --- |
| Project, Workspace, Terminal Group, Task | Headless Host | Yes |
| Session, Runtime binding, and PTY | Headless Host/runtime | Yes |
| **Pane Group (owner, name, order, pane tree, revision)** | **Headless Host** | **Yes** |
| Tab projection and tab order | Desktop client model | No |
| Active group, focused pane, viewport, scroll | Desktop window | No |
| "Visit" of a Session outside the active group | Desktop window | No |
| Ghostty surface and AppKit host view | `TerminalSurfaceManager` | No |
| Screen-session report | Authenticated WebSocket peer | No |

Invariants, which supersede RFC 0008's ownership list:

1. Every leaf carries one stable Host-generated Pane ID and one Session ID.
2. A Pane Group belongs to exactly one owner: a Workspace or a Terminal Group.
3. Every pane of a group belongs to that owner, and its Session is running and
   present in the roster. Non-conforming leaves are reconciled away by the Host.
4. A Session occupies at most one pane on one Host, across all groups. Moving a
   Session between groups is an explicit move, never a copy.
5. A group holds at most four panes (`maxPanes`), and a scope holds at most
   eight groups.
6. Editing a layout never creates, moves, resizes, or ends a Session. Ending a
   Session remains an explicit Session command.
7. Only the active group of a Desktop window is rendered, subscribed, and
   reported; background groups hold no surface, no output subscription, and no
   resize authority.
8. Only the active pane receives local keyboard focus and the input control
   lease. Sibling panes keep passive output and their own viewport, as today.
9. Output and recovery state stay keyed by Session ID, never by Pane ID.
10. All mutations address one group by ID and carry its expected revision. The
    Host has no notion of a "current" group.

## 4. Domain model

### 4.1 Stored records

`api.State` gains `PaneGroups []PaneGroup`:

```go
// PaneGroup is one whole-screen arrangement of running Sessions. It is durable
// Host state and is projected through the roster.
type PaneGroup struct {
    ID              string    `json:"id"`
    // WorkspaceID and TerminalGroupID are mutually exclusive owners, exactly as
    // they are for a Session.
    WorkspaceID     string    `json:"workspace,omitempty"`
    TerminalGroupID string    `json:"terminalGroup,omitempty"`
    // Scope mirrors Session.Scope so a group's owner kind is explicit.
    Scope           string    `json:"scope,omitempty"`
    // Name is an optional user label. An empty name renders as its ordinal.
    Name            string    `json:"name,omitempty"`
    // Order positions the group among its owner's groups.
    Order           int       `json:"order,omitempty"`
    Tree            PaneNode  `json:"tree"`
    // Revision increments on every accepted tree mutation and is the
    // compare-and-swap token for pane-group.update. A rename or a reorder is not
    // a tree change and leaves it alone, so a divider drag in flight stays valid.
    Revision        uint64    `json:"revision"`
    CreatedAt       time.Time `json:"createdAt"`
    UpdatedAt       time.Time `json:"updatedAt"`
}

// PaneNode is a recursive layout node. A leaf sets PaneID and SessionID; a
// split sets Axis, Ratio, First, and Second. Exactly one shape is valid.
type PaneNode struct {
    PaneID    string    `json:"paneId,omitempty"`
    SessionID string    `json:"sessionId,omitempty"`
    Axis      string    `json:"axis,omitempty"`
    Ratio     float64   `json:"ratio,omitempty"`
    First     *PaneNode `json:"first,omitempty"`
    Second    *PaneNode `json:"second,omitempty"`
}
```

The tree is the single source of pane membership, order, and geometry. Pane
order is preorder leaf order; a pane's 1-based index is derived, never stored.
There is deliberately no parallel flat pane list that could disagree with it.

### 4.2 Validation

`validatePaneGroup` runs on create and on every update, and rejects:

- an owner that is neither exactly one of `workspace` / `terminalGroup`, or an
  owner that does not exist;
- a leaf without a Pane ID or Session ID, a split missing `Axis`/`First`/`Second`,
  or a node with both leaf and split fields;
- `Axis` outside `horizontal` / `vertical`;
- a ratio that is not finite is clamped rather than rejected; after
  normalization it always sits inside `[0.15, 0.85]`;
- duplicate Pane IDs, duplicate Session IDs, or a Session already placed in
  another group;
- a Session that is missing, not `running`, or owned by a different owner;
- more than `maxPanes` (4) leaves, or a group count above `maxPaneGroups` (8) for
  the owner;
- a non-numeric name longer than 120 characters.

### 4.3 Reconciliation

The Host is the only reconciler. `reconcilePaneGroups` runs inside the store
update that changed sessions or owners, and at daemon start:

1. drop leaves whose Session is gone, ended, or no longer belongs to the owner;
2. collapse a split with a single surviving child (the survivor keeps its
   subtree and the parent's slot);
3. clamp and normalize ratios, then normalize again after a collapse;
4. keep every surviving Pane ID stable so a client's focus and identity survive;
5. delete a group with no leaves left;
6. never touch another group, another owner, or another Host's data.

The same algorithm backs `pane-group.update`, so an update that would leave an
invalid tree is rejected with a typed error instead of being silently repaired;
reconciliation exists for changes that come from outside the group (a Session
ending, moving, or being deleted).

## 5. Protocol surface

### 5.1 Methods

| Method | Params | Result |
| --- | --- | --- |
| `pane-group.create` | `{workspace? \| group?, session, name?, before?}` | `api.PaneGroup` |
| `pane-group.rename` | `{id, name}` | `api.PaneGroup` |
| `pane-group.move` | `{id, before?}` | `api.PaneGroup` |
| `pane-group.remove` | `{id}` | `void` |
| `pane-group.update` | `{id, tree, expectedRevision}` | `api.PaneGroup` |

- `create` always produces a single-pane group around an existing Session; a
  group never exists without at least one pane.
- `update` is the only structural mutator. Split, close a pane, place a Session
  into a pane, and drag a divider are all one `tree` replacement, guarded by
  `expectedRevision`. `expectedRevision` is required; omitting it is a
  validation error rather than a last-write-wins write.
- A leaf in an incoming tree may omit `paneId`. Pane identity is Host-owned, so
  the Host assigns a fresh ID for every leaf that arrives without one: two
  clients that split at the same moment cannot invent the same identity, and
  every leaf that already had one keeps it.
- An incoming ratio is clamped into the interactive range, not rejected: a
  divider drag is a geometry change, not a protocol violation.
- `remove` deletes the arrangement only. The Sessions keep running and stay
  reachable as ordinary Tabs.
- There is no `pane-group.list`: the roster is the list, exactly as it is for
  Sessions.
- Read-only hydration for the CLI uses the roster, not a new method.

Errors are stable-prefixed messages, matching the rest of the control protocol:
`pane group not found`, `pane group revision conflict`, `pane group invalid
tree`, `pane group session not found`, `pane group session in use`, `pane group
limit reached`.

### 5.2 Roster and deltas

`api.State.PaneGroups` joins the roster. `rosterDeltaMessage` gains
`PaneGroups *rosterEntityDelta[api.PaneGroup]`, so an accepted mutation travels
as one entity upsert and never resends unrelated groups. A client that does not
decode `paneGroups` ignores the field, which keeps this change additive for the
Web and iOS clients.

### 5.3 Capability

`pane-groups-v1` joins the capability enum in `protocol/warren.schema.json` and
`api.HostCapabilities()`. A Desktop that did not negotiate it does not offer
split UI at all: there is no local layout path any more (see §7.4). Remote
daemons are upgraded by the existing `warren ssh` bootstrap, so the mismatch
window is a reconnect.

### 5.4 Screen reporting

`screen.report` stays per-peer, in-memory presentation telemetry, and gains an
optional `group` field naming the arrangement the peer currently renders. It is
never durable and never the lifecycle authority for a Session.

`session.current` keeps reporting `screenPosition` / `screenPaneCount` from peer
telemetry; the durable shape is read from the roster instead. `session panes`
therefore answers from two explicit sources: the pane order and title come from
the Host's group, and the `SCREEN` column stays "which connected client is
displaying it right now".

## 6. Persistence and schema

- `state.json` schema moves `3 -> 4` (`store.currentSchema`). The migration is
  additive: existing fields are preserved, `paneGroups` starts empty. An older
  daemon that opens a schema-4 file fails loudly with `StateResetError` instead
  of silently dropping the new field on its next write, which is the existing
  policy for an unknown schema. Downgrading the daemon therefore requires a
  fresh state file.
- The Desktop stops using `warren.desktop.splitLayouts`. The split feature has
  not shipped, so no key is migrated, read, or interpreted; the persistence type
  and its scope-key/prune machinery are deleted together with the feature's
  local path.
- `state.json` growth is bounded by `maxPaneGroups` per owner; a group is small
  (one tree of at most four leaves) and is written only on user action.

## 7. Desktop rendering

### 7.1 Data source

`WarrenDesktopProjection` gains `paneGroups: [api.PaneGroup]` with lookups
`paneGroups(in workspaceID:)`, `paneGroups(in terminalGroupID:)`, and
`group(containingSession:)`. `WarrenDesktopRootView` derives its tree from the
projection instead of `@State splitTrees`.

Local, in-memory state only:

- `activeGroupIDs: [String: String]` keyed by the existing endpoint-scoped scope
  key, so switching endpoint or scope never rewrites another dimension;
- `activePaneIDs`, as today;
- `pendingTrees: [String: (tree: PaneNode, baseRevision: UInt64)]` for optimistic
  divider drags.

When a scope has no group, the renderer falls back to a single pane showing the
selected Tab, exactly as the current feature behaves for an unsplit scope.

### 7.2 Top bar

The tab strip draws one group mark per group of the active scope, ordered by
`Order` then `CreatedAt` then `ID`. The active group's mark is the filled one;
pressing a mark selects that group for this window and endpoint. The mark slot
width already exists in the strip's track math and the scroll follower
(`tabTrackWidth(tabCount:groupMarkSlotWidth:)`), so N marks are a width change,
not a new layout model. `⌘\`` cycles to the next group; the existing split, close,
maximize, and other-pane commands act on the active group only.

### 7.3 Mutations and optimistic geometry

- Structural changes (split, close a pane, place a Tab into a pane, create or
  remove a group) send one request and wait for the roster to confirm, reusing
  the existing pending-split machinery.
- A divider drag updates `pendingTrees` locally per frame, and coalesces a single
  `pane-group.update` per settle (same quiet period as today's persistence
  coalescing). The echoed roster revision retires the pending value. On
  `pane_group_revision_conflict` the client refreshes the roster, rebases once
  after dropping now-invalid leaves, and otherwise keeps the Host's tree: a
  divider is not worth an error dialog.
- No PTY frame ever carries layout data, and a drag never produces one request
  per pointer event.

### 7.4 Visibility, subscription, and the removed local path

`visibleScreenSessionIDs` returns the active group's leaves only. Background
groups therefore hold no output subscription, no resize lease, and no place in
`screen.report`; the surface budget stays bounded by the four-pane cap.

`WarrenDesktopSplitLayoutPersistence` and the `endpoint-<id>-<scope>` key
namespace are deleted. Without the `pane-groups-v1` capability the split commands
and marks are not offered; there is no fallback device-local layout.

## 8. CLI surface

The resource is spelled `pane` on the command line; the wire methods keep the
domain name `pane-group`.

```sh
warren pane list [--workspace WORKSPACE_ID | --group GROUP_ID] [--json] [-q]
warren pane create (--workspace W | --group G) --session SESSION_ID [--name N] [--before ID]
warren pane split --pane PANE_ID --session SESSION_ID [--axis horizontal|vertical] [--before|--after]
warren pane close --pane PANE_ID
warren pane rename PANE_GROUP_ID --name N
warren pane move PANE_GROUP_ID [--before ID]
warren pane remove PANE_GROUP_ID
warren session panes [SESSION_ID] [--json]
```

- `pane` addresses groups; `--pane` addresses one pane inside a group.
- `pane split` and `pane close` read the current tree from the roster, compute the
  replacement tree locally, and send one `pane-group.update` with the observed
  revision. A concurrent change surfaces as a revision conflict and a non-zero
  exit, never a silent overwrite.
- `pane close` on the last pane removes the group and leaves the Session running.
- `pane list` prints `ID`, `SCOPE`, `WORKSPACE`/`GROUP`, `NAME`, `PANES`, `ORDER`,
  `REVISION`; `--json` prints the roster records verbatim.
- `session panes` keeps its `SCREEN` column and gains `GROUP`, `PANE`, and
  `REVISION`, sourced from the roster plus peer telemetry. It now answers without
  any connected client, which is what the current column layout cannot do.
- Exit codes follow the existing CLI convention: usage errors and typed protocol
  errors are non-zero and printed as `code: message`.

## 9. Lifecycle

| Event | Host action |
| --- | --- |
| Session ends or is deleted | Remove its leaf, collapse, normalize; delete the group if empty |
| Session moves to another Workspace or Terminal Group | Remove its leaf from the old owner's group; the Session appears as an ordinary unplaced Tab |
| Workspace or Terminal Group removed | Delete its groups with it |
| Daemon start | Reconcile every group against the rehydrated Sessions |
| `pane-group.remove` | Delete the group; Sessions keep running |
| Last pane closed through `update` | Group is deleted; Session keeps running |

## 10. Failure, recovery, and compatibility

- Client without the capability: no split UI; Sessions, Tabs, and everything else
  behave exactly as today.
- Host with `pane-groups-v1` and a client that never mutates groups: groups are
  still projected, so the CLI can list and edit them from a plain shell.
- Two clients editing one group: the loser of the compare-and-swap rebases once,
  then keeps the Host's tree.
- Daemon restart: groups are durable; a stale leaf whose Session did not survive
  is reconciled on open.
- Relay, SSH, and Public Access are untouched: pane groups are ordinary roster
  data behind the same authenticated socket.
- Rollback: restoring a schema-3 daemon over a schema-4 state file requires a
  fresh state file, by design.

## 11. Non-goals

- Rendering two groups at once, or composing groups into a nested layout.
- Cross-Host pane groups (a group's panes always live on its own Host).
- Moving a group between owners, or a pane between owners, in this revision.
- Web and iOS pane rendering; they continue to ignore `paneGroups`.
- Pane-level undo/history; `session undo` stays specific to Session moves.
- Migrating device-local layouts: the feature is unreleased.

## 12. Acceptance criteria

Every criterion below is verifiable without a screenshot, a mouse event, or
focus stealing.

| # | Criterion | Where |
| --- | --- | --- |
| 1 | Tree validation and reconciliation: ended Session, foreign Session, duplicate Pane ID, duplicate Session, five panes, bad axis, unnormalized ratio, collapse, empty-group deletion | `Headless/internal/server/pane_group_test.go` |
| 2 | `state.json` schema 3 migrates to 4 preserving every existing field, `paneGroups` survives a restart, an unknown future schema still resets | `Headless/internal/store` tests |
| 3 | Concurrent `pane-group.update` on one group: exactly one wins; a stale `expectedRevision` returns `pane_group_revision_conflict` | `pane_group_test.go` |
| 4 | Session end, Session move, Workspace removal, and Terminal Group removal each reconcile their own group and leave every other group byte-identical | `pane_group_test.go` |
| 5 | Over a real WebSocket, a mutation produces a `roster.delta` whose `paneGroups.upsert` contains only the changed group, and the full roster carries the field | `Headless/internal/server` integration test |
| 6 | The real `warren-headless` plus the real `warren` binary run create/split/close/rename/move/remove, and `session panes` lists the arrangement with no client connected | Headless E2E test in the style of `Headless/internal/relay/e2e_test.go` |
| 7 | The generated protocol constants, capability enum, and Swift/Web bindings stay in step with `protocol/warren.schema.json` | `go test ./Headless/internal/protocol/...` |
| 8 | Swift transport decodes a roster and a delta carrying nested pane groups, and treats an absent `paneGroups` in a delta as "unchanged" | `Packages/Transport` tests |
| 9 | Desktop: group selection is keyed by endpoint and scope, the fallback single pane renders for a scope without a group, an optimistic drag rebases once on conflict, and background groups are absent from `visibleScreenSessionIDs` | `Packages/Desktop` tests |
| 10 | Semantic UI: pressing a group mark swaps the rendered tree, the inactive group's panes leave the semantic tree, and `WarrenInteractionGuard` still reports an unchanged frontmost application and mouse position | `swift run UIProbe` |

Not covered by automation, and checked by hand once: the subjective feel of
divider dragging over a real socket, and switching groups in the real app.
Everything else in RFC 0008's geometry, placement, and surface-manager suites
must stay green: the renderer is unchanged, only its source of truth moves.

## 13. Verification commands

```sh
go test -race ./Headless/...
swift test --package-path Packages/Transport
swift test --package-path Packages/Desktop
swift run UIProbe
bash scripts/verify.sh
```

## 14. Rollout

1. Host: `PaneGroup` model, reconciliation, service methods, store schema 4.
2. Protocol: schema methods, capability, roster and delta.
3. CLI: `pane` read and write commands, `session panes` joined output.
4. Desktop: projection, group marks, Host-backed mutations, deletion of the local
   layout path.
5. Docs: mark RFC 0008's ownership and persistence sections as superseded, add a
   CHANGELOG entry.
