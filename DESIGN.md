# Warren Product and System Design

Status: single source of truth for system architecture and domain design
Scope: product, domain model, architecture, terminal runtime, agent views, and client contracts
Update rules: when implementation conflicts with this document, this document wins; design changes must update this document in the same commit

## 1. Product Goals

Warren is a local-first development workbench organized around Workspaces, with durable terminal sessions and AI agent workflows at its core.

The macOS Desktop connects to a local `warren-headless` daemon by default, and can also connect to `warren-headless` running on a VPS or remote server. Users can switch between Local and Server to manage Tasks, Projects, Workspaces, Git worktrees, and Terminal Sessions on the target Host, with persistent terminal interaction through Ghostty. The CLI uses the same remote API and provides SSH bootstrap and port-forwarding entry points.

Warren defines a clear three-surface client hierarchy:
1. **macOS Desktop (Primary First-Class Surface)**: Native AppKit and SwiftUI components, keyboard-driven navigation, low-latency Ghostty terminal rendering, embedded workspace editor (`code-server`), and Raycast integration.
2. **Web / PWA (Remote & Fallback Surface)**: Lightweight remote viewer, browser access, and execution control through the Relay Service under Public Access.
3. **iOS Mobile (Native Companion)**: Companion mobile client in active development, distributed separately as a proprietary client.

Web reachability and Public Access are enabled explicitly by the user; neither the Desktop nor the headless daemon opens a public network entry point by default.

## 2. First Principles

1. Sessions belong to Hosts, Tabs belong to Windows, Runtimes belong to Sessions. An open Tab holds one Session; closing the Tab also ends that Session and its Runtime.
2. Workspaces and Terminal Groups are the isolation boundaries for terminal Tabs; Workspaces remain the isolation boundary for Git-aware async commands.
3. Ghostline v1 is the sole terminal Runtime; server-side PTY emulation via `libghostty-vt` provides deterministic output streaming and checkpoint recovery.
4. In Warren, an open Tab corresponds to one Warren Terminal Session; closing a Tab explicitly terminates that Session's Runtime. Switching Workspaces or quitting the Client does not terminate Sessions retained in the Host layout.
5. Only Close Tab or an explicit Terminate Session ends a Runtime; switching Workspaces, detaching, and quitting the Client never end a still-running Session.
6. The UI displays projections and sends typed intents; it never directly manipulates the Runtime, the daemon store, or the Ghostty lifecycle.
7. Every state kind has exactly one write authority; caches and projections must not become a second authority.
8. Every async operation carries an immutable target ID and Request ID; it never infers its target from the current selection when it completes.
9. Local and remote network connections share the same versioned application protocol.
10. Observability is a product capability, not a test patch.

## 3. Shared Terminology

### 3.1 Resources

**Host**: execution node holding the real state of Tasks, Projects, Workspaces, Terminal Sessions, and Runtimes. A Host is a `warren-headless` daemon, either on the current Mac or on a remote VPS.

**Task**: Host-owned work context that aggregates related Workspaces across Projects. A Task may carry a provider-neutral `source` and `externalID` pair plus an HTTP(S) URL for an external work item. It does not own repositories, working directories, Sessions, or Runtimes.

**Project**: identity of a Git repository. Projects organize Workspaces; they are not terminal working directories.

**Workspace**: a concrete, accessible local working directory under a Project, together with its Git context. The main checkout and worktrees are both Workspaces. A Workspace may additionally belong to one Task for cross-Project aggregation. A Workspace ID is stable identity; branch and path are mutable attributes.

**Terminal Group**: Host-owned ordered container for standalone terminal Sessions that are not tied to a Project or Workspace. The first Group is the default destination for newly created standalone Sessions. A Group may define a default startup directory; otherwise the Host user's home directory is used.

**Session Scope**: the single ownership context of a Terminal Session. A Scope is either a Workspace or a Terminal Group; a Session never belongs to both.

**Terminal Session**: interactive terminal context on a Host. It belongs to exactly one Session Scope and is accessed through an open Tab; closing the Tab ends the Session. Sessions still running when the Client quits are kept by the Host and restored after restart.

**Runtime Binding**: persistent mapping from a Terminal Session to its Ghostline PTY. The binding is recovery metadata, not a second terminal resource.

### 3.2 Clients and Surfaces

**Device**: stable device identity.

**Client Instance**: one run of the app. It is invalidated when the app quits.

**Client Window**: independent navigation and layout scope. Each Window independently stores its Active Session Context and Workspace or Terminal Group Views.

**Workspace View**: local presentation state a Window keeps for a Workspace, including ordered Tabs and the Active Tab.

**Terminal Group View**: local presentation state a Window keeps for a Terminal Group, including ordered Tabs and the Active Tab.

**Tab**: local entry in a Workspace View that points to a Terminal Session. In Warren, an open Tab corresponds to one Session; closing a Tab terminates that Session's Runtime. The same active Session is not opened twice within one Workspace View.

**Renderer Surface**: Ghostty surface a client mounts for a Tab. A Surface does not own a Session.

**Attachment**: temporary connection between a Client Instance and a Terminal Session. Multiple Attachments on the same Session enable multi-client observation.

**Input Lease**: exclusive lease that lets one Attachment send input to a Session.

**Canonical Viewport Owner**: the only participant allowed to change PTY row/column counts. The Input Lease holder serves this role; observers do not resize the PTY.

### 3.3 Import and Automation

**Superset Import**: onboarding operation that reads Project and Workspace metadata from Superset's CLI JSON output and copies it into Warren-owned data in one pass. It is not a sync.

**Import Receipt**: durable record of a successful import, containing source, version, time, and summary. After success, Warren no longer prompts automatically or re-imports.

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
| :--- | :--- | :--- |
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
12. Closing a Tab terminates its Runtime; it is not merely a detach. Ended Session records without a Tab can be retained for history and later cleanup.
13. Adding a Project creates a Workspace; adding a Workspace or Terminal Group Tab-bar entry creates a Session.
14. Creating a Session must carry a fixed Session Scope and Request ID; the same Request ID creates at most one Session.
15. App initialization must not auto-create shell, Codex, or Claude Sessions.
16. Selecting a Workspace with no Tabs may idempotently create its default Shell Tab; selecting an empty Terminal Group does not start a process until the user creates a Terminal.
17. The app allows only one foreground Client Instance; repeated launches activate the existing instance and then exit.
18. Quitting the app must end the Client process but must not kill created Runtime sessions (ghostline PTYs).
19. Import must not modify Superset data, Git repositories, worktrees, or runtimes.
20. A Host always has at least one Terminal Group when a standalone Session is created; the first ordered Group is the default.
21. Deleting a Terminal Group must not silently terminate its running Sessions; Sessions must be moved to another Group or explicitly terminated.

## 6. Architecture and Module Boundaries

```text
macOS Desktop UI (AppKit + SwiftUI)
  ↓ typed intents / screen projections
Client Application
  ├── Client Layout Store
  ├── Renderer Coordinator → Ghostty Native Adapter
  └── Embedded Editor Coordinator → code-server WebView
  ↓ versioned WebSocket API
warren-headless Daemon
  ├── Resource Service
  ├── Session Service
  ├── Import Service
  ├── Agent Service (Normalization & Hooks)
  ├── JSON Host Store
  └── Terminal Runtime → Ghostline v1 Adapter
```

Dependencies point strictly inward to protocol and domain values. SwiftUI, AppKit, Ghostty, Ghostline, and WebSocket are edge adapters.

### 6.1 Multi-Client and Relay Topology

```text
macOS Desktop / Web Client / iOS Client
                  ↓
          Endpoint Resolver
                  ↓
Local IPC / Direct WebSocket / Relay Transport
                  ↓
        warren-headless daemon
```

- **Local and Server Parity**: The macOS Desktop uses the same versioned WebSocket API for both Local and Server endpoints. Switching endpoints replaces the client projection and renderer without terminating resources on the remote Host.
- **SSH Transport Boundary**: SSH bootstraps the remote daemon and forwards a loopback port. Git, Runtime, and resource semantics are never encoded into SSH; once reached, all clients speak the standard WebSocket API.
- **Relay Service**: Provides Host registration, discovery, pairing, revocation, signaling, public routes, and outbound WSS forwarding. The Relay never stores Project, Workspace, or Session state, terminal output, or user input.
- **Public Access**: Explicitly configured route providing credential-free public access URLs. Web authentication requires the daemon token at the WebSocket boundary.
- **Dual-Repository Governance**: Open-source core (`warren`) contains the macOS Desktop, Web PWA, Relay, and Headless daemon. The native iOS client lives in the internal master (`warren-private`) and is maintained as a proprietary companion.

### 6.2 Git Integration

The daemon owns all Git execution through typed intents:
- `git.panel` { workspace } -> branch, upstream, ahead/behind, remote, changes, commits, branches.
- `git.diff` { workspace, path, staged, commit } -> full file content and unified diff.
- `git.checkout` { workspace, branch, create } -> branch checkout result.
- `git.pull` / `git.push` { workspace } -> fetch/push results.
- `git.pr.create` { workspace, title, body } -> pull request creation via `gh` or `glab`.

Read commands execute with a 60-second timeout and never interpolate shell input; only `git -C <path>` with fixed argument arrays is permitted.

## 7. Data Design

Host resource state is owned by `warren-headless` and persisted atomically in JSON via mutex serialization and atomic file rename.

Default files under `~/.warren/`:
```text
~/.warren/
├── state.json        # Tasks, Projects, Workspaces, Sessions, sidebar order, runtime bindings, import receipts
├── config.json       # CLI/Desktop endpoint list and current endpoint
├── settings.json     # Daemon settings such as defaultRuntime, Relay metadata, and route intent
├── token             # Local daemon authentication token
├── output/           # Ghostline durable output history
├── worktrees/        # Git worktrees created by Warren
├── ghostline.sock    # Detached Ghostline server socket
└── tls/              # Local CA and certificates for LAN HTTPS
```

`state.json` maintains:
- Host identity and display name.
- Tasks, Projects, Workspaces, Terminal Groups, and sidebar order.
- Terminal Sessions with output monotonic positions (`epoch`/`sequence`).
- Runtime Bindings with Ghostline runtime identifiers and recovery metadata.
- Import Receipts and idempotency receipts.

## 8. Structured Agent Views and Interaction Architecture

Warren bifurcates terminal execution into two first-class tracks:
1. **Raw PTY Track**: Real-time ANSI byte stream parsed by Ghostty (macOS) or xterm.js (Web), preserving full terminal fidelity.
2. **Structured Agent Track**: Normalized conversation events projected from agent transcripts and lifecycle hooks, rendering structured tool calls, status tracks, and diff cards without losing the terminal fallback.

### 8.1 Supported Agent Integrations

- **Codex**: Hooks managed by Warren report `SessionStart` into `~/.warren/agent-bind/`; transcripts (JSONL) are tailed and normalized.
- **Claude Code**: Launched with `--session-id` for deterministic transcript binding; lifecycle hooks report activity state.
- **OpenCode**: Bound via SQLite session identity discovered after launch.

### 8.2 Invariants for Agent Views

1. **PTY Stream Independence**: The transcript tails the agent execution; it never replaces the PTY stream. If a transcript is missing or unparseable, the session continues seamlessly as a standard terminal.
2. **Canonical Tool Metadata**: Normalized events extract tool name, inputs, status, and outputs for rich UI presentation (e.g. file edits, bash executions).
3. **Status Aggregation**: Workspace status aggregates Session activity across all Sessions, prioritized: `failed > attention/blocked > stalled > working > ready > exited`.
4. **Prompt Mutex and Attention Guarding**: When human attention or permission is requested by an agent, Warren surfaces an attention banner and status dot, guarding interactive inputs against corruption.

## 9. Session and Runtime Design

### 9.1 Mapping and Creation

One Terminal Session maps to one Ghostline PTY. Runtime IDs are derived from Warren Session IDs, never from user titles or branch names.

```text
CreateSession(sessionScope, launchSpec, requestID)
→ validate Workspace or Terminal Group and request idempotency
→ subscribe to Runtime output
→ create the Ghostline PTY
→ resolve Group home or Workspace path, set working directory, TERM, size, and shell environment
→ start cursor output subscription
→ persist Session and Runtime Binding
→ return resource events
→ Client Layout creates and activates the Tab
```

### 9.2 Input and Output Streaming

- **Input**: Ghostline writes input bytes to the PTY verbatim. Signals and special keys use explicit operations; `Ctrl-C` is never sent as an ordinary business string.
- **Output**: Raw PTY bytes stream through a durable cursor stream. Output is dual-buffered:
  - Bounded in-memory ring for low-latency broadcast.
  - Ghostline durable history files for recovery across reconnects and restarts.
- Every byte position is identified by `epoch + sequence`. Reconnecting clients present their last Recovery Anchor to catch up without skipping gaps.

### 9.3 Lifecycle and Recovery

- **Close Tab**: Terminate Runtime, record Session as ended, and remove Tab/Surface.
- **Detach**: Disconnect client Attachment without ending the Session process.
- **Quit Client**: Stop UI, connections, and observation tasks; Host and Ghostline PTYs continue running.
- **Relaunch**: Daemon restores state and adopts live Ghostline PTYs; missing runtimes are marked ended and never stay stuck in connecting.

## 10. macOS Desktop Interaction Design

The information architecture organizes resources hierarchically:
```text
Window
├── Sidebar
│   ├── Terminal Groups (fixed height, scrolls internally)
│   ├── Tasks (aggregating Workspaces across Projects)
│   └── Projects (Git repositories)
│       └── Workspaces (main checkout & worktrees)
└── Session Context Screen
    ├── Top Bar & Trailing Controls (IDE, Endpoint, Public Access, Notifications, Settings)
    ├── Context-scoped Tab Bar
    ├── Preset Bar (Terminal / Editor modes, Agent activity indicators)
    └── Active Workspace Content
        ├── Terminal (Ghostty Native Surface)
        └── Embedded Editor (code-server WebView)
```

### 10.1 Embedded Editor (`code-server`)

- Local-endpoint workspaces can toggle between Terminal and Editor from the top-right control.
- Terminal surface remains mounted behind Editor so mode switching preserves terminal grid, scrollback, and focus.
- Starts a managed `code-server` process bound to a random loopback port on demand, isolated to `~/Library/Application Support/Warren/EmbeddedEditor`.
- Uses Warren Ember dark palette, positions File Explorer on the right, and suppresses duplicate global chrome.

### 10.2 Raycast Integration

- Warren registers the `warren://terminal?group=Inbox` URI protocol and provides a dedicated Raycast extension and Script Command fallback.
- External launchers can trigger immediate terminal opening without bringing up window chrome manually.

## 11. Web/PWA Interaction Design

The Web client mirrors the Desktop resource model:
- Desktop view displays fixed Sidebar, Tab Bar, and Terminal.
- Mobile view provides a slide-out drawer, scrollable Tabs, and a bottom shortcut bar for terminal control keys (Esc, Tab, Ctrl-C, Ctrl-D, arrows).
- Web Attachments acquire the Control Lease on active input or resize using last-writer-wins semantics.
- Agent view toggle switches between raw xterm.js terminal and structured conversation view.

## 12. Appearance

Appearance is per-surface, not global. The three clients do not share one palette:

- **macOS Desktop**: dark only. It uses the shared `WarrenColorTokens`, whose `resolved(for:)` returns the Ember dark values for every color scheme.
- **Web/PWA**: dark only. `color-scheme: dark` is declared at `:root`, and there is no light branch.
- **iOS**: follows the system appearance, with a first-class light palette (Ember Paper) beside the Ember dark one. A phone has a system-level appearance preference and is read in daylight; a developer workbench should not override it. iOS therefore owns its design semantics in `IOSDesignTokens.swift` and does not consume the shared color tokens.

Two invariants follow:

1. **The terminal canvas is dark in every appearance, on every client.** ANSI palettes — and the TUIs that assume them — are calibrated against a dark ground, so inverting the canvas would misrender the bright color series rather than merely restyle it. Under a light appearance the canvas is inset and bordered so it reads as a deliberate dark surface.
2. **Elevation is expressed with opaque per-appearance surfaces, not with alpha.** A translucent light wash lifts a surface off a dark ground but is invisible over a light one, where elevation has to darken instead. Any surface that must read in both appearances resolves an explicit value per appearance.

Colors in each client resolve through that client's semantic token tier. A component never hardcodes a literal color; a missing token should surface as a visible defect rather than silently resolve to a stale fallback.

## 13. Non-Intrusive Observability and Acceptance

Acceptance tests must not take screenshots, move the mouse, or steal keyboard focus.

### 13.1 Three Observation Layers

1. **Domain Event Log**: Structured JSON events with monotonic timestamps, trace IDs, and resource IDs.
2. **Semantic UI Snapshot**: Read-only accessibility tree capturing identifier, role, label, value, enabled, selected, and focused state.
3. **Terminal Probe**: Verifies runtime state, PTY dimensions, input sequences, recovery anchors, and post-ANSI cell attributes.

## 14. Scope and Out of Scope

Out of scope for the open-source phase-one repository:
- Multi-user accounts, organizations, and billing.
- Automatic unauthenticated public network exposures.
- Native iOS client source code (developed separately as a proprietary companion app).
- CRDT and multi-person real-time simultaneous layout syncing.
