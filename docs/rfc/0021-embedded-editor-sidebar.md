# RFC 0021: Embedded Editor Sidebar and Workspace Pane Integration

- Status: Draft
- Owner: Warren Desktop
- Created: 2026-09-16
- Scope: replace the editor-exclusive workspace mode with an optional
  code-server region beside the terminal
- Editor baseline: code-server 4.112.0 (Code 1.112.0)
- Protocol baseline: Warren protocol 4.0
- Depends on: [RFC 0020](0020-host-owned-pane-groups.md) and the Embedded Editor
  section of [DESIGN.md](../../DESIGN.md)

## 1. Summary

The current Desktop treats the Embedded Editor as an alternative to the
Terminal. Opening it hides the terminal and makes the editor look like a
second Warren content mode. This RFC changes the editor into a companion
surface:

1. The top-right IDE control opens a code-server region in the central content
   area, split from the Terminal. That region carries the whole code-server
   surface: its editor area, its own Explorer, and its activity bar.
2. Warren owns one split — Terminal against the code-server region. The
   division between the editor area and the Explorer inside that region belongs
   to code-server.
3. The same control closes the region. The editor is not a Tab, so the track
   has no close affordance for it.

The resulting screen is:

```text
Warren owns this split ⇕            code-server owns this one ⇕
┌ Warren sidebar ┬─ Terminal ───┬─ Editor area ─┬─ Explorer ─┐
│ Projects       │              │ App.swift     │ ▾ Sources  │
│ Workspaces     │ $ swift …    │ 1 import …    │   ▸ Warren │
│ Sessions       │ █            │ 2             │ ▸ Tests    │
└────────────────┴──────────────┴───────────────┴────────────┘
                                └──── one WKWebView ─────────┘
```

The Terminal is never hidden. Warren does not mount code-server's Explorer in a
surface of its own; §5.1 records the code-server constraint that rules this out
and the measurements behind it. Because code-server already places its sidebar
on the trailing edge of its own region, the reading order is
`Terminal | Editor | Explorer`.

When a Workspace has no running Session, the code-server region can occupy the
central area by itself.

## 2. Problem and goals

### 2.1 Problems

The current implementation has four mismatches with the desired workflow:

1. Terminal and editor are mutually exclusive, so a user cannot keep a
   conversation or shell visible while reading a file.
2. Opening the editor parks the terminal surfaces and reports an empty screen
   set, so the Terminal is not merely covered but actively torn down.
3. Search and Git can be mistaken for Warren-owned secondary panels even though
   they are already code-server capabilities.
4. The active-only Workspace filter only considers running Warren Sessions, so
   an editor-only Workspace disappears from the lightning-button view.

### 2.2 Goals

- Keep Terminal and Embedded Editor visible and usable at the same time.
- Split the code-server region from the Terminal in the central content area,
  without ending or duplicating a Warren Session.
- Keep the whole editor experience inside one code-server runtime and one
  WKWebView, so Warren maintains no IDE surface of its own.
- Keep Search, Source Control/Git, Quick Open, and editor commands inside
  code-server; Warren must not duplicate those panels.
- Persist a per-Workspace editor marker and enough state to restore the user's
  editor entry after a view or app restart.
- Treat an editor-marked Workspace as active even when it has no running
  Session.
- Preserve existing Host-owned terminal PaneGroup semantics.

### 2.3 Non-goals for this revision

- A code-server process that survives termination of the Warren app. The
  process may be stopped and lazily relaunched; the Workspace editor state is
  what persists.
- A remote code-server service for remote Endpoints. The current capability
  boundary exposes the Embedded Editor only for the local Endpoint.
- New Warren Search, Git, diff, or source-control panels.
- A Warren-owned file tree. The Explorer stays inside the code-server region,
  which keeps Git decorations, context menus, and drag-and-drop working without
  Warren reimplementing them.
- A Warren-built editor view or LSP client. Replacing code-server with a native
  editor stack was evaluated and rejected: it would move file indexing,
  completion, diagnostics, and Search into Warren's maintenance surface, which
  §2.2 and §5 explicitly assign to code-server.
- A Warren-owned tool rail. An earlier revision of this RFC put a fixed-width
  trailing rail beside the region to hold a `Code Editor` entry. With the
  Explorer staying inside the region, that rail held one entry and occupied
  width for it, so the IDE control the Desktop already had is the entry point.
- Host-shared editor markers. The first revision stores this Desktop-local
  presentation state; a future Host capability may make it visible to other
  clients.
- Adding an editor leaf to the Host-owned `PaneGroup` tree. That tree remains a
  tree of Warren Terminal Sessions.

## 3. Interaction model

### 3.1 Editor region states

The region has a small state machine. Opening or closing it never changes the
selected Workspace or the Terminal PaneGroup.

```text
closed
  │ open the Embedded Editor from the IDE control
  ▼
open (code-server region split from the Terminal in the central area)
  │ close the Embedded Editor from the same control
  ▼
closed (the marker survives; see §6.1)
```

Warren contributes no `Search` or `Git` surface of its own. Those actions are
reached through code-server's own activity bar, command palette, quick search,
and Source Control views inside the region.

### 3.2 File selection

File selection happens inside the code-server region and needs no Warren
mediation: the user clicks a file in code-server's Explorer and code-server
opens it in its own editor area, one WebKit process, no cross-surface protocol.
Warren's only involvement is focus routing. Clicking the Terminal moves focus
and its control lease back to the Terminal as usual.

Warren still drives one open path programmatically. Opening the editor reopens
the Workspace's `lastRelativeFile` (§6.1) through the existing
`payload=openFile` query parameter, so the region starts on the document the
user left rather than on an empty editor area. §4.1 explains why the empty state
is worth avoiding.

Closing the region does not end the Terminal's Session.

### 3.3 Workspace changes

The code-server region is scoped to the active Workspace. A Workspace change
never opens a file from another Workspace by path coincidence.
The Desktop switches editor state using the Host/Workspace identity key and
restores that Workspace's last selected document when one exists.

## 4. Layout and ownership

The Desktop composition becomes:

```text
Window
├── Warren resource sidebar (existing)
└── Workspace column
    ├── top bar / tabs / presets (existing)
    └── HStack
        ├── CentralContent
        │   ├── Terminal region
        │   │   └── Host-owned PaneGroup tree (zero or more terminal leaves)
        │   └── EditorRegion (optional, client-local)
        │       └── one code-server WKWebView
        │           └── editor area + Explorer + activity bar (code-server)
```

The Terminal and the code-server region share the central content width with
one Warren-owned draggable divider, defaulting to roughly 40/60. Whether the
region is up, and where the divider sits, is window-local UI state.

`EditorRegion` is intentionally not a `PaneGroup` leaf. RFC 0020 requires every
Host pane leaf to identify a running Warren Session, while the editor region has
no PTY, Session lifecycle, input lease, or Host ownership. The Desktop composes
the terminal tree and the editor region at the content boundary instead of
weakening those invariants.

The Terminal remains mounted and subscribed while the editor region is
visible. Opening the editor must not report an empty terminal screen set or
park all terminal surfaces as the old exclusive editor mode does. Because the
Terminal is no longer hidden, the preset bar also stays visible in this mode
instead of being removed with the terminal layout.

### 4.1 Width floor and the empty editor area

Measured against the code-server this RFC targets (4.112.0, Code 1.112.0), the
editor part reports a hard minimum of 220 × 70 pt. Warren reserves 180 pt beside
it for the Explorer rather than the roughly 300 pt code-server opens at, giving a
400 pt region floor: the reserved width is a floor, not the width the tree opens
at, and 180 pt still shows ordinary file names. Below a window width of about
900 pt the Terminal becomes cramped. Behavior below that floor — collapsing the
editor region automatically or letting the user live with a narrow Terminal — is
left to the implementation.

The two regions open on even halves. The editor region carries two columns
inside its share, so sizing it by content made it open wider than the Terminal —
the surface the user was working in when they opened a file. The divider settles
anything else.

Warren cannot set the Explorer's initial width declaratively: code-server keeps
its sidebar width in its own workbench state, and there is no `settings.json`
key for it. Narrowing the reserved floor is the whole of what the client can do
here; the user's own drag is what persists.

That 220 pt floor cannot be collapsed (§5.1), so a Workspace with no open
document shows an empty editor area rather than an Explorer-only region. This is
why §3.2 restores `lastRelativeFile` on entry: the empty state then appears only
the first time a Workspace uses the editor. `workbench.editor.empty.hint` is
already `hidden` in Warren's managed settings, so that area renders as plain
background rather than a keyboard-shortcut splash.

## 5. Responsibility boundaries

| Layer | Owns | Does not own |
| --- | --- | --- |
| Warren Host | Projects, Workspaces, Terminal Sessions, runtimes, and terminal PaneGroups | The local code-server process or the Desktop's editor marker |
| Warren Desktop | The Terminal/editor split, focus routing, and per-Workspace editor state | File trees, file indexing, Monaco editing, or a second Git implementation |
| code-server | Explorer, document editing, Search, Quick Open, Source Control/Git, decorations, its internal sidebar split, and editor shortcuts | Warren Session lifecycle and Warren sidebar navigation |
| Ghostty/Terminal surface | PTY input/output, resize, recovery, and control lease | Editor files or Workspace editor markers |

The existing `WarrenEmbeddedEditorModel` remains the process/profile boundary
and its view contract is unchanged: one whole-page code-server surface per
Workspace, one WKWebView, one runtime. The executable resolver, managed
settings, loopback binding, extension preparation, Workspace-scoped URLs, and
the bounded warm-view cache all keep working as they do today. This RFC changes
where that surface is mounted, not what it is.

### 5.1 Why the Explorer is not mounted in a Warren surface

An earlier draft split the contract into an `ExplorerSurface` beside the region
and a
`DocumentSurface` in the central area, backed by one runtime. That is not
achievable against the code-server this RFC targets. Measured on 4.112.0
(Code 1.112.0):

- The web entry point is a whole page. `workbench.html` ships an empty `<body>`
  and a single `workbench.js` that mounts the entire workbench into it. There is
  no per-part entry point.
- The bundle exposes no part-level mounting API — no `attachPart`,
  `detachPart`, `getPartContainer`, or `createPart`. `workbench.parts.sidebar`
  and `workbench.parts.editor` exist only as part identifiers inside one
  workbench instance. (`attachPart` belongs to the `monaco-vscode-api` fork, not
  to upstream VS Code.)
- The server route honors only three query parameters — `folder`, `workspace`,
  and `ew`. Nothing selects or suppresses a part. `payload=openFile` is consumed
  by page scripts and is not a part selector.
- `workbench.action.toggleEditorVisibility` exists by name but its handler calls
  `toggleMaximizedPanel()`, and it is preconditioned on a visible non-bottom
  panel. It does not hide the editor area, which is why the 220 pt floor in §4.1
  stands.

A single WebKit view cannot be mounted in two places, and running two views over
one Workspace would either share a data store — two clients contending for one
state database, like two browser tabs on the same code-server — or isolate them,
in which case the separated Explorer could not drive the central editor. Warren's
per-Workspace stores are already isolated and non-persistent, and the warm-view
cache is bounded at three, so a second view per Workspace would halve it.

Warren therefore mounts the code-server region whole and lets code-server own
the split inside it. Warren must not ship two workbench views and hide half of
each with CSS as a substitute for independent surfaces.

## 6. Per-Workspace editor persistence

### 6.1 Record

The Desktop adds a versioned, local `WorkspaceEditorStateStore`. A conceptual
record is:

```json
{
  "schemaVersion": 1,
  "hostId": "host-id",
  "workspaceId": "workspace-id",
  "enabled": true,
  "lastRelativeFile": "Sources/App.swift",
  "lastLine": 42,
  "lastColumn": 1,
  "updatedAt": "2026-09-16T00:00:00Z"
}
```

The key is `(hostId, workspaceId)`, not only a display name or path. This
prevents two Hosts with equal UUIDs or two Endpoint aliases for one Host from
sharing the wrong editor state. The record is client-local and must not contain
tokens, credentials, or a copy of the Workspace tree. `schemaVersion` is
explicit so a later field change can migrate rather than discard the marker.

`lastRelativeFile` is restored eagerly: opening the editor reopens it through
`payload=openFile` (§3.2). Warren does not reopen it merely because a Workspace
became selected — Workspace navigation must not start code-server.

`enabled` is the durable editor marker:

- Opening the editor, or opening a file in it, sets it to `true`.
- An idle code-server stop does not clear it: the runtime's lifetime is not the
  user's intent.
- Closing the editor region clears it, along with the last-file metadata. An
  earlier revision kept the marker through a close and asked for a separate
  `Forget Editor for Workspace`, which meant closing the editor and relaunching
  brought it back — a restored surface the user had already dismissed reads as a
  bug rather than as preserved state. There is one close.
- A confirmed Workspace deletion prunes the record. A temporary Host outage
  does not.

The existing code-server profile and extension directories remain persistent
under Warren's application-support directory. WebView instances may still be
evicted from the memory cache; restoration uses the Workspace record and
code-server's profile rather than retaining an unbounded number of views.

### 6.2 Runtime lifecycle

The Desktop may reuse one managed code-server process for the local Endpoint
and keep a bounded set of Workspace views warm. The process is started on the
first editor request, may be stopped after the existing idle timeout, and is
started again on demand. A failed or unavailable runtime leaves `enabled`
intact, shows a retryable error state in the region itself, and keeps the
Workspace visible in active-only mode.

## 7. Active Workspace semantics

The Workspace activity projection changes from Session-only to:

```text
workspace.isActive =
    workspace has at least one running Warren Session
    OR WorkspaceEditorState.enabled == true
```

Consequences:

- A Workspace with only an editor marker is included when the lightning
  `Active only` filter is enabled.
- Its Project and any Task copy remain visible when they contain at least one
  active Workspace.
- A code-server startup failure still leaves the marker visible, with a
  warning affordance rather than silently filtering the Workspace out.
- An unmarked Workspace with no running Session remains hidden by the filter.
- Terminal Groups keep their existing Session-based active rule.

The editor state is an overlay on the Desktop sidebar projection. It does not
change Host roster ordering or create a fake Warren Session/Tab.

Because the marker is Desktop-local (§2.3), a Workspace can read as active on
this Mac and inactive on Web or iOS. The marker affordance should therefore read
as local editor state rather than as Workspace-wide activity.

The marker is also the entry: the workspace row draws a borderless code glyph
that reveals the Workspace's editor on click, with hover as its only affordance
so a row with an editor open is no louder at rest than one without. Without it
the editor would be reachable only from the chrome control that opened it, in a
Workspace the user has since navigated away from. Only the current Host's tree
offers the entry, because the marker is stored per Endpoint (§6.1); a background
Host's row keeps the glyph as a readout.

## 8. Migration from the current editor mode

The migration should be incremental and preserve the existing executable
resolver, managed settings, loopback binding, extension preparation, and
Workspace-scoped URLs.

No embedding spike is required: §5.1 settles the question, and the editor view
contract is unchanged.

1. Add the `WorkspaceEditorStateStore`.
2. Replace `WarrenDesktopWorkspaceContentMode`'s terminal/editor exclusivity
   with an optional editor region, and give the central area one draggable
   divider between the Terminal and that region.
3. Keep the preset bar mounted in this mode. It is currently gated on the
   terminal-only content mode, so it disappears whenever the editor opens.
4. Map a persisted old `.editor` selection to `enabled = true` and an open
   region. Map old `.terminal` selection to a closed region without deleting any
   existing editor record.
5. Keep the existing IDE popover as an entry point, but have its Embedded
   Editor action split the region from the Terminal rather than replace it, and
   add the matching close action there — the editor is not a Tab, so the track
   carries no close control for it. Its checked state becomes "the region is up"
   rather than "content mode is editor".
6. Extend `activeWorkspaceIDs` and the multi-Host sidebar projections with the
   local editor-state overlay.
7. Remove the old path that hides terminal surfaces, reports an empty screen
   set, or treats the editor as a synthetic Tab. In particular the visibility
   flags that cross-fade the terminal and editor panes, and the call that
   reports an empty screen set before switching to the editor, both go away.

No new Host RPC or `state.json` field is required for this first revision. If
editor state later becomes shared across Desktop, Web, and iOS, it should be a
separate negotiated capability and resource instead of overloading Sessions or
PaneGroups.

## 9. Acceptance criteria

1. The top-right IDE control opens one code-server region split from the
   Terminal, without changing Workspace selection or terminal focus
   unexpectedly.
2. Warren shows no `Search` or `Git` surface of its own; those stay inside the
   region.
3. The open region reads `Terminal | Editor | Explorer`. The Explorer is
   code-server's, on the trailing edge of that region; the Warren divider
   between the Terminal and the region is draggable.
4. Terminal input, output, resize, recovery, and Agent conversation remain
   usable while the editor region is open, and the preset bar stays visible.
5. The same control closes the region, which leaves the Terminal's Session
   untouched and clears the Workspace's marker so a relaunch does not reopen it.
6. An editor-only Workspace has a visible editor marker and remains visible
   with `Active only` enabled. A plain inactive Workspace remains filtered.
7. The marker and last selected relative file survive view eviction and app
   relaunch, are isolated by Host/Workspace identity, and are pruned by closing
   the editor or after confirmed Workspace deletion.
8. An unavailable or crashed code-server shows retryable status without
   hiding the Workspace or affecting the Terminal.
9. Opening the editor for a Workspace with a stored `lastRelativeFile`
   opens that document, so the editor area is not empty on re-entry. A
   first-time Workspace shows a plain empty editor area.
10. Exactly one code-server WKWebView exists per Workspace; Search, Quick Open,
    and Source Control remain reachable inside it.

## 10. Open questions

Resolved since the first draft:

- Whether code-server can expose Explorer and Monaco as two independently
  mountable surfaces. It cannot; see §5.1 for the measurements. Warren mounts
  one region and code-server owns the split inside it.
- Whether to restore the last document automatically. Yes, on opening the editor
  rather than on Workspace selection (§6.1), which also keeps the empty editor
  area of §4.1 to a first-run occurrence.
- Whether a Warren tool rail holds the editor entry. No: with the Explorer
  inside the region, the rail carried one entry and cost width for it, so the
  existing IDE control is the entry point (§2.3).

Still open:

- Should a future Host-shared editor marker describe one user's Desktop state,
  or should it be per authenticated client? The first revision deliberately
  avoids this protocol decision.
- When a Workspace has no Terminal Session, should the code-server region fill
  the central area (the recommended behavior) or show an explicit empty terminal
  placeholder?
- What should happen below the roughly 900 pt window width of §4.1 — collapse
  the editor region automatically, or let the Terminal stay cramped?
