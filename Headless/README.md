# Warren Headless

Warren Headless holds Projects, Workspaces, Git worktrees, and Terminal
Sessions on a Host (local Mac or remote VPS). Ghostline is the sole terminal
runtime. Both the
Desktop and the CLI are clients; a client disconnecting never ends a Session.

## Installation

A remote host needs Go 1.25 and Git. The default runtime is
[ghostline](https://github.com/abcdlsj/ghostline): server-side PTY sessions
with libghostty-vt snapshots, needing no terminal multiplexer. Configurations
selecting any removed runtime are rejected at startup; use ghostline.

```sh
go install github.com/abcdlsj/warren/Headless/cmd/warren-headless@latest
go install github.com/abcdlsj/warren/Headless/cmd/warren@latest
```

Or build the current revision from the repository:

```sh
mise run build:headless
```

On macOS, the headless binaries are built for arm64 and require macOS 13 or
later on an Apple Silicon Mac. Ghostline v1 statically links its terminal core.
The app package also includes the v0.8 compatibility binary and its arm64
`libghostty-vt.dylib` for a one-time v0 -> v1 migration, with no separate
Ghostty checkout.

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
warren --endpoint my-vps agent create WORKSPACE_ID --provider codex --prompt "Run the relevant tests"
warren --endpoint my-vps agent create WORKSPACE_ID --provider codex --command codex-alias --no-prompt
warren --endpoint my-vps agent create WORKSPACE_ID --provider opencode --prompt "Run the relevant tests"
warren --endpoint my-vps agent create WORKSPACE_ID --provider opencode --command opencode --no-prompt
warren --endpoint my-vps session move SESSION_ID --group GROUP_ID --confirm
warren --endpoint my-vps session move SESSION_ID --workspace WORKSPACE_ID --confirm
warren --endpoint my-vps session current
warren --endpoint my-vps session move --current --workspace WORKSPACE_ID --dry-run
warren --endpoint my-vps session move --current --workspace WORKSPACE_ID
warren --endpoint my-vps session list
warren --endpoint my-vps session attach --current
warren agent list
warren agent read AGENT_ID --text-only
warren agent send AGENT_ID "Run the relevant tests" --wait --timeout 30m
warren agent wait AGENT_ID --timeout 30m
warren agent attach AGENT_ID
warren session send SESSION_ID "Run a shell command"
warren session read SESSION_ID --timeout 8s
```

### Owned Relay

The daemon token is the single Host Secret for an owned Relay. Create a Host
record on Relay, enroll the existing `~/.warren/token` with its one-time ticket,
then save the non-secret Relay settings (`url`, `hostID`, and the pinned Relay
signing key) through `PUT /v1/settings` or `settings.put`. The CLI enrollment
command performs that persistence and enables the supervised connector:

```sh
warren relay enroll --url https://relay.example.com --host HOST_ID \
  --ticket ENROLLMENT_TICKET --secret "$(cat ~/.warren/token)"
```

Set `relay.enabled` (and, for an application route, `publicTunnel.enabled`) to
start the supervised connector. It opens one outbound WSS connection and
multiplexes private control, HTTP, and WebSocket Upgrade streams using BRLY/2;
the connector dispatches those streams to the in-process Headless handler and
never assumes port `8789`. A Relay disconnect or restart does not stop local
Sessions or PTYs. `warren relay pair`, `status`, `tunnel enable|disable`, and
`revoke` expose the corresponding explicit Relay operations. The existing
local, SSH, and `gnar` adapters remain available during migration.

All commands support `--json`. `worktree` is an alias for `workspace`; help
and error messages keep the command name you typed instead of rewriting it to
the canonical name. `warren help`, `warren --help`, and
`warren <command> --help` print help and exit 0. Missing or invalid arguments
print the relevant usage and exit 2; server errors use exit code 1.

Roster-heavy `list` commands return at most 10 rows by default so an Agent
does not receive an entire long-lived roster in one context window. Use
`--all` when the complete result is required, and prefer searching that
explicit full output with `rg`, for example:

```sh
warren session list --all | rg 'codex|workspace-id'
warren workspace list --all | rg 'release/'
```

Commands default to aligned, human-readable tables. Pass `--json` for stable,
machine-readable JSON output. `workspace create` reports `created` and
`gitWorktree` in its result, so scripts know whether a Git worktree was really
created and where it landed. `session list` shows running sessions by default;
the default output is limited to 10 rows. Pass `--all` for the complete list
(including ended sessions), or `--ended` to list only ended ones. Use
`--limit N` for a smaller bounded result.
Each session row exposes the Warren Session ID separately from the
agent/thread ID and transcript path. JSON rows also include `current: true`
when the row's Warren Session ID exactly matches `WARREN_SESSION_ID`; no cwd,
name, timestamp, or transcript inference is performed.

`project add --auto-import-worktrees` stores automatic Git worktree import on
that Project and imports every currently existing external checkout without a
confirmation prompt. The Web and Desktop project context menus also expose
this toggle. Their **Import Existing Worktrees…** action opens a one-time
multi-select list; already registered worktrees remain visible but disabled.

`warren agent create` is the primary Codex/Claude/OpenCode entry point.
`--provider` selects the transcript protocol and `--command` selects the
executable or alias (defaulting to the provider name). For Codex and Claude,
`--prompt` is appended as the provider's initial positional prompt. OpenCode
receives the initial text through its `--prompt` option. `--command` may contain
executable options but must not contain its own positional prompt or prompt
option. Warren also rejects provider print/non-interactive mode because
`agent send` relies on the interactive composer. Use `--no-prompt` to create an
idle Agent explicitly. `--wait` can wait for that first turn to finish.

OpenCode sessions are deliberately started without `--continue`, `--session`,
or `--fork`. Warren binds one OpenCode conversation to one Warren session; a
resume or fork flag would make the provider identity diverge from the durable
Warren identity. With `--no-prompt`, OpenCode does not create its SQLite
conversation until the first prompt is entered in Terminal; after that initial
input, send subsequent prompts through the same Warren Agent session. With
`--prompt`, Warren performs that first turn during creation.

`warren agent read AGENT_ID` reads the normalized transcript, never the PTY.
By default it returns the newest 20 user, assistant, and error activities and
limits text fields to 2,000 characters. `--tools` adds compact tool-call
records; `--tool-output` is the explicit opt-in for bounded raw tool results.
Use `--recent N`, `--all`, `--include TYPE,...`, `--filter TYPE,...`, or
`--text-only` to control the normalized projection. `--full` is the rare
escape hatch: it streams the exact JSONL from the transcript bound to that
Agent, without loading the whole file into the daemon or CLI. `agent send`
waits for the transcript watcher, writes the composer text, and submits a
separate kitty-protocol Enter event. `agent wait` blocks until the current or
next turn finishes. `agent attach` is the explicit raw TTY operation.

`session` is the generic PTY resource. `session create` starts shells,
custom commands, and other interactive programs; it does not create Codex,
Claude, or OpenCode Agents. `session send` writes terminal input and `session read` returns
raw PTY output with `--timeout`/`--contains`. Agent transcript and turn flags
are rejected on these commands so a TUI cannot be mistaken for conversation
data. The `trae` preset likewise only launches a shell command; it is not an
Agent provider and has no transcript, activity, or Agent CLI semantics.

Agent and Session commands use Warren IDs. `agentThreadId` remains a separate
provider conversation ID in roster output. Use `--current` when
`WARREN_SESSION_ID` identifies the target resource.

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

The Web UI and `/v1/ws` share port 8789; the local browser uses `http://127.0.0.1:8789/#t=<token>` and LAN devices use `https://<host-LAN-IP>:8788/#t=<token>` after trusting the local CA (see "LAN HTTPS"). Public Access is managed by the daemon: `GET /v1/public-access` reports the effective Edge URL, any saved custom override, effective/configured account label, credential-free authenticated/enabled/running state, and credential-free Public Endpoint; `POST /v1/public-access/test` saves the non-secret Edge/account configuration and verifies the gnar login without enabling the live endpoint. Settings should use this route for Save & Test. `POST /v1/public-access/enable` starts the live endpoint (and still accepts the older one-step Edge/account/key body for compatibility), while `/disable` and `/restart` control the lifecycle. `POST /v1/public-access/reset` stops Warren's local worker, clears the local Edge/account/enabled intent, and removes only the bundled Warren gnar credential directory; it never calls a remote release operation. Approval Key takes precedence when both keys are supplied. An omitted Edge URL keeps the current override; an explicit empty `edgeUrl` clears it and selects the release/launcher default. Approval Keys are sent to `gnar login --edge <EDGE_URL> --account <ACCOUNT_NAME> --enrollment-key-stdin --json`; Invite Keys use `--key-stdin --json`; both travel only through stdin and are never persisted. When account name is omitted, Warren derives a gnar v1.7-compatible value from `--name`/`WARREN_HOST_NAME` (or the system hostname). The lower-level `GET /v1/tunnels` and `POST /v1/tunnels/start|stop` routes remain for compatibility with existing clients; their legacy `web_url` token fragment is retained only for those clients and is not returned by Public Access. Legacy clients may still need that fragment to open a protected URL. Warren's explicit Public Access Open action adds the fragment only for that browser launch; the API, endpoint display, and copy surfaces strip it, so this compatibility path remains a residual credential exposure risk in browser history. The user’s custom Edge override and non-secret account label are configured through `gnarEdge` and `gnarAccount` in `~/.warren/settings.json` (or `WARREN_GNAR_EDGE`) and can be read or updated with `GET/PUT /v1/settings` or the `settings.get` / `settings.put` WebSocket methods. Release builds inject the non-secret default Edge with `WARREN_GNAR_DEFAULT_EDGE`; source builds show `https://tunnel.example.com` until a release replaces it. That value is not persisted, so users without an override follow a new default after upgrading. Empty-workspace entry defaults are host settings: `autoOpenShell` and `autoStartAI` both default to `false`. Git worktree import is project-scoped: `Project.autoImportGitWorktrees` is opt-in, and `project.worktrees` plus `project.worktrees.import` expose the one-time selector path; `project.autoImportGitWorktrees` enables immediate, non-interactive import of all currently existing external worktrees for that project.

Operators can announce a planned restart with `POST /v1/maintenance` (Bearer
token required). The daemon broadcasts a `{"t":"maintenance","state":"starting","message":...}`
control message to every connected client, which then shows an "Updating"
state instead of treating the disconnect as a connection failure. The install
script calls this endpoint before replacing the daemon binary.

## Output Pipeline

Ghostline owns the PTY output stream and exposes an atomic checkpoint (screen
replay plus cursor) for recovery. The Host broadcasts bounded DENB frames
(`sessionID/epoch/sequence/payloadLength`) and sends a `synced` marker only
after the checkpoint is complete. Every client has its own outbound queue; a
slow client only disconnects itself.

## Runtime

`warren-headless` defaults to the
[ghostline](https://github.com/abcdlsj/ghostline) runtime: one
pseudo-terminal per session. Sessions are owned by a detached ghostline
server process (`ghostline serve`, spawned automatically on first start and
reconnected over `~/.warren/ghostline.sock`), so daemon upgrades and restarts
never end sessions. A server-side libghostty-vt emulator renders screen
snapshots (visible grid + scrollback, SGR preserved) at the client's size.
The Host keeps a bounded in-memory output ring and a durable Ghostline cursor;
checkpoint recovery is atomic and clients still render with their own terminal
emulator. Input is written to the PTY
verbatim, and kitty-protocol keys
(for example Shift+Enter) reach the application unchanged.

Known limits:

- A forced ghostline server restart still ends its sessions (the server
  process owns the PTY masters). Protocol upgrades are rolled in place: the
  daemon starts a fresh server, adopts every session over the admin socket,
  and retires the old process without ending children. If adoption is not
  possible (for example a server predating the admin socket), the daemon
  keeps the old server running and retries on a later start.
- The release app bundles the v0.8 compatibility bridge and its arm64
  libghostty-vt dylib for one-time v0 migration. A non-app installation that
  still needs that bridge must provide it through `WARREN_GHOSTLINE_V0_COMPAT`.

## Agent Transcript Projection

For `codex`, `claude`, and `opencode` sessions, `warren-headless` projects the
provider's own activity into normalized `agent` events and sends them to
attached clients as `{"t":"agent","session":...,"events":[...]}` text messages.
Codex and Claude write JSONL transcripts (Codex:
`~/.codex/sessions/**/rollout-*.jsonl`, Claude Code:
`~/.claude/projects/**/<session>.jsonl`). OpenCode stores SQLite rows in
`opencode.db`.
Live batches are split so a single message stays around 256 KiB; the complete
Host-owned activity/attention status is its own lightweight
`{"t":"agent.status","session":...,"status":{...}}` message. The
contract is defined in
[`docs/rfc/0006-agent-activity-attention.md`](../docs/rfc/0006-agent-activity-attention.md).
Attach only replays a bounded tail of the conversation, so clients
that need the full history fetch it page by page with the `agent.history`
request (`session`, optional `before` sequence cursor and `limit`, returning
`events`, `cursor` and `hasMore`). This keeps any single WebSocket message far
below client message-size limits even for transcripts with thousands of events.
The PTY byte stream remains the source of truth; the transcript is a
best-effort, read-only side channel.

OpenCode's data root follows `WARREN_OPENCODE_DATA_DIR` when an operator needs
to point Warren at a separate store, then the provider's platform data
directory (`~/.local/share/opencode` on macOS and Linux, or
`%LOCALAPPDATA%\opencode` on Windows). `XDG_DATA_HOME/opencode` is honored when configured. Warren opens
the SQLite database with a read-only connection and never creates or mutates
the provider database. If no usable SQLite schema is found, the Agent
projection waits for a later successful poll. Warren mirrors one bound
conversation into a private
JSONL cache under `~/.warren/opencode-cache/`; mutable snapshots are compacted
periodically so a long response does not grow quadratically. The cache survives
a daemon restart for recovery and is removed when the Warren session is
explicitly deleted.

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

OpenCode has no Warren hook binding. The daemon discovers a newly created
OpenCode session by workspace and creation time, then persists both the Warren
session ID and the OpenCode session ID. Subsequent polls use that exact ID, so
two Warren sessions in one workspace cannot silently consume each other's
conversation. If the provider database is unavailable or the schema changes,
the terminal remains usable and the Agent projection simply waits for a future
successful poll.

The bound CLI session ID and transcript path are stored on the Session and
shown in the Web Agent view. For Codex and Claude, when a hook binding is not
available yet (for example, an older CLI layout), discovery falls back to cwd
and mtime matching. OpenCode remains unbound until its provider session can be
identified safely.

The Web client renders an Agent view for these sessions and sends user input
through the same PTY as terminal bytes. If a transcript is missing or its
format changes, sessions keep working as plain terminals.

Owned Relay enrollment is a separate lifecycle from Public Access. A local
client may `POST /v1/relay/enroll` with the Relay URL, Host UUID, and one-time
enrollment ticket while authenticating with the daemon token. Headless sends
that canonical token to Relay, validates and pins the returned signing key,
and persists only Relay metadata. The request body and settings never accept
or store a second Relay secret.
