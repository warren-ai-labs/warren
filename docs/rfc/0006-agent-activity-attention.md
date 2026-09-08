# RFC 0006: Agent activity and human attention

- Status: Implemented
- Owner: Warren Headless, Web, Desktop, and CLI clients
- Created: 2026-08-22
- Scope: Codex, Claude, OpenCode, Pi, Qoder, and Antigravity session status projection
- Supersedes: the `waitingForInput` activity heuristic described in the first
  agent status implementation

## Summary

Warren will stop using one activity enum to represent both what an Agent is
doing and whether a person should inspect the Session. The Host will publish a
single `AgentStatus` value with two independent dimensions:

```text
activity:  ready | working | blocked | stalled | failed | exited
attention: null | input | approval | warning
```

`activity` describes the Agent lifecycle. `attention` describes an outstanding
human-facing condition. A yellow status dot means that attention is present or
that the Session is stalled; it does not claim that the Agent is necessarily
waiting for typed input.

Turn termination is a separate lifecycle projection. `interrupt` describes a
Provider-observed stop with no matching Host cancellation request. `cancel`
describes a Host request whose terminal Provider observation can be correlated
to that request. The two observations may lead to the same `ready` activity,
but they are different facts and produce different turn events.

This RFC deliberately permits a protocol break. Warren ships the Host, CLI,
Web, and Desktop as one product release, so the new status contract replaces
the old `agent.activity` message instead of carrying a compatibility layer.

## Motivation

The previous implementation assigned `waitingForInput` to three unrelated
observations:

- Codex `turn_aborted`;
- Claude `[Request interrupted by user]`;
- any pending tool call with no result after five seconds.

Those observations do not have the same meaning. A user interrupt normally
leaves an Agent idle and ready for another request. A five-second tool call is
usually normal work, not a permission prompt. Treating both as `waitingForInput`
made the yellow dot assert a fact that the Host did not know.

The status contract must optimize for an honest user signal:

- amber means expected work is in progress;
- yellow means a person should inspect or act;
- red means a known failure;
- green means normal idle readiness;
- gray means the Agent process has exited.

## Concepts

### Activity

`activity` is a lifecycle projection owned by the Host. It is not a diagnosis
and it is not a notification.

| Value | Meaning |
| --- | --- |
| `ready` | No active turn; the Session can accept a new request. |
| `working` | An active turn is making expected progress. |
| `blocked` | An active turn cannot continue until an external response, such as an answer or approval, is supplied. |
| `stalled` | An active turn has exceeded the configured no-progress grace period; the cause is not known to be a user request. |
| `failed` | The provider reported a terminal error for the turn or process. |
| `exited` | The Agent process ended and the surrounding terminal Session remains. |

`blocked` and `stalled` are activity states, not evidence by themselves about
why the Agent stopped. Their corresponding `attention` value carries that
human-facing meaning.

### Attention

`attention` is nullable. A non-null value means that the Session deserves
human inspection or action. It contains stable, non-conversational metadata:

```json
{
  "kind": "approval",
  "reason": "permission",
  "requestId": "call-42",
  "since": "2026-08-22T10:00:00Z"
}
```

The allowed `kind` values are:

- `input`: the provider explicitly requests an answer or elicitation;
- `approval`: the provider explicitly requests permission;
- `warning`: Warren has evidence of an abnormal condition, such as a stalled
  turn or an unexpected interruption.

`reason` is a finite, provider-neutral code used for labels and telemetry.
Initial values are `question`, `permission`, `stalled`, and
`unexpectedAbort`. Providers may add codes only through a documented RFC
update. Raw prompt text, command arguments, transcript content, and secrets
must never be placed in `attention`.

The following invariants are required:

1. `attention.kind == input` or `approval` implies `activity == blocked`.
2. `attention.kind == warning` with `reason == stalled` implies
   `activity == stalled`.
3. `activity == failed` has no `attention` object; red is already the highest
   severity and carries the failure details through the existing error/event
   channels.
4. `activity == ready` normally has no `attention`. A warning for an unknown
   or unexpected abort requires separate evidence; a `turn.interrupted` event
   alone never creates `attention.kind == warning`.

## Presentation contract

Clients do not infer status from transcript text or event timing. They render
the Host's `AgentStatus` value using this precedence:

```text
failed > attention/blocked > stalled > working > ready > exited
 red        yellow          yellow     amber    green    gray
```

The yellow label, tooltip, and accessibility label are always `Needs
attention`. The `activity` and `attention` subdivisions remain Host-owned
protocol data for reducers, clearing rules, and diagnostics; they are not
part of the user-facing status vocabulary. This keeps every yellow marker
visually and semantically consistent across Web, Desktop, and CLI surfaces.

Opening a Session does not clear attention. Attention is a condition, not a
client-local notification badge. It clears only when the Host observes a
matching provider resolution, an explicit user answer/approval/cancel, a new
turn that supersedes the request, or `SessionEnd`.

Workspace and Terminal Group summaries reduce child statuses with the same
precedence. If several children are yellow, the summary keeps the highest
priority reason and the number of affected Sessions remains available to the
client. A client must not look only at the selected Tab.

## Observation pipeline

Provider-specific formats stay outside the status reducer:

```text
Codex / Claude transcript or hooks
OpenCode SQLite projection
PTY liveness observations (optional)
             │
             ▼
      provider adapter
             │ normalized AgentObservation
             ▼
       status reducer
             │ AgentStatus
             ▼
   Host status store and broadcast
             │
             ▼
       Web / Desktop / CLI
```

### Provider adapter

An adapter converts raw input into provider-neutral observations. It may read
event names, IDs, timestamps, and bounded metadata, but it must not make UI
decisions. The adapter is the only layer that knows whether a provider event
means `PermissionRequest`, `turn_aborted`, or `task_complete`.

### Status reducer

The reducer is the single authority for `AgentStatus`. It folds normalized
observations in order, associates requests with turn and call IDs, clears
stale attention, and emits a complete status snapshot whenever the value
changes. Transcript rendering and status reduction may share the same tailer,
but neither one may mutate the other's state implicitly.

### Liveness monitor

The liveness monitor is separate from transcript parsing. A missing transcript
line is not an input request. It may emit `ProgressHeartbeatLost` after the
configured grace period, which the reducer can turn into `stalled` plus a
`warning` attention. A later transcript line, PTY heartbeat, tool result,
turn boundary, or process exit clears the stalled warning.

### Interrupt and cancellation boundary

Agent interruption has three distinct planes. They must not be collapsed into
one optimistic status mutation:

1. **Input plane**: a TUI key is a raw PTY byte (`0x03` for Ctrl-C or `0x1b`
   for Escape). Warren forwards it to the terminal driver. The status reducer
   does not observe the byte and must not infer an interrupt from it. Escape is
   provider-defined; Ctrl-C may be translated by the TTY into a process signal.
2. **Command plane**: `agent.turn.cancel` is a Host command admission. An
   `accepted` response means that the driver accepted a cancellation attempt;
   it is not evidence that the Provider stopped the turn. Accepting the command
   does not change `activity`.
3. **Observation plane**: the Provider adapter or lifecycle hook emits a
   normalized terminal observation after the Provider has actually stopped.
   Only this observation may complete the turn and move `working` to `ready`,
   `failed`, or `exited`.

The same Provider observation may result from a TUI key, a Warren cancel
command, or a Provider-side action. Unless the driver can prove the origin,
the adapter must not claim that a particular key caused it. A Host-originated
cancel may correlate the resulting turn event with its command ID through the
canonical event's `causedBy` field; a direct TUI interruption normally has no
such correlation.

The reducer follows these rules:

| Observation | Result |
| --- | --- |
| Raw PTY input only | Keep the current activity; never infer completion or attention. |
| Cancel command accepted | Keep the current activity; expose completion only through a later lifecycle event. |
| Confirmed Provider abort with no matching Host cancel/steer request (`turn_aborted`, Claude's interruption marker, Pi `stopReason=aborted`, or an equivalent terminal boundary) | `ready`, emit `turn.interrupted`, and leave `causedBy` absent. |
| Confirmed Provider abort matching an accepted Host cancel/steer request | `ready`, emit `turn.cancelled`, and set `causedBy` to that command ID. |
| No terminal observation after an accepted cancel | Keep `working` until normal liveness or process rules apply; do not fabricate `ready`. |

`turn.interrupted` and `turn.cancelled` are **completion events**, not command
acknowledgements. A client may show a local "cancelling" affordance after the
command receipt, but it must continue rendering Host `AgentStatus` as the
authority and must clear that affordance only after a Host event or a fresh
snapshot. A normal `turn.completed` or `turn.failed` boundary also clears an
unfulfilled pending cancel request; it must not be relabeled as cancellation.

## Event mapping

The following table is normative for the first implementation.

| Normalized observation | Result |
| --- | --- |
| `SessionStart` | `ready`, no attention |
| User message or `task_started` | `working`, clear superseded attention |
| Tool call starts | `working`; never attention by itself |
| Tool result succeeds | Keep the active turn state; never infer approval from latency |
| Assistant `end_turn` or successful `task_complete` | `ready`, no attention |
| Explicit provider input/elicitation request | `blocked` + `attention=input` |
| Explicit provider permission request | `blocked` + `attention=approval` |
| Provider/TUI interruption (`turn_aborted`, `[Request interrupted by user]`, or an equivalent terminal observation) | `ready`, `turn.interrupted`, no attention |
| Host cancel/steer confirmed by the matching Provider terminal observation | `ready`, `turn.cancelled`, `causedBy=<commandId>` |
| Raw TUI interrupt byte without a terminal Provider observation | Keep the current state; do not infer a transition |
| No progress beyond the configured grace period | `stalled` + `attention=warning/stalled` |
| Provider/API/tool terminal error | `failed`, no attention |
| `SessionEnd` | `exited`, no attention |

Natural-language heuristics are explicitly forbidden. A question mark at the
end of an Assistant message, a tool call that takes five seconds, or a missing
transcript update does not prove that a person is being asked to act.

## Stall policy

Stalled is a warning, not a claim that the provider is waiting for approval.
The first implementation must follow these rules:

1. There is no universal five-second input timeout.
2. The grace period is configurable and must be at least 30 seconds by
   default. Provider or tool classes may extend it for known long-running work.
3. A stall requires both an outstanding operation and no transcript or PTY
   progress for the full grace period.
4. The warning is cleared immediately by any progress signal or terminal
   lifecycle boundary.
5. The UI copy must say `No progress detected` or equivalent; it must not say
   `Needs input` unless an explicit input observation exists.

The grace period is a liveness warning and may be tuned with telemetry. It is
not part of the semantic meaning of `input` or `approval`.

## Provider requirements

### Claude

The Warren-managed Claude hook should consume a stable `PermissionRequest`
event (and a documented input/elicitation event when available) and emit a
normalized attention observation. Resolution is observed through the matching
provider hook or a subsequent user turn/tool result. The hook must never
approve or deny on Warren's behalf merely to report status.

### Codex

Codex attention is emitted only when the installed version exposes a stable,
machine-readable approval or input event. `turn_aborted` is a lifecycle
observation, not an approval signal. If no such Codex event exists, Warren
must not synthesize `approval` from a pending tool call. A future PTY prompt
detector may emit `warning`, but it must not claim `approval` without a
provider-confirmed request.

The Codex TUI may produce the same `turn_aborted` observation after a user
Escape/Ctrl-C as the Host's PTY fallback. The adapter handles the observation;
it does not inspect the raw key or attempt to distinguish those origins. The
Host emits `turn.interrupted` unless an accepted cancel/steer request for the
same turn is still pending, in which case it emits `turn.cancelled` with the
command correlation.

### OpenCode

The current OpenCode release stores sessions, messages, and parts in
`opencode.db`. Warren opens that database read-only, binds one provider session
ID to one Warren Session, and maps message `finish` values to terminal turn
boundaries. Mutable text and reasoning parts are emitted as append-only event
deltas with a stable part ID; clients use the `contentDelta` marker to merge
those updates for display. Legacy OpenCode storage formats and resume/fork
flags are outside this contract.

OpenCode's `session.idle` hook is a valid turn boundary for both a TUI
interrupt and a Host cancellation. An interrupted tool result alone is not a
turn boundary; the adapter must wait for `session.idle` or another explicit
terminal observation.

### Other TUI providers

Pi, Qoder, and Antigravity follow the same three-plane contract. Pi's
`stopReason=aborted` is a confirmed abort. Qoder must not map a missing or
provider-unknown stop reason to `ready`; without a terminal observation the
Host keeps the prior state. Antigravity's Stop hook is a valid boundary, but a
raw PTY key by itself is not.

### Hooks and privacy

Hooks report event type, Warren Session ID, provider conversation ID, request
or call ID, and timestamps only. They do not upload transcript content or
secrets. Hook configuration merging remains idempotent and preserves user
entries, but the hook is an observation source rather than a second status
authority.

## Host protocol

The old `agent.activity` message and `waitingForInput` value are replaced by a
versioned status message:

```json
{
  "t": "agent.status",
  "session": "session-123",
  "epoch": 7,
  "status": {
    "activity": "blocked",
    "attention": {
      "kind": "approval",
      "reason": "permission",
      "requestId": "call-42",
      "since": "2026-08-22T10:00:00Z"
    }
  }
}
```

The same `status` object is included in roster snapshots under
`agentStatus`. Status is Host-owned in-memory projection data and is not part
of the durable Session record. A daemon restart starts a new `epoch`; clients
discard the old status and accept the new snapshot.

The event/history stream remains responsible for normalized conversation
events. Clients must not reconstruct `AgentStatus` from that stream. Status
updates are complete snapshots, not patches, so a dropped update can be
recovered by the next roster or subscription snapshot.

## Testing and acceptance

The implementation is complete only when all of the following hold:

1. A known Codex, Claude, OpenCode, or Pi user interruption returns to green
   `ready` and emits `turn.interrupted` when no Host request is pending.
2. A Host cancel/steer receipt does not change `working`; only its matching
   Provider terminal observation emits `turn.cancelled` with `causedBy`.
3. A five-second pending tool remains amber `working`.
4. A long no-progress operation becomes yellow `stalled` only after the
   configured grace period and carries the `stalled` reason.
5. Explicit input and permission events become yellow `blocked` with the
   correct reason and request ID.
6. Matching resolution, cancellation, a new superseding turn, and
   `SessionEnd` clear attention deterministically.
7. Provider errors remain red and are never downgraded to yellow.
8. Web, Desktop, workspace aggregation, accessibility labels, and CLI output
   consume the same status object.
9. Tests cover TUI raw input versus Host cancel, out-of-order provider events,
   duplicate hook delivery, daemon epoch changes, missing transcripts, and
   concurrent Sessions.
10. No test depends on assistant punctuation, a hard-coded five-second timeout,
   or a provider-specific string outside its adapter.

## Implementation guide

The current code areas are useful starting points but are not authorities for
the new contract:

- `Headless/internal/agent/activity.go`: replace the single tracker with a
  reducer over normalized observations;
- `Headless/internal/agent/transcript.go`: keep parsing/content projection
  separate from attention and liveness observations;
- `Headless/internal/api/types.go`: add `AgentStatus`, remove
  `waitingForInput`, and define the `agent.status` wire envelope;
- `Headless/internal/server/`: store and broadcast complete status snapshots;
- Web, Desktop, and CLI renderers: consume `agentStatus` and the generic
  attention label, never infer status from event text.

Implement the reducer and protocol first, then update provider adapters and
clients in the same release. Do not add a compatibility branch for the old
`waitingForInput` heuristic.
