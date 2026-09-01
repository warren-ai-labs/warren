# Warren Product and System Design

Status: single source of truth for phase-one design
Scope: product, domain model, architecture, data, terminal runtime, UI, and acceptance
Update rules: when implementation conflicts with this document, this document wins; design changes must update this document in the same commit

## 1. Product Goals

Warren is a local-first development workbench organized around Workspaces, with durable terminal sessions at its core.

The macOS Desktop connects to a local `warren-headless` daemon by default, and can also connect to `warren-headless` running on a VPS. Users can switch between Local and Server from the top-right corner to manage Tasks, Projects, Workspaces, Git worktrees, and Terminal Sessions on the target Host, with persistent terminal interaction through Ghostty. The CLI uses the same remote API and provides SSH bootstrap and port-forwarding entry points.

The system must keep stable boundaries for a future iOS native client, Session sharing, Automation, and a central control plane. Web reachability is enabled explicitly by the user; neither the Desktop nor the headless daemon opens a public entry point by default.

## 2. First Principles

1. Sessions belong to Hosts, Tabs belong to Windows, Runtimes belong to Sessions. An open Tab holds one Session; closing the Tab also ends that Session and its Runtime.
2. Workspaces and Terminal Groups are the isolation boundaries for terminal Tabs; Workspaces remain the isolation boundary for Git-aware async commands.
3. Ghostline is the sole terminal Runtime; the Runtime boundary remains replaceable without becoming a product domain model.
4. In Warren v1, an open Tab corresponds to one Warren Terminal Session; closing a Tab explicitly terminates that Session's Runtime. Switching Workspaces or quitting the Client does not additionally terminate Tabs/Sessions that are still retained in the client layout.
5. Only Close Tab or an explicit Terminate Session ends a Runtime; switching Workspaces, detaching, and quitting the Client never end a still-running Session.
6. The UI only displays projections and sends typed intents; it never directly manipulates the Runtime, the daemon store, or the Ghostty lifecycle.
7. Every state kind has exactly one write authority; caches and projections must not become a second authority.
8. Every async operation carries an immutable target ID and Request ID; it never infers its target from the current selection when it completes.
9. Local and future network connections share the same application protocol.
10. Observability is a product capability, not a test patch.

## 3. Shared Terminology

### 3.1 Resources

**Host**: execution node holding the real state of Tasks, Projects, Workspaces, Terminal Sessions, and Runtimes. A Host is a `warren-headless` daemon, either on the current Mac or on a remote VPS.

**Task**: Host-owned work context that aggregates related Workspaces across Projects. A Task may carry a provider-neutral `source` and `externalID` pair plus an HTTP(S) URL for an external work item. It does not own repositories, working directories, Sessions, or Runtimes.

**Project**: identity of a Git repository. Projects organize Workspaces; they are not terminal working directories.

**Workspace**: a concrete, accessible local working directory under a Project, together with its Git context. The main checkout and worktrees are both Workspaces. A Workspace may additionally belong to one Task for cross-Project aggregation. A Workspace ID is stable identity; branch and path are mutable attributes.

**Terminal Group**: Host-owned ordered container for standalone terminal Sessions that are not tied to a Project or Workspace. The first Group is the default destination for newly created standalone Sessions. A Group may define a default startup directory; otherwise the Host user's home directory is used.

**Session Scope**: the single ownership context of a Terminal Session. A Scope is either a Workspace or a Terminal Group; a Session never belongs to both.

**Terminal Session**: interactive terminal context on a Host. It belongs to exactly one Session Scope and is accessed through an open Tab; closing the Tab ends the Session. Sessions still running when the Client quits can be kept by the Host and restored after restart.

**Runtime Binding**: persistent mapping from a Terminal Session to its Ghostline PTY. The binding is recovery metadata, not a second terminal resource.

### 3.2 Clients

**Device**: stable device identity. Phase one only has the current Mac, but the model must not assume there is always exactly one device.

**Client Instance**: one run of the app. It is invalidated when the app quits.

**Client Window**: independent navigation and layout scope. Each Window independently stores its Active Session Context and Workspace or Terminal Group Views.

**Workspace View**: local presentation state a Window keeps for a Workspace, including ordered Tabs and the Active Tab.

**Terminal Group View**: local presentation state a Window keeps for a Terminal Group, including ordered Tabs and the Active Tab.

**Tab**: local entry in a Workspace View that points to a Terminal Session. In Warren v1, an open Tab corresponds to one Session; closing a Tab terminates that Session's Runtime. The same active Session is not opened twice within one Workspace View.

**Renderer Surface**: Ghostty surface a client mounts for a Tab. A Surface does not own a Session.

**Attachment**: temporary connection between a Client Instance and a Terminal Session. Future sharing is built from multiple Attachments on the same Session.

**Input Lease**: exclusive lease that lets one Attachment send input to a Session.

**Canonical Viewport Owner**: the only participant allowed to change PTY row/column counts. In phase one, the Input Lease holder also serves this role; observers must not resize the PTY.

### 3.3 Import and Automation

**Superset Import**: onboarding operation that reads Project and Workspace metadata from Superset's CLI JSON output and copies it into Warren-owned data in one pass. It is not a sync.

**Import Receipt**: durable record of a successful import, containing source, version, time, and summary. After success, Warren no longer prompts automatically or re-imports.

**Automation Run**: in a later version, a non-human task with a clear start, exit status, and retention policy. It may use a Terminal Session to show progress, but must not infer completion from Tabs or prompts.

## 4. Authority Model

```text
Resource Authority
Selected Host
├── Task ··· aggregates zero or more Workspaces
├── Project
│   └── Workspace
│       └── Terminal Session
│           └── Runtime Binding
└── Terminal Group
    └── Terminal Session
        └── Runtime Binding

Presentation Authority
Device
└── Client Instance
    └── Client Window
        ├── Active Workspace
        ├── Active Session Context
        └── Workspace / Terminal Group Views
            └── Tabs / Active Tab

Connection Authority
Terminal Session
└── Attachments
    ├── Input Lease
    └── Canonical Viewport Owner
```

| State | Single authority | Persisted |
| --- | --- | --- |
| Tasks, Projects, Workspaces, Terminal Groups, Sessions | Host Store | Yes |
| Task, Project, Workspace, and Terminal Group sidebar order | Host Store | Yes |
| Runtime Bindings, Session state | Host Store | Yes |
| PTY output recovery position | Host Output Store | Yes |
| Windows, Workspace / Terminal Group Views, Tabs | Client Layout Store | Yes, device-local |
| Attachments, Leases, Viewport Owners | Host in-memory state | No |
| Agent status (activity plus human attention) | Host in-memory state | No |
| Surfaces, focus, measured size | Renderer Coordinator | No |
| Import completion state | Import Receipt Store | Yes |

## 5. Required Invariants

1. A Workspace belongs to exactly one Project and at most one Task.
2. A Task may aggregate Workspaces from any Project on the same Host but never changes their Project ownership.
3. A Task's `source` and `externalID` are either both absent or both present; their pair is unique within a Host.
4. Deleting a Task only detaches its Workspaces and never deletes Workspaces, Sessions, files, or Git worktrees.
5. A Terminal Session belongs to exactly one Session Scope: a Workspace or a Terminal Group.
6. A Tab belongs to exactly one Window's Workspace View or Terminal Group View and references only Sessions in that context.
7. The top Tab bar shows only Tabs of the Active Session Context.
8. Switching Workspaces or Terminal Groups must atomically switch Tabs, the Active Tab, and the Renderer Set.
9. A Window has exactly one Active Session Context; each context View has at most one Active Tab.
10. Background Workspaces and Terminal Groups mount no Surfaces and send no input or resize.
11. A Session has at most one Input Lease and one Canonical Viewport Owner.
12. In Warren v1, closing a Tab terminates its Runtime; it is not merely a detach. Ended Session records without a Tab can be retained for history and later cleanup.
13. Adding a Project creates a Workspace; adding a Workspace or Terminal Group Tab-bar entry creates a Session.
14. Creating a Session must carry a fixed Session Scope and Request ID; the same Request ID creates at most one Session.
15. App initialization must not auto-create shell, Codex, or Claude Sessions.
16. Selecting a Workspace with no Tabs may idempotently create its default Shell Tab; selecting an empty Terminal Group does not start a process until the user creates a Terminal.
17. The app allows only one foreground Client Instance; repeated launches activate the existing instance and then exit.
18. Quitting the app must end the Client process but must not kill created Runtime sessions (ghostline PTYs or tmux sessions).
19. Import must not modify Superset data, Git repositories, worktrees, or runtimes.
20. A Host always has at least one Terminal Group when a standalone Session is created; the first ordered Group is the default.
21. Deleting a Terminal Group must not silently terminate its running Sessions; Sessions must be moved to another Group or explicitly terminated.

## 6. Module Boundaries

```text
macOS UI
  ↓ typed intents / screen projections
Client Application
  ├── Client Layout Store
  └── Renderer Coordinator → Ghostty Adapter
  ↓ versioned WebSocket API
warren-headless
  ├── Resource Service
  ├── Session Service
  ├── Import Service
  ├── JSON Host Store
  └── Terminal Runtime → Ghostline Adapter
```

Dependencies may only point inward to protocol and domain values. SwiftUI, Ghostty, Ghostline, the Superset schema, and WebSocket are edge adapters.

### 6.1 Future Extension Boundaries

```text
macOS / iOS / Web Client
        ↓
Endpoint Resolver
        ↓
Local IPC / Direct WebSocket / Relay Transport
        ↓
warren-headless daemon
```

The macOS Client uses a versioned WebSocket API for both Local and Server. `warren-headless` is the deployment form of a Host, owning an independent resource tree and Ghostline runtime. Switching endpoints only replaces the client projection and renderer; it does not migrate or terminate resources on the other Host.

SSH only bootstraps the remote daemon and forwards a loopback port. Once `warren ssh` establishes reachability, Desktop and CLI continue over the same WebSocket API; Git, Runtime, and resource semantics must not be encoded into the SSH transport.

LAN and SSH only provide network reachability; the central Relay Service provides
Host registration, discovery, pairing, revocation, signaling, public routes, and
WebSocket relay. Sessions and processes remain owned by the Host.

The daemon serves the Web UI over HTTP on `0.0.0.0:8789` (Desktop and CLI keep using the loopback address) and over HTTPS on `0.0.0.0:8788` for LAN devices; the HTTPS listener uses a locally generated CA so phones only need to trust it once. Public Access uses an explicitly configured Relay route and reports a credential-free Public Endpoint. Warren Web authentication still requires the daemon token at the WebSocket boundary; route status APIs return only canonical public URLs, while explicit browser-open actions add authentication at the last possible moment. Slow Web clients use a bounded non-blocking send queue and must never block the macOS main thread or Host output.

The Web/PWA client uses React + Vite, with source in `Web/`. React owns the component tree and client state; xterm owns terminal rendering. `Web/dist` contains build output only and is embedded by both the Go daemon and the Go Relay Service; do not maintain single-file inline copies of the script.

The remote control plane is an independently deployable process. Each Host reuses its daemon token as the Host Secret and only makes one outbound WSS connection to the Relay; the Relay multiplexes Web clients by connection ID and never connects to an inbound macOS port. A seven-day-by-default pairing code and client-facing ticket are reusable during their sharing window, while each exchange receives a short-lived Ed25519 capability bound to the Host, scope, route, client, and credential generation. Revoking or rotating a Host credential must disconnect the Host immediately and invalidate old capabilities and tickets. The Relay persists credential hashes, generations, and online metadata, but never Project/Workspace/Session state, terminal output, or user input. Public deployments must sit behind TLS, enforce a strict Origin, use strong random secrets, and use a persistent data volume.

Session sharing is added incrementally through Principals, Share Grants, Capabilities, and multiple Attachments, without changing the resource tree.

### 6.2 Git Panel

The daemon owns all Git execution. Workspace-scoped typed intents:

- `git.panel` { workspace } -> GitPanel (branch, upstream, ahead/behind, remote, changes, commits, branches)
- `git.diff` { workspace, path, staged, commit } -> GitDiff (full file content and unified diff at the selected version)
- `git.checkout` { workspace, branch, create } -> GitCommandResult
- `git.pull` { workspace } -> GitCommandResult
- `git.push` { workspace } -> GitCommandResult
- `git.pr.create` { workspace, title, body } -> GitPullRequest

`git.panel` also reports the hosted pull request for the current branch
(`pullRequest`, or `pullRequestError` when the GitHub/GitLab CLI cannot be
used). Pull requests are created against the repository's main branch
(origin/main, falling back to origin/master) using `gh` or `glab` depending
on the origin host.

Read commands run with a 60-second timeout and never interpolate shell
input; only `git -C <path>` with fixed argument arrays is used.

## 7. Data Design

Host resource state is owned by the `warren-headless` daemon and persisted
atomically in JSON. The daemon serializes writes through one mutex and commits
with a temp-file rename; every commit bumps a revision used for change
broadcasts.

Default files under `~/.warren/`:

```text
~/.warren/
├── state.json        # Tasks, Projects, Workspaces, Sessions, sidebar order, runtime bindings, import receipts
├── config.json       # CLI/Desktop endpoint list and current endpoint
├── settings.json     # daemon settings such as defaultRuntime, Relay metadata, and route intent
├── token             # authentication token
├── output/           # Ghostline-owned durable output history
├── worktrees/        # Git worktrees created by Warren
├── ghostline.sock    # detached Ghostline server socket
└── tls/              # LAN HTTPS local CA and certificates
```

Tests override state path, output directory, runtime socket, and worktree root
through explicit flags or environment variables without touching user data.

Minimal data set in `state.json`:

- Host identity and display name.
- Tasks, Projects, Workspaces, Terminal Groups, and their sidebar order.
- Terminal Sessions with lifecycle and output position (`epoch`/`sequence`).
- Runtime Bindings with the Ghostline runtime identifier and recovery metadata.
- Superset Import Receipts and request receipts for idempotency.

Client window layout and Tabs are device-local presentation state, not Host
resources; the desktop persists navigation preferences locally.

Constraints:

- Task external identities are provider-neutral and unique by `source` plus `externalID` when present.
- Workspace Task membership is optional and single-valued; changing Tasks requires an explicit detach followed by attach.
- Projects are deduplicated by normalized repository identity.
- Workspaces are deduplicated by normalized real path within a Host.
- A Session belongs to exactly one Session Scope.
- A Terminal Group home path is Host-local and is used as the startup working directory for new Group Sessions.
- Runtime Binding records the engine a Session was created with and never
  migrates Sessions between engines.
- Sidebar order is normalized within each Host.
- Output positions are monotonic per Session and drive recovery anchors.

State schema 2 introduces Tasks and optional Workspace membership. The Host
automatically migrates schema 1 and immediately persists schema 2. Future or
unknown schemas fail closed so an older binary cannot silently discard Task
data.

## 8. Superset One-Time Import

### 8.1 Source

Superset Import uses Superset's public CLI JSON interface
(`superset projects list --local --json` and
`superset workspaces list --local --project <id> --json`) instead of parsing
private SQLite schema. The CLI is resolved from `~/.superset/bin/superset`,
`PATH`, or the `SUPERSET_CLI_PATH` environment variable. Reads must stay
read-only; Warren must not assume Superset's future schema stays unchanged.

Imported objects:

- `projects`: name, main repository path, and available Git metadata.
- `worktrees`: working directory, branch, and owning main repository.
- `workspaces`: display name, order, and relationship to a worktree or the main checkout.

Explicitly not imported:

- runtime sessions, terminal tabs, panes, terminal output.
- Superset accounts, organizations, tasks, Automations, and cloud identities.
- UI window state and credentials.

### 8.2 Flow

```text
Select Import from Superset
→ query Superset CLI JSON read-only
→ build candidate Projects/Workspaces
→ validate realpath, Git common-dir, and branch
→ show importable, duplicate, missing, and invalid summary
→ write Warren IDs in one atomic daemon state update
→ write Import Receipt
→ select the first valid Workspace
```

On failure the whole transaction rolls back, leaving no half-imported data or Receipt. After success, Warren no longer checks Superset automatically and sets up no file watchers. Re-import is an explicit diagnostic capability, not part of the phase-one main flow.

## 9. Session and Runtime Design

### 9.1 Mapping

One Terminal Session maps to one Ghostline PTY. Runtime implementation details
are never exposed as UI domain objects.

Runtime identifiers are derived from the Warren Session ID, never from user
titles, branches, or paths, so renaming or character escaping cannot affect
identity.

### 9.2 Creation

```text
CreateSession(sessionScope, launchSpec, requestID)
→ validate Workspace or Terminal Group and request idempotency
→ subscribe to Runtime output
→ create the Ghostline PTY
→ resolve Group home or Workspace path, then set working directory, TERM, size, and shell environment
→ start the cursor output subscription
→ persist Session and Runtime Binding
→ return resource events
→ Client Layout creates and activates the Tab
```

The interactive shell starts directly as the foreground process of the PTY.
Preset commands must not simulate keystrokes after a fixed sleep;
the Runtime must provide a reliable way to start commands and preserve a full
interactive TTY.

### 9.3 Input

Ghostline writes input bytes to the PTY verbatim. Special keys and signals use
explicit operations; control actions such as `Ctrl-C` are never encoded as
ordinary business strings.

Any input must validate the Attachment, Input Lease, and Session lifecycle. Input failure must not break the connection or the app globally.

### 9.4 Output and Color

Ghostline exposes raw PTY bytes through a durable cursor stream. The Host does
not strip ANSI, OSC, Unicode, or control sequences; Ghostty and xterm parse and
render them on the client side, so colors from Codex, Claude, shells, and TUIs
are preserved.

Output goes to both:

- a bounded in-memory ring: low-latency broadcast and short-term recovery;
- Ghostline-owned durable output history: cursor continuation after Host restart.

Every byte position is identified by `epoch + sequence`. On reconnect, a client requests its last Recovery Anchor; the Host sends catch-up bytes or reanchors, never silently skipping gaps.

### 9.5 Size and Focus

Only the Active Tab Surface of the Active Session Context can take local keyboard focus. Only the Canonical Viewport Owner can resize the PTY.

Resize uses one worker per Session with latest-wins semantics; after a Surface becomes active, row/column counts are forcibly recomputed from the actual visible area once. Layout callbacks from hidden Surfaces are discarded.

### 9.6 Close, Quit, and Recovery

- Close Tab: terminate the Runtime, record the Session as ended, then remove the local Tab and Surface; ended Sessions cannot be reopened, only a new Tab/Session can be created.
- Detach: disconnect one Attachment without ending the Session.
- Terminate Session: ask the Runtime to end the Ghostline PTY
  and record ended state.
- Quit Client: stop UI, connections, and observation tasks; the Runtime keeps
  running.
- Relaunch: the daemon restores resources, and the Runtime Adapter detects and
  adopts live Ghostline PTYs; missing Runtimes are marked
  ended and must not stay stuck in connecting.

The detached Ghostline server owns PTY lifecycle. The daemon reconciles its
Session records against Ghostline without per-Session polling processes.
Transient probe failures do not produce ended events.

## 10. macOS Interaction Design

The UI information architecture follows Superset's proven base relationships without copying its domain implementation:

```text
Window
├── Sidebar
│   ├── Terminal Groups
│   ├── Tasks
│   │   └── Workspaces from any Project
│   └── Projects
│       └── Workspaces
└── Session Context Screen
    ├── Top Bar
    ├── Context-scoped Tab Bar
    ├── Preset Bar with Terminal / Editor mode
    └── Active Workspace Content
        ├── Terminal
        └── Embedded Editor (local Workspace only)
```

Behavior requirements:

- The initial empty state keeps Import and Add Project available, may also offer Task creation, and creates no Sessions.
- Tasks provide a second navigation projection over existing Workspaces; they never replace Project ownership or duplicate Session state.
- Task rows show linked Workspaces across Projects with enough Project context to disambiguate identical Workspace names.
- Attaching and detaching a Workspace is explicit. Deleting a Task leaves its Workspaces and Sessions reachable under Projects.
- Projects are collapsed by default; Workspaces appear only after explicit expansion, and newly added Projects are collapsed by default.
- Besides a dedicated add button, the whole Project row is the expand/collapse hot zone; expanding does not implicitly create a Session.
- The whole Workspace row is the hot zone for selecting and entering a Session; no small, easy-to-misclick add buttons remain.
- The Terminal Groups section appears above Projects, has a fixed height of at most three rows, and scrolls internally when more Groups exist.
- Each Terminal Group row shows the Group identity and aggregate Session state; individual Group Sessions appear in the context-scoped Tab Bar.
- Clicking a Workspace must switch immediately without waiting for the daemon, Git, or disk operations.
- Clicking a Terminal Group switches the active Session Context immediately; selecting an empty Group keeps the pane blank until the user creates a Terminal through the Tab Bar or `Command+T`.
- After clicking a Workspace with no Tabs, show a non-interactive `Starting Shell…` loading Tab and content progress state immediately, then create the default Shell in that Workspace's serial command queue. Rapid repeated clicks share the same in-flight operation; on success the loading Tab is replaced in place; on failure it is removed and a recoverable error is shown. If the user has already navigated elsewhere, the creation result must not steal the selection back.
- Clicking a Tab must switch the Active Session immediately and hand focus to Ghostty.
- Presets create a Session in the Workspace captured at click time; switching Workspaces must not change the in-flight request target.
- A local Workspace may open Editor from the top-right IDE control and switch between Terminal and Editor in the Preset Bar. This is client presentation state: it does not create, close, move, or relabel a Terminal Session.
- The Terminal Surface stays mounted while Editor is visible so switching modes cannot discard terminal grid, recovery, or focus state. The editor surface may be recreated when it is closed.
- The embedded-editor MVP is Desktop- and Local-endpoint-only. It starts one `code-server` child process for the visible Workspace, binds it to a random `127.0.0.1` port, and terminates it when the editor closes or the endpoint changes.
- `code-server` uses a Warren-owned user-data and extension directory. Go and rust-analyzer installation starts only after the editor is ready and runs as a background utility task; existing VS Code and Cursor profiles are outside Warren ownership.
- The embedded workbench uses Warren's Ember palette, keeps File Explorer on the right, and hides duplicate global chrome through supported VS Code settings. Tabs, breadcrumbs, status, diagnostics, Quick Open, Search, Problems, and diff remain available; Warren-managed settings override those UI keys while preserving unrelated valid JSON profile settings.
- A missing editor executable, startup timeout, or server exit must leave Terminal usable and show a retryable Editor state.
- While focus is inside the embedded editor, Warren menu equivalents yield to the WebView so editor commands such as `Command+T`, `Command+W`, `Command+F`, `Command+K`, and `Command+B` remain available. Warren shortcuts resume when focus returns to its chrome or Terminal.
- The MVP does not expose its loopback listener through Public Access, Relay, or `warren-headless`. Remote Workspace editing requires a later Host-owned service with Warren authentication instead of a client-local path assumption.
- In Terminal Group mode, `Command+T` creates a shell in the captured Group; in Workspace mode it preserves the existing Workspace target.
- The Tab add button sits right after the last Tab; with no Tabs it sits at the start position.
- The workspace Tab bar trailing controls have a locked priority: `External IDE → Execution Server → Public Access → Notifications → Settings`. `Execution Server` is only visible when more than one endpoint exists and occupies the second slot; `Settings` stays in the overflow (`⋯`) unless all visible controls fit without overflow. The Preset bar uses a `light` weight intentionally so it remains subordinate to Tabs and Terminal.
- Icons that are meaningless, actionless, or redundant are not shown.
- Typography, density, spacing, hierarchy, and hover/selected states use the Superset macOS Desktop as the phase-one visual baseline; the terminal itself uses monospace fonts and Ghostty theme capabilities.
- Every interactive element must have a stable Accessibility Identifier, Role, Label, Value, and an executable Action.
- In the custom frameless window, only an explicit empty chrome leaf node at the top may call AppKit `performDrag`; Tabs, buttons, and the terminal must not inherit window dragging.
- Agent activity and human attention follow [RFC 0006](docs/rfc/0006-agent-activity-attention.md); the RFC is the authority for the status model, provider event mapping, and wire contract.
- A Workspace aggregates explicit Session status across all Host Sessions, prioritized `failed > attention/blocked > stalled > working > ready > exited`; it must not look at only the current Tab.
- Superset-style status dots: failed red breathing, attention/stalled yellow breathing, working amber breathing, ready green static, exited gray static.
- Agent activity is reported by Claude/Codex Hooks managed by Warren, or by the current OpenCode SQLite projection. Hooks read only the event type and `WARREN_SESSION_ID`; they never read or upload conversation content. Config merging must preserve user entries and update idempotently. Every Warren session inherits the binding environment, so a CLI started manually inside a plain Shell tab is promoted to an agent overlay while it runs and demoted back to shell after `SessionEnd`.
- Structured Web projections are fed by the agent CLI's own local transcript (JSONL for Codex/Claude, SQLite rows for current OpenCode), tailed by the Host and normalized into `agent` events. The transcript never leaves the Host and never replaces the PTY stream: if a transcript is missing or its format changes, the session remains a plain terminal.
- Transcripts are bound to Warren sessions by the CLI's own conversation ID, never guessed from cwd alone: Claude is started with `--session-id` (deterministic transcript path), Codex reports `session_id`/`transcript_path` through the Warren-managed `SessionStart` hook into `~/.warren/agent-bind/`, and OpenCode is bound to its SQLite session ID discovered after launch. The cwd+mtime finder is only a fallback for Codex/Claude.
- When Warren launches Codex, it uses `--dangerously-bypass-hook-trust` only to trust the Warren-generated and -validated Hook; it must not bypass Codex command approval or sandbox.

Embedded-editor review risks and mitigations:

- Business and coupling: Editor mode is not a Session or Runtime and sends no Host intent; the Composition Root owns its process and injects an editor surface into Desktop chrome.
- Interaction: the existing top-right IDE control opens Editor; the mode picker retains Terminal navigation, semantic actions, loading, unavailable, failure, and retry states. Terminal remains the default and Terminal Groups are unchanged.
- Compatibility: UI trimming uses supported VS Code settings instead of DOM or CSS injection. This avoids version-fragile selectors; an invalid hand-edited profile settings file produces a recoverable Editor error instead of being overwritten.
- Performance: no editor process starts during app launch or ordinary Terminal use. Profile preparation performs no extension command or network download; extension installation begins only after server readiness and runs in the background, and only one visible editor process is retained.
- Out-of-the-box use: `code-server` is an explicit optional prerequisite with a Homebrew command, executable override, isolated writable data, and a recoverable missing-tool state.
- Security: the unauthenticated editor listener is restricted to a random loopback port and dies with the client surface. It is never bound to LAN or routed through Warren Public Access.

## 11. Web/PWA Interaction Design

The Web Client uses the same Project → Workspace → Session information architecture as the desktop and follows these rules:

- Desktop width shows a fixed Sidebar, horizontal Session Tabs, Preset Bar, and Terminal.
- Mobile width uses a closable Sidebar drawer, horizontally scrollable Tabs, and a bottom safe-area shortcut bar.
- The PWA provides a manifest, maskable icons, standalone mode, and shell caching; the pairing token is stored locally in the browser after first authentication so the installed app can start from `start_url`.
- Offline, the PWA shows only the cached UI shell and a disconnected state; it never fakes Host or Session availability.
- Web Attachments are distinct identities from Desktop Attachments; both ends can observe simultaneously. Only an Attachment that actually sends input or resizes acquires the Control Lease with last-writer-wins semantics.
- Creating a Session on Web shows loading immediately; when the Host returns the new Session ID, attach directly instead of waiting for the next roster guess.
- Touch arrow keys send real ANSI cursor sequences; Esc, Tab, Ctrl-C, and Ctrl-D send real control bytes.
- Codex and Claude sessions may render an Agent view from normalized transcript events instead of an emulated TUI; the terminal stays available through a pane-title toggle and remains the input authority.

Performance goals:

- Local navigation and Tab switching complete in one main-thread transaction without waiting for I/O.
- Each runtime lifecycle observation round starts at most one query process; query frequency does not grow with Session count.
- Input writes to the Runtime must not be blocked by persistence or the global Snapshot.
- PTY output must not be backpressured by database writes.
- A single Workspace failure must not freeze other Workspaces or the whole window.

### 11.1 Visual Tokens

Both clients share one visual language sourced from the Ember dark palette
already used by the terminal renderer. The macOS DesignSystem
(`WarrenColorTokens`, `WarrenSpacing`, `WarrenRadius`, `WarrenTypography`) is
the semantic source of truth; the Web client mirrors the same roles as CSS
custom properties in `Web/src/style.css`:

- Surfaces: page background `#151110`, chrome/sidebar `#1c1918`, popovers
  `#201e1c`, inputs `#181615`; borders and separators stay within the
  `#2a2827`/`#3a3837` range.
- Text: primary `#eae8e6`, secondary `#a8a5a3`, links `#7ec0f5`, danger
  `#e88888`.
- Accent: interactive/focus uses `#e07850`; brand cursor uses `#f59e0b`.
- Status: working `#f59e0b`, waiting `#e5c07b`, ready/success `#7ec699`,
  failed/danger `#dc6b6b`, exited/connecting neutral `#a8a5a3`.
- Spacing: one scale (`1/2/4/6/8/12/16/24/32/40px`) with the same semantic
  names as `WarrenSpacing`.
- Radius: `4/6/8/10/12px` tiers matching `WarrenRadius`, plus full-pill
  (`999px`) for chips, toggles, and sheets.
- Typography: UI text is 13px by default, chrome metadata 10–12px, headings
  17–20px; Settings and business dialogs use the scoped 18–22px title and
  13–14px body tiers. Light weights are display-only titles; regular is the
  default for functional labels, and medium is reserved for destructive
  confirmation actions or explicit critical states.
- Status: success `#7ec699`, warning `#e5c07b`, info `#61afef`, amber working
  `#f59e0b`, failed/destructive `#cc4444`, exited neutral `#a8a5a3`.

Web components must reference semantic CSS variables, never raw hex values.
Focus rings use the accent token, hover treatments are gated behind
`@media (hover: hover)`, and all motion honors `prefers-reduced-motion`.

The macOS client shares one presentation vocabulary through
`WarrenDesignSystem` primitives: `warrenPresentationSurface(role:)` with
`WarrenPresentationRole` and `WarrenPresentationLayer` for every floating
surface (command palette, Web panel, endpoint popover, terminal search), and
`WarrenModalSurface` / `WarrenSheetSurface` / `WarrenMessageDialog` /
`WarrenTextInputDialog` / `WarrenInputField` / button styles for dialogs,
inputs, and confirmations. Settings, rename dialogs, delete confirmations,
workspace creation, Superset import, and progress overlays all use these
primitives instead of system alerts, sheets, rounded-border fields, or
per-screen radius/shadow values. OS-owned folder and application selection
still uses `fileImporter` / `NSOpenPanel`; global and context menus remain
native, sharing action labels and ordering with the Web client.

The Web client mirrors the same roles with `--layer-*` CSS variables, the
`warren-dialog` primitives for rename/delete flows, `worktree-dialog` and
`session-sheet` surfaces, and dialog semantics on the mobile context menu.

## 12. Non-Intrusive Observability and Acceptance Design

Acceptance must not depend on screenshots, must not move the mouse, and must not steal keyboard focus from the user's current app.

### 12.1 Three Observation Layers

**Domain event log**: every command and state transition emits a structured event with monotonic timestamp, trace ID, request ID, window ID, workspace ID, session ID, old state, target state, result, and error. Credentials and full user input must never be logged.

**Semantic UI snapshot**: the real Views expose a read-only semantic tree with Accessibility Identifier, role, label, value, enabled, selected, focused, frame, and children. It describes what the user can operate on, without pixels.

**Terminal probe**: records Runtime state, actual PTY dimensions, Attachment/Lease, input sequences, Recovery Anchor, raw output summaries, and parsed cell/style summaries. Color acceptance reads post-ANSI cell attributes, never screenshots.

### 12.2 Test Execution

Tests use an isolated temporary directory and an isolated daemon/runtime:

```text
Warren Test Process
├── data-dir = mktemp
├── runtime socket = warren-test-<uuid>
├── deterministic clock / request IDs
├── offscreen, never-key NSWindow
└── test observation socket
```

The real SwiftUI Root View is mounted in an `orderOut`'d NSWindow. Tests click, select, type, and resize through Accessibility Actions or direct event dispatch; they must not use CGEvent to move the global mouse, must not call `NSApp.activate`, and must not call `makeKeyAndOrderFront`.

The Observation Socket only opens under an explicit test launch argument, uses a random temporary Unix socket, and provides:

- `snapshot.resources`
- `snapshot.window`
- `snapshot.accessibility`
- `snapshot.renderer`
- `snapshot.runtime`
- `events.since(sequence)`
- `intent.perform(identifier, action)`
- `wait.until(predicate, timeout)`

Production builds disable this entry point by default. Test actions must still go through the same typed intents as the real UI; directly tampering with the Store to fake a pass is forbidden.

### 12.3 Acceptance Evidence

Each end-to-end case outputs one machine-readable artifact:

```text
artifacts/<run-id>/
├── result.json
├── event-trace.jsonl
├── semantic-ui.json
├── runtime.json
└── terminal-cells.json
```

Failure reports must identify the last successful invariant, the first violating event, related resource IDs, and a reproducible command. Tests must verify at the end that the user's mouse coordinates and foreground app PID did not change.

## 13. Out of Scope for Phase One

- Multi-user accounts, organizations, billing, and cross-organization Host directories.
- Automatic Host registration or automatic public entry points.
- iOS native client.
- Multi-person sharing and permission UI.
- Automation scheduler.
- Native split Pane layouts inside a client Tab; the intended boundary and
  historical nested-terminal workaround are recorded in
  [RFC 0008](docs/rfc/0008-native-tab-splits.md), which is Deferred.
- Runtime multi-window/pane to UI Pane mapping.
- Cross-device real-time Client Layout sync.
- CRDT.

These capabilities can only be added incrementally through the defined Host Protocol, Transport, Principal/Capability, Attachment, and Runtime boundaries; they must not pollute the phase-one model retroactively.
