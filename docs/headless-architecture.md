# Headless and Remote Connection Architecture

Status: implemented baseline architecture
Control protocol version: 4.0 (only supported version)
Relay transport: BRLY/2 (wire version 2.0)

## Decisions

Warren is split into three layers: Host, Transport, and Client:

```text
Desktop / CLI
      ↓ versioned WebSocket API
Endpoint (Local, SSH tunnel, Relay)
      ↓
warren-headless
├── Project / Workspace / Session authority
├── atomic JSON state store
├── Git worktree adapter
├── Ghostline runtime adapter
└── read-only agent projection (Codex / Claude / OpenCode)
```

SSH is not a Warren business protocol. `warren ssh` starts the remote daemon,
reads the token, and establishes loopback port forwarding with the embedded Go
client. Desktop can also launch the bundled helper directly after the user
chooses an alias from `~/.ssh/config`; once connected, Desktop and CLI use the
same WebSocket API.

## State Ownership

| State | Authority | Behavior after disconnect |
| --- | --- | --- |
| Projects, Workspaces, Sessions, Host-local project/workspace order | Headless daemon | Retained |
| Desktop display set | Local Desktop/CLI config | Retained |
| Ghostline Runtime | Headless daemon | Keeps running |
| Current endpoint | Local Desktop/CLI config | Retained |
| Desktop selection and renderer | Local Desktop | Rebuildable |
| SSH tunnel | CLI process or bundled Desktop helper | Closed when its owner exits or switches endpoints |

Local and Server are two independent Host resource trees. Switching endpoints only switches the projection and renderer; it does not migrate, copy, or terminate Sessions on the other end.

## Multi-host Desktop sidebar

The macOS Desktop optionally aggregates Project and Workspace rosters from an
ordered set of Endpoint aliases in `~/.warren/config.json`. The `display`
section is client-local and stores aliases only; Endpoint URLs, tokens, SSH
route metadata, and Relay credentials remain in the catalog. A configuration
without that section keeps the legacy single-current behavior. Web and iOS do
not consume this Desktop-only projection. The foreground `current` Endpoint is
independent from the explicit `display` aliases, so connecting or switching
Endpoints never changes sidebar membership. The Desktop execution-server menu
adds or removes a Host; `warren display move` controls its order.

The foreground Endpoint owns the existing terminal controller, subscriptions,
focus lease, resize path, Agent projection, and write operations. Each other
visible Endpoint has an independent roster-only connection that consumes
`roster` and `roster.delta` but never sends `session.subscribe`,
`session.focus`, or `session.resize`, creates a terminal surface, or claims a
control lease. The coordinator keeps the current Endpoint plus at most seven
background connections (eight total), and gives each SSH Endpoint its own
tunnel owner. A failed background Host is isolated: its last in-memory roster
and a bounded reconnect/error state do not block healthy sections, and no
disk-backed roster cache is written.

Every aggregated Project/Workspace identity and navigation key is prefixed by
its Endpoint scope. In the expanded sidebar, a Project row only expands or
collapses its Workspace children. Selecting a background Workspace row
promotes that Endpoint before the existing terminal flow runs; mutations are
routed through the owning active connection. Host section order is changed by
`warren display move`, while
Project and Workspace order remains Host state. When more than one Host is
visible, a faint presentation-only Host tint groups each section without
changing row foregrounds or selection colors. Those Host headers align with
the sidebar section labels, can be collapsed, show no success label while
connected, and use only a spinner while connecting or reconnecting. A one-Host
display set uses the legacy `PROJECTS` tree without a Host header or tint.

## Security

- The daemon binds to loopback by default.
- Tokens use 256 random bits; config files use `0600` permissions.
- WebSocket auth uses constant-time comparison.
- Warren control protocol 4.0 is the only application wire version. Clients
  that send another (or no) version are rejected during authentication with an
  explicit reset/upgrade error, before the daemon sends a roster or session
  data.
- HTTP state endpoints require a Bearer token.
- Public connections should go through SSH or a TLS-terminating Relay.

## Extension Points

- The store can move from atomic JSON to a stronger database without changing the API.
- Runtime is isolated behind an interface, so systemd, container, or PTY adapters can be added.
- Endpoints can add Relay, mTLS, and organization-level discovery.
- Control protocol 4.0 negotiates roster deltas and the two explicit terminal
  state formats. New request receipts, input leases, and other capabilities
  must be introduced as a later protocol version rather than inferred by
  clients that do not advertise them.
- The Desktop remote model is the only client model; local Host state is owned by the daemon.

## Output and Recovery

- Ghostline exposes raw PTY bytes through an opaque cursor stream. The Host owns
  one reader per Session, appends each completed read to a bounded Output Ring,
  persists the cursor only after recording the bytes, and broadcasts DENB output
  frames to subscribed clients.
- A reconnecting client sends its last confirmed Recovery Anchor. An anchor in
  the Ring receives only the exact tail. A cold desktop peer that negotiates
  `ghostty-vt-snapshot-v1` receives one opaque Ghostty snapshot and its
  matching cursor; Web, mobile, and CLI peers negotiate
  `ghostline-vt-replay-v1` and install that checkpoint behind their own
  presentation gate.
- Binary output and atomic-state frames share the DENB envelope:
  `DENB | version | direction | kind | headerLen | payloadLen | JSON header | payload`.
  Atomic state has its own kind and format so snapshot bytes can never enter a
  VT output parser.
- Each WebSocket client has its own outbound writer and send queue; queue overflow or a write timeout disconnects only that client, which can reconnect and catch up from its anchor.
- After startup, the daemon reconnects to the current Ghostline v1 server
  through its server socket and marks confirmed missing Runtimes ended. An old
  or incompatible socket fails closed and must be reset; only an explicit
  Session delete ends a healthy Runtime, while unsubscribing and client exits
  never terminate it.

## Current Limitations

- The Host Ring is bounded. An evicted or stale anchor reanchors from Ghostline
  state; it never guesses across a missing interval.
- Headless Go's `/v1/ws` exposes one request/response control protocol.
  `session.subscribe` creates an output subscription and carries the
  `epoch/sequence` recovery anchor; `session.focus` claims or releases the
  control lease with an optional `cols/rows` viewport. The Host only lets the
  focused peer resize the shared PTY; background `session.resize` requests are
  safe no-ops, and `session.unsubscribe` releases the subscription and focus.
  Control messages and DENB output frames match the daemon protocol used by
  Desktop, iOS, Web, and CLI clients.
- Desktop discovers servers from the CLI config file and refreshes the endpoint catalog in the background, so CLI changes appear without restarting.
- Remote Project paths must be added through the CLI; the Desktop file picker only applies to Local.
- SSH auto-start requires `warren-headless` to be installed on the remote host;
  the existing remote token file is reused and no private key or token is
  copied into the endpoint catalog.

## Agent Projection Boundary

Agent activity is a best-effort side channel; the runtime PTY remains the source
of truth. Codex and Claude are tailed from their JSONL transcripts. OpenCode is
read from its current SQLite store (`opencode.db`) with `mode=ro` and `PRAGMA
query_only`; older storage formats are intentionally out of scope.
The daemon binds one OpenCode session ID to one Warren session and persists the
binding in the Host roster. It mirrors mutable provider rows into a Warren-owned
JSONL cache, compacts that cache to the latest snapshot per message at bounded
line/byte thresholds, and detects atomic cache replacement before resuming a
watch offset. The cache is retained across daemon restarts and removed only on
explicit Warren session deletion. A missing database, incomplete provider
transaction, or schema mismatch never invalidates the terminal session; it only
pauses structured Agent updates.
