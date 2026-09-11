# RFC 0018: Multi-Host Project and Workspace Sidebar

- Status: Draft
- Owner: Warren Desktop and CLI
- Created: 2026-09-08
- Scope: opt-in aggregation of Projects and Workspaces from multiple configured Hosts in the macOS sidebar
- Protocol baseline: Warren protocol 4.0
- Depends on: [RFC 0003](0003-terminal-groups.md) (Host-local resource contexts) and the [Headless and Remote Connection Architecture](../headless-architecture.md)

---

## 1. Executive Summary

Warren currently displays the Project and Workspace tree for one selected
Endpoint. Users who work across several machines must switch the Endpoint
selector before they can discover the Projects on another Host.

This RFC adds an explicit display set. The Desktop keeps a roster connection
for each Endpoint in that set and renders the resulting Project and Workspace
trees under separate Host sections. The execution-server menu adds or removes
an Endpoint from the set, while the CLI controls its order. A click on a row
activates that Host and then uses the existing terminal and mutation flows.

The feature is deliberately client-side:

- the Host remains the authority for its own Projects, Workspaces, Sessions,
  and ordering;
- `~/.warren/config.json` remains the authority for the local Endpoint catalog,
  current Endpoint, and display set;
- the Warren wire protocol and Relay service do not need a cross-Host API;
- only one Host is active for terminal content in the first release.

The feature is opt-in. A configuration without the new `display` field keeps
the current single-Endpoint behavior. This version is Desktop-only; Web and
iOS retain their existing single-Endpoint behavior.

## 2. Motivation and Current Boundary

The existing Desktop composition has three single-Host assumptions:

1. `WarrenCompositionRoot` stores one `selectedEndpointID` and one Endpoint
   catalog.
2. `WarrenRemoteApplicationModel` owns one WebSocket, one live roster, one
   terminal surface manager, and one `WarrenDesktopProjection`.
3. `WarrenDesktopSidebar` passes one projection's `groups` to its row tree.

The CLI configuration currently stores `current` and `endpoints`, where
`current` means the Endpoint used by the active Desktop/CLI operation. It does
not describe a set of visible Hosts.

Flattening several rosters into the existing arrays is not sufficient. It
would lose the owner of each row, send mutations to the wrong Host, make
navigation IDs ambiguous, and potentially collide when independently created
Hosts contain equal resource IDs. The aggregation must therefore be a
client-side read model with an explicit Endpoint scope on every row and
action.

## 3. Terminology and Invariants

- **Endpoint**: a local connection definition and alias in the CLI catalog.
  It may be direct, SSH-backed, or Relay-backed.
- **Host**: the daemon identified by the `host.id` reported during the Warren
  handshake. One Endpoint normally reaches one Host, but two Endpoint aliases
  may intentionally reach the same Host through different routes or scopes.
- **Current Endpoint**: the one Endpoint that owns the foreground terminal,
  Tab, Agent, settings, and write operations.
- **Display set**: the ordered, client-local allowlist of Endpoints
  whose Project and Workspace rosters are visible.
- **Host-local resource**: a Project, Workspace, Task, Terminal Group, or
  Session remains owned by the Host that created it. This feature never moves
  a resource between Hosts.

The following invariants are required:

1. The current Endpoint and the explicit display set are independent. Switching
   or connecting to an Endpoint must not change sidebar membership.
2. An explicit display set contains at least one valid Endpoint. `local` is a valid
   synthetic Endpoint even though it is not stored in `endpoints`.
3. A row identity and a navigation key contain its Endpoint scope. A raw
   `ProjectID` or `WorkspaceID` is never used as the sole cross-Host identity.
4. A mutation is sent only through the connection that owns the row. The
   Desktop must not infer ownership from a display name or from the current
   selection after an asynchronous operation has started.
5. Host order in the sidebar is display configuration. Project and Workspace
   order inside a Host remains Host state and is changed through the existing
   Host APIs.

## 4. CLI Configuration

### 4.1 Configuration shape

`~/.warren/config.json` gains an optional section:

```json
{
  "current": "local",
  "endpoints": {
    "dev": {
      "name": "dev",
      "url": "https://dev.example.test:8789",
      "token": "..."
    },
    "prod": {
      "name": "prod",
      "ssh": "prod"
    }
  },
  "display": {
    "version": 1,
    "endpoints": ["local", "dev", "prod"]
  }
}
```

`display` is optional for backward compatibility. When absent, its effective
value is `[current]`, or `[local]` when no current Endpoint exists. The CLI
normalizes duplicates, validates Endpoint names, and rejects an empty explicit
result. The current Endpoint remains independent from `display`, so selecting
or connecting to an Endpoint never adds it to the sidebar. The section contains
aliases and optional client-local display names; it never duplicates URLs,
tokens, SSH metadata, or Relay credentials. The canonical `local` alias remains
lowercase even when its label is customized in the Desktop.

Both the Go config model and the Swift `WarrenEndpointCatalog` model must
decode and write this field. Existing sidecar locks, `0600` permissions,
temporary-file writes, and atomic replacement remain mandatory. Endpoint
mutations must preserve the display section, and display mutations must
preserve Endpoint credentials and route metadata.

### 4.2 Commands

The commands are local configuration operations and do not use `--endpoint`,
`--server`, or `--token`:

```text
warren display list
warren display add NAME [--before NAME]
warren display remove NAME
warren display move NAME --before NAME
warren display set NAME [NAME ...]
warren display reset
```

Examples:

```bash
warren display set local dev prod
warren display add staging --before prod
warren display remove dev
warren display reset
```

The commands follow the existing `--json`, `--quiet`, and `--config` output
and configuration conventions. `list --json` returns the ordered aliases,
the current alias, and the effective configuration version. Human-readable
output shows order and the current marker, but never prints tokens.

`reset` removes the explicit `display` section and returns to the compatible
single-current behavior. `endpoint remove NAME` also removes `NAME` from the
display set and chooses a new current Endpoint only when the removed Endpoint
was current. The Desktop execution-server menu provides an add/remove sidebar
control for each Endpoint; it changes membership without changing `current`.
The CLI remains the editor for display order.

## 5. Runtime Architecture

### 5.1 Multi-Host coordinator

Add a Desktop application-layer coordinator, for example
`WarrenMultiHostModel`:

```text
WarrenMultiHostModel
├── endpointID -> WarrenHostConnection
├── sidebarHostProjections
├── activeEndpointID
└── active terminal controller
```

`WarrenHostConnection` owns one Endpoint's connection lifecycle, latest roster,
connection state, and error. It may use the existing `WarrenRemoteClient`, but
the roster path must be independent of terminal attachment and rendering.

Connections for non-current Endpoints run in roster-only mode:

- authenticate and consume `roster` and `roster.delta`;
- keep Project, Workspace, and roster-projected activity data in memory;
- do not call `session.subscribe`, `session.focus`, or `session.resize`;
- do not create a Terminal Surface or claim a control lease.

The current Endpoint is promoted to the interactive controller. Prefer sharing
the same underlying `WarrenHostConnection` during promotion so a click does not
require a second WebSocket. If that refactor is too risky for the first
implementation slice, activation may reconnect the existing interactive model
while retaining the same public behavior.

### 5.2 Configuration monitoring

The existing background catalog monitor must also read the effective display
set. On each change it computes a diff:

- new aliases start roster connections;
- removed aliases cancel their connection and discard their in-memory snapshot;
- unchanged aliases retain their connection and navigation state;
- a changed `current` Endpoint becomes the interactive controller.

A connection failure is isolated to that Host. Other Host sections remain
usable. During a transient failure, the last in-memory roster remains visible
with a reconnecting or offline indicator. A disk-backed roster cache is
deferred because Project paths can contain sensitive local information.

SSH-backed Endpoints require one tunnel owner per Endpoint. The current Desktop
implementation has one embedded SSH tunnel property, so it must become a
scoped collection before multiple SSH Hosts can be connected simultaneously.
Relay client identities remain per Endpoint.

## 6. Sidebar Read Model and Scoping

The Desktop package should add a Host-wrapped sidebar projection rather than
make every existing view immediately understand multiple transports:

```swift
struct WarrenDesktopSidebarHostProjection {
    let endpointID: String
    let endpointLabel: String
    let host: Host?
    let connectionState: WarrenDesktopConnectionState
    let projectGroups: [WarrenDesktopProjectGroup]
    let workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary]
    let activeWorkspaceIDs: Set<WorkspaceID>
    let lastError: String?
}
```

Host color is a presentation concern and is assigned at the sidebar rendering
boundary, not persisted in Host state or shared through the wire protocol. It is
used only as a very subtle background tint for the Host's Projects/Workspaces
section.

The outer Host identity used by SwiftUI must be namespaced by `endpointID`.
For actions and navigation, use a client-side reference equivalent to:

```swift
struct WarrenDesktopHostResourceRef<ID> {
    let endpointID: String
    let id: ID
}
```

`hostID` and the authenticated access scope may be retained as validation
metadata after the welcome event, but Endpoint scope remains the routing key.
This deliberately treats two aliases for one Host as separate entries when
their access scopes differ.

The following must be scoped:

- Project and Workspace row IDs;
- sidebar selection and typed Desktop actions;
- navigation memory and selected-tab persistence;
- tab IDs and terminal-surface lookup keys;
- deletion, rename, pin, move, setup-script, and Workspace creation requests.

Existing single-Host fixtures and callers can keep the current
`WarrenDesktopProjection` initializer. The new sidebar projection is an
additive boundary, allowing the active workspace column to migrate separately.

## 7. Desktop Interaction

The first release aggregates Project and Workspace rows only:

```text
Local Mac
    repository-a
      main
Build VPS
    repository-a
      release/test
Production · Offline
    repository-b
```

### 7.1 Host visual identity

When more than one Host is visible, every Host receives a stable,
low-saturation background tint for its entire Projects/Workspaces section. The
tint is a quiet grouping surface, not an accent applied to individual rows.
Host titles, Project/Workspace names, metadata, and connection/status labels
keep the existing foreground and semantic color tokens. Host headers begin at
the same leading edge as the sidebar section labels and do not use a server
glyph. A one-Host display set retains the legacy Projects presentation, with
no Host title, grouping tint, or `PROJECTS · HOSTS` label.

Multi-Host sections are compact tree groups rather than padded cards: a 24pt
Host subheading immediately precedes its Project rows, and the tint covers the
subheading and children without extra vertical inset. Project and Workspace row
heights remain unchanged so their interaction targets stay consistent.

The tint must be extremely faint: target four percent opacity over the existing
sidebar surface, with an eight percent hard maximum pending visual validation.
It must not change the perceived layout or compete with terminal content. The
selected Project/Workspace row is rendered above the tint with the existing
selection background, border, focus ring, and text exactly unchanged; the Host
tint must not leak into or recolor the selected state.

Use a dedicated set of soft Host background tints in the Design System rather
than status colors such as success, warning, or destructive. Assignment is
keyed by the stable Endpoint alias (and may incorporate the authenticated Host
identity after the first handshake), not by the current array index. Existing
Hosts therefore keep their tint when the CLI order changes or a new Host is
added. A client-local mapping or deterministic hash with collision resolution
may provide this stability; it must not add color data to `config.json`.

Host alias and reported Host name remain the primary identity signals, and
accessibility labels include that text. Color is supplementary and is omitted
from the collapsed sidebar, where no Host section background is visible. The
existing order-based `WarrenDesktopEndpointAppearance` helper must not be used
to recolor row foregrounds or selection states.

Behavior:

- Host sections follow the CLI order and show the configured alias plus the
  reported Host name when available.
- A one-Host display set uses the ordinary collapsible `PROJECTS` tree while
  retaining endpoint-scoped row identity and routing.
- A Host header uses the same disclosure behavior as `Projects`; collapsing it
  hides that Host's Project and Workspace rows.
- An attached Host has no visible `Connected` label. Connecting and reconnecting
  states use a spinner without status text; disconnected and failed Hosts keep
  their actionable error and retry affordance.
- Equal Project names are allowed because their Host sections disambiguate
  them.
- In the expanded sidebar, a Project row only expands or collapses its
  Workspace children.
- Selecting or double-clicking a Workspace first activates its Endpoint, then
  applies the existing Workspace navigation and terminal behavior.
- The existing active-only filter can be calculated per Host from each roster;
  it must not accidentally hide a Host merely because that Host is not current.
- Project and Workspace context-menu writes are enabled only when the owner
  connection is attached and the operation is supported by that Endpoint.
  A background row may be selected to promote its Host before a write.
- Add Project remains a current-Endpoint operation. Remote filesystem paths
  continue to be added through the CLI on the remote Host.
- Host order is not draggable in the Desktop; it is changed with
  `warren display move`.
- Host-local Project/Workspace order may continue to use existing Host APIs,
  but a drag source and destination must have the same Endpoint scope.

Tasks, Terminal Groups, Active Sessions, and simultaneous terminal Tabs remain
current-Host features in this release. Their future aggregation can reuse the
same Host wrapper and scoped references.

## 8. Activation and Terminal Semantics

The sidebar is multi-Host; the foreground terminal remains single-Host in v1.
This keeps the existing attachment, focus, Ghostty surface, Agent event, and
embedded-editor invariants intact.

When activation changes from Host A to Host B:

1. capture and persist Host A's navigation state;
2. promote or connect Host B;
3. validate the requested scoped Workspace against Host B's roster;
4. attach the existing terminal controller only after Host B is ready;
5. persist `current = B` through the shared config catalog.

An asynchronous request captures its Endpoint and resource reference at
invocation time. Completion must not derive its target from whichever Host is
current when the response arrives.

## 9. Protocol, Security, and Performance

No Host protocol change is required. Each connection still uses Warren
protocol 4.0 and receives the normal Host-scoped roster. No Relay-side
cross-Host aggregation endpoint is introduced.

The display set is not an authorization boundary. A token still determines
which Projects a Host exposes; the CLI merely opts the local Desktop into
showing those already-authorized rosters together. Diagnostics must log aliases
and state only, never bearer tokens, URLs containing credentials, or Project
paths unless an existing redacted diagnostic explicitly permits them.

The implementation must bound background work. It should enforce a measured
soft limit (initial target: eight simultaneous roster connections), use the
existing welcome timeout and exponential reconnect backoff, and stop all
connections and SSH helpers on app termination. A single slow or failed Host
must not delay the first usable section from another Host.

## 10. Compatibility and Migration

- Existing `config.json` files without `display` behave exactly as they do
  today.
- The preview `sidebar` field is accepted on read and rewritten as `display`
  by the next catalog update.
- Existing Endpoint aliases, tokens, SSH metadata, Relay metadata, and
  `current` semantics remain unchanged.
- Existing navigation keys are migrated by treating them as belonging to the
  current Endpoint. New writes include the Endpoint prefix.
- If the Desktop cannot decode the optional display section, it falls back to
  the effective current Endpoint and presents a visible configuration notice;
  it does not erase the file.
- A malformed or unknown Endpoint name is rejected by the CLI. The Desktop
  marks that entry unavailable until the catalog is corrected.

## 11. Implementation Plan

1. **Config and CLI**
   - Add the optional `DisplayConfig` to Go and `WarrenDisplayConfiguration`
     to Swift catalog models.
   - Implement `warren display` commands and atomic current-selection
     reconciliation.
   - Add Go/Swift round-trip, locking, migration, and endpoint-removal tests.
2. **Roster coordinator**
   - Extract a reusable Host roster connection from the single-Host Desktop
     model.
   - Add dynamic connection diffing, failure isolation, and scoped SSH tunnel
     ownership.
3. **Desktop read model**
   - Add Host-wrapped sidebar projections and Host section rows.
   - Add a stable Host tint assignment layer and apply it only to the
     Projects/Workspaces section background; preserve existing row and
     selection styling.
   - Add endpoint-scoped resource references and navigation persistence.
4. **Activation and writes**
   - Route Workspace selection and all Project/Workspace mutations by owner
     Endpoint.
   - Preserve the existing single active terminal controller.
5. **Verification and documentation**
   - Update `Headless/README.md`, `docs/headless-architecture.md`, and the CLI
     usage text.
   - Exercise the real Desktop artifact with at least two fake or local Hosts,
     including a disconnected Host and a live CLI roster change.

## 12. Acceptance Criteria

1. A fresh configuration without `display` shows only the current Endpoint.
2. `warren display set local dev prod` causes the Desktop to show all
   three Host sections without restarting the app.
3. A Project and Workspace with the same display name on two Hosts remain
   distinct and selectable.
4. With the initial supported Host count, each visible Host has a distinct,
   stable, very faint Projects/Workspaces background tint; reordering the CLI
   list does not recolor existing Hosts.
5. Selecting a Workspace on a non-current Host activates that Host and opens
   the Workspace through the existing terminal flow.
6. A failed or stopped Host does not remove healthy Host sections; its section
   shows a bounded error/retry state.
7. A Project/Workspace mutation is routed to its owner Endpoint, even if the
   user switches Hosts before the asynchronous response completes.
8. Removing an Endpoint or display alias cancels its background connection and
   does not remove the Endpoint's credentials unless `endpoint remove` was
   explicitly requested.
9. Existing Host-local order, Task membership, Session ownership, terminal
   recovery, and Relay/SSH credential boundaries remain unchanged.
10. The CLI and Desktop can concurrently update `config.json` without losing
   either the Endpoint catalog or the display set.

## 13. Non-Goals

- Cross-Host Task/Workspace attachment;
- moving a Workspace, Project, Task, Session, or Terminal Group between Hosts;
- cross-Host drag-and-drop;
- simultaneous terminal panes or active Tabs from multiple Hosts;
- a Host or Relay server-side aggregate API;
- a full GUI editor for display ordering;
- persistent local roster caching in the first release;
- aggregating Tasks, Terminal Groups, or Active Sessions in the first release.

## 14. Open Questions for Follow-up

1. Should a future release aggregate Tasks and Terminal Groups under the same
   Host sections, or keep them in a current-Host-only switcher?
2. After measuring real usage, should the soft connection limit be configurable
   or replaced by an explicit per-Host refresh policy?
3. Is a privacy-preserving, TTL-bounded roster cache worth the local
   data-at-rest trade-off for offline sidebar discovery?
