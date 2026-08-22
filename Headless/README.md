# Warren Headless

Warren Headless holds Projects, Workspaces, Git worktrees, Terminal Sessions, and ghostline/tmux runtimes on a Host (local Mac or remote VPS). Both the Desktop and the CLI are clients; a client disconnecting never ends a Session.

## Installation

A remote host needs Go 1.25 and Git. The default runtime is
[ghostline](https://github.com/abcdlsj/ghostline): server-side PTY sessions
with libghostty-vt snapshots, needing neither tmux nor any other terminal
multiplexer. `--runtime tmux` is a fully supported alternative runtime for
environments that prefer or require tmux.

```sh
go install github.com/abcdlsj/warren/Headless/cmd/warren-headless@latest
go install github.com/abcdlsj/warren/Headless/cmd/warren@latest
```

Or build the current revision from the repository:

```sh
mise run build:headless
```

`warren-headless` listens on `0.0.0.0:8789` by default so phones and tablets on the same LAN can open the Web UI directly. It also serves the same UI over HTTPS on `0.0.0.0:8788` (see "LAN HTTPS" below). The HTTP port has no TLS, so do not expose it to the public internet.

## Start and Connect

Start it directly on the remote host:

```sh
warren-headless
```

Default files:

- State: `~/.warren/state.json`
- Token: `~/.warren/token`
- ghostline socket: `~/.warren/ghostline.sock` (default runtime)
- tmux socket: `warren-headless` (alternative runtime)
- Worktrees: `~/.warren/worktrees/`

From your Mac, `warren ssh` starts the remote daemon, fetches the token, saves the endpoint, and sets up port forwarding:

```sh
warren ssh user@vps
```

Keep that process running. The Desktop reads the endpoint from `~/.warren/config.json` and shows `Local` plus server options in the top-right corner. Endpoint changes made with `warren endpoint add|use|remove` are picked up within about a second, so restarting Warren is not required.

## LAN HTTPS

To remove the browser's "Not secure" badge when opening the Web UI from a phone on the same LAN, use the HTTPS listener on `0.0.0.0:8788` (disable it with `--lan-https=` or an empty `WARREN_LAN_HTTPS`). On first start the daemon generates a local CA and a server certificate in `~/.warren/tls/`; the certificate includes `localhost` and the machine's current LAN IPs.

1. Open `http://<host-LAN-IP>:8789/tls/ca.pem` on the phone, install the CA certificate, and enable full trust for it (iOS: Settings → General → VPN & Device Management, then Certificate Trust Settings; Android: Settings → Security → Install certificates).
2. Open `https://<host-LAN-IP>:8788/#t=<token>`.

The loopback HTTP endpoint `127.0.0.1:8789` keeps serving Desktop and CLI clients unchanged. If the machine's LAN IP changes, restart the daemon so the server certificate is regenerated with the new IP.

## CLI

```sh
warren endpoint list
warren --endpoint my-vps project add /srv/git/my-project
warren --endpoint my-vps project add /srv/git/my-project --auto-import-worktrees
warren --endpoint my-vps project list
warren --endpoint my-vps project move PROJECT_ID --before OTHER_PROJECT_ID
warren --endpoint my-vps workspace create PROJECT_ID --branch release/my-feature
warren --endpoint my-vps workspace move WORKSPACE_ID --before OTHER_WORKSPACE_ID
warren --endpoint my-vps session create WORKSPACE_ID --kind codex --command codex --title "My Agent"
warren --endpoint my-vps session move SESSION_ID --group GROUP_ID --confirm
warren --endpoint my-vps session move SESSION_ID --workspace WORKSPACE_ID --confirm
warren --endpoint my-vps session current
warren --endpoint my-vps session move --current --workspace WORKSPACE_ID --dry-run
warren --endpoint my-vps session move --current --workspace WORKSPACE_ID
warren --endpoint my-vps session list
warren --endpoint my-vps session attach --current
warren agent read codex --recent 10 --include user,assistant
warren agent read claude /path/to/session.jsonl --full
warren agent wait SESSION_ID --timeout 30m
warren session send SESSION_ID "Run the relevant tests" --wait --timeout 30m
warren session read SESSION_ID --text-only
warren session read SESSION_ID --terminal
```

All commands support `--json`. `worktree` is an alias for `workspace`; help
and error messages keep the command name you typed instead of rewriting it to
the canonical name. `warren help`, `warren --help`, and
`warren <command> --help` print help and exit 0. Missing or invalid arguments
print the relevant usage and exit 2; server errors use exit code 1.

Commands default to aligned, human-readable tables. Pass `--json` for stable,
machine-readable JSON output. `workspace create` reports `created` and
`gitWorktree` in its result, so scripts know whether a Git worktree was really
created and where it landed. `session list` shows running sessions by default;
pass `--all` to include ended sessions, or `--ended` to list only ended ones.
Each session row exposes the Warren Session ID separately from the
agent/thread ID and transcript path. JSON rows also include `current: true`
when the row's Warren Session ID exactly matches `WARREN_SESSION_ID`; no cwd,
name, timestamp, or transcript inference is performed.

`project add --auto-import-worktrees` stores automatic Git worktree import on
that Project and imports every currently existing external checkout without a
confirmation prompt. The Web and Desktop project context menus also expose
this toggle. Their **Import Existing Worktrees…** action opens a one-time
multi-select list; already registered worktrees remain visible but disabled.

`warren agent read codex|claude` parses a provider transcript into the same
normalized activity objects used by Warren's agent view. A transcript path may
be supplied explicitly; when omitted, Warren finds the newest transcript for
the current directory (or `--workspace PATH`). The command returns the newest
20 useful activities by default and limits text fields to 2,000 characters.
Use `--recent N` (or `--all`) to control the activity window, `--include
TYPE,...` to select event types, `--filter TYPE,...` to omit types, and
`--full` to retain complete text. Usage, attachment, and system-instruction
events stay hidden unless requested through `--include`. An unbounded `--all`
read is defensively capped at 100,000 matching activities; use `--recent` for
a smaller, predictable result.

`warren agent wait SESSION_ID` blocks until the currently running turn ends,
or until the next turn ends when the agent is idle. It returns the normalized
events assigned to that turn and defaults to a 30-minute timeout. `warren
session send SESSION_ID TEXT --wait` captures the turn baseline before sending
input, then waits for the new turn. For Codex/Claude sessions Warren waits for
the transcript watcher before sending, writes the composer text, and submits a
separate kitty-protocol Enter event. This avoids treating the first Enter as a
first-run trust/resume confirmation or leaving the message in the TUI composer.
Use `--raw` only when the target is deliberately being driven as a terminal;
raw Agent input skips the readiness gate and submit-key translation.

`session read SESSION_ID` uses the normalized Agent transcript for Codex/Claude
and Warren-bound shell overlays, so cursor movement, spinners, and other TUI
bytes do not enter automation output. Use `--text-only` (also `--text` or
`--plain`) to print only user/assistant text. Use `--terminal` (or `--raw`) to
read the original PTY stream with the existing `--timeout`/`--contains`
behavior. Non-Agent sessions continue to use the PTY reader by default.

`session send` and `session read` serialize no Agent turn ownership: callers
must serialize concurrent sends targeting the same session. `--wait` rejects
an already-running Agent turn because terminal input may steer that turn or
queue a new one depending on provider state; use `agent wait` first when
deterministic completion ownership matters. Completed turns exit 0; failed or
aborted turns print their structured result and exit 1. Use `--current` with
either command when `WARREN_SESSION_ID` identifies the target Warren Session.

For `workspace create`, `--branch` is required and `--path` is optional: omit
`--path` and the daemon places the new worktree under
`~/.warren/worktrees/<project>/<workspace>-<branch>`; pass `--path /custom/path`
only when the worktree must live somewhere specific. `session create` starts a
durable terminal in an existing workspace; the Desktop and Web clients see it
as soon as the daemon broadcasts the updated roster. Pass `--title NAME` to
set the user-facing name shown in tabs; `session rename SESSION_ID --title NAME`
changes it later. Without a user-set name, clients fall back to a generated
default (kind or command), and a user-set name always takes precedence.
`session move SESSION_ID --workspace WORKSPACE_ID` moves a standalone Terminal
Group session into a Workspace; `session move SESSION_ID --group GROUP_ID`
moves it back. The running process, cwd, output history, and Session ID are
preserved, so the tab simply appears under the destination context. Use
`session current` or `--current` from a Warren-managed shell to target only the
session named by `WARREN_SESSION_ID`. `--current` refuses to guess when the
binding is missing. `--dry-run` (also `--preflight`) returns the exact source,
destination, agent binding, and transcript path without changing state.
Explicit-ID moves require `--confirm` (or `--yes`) unless an expected source
context is supplied with `--expected-workspace` or `--expected-agent-session`;
this keeps a copied but valid ID from being treated as sufficient intent.
Current-session moves automatically send the observed workspace and agent
session IDs as compare-and-swap expectations; a stale observation fails with a
refresh-and-retry error instead of moving a changed session. Successful moves
return an operation ID, and `session undo OPERATION_ID` reverts only when the
session still has the recorded post-move context. Deletes expose the same
target information through `session remove ... --dry-run`; deletion has no
automatic undo because its runtime and transcript side effects are not safely
reconstructible.

On macOS, `mise run install` also initializes a `local` endpoint pointing at
`http://127.0.0.1:8789` with the daemon token from `~/.warren/token`, so the
CLI works against the local daemon without extra setup. On a remote host, use
`warren ssh user@vps` to create and select the endpoint instead.

## API Boundaries

The control interface is `/v1/ws`: authenticate with the token first, then use request/response messages with request IDs. Roster is the Host resource projection; terminal output uses WebSocket binary frames. `project.move` and `workspace.move` persist the sidebar order on the Host (both accept `id` and an optional `before`; omitting `before` moves the entry to the end). `session.current` accepts only an already-resolved Warren Session ID, while `session.move.preflight` and `session.delete.preflight` validate context without mutation. `session.move` accepts optional `expectedWorkspace` and `expectedAgentSession` guards and returns a mutation operation ID; `session.undo` is compare-and-swap guarded. `session.attach` subscribes to output only. The client that owns UI focus sends `session.focus` with optional `cols/rows` to control the shared terminal size, while background `session.resize` requests are safe no-ops. SSH, Tailscale, and future Relay provide reachability only and do not enter the resource domain model.

Public Access tunnel lifetimes are bound to the daemon: every running adapter is stopped on shutdown, and a gnar process left behind by a crashed daemon is reaped before the next start, so a public endpoint never outlives its owner and a restart cannot leave two clients fighting over one reserved name. The user's intent is persisted in `tunnelEnabled` in `~/.warren/settings.json`; after a restart the daemon restores the adapters that were left enabled, so Public Access recovers until the user explicitly disables it. Release apps may bundle gnar at `Contents/Resources/gnar`; Warren runs that worker with a separate `~/.warren/gnar` credential directory and never migrates the system gnar store. `WARREN_GNAR_PATH` preserves explicit/system selection, while `WARREN_GNAR_CONFIG_DIR` overrides the child credential directory for operators and tests.

Daemon events (start/stop with build version, tunnel start, restore, and errors) are appended to `~/.warren/headless.log` with `0600` permissions and rotate at 5 MiB; point `--log-file` or `WARREN_LOG_FILE` elsewhere or set it empty to disable file logging.

The Web UI and `/v1/ws` share port 8789; the local browser uses `http://127.0.0.1:8789/#t=<token>` and LAN devices use `https://<host-LAN-IP>:8788/#t=<token>` after trusting the local CA (see "LAN HTTPS"). Public Access is managed by the daemon: `GET /v1/public-access` reports the effective Edge URL, any saved custom override, effective/configured account label, credential-free authenticated/enabled/running state, and credential-free Public Endpoint; `POST /v1/public-access/test` saves the non-secret Edge/account configuration and verifies the gnar login without enabling the live endpoint. Settings should use this route for Save & Test. `POST /v1/public-access/enable` starts the live endpoint (and still accepts the older one-step Edge/account/key body for compatibility), while `/disable` and `/restart` control the lifecycle. Approval Key takes precedence when both keys are supplied. An omitted Edge URL keeps the current override; an explicit empty `edgeUrl` clears it and selects the release/launcher default. Approval Keys are sent to `gnar login --edge <EDGE_URL> --account <ACCOUNT_NAME> --enrollment-key-stdin --json`; Invite Keys use `--key-stdin --json`; both travel only through stdin and are never persisted. When account name is omitted, Warren derives a gnar v1.7-compatible value from `--name`/`WARREN_HOST_NAME` (or the system hostname). The lower-level `GET /v1/tunnels` and `POST /v1/tunnels/start|stop` routes remain for compatibility with existing clients; their legacy `web_url` token fragment is retained only for those clients and is not returned by Public Access. Legacy clients may still need that fragment to open a protected URL. Warren's explicit Public Access Open action adds the fragment only for that browser launch; the API, endpoint display, and copy surfaces strip it, so this compatibility path remains a residual credential exposure risk in browser history. The user’s custom Edge override and non-secret account label are configured through `gnarEdge` and `gnarAccount` in `~/.warren/settings.json` (or `WARREN_GNAR_EDGE`) and can be read or updated with `GET/PUT /v1/settings` or the `settings.get` / `settings.put` WebSocket methods. Release builds inject the non-secret default Edge with `WARREN_GNAR_DEFAULT_EDGE`; source builds show `https://tunnel.example.com` until a release replaces it. That value is not persisted, so users without an override follow a new default after upgrading. Empty-workspace entry defaults are host settings: `autoOpenShell` and `autoStartAI` both default to `false`. Git worktree import is project-scoped: `Project.autoImportGitWorktrees` is opt-in, and `project.worktrees` plus `project.worktrees.import` expose the one-time selector path; `project.autoImportGitWorktrees` enables immediate, non-interactive import of all currently existing external worktrees for that project.

Operators can announce a planned restart with `POST /v1/maintenance` (Bearer
token required). The daemon broadcasts a `{"t":"maintenance","state":"starting","message":...}`
control message to every connected client, which then shows an "Updating"
state instead of treating the disconnect as a connection failure. The install
script calls this endpoint before replacing the daemon binary.

## Output Pipeline

Each Session's raw PTY bytes are written to a dedicated append-only spool (`~/.warren/output/<runtime>.out` by default); ghostline writes its own spool, while tmux uses `pipe-pane -o -O`. The Host's SpoolWatcher reads continuously from a persisted offset, writes into a bounded OutputRing, and broadcasts to clients as DENB binary frames (`sessionID/epoch/sequence/payloadLength`). On reconnect, a client sends its last confirmed Recovery Anchor; the Host replays the exact bytes while the Anchor is still in the Ring or the spool gap is small, otherwise it sends a screen snapshot and reanchors. Raw spool replay is bounded to the same order as the in-memory ring, so a long-detached session never replays tens of megabytes of terminal bytes. Every client has its own outbound queue; a slow client only disconnects itself.

## Runtime

`warren-headless` defaults to the
[ghostline](https://github.com/abcdlsj/ghostline) runtime: one
pseudo-terminal per session. Sessions are owned by a detached ghostline
server process (`ghostline serve`, spawned automatically on first start and
reconnected over `~/.warren/ghostline.sock`), so daemon upgrades and restarts
never end sessions. A server-side libghostty-vt emulator renders screen
snapshots (visible grid + scrollback, SGR preserved) at the client's size.
The output pipeline is unchanged: raw PTY bytes are appended to the same
spool files, so recovery anchors and reanchor behave identically, and clients
still render with their own terminal emulator. Input is written to the PTY
verbatim, so there is no tmux paste-vs-key translation and kitty-protocol keys
(for example Shift+Enter) reach the application unchanged.

The tmux adapter (`--runtime tmux`) is a fully supported alternative runtime;
ghostline remains the default and recommended choice.

See [docs/runtime.md](../docs/runtime.md) for the full comparison, how to
switch the default, and why sessions keep the engine they were created with.

Known limits:

- A forced ghostline server restart still ends its sessions (the server
  process owns the PTY masters). Protocol upgrades are rolled in place: the
  daemon starts a fresh server, adopts every session over the admin socket,
  and retires the old process without ending children. If adoption is not
  possible (for example a server predating the admin socket), the daemon
  keeps the old server running and retries on a later start.
- The ghostline module bundles a prebuilt libghostty-vt dylib for macOS
  arm64; other platforms must rebuild it (see the ghostline README).

## Agent Transcript Projection

For `codex` and `claude` sessions, `warren-headless` also watches the JSONL
transcript written by the CLI itself (Codex: `~/.codex/sessions/**/rollout-*.jsonl`,
Claude Code: `~/.claude/projects/**/<session>.jsonl`), normalizes messages,
reasoning, tool calls, and tool output into `agent` events, and sends them to
attached clients as `{"t":"agent","session":...,"events":[...]}` text messages.
Live batches are split so a single message stays around 256 KiB; the activity
status light is its own lightweight `{"t":"agent.activity","session":...,"activity":...}`
message. Attach only replays a bounded tail of the conversation, so clients
that need the full history fetch it page by page with the `agent.history`
request (`session`, optional `before` sequence cursor and `limit`, returning
`events`, `cursor` and `hasMore`). This keeps any single WebSocket message far
below client message-size limits even for transcripts with thousands of events.
The PTY byte stream remains the source of truth; the transcript is a
best-effort side channel.

Each Warren session is bound to one CLI conversation by its own session ID,
so several agents in the same workspace never mix transcripts:

- Claude starts with `--session-id <warren-session-id>`, which makes its
  transcript path deterministic (`~/.claude/projects/-Users-.../<id>.jsonl`).
- Codex and Claude get Warren-managed `SessionStart` and `SessionEnd` hooks
  merged into `$CODEX_HOME/hooks.json` / `$CLAUDE_CONFIG_DIR/settings.json`
  (user entries are preserved). `SessionStart` writes the CLI's
  `session_id`/`transcript_path` to
  `~/.warren/agent-bind/<warren-session-id>.json` and resets the state file;
  `SessionEnd` marks the state file exited so the status light returns to
  the surrounding shell. The daemon starts the watcher from the exact file.
- Every Warren session, including a plain Shell tab, inherits the same
  binding environment. A Codex/Claude CLI started manually inside that shell
  is bound by the same hooks: the tab shows agent activity while it runs and
  returns to a plain shell after `SessionEnd`. Sessions created before this
  feature need to be reopened so the shell picks up the new environment.

The bound CLI session ID and transcript path are stored on the Session and
shown in the Web Agent view. When a binding is not available yet (hook not
installed, CLI version with a different layout), discovery falls back to
cwd + mtime matching so the session still works.

The Web client renders an Agent view for these sessions and sends user input
through the same PTY as terminal bytes. If a transcript is missing or its
format changes, sessions keep working as plain terminals.
