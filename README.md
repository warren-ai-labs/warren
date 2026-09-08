<p align="center">
  <img src="Assets/Brand/warren-app-icon.png" width="128" alt="Warren logo">
</p>

<h1 align="center">Warren</h1>

Warren is a local-first workspace for **durable AI workflows**, organized around **Workspaces** with durable terminal sessions at its core. Run an agent-driven workflow such as Codex, Claude Code, or OpenCode on a Host — your Mac or a remote VPS — then reconnect from the macOS desktop, Web/PWA, or CLI after an app quit, network change, or closed laptop. Every client talks to the same Host through one versioned protocol.

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
conversation. Use the terminal view when you need raw control and the Agent view when
you want a structured conversation around the same session.

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
| `docs/` | Architecture and screenshot assets |

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

The 0.12.0 release is a coordinated protocol boundary with selective
persistence migration. Pre-4.0 clients are rejected during authentication.
Host state schemas 1 and 2 migrate in place to schema 3, while unknown or
future schemas fail closed. Compatible Ghostline v1 sessions use the rolling
handoff journal; Ghostline v0 sockets, legacy PTY aliases, and pre-canonical
Agent projections require recreation or a fresh client cache. Back up
`~/.warren` before upgrading an existing Host.

The app bundle includes the `warren` CLI. On its first launch Warren installs
it to `~/.local/bin` and adds that directory to the active shell profile when
needed. Use `Tools > Install CLI` to reinstall it manually.

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

### Raycast integration

The repository includes a Raycast extension whose command is named **Terminal**.
Search for `terminal` in Raycast to open a new Warren shell; the command
defaults to the `Inbox` terminal group and can be changed in its preferences.
For local development or installation from this checkout:

```sh
cd Support/Raycast
npm install
npm run dev
```

The extension is intentionally kept as a separate package so future Warren
actions can be added as additional Raycast commands without changing the
desktop app.

#### Script Command fallback

Warren registers the `warren://terminal?group=Inbox` URL for external
launchers. Release app bundles include an optional Raycast Script Command and
its Warren icon, but Warren does not install either file or modify Raycast
settings automatically.

After installing Warren at `/Applications/Warren.app`, install the launcher
for the current user:

```sh
mkdir -p "$HOME/.warren"
install -m 755 \
  "/Applications/Warren.app/Contents/Resources/warren-terminal.sh" \
  "$HOME/.warren/warren-terminal.sh"
install -m 644 \
  "/Applications/Warren.app/Contents/Resources/warren-terminal.png" \
  "$HOME/.warren/warren-terminal.png"
```

Then open Raycast **Settings → Script Commands → Add Script Directory**, add
`~/.warren`, and search for **Terminal**. The command can be given the
alias `terminal` or a global hotkey from Raycast's **Configure Command** menu.

When working from a source checkout, use the same commands with
`Support/Raycast/warren-terminal.sh` and `Assets/Brand/warren-app-icon.png` as
the two source paths.

### Settings links

Warren also accepts `warren://settings` links. Each Settings section has a
stable `section` value, for example:

```text
warren://settings?section=public-access
```

The Relay administrator creates short-lived enrollment keys in batches. Each
key is a 16-letter code in `XXXX-XXXX-XXXX-XXXX` form and has a bounded lifetime
and use count. The response includes a `warren://settings` shortcut containing
only the Relay URL and key:

```sh
curl -fsS -X POST "$WARREN_RELAY_PUBLIC_URL/v1/admin/enrollment-keys" \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"count":5,"ttl":"24h","max_uses":1,"label":"developer laptops"}' \
  | jq -r '.keys[] | [.key, .settings_url] | @tsv'
```

Open the settings URL in Warren Desktop. It only prefills the Relay URL and
enrollment key; the key is consumed when the operator presses **Connect Relay**. Headless
then calls `POST /v1/hosts/claim`, creates the Host identity on the Relay, and
stores the resulting Host ID and signing-key pin locally. A headless install can
perform the same active step without Desktop:

```sh
WARREN_RELAY_URL="$WARREN_RELAY_PUBLIC_URL" \
WARREN_RELAY_ENROLLMENT_KEY='<enrollment-key>' \
warren-headless
```

The CLI accepts either the two values or the same settings shortcut:

```sh
warren relay connect --url "$WARREN_RELAY_PUBLIC_URL" --key '<enrollment-key>'
warren relay connect '<settings-url>'
```

Enrollment keys are bearer credentials. Share them only with the intended Host
operator and remove them from shell history, chat, and copied logs after use.

Warren checks GitHub Releases in the background at launch, no more than once
every three hours. When a newer
macOS app is available, a banner below the workspace tabs offers to download
and install it; the Warren application menu always performs a fresh check.

Build the headless daemon and CLI:

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

- [DESIGN.md](DESIGN.md) — product and system design, domain model, architecture, and acceptance criteria
- [GLOSSARY.md](GLOSSARY.md) — shared terminology
- [docs/terminal-rendering-runbook.md](docs/terminal-rendering-runbook.md) — terminal black screen and missing text troubleshooting
- [docs/headless-architecture.md](docs/headless-architecture.md) — headless and remote connection architecture
- [docs/project-architecture-and-customization-guide.md](docs/project-architecture-and-customization-guide.md) — source-audited architecture tutorial and customization guide
- [docs/startup-performance-governance.md](docs/startup-performance-governance.md) — cold-start critical path, deferral rules, and review checklist
- [docs/update-service.md](docs/update-service.md) — Cloudflare release proxy, caching, and updater endpoint contract
- [docs/relay-http.md](docs/relay-http.md) — trusted-network HTTP Relay setup and iOS development notes
- [docs/runtime.md](docs/runtime.md) — ghostline runtime and recovery
- [Headless/README.md](Headless/README.md) — headless daemon and CLI
- [RelayService/README.md](RelayService/README.md) — Relay control plane
- [Web/README.md](Web/README.md) — Web/PWA client
- [Assets/Brand/README.md](Assets/Brand/README.md) — brand and icon assets
- [CONTRIBUTING.md](CONTRIBUTING.md) — development setup and contribution expectations
- [SECURITY.md](SECURITY.md) — vulnerability reporting and deployment boundaries
- [LICENSE](LICENSE) — Apache-2.0 license terms

## Contributors

<a href="https://github.com/abcdlsj" title="abcdlsj">
  <img src="https://github.com/abcdlsj.png?size=96" width="64" alt="abcdlsj avatar">
</a>
<a href="https://github.com/izy1sky" title="izy1sky">
  <img src="https://github.com/izy1sky.png?size=96" width="64" alt="izy1sky avatar">
</a>
