<p align="center">
  <img src="Assets/Brand/warren-app-icon.png" width="128" alt="Warren logo">
</p>

<h1 align="center">Warren</h1>

Warren is a local-first, **headless-first workspace for durable AI workflows**. It keeps the Host, not the client window, in charge of Tasks, Projects, Workspaces, Sessions, and Runtimes. Run Codex, Claude Code, OpenCode, a shell, or another interactive program on a Mac or remote VPS, then reconnect from the macOS desktop, Web/PWA, or CLI after an app quit, network change, or closed laptop. Every client talks to the same Host through one versioned protocol.

## Screenshots

<img src="docs/warren-desktop.png" width="800" alt="Warren desktop">

### Web

| Terminal | Agent |
| --- | --- |
| <img src="docs/warren-web-terminal.png" width="440" alt="Warren web terminal"> | <img src="docs/warren-web-agent.png" width="440" alt="Warren web agent"> |

### Mobile *(Coming Soon)*

*The native iOS companion client is in active development and coming soon.*

| Terminal | Agent |
| --- | --- |
| <img src="docs/warren-mobile-terminal.png" width="320" alt="Warren mobile terminal"> | <img src="docs/warren-mobile-agent.png" width="320" alt="Warren mobile agent"> |

## Why Warren

AI workflows are rarely finished in one sitting or on one screen. Warren keeps the
Task, Project, Workspace, Session, and Runtime together on a durable Host, so a workflow
can move from a Mac to the Web or a phone without losing its terminal state or agent
conversation. The client is a replaceable control surface: the Host owns execution,
durability, recovery, and the canonical resource graph. Use the Terminal view when you
need raw control and the Agent view when you want a structured conversation around the
same Session.

## Highlights

- **Durable sessions** — Sessions belong to the Host, not the client. Detaching, switching workspaces, or quitting the app never ends a running session; closing a Tab is the explicit command to end one.
- **One resource model** — Tasks aggregate related Workspaces across Projects, while Project → Workspace → Terminal Session → Runtime remains the ownership path shared by every client surface.
- **Local and remote** — The desktop connects to the local `warren-headless` daemon by default, or to a VPS through an embedded SSH client. Choose an alias from `~/.ssh/config` in the execution-server menu; Warren bootstraps the remote daemon and forwards a loopback port while using the same versioned WebSocket API everywhere.
- **Real terminal fidelity** — Ghostty on macOS and xterm.js on the Web preserve ANSI, OSC, Unicode, and colors from shells, Codex, Claude, and TUIs.
- **Structured agent views** — Codex, Claude, and OpenCode activity is projected as normalized events on the Web, so agent sessions can render as a conversation without losing the terminal fallback.
- **Workspace-first Git support** — Projects, main checkouts, and Git worktrees are first-class resources; one-time onboarding can import your existing Superset metadata.
- **Cross-repository tasks** — A Host-owned Task can group Workspaces from several Git repositories and optionally retain a provider-neutral external work-item identity such as TAPD or GitHub.
- **Optional central control plane** — The Relay Service provides Host registration, pairing, revocation, and outbound WSS forwarding without storing terminal output or user input.
- **Observability-first acceptance** — Tests use semantic UI snapshots and typed intents: no screenshots, no mouse movement, no focus stealing.

## The Warren workflow

### Boost: the activity lens

The lightning control in the desktop chrome is called **Boost**. Clicking Boost
switches the navigation into an activity-only view: the Project, Workspace, and
Terminal navigation keeps only contexts with running or attached Sessions, and
expands the relevant project paths so active work is immediately visible. Task
headings remain available as cross-repository context. Agent sessions contribute
provider-neutral activity and attention signals such as Working, Blocked, Stalled,
Failed, Ready, input required, or approval required. Boost is a presentation
filter only; it never moves, stops, or mutates a Session.

The separate **Active Sessions** switcher is a flat, searchable view of every live
Session. It opens a Session directly, keeps workspace context in each row, and
promotes recently-ready Agent sessions so a completed turn is easy to find. This
keeps triage fast even when a Host has many Projects and Workspaces.

### Tasks that span repositories

A Task is a Host-owned piece of work, not another Git repository. It groups
Workspaces from any number of Projects, so one delivery can contain, for example,
a frontend checkout, an API checkout, and a deployment/configuration checkout.
Each Workspace still belongs to exactly one Project and can belong to at most one
Task; the Task adds coordination without flattening repository boundaries.

Tasks support the complete lifecycle:

- Create a Task once, optionally preserving a provider-neutral external work-item
  identity such as TAPD or GitHub.
- Attach existing Workspaces from different Projects, or create a new Warren-managed
  Git worktree and attach it to the Task in one request.
- Navigate the same Workspace from its Project context or its Task context without
  duplicating the underlying checkout or Session.
- Detach a Workspace or remove a Task without deleting the Workspace, Git checkout,
  worktree, terminal Session, or runtime it contains.

The Desktop and CLI expose this model; the Web client renders the Project tree
only:

```sh
warren task create --name "Cross-repository delivery" --source tapd --external-id 12345
warren task workspace attach TASK_ID WORKSPACE_ID
warren task workspace create TASK_ID PROJECT_ID --branch feature/cross-repository
warren task workspace list TASK_ID
```

### Headless by design

`warren-headless` is the Warren Host. It can run without a GUI on a remote VPS or
server environment, owns the durable JSON state and runtime bindings, and serves
the Web UI and versioned WebSocket API. The macOS application, Web/PWA, and CLI
are clients of that Host. A client can disconnect, switch endpoints, or quit while
the Host continues to run the work.

Local and remote execution use the same resource semantics. SSH bootstraps a
remote daemon and forwards a loopback port; the Relay provides optional pairing,
revocation, and outbound WSS forwarding. Neither transport becomes a second
resource model, and the Relay never stores terminal output or user input. This is
why Warren remains usable in a terminal-only or otherwise headless environment:
the UI is helpful, but it is not the authority.

```text
macOS Desktop / Web/PWA / CLI
             |
       versioned WebSocket API
             |
       warren-headless Host
       /        |          \
   Tasks    Git/Workspaces   Sessions
                              |
                    detached Ghostline runtime
```

### Ghostline instead of tmux

Warren uses [Ghostline](https://github.com/abcdlsj/ghostline) as its sole
terminal runtime. Each Warren Session owns one persistent PTY managed by a
detached Ghostline server. The historical tmux runtime is gone, so there is no
second set of tmux sessions, windows, pane identities, or lifecycle rules for
the Host to reconcile.

This boundary gives Warren a real terminal while keeping session ownership
explicit:

- Ghostline owns the PTY and server-side terminal state; Warren owns the Session,
  resource scope, Agent binding, and client attachments.
- Raw PTY bytes remain available for Terminal views, while libghostty-vt snapshots
  provide atomic recovery for Desktop, Web, mobile, and CLI clients.
- A bounded in-memory output ring and durable cursor history support reconnects
  without replaying an arbitrary suffix of ANSI bytes.
- `epoch + sequence` recovery anchors, typed DENB binary frames, per-client
  outbound queues, and focused input/resize leases prevent one slow or competing
  client from corrupting another client's view.
- Runtime environment construction is isolated from the launching shell, and
  bundled `xterm-ghostty` terminfo keeps truecolor behavior consistent on hosts
  that do not have Ghostty installed.
- Compatible Ghostline v1 upgrades use a durable rolling handoff journal. Old or
  incompatible sockets fail closed instead of silently attaching a session to a
  different runtime.

The result is more than a tmux replacement: it is a runtime boundary designed
for reconnects, upgrades, multiple clients, and inspectable failure recovery.
The implementation decisions and failure cases are documented in
[the runtime notes](docs/runtime.md), [the headless architecture](docs/headless-architecture.md),
and [the terminal rendering runbook](docs/terminal-rendering-runbook.md).

### Agent-native, PTY-first

Warren supports structured Agent views without pretending that a TUI is a normal
request/response API. The PTY remains the source of truth for interactive
terminal behavior. In parallel, provider adapters and hooks observe Codex,
Claude, and OpenCode transcripts and project them into one canonical Agent event
stream for Desktop, Web, and CLI.

The Agent layer provides:

- Provider-neutral activity and human attention as separate projections, so
  Working is not confused with input or approval being required.
- Normalized messages, tool calls, diffs, usage, plans, and turn boundaries with
  bounded payloads and stable IDs.
- An append-only Host event journal, checkpointed replicas, typed commands,
  durable command IDs, and version checks for deterministic multi-client updates.
- Explicit Terminal and Agent paths. A missing transcript or provider schema
  never destroys the underlying terminal Session; the user can fall back to raw
  terminal control.

Interactions are validated against provider capabilities and observed state.
Warren does not infer an Agent question from a question mark, terminal silence,
or a screen that merely resembles a prompt. The PTY input contract, including the
separation between prompt text, raw keys, Enter submission, and cancellation, is
captured in [the Agent/PTY interaction note](docs/herdr-agent-pty-interaction.md).

## Engineering principles

Warren's implementation is organized around a few deliberately strict boundaries:

- **Host authority** — durable state, runtime bindings, Git operations, Agent
  projections, and recovery cursors live behind `warren-headless`.
- **Client parity** — Desktop, Web/PWA, and CLI consume the same versioned
  protocol and typed resource operations; clients own local layout and selection,
  not execution state.
- **Explicit lifecycle** — detach, client quit, daemon restart, runtime exit, and
  Close Tab have different meanings. Closing a Tab is the explicit user command
  that ends its running Session.
- **Fail closed** — protocol, schema, runtime, and cursor mismatches surface as
  upgrade or recovery boundaries rather than silently guessing or deleting state.
- **Bounded recovery** — output rings, transcript reads, event history, Git data,
  and client queues are bounded so long-lived work remains inspectable and
  automation remains safe.
- **Human-steerable automation** — Agent commands are typed and observable;
  acceptance means Host admission, while completion is confirmed by a later
  canonical event.

## Current scope

Warren is an early, open-source phase-one project. The desktop client targets macOS 13+ on arm64 Apple Silicon Macs, while the Web/PWA and CLI connect to a local or remote `warren-headless` Host. First-class Agent transcript views currently cover Codex, Claude, and OpenCode; other interactive programs remain available through the generic terminal Session interface.

### Client surface priority

Warren's product design and interactive capabilities follow a clear surface hierarchy:
- **macOS Desktop (Primary First-Class Surface)**: Primary design, native AppKit/SwiftUI components, keyboard-driven navigation, Ghostty terminal rendering, and native agent interaction reside here. All interaction paradigms, session controls, and structured views are designed and verified for Desktop first.
- **Web / PWA (Remote & Fallback Surface)**: Lightweight remote viewer and execution control under Public Access or Relay pairing.
- **iOS Mobile (Native Companion — Coming Soon)**: Companion mobile client currently in active development.

Public Access is an explicit way for the Host owner to reach an existing Web interface from outside the local network. It is not a multi-user Workspace sharing or collaboration feature. Read [SECURITY.md](SECURITY.md) before exposing any Host or Relay to a network.

The open-source repository code is licensed under [Apache-2.0](LICENSE). This covers the macOS Desktop app, Headless daemon, CLI, Relay Service, and Web client. The upcoming iOS companion client is distributed separately.

## Repository Layout

| Path | What it is |
| --- | --- |
| `Sources/Warren/` | macOS desktop app (SwiftUI + Ghostty) |
| `Packages/` | Domain, client core, desktop, ghostty adapter, protocol, terminal renderer, transport, state store, design-system, and observation packages |
| `Headless/` | Go headless daemon (`warren-headless`) and CLI (`warren`) |
| `RelayService/` | Go Relay control plane |
| `Web/` | React + Vite Web/PWA client |
| `Onboarding/` | Cloudflare Worker onboarding site (React + Vite + Ghostty WASM) |
| `Assets/Brand/` | App icon, menubar templates, and brand assets |
| `docs/` | Architecture, [RFCs](docs/rfc/), decisions, runbooks, and screenshot assets |
| `Support/Raycast/` | Raycast extension and Script Command launcher |

## Getting Started

Prerequisites:

- macOS 13+
- Swift 6 toolchain (Xcode)
- Go 1.25
- [mise](https://mise.jdx.dev) for the task runner

Build and run the macOS app:

```sh
mise install
mise run dev
```

`mise run dev` and `mise run package` build arm64 binaries for macOS 13 and
later. macOS app builds require an arm64 Apple Silicon Mac; the headless
daemon and CLI can still be built for non-macOS hosts. Ghostline v1 statically
links its terminal core, so the app has one runtime and no bundled v0 bridge,
legacy daemon, or separate Ghostty checkout to maintain.

The app bundle includes the `warren` CLI. On its first launch Warren installs
it to `~/.local/bin` and adds that directory to the active shell profile when
needed. Use `Tools > Install CLI` to reinstall it manually.

Build the headless daemon and CLI on their own:

```sh
mise run build:headless
```

Run the Web client in development:

```sh
mise run web:dev
```

Try the one-command local Relay experience:

```sh
mise run relay:dev
```

Back up `~/.warren` before upgrading an existing Host. Warren fails closed on
state it cannot migrate rather than guessing, and a release that moves the
protocol or a persistence schema says so in
[CHANGELOG.md](CHANGELOG.md). After installation, Warren checks GitHub Releases
in the background at launch no more than once every three hours; when a newer
macOS app is available a banner below the workspace tabs offers to download and
install it, and the Warren application menu always performs a fresh check.

## Optional integrations

### Embedded editor

The macOS client can show a workspace-scoped VS Code-compatible editor next
to its existing Terminal workflow. Install `code-server` before selecting the
**Editor** button in the top-right workspace actions:

```sh
brew install code-server
```

Warren prewarms code-server and a concealed workspace WebView after a workspace
is selected, then reuses it when the Editor surface opens. The server listens
on a random loopback-only port, uses an isolated profile under
`~/Library/Application Support/Warren/EmbeddedEditor`, and is stopped as a
process group when the local endpoint or app window goes away. After the editor
is ready, Warren installs `golang.go` and `rust-lang.rust-analyzer` in a
background utility task; extension downloads never block the editor from
opening. Existing VS Code and Cursor profiles are not read or modified.

The managed profile uses Warren's Ember colors and a compact editor layout:
the File Explorer lives on the right, while the Activity Bar, title controls,
welcome surfaces, editor action toolbar, minimap, and secondary sidebar stay
hidden. Tabs, breadcrumbs, language diagnostics, the status bar, Quick Open,
the Command Palette, Search, Problems, and diff editors remain available.
Warren refreshes only these managed UI settings on launch and preserves other
valid JSON settings in the isolated profile.

The MVP is available for the Local execution endpoint only. Set
`WARREN_CODE_SERVER_PATH` to an explicit executable when `code-server` is not
on the app's `PATH`. Remote Host integration requires a Host-owned editor
service and is not part of this version.

### Raycast

The repository includes a Raycast extension whose command is named **Terminal**.
Search for `terminal` in Raycast to open a new Warren shell; it defaults to the
`Inbox` terminal group and can be pointed at another group in its preferences.
The extension is kept as a separate package so future Warren actions can be
added as additional Raycast commands without changing the desktop app.

Installation, preferences, and the `warren-terminal.sh` Script Command fallback
are documented in [Support/Raycast/README.md](Support/Raycast/README.md).

### Deep links

Warren registers two URL schemes for external launchers. `warren://terminal`
opens a shell in a named terminal group, and `warren://settings` opens a
Settings section by its stable `section` value:

```text
warren://terminal?group=Inbox
warren://settings?section=public-access
```

A Relay enrollment shortcut is a `warren://settings` link carrying only a Relay
URL and an enrollment key. Opening it in Desktop prefills both fields; the key
is consumed when the operator presses **Connect Relay**. Enrolling a Host,
issuing keys, pairing a device, and revoking access are covered in
[docs/relay.md](docs/relay.md).

## Common Tasks

| Command | Description |
| --- | --- |
| `mise run dev` | Build and run the macOS app |
| `mise run build` | Build the macOS app |
| `mise run test` | Run the macOS app unit tests |
| `mise run test:headless` | Run headless daemon and CLI tests |
| `mise run verify` | Build, run all package tests, build the app, and verify the Web bundle |
| `mise run verify:web` | Launch the app and verify the HTTP page plus WebSocket auth/roster |
| `mise run web:dev` | Run the Vite development server |
| `mise run web:build` | Build the Vite Web client into `Web/dist` |
| `mise run relay:dev` | Start a local Relay, connect Warren, and open Remote Web |
| `mise run relay:pair` | Generate and open another Remote Web pairing URL |
| `mise run relay:status` | Show local Relay and Host presence |
| `mise run relay:stop` | Stop the local Relay without quitting Warren or terminal sessions |
| `mise run brand:assets` | Regenerate macOS and Web brand assets |
| `mise run package` | Build a release app and package a zip |

## Brand

The icon is a slanted straight-line `W` with silver metallic highlights on a
charcoal rounded tile. Source files, colors, and regeneration steps live in
[Assets/Brand/README.md](Assets/Brand/README.md).

## Documentation

**Start here**

- [DESIGN.md](DESIGN.md) — product and system design, domain model, architecture, and acceptance criteria
- [GLOSSARY.md](GLOSSARY.md) — shared terminology
- [docs/project-architecture-and-customization-guide.md](docs/project-architecture-and-customization-guide.md) — source-audited architecture tutorial and customization guide

**Architecture and design records**

- [docs/headless-architecture.md](docs/headless-architecture.md) — headless and remote connection architecture
- [docs/runtime.md](docs/runtime.md) — Ghostline runtime boundary, environment isolation, and recovery
- [docs/herdr-agent-pty-interaction.md](docs/herdr-agent-pty-interaction.md) — provider-safe PTY Agent interaction contract
- [docs/rfc/](docs/rfc/) — RFC index: every design proposal with its current status
- [docs/adr/](docs/adr/) and [docs/decisions/](docs/decisions/) — architecture and narrower decision records
- [docs/backlog.md](docs/backlog.md) — deferred work: what we deliberately left, why it can wait, and what would force it

**Operating a Host**

- [docs/relay.md](docs/relay.md) — enrolling a Host, pairing a phone or browser, and revoking access through Relay
- [docs/relay-http.md](docs/relay-http.md) — Relay control-plane HTTP API, trusted-network setup, and iOS transport constraints
- [docs/update-service.md](docs/update-service.md) — Cloudflare release proxy, caching, and updater endpoint contract
- [docs/onboarding-download-analytics.md](docs/onboarding-download-analytics.md) — Workers Analytics Engine download events and private metrics queries

**Troubleshooting and engineering practice**

- [docs/terminal-rendering-runbook.md](docs/terminal-rendering-runbook.md) — terminal black screen and missing text troubleshooting
- [docs/desktop-freeze-runbook.md](docs/desktop-freeze-runbook.md) — capturing and diagnosing a frozen desktop client
- [docs/lessons.md](docs/lessons.md) — engineering lessons from runtime and lifecycle incidents
- [docs/startup-performance-governance.md](docs/startup-performance-governance.md) — cold-start critical path, deferral rules, and review checklist

**Per-component**

- [Headless/README.md](Headless/README.md) — headless daemon and CLI
- [RelayService/README.md](RelayService/README.md) — Relay control plane
- [Web/README.md](Web/README.md) — Web/PWA client
- [Support/Raycast/README.md](Support/Raycast/README.md) — Raycast extension and Script Command
- [Assets/Brand/README.md](Assets/Brand/README.md) — brand and icon assets

**Contributing**

- [CONTRIBUTING.md](CONTRIBUTING.md) — development setup and contribution expectations
- [REVIEW.md](REVIEW.md) — the five review dimensions a change is checked against
- [RELEASE.md](RELEASE.md) — release process
- [SECURITY.md](SECURITY.md) — vulnerability reporting and deployment boundaries
- [LICENSE](LICENSE) — Apache-2.0 license terms

## Contributors

<a href="https://github.com/abcdlsj" title="abcdlsj">
  <img src="https://github.com/abcdlsj.png?size=96" width="64" alt="abcdlsj avatar">
</a>
<a href="https://github.com/izy1sky" title="izy1sky">
  <img src="https://github.com/izy1sky.png?size=96" width="64" alt="izy1sky avatar">
</a>
