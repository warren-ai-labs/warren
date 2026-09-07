# Warren Protocol Interaction Audit and Repository Cleanup Plan

**Status:** clean-break implementation complete; verification passed
**Audit date:** 2026-09-06
**Audit baseline:** `main` at `4ce9b14` (`fix: make canonical agent event replay idempotent`)

This document records the repository-wide audit and the resulting one-shot
cleanup contract. The original 3.0 findings remain as historical evidence; the
implementation record and the clean-break profile below define the current
4.0 contract. Historical observations must not be read as supported wire
methods or persistence behavior.

**Clean-break premise:** old data, compatibility aliases, and duplicate legacy
paths are not product requirements for the next cutover. They must not be
silently reinterpreted, dual-written, or kept “just in case.” An old state file
or Agent database is unsupported and must be explicitly reset at the release
boundary; a daemon must fail closed on an old schema rather than guess how to
read it. This premise applies to protocol and persistence compatibility, not to
ordinary reliability behavior such as bounded retries, validation, or a clear
error for an unavailable provider.

## Implementation record

The clean-break rewrite has now been applied to the active source tree:

- Warren control protocol is gated at 4.0; DENB input is mandatory and the
  `session.subscribe`/`focus`/`unsubscribe` lifecycle is canonical.
- `ghostline-vt-replay-v1` and `ghostty-vt-snapshot-v1` remain explicit,
  negotiated recovery formats; neither is a compatibility fallback.
- Desktop uses the shared `WarrenRemoteClient`; the duplicate wire actor and
  obsolete Swift control transport are removed.
- Agent observations persist directly to the canonical journal/checkpoint
  model and the old Agent tables and APIs are gone.
- Ghostline v0 handoff, old state/worktree migration, migration-only roster
  fields, and the v0 compatibility packaging path are removed. Old state,
  databases, sockets, and protocol clients fail closed or require reset.
- Public Access REST and RPC call one typed `PublicAccessService` use-case.

Final verification has passed: the Go services, all Swift packages, Web tests
and build, generated Web artifacts, removed-symbol search, and `git diff --check`
are clean. The exact command record is listed below.

Sections 1–8 below preserve the original audit evidence. Where those sections
mention Warren 3.0, `session.attach`/`detach`, or migration aliases, they are
historical baseline observations, not current contracts.

## Executive assessment

At the audit baseline, the repository had a coherent intended architecture,
but several migrations were only half-complete. The most serious problem was
not duplicated code by
itself; it is that the duplicate paths have already diverged and one shared
Swift model silently drops fields from valid server messages.

| Priority | Finding | Impact | Required treatment |
| --- | --- | --- | --- |
| P0 | Desktop contains a second remote WebSocket client | Protocol behavior can change twice and drift without a compiler error | Move Desktop to `WarrenRemoteClient` and delete the private wire actor in the cutover |
| P0 | Shared Swift roster omits `Task`, `setupScript`, and migration-era fields | iOS and shared consumers lose valid state and deltas | Add current fields; remove `ghostlineMigration` with the migration code instead of preserving it |
| P1 | Raw binary input, DENB input, and base64 JSON input coexist | The same operation has three wire contracts and three validation paths | Make DENB input mandatory; remove raw fallback and `session.input` in the same major cutover |
| P1 | `session.attach`/`detach` and `subscribe`/`focus`/`unsubscribe` coexist | Output subscription and control lease semantics are easy to confuse | Keep only `subscribe`/`focus`/`unsubscribe`; remove attach/detach aliases |
| P1 | Legacy Agent projection and canonical Agent journal are dual-written | Storage and in-memory state can disagree after partial failure | Make canonical persistence the only model and start from a fresh Agent database |
| P1 | Schema catalogs are examples rather than enforceable inventories | RPC, event, route, and field drift is currently review-only | Generate or validate complete catalogs for the new 4.0 contract |
| P2 | Public Access REST and RPC duplicate the same Relay use case | Fixes and error mapping can diverge | Extract one service/use-case layer and leave thin adapters |
| P2 | Old Swift control protocol and old RFC wording remain | New contributors can implement the wrong wire shape | Mark old RFCs superseded and remove old code only after consumers move |
| P2 | A few event handlers and helpers have no current producer/caller | Maintenance noise and misleading compatibility assumptions | Delete only after a producer/consumer proof and the relevant contract test |

## Audit method and evidence

The audit traced protocol constants, handshakes, request dispatch, server push,
binary framing, recovery, persistence, and all first-party clients. The primary
bindings are:

- [Protocol schema](../protocol/warren.schema.json)
- [Protocol README and bindings map](../protocol/README.md)
- [Headless WebSocket and HTTP handlers](../Headless/internal/server/http.go)
- [Headless API types](../Headless/internal/api/types.go)
- [Headless roster delta implementation](../Headless/internal/server/roster_delta.go)
- [Headless Agent service and stores](../Headless/internal/server/service.go), [legacy store](../Headless/internal/store/agent_event_store.go), and [canonical store](../Headless/internal/store/canonical_agent_event_store.go)
- [Relay BRLY/2 framing](../RelayService/internal/controlplane/protocol.go)
- [Shared Swift transport](../Packages/Transport/Sources/WarrenTransport/WarrenRemoteClient.swift)
- [Desktop remote model](../Sources/Warren/WarrenRemoteApplicationModel.swift)
- [Web connection and terminal code](../Web/src/connection.js), [Web application](../Web/src/App.jsx), and [Web wire helpers](../Web/src/wire.js)
- [Go CLI client](../Headless/internal/client/client.go)

The baseline checks completed before this document was written were:

```text
go test ./Headless/... ./RelayService/...
swift test
swift test --package-path Packages/GhosttyAdapter
cd Web && npm run check
```

At the audit baseline, no code or data was removed as part of the read-only
audit. The subsequent clean-break implementation is recorded above.

## Final verification record

The clean-break tree was validated on 2026-09-07 with:

```text
go test ./Headless/... ./RelayService/...
swift test
swift test --package-path Packages/GhosttyAdapter
swift test --package-path Packages/WarrenIOS
cd Web && node --test src/*.test.js
cd Web && npm run check
git diff --check
```

All checks passed. The Web suite reported 198 passing tests; the focused
GhosttyAdapter and WarrenIOS suites reported 50 and 78 passing tests. The
removed-symbol sweep found no active implementation of the deleted migration,
legacy Agent, duplicate Desktop wire, or `session.attach`/`detach`/`input`
protocol paths. Historical audit and RFC text remains explicitly labelled as
historical and is not compiled or shipped.

## 1. Intended protocol architecture

The intended chain is:

```text
Desktop / iOS / Web / CLI
        │
        │ Warren JSON control protocol 4.0
        │ DENB terminal envelope, binary wire version 1
        ▼
Headless /v1/ws
        │
        │ Ghostline runtime, roster authority, Agent projection
        ▼
PTY/session state and canonical Agent streams

Headless ── BRLY/2 control and upgrade streams ── Relay
                         │
                         └─ relays the inner Warren JSON + DENB WebSocket
```

There are three independent version numbers that must not be conflated:

| Surface | Current version | Meaning |
| --- | --- | --- |
| Warren JSON control | `4.0` | Authentication, RPC, server events, roster, Agent commands |
| DENB binary envelope | wire version `1` | PTY input/output and atomic terminal state |
| BRLY Relay stream | wire version `2` (`BRLY/2`) | Host-to-Relay control, HTTP, and WebSocket upgrade tunneling |

`BRLY/2` is not “Warren API 2.0”. The Relay may use `version: "2.0"` in its
own Host challenge and stream metadata while the tunneled client-to-Host
protocol remains Warren `4.0`.

### 1.1 Warren JSON control handshake

The current direct and relayed client handshake is conceptually:

```json
{
  "t": "auth",
  "version": "4.0",
  "token": "...",
  "capabilities": ["roster-delta", "agent-timeline-v1"],
  "terminalStateFormats": ["ghostline-vt-replay-v1"]
}
```

Relay clients use `access_token` and `client_id` instead of the local daemon
token. The example above is a replay-capable client; a native Ghostty client
advertises `ghostty-vt-snapshot-v1` instead. The Host validates the version and
selects one format from the client's explicit `terminalStateFormats` list before
sending any roster or session data. A successful connection then receives:

1. `welcome` with Host identity, access scope, and negotiated capabilities;
2. a full `roster` snapshot;
3. subsequent `roster.delta` messages when the client negotiated
   `roster-delta`;
4. request responses and asynchronous session/Agent events.

Normal requests are `{t: "request", id, method, params}`. Responses are
`{t: "response", id, ok, result}` or `{t: "response", id, ok: false, error,
code?, details?}`. The latter `code` and `details` fields are used by canonical
Agent errors and are not optional documentation details: clients classify
replay boundaries, capability errors, and idempotency conflicts with them.

### 1.2 DENB terminal envelope

The shared binary layout is:

```text
DENB | version | direction | kind | headerLength (u32 BE)
     | payloadLength (u32 BE) | JSON header | payload bytes
```

The current constants are:

| Item | Value |
| --- | --- |
| Magic | ASCII `DENB` |
| Binary wire version | `1` |
| Client-to-Host direction | `1` |
| Host-to-Client direction | `2` |
| Input kind | `1` |
| Output kind | `2` |
| Atomic-state kind | `3` |
| Header limit | 16 KiB |
| PTY input/output limit | 8 MiB |
| Atomic-state limit | 64 MiB |

Output and atomic-state frames carry a session, epoch, sequence, and payload
length. Input frames additionally carry protocol version, session, attachment,
and optional sequence metadata. The decoder checks direction/kind, lengths,
limits, and trailing bytes.

### 1.3 Recovery and control lease

The Host owns the PTY reader and the output cursor. A subscription is paired
with an epoch/sequence recovery anchor. On a cold or stale reconnect the Host
captures an atomic terminal state, sends it as a DENB atomic-state frame, then
sends `synced` at the matching cursor before live output continues. The
terminal renderer must keep the visible surface behind its presentation gate
until that pair has been installed.

Output subscription and input/resize control are separate concepts in the
current design:

- `session.subscribe` registers an output subscription and may optionally claim
  the control lease with `claim: true`;
- `session.focus` promotes or releases the control lease without creating a
  second output subscription;
- only the focused peer may resize the shared PTY;
- `session.unsubscribe` removes one output subscription;
- `session.attach` is the legacy single-subscription path and also carries a
  control lease;
- `session.attach` with `output: false` is a Desktop warm-surface control-only
  handoff, not a normal output attach.

## 2. Client/server interaction matrix

| Actor | Endpoint/transport | Authentication | Terminal state | Session lifecycle in use | Input path | Agent path |
| --- | --- | --- | --- | --- | --- | --- |
| macOS Desktop | Direct `/v1/ws`, SSH loopback, or Relay `/h/{host}/v1/client/connect` | Local `token` or Relay `access_token` + `client_id` | Advertises and decodes `ghostty-vt-snapshot-v1` | Private client uses `subscribe`; control handoff still uses `attach(output:false)` and `focus` | Raw WebSocket bytes through `WarrenRemoteWire` | Canonical events projected into Desktop store |
| Shared Swift/iOS | `WarrenRemoteClient` over direct or Relay WebSocket | Same two auth modes | `ghostline-vt-replay-v1` | `subscribe`, `focus`, `unsubscribe` | Raw WebSocket bytes through `sendInput` | Canonical history/subscription and local persistence |
| Web | `WarrenConnection` over `/v1/ws` or Relay scoped route | Browser token or Relay access capability | `ghostline-vt-replay-v1` | `subscribe`/`unsubscribe`, `focus`; a few cleanup paths still call `detach` | `connection.sendBinary` sends raw PTY bytes | Canonical `agent.events` history/live merge |
| Go CLI | `Headless/internal/client` over direct/SSH/Relay | Local token or Relay access token | `ghostline-vt-replay-v1` | `session.attach` and streamed output | `WriteMessage(BinaryMessage, data)` raw bytes | Canonical Agent commands/events projected for CLI output |
| Headless-to-Relay connector | BRLY/2 Host WebSocket | Relay challenge, pinned signing key, Host credentials | Does not choose the inner client format; tunnels it | Owns Relay control/upgrade stream lifecycle | Opaque upgraded WebSocket payloads | Opaque upgraded WebSocket payloads |
| Public Access REST | Bearer-authenticated HTTP on Headless | Host bearer token | Not a terminal stream | N/A | N/A | N/A |
| Public Access RPC | JSON control over the relayed Host WebSocket | Inner Warren auth plus Host-side Relay credentials | Not a terminal stream | N/A | N/A | N/A |

The intended commonality is the Headless `wsPeer` and Service. The main
fragmentation is at the client adapters and at the compatibility paths inside
that common server peer. The native Ghostty snapshot and ANSI replay are not
counted as fragmentation: they are intentional terminal-state variants selected
by the renderer that receives them. The contract gap is only that the schema
must list and test both variants explicitly.

## 3. RPC, event, route, and Relay inventory

### 3.1 Actual RPC groups

The switch in `Headless/internal/server/http.go` currently handles 75 distinct
method names. They fall into these groups:

| Group | Methods |
| --- | --- |
| Roster | `roster` |
| Canonical Agent read/control | `agent.execution.get`, `agent.events.history`, `agent.events.subscribe`, `agent.execution.resume`, `agent.turn.start`, `agent.turn.steer`, `agent.turn.cancel`, `agent.interaction.resolve`, `agent.attachment.prepare`, `agent.attachment.chunk`, `agent.attachment.complete`, `agent.attachment.abort` |
| Relay and public access | `relay.pairing`, `relay.devices.list`, `relay.devices.revoke`, `relay.reset`, `public-access.status`, `public-access.enable`, `public-access.test`, `public-access.disable`, `public-access.reset`, `public-access.restart` |
| Settings | `settings.get`, `settings.put`, `settings.testOpenAI` |
| Project/task/workspace/group | `project.add`, `project.remove`, `project.rename`, `project.pin`, `project.move`, `project.worktrees`, `project.worktrees.import`, `project.autoImportGitWorktrees`, `project.setupScript`, `task.create`, `task.remove`, `task.rename`, `task.pin`, `task.move`, `task.attach`, `task.detach`, `workspace.create`, `workspace.remove`, `workspace.rename`, `workspace.pin`, `workspace.move`, `terminal-group.create`, `terminal-group.remove`, `terminal-group.rename`, `terminal-group.home`, `terminal-group.move` |
| Session | `session.create`, `session.delete`, `session.delete.preflight`, `session.current`, `session.rename`, `session.pin`, `session.move`, `session.move.preflight`, `session.undo`, `session.attach`, `session.detach`, `session.subscribe`, `session.unsubscribe`, `session.focus`, `session.input`, `session.resize` |
| Git | `git.panel`, `git.diff`, `git.checkout`, `git.pull`, `git.push`, `git.commit`, `git.pr.create` |

The schema's `rpcMethods` section stores these as `examples`, not as a
machine-checkable complete set. At minimum, the following live methods are
absent from those examples:

```text
relay.devices.list
relay.devices.revoke
public-access.status
public-access.enable
public-access.test
public-access.disable
public-access.reset
public-access.restart
```

The count and list should be generated from one registry or checked directly
against the Go dispatch table. A hand-maintained example list will drift again.

### 3.2 Server-pushed events

The intended event discriminators are `welcome`, `maintenance`, `auth`,
`error`, `roster`, `roster.delta`, `attached`, `synced`, `exited`,
`agent.events`, and `pong`. Important shape details from the implementation:

- `roster` is encoded as `{t: "roster", state: api.State}`. The schema's
  event-details example currently describes the state fields as if they were
  top-level fields.
- `roster.delta` includes task changes and an explicit nullable
  `ghostlineMigration` value. Clients must apply it only when
  `baseRevision` equals their current revision.
- `attached` carries `session`, `epoch`, `sequence`, and `reanchor` in the
  current server implementation. The schema event details currently list only
  `session`.
- `synced` carries `session`, `epoch`, and `sequence`.
- `agent.events` is the only semantic Agent push. It carries canonical event
  envelopes and can contain event types unknown to an older renderer.
- Response errors can include `code` and structured `details`, even though
  those fields are not fully described in the schema.

### 3.3 HTTP routes

The current route table contains the typed service endpoints:

```text
GET  /healthz
GET  /v1/state
GET  /v1/ws
GET  /v1/settings
PUT  /v1/settings
POST /v1/relay/join
POST /v1/relay/pairing
POST /v1/maintenance
POST /v1/runtime/refresh
GET  /v1/public-access
POST /v1/public-access/enable
POST /v1/public-access/test
POST /v1/public-access/disable
POST /v1/public-access/reset
POST /v1/public-access/restart
```

The same server also serves the Web shell and assets (`/`, `/assets/`,
`/service-worker.js`, `/manifest.webmanifest`, `/preset-*`, `/icon`,
`/apple-touch-icon.png`, and `/tls/ca.pem`). The schema lists the service
examples, but does not function as a complete route manifest.

### 3.4 BRLY/2 streams

The Relay control plane uses a 22-byte BRLY/2 header with `open`, `close`,
`text`, `binary`, `httpHeaders`, `data`, `end`, `windowUpdate`, and `error`
frames. Stream classes are `control`, `http`, `upgrade`, and `p2p-signal`.

- `control` is the duplex Host-to-Relay authenticated control channel.
- `http` carries proxied HTTP/1.1, including public access.
- `upgrade` carries the relayed client WebSocket; the Relay does not parse the
  inner Warren JSON or DENB payload.
- `p2p-signal` is the authenticated signaling class; no unversioned alias is
  accepted.

The Relay therefore should not acquire Warren session or terminal semantics.
Any cleanup that moves those semantics into Relay would make the boundary less
clear, not cleaner.

## 4. Detailed findings

### 4.1 Two independent native remote clients (P0)

The Desktop model defines a private `WarrenRemoteWire` actor in
`Sources/Warren/WarrenRemoteApplicationModel.swift` (around line 871). The
shared Transport package defines `WarrenRemoteClient` and its socket actor in
`Packages/Transport/Sources/WarrenTransport/WarrenRemoteClient.swift`.

Both implementations own the following responsibilities:

- URL normalization and direct/Relay WebSocket construction;
- authentication and Relay access-token refresh;
- welcome validation, heartbeat, request continuation queues, and timeouts;
- reconnect behavior;
- roster snapshots and deltas;
- DENB output/atomic-state decoding and recovery anchors;
- Agent event subscriptions, gap recovery, local persistence, and projection;
- session input and control operations.

They are not behaviorally identical:

| Concern | Desktop private actor | Shared client |
| --- | --- | --- |
| Default capabilities | `roster-delta`, `agent-timeline-v1` | Adds interactions, interrupt, and attachments |
| Terminal format advertised | `ghostty-vt-snapshot-v1` | `ghostline-vt-replay-v1` |
| Version policy | Initial and receive-path checks are not one uniform policy; one path is exact `3.0` | `compatibleProtocolVersion` accepts the same major version |
| Error model | `NSError`/localized strings and request context kept locally | Typed `WarrenRemoteClientError`, including code/details |
| Event bridge | Desktop-specific `RemoteWireEvent` and AppKit buffering | Shared async socket events and Transport models |
| Lifecycle integration | Warm-surface control attach plus Desktop projection | Public `subscribe`, `focus`, `unsubscribe`, and reusable request API |

This is the highest-risk duplication in the repository. A fix to heartbeat,
Relay refresh, recovery, or canonical Agent handling can be applied to one
client and silently omitted from the other.

**Plan:**

1. Add Desktop/shared-client parity tests for handshake, capability selection,
   recovery, input queuing, Relay refresh, and Agent gap replay.
2. Introduce a narrow Desktop adapter around `WarrenRemoteClient` so the
   existing AppKit model can migrate without changing renderer behavior.
3. Migrate Desktop call sites and remove `WarrenRemoteWire` only after the
   Desktop target no longer references it and the parity suite passes.
4. Make one version-compatibility policy shared by all native clients.

### 4.2 Swift roster data loss (P0)

The Go API state contains fields that are not represented by the shared Swift
roster model:

| Server field | Server source | Missing Swift location | Result |
| --- | --- | --- | --- |
| `Project.setupScript` | `Headless/internal/api/types.go` | `WarrenRemoteRoster.Project` | Project setup configuration disappears after decode |
| `Workspace.task` | `Headless/internal/api/types.go` | `WarrenRemoteRoster.Workspace` | Task/workspace association disappears |
| `State.ghostlineMigration` | `Headless/internal/api/types.go` | `WarrenRemoteRoster` root | Migration state is silently dropped |
| `Delta.tasks` | `Headless/internal/server/roster_delta.go` | `WarrenRemoteRoster.Delta` | iOS/shared clients cannot apply task add/update/remove/order changes |
| `Delta.ghostlineMigration` | `Headless/internal/server/roster_delta.go` | `WarrenRemoteRoster.Delta` | Migration phase changes disappear |

`WarrenRemoteRoster.applying(_:)` can only preserve fields that the model
actually decodes. The result is a valid JSON message becoming an incomplete
local projection with no error.

**Plan:** add the fields, preserve the existing `groups` compatibility alias,
and add fixtures that round-trip a full roster and every delta entity. This
must land before Desktop/shared-client convergence because the shared model is
the intended common representation.

### 4.3 Three terminal input paths (P1)

The server accepts all of the following:

1. **Raw WebSocket binary bytes.** `wsPeer.input` treats any non-DENB binary
   message as PTY bytes. This is the production path used by Web, iOS,
   Desktop, and the Go CLI.
2. **DENB input envelope.** The same method recognizes `DENB` and validates an
   input header before forwarding its payload. The Go and Swift codecs fully
   implement this path.
3. **JSON `session.input` with base64.** The RPC decodes `params.data` and
   forwards it to the same input method. No production caller was found;
   current references are the server handler, schema, and HTTP tests.

`Web/src/wire.js::encodeInput` also exists but is currently test-driven rather
than used by the production Web send path. `Web/src/connection.js::sendBinary`
sends the raw bytes directly.

**Recommended target:** make DENB input canonical because it is already the
declared cross-language binary contract and provides session/attachment
validation. Migrate every client to encode DENB input, keep the raw fallback
for one measured compatibility window, then remove the fallback and the
base64 RPC. If product requirements intentionally prefer raw bytes, make that
the explicit contract instead and remove the unused DENB-input machinery; do
not keep three paths indefinitely.

Required safeguards are input-path metrics, an interop test for every client,
and a release note for any external CLI or Relay client that sends raw bytes.

### 4.4 Session lifecycle dual track (P1)

The new lifecycle is subscription-oriented:

```text
session.subscribe → attached/synced + output stream
session.focus     → control lease and optional resize
session.unsubscribe
```

The old lifecycle is attach-oriented:

```text
session.attach → one output subscription + control lease
session.detach
```

The old path is not dead:

- the CLI still calls `session.attach` and consumes its output stream;
- Desktop uses `session.attach` with `output:false` for warm-surface control
  promotion;
- the server explicitly retains attach semantics for older clients;
- Web still contains a few cleanup calls to `session.detach`.

`session.attach(output:false)` is not automatically equivalent to
`session.focus`: it relies on an existing retained subscription and changes
the control pointer without replay or runtime I/O. Deleting it before proving
that equivalence would break Desktop tab switching and could strand a control
lease.

**Plan:** add a state-machine test matrix for passive subscribe, focus claim,
focus release, resize ownership, legacy attach, control-only attach, and
disconnect cleanup. Then route both public APIs through one internal lease
implementation. Keep the old method names as compatibility aliases until a
major logical protocol version permits removal.

### 4.5 Legacy and canonical Agent models are dual-written (P1)

The repository contains two Agent representations:

| Layer | Legacy model | Canonical model |
| --- | --- | --- |
| API type | `api.AgentEvent` | `api.CanonicalAgentEvent` |
| Durable rows | `agent_events`, `agent_session_state` | `agent_event_journal`, `agent_stream_state` |
| In-memory projection | `agentSession.events`, status/turn projection | canonical event list/checkpoint |
| Service APIs | `AppendEvents`, `QueryEvents`, `MaxSequence`, `ClearSession` | canonical history, subscription, checkpoint, command journal |
| Consumers | Provider parsers and CLI presentation | Web, native shared client, canonical Agent commands |

The old representation cannot be removed yet: provider parsers still produce
it, the CLI still projects canonical events for display, and existing databases
may contain only the old rows. The service currently writes both paths. For
example, `recordAgentEventsForHandle` appends legacy rows and then appends
canonical events; `recordAgentInteractionResolved` updates the in-memory
legacy list before canonical persistence. A canonical write failure can
therefore leave the two projections inconsistent even though the provider
callback returned.

**Plan:**

1. Keep provider parsing as an internal adapter, but make canonical event
   creation the first durable operation.
2. Commit the canonical journal and projection checkpoint atomically; only then
   update compatibility projections or make them rebuildable from canonical
   history.
3. Add a migration that imports legacy rows into canonical streams with a
   stable identity and records the migration version.
4. Compare old and canonical projections in tests and in a bounded diagnostic
   during rollout.
5. After all supported databases are migrated and no production reader calls
   legacy APIs, delete the old tables, methods, and in-memory event list in one
   migration-aware change.

### 4.6 The schema is not a complete protocol directory (P1)

`protocol/warren.schema.json` is authoritative in intent but not enforceable in
several important sections:

- `rpcMethods` is an examples array, not an enum or generated registry;
- `httpRoutes` is also examples-only and omits the static asset route family;
- `serverEvents.roster` documents fields at the wrong nesting level;
- `attached` details omit `epoch`, `sequence`, and `reanchor`;
- `Response.code` and `Response.details` are emitted by Go but under-described;
- `workspace.remove.remove_worktree` is not represented in the method details;
- the `terminalStateFormats` enum omits the native format already used by
  Desktop, even though the coexistence itself is intentional;
- `protocolgen` currently generates constants but does not compare handler,
  event, route, and binding inventories.

**Plan:** introduce a small generated manifest or a drift test that extracts:

1. Go RPC names from a single dispatch registry;
2. server event discriminators and required fields from typed constructors;
3. HTTP method/path registrations;
4. terminal formats and capabilities;
5. Swift and TypeScript constant sets.

The test should fail on omission, not only on a changed constant. Until then,
the schema should be treated as a review aid rather than proof of complete
coverage.

### 4.7 Public Access REST and RPC duplicate the use case (P2)

`Headless/internal/server/http.go` contains both:

- REST handlers `handlePublicAccess*` for status, enable, test, disable, reset,
  and restart;
- `publicAccessRPC` for the same Relay route lifecycle over the WebSocket.

Both paths acquire the route lock, build a `relay.Route`, call Relay, persist
`PublicTunnelSettings`, start/stop the connector, and translate errors. This is
business duplication, not harmless protocol adaptation.

**Plan:** extract a Host-owned public-access service with typed operations and
error codes. Keep REST and RPC as authentication/serialization adapters. Add
one use-case test suite and thin endpoint tests that verify mapping only.
Do not delete REST: it is used for management and health workflows even when
the WebSocket is unavailable.

### 4.8 Old Swift control protocol remains a real package dependency (P2)

The following are older typed control messages and transport abstractions:

- `Packages/Protocol/Sources/WarrenProtocol/ClientMessages.swift`;
- `Packages/Protocol/Sources/WarrenProtocol/ServerMessages.swift`;
- `ProtocolError.swift` and `Recovery.swift`;
- `Packages/Transport/Sources/WarrenTransport/URLSessionWebSocketClientTransport.swift`;
- `Packages/ClientCore/Sources/WarrenClientCore/ClientSessionStore.swift` and
  `InMemoryHostTransport.swift`.

They are still imported by ClientCore, TerminalRenderer, WarrenWireCodec, and
tests. The DENB portion of `WarrenWireCodec` is also used by the new shared
remote client. Deleting the package wholesale would remove tested behavior,
not clean dead code.

**Plan:** first move any remaining production ClientCore composition to the
shared remote client and keep the codec's DENB implementation. Then split or
delete only the old JSON control-message layer whose references and tests have
been removed. Keep a compatibility package if downstream targets still build
against the public symbols.

### 4.9 Stale documentation and event handlers (P2)

Several RFCs still say “Warren protocol 2.0” even though RFC 0016 defines the
canonical Agent protocol on 3.0 and RFC 0017 uses 3.0 as its baseline. The
affected documents include RFCs 0009, 0010, 0011, 0012, 0013, 0014, and 0015.
The old wording is especially confusing where “API 2.0” appears next to
`BRLY/2`.

Separately, `Web/src/App.jsx` still handles `created`, `runtimeMetadata`, and
`sessionDeleted`, while no current Headless producer for those event
discriminators was found. The old Swift `RuntimeMetadataMessage` is still used
by ClientCore tests, so this is not proof that the entire old model is unused.

**Plan:** mark historical RFCs `Superseded` with a link to the current schema
and RFC 0016/0017; do not rewrite historical design decisions silently. For
the Web cases, first search Relay fixtures and deployed compatibility clients,
add a negative producer test or telemetry, and then remove the handlers if no
supported producer remains.

## 5. Cleanup inventory

The following inventory separates safe local cleanup from changes that require
a protocol or data decision.

| Candidate | Evidence | Confidence | Prerequisite | Proposed action |
| --- | --- | --- | --- | --- |
| `Service.attachOutput(...)` in `Headless/internal/server/service.go` | Repository search finds only the definition; callers use `prepareAttach` + `attachOutputLocked` directly | High | Run Go compile/tests after removal | Delete in a small `refactor:` change |
| Desktop `WarrenRemoteWire` | Full duplicate of shared remote client; still active Desktop production code | High after migration | Desktop adapter and parity tests | Migrate, then delete actor and Desktop-specific transport plumbing |
| `Web/src/wire.js::encodeInput` | Used by wire tests, not production send path | Medium | Decide DENB-vs-raw input contract | Wire it into production if DENB wins; otherwise delete with its tests |
| Raw branch in `wsPeer.input` | Used by Web, iOS, Desktop, and CLI today | None before decision | Client rollout and usage telemetry | Keep during migration; remove only after all clients use the chosen contract |
| JSON `session.input` base64 RPC | No first-party production caller found | Medium | Confirm external API/automation users | Deprecate, observe, then remove or retain as a documented management API |
| Legacy Agent tables/API/in-memory event list | Provider and compatibility consumers still use them; old DBs exist | None before migration | Canonical backfill, dual-read verification, DB version gate | Migrate and remove as one storage change |
| Old Swift ClientCore transport/control JSON | ClientCore and tests still reference it | None before migration | Move production composition and downstream targets | Split/delete only the unused layer; retain DENB codec |
| Web `created`/`runtimeMetadata`/`sessionDeleted` cases | No current Headless producer found; old package tests still mention runtime metadata | Low/medium | Relay/deployed-client producer audit | Add proof, then remove handlers and obsolete fixtures |
| REST/RPC Public Access duplication | Two complete implementations in one server file | High | Extract typed use-case service | Refactor; do not delete either protocol adapter |
| Protocol 2.0 wording in old RFCs | Direct search finds seven stale RFCs | High | None | Mark superseded and update the index |

### Code that must not be deleted in the first sweep

- `Web/src/connection.js::sendBinary`: it is the current production input
  entry point until the input decision is implemented.
- DENB encode/decode in `WarrenWireCodec`, Go `output`, and Web wire parsing:
  the shared remote client and tests still use it.
- All `Packages/Protocol` types: ClientCore, TerminalRenderer, and tests still
  depend on them.
- `session.attach` and `session.detach` as externally accepted method names:
  the CLI, Desktop warm surfaces, and compatibility clients still depend on
  them. Converge their implementation before considering a protocol-major
  removal.
- GhosttyAdapter to TerminalRenderer dependencies such as
  `TerminalPalette` and `TerminalPaletteColor`: they remain live renderer
  contracts.

## 6. Recommended migration sequence (baseline compatibility release)

The sequence in this section is the safe default when a compatibility window is
required. The requested one-shot cutover uses the stricter order in Section 9.4
and does not retain its deprecation or fallback steps.

### Phase 0 — Freeze decisions and invariants

Record the intentional dual terminal-format policy and the input contract.
Define the invariants that cleanup must preserve:

- a 3.0 client is rejected before roster/session data on version mismatch;
- a selected terminal state and its recovery cursor are one atomic pair;
- only the focused peer can resize or send controlled input;
- roster deltas apply only at the matching revision;
- canonical Agent event identity and sequence are idempotent across reconnect;
- Relay never parses or owns inner Warren session semantics.

### Phase 1 — Make the contract complete

Fix the Swift roster omissions and schema shape omissions first. Add fixtures
for full roster, task deltas, migration clear (`null`), response error codes,
and attached/synced recovery metadata. Add a generated or extracted inventory
test for RPCs, events, and routes.

**Exit criterion:** every first-party binding can decode every field that the
server sends, and the drift test reports the same method/event/route set.

### Phase 2 — Converge native remote transport

Migrate Desktop to `WarrenRemoteClient` behind an adapter. Preserve current
Desktop renderer gates and warm-surface behavior while replacing only socket,
request, recovery, and Agent transport ownership. Compare direct, SSH, Relay,
disconnect, token refresh, and rapid session-switch traces.

**Exit criterion:** one native remote implementation remains, and the old actor
has no production or test references.

### Phase 3 — Converge terminal state and input

Keep the intentional terminal-format negotiation explicit. Then migrate clients
to the selected input contract and test cold attach, stale anchor, reconnect,
resize, and full-screen TUI redraws. The input contract has no compatibility
fallback in the clean-break profile.

**Exit criterion:** one documented input contract and one documented terminal
state policy are used by every first-party client.

### Phase 4 — Converge session lifecycle

Route legacy attach/detach and new subscribe/focus/unsubscribe through the same
internal subscription and control-lease state machine. Migrate CLI and Desktop
call sites where semantics are proven equivalent. Retain compatibility aliases
until a protocol-major policy allows external removal.

**Exit criterion:** state-machine tests cover every combination of passive
observer, focused controller, handoff, disconnect, and cleanup.

### Phase 5 — Make canonical Agent storage authoritative

Fix write ordering and transaction boundaries, backfill old rows, validate
canonical/legacy projection equivalence, and add a database schema/version
gate. Remove legacy reads before legacy writes, then remove legacy writes and
tables.

**Exit criterion:** a restarted Host can rebuild all supported Agent views from
the canonical journal and checkpoint alone.

### Phase 6 — Extract duplicated business services

Extract Public Access route lifecycle into a typed service shared by REST and
RPC. Keep endpoint-specific auth, status codes, and serialization at the edge.
Use the same approach for any remaining duplicated Relay token or settings
operations found during implementation.

### Phase 7 — Delete and document

Delete the proven-unused helper, old actor, obsolete input encoder/branch,
legacy storage, and old Swift layer in separate typed commits so each removal
has a narrow rollback. Mark stale RFCs superseded and update the protocol
bindings map in the same release.

## 7. Verification required for the cleanup PRs

Run the existing baseline checks for every affected surface:

```text
go test ./Headless/... ./RelayService/...
swift test
swift test --package-path Packages/GhosttyAdapter
cd Web && npm run check
```

Add or retain focused tests for:

- protocol 3.0 rejection before roster exposure;
- capability and terminal-format negotiation for every supported format;
- DENB input/output/atomic-state interop across Go, Swift, and TypeScript;
- roster full snapshot and every delta entity, including nullable migration;
- attach/subscribe/focus/unsubscribe lease transitions and resize ownership;
- reconnect and recovery-anchor replay at ring boundary and stale-anchor cases;
- canonical Agent idempotency, history boundary, checkpoint, and migration;
- REST/RPC Public Access equivalence and error-code mapping;
- Relay BRLY/2 opaque upgrade forwarding without inner-protocol parsing.

For UI and TUI changes, verify a real running Desktop, iOS, and Web artifact:
tests that only replace fixtures do not prove terminal recovery or focus
behavior.

## 8. Risk register (baseline compatibility release)

These mitigations describe the conservative rollout. For the requested clean
break, the accepted risks and required guards are restated in Section 9.6.

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Silent roster field loss | A decoder can succeed while dropping task/migration state | Strict fixture coverage and model parity checks |
| Recovery format decoding | A wrong snapshot or replay parser can expose a blank or corrupted terminal | Pair each format/sequence path with real renderer smoke tests |
| Input fallback removal | External clients may still send raw bytes | Instrument first, retain a bounded compatibility release, publish contract |
| Lease semantics regression | Two clients can resize or type into one PTY | State-machine tests and focused-peer assertions |
| Agent data split-brain | Canonical and legacy stores can diverge after a failed write | Canonical-first transaction and migration verification |
| Relay boundary expansion | Relay-side business logic would duplicate Host authority | Keep BRLY/2 opaque and test upgrade forwarding |
| External clients not in this repository | Method removal is a breaking change even without local call sites | Deprecate in 3.x; reserve removal for a documented major protocol version |
| Stale docs reintroducing old design | Contributors may copy protocol 2.0 examples | Mark RFCs superseded and link the current schema |

## Baseline recommendation (conservative default)

For a normal backwards-compatible release, do not perform a single blind
deletion sweep. First land the contract and model parity fixes, then converge
the Desktop transport, decide terminal/input formats, and only then remove
compatibility code and legacy storage. The one immediately defensible deletion
candidate is `Service.attachOutput(...)`, because the repository has no caller;
every other material candidate has a protocol, renderer, external-client, or
data-migration prerequisite.

The project has now chosen a different release policy for the next cleanup:
the clean-break profile below supersedes the compatibility-preserving advice
above. The audit evidence and the deletion inventory remain valid; only the
rollout assumption changes.

## 9. Clean-break implementation profile

This profile is the requested target for the next implementation. It is a
single product cutover, not a rolling compatibility migration. All first-party
clients, the Host, and the Relay-facing client route are released together.
There is no supported mixed-version window, no legacy alias period, and no
backfill of Warren-owned data.

### 9.1 Hard boundary and target contract

| Area | Cutover contract | Immediate consequence |
| --- | --- | --- |
| JSON control | Warren `4.0` is the only accepted logical version | Reject `3.x`, `2.x`, missing, and future versions before sending `welcome`, roster, or session data |
| DENB | Keep binary wire version `1`; every client-to-Host binary message is a DENB input frame | Delete the raw WebSocket PTY-byte branch; a malformed or non-DENB binary frame is an input error, never terminal input |
| Terminal recovery | `ghostty-vt-snapshot-v1` and `ghostline-vt-replay-v1` are intentional negotiated formats | Native Ghostty clients use the snapshot; Web, iOS, and CLI use replay. The Host selects only a format explicitly advertised by the client, with no hidden compatibility fallback |
| Session output/control | `session.subscribe`, `session.unsubscribe`, `session.focus`, and the existing focused `session.resize` are canonical | Delete `session.attach` and `session.detach`; `session.attach(output:false)` becomes `session.focus` |
| Session input | DENB input metadata carries session, attachment, and optional sequence | Delete JSON `session.input` and its base64 decoder; all clients use one typed encoder |
| Agent state | `CanonicalAgentEvent` journal, command journal, and canonical checkpoint are the only Agent model | Delete `AgentEvent` as a wire/storage model, legacy tables, legacy APIs, and the dual-written in-memory projection |
| Roster | Full current fields are required (`Task`, `Project.setupScript`, `Workspace.task`, and all non-migration deltas) | Add the missing Swift fields; remove migration-only roster fields instead of carrying them forward |
| Schema inventory | RPCs, events, routes, capabilities, and terminal formats are complete generated/validated registries | Replace `examples`-only sections and fail the build on an omitted live binding |
| Public Access | REST and RPC remain two adapters over one Host-owned use-case service | Refactor the business logic; do not create a second protocol implementation |
| Relay | `BRLY/2` remains an opaque tunnel for the inner 4.0 WebSocket | Do not move Warren session, terminal, or Agent semantics into Relay |

The logical version must move to `4.0` because removing methods and changing
the binary input contract is a breaking change under the existing protocol
rules. DENB wire version `1` and BRLY/2 do not change: their layouts remain
valid and they are not compatibility aliases. The DENB input header's logical
version default and every generated client constant must move from `3.0` to
`4.0` at the same time.

The two terminal-state formats are deliberately retained because they match
different renderer contracts, not because an old client must be supported.
Native snapshot and replay implementations are both current code paths. The
cleanup requirement is a complete negotiation/schema/test contract for both,
not deletion of either format.

### 9.2 Concrete rewrite and deletion map

| Current surface | Rewrite | Delete after the rewrite |
| --- | --- | --- |
| `Sources/Warren/WarrenRemoteApplicationModel.swift::WarrenRemoteWire` | Make the Desktop model consume `WarrenRemoteClient`; add only a renderer/application adapter where needed | The private actor, duplicate request/reconnect/recovery code, and its private event bridge |
| `wsPeer.input` raw branch and `WarrenRemoteClient.sendBinary` call sites | Encode `DENB` input in the shared Go/Swift/TypeScript helpers; validate the focused lease and attachment on the Host | Raw fallback, arbitrary `sendBinary` API, and any caller that writes unframed PTY bytes |
| `Web/src/wire.js::encodeInput` | Make it the production Web input encoder (or move the same implementation into a shared generated binding) | Test-only duplicate encoders and the old direct-byte send path |
| `session.attach`/`session.detach` | Move the wire clients and tests to subscribe/focus/unsubscribe; keep `session.resize` only as the explicit focused resize operation. The CLI `session attach` command remains as a user-facing wrapper over `session.subscribe`. | Server switch cases, control-only attach parameters, legacy attach state helpers, and attach-specific wire tests |
| JSON `session.input` | Route all input through DENB and return a structured unsupported-method error for the removed RPC | RPC handler, schema entry, base64 helpers, and tests for the removed method |
| Legacy Agent parser/store path | Let provider adapters emit a provider-neutral internal observation that is normalized directly into `CanonicalAgentEvent`; persist journal + checkpoint before broadcasting | `api.AgentEvent`, `CanonicalAgentEventFromLegacy`, `AppendEvents`, `QueryEvents`, `MaxSequence`, `ClearSession`, `agent_events`, `agent_session_state`, `agentSession.events`, and compatibility projection tests |
| Ghostline v0.8 handoff | Start only the current Ghostline runtime; an old socket/session is reported as unsupported and must be recreated | `ghostline_migration.go`, migration journal/tests, v0 compatibility binary and packaging, legacy socket probes, `GhostlineMigration` API/delta/UI, and `WARREN_GHOSTLINE_V0_COMPAT` handling |
| Legacy worktree ownership and config scrubbing | Create the new state/config shape from scratch and require explicit reset for old files | `migrateLegacyWorktreeOwnership`, `WorktreeOwnershipMigrated`, `loadUnlockedWithMigration`, and tests whose only purpose is to rewrite old fields |
| Old Swift JSON control layer | Move remaining production composition to the shared remote client while retaining the DENB codec and renderer contracts | Unreferenced ClientCore control messages, old URL-session transport, unused compatibility-only typealiases, and tests that exercise only the removed layer |
| Public Access REST/RPC | Extract a typed service and have both endpoints call it | Duplicate route-lock, Relay-call, persistence, and error-translation branches (the endpoint adapters stay) |
| Web event cases with no producer | Prove the current producer set against the new manifest | `created`, `runtimeMetadata`, `sessionDeleted`, and fixtures that exist only for removed producers |
| `Service.attachOutput(...)` | None | Delete immediately in its own `refactor:` commit |

The word “delete” here means delete from active source, tests, generated
artifacts, and release packaging. Historical RFCs may remain only as explicitly
marked superseded records; no active document may present a removed method or
format as an available contract.

### 9.3 Data reset policy

“Discard old data” must mean “do not read or migrate it,” not “silently erase
an arbitrary home directory on startup.” The release needs one explicit,
operator-visible reset boundary:

1. Bump the Warren state schema from `2` to a new schema value. Opening any
   other value, including `1`, `2`, or a missing schema, returns a typed
   `state_reset_required` error. Remove the `case 1` migration and do not call
   `ensureTerminalGroups` as a repair for an old file.
2. Create the canonical Agent database under a new, versioned path (for
   example `agent-journal.db`) with only the canonical journal, command journal,
   stream state, and checkpoint tables. Never open the old
   `agent-events.db` to discover or import rows. The release reset step may
   remove the old file only after validating the exact configured path and
   stopping the daemon.
3. Remove Warren-owned OpenCode projection caches and binding records at the
   same boundary; the provider's own database remains external source data and
   is not rewritten by Warren.
4. Do not adopt a pre-cutover Ghostline socket or PTY. Stop the obsolete
   runtime through the release procedure and require new Warren Sessions.
5. Give the endpoint/config file an explicit schema version. A missing or old
   version returns `config_reset_required` instead of running the current
   credential-scrubbing migration. Current Relay enrollment and Keychain
   credentials are not protocol compatibility data and must not be deleted as
   collateral; only metadata in the removed shape is reset.

The reset operation must be explicit and reviewable (for example a confirmed
release command or installer step), idempotent, and logged without printing
tokens or private paths. A daemon started against an old file must fail with an
actionable message; it must never reinterpret old rows as new state.

### 9.4 Implementation order for the one-shot cutover

The product cutover is atomic even if the source changes are split into small
typed commits for review and rollback:

1. **Freeze the 4.0 contract.** Update the schema, generated constants, binding
   map, RPC/event/route manifest, RFC status, and negative compatibility tests.
2. **Make the Host strict.** Gate auth on exactly `4.0`, require DENB input,
   remove attach/detach/input dispatch, enforce explicit terminal-format
   negotiation, and stop emitting migration-only fields.
3. **Rewrite every first-party client.** Migrate Desktop to the shared client,
   complete the Swift roster model, update Web and CLI input/subscription
   calls, and remove all raw binary writes.
4. **Lock terminal recovery contracts.** Keep both native snapshot and replay
   paths, exercise cold attach, reconnect, stale anchors, full-screen TUIs,
   resize, and focus handoff for each supported renderer, and remove only
   unreferenced or duplicate recovery helpers.
5. **Cut over Agent persistence.** Normalize provider observations directly to
   canonical events, make journal/checkpoint persistence atomic, point the
   daemon at the new database path, and remove all legacy reads and writes.
6. **Remove migration machinery.** Delete Ghostline v0 handoff, worktree and
   config rewrites, old Swift control transport, obsolete event handlers, and
   their tests/assets/docs. Apply the explicit state reset once.
7. **Extract duplicated services and finish the sweep.** Share Public Access
   use cases, delete the proven-unused helper and aliases, run repository-wide
   searches for removed symbols, and update active documentation.
8. **Publish one compatible set.** Ship the Host, Desktop, iOS, Web, CLI, and
   Relay-facing route together. A partially upgraded component is expected to
   fail authentication rather than run a mixed protocol.

### 9.5 Acceptance criteria

The cleanup is complete only when all of the following are true:

- The drift test extracts the same complete 4.0 method/event/route/format set
  from the schema and every binding; no catalog section is examples-only.
- A 3.0 client, a client without `version`, a raw binary input, and each
  removed RPC receive a deterministic structured error before any PTY or roster
  data is exposed.
- Both `ghostty-vt-snapshot-v1` and `ghostline-vt-replay-v1` are declared in
  the schema and present in the active Go, Swift, TypeScript, test, and release
  bindings that support them; neither format is an undocumented fallback.
- Active source contains no `WarrenRemoteWire`, `CanonicalAgentEventFromLegacy`,
  `GhostlineMigration`, `migrateLegacyWorktreeOwnership`, or legacy Agent table
  names. Matches in historical archive documents are marked as such and do not
  compile or ship.
- A fresh state and fresh Agent database boot successfully; an old state or
  Agent database fails closed with the reset instruction; no old row is read.
- Desktop, iOS, Web, and CLI all use the same DENB input framing and the same
  subscription/control state machine, and real terminal smoke tests pass.
- REST and RPC Public Access tests exercise one service implementation, while
  Relay tests prove BRLY/2 still forwards the inner protocol opaquely.

### 9.6 Risks accepted by the clean break

| Risk | Decision under this profile | Required guard |
| --- | --- | --- |
| Existing Warren state and Agent history is lost | Accepted; no migration/backfill is implemented | Explicit path-validated reset and release notes that say the data is not recoverable by Warren |
| External 3.0 clients stop working | Accepted; this is the reason for the 4.0 gate | Publish the new contract and fail before roster exposure |
| One renderer advertises a format it cannot install | Not accepted; the two formats must remain explicit capability contracts | Test negotiation and installation per client, including cold attach, reconnect, CJK/SGR, cursor, scrollback, and full-screen redraw behavior |
| Provider events no longer have a legacy projection | Accepted; canonical journal is the only source of truth | Canonical fixture coverage for every provider and restart/replay idempotency tests |
| A stale compatibility reference survives in a package or document | Not accepted | Repository-wide symbol search, generated-manifest check, and release-artifact inspection |

## Final recommendation

Adopt the clean-break profile as the implementation contract: bump the logical
protocol to 4.0, keep the intentional native-snapshot/replay negotiation, make
DENB input and the subscription/focus lifecycle canonical, reset Warren-owned state, and delete
the legacy Agent, Ghostline migration, Desktop wire, and old Swift control
layers. Implement it as one coordinated release with small typed commits and
an explicit reset step. Do not leave a compatibility branch “temporarily”;
that would recreate the same split the audit found.
