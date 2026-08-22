# Warren Architecture and Customization Guide

- Status: source-audited guide for the current repository checkout
- Audience: contributors who want to understand Warren before adding personal features
- Validation scope: static source inspection; runtime, build, visual, and device behavior are not asserted here

## 1. What Warren Is

Warren is not a terminal UI that happens to remember its tabs. It is a
local-first development workbench whose durable resources and terminal
processes belong to a Host. The macOS app, Web/PWA, and CLI are clients of
that Host.

The central design decision is ownership:

```text
macOS Desktop ---+
Web / PWA --------+-- WebSocket protocol 1.0 --> warren-headless
CLI --------------+                                |
                                                   +-- Projects / Workspaces
                                                   +-- Terminal Groups
                                                   +-- Terminal Sessions
                                                   +-- JSON Host Store
                                                   +-- Output Ring + Spool
                                                   +-- Agent Transcript Watchers
                                                   +-- Runtime Adapter
                                                       +-- ghostline
                                                       +-- tmux
```

A client disconnect, app quit, or network change does not end a running
Terminal Session. Closing a Tab is the explicit user operation that ends its
Runtime in Warren v1.

This distinction matters for every customization. A feature implemented in
the wrong authority layer can create a second source of truth and make local,
Web, CLI, and remote behavior disagree.

## 2. Resource and Presentation Models

### 2.1 Host-owned resources

```text
Host
+-- Project
|   +-- Workspace
|       +-- Terminal Session
|           +-- Runtime Binding
+-- Terminal Group
    +-- Terminal Session
        +-- Runtime Binding
```

- **Host** is one `warren-headless` daemon on a Mac or remote machine.
- **Project** identifies a Git repository. It is organizational metadata, not
  a terminal working directory.
- **Workspace** is a concrete working directory. The main checkout and Git
  worktrees are both Workspaces.
- **Terminal Group** owns standalone Sessions that are not attached to a
  Project or Workspace.
- **Terminal Session** is Warren's durable terminal resource.
- **Runtime Binding** maps the Warren Session to a concrete ghostline PTY or
  tmux session.

### 2.2 Client-owned presentation

```text
Client Window
+-- Active Workspace or Terminal Group
+-- Context-scoped Tabs
+-- Active Tab
+-- Renderer Surface
```

- A **Tab** is a device-local entry that points at a Host Session.
- An **Attachment** is a temporary client connection to a Session.
- A **Renderer Surface** displays bytes but does not own the process.
- The focused Attachment is the canonical viewport owner and controls PTY
  rows and columns.

The intended authority table is:

| State | Authority | Persistence |
| --- | --- | --- |
| Projects, Workspaces, Groups, Sessions | Host Store | Host-local |
| Runtime binding and Session lifecycle | Host Store | Host-local |
| PTY output and recovery cursor | Host Output Store | Host-local |
| Window navigation and Tabs | Client | Device-local |
| Attachment, focus, viewport ownership | Host service | In memory |
| Ghostty/xterm Surface state | Client renderer | In memory |
| Agent activity | Host projection | In memory |

The target model is documented in `DESIGN.md`. The implementation has some
migration seams described in [Section 12](#12-design-and-implementation-gaps).

## 3. User-visible Capabilities

The current source contains implementations for:

- local and remote Git Project registration;
- main-checkout and Git-worktree Workspaces;
- standalone Terminal Groups;
- Shell, Claude, Codex, and custom-command Sessions;
- ghostline and tmux Runtime adapters;
- a macOS Ghostty terminal client;
- a responsive React/xterm Web/PWA client;
- a CLI that uses the same Host protocol;
- SSH bootstrap and port forwarding for remote Hosts;
- reconnect recovery using output anchors, rings, spools, and snapshots;
- structured Codex and Claude transcript projection on the Web;
- optional gnar, Cloudflare, and Tailscale reachability adapters;
- one-time Superset Project/Workspace import;
- semantic UI and terminal probes for non-intrusive acceptance testing;
- a Relay control-plane server for registration, pairing, revocation, and
  WebSocket multiplexing.

The Relay end-to-end path is not source-closed in this checkout. See
[Section 10.4](#104-relay-control-plane).

## 4. Repository Map

| Path | Responsibility | Current production relevance |
| --- | --- | --- |
| `Sources/Warren/` | macOS bootstrap, composition root, endpoint selection, WebSocket application model | Main path |
| `Sources/WarrenDaemonMenuBar/` | Local daemon health, startup, restart, and stop | Main path |
| `Sources/UIProbe/` | Semantic desktop acceptance probe | Verification |
| `Sources/TerminalProbe/` | Terminal semantic acceptance probe | Verification |
| `Packages/Desktop/` | Pure SwiftUI shell, projections, navigation reducer, and typed actions | Main path |
| `Packages/GhosttyAdapter/` | Ghostty/AppKit Surface ownership and rendering | Main path |
| `Packages/Domain/` | Swift identifiers and domain values | Main and foundation |
| `Packages/ClientCore/` | Generic client state, layout, and reconnect abstractions | Partially integrated |
| `Packages/Protocol/` | Typed Swift control and binary protocol values | Foundation; not the complete live control path |
| `Packages/Transport/` | DENB codec and generic URLSession WebSocket transport | Codec is used; generic transport is not the whole app path |
| `Packages/StateStore/` | Swift repositories and Superset import | Import is used; Host state is owned by Go |
| `Packages/TerminalRenderer/` | Platform-neutral terminal renderer boundary | Used by Ghostty adapter |
| `Packages/Observation/` | Semantic snapshots, events, and artifact output | Main verification path |
| `Packages/DesignSystem/` | macOS design tokens and reusable UI primitives | Main path |
| `Headless/cmd/warren-headless/` | Host daemon executable | Main path |
| `Headless/cmd/warren/` | CLI and SSH bootstrap executable | Main path |
| `Headless/internal/server/` | Resource service and HTTP/WebSocket protocol | Backend core |
| `Headless/internal/store/` | Atomic JSON Host Store and revision notifications | Backend core |
| `Headless/internal/runtime/` | tmux adapter and runtime environment policy | Backend core |
| `Headless/internal/output/` | Output Ring and DENB binary envelope | Backend core |
| `Headless/internal/agent/` | Agent binding, transcript parsing, and activity | Backend core |
| `Headless/internal/tunnel/` | gnar, cloudflared, and Tailscale lifecycle | Optional runtime path |
| `Web/` | React application, xterm renderer, Agent view, and PWA | Main path |
| `RelayService/` | Relay registry, auth, pairing, and frame routing | Server side exists; Host connector not located |
| `scripts/` and `mise.toml` | Build, package, install, Relay development, and verification workflows | Tooling |

### 4.1 A naming trap: `StateStore`

`Packages/StateStore` contains substantial SQLite and JSON repository code,
but the running Host authority is the Go Store in
`Headless/internal/store/store.go`, persisted as `~/.warren/state.json`.
The production macOS application currently uses the Swift StateStore package
primarily for Superset import support.

Do not add Host-owned production state to the Swift SQLite repository unless
the architecture is intentionally being changed. Doing so would create a
second resource authority.

## 5. Application Startup

### 5.1 macOS process

`Sources/Warren/WarrenMain.swift`:

1. configures terminal diagnostics;
2. acquires a single-instance lock;
3. creates a borderless AppKit window hosting SwiftUI;
4. launches the menu-bar helper;
5. mounts `WarrenCompositionRoot`.

The app uses AppKit directly because a standard SwiftUI `WindowGroup` would
retain unwanted title-bar layout.

### 5.2 local daemon helper

`Sources/WarrenDaemonMenuBar/main.swift`:

1. polls `http://127.0.0.1:8789/healthz`;
2. checks authenticated `/v1/state` using `~/.warren/token`;
3. starts the bundled `warren-headless` when it is not reachable;
4. exposes restart and stop actions in the menu bar;
5. deliberately leaves the detached ghostline server alive when the daemon
   restarts.

### 5.3 client connection

`WarrenCompositionRoot` waits for the local token and authenticated daemon
state, then asks `WarrenRemoteApplicationModel` to connect. Remote endpoint
definitions come from `~/.warren/config.json` and are refreshed in the
background.

`WarrenRemoteApplicationModel` owns the current production macOS connection
loop, roster projection, attachment state, output anchors, terminal focus,
and reconnect behavior. It recreates a wire per reconnect attempt and keeps
the old navigation projection visible while reconnecting.

## 6. Project and Workspace Lifecycle

### 6.1 adding a Project

`Service.AddProject`:

1. expands and resolves the provided path;
2. verifies that it is a directory;
3. runs `git rev-parse --show-toplevel`;
4. rejects a duplicate normalized repository path;
5. creates the Project and stores its project-scoped worktree import policy;
6. creates its root Workspace from the current checkout and branch, plus
   external worktrees only when automatic import is enabled;
7. commits both records in one Host Store update.

The Project is repository identity. The root Workspace is the executable
working-directory resource. `project.worktrees` lists external Git checkouts
for a one-time selector, and `project.worktrees.import` registers the selected
paths without creating, moving, or deleting files. Imported candidates remain
in the list with an imported marker so clients can disable them.

### 6.2 creating a Workspace

`Service.CreateWorkspace` requires a branch and enforces at most one Workspace
per branch in a Project.

If an existing path is supplied, Warren can register it as a root checkout or
worktree. Otherwise it creates a Git worktree below:

```text
~/.warren/worktrees/<project-prefix>/<workspace-prefix>-<safe-branch>
```

If persistence fails after `git worktree add`, Warren removes the worktree as
compensation.

Workspace removal is intentionally sensitive. A non-forced removal rejects
running Sessions. Removing a worktree from disk first terminates processes
whose current working directory is inside that worktree, then calls
`git worktree remove --force`.

## 7. Terminal Session Lifecycle

### 7.1 client intent

The desktop built-in preset catalog lives in
`Packages/Desktop/Sources/WarrenDesktop/WarrenDesktopSessionPreset.swift`.
It produces a value-only `TerminalSessionLaunchRequest` containing:

```text
kind
command
title
optional request ID
```

The production macOS application sends a WebSocket request similar to:

```json
{
  "t": "request",
  "id": "client-request-id",
  "method": "session.create",
  "params": {
    "workspace": "workspace-id",
    "kind": "codex",
    "command": "codex --dangerously-bypass-hook-trust",
    "title": "Codex"
  }
}
```

### 7.2 Host creation

`Headless/internal/server/http.go` selects a Workspace, Terminal Group, or the
default Group, then calls `Service.createSession`.

The service:

1. validates that exactly one Session Scope exists;
2. resolves the working directory;
3. generates a Warren Session ID and opaque runtime name;
4. derives a title and Session kind;
5. selects ghostline or tmux;
6. injects agent-binding environment variables;
7. creates the Runtime;
8. persists the Session record;
9. starts/adopts the output pipeline;
10. starts the best-effort Agent watcher.

The runtime name is derived from the Session ID, not a user title or branch,
so renaming display metadata cannot break Runtime identity.

### 7.3 Runtime adapter boundary

The backend Runtime interface contains:

```go
Create
Exists
Capture
Input
Resize
Kill
```

ghostline is the default. It owns one PTY per Session in a detached server
process and can generate libghostty-vt screen snapshots. tmux remains a
supported alternative.

Both adapters start an interactive shell and then enter a preset command. As
a result, exiting Codex or Claude returns to a usable shell instead of ending
the Warren Session.

The current implementations wait a fixed 400 ms before entering the command.
That is a timing seam, not a stable launch handshake; customizations should
not copy this pattern.

### 7.4 close versus disconnect

- Disconnecting a client only removes its temporary connection.
- Switching Workspace or Tab does not end the Host Runtime.
- Quitting the app does not end the Host Runtime.
- Explicit `session.delete` kills the Runtime and removes the Session record.

## 8. Terminal Data Path and Recovery

### 8.1 output pipeline

```text
PTY raw bytes
    |
    +-- append-only per-Session spool
    |
    +-- bounded in-memory Output Ring
             |
             +-- DENB binary WebSocket frame
                      |
                      +-- Ghostty on macOS
                      +-- xterm.js on Web
```

The Host does not strip ANSI, OSC, Unicode, or control sequences. The client
terminal emulator remains responsible for interpreting the bytes.

### 8.2 recovery position

Each output byte position is identified by:

```text
epoch + sequence
```

- `epoch` changes when continuity can no longer be represented in the same
  stream, such as spool compaction.
- `sequence` is the byte position inside the epoch.
- A client stores the next byte it needs as a Recovery Anchor.

The Output Ring chooses one of three plans:

| Plan | Meaning |
| --- | --- |
| Exact | The client already has the current upper position |
| Tail | The client's Anchor is inside the retained interval |
| Reanchor | The Anchor is absent, stale, from another epoch, or evicted |

When the Ring cannot serve a Tail, the Host attempts bounded raw spool
recovery. If that gap is too large or unsafe, it captures a rendered Runtime
screen, sends it as a reset snapshot, and establishes a new Anchor.

Attach recovery runs while the spool watcher is paused and the Session
broadcast lock is held. This prevents old replay bytes and new live bytes
from interleaving.

### 8.3 DENB envelope

PTY data uses a binary envelope shared by Go, Swift, and Web:

```text
magic: DENB
version
direction
kind
header length
payload length
JSON header
raw payload
```

Control-plane messages use JSON text. Separating control and raw PTY bytes
avoids Base64 overhead and gives each stream independent validation rules.

### 8.4 slow clients

Each WebSocket peer has a bounded outbound queue. A slow client is closed
without blocking the Host output path or other clients. It reconnects and
recovers from its Anchor.

The Web client also batches xterm writes once per animation frame. Hidden-tab
buffering is bounded; overflow deliberately forces a reanchor instead of
growing memory without limit.

## 9. Focus, Input, and Renderer Ownership

Several clients may observe one Session, but one peer owns focus and the
canonical PTY viewport at a time.

- `session.attach` subscribes to output and returns Session metadata.
- `session.focus` claims or releases focus and may carry rows and columns.
- input requires the peer to control the attached Session.
- background `session.resize` requests are safe no-ops.
- detach releases focus but does not end the Runtime.

On macOS, `TerminalSurfaceManager` is the only owner of AppKit terminal views
and Ghostty presentation work. SwiftUI submits immutable presentation intent;
the manager reconciles it outside `body` and layout call stacks.

Its default retention policy keeps:

- one active Surface;
- up to eight warm Surfaces;
- up to 1 GiB of estimated warm Surface memory;
- all other Surfaces cold and disposable.

This policy exists because recreating terminal renderers on every Tab switch
can lose visual continuity, scrollback, or produce black frames.

## 10. Remote and Web Paths

### 10.1 SSH endpoint

`warren ssh user@host`:

1. checks that `warren-headless` exists remotely;
2. starts it on remote loopback when necessary;
3. reads its token;
4. stores a local endpoint in `~/.warren/config.json`;
5. keeps an SSH local port forward running.

After bootstrap, Desktop and CLI still speak the normal `/v1/ws` protocol.
SSH provides reachability only and does not enter Warren's domain model.

### 10.2 direct Web/PWA

The daemon serves `Web/dist` and `/v1/ws` on the same HTTP server. The React
application owns UI state; xterm owns terminal rendering.

The Web client has three layout tiers:

- desktop at 1024 px and above;
- compact from 768 through 1023 px;
- mobile below 768 px.

The Web token is read from the URL fragment and persisted in browser local
storage. PWA offline behavior caches the application shell but does not fake
Host resources or Session availability.

The current Web catalog remains primarily Workspace-based and does not fully
project Terminal Groups.

### 10.3 direct reachability adapters

The daemon can manage gnar, cloudflared, and Tailscale Serve processes. These
adapters expose the local Web endpoint but do not own Projects, Sessions, or
terminal data.

The intended running state is persisted in `settings.json`, so tunnels left
enabled can be restored after a daemon restart. On shutdown, the daemon stops
the adapter processes so a Public Endpoint does not outlive its owner. The
self-hosted gnar Public Access API keeps Invite and Approval Keys in memory
only; Approval Key takes precedence, and the legacy tunnel response remains
the only compatibility path that can carry a Web token fragment.

### 10.4 Relay control plane

`RelayService` implements:

- Host provisioning and hashed credentials;
- one-time, short-lived pairing codes;
- HMAC-SHA256 access tokens bound to Host generation;
- Host revocation and credential rotation;
- Web Client to Host WebSocket multiplexing;
- bounded relay messages and per-client queues;
- embedded Web/PWA assets.

The Relay server treats terminal business frames as opaque payloads.

However, this repository checkout does not contain a located Swift or Go
consumer of `WARREN_CONTROL_PLANE_URL`, `WARREN_CONTROL_PLANE_HOST_ID`, and
`WARREN_CONTROL_PLANE_HOST_TOKEN`. The variables are injected by
`scripts/relay-dev.sh`, while the Relay server and Web Relay client exist.

Therefore the source-audited maturity is:

| Component | Status |
| --- | --- |
| Relay server | Present |
| Pairing, tokens, and registry | Present |
| Relay-aware Web client | Present |
| Host outbound connector | Not located in this checkout |
| End-to-end Relay behavior | Requires runtime verification |

## 11. Structured Agent Projection

The Agent view is not a second AI integration. The external CLI still runs in
the PTY and remains the execution authority.

```text
Codex / Claude TUI
+-- PTY bytes ----------------------> Terminal view
+-- local JSONL transcript
        |
        +-- Host transcript watcher
                |
                +-- normalized AgentEvent batches
                        |
                        +-- Web Agent view
```

### 11.1 binding

Every Warren Session receives:

```text
WARREN_SESSION_ID
WARREN_BIND_FILE
WARREN_STATE_FILE
optional WARREN_AGENT_KIND
```

- Claude gets a deterministic `--session-id` unless the user already supplied
  resume/session arguments.
- Warren merges managed SessionStart and SessionEnd hooks into Codex and
  Claude configuration while preserving user entries.
- A manually started agent inside a plain Shell can temporarily become an
  Agent overlay through the same binding environment.
- cwd and modification-time transcript discovery is only a fallback.

### 11.2 projection

The Host normalizes provider-specific JSONL records into events such as:

- user and assistant messages;
- reasoning;
- tool calls and tool output;
- usage;
- errors and attachments;
- activity states including working, blocked, stalled, failed, ready, and
  exited, with human attention carried separately in `AgentStatus`.

Initial attach sends only a bounded conversation tail. Older history is
fetched with paginated `agent.history` requests. The PTY remains usable if a
transcript is missing or its format changes.

Adding another agent provider requires work in all of these areas:

1. Session kind and preset metadata;
2. deterministic binding or managed lifecycle hook;
3. provider transcript discovery;
4. transcript normalization;
5. activity mapping;
6. Web rendering and tests;
7. plain-terminal fallback.

## 12. Design and Implementation Gaps

`DESIGN.md` is the target architecture, but the current implementation has
several important seams.

### 12.1 Session create idempotency

The design requires immutable Request IDs and idempotent Session creation.
The Swift launch value contains an optional Request ID, but the production
macOS `session.create` request does not send it and the Go creation path does
not store a request receipt.

### 12.2 Swift Session scope

The legacy Swift `WarrenDomain.TerminalSession` is Workspace-scoped. Full
Workspace-or-Terminal-Group ownership is represented in the Go API and the
Desktop remote projection, not yet consistently in the base Swift model.

### 12.3 duplicated client abstractions

Swift contains typed Protocol, ClientCore, and generic Transport packages,
but the production macOS path still implements much of the request, roster,
attachment, and reconnect policy directly in `WarrenRemoteApplicationModel`.

New protocol work should either deliberately finish that migration or extend
the current live path consistently. Updating only the unused abstraction is
not a product change.

### 12.4 explicit deletion and ended history

The design describes ending a Session and retaining an ended record. Current
explicit `session.delete` kills the Runtime and filters the Session from the
Store. Ended records can still arise from runtime reconciliation, but explicit
Tab close does not implement the full documented history model.

### 12.5 daemon listen documentation

Some architecture text describes a loopback default, while the current daemon
flag defaults to `0.0.0.0:8789` and separately serves LAN HTTPS on 8788.
Bearer-token authentication protects state and WebSocket access, but the
plain HTTP listener must not be exposed directly to the public Internet.

### 12.6 fixed launch delay

Both Runtime adapters use a fixed 400 ms delay before entering a preset
command into the login shell. This conflicts with the design goal of a
reliable launch mechanism that does not depend on timing.

### 12.7 Web Terminal Groups

The Go and macOS models support Terminal Groups, but the current Web catalog
and navigation remain Workspace-centric.

### 12.8 Relay connector

The Relay server and Relay-aware Web path exist, but the Host outbound
connector is not present in the located source path.

### 12.9 large application models

`Sources/Warren/WarrenRemoteApplicationModel.swift` and `Web/src/App.jsx`
both combine several responsibilities and are now large. Personal features
should not continue appending unrelated state and effects to these files.
Extract only the boundary needed by the feature; do not start an unrelated
whole-application rewrite.

## 13. Persistence and Configuration

Default Host files:

```text
~/.warren/
+-- state.json
+-- config.json
+-- settings.json
+-- token
+-- headless.log
+-- output/
+-- worktrees/
+-- ghostline.sock
+-- agent-bind/
+-- hooks/
+-- tls/
```

| Location | Contents |
| --- | --- |
| `state.json` | Host resources, Runtime bindings, lifecycle, output positions |
| `config.json` | Desktop/CLI endpoint catalog and selected endpoint |
| `settings.json` | Default Runtime, Runtime environment, optional gnar Edge override/account label, tunnel intent, and empty-workspace Shell/AI defaults; the release default Edge is injected at build time and Invite/Approval Keys are never persisted; an omitted account derives from the Warren Host/system name; worktree import policy lives on each Project |
| `token` | Direct Host bearer token |
| `output/` | Per-Session raw PTY spools and archives |
| `agent-bind/` | Warren Session to external agent conversation binding |
| Desktop AppStorage | Font, title template, presets, navigation preferences |
| Web localStorage | Token, selection, font, title template, preset commands |

The Go Store serializes updates under a mutex, applies changes to a cloned
state value, writes a temporary file with mode `0600`, atomically renames it,
and increments a revision used to wake roster publishers.

## 14. Choosing the Correct Customization Boundary

Before editing files, answer: **who must own this state?**

| Feature | Correct initial boundary |
| --- | --- |
| Font, theme, title template, shortcuts | Client preference |
| One-device personal preset | Desktop AppStorage or Web localStorage |
| Preset shared across all clients of one Host | Host settings/resource plus protocol |
| New Project or Workspace metadata | Go API, Store, roster, and every client projection |
| New terminal engine | Runtime adapter |
| New AI CLI | Session metadata, binding, parser, activity, and renderer |
| Scheduled or non-human work | New Automation domain resource |
| New remote transport | Endpoint, tunnel, or Relay boundary |
| Multi-user permission | Principal, capability, share grant, and attachment layers |

Do not model an Automation as a Tab, a transport as a Host resource, or a
client preference as a server truth merely because those paths already exist.

## 15. Recommended First Personal Feature: Configurable Presets

Configurable command presets are a useful first customization because they
exercise UI, persistence, and Session launch values without changing the Host
resource model.

### 15.1 MVP value shape

```text
Preset
+-- id
+-- display name
+-- command
+-- title
+-- icon
+-- pinned
```

Keep the backend Session kind as `custom`. The daemon does not need to know
whether a command launches an editor, an agent, a development server, or a
personal tool.

### 15.2 recommended phases

**Phase 1: device-local presets**

- replace the fixed desktop preset catalog with decoded AppStorage values;
- replace the Web `sessionPresets` constants with localStorage values;
- preserve Shell, Claude, and Codex as safe built-in defaults;
- validate empty IDs, duplicate IDs, empty commands, and unsupported icons;
- keep `session.create` unchanged.

**Phase 2: Host-shared presets, only if needed**

- add a versioned settings schema;
- return it from `settings.get` and accept it through `settings.put`;
- project it into macOS and Web;
- define migration and validation rules;
- keep per-device pinning or ordering separate if those preferences are not
  genuinely Host-wide.

Do not begin with a plugin marketplace, dynamic code loading, or a general
sync engine. Those mechanisms are unnecessary for a personal MVP.

## 16. Adding Larger Features Safely

### 16.1 Host-owned resource field

For a new durable field, trace every layer:

```text
Go api type
-> JSON Store persistence
-> Service validation and mutation
-> WebSocket request/roster
-> Swift remote decoder
-> Desktop projection
-> Web catalog/state
-> CLI JSON and human output
-> tests
```

If only one client shows the field, the feature is not cross-client.

### 16.2 new WebSocket method

Add:

1. Service method with domain validation;
2. `wsPeer.handle` method routing;
3. result/error contract;
4. CLI or client request wrapper;
5. roster update when resource state changes;
6. tests for authorization, invalid parameters, and concurrent behavior.

Prefer typed parameters over adding more generic string maps. The current
map-based API is convenient but permits silent client/server drift.

### 16.3 new Runtime adapter

Implement the Runtime interface first. If exact spool replay is available,
implement the optional spool capabilities as well. Verify:

- create and rollback;
- adoption after daemon restart;
- exact input byte behavior;
- resize ownership;
- capture and reanchor;
- explicit kill;
- orphan cleanup;
- runtime environment filtering.

Runtime selection belongs to the Host. A client may request an explicit kind,
but existing Sessions must retain the Runtime that created them.

### 16.4 new client surface

A new iOS or alternate desktop client should consume roster projections and
the versioned WebSocket protocol. It must not directly inspect Host files,
ghostline sockets, tmux state, or Git worktrees.

## 17. Testing and Verification Map

The broad verification command is:

```sh
mise run verify
```

It performs:

1. Web Node tests and a Vite build;
2. root Swift build;
3. Relay `go vet` and race tests;
4. Headless `go vet` and race tests;
5. tests for every Swift package;
6. semantic UI acceptance through `UIProbe`;
7. terminal semantic acceptance through `TerminalProbe`;
8. application bundle build.

More focused commands include:

```sh
mise run test:headless
mise run relay:test
npm --prefix Web run check
swift test --package-path Packages/Domain
swift test --package-path Packages/Desktop
swift test --package-path Packages/GhosttyAdapter
```

For a customization, verification should be proportional to the boundary:

| Change | Minimum focused evidence |
| --- | --- |
| Documentation | link and path checks, diff review |
| Web-only presentation | relevant Node tests and Web build |
| Desktop presentation | relevant package tests and Swift build |
| Protocol/output | Go and Swift codec tests plus race tests |
| Runtime lifecycle | Headless tests plus isolated runtime acceptance |
| Cross-client resource | Headless, CLI, Desktop, and Web checks |
| Relay | Relay tests plus a real Host-to-Relay-to-Web connection |

Do not use a successful unit test to claim visual, device, installation, or
live remote behavior.

## 18. Recommended Reading Order

Read the repository in this order:

1. `README.md`
2. `GLOSSARY.md`
3. `DESIGN.md`
4. `Headless/internal/api/types.go`
5. `Headless/internal/server/http.go`
6. `Headless/internal/server/service.go`
7. `Headless/internal/output/ring.go`
8. `Headless/internal/output/wire.go`
9. `Sources/Warren/WarrenCompositionRoot.swift`
10. `Sources/Warren/WarrenRemoteApplicationModel.swift`
11. `Packages/GhosttyAdapter/Sources/GhosttyAdapter/TerminalSurfaceManager.swift`
12. `Web/src/connection.js`, `wire.js`, and `App.jsx`
13. `Headless/internal/agent/`
14. `RelayService/`

This order starts with ownership and protocol, then follows the live Host
path before studying client presentation details.

## 19. Practical Rules for Future Work

1. Identify the single state authority before writing code.
2. Trace a real request from client to Host and back before adding fields.
3. Treat `DESIGN.md` as the target and executable code as current reality.
4. Preserve terminal behavior when transcript projection fails.
5. Keep Runtime details behind the adapter interface.
6. Never infer an async target from the currently selected Workspace.
7. Keep slow clients and persistence away from the PTY output hot path.
8. Avoid adding more unrelated responsibilities to the two large application
   models.
9. Keep personal MVPs local and small until cross-client sharing is proven
   necessary.
10. Separate source proof from build, runtime, visual, device, and remote
    validation.

## 20. Source Evidence Index

- Product overview and repository layout: `README.md`
- Authority, invariants, and target design: `DESIGN.md`
- Shared terminology: `GLOSSARY.md`
- Daemon flags and composition: `Headless/cmd/warren-headless/main.go`
- Host resources and wire values: `Headless/internal/api/types.go`
- WebSocket API and authorization: `Headless/internal/server/http.go`
- Resource, Runtime, output, and agent service: `Headless/internal/server/service.go`
- Atomic Host Store: `Headless/internal/store/store.go`
- Recovery Ring: `Headless/internal/output/ring.go`
- DENB wire envelope: `Headless/internal/output/wire.go`
- ghostline adapter: `Headless/internal/server/ghostline.go`
- tmux adapter: `Headless/internal/runtime/tmux.go`
- Agent binding: `Headless/internal/agent/binding.go`
- Transcript normalization: `Headless/internal/agent/transcript.go`
- macOS composition: `Sources/Warren/WarrenCompositionRoot.swift`
- macOS live client model: `Sources/Warren/WarrenRemoteApplicationModel.swift`
- Ghostty Surface ownership: `Packages/GhosttyAdapter/Sources/GhosttyAdapter/TerminalSurfaceManager.swift`
- Web connection and routing: `Web/src/connection.js`, `Web/src/runtime.js`
- Web terminal and Agent application: `Web/src/App.jsx`, `Web/src/agent.jsx`
- Relay server: `RelayService/internal/controlplane/server.go`
- Full verification workflow: `scripts/verify.sh`
