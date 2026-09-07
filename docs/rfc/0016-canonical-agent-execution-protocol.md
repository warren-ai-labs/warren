# RFC 0016: Canonical Agent Execution Protocol and Client Event Replicas

- Status: Accepted and implemented
- Owner: Warren Headless, Web, Desktop, iOS, and CLI
- Created: 2026-09-05
- Scope: Agent execution identity, provider adapters, command APIs, append-only event streams, and client persistence
- Protocol baseline: Warren protocol 4.0
- Supersedes: the Agent API and wire portions of RFC 0013 and RFC 0010
- Depends on: RFC 0006 (Agent activity and human attention), RFC 0015 (Cloud Agent daemon and scheduled bots)

---

## 1. Decision summary

Warren exposes one canonical Agent protocol. This is a clean break: the Host
and all clients ship together, and no compatibility messages or aliases for
the current Agent surface are retained.

The protocol has five rules:

1. **Headless owns the facts.** Provider adapters, terminal observers, and
   command handlers run behind warren-headless. The Host appends canonical
   events to one durable journal and broadcasts those same events.
2. **Events are append-only.** Every event has an immutable event ID and a
   required monotonic sequence within one stream. A sequence position can never
   be overwritten by another payload.
3. **Clients are replicas, not authorities.** Web, iOS, Desktop, and CLI keep
   local event replicas for instant rendering and reconnect clarity. A local
   replica is a disposable cache/read model; it never changes Host truth.
4. **Terminal bytes and Agent semantics are separate.** TUI sessions retain
   the DENB PTY stream. Agent events travel on the JSON control channel.
5. **Provider details stop at the adapter.** Clients consume typed,
   provider-neutral events and send typed commands. They do not parse
   transcript formats or infer status from text.

The Host emits semantic events, not React, SwiftUI, or HTML display blocks.
Clients still perform a small presentation projection.

## 2. Goals and non-goals

### 2.1 Goals

- Give every Agent execution one stable Host-owned identity.
- Make a new provider adapter independent from client code.
- Make command admission, idempotency, stale-response handling, and ordering
  explicit.
- Let clients render from a local append-only replica before the network
  catches up.
- Use one cursor model for history and reconnect.
- Preserve Warren's native TUI and Host-first lifecycle.

### 2.2 Non-goals

- Turning PTY bytes into a second semantic event log.
- Encoding client presentation structures in the Host protocol.
- Reusing a Provider conversation ID across different executions.
- Making every TUI prompt remotely answerable.
- Retaining the current Agent wire messages or method names.

## 3. Domain model

The existing Warren glossary remains authoritative for Warren Terminal Session
and Agent Conversation. This RFC adds a Host-owned Agent Execution.

    Target (terminal session or run attempt)
                           |
                           v
                     AgentExecution
                     |- provider conversation reference
                     |- driver and capabilities
                     |- current status
                     |- Turn records
                     '- append-only event stream

An Agent Execution has one immutable execution ID. If /new, /clear, or an
equivalent Provider action starts another conversation, the old execution is
closed and a new execution starts a new stream at sequence 1.

    TargetRef {
      kind: "terminal_session" | "run_attempt"
      id: string
    }

    AgentExecution {
      id: string
      target: TargetRef
      provider: string
      conversation: ProviderConversationRef
      driver: "tui" | "acp" | "cloud"
      capabilities: CapabilityDetails
      state: ExecutionState
    }

    Turn {
      id: string
      status: "started" | "completed" | "failed" | "cancelled"
      startedAt: timestamp
      completedAt?: timestamp
    }

    Interaction {
      id: string
      turnId: string
      kind: "question" | "permission" | "confirmation"
      version: uint64
      title: string
      schema?: bounded JSON schema
      options?: InteractionOption[]
      state: "pending" | "resolved" | "expired" | "cancelled"
    }

Provider conversation IDs and transcript paths are opaque Host metadata.
Clients never use them as cache keys or command targets.

## 4. Authority and processing pipeline

    PTY / ACP / hook / Provider database / Runner
                          |
                          v
                  Agent Driver + Adapter
                          | internal observations
                          v
                  Headless event normalizer
                          | canonical events
                    +-----+------+
                    v            v
              Event journal  Host projections
                    |            |
                    +-----+------+
                          v
                    Client replicas

The internal AgentObservation type is not a wire type. Provider adapters may
use it to report observations without leaking Provider fields into the public
protocol.

The event journal is the only semantic source of truth. Host projections such
as current status, active Turn, pending interactions, and roster summaries may
be checkpointed for performance, but must be rebuildable from the journal.

The PTY and Agent planes share resource identity but not sequence space:

- DENB keeps its terminal cursor and binary framing.
- Agent events use the sequence defined in this RFC.
- A terminal byte must never be interpreted as an Agent event by a client.

## 5. Driver and adapter boundary

Provider and Driver are separate concepts:

    Provider: Claude, Codex, OpenCode, Pi, ...
    Driver:   TUI, ACP, Cloud

The Host binds one concrete driver to each Agent Execution. A driver owns
process and transport lifecycle. A Provider adapter decodes Provider messages
and encodes canonical commands.

The driver contract is intentionally small:

    type AgentDriver interface {
        Start(context.Context, ObservationSink) error
        Execute(context.Context, AgentCommand) error
        Snapshot(context.Context) AgentExecutionSnapshot
        Capabilities() CapabilityDetails
        Close() error
    }

The TUI driver keeps PTY display and raw keyboard input authoritative. Its
structured message path may use bracketed paste, and cancellation may use an
explicit interrupt signal. It may resolve an interaction only through a
Provider-native or blocking hook channel. It must never answer approval by
guessing terminal keystrokes.

The ACP driver uses the Provider's bidirectional JSON-RPC channel without a
PTY. The Cloud driver uses the Run/Runner control plane without a PTY. Both
produce the same canonical Agent events.

## 6. Canonical command API

All Agent commands are typed RPC methods. There is no generic untyped command
map and no legacy alias layer.

### 6.1 Read methods

    agent.execution.get
    agent.events.history
    agent.events.subscribe

agent.execution.get returns the execution descriptor, capabilities, status,
active Turn, pending interactions, and current stream cursor.

agent.events.history accepts afterSequence or beforeSequence and returns an
ordered page. A cursor below the Host retention boundary returns
history_boundary together with a replacement snapshot cursor.

agent.events.subscribe establishes a checkpoint before live delivery. Its
result contains the Host projection checkpoint and every event committed
after the client cursor before the subscription becomes live.

### 6.2 Mutation methods

    agent.execution.resume
    agent.turn.start
    agent.turn.steer
    agent.turn.cancel
    agent.interaction.resolve
    agent.attachment.prepare
    agent.attachment.chunk
    agent.attachment.complete
    agent.attachment.abort

Every mutation contains:

    commandId       durable client-generated idempotency key
    executionId     command target
    expectedVersion optimistic concurrency check
    leaseId         optional control lease for shared TUI input

Repeating a command with the same payload returns its original admission
result. Reusing commandId with a different payload is an error. A response
means accepted by Host; completion is always an event.

agent.turn.start creates a new Turn from text and opaque attachment references.
agent.turn.steer atomically cancels one active Turn and starts a replacement.
agent.turn.cancel only cancels.

agent.interaction.resolve targets an interaction ID and version:

    {
      "executionId": "exec-001",
      "commandId": "cmd-001",
      "interactionId": "int-001",
      "expectedVersion": 2,
      "resolution": { "type": "allow" }
    }

The first valid resolution wins. A second client receives stale_interaction or
the cached result for the same command ID. Resolution is validated against the
interaction schema before the driver is called.

### 6.3 Wire shapes

The authenticated connection starts with one `welcome` message. The Host
identity and the visibility scope are explicit protocol data; neither is
derived by a client from the URL or from a display name:

    {
      "t": "welcome",
      "version": "4.0",
      "host": {
        "id": "host-01J...",
        "name": "build-mac",
        "version": "0.9.0"
      },
      "accessScopeId": "scope-owner",
      "capabilities": ["agent-timeline-v1", "agent-interactions-v1"]
    }

`host.id` is stable for the lifetime of a Host installation. `accessScopeId`
is opaque, non-secret, and stable for the authenticated visibility set. A
change of permissions produces a new scope ID. The Host must never put a
bearer token, filesystem path, or provider credential in this message.

The subscription request and result are deliberately small and explicit:

    {
      "t": "request",
      "id": "req-01J...",
      "method": "agent.events.subscribe",
      "params": {
        "streamId": "exec-001",
        "afterSequence": 41,
        "limit": 200
      }
    }

    {
      "t": "response",
      "id": "req-01J...",
      "ok": true,
      "result": {
        "streamId": "exec-001",
        "executionId": "exec-001",
        "checkpoint": {
          "sequence": 44,
          "state": { "status": "working", "turnId": "turn-008" }
        },
        "events": [ /* events 42, 43, 44 */ ],
        "live": true
      }
    }

The Host establishes the checkpoint before switching the subscription to live
delivery. Thus every event committed after `afterSequence` appears either in
the response or in a later `agent.events` batch, never neither and never as a
second semantic event. `limit` is bounded by the Host and is a delivery hint,
not a cursor.

History uses the same stream and cursor names:

    {
      "streamId": "exec-001",
      "afterSequence": 40,
      "beforeSequence": 0,
      "limit": 200
    }

The successful result contains `events`, `nextAfterSequence`, and
`hasMore`. When the requested cursor is older than Host retention, the request
fails with the structured error `history_boundary` and includes
`retainedFromSequence` plus a replacement checkpoint. Clients must install
that checkpoint and continue at its sequence; they must not invent a new
sequence or replay a provider transcript.

Mutation responses use the same envelope. The response only acknowledges
admission:

    {
      "t": "response",
      "id": "req-01J...",
      "ok": true,
      "result": {
        "commandId": "cmd-01J...",
        "accepted": true
      }
    }

`commandId` is durable and idempotent. Validation or admission failures use
an error object with a stable `code` (`invalid_command`, `stale_version`,
`stale_interaction`, `capability_unavailable`, or `history_boundary`) and a
human-readable `message`. Completion is never encoded as a mutation response;
it is represented by canonical events.

## 7. Canonical event protocol

### 7.1 Event envelope

Every event has the same envelope and a required sequence:

    {
      "eventId": "evt-01J...",
      "streamId": "exec-001",
      "executionId": "exec-001",
      "sequence": 42,
      "turnId": "turn-008",
      "type": "interaction.requested",
      "occurredAt": "2026-09-05T10:00:00Z",
      "recordedAt": "2026-09-05T10:00:01Z",
      "causedBy": "cmd-001",
      "origin": {
        "kind": "provider",
        "provider": "claude",
        "driver": "acp",
        "channel": "rpc",
        "confidence": "native"
      },
      "payload": {
        "interactionId": "int-001",
        "kind": "permission",
        "version": 1,
        "title": "Allow command",
        "options": [
          { "id": "allow", "label": "Allow" },
          { "id": "deny", "label": "Deny" }
        ]
      }
    }

streamId is stable for the lifetime of an Agent Execution. sequence starts at
1, is assigned by Headless at journal commit time, and is never reused.
eventId is globally unique in the Host namespace and is used for duplicate
detection. occurredAt is the Provider or Host occurrence time; recordedAt is
the Host commit time.

Replay is delivery metadata, not an event fact:

    {
      "t": "agent.events",
      "streamId": "exec-001",
      "replay": true,
      "events": [ /* canonical events */ ]
    }

The event payload is a discriminated union selected by type. Provider raw JSON
is not part of this contract. Provider-specific diagnostics use a separate
Host diagnostic channel.

### 7.2 Event vocabulary

    execution.started
    execution.resumed
    execution.replaced
    execution.failed

    turn.started
    turn.completed
    turn.failed
    turn.cancelled

    message.created
    message.delta
    message.completed
    reasoning.delta

    tool.started
    tool.updated
    tool.completed
    tool.failed

    interaction.requested
    interaction.resolved
    interaction.expired

    plan.updated
    tasks.updated
    context.updated
    status.changed

Message events use a stable messageId. Deltas additionally use an append-only
deltaIndex. Tool events use callId. Interaction events use interactionId and a
monotonic version. status.changed carries the complete RFC 0006 status object,
never a patch.

The Host emits status.changed from the status reducer and stores it in the same
journal. A client replaces its status projection; it does not infer status from
message timing, punctuation, or Provider text.

Host-wide attention delivery uses the same envelope. Its stream ID is the
reserved value `host:attention:v1` and it is not an execution ID. A client may
subscribe to that stream and receive `attention.changed` events whose payload
contains a target `executionId` and sanitized attention metadata. The stream
is scoped by `accessScopeId`; two visibility scopes never share attention
events. There is no second `host.attention` event format.

### 7.3 Ordering and integrity

- Events are ordered by sequence within one streamId.
- Provider timestamps never override Host sequence order.
- A duplicate (streamId, sequence) with the same eventId and payload is a
  no-op.
- A duplicate sequence with a different event is a protocol integrity error;
  clients must not overwrite the first event.
- Unknown event types still advance the cursor and remain persisted.
- The Host appends events and updates its checkpoint in one transaction.

## 8. Client event replicas

Client persistence is mandatory. It provides instant cold-start rendering,
clear reconnect behavior, and a durable local copy of the append-only stream.
It is not a second authority.

### 8.1 Namespace and scope

    ReplicaNamespace = (hostId, accessScopeId)

- hostId is the stable Host.id returned in the authenticated welcome. It is
  not the URL, relay route, workspace name, or display name.
- accessScopeId is an opaque, non-secret identifier returned by welcome. It
  identifies the authenticated visibility scope and changes when that scope
  changes.
- Direct owner and shared/Relay connections receive non-colliding scopes.

Endpoint names and URLs are local routing metadata only. Direct and Relay
routes to the same Host and access scope intentionally share one event
namespace.

clientProfileId is separate and local. It scopes drafts, queued messages,
collapsed cards, and attachment state; it is never part of an Agent event
identity.

### 8.2 Keys and ranges

The canonical event key is:

    (hostId, accessScopeId, streamId, sequence)

The duplicate index is:

    (hostId, accessScopeId, streamId, eventId)

The synchronization state key is:

    (hostId, accessScopeId, streamId)

streamId is normally executionId. The Host attention stream is a separate
stream ID in the same namespace. sessionId is only an index from the Warren
roster to the active execution; it is never the primary event key.

A client replica stores at least:

    agent_events(
      host_id,
      access_scope_id,
      stream_id,
      execution_id,
      sequence,
      event_id,
      event_type,
      event_json,
      recorded_at,
      PRIMARY KEY (host_id, access_scope_id, stream_id, sequence),
      UNIQUE (host_id, access_scope_id, stream_id, event_id)
    )

    agent_stream_state(
      host_id,
      access_scope_id,
      stream_id,
      retained_from_sequence,
      head_sequence,
      contiguous_through,
      checkpoint_sequence,
      checkpoint_json,
      has_more_before,
      updated_at,
      PRIMARY KEY (host_id, access_scope_id, stream_id)
    )

checkpoint_json is a replaceable derived projection used for cold starts. It
can always be discarded and rebuilt.

### 8.3 Cursor semantics

The replica tracks three positions:

- headSequence: the greatest sequence observed, even if there is a gap;
- contiguousThrough: the greatest sequence for which every event after the
  locally retained boundary is present;
- retainedFromSequence: the oldest event still held locally.

The client reconnects with afterSequence = contiguousThrough, not
headSequence. If the cache has events 41, 42, and 44, headSequence is 44 but
contiguousThrough is 42. Receiving 43 advances the contiguous cursor to 44.

### 8.4 Sync algorithm

1. Authenticate and receive hostId, accessScopeId, and the current roster.
2. Load local stream state for each visible execution.
3. Request agent.events.subscribe from contiguousThrough.
4. Atomically persist the returned checkpoint and catch-up events.
5. Apply those committed events to the in-memory reducer.
6. Persist each live batch before advancing contiguousThrough.
7. On a gap, request the missing range through agent.events.history.
8. On a sequence conflict, quarantine only that stream and refetch its Host
   snapshot; never silently replace a cached event.

The Host may send one event in both a history page and a live batch. The local
transaction must make that duplicate a no-op.

### 8.5 Retention and lifecycle

The Host journal is append-only. Client replicas may prune old events by count
or bytes, but pruning removes the oldest retained rows and updates
retainedFromSequence. Local pruning never changes the Host cursor.

When an execution is replaced, the new execution receives a new stream ID. The
old stream is closed but may remain locally cached for historical browsing.
When an execution or access scope is deleted, the client removes only that
stream or namespace.

When the Host reports history_boundary, the client installs the supplied
checkpoint and continues from its sequence. Local events before that boundary
are disposable cache data.

## 9. Capability contract

Capabilities are computed for the concrete Agent Execution:

    timeline.read
    turn.start
    turn.cancel
    turn.steer
    interaction.resolve
    attachment.upload
    execution.resume
    terminal.raw

Each capability includes a mode:

    native | hook | pty-framed | pty-signal | observed | none

Examples:

    TUI without hook:
      timeline.read        observed
      turn.start           pty-framed
      turn.cancel          pty-signal
      interaction.resolve  none

    ACP:
      timeline.read        native
      turn.start           native
      turn.cancel          native
      turn.steer           native
      interaction.resolve  native

An unsupported operation is absent or explicitly none. The Host must never
advertise a capability because a Provider type is known.

## 10. Client and UI contract

The UI is an event consumer and command producer. Web, iOS, and Desktop data
layers implement the same logical store:

    AgentExecutionStore
      applySnapshot(...)
      append(events...)
      history(...)
      dispatch(command...)

The reducer knows event types and stable IDs, but not Provider names or
transcript formats. It may assemble message deltas, keep a tool card open until
tool.completed, and render Markdown. These are generic presentation operations,
not semantic inference.

The following remain local UI state and are outside the Host event journal:

- draft text;
- attachment upload progress;
- collapsed/expanded cards;
- local notification acknowledgement;
- an optional local message queue.

The terminal surface continues to consume DENB. Agent events must not repaint
the PTY, and PTY bytes must not fabricate structured interactions.

## 11. Wire version and clean break

The JSON control protocol is logical version 4.0. An old or future client is
rejected during handshake before roster or session data is exposed.

The following public types and messages are removed rather than adapted:

    agent
    agent.status
    agent.turn
    old agent.history and agent.subscribe result shapes
    agent.message.send
    agent.turn.interrupt
    flattened AgentEvent
    AgentStatusMessage
    AgentTurnMessage
    global optional AgentController

The DENB binary terminal envelope remains independently versioned.

## 12. Implementation plan

1. Add protocol 4.0 types and schema, including welcome.host and
   welcome.accessScopeId.
2. Replace the flattened event struct with typed domain events and one journal
   append path.
3. Move Agent conversation metadata out of Session into AgentExecution.
4. Replace the optional global controller with concrete per-execution drivers.
5. Implement durable command receipts and event append transactions.
6. Implement the ACP driver before registering ACP capabilities.
7. Implement TUI hook gates where supported; keep unsupported interactions
   terminal-only.
8. Replace Web/iOS/Transport handling with one execution store and the
   namespace/key/cursor rules above.
9. Delete obsolete branches and run cross-platform contract tests.

## 13. Acceptance tests

1. Every emitted Agent event has a sequence and immutable event ID.
2. Duplicate delivery produces one local row and one reducer update.
3. A conflicting payload at an existing sequence fails loudly and is never
   overwritten.
4. Reconnect requests the greatest contiguous sequence, not the greatest
   observed sequence.
5. A TUI prompt without a hook exposes no interaction.resolve capability.
6. A stale interaction response cannot resolve a newer interaction version.
7. Rebinding a Provider conversation creates a new execution stream.
8. Direct and Relay routes for the same Host and access scope share a cache
   namespace.
9. Different access scopes cannot read each other's local event rows.
10. Deleting one execution or scope does not delete unrelated Host streams.
11. Web, iOS, Desktop, and CLI render the same event sequence and status.
12. Removing the derived checkpoint and local cache still permits a full
    rebuild from execution.get and events.history.
