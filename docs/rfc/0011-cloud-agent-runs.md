# RFC 0011: Cloud Agent runs and runner control plane

- Status: Proposed
- Owner: Warren Headless, clients, and Runner
- Created: 2026-09-01
- Scope: asynchronous Agent execution across local, remote, and cloud targets
- Protocol baseline: Warren protocol 2.0 with capability negotiation
- Depends on: RFC 0004 (headless flow orchestration), RFC 0006 (Agent activity and attention)

## Summary

Warren will add a durable **Run** domain for asynchronous Agent work. A Run is
the product-level record for a task that may execute on a local Host, a
user-managed remote Host, or an ephemeral Cloud Runner. It owns the execution
intent, policy snapshot, lifecycle, events, and resulting artifacts. It does
not replace Terminal Session, Workspace, Runtime, or Relay resources.

The public product name is `Run`. Headless may persist a single-node Run using
the `FlowRun` shape from RFC 0004 and may add `NodeRun` records for a graph.
Each retry creates a new immutable `RunAttempt`; a client reconnects to the Run
and its event history rather than to a provider's terminal process.

The first implementation target is a BYOC/self-hosted Runner. Warren-hosted
multi-tenant execution, organization controls, and billing are later layers,
not prerequisites for validating the Run contract.

## Motivation

The current Agent integration is a read-only projection of a provider CLI
running inside a Warren Terminal Session. The PTY is the source of truth and
the Agent transcript, status, and turn are best-effort projections. This is the
right model for interactive local work, but it cannot provide a Cloud Agent
experience:

- a client must not stay connected while work is running;
- an ephemeral environment needs an explicit setup, policy, expiry, and
  cleanup lifecycle;
- progress, approvals, retries, and follow-up messages need durable events;
- the useful result is a diff, check report, log, artifact, or pull request,
  not a terminal screenshot;
- a cloud worker must be isolated from the control plane and from other runs.

RFC 0004 already supplies FlowDefinition, FlowRun, NodeRun, and approval
concepts. Its default `agent.run` behavior creates a Terminal Session, which is
appropriate for a PTY-backed Host but is too strong a requirement for a Cloud
Runner. This RFC keeps the flow model and adds a target-neutral Runner
boundary, a non-PTY execution path, and the missing persistence and policy
contracts.

The design follows the common shape of current Cloud Agent products: an
independent environment per task, background execution, structured events,
reviewable code changes, and explicit human attention points. Warren's
differentiation is continuity across local, remote, and cloud execution with
the same Host protocol and Workspace history.

## Goals

- Run an Agent without a connected Desktop, Web, or iOS client.
- Make local, remote, BYOC, and hosted Cloud execution targets selectable by a
  typed intent rather than by a terminal preset.
- Preserve one source of truth in Headless or the Warren Control Plane.
- Keep the existing Workspace and Session resource models; do not create a
  parallel cloud-only resource tree.
- Capture an immutable environment and permission policy for every attempt.
- Persist a bounded, replayable event stream for status, Agent activity,
  approvals, tests, and failures.
- Support cancellation, approval, follow-up, retry, reconnect, expiry, and
  explicit cleanup.
- Return reviewable artifacts: branch/commit, unified diff, test results,
  logs, screenshots where applicable, and PR/MR links.
- Normalize Codex, Claude, OpenCode, and future provider adapters without
  making provider conversation IDs Warren resource IDs.
- Allow old clients and Hosts to continue operating when Run capabilities are
  absent.

## Non-goals

This RFC does not define:

- a new model-training or inference service;
- a new Terminal Session, Workspace, or Runtime schema;
- a plugin marketplace or arbitrary code loaded into Headless;
- a second Relay implementation or persistent data in Relay;
- organization billing, quotas, SSO, or hosted multi-tenancy in the first
  phase;
- automatic merge or release policy beyond an explicit Run node or external
  integration;
- a terminal-shaped UI for a Cloud Run that has no PTY;
- rewriting or deleting a provider transcript.

## Terminology and authority

**Run** is the stable product identity of one user-requested execution. A Run
may contain one Agent node or a graph of dependent nodes.

**FlowRun** is the orchestration record described by RFC 0004. It is the
recommended persistence representation for a Run with multiple nodes; clients
must not expose two separate concepts for the same execution.

**NodeRun** is one node's state in a FlowRun. The initial node types remain
`workspace.create`, `agent.run`, `command.run`, `approval`, and `gate`.

**RunAttempt** is one concrete execution of a Run or NodeRun. A retry never
mutates the prior attempt; it creates a new attempt with a new environment and
execution lease.

**Runner** is an execution adapter, not a user-facing resource. It can be a
Warren Host using an existing Runtime, a container or VM managed by Warren, or
an adapter for a provider-hosted Agent API.

**Control Plane** is the authority for Run intent, scheduling, policy, events,
and artifact metadata. In the BYOC phase it may be part of `warren-headless`;
the hosted service can split it into a separate service later.

**ConversationRef** identifies a provider conversation. It is opaque metadata
associated with an attempt and is never used as a Session ID or Run ID.

Run state is owned by the Control Plane. Workspace and Terminal Session state
remain owned by the Host that creates them. Runner processes own only their
short-lived process, checkout, and local buffers. Relay owns reachability,
pairing, and frame forwarding; it does not schedule Runs or store their
content.

## Domain model

```text
Host
├── Projects / Workspaces / Terminal Sessions / Runtimes
└── Run service (local or attached Control Plane)
    ├── Run (wire/product projection of FlowRun)
    │   └── NodeRun
    │       └── RunAttempt
    ├── EnvironmentSnapshot
    ├── Artifact
    └── ConversationRef
```

### Run

```text
Run {
  id
  taskID?                 # existing Warren Task, if any
  projectID?
  source                  # repository/ref/base commit
  target                  # local | remote | byoc | cloud | provider
  workspaceID?            # existing or Host-created Warren Workspace
  flowID?
  prompt
  agentProfile
  environmentSnapshotID
  policy
  status
  attention?
  createdBy
  createdAt
  expiresAt?
  retention
}
```

`source` is immutable after start and records the repository identity, base
branch or commit, and requested output branch. A Run may reference a normal
Warren Workspace when the target is a Host. An ephemeral runner may use a
temporary checkout instead; in that case the checkout identity is stored on
the attempt and a Warren Workspace is materialized only when the user asks to
promote or inspect it. This avoids a second cloud-only Workspace model.

The minimum Run states are:

```text
queued
  → provisioning
  → running
  → needs_attention
  → validating
  → succeeded | failed | cancelled | expired
```

`needs_attention` is entered only for a typed approval, question, or an
explicitly reported human decision. A client must not infer it from a prompt,
terminal text, or a stalled network request. A failed or cancelled Run may
retain its checkout and artifacts according to `retention`; cleanup is an
explicit policy action and must be observable.

### RunAttempt

An attempt records the concrete Runner identity, lease, start and finish times,
environment digest, checkout branch/commit, `ConversationRef`, exit reason,
and resource usage. The control plane allocates at most one active attempt for
an idempotency key. A lost Runner lease is recoverable: the scheduler marks
the attempt `failed` or `expired` after its heartbeat grace period and may
create a new attempt only through an explicit retry policy.

### EnvironmentSnapshot

An environment snapshot is immutable and addressable by digest. It contains:

- image or VM template digest;
- setup and maintenance commands;
- toolchain and dependency cache policy;
- non-secret environment values;
- references to Secrets, never their plaintext values;
- network egress mode and allowlist;
- CPU, memory, disk, duration, and concurrency limits;
- filesystem mounts and allowed capabilities.

The snapshot is stored with the Run's policy version so a later environment
edit cannot silently change a running or retrying attempt. Secret values are
injected just before execution, redacted from events and logs, and removed
when the attempt ends.

### Artifact

Artifacts are immutable or content-addressed outputs with a type, digest,
size, retention class, and download or external URL metadata. Initial types
are `diff`, `patch`, `check-report`, `log`, `screenshot`, `archive`, and
`pull-request`. The control plane stores metadata and access capabilities;
large payloads may use an object store or Runner-local retention according to
policy.

### ConversationRef

```text
ConversationRef {
  provider
  providerID
  attemptID
  resumeSupported
  metadataVersion
}
```

The provider ID may be a Codex thread, Claude session, OpenCode database ID,
or a remote provider conversation. It is opaque to clients and is not copied
into `Session.AgentSessionID` unless the attempt is explicitly attached to a
real Warren Agent Session.

## Execution architecture

```text
Desktop / Web / iOS
        │ typed Run intents and projections
        ▼
Warren Control Plane
  ├─ Run / Flow / Policy / Environment authority
  ├─ durable event log and scheduler
  ├─ approval, retry, cancellation, and follow-up
  └─ artifact and integration metadata
        │ scoped Runner lease
        ▼
Runner
  ├─ Warren Host + existing Runtime
  ├─ ephemeral container or VM
  └─ provider adapter
        │
        ▼
Checkout → Agent / Command nodes → tests
        │
        ▼
Events + logs + diff + checks + PR/MR
```

The Runner connects to the Control Plane with a short-lived, scoped
capability. The connection may use a direct endpoint or an existing Relay
route, but the Relay remains a transport boundary and never becomes the
scheduler. A Runner must heartbeat its lease, acknowledge cancellation, and
publish a terminal result exactly once. Duplicate result delivery is safe by
`attemptID` and event sequence.

For a Host target, the Runner invokes the existing Runtime adapter and may
associate the attempt with a Warren Terminal Session. For a container or VM,
the Runner owns the process and checkout directly. For a provider adapter,
the adapter translates provider events and controls into the normalized Run
contract.

### Agent and terminal boundary

The existing Agent watcher remains valid for interactive Sessions. A Cloud
attempt instead emits normalized events directly through the Run event stream.
It must not manufacture PTY bytes or a fake Terminal Session merely to satisfy
the existing Agent View.

When a real PTY exists, the Run detail may link to the associated Session and
offer `Open terminal`. When no PTY exists, the UI exposes structured activity,
logs, tool calls, tests, and artifacts only. A follow-up is a typed Run intent;
it may resume the same `ConversationRef` when the provider supports it or
create a new attempt when the policy requires a fresh environment.

## Event and protocol contract

Protocol 2.0 remains the wire baseline. Run features are additive and exposed
through capability negotiation. Suggested capabilities are:

| Capability | Meaning |
| --- | --- |
| `runs-v1` | Run snapshots and typed Run requests are supported |
| `run-events-v1` | Replayable normalized Run event batches are supported |
| `run-interactions-v1` | Approval/question requests and responses are supported |
| `run-artifacts-v1` | Artifact metadata and scoped download operations are supported |
| `run-followup-v1` | Follow-up messages can be submitted to an active Run |

The Host or Control Plane is the only writer. Every request carries an
immutable `runID` or `attemptID` and a `requestID`; the same request ID is
idempotent. A client never targets the current selected Run implicitly.

The minimum request surface is:

```text
run.create       { requestID, spec }
run.start        { requestID, runID }
run.snapshot     { runID }
run.history      { runID, cursor, limit }
run.subscribe    { runID, cursor }
run.cancel       { requestID, runID, reason? }
run.approve      { requestID, runID, interactionID, decision }
run.retry        { requestID, runID, nodeID?, policy? }
run.followup     { requestID, runID, text, attachments? }
run.cleanup      { requestID, runID, scope }
artifact.get     { runID, artifactID }
```

Events use a Run-local epoch and monotonic sequence, independently of the
terminal output cursor and the provider transcript sequence:

```json
{
  "t": "run.event",
  "run": "run-1",
  "epoch": 2,
  "events": [
    {
      "seq": 41,
      "attempt": "attempt-2",
      "type": "test.finished",
      "state": "failed",
      "payload": { "command": "go test ./...", "exitCode": 1 }
    }
  ]
}
```

Event payloads are typed at the domain boundary and extensible on the wire.
Initial event types are `run.created`, `run.status`, `run.attention`,
`checkout.ready`, `agent.message`, `agent.tool`, `command.started`,
`command.finished`, `test.started`, `test.finished`, `artifact.created`,
`approval.requested`, `approval.resolved`, `runner.heartbeat`, and
`run.completed`. Unknown event types still advance the sequence and are
ignored safely by older clients.

The Control Plane persists enough event history to recover a Run after a
client or daemon restart. It may compact old events behind a snapshot, but it
must retain the snapshot cursor and report when a requested cursor is too old.

## Interaction, policy, and safety

An Agent may ask for a question or permission only through a typed interaction
event with a stable `interactionID`, options, expiry, and required capability.
The client submits a decision; the final `approval.resolved` event is the
authority. Sending text to a PTY, parsing a question mark, or waiting for a
provider-specific prompt is not a substitute.

The initial policy fields are:

```text
Policy {
  approvalMode       # never | on-dangerous-action | every-tool | explicit
  networkMode        # disabled | allowlist | unrestricted
  allowedDomains[]
  secretRefs[]
  maxDuration
  maxAttempts
  retainWorkspace    # always | on-failure | until-complete | never
  retainArtifacts
  allowPullRequest
}
```

The Runner must execute untrusted repository code in a per-attempt isolation
boundary. It must not expose the Host socket, Warren token, sibling run
directories, or arbitrary host mounts. Network egress, credentials, process
limits, and cleanup are enforced by the Runner rather than by UI hints.
Control Plane logs and artifacts must redact configured secrets. Hosted
multi-tenancy additionally requires signed Runner enrollment, organization
scoping, quota enforcement, audit records, and a durable secret manager; those
requirements are deliberately deferred but cannot be skipped when hosted
execution is enabled.

## Client product and UI

Runs become a top-level product surface. Terminal tabs remain the right place
for live PTY interaction; Cloud Runs are not hidden inside a Terminal Group.

```text
Sidebar
├── Runs
│   ├── Needs attention
│   ├── Running
│   ├── Review
│   └── Archive
├── Tasks
├── Projects
└── Terminal Groups
```

### New Run

The creation form contains:

- Task, Issue, Repository, and source/base branch;
- output branch and workspace mode (`new`, `current`, `selected`, or
  ephemeral checkout);
- execution target (`Local`, `Remote`, `BYOC`, or `Cloud`);
- Environment and Agent provider/model/profile;
- permission mode, network policy, Secrets, duration, and retention;
- prompt and attachments;
- `Run in background` (the default for Cloud and BYOC targets).

The form shows a capability-aware preview. If the selected target cannot
provide approvals, artifacts, or a PTY, the UI states the limitation before
start instead of presenting controls that cannot work.

### Run detail

The detail view contains:

- a header with status, repository, branch, target, Runner, and elapsed time;
- a timeline for plan, Agent messages, tool calls, approvals, commands, and
  tests;
- result tabs for `Diff`, `Checks`, `Logs`, `Artifacts`, and `PR/MR`;
- a follow-up composer that is disabled after expiry or terminal cleanup;
- `Stop`, `Retry`, `Approve`, `Cleanup`, and `Open PR` actions according to
  capabilities and policy;
- `Open terminal` only when the attempt is linked to a real PTY-backed Session.

The list view is attention-oriented: status, latest activity, elapsed time,
branch, target, and the next required action are visible without opening a
terminal. Web is the full review surface. iOS prioritizes Run list,
notifications, approvals, follow-up, stop, and compact diff/check summaries;
large diffs and environment editing may deep-link to Web.

## Rollout

### Phase 0: contract and local scheduler

- finalize Run, Attempt, EnvironmentSnapshot, Artifact, and policy schemas;
- implement the state machine, event cursor, idempotency, and capability
  handshake;
- add a local single-node scheduler behind `warren-headless`;
- update RFC 0004's Agent node rule to make Session creation conditional on a
  real PTY.

### Phase 1: BYOC and ephemeral container Runner

- define Runner enrollment, lease, heartbeat, cancellation, and result
  protocol;
- run a checkout, Agent, and tests in a disposable container;
- expose Runs, timeline events, diff, checks, logs, and artifact metadata in
  Web;
- retain the existing local and remote Host paths unchanged.

### Phase 2: durable interactions and review loop

- add approval/question responses, follow-up, retry, reconnect, cleanup, and
  PR/MR creation;
- add push notifications and the iOS Run surface;
- add structured provider adapters and ConversationRef resume behavior;
- exercise restart, lease loss, duplicate delivery, stale cursors, and secret
  redaction in acceptance tests.

### Phase 3: hosted Cloud Runner and team control plane

- add Warren-managed isolation, object storage, secret manager, and quotas;
- add GitHub/GitLab/Linear/Slack triggers and webhooks;
- add organizations, roles, SSO, audit, usage reporting, and billing;
- publish retention, data residency, network, and incident-response policies.

## Compatibility and migration

- A Host without `runs-v1` keeps current Session and Agent behavior.
- A client without Run capabilities continues to render the existing roster
  and Terminal/Agent views.
- Existing `FlowDefinition`, `FlowRun`, `NodeRun`, and `AgentProfile` records
  remain valid; this RFC adds execution target, attempt, environment, event,
  and artifact fields through versioned optional fields.
- No existing Terminal Session is converted into a Run automatically.
- Relay deployments remain compatible because Run frames are opaque transport
  payloads; Relay does not need Run persistence to forward them.

## Acceptance criteria

1. A Run can start and finish with no connected client, and its snapshot and
   event history survive a Control Plane restart.
2. Repeating `run.create`, `run.start`, `run.cancel`, or `run.retry` with the
   same `requestID` produces one effect and one stable receipt.
3. A retry creates a distinct Attempt with a captured environment digest and
   does not rewrite the prior attempt's events or artifacts.
4. A Cloud or BYOC attempt never requires a PTY and never fabricates terminal
   output; a real PTY-backed attempt can link to an existing Session.
5. Approval, cancellation, expiry, and cleanup are represented by typed
   events and remain correct across reconnects and duplicate delivery.
6. A Runner cannot access another attempt's checkout, Host credentials, or
   unrestricted network unless the captured policy explicitly permits it.
7. A completed Run exposes at least a status summary, branch/commit, logs,
   test results, and a diff or an explicit reason why no diff exists.
8. Existing Hosts and clients that do not negotiate Run capabilities preserve
   current startup, Session, Agent projection, and Relay behavior.

## Alternatives considered

### Model Cloud Agent as a fourth Session kind

Rejected. Session currently means a real interactive PTY with Host-owned
runtime lifecycle. Making a Cloud Run a Session would force clients to infer
completion from terminal text, hide artifacts behind a terminal surface, and
make cleanup semantics ambiguous.

### Make Relay the Cloud scheduler and data store

Rejected. Relay is intentionally a transport and pairing service and currently
does not store terminal output, user input, or Host resource state. Scheduling,
policy, event retention, and artifacts require a separately authorized Control
Plane.

### Build a provider-specific Cloud Agent integration first

Rejected as the product boundary. Provider adapters are useful implementations,
but a Warren Run must remain able to move between a local CLI, a BYOC Runner,
and a hosted provider without changing its identity, UI, or artifact contract.

## References

- [RFC 0004: Headless flow orchestration and optional extensions](0004-headless-flow-orchestration.md)
- [RFC 0006: Agent activity and attention](0006-agent-activity-attention.md)
- [Headless architecture](../headless-architecture.md)
- [Warren product and system design](../../DESIGN.md)
- [OpenAI Codex Cloud](https://developers.openai.com/codex/cloud)
- [OpenAI Cloud environments](https://developers.openai.com/codex/environments/cloud-environment)
- [GitHub Copilot coding agent](https://docs.github.com/en/copilot/concepts/agents/coding-agent/about-coding-agent)
- [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)
