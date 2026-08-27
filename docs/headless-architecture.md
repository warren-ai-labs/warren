# Headless and Remote Connection Architecture

Status: implemented baseline architecture
Protocol version: 2.0 (minimum supported version)

## Decisions

Warren is split into three layers: Host, Transport, and Client:

```text
Desktop / CLI
      ↓ versioned WebSocket API
Endpoint (Local, SSH tunnel, Tailscale, Relay)
      ↓
warren-headless
├── Project / Workspace / Session authority
├── atomic JSON state store
├── Git worktree adapter
├── Ghostline runtime adapter
└── read-only agent projection (Codex / Claude / OpenCode)
```

SSH is not a Warren business protocol. `warren ssh` only starts the remote daemon, reads the token, and establishes loopback port forwarding. Once connected, Desktop and CLI use the same WebSocket API.

## State Ownership

| State | Authority | Behavior after disconnect |
| --- | --- | --- |
| Projects, Workspaces, Sessions, sidebar order | Headless daemon | Retained |
| Ghostline Runtime | Headless daemon | Keeps running |
| Current endpoint | Local Desktop/CLI config | Retained |
| Desktop selection and renderer | Local Desktop | Rebuildable |
| SSH tunnel | `warren ssh` process | Closed when the process exits |

Local and Server are two independent Host resource trees. Switching endpoints only switches the projection and renderer; it does not migrate, copy, or terminate Sessions on the other end.

## Security

- The daemon binds to loopback by default.
- Tokens use 256 random bits; config files use `0600` permissions.
- WebSocket auth uses constant-time comparison.
- Protocol 2 is the minimum wire version. Clients that send another (or no)
  version are rejected during authentication with an explicit upgrade error,
  before the daemon sends a roster or session data.
- HTTP state endpoints require a Bearer token.
- Public connections should go through SSH, Tailscale, or a TLS-terminating Relay.

## Extension Points

- The store can move from atomic JSON to a stronger database without changing the API.
- Runtime is isolated behind an interface, so systemd, container, or PTY adapters can be added.
- Endpoints can add Relay, mTLS, and organization-level discovery.
- Protocol 2 negotiates roster deltas and an opaque terminal-state format. New
  request receipts, input leases, and other capabilities must be introduced as
  a later protocol version rather than inferred by older clients.
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
- After startup, the daemon adopts live Ghostline sessions through the server
  socket and marks confirmed missing Runtimes ended. Only an explicit Session
  delete ends the Runtime; detaching and client exits never terminate it.

## Current Limitations

- The Host Ring is bounded. An evicted or stale anchor reanchors from Ghostline
  state; it never guesses across a missing interval.
- Headless Go's `/v1/ws` exposes one request/response control protocol. `session.attach` creates an output subscription only (and carries the `epoch/sequence` recovery anchor); a client sends `session.focus` with an optional `cols/rows` viewport after it gains UI focus. The Host only lets the focused peer resize the shared PTY; background `session.resize` requests are safe no-ops, and detach releases focus. Control messages and DENB output frames match the daemon protocol used by Desktop and Web clients.
- Desktop discovers servers from the CLI config file and refreshes the endpoint catalog in the background, so CLI changes appear without restarting.
- Remote Project paths must be added through the CLI; the Desktop file picker only applies to Local.
- SSH auto-start requires `warren-headless` and `openssl` to be installed on the remote host.

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
