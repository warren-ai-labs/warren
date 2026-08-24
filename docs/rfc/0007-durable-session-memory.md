# RFC 0007: Durable Session memory after Host restart

- Status: Accepted
- Owner: Warren Headless, Web, Desktop, and CLI clients
- Created: 2026-08-24
- Scope: ended Session history, terminal checkpoints, and Agent continuation

## Summary

Warren will preserve a bounded, inspectable Session memory after the operating
system or terminal Runtime exits. A process is allowed to die; its Warren
Session record, last terminal checkpoint, launch context, and Agent
conversation binding remain available until the user explicitly removes the
Session.

Runtime lifecycle and recovery capability are separate dimensions:

```text
Runtime lifecycle: running -> ended
Session memory:     unavailable | inspectable | resumable
```

An ended Session with durable memory remains visible as a stopped Tab. Opening
it never creates a process and never sends input. The client renders a
read-only terminal checkpoint or Agent transcript together with the reason the
Runtime ended and the safe actions available for that Session.

Codex and Claude continuations are generated from a structured Agent launch
specification and the provider conversation ID. Warren never derives a resume
command by editing the old shell command. Resuming creates a new Warren
Session linked to the ended Session; it does not mutate history into a new
Runtime generation.

## Motivation

Warren already persists Session records, launch commands, raw PTY spools,
output cursors, Agent conversation IDs, and transcript paths. Those records
survive a machine restart. The current lifecycle reconciliation nevertheless
marks every Session whose Runtime is missing as `ended`, while Desktop and Web
only create Tabs for `running` Sessions. The useful durable state therefore
exists but is not presented or served.

Raw PTY output alone is not a terminal image. Replaying an arbitrary suffix can
start in the middle of an ANSI sequence, omit required mode and color state,
or reproduce an alternate-screen application incorrectly. A bounded rendered
checkpoint is required for predictable inspection after the Runtime has gone.

The feature must satisfy three user needs:

1. preserve enough of the last terminal surface to recover visual context;
2. show what Warren launched and the last observed process and directory;
3. make a bound Codex or Claude conversation quick to continue without
   automatically re-running arbitrary shell commands.

## Goals

- Keep recoverable ended Sessions visible in their original Workspace or
  Terminal Group.
- Render a bounded, read-only terminal checkpoint without a live Runtime.
- Read an ended Agent's transcript directly from its persisted JSONL file.
- Generate provider-correct, shell-escaped Codex and Claude resume commands.
- Resume an Agent through one typed Host operation that creates a new Session.
- Preserve explicit deletion as the authority that removes Session memory.
- Keep capture, compression, and persistence work outside the PTY output hot
  path.
- Ship one coherent protocol and behavior across Headless, Web, Desktop, and
  CLI.

## Non-goals

- Preserving processes, PTY file descriptors, or in-memory terminal emulators
  across an operating-system restart.
- Automatically re-running a shell or custom Session's old command.
- Inferring the last interactive shell command from terminal output.
- Treating a transcript path, cwd, title, timestamp, or process name as a
  provider conversation identity.
- Restoring an exact scroll position, selection, input draft, or alternate
  screen after the Runtime has exited.
- Uploading terminal checkpoints or transcripts to the Relay.

## Domain model

### Runtime lifecycle

`Session.lifecycle` remains `running` or `ended`. Recovery is deliberately not
a lifecycle value. A Runtime can be ended while its Session remains
inspectable or resumable.

An ended Session records one stable reason:

| `endReason` | Meaning |
| --- | --- |
| `runtimeMissing` | Reconciliation could no longer find the recorded Runtime. |
| `runtimeExited` | The Runtime reported a normal or observed exit. |
| `hostRestart` | A Host boot boundary proves that the previous Runtime generation cannot survive. |
| `unknown` | The Host cannot distinguish the cause. |

The first implementation may use `runtimeMissing` when a reliable boot
identifier is unavailable. It must not guess `hostRestart` from a timestamp.
Explicit Session deletion still removes the Session instead of recording an
end reason.

### Session memory

The Host projects one recovery value for every Session:

```go
type SessionRecovery struct {
    Capability string              `json:"capability"` // unavailable, inspectable, resumable
    Checkpoint *TerminalCheckpoint `json:"checkpoint,omitempty"`
    Agent      *AgentRecovery      `json:"agent,omitempty"`
}

type TerminalCheckpoint struct {
    Format     string    `json:"format"` // ansi-snapshot-v1
    CapturedAt time.Time `json:"capturedAt"`
    Columns    int       `json:"columns"`
    Rows       int       `json:"rows"`
    Epoch      uint64    `json:"epoch"`
    Sequence   uint64    `json:"sequence"`
    Size       int64     `json:"size"`
    SHA256     string    `json:"sha256"`
}

type AgentRecovery struct {
    Provider       string `json:"provider"`
    ConversationID string `json:"conversationId"`
    Transcript     bool   `json:"transcript"`
    ResumeCommand  string `json:"resumeCommand,omitempty"`
}
```

`Capability` is a Host projection, not an independently mutable field:

- `resumable` requires a supported provider, a validated Agent launch spec,
  and a bound provider conversation ID;
- `inspectable` requires a valid terminal checkpoint or readable transcript;
- otherwise the value is `unavailable`.

### Persisted Session fields

The state store adds the following durable fields:

```go
EndReason             string           `json:"endReason,omitempty"`
LastObservedProcess   string           `json:"lastObservedProcess,omitempty"`
LastObservedDirectory string           `json:"lastObservedDirectory,omitempty"`
AgentLaunch           *AgentLaunchSpec `json:"agentLaunch,omitempty"`
ResumedFromSessionID  string           `json:"resumedFromSessionId,omitempty"`
```

`LastObservedProcess` is the foreground executable name, not a reconstructed
shell command. `LastObservedDirectory` is sampled from the Runtime metadata
provider. The Host persists both when it writes a checkpoint, avoiding writes
on every metadata polling interval.

### Agent launch specification

Agent creation persists structured execution intent before any initial prompt
or provider session flag is appended:

```go
type AgentLaunchSpec struct {
    Provider   string   `json:"provider"`
    Executable string   `json:"executable"`
    BaseArgs   []string `json:"baseArgs,omitempty"`
}
```

`Executable` may be a user-selected command such as `codex-opgo`.
`BaseArgs` contains only validated reusable options. It never contains:

- an initial prompt;
- Codex's `resume` subcommand or conversation argument;
- Claude's `--resume`, `-r`, or `--session-id` option;
- shell operators, substitutions, redirections, or environment assignments;
- provider print or non-interactive mode.

The Host owns provider adapters that turn this structure plus the persisted
conversation ID into an argv and a display command. Clients never assemble a
resume command.

Default display commands are equivalent to:

```sh
codex resume <conversation-id>
claude --resume <conversation-id>
```

Every display argument is shell-escaped. Resume command text is presentation
data only; the typed resume operation executes the structured argv directly.

### Resume lineage

Resuming does not revive an ended Warren Session. The Host atomically creates a
new Session with:

- a new Warren Session ID and Runtime binding;
- the same Session scope, effective title, Agent launch spec, and provider
  conversation ID;
- `resumedFromSessionId` pointing to the ended Session;
- a provider-specific resume argv with no initial prompt.

The old Session remains immutable history. A conversation may therefore be
referenced by several ended Warren Sessions and at most one running Session.
The Host rejects a resume when another running Session already owns the same
provider conversation ID.

## State schema and storage

The persisted state schema advances from version 1 to version 2. `store.Open`
must migrate version 1 atomically, preserving all existing resources and
leaving new fields empty. An older binary must reject schema 2 instead of
opening and later erasing fields it does not understand.

Checkpoint files use the Warren Session ID, not the Runtime name:

```text
~/.warren/history/<session-id>/terminal.ansi
```

The path is derived by the Host and is never accepted from a client. Each file
is regular, non-symlinked, mode `0600`, and committed by writing a sibling
temporary file followed by an atomic rename. The state record is updated only
after the checkpoint file is durable. A file without matching metadata is an
uncommitted artifact and may be removed during reconciliation.

Checkpoint payload is bounded to 2 MiB and at most the most recent 2,000
rendered lines. Runtime adapters should capture within those bounds instead of
truncating arbitrary ANSI bytes after capture. If an adapter cannot provide a
bounded rendered snapshot, the Host may store its already-resetting snapshot
only when it fits the byte limit.

The existing raw spool remains the live recovery stream. It is not renamed or
made the authority for ended Session presentation. If no checkpoint exists,
the Host may replay a complete, bounded spool segment from byte zero as a
best-effort fallback and must report that fallback in recovery metadata. It
must never feed an arbitrary byte suffix to a fresh terminal renderer.

Explicit Session, Workspace, or Terminal Group removal deletes the associated
checkpoint, spool, archives, hook binding, and Warren-owned recovery metadata.
Ended Session memory has no automatic TTL in the first implementation.

## Checkpoint coordinator

Headless owns one checkpoint coordinator. Output recording only marks a
Session dirty and wakes the coordinator; it performs no capture or filesystem
write while holding the output Session mutex or broadcast lock.

For every dirty running Session, the coordinator captures:

- two seconds after output becomes quiet;
- at most once every thirty seconds during continuous output;
- on graceful Host shutdown when the Runtime still answers within the normal
  command timeout;
- immediately before an observed Runtime shutdown when the adapter provides a
  pre-exit notification.

Capture failure keeps the previous valid checkpoint. Failure never ends a
Session, blocks input, or closes a client. Capturing one Session is independent
of every other Session. A permanently slow Runtime is bounded by the existing
command timeout and cannot accumulate concurrent capture jobs.

When reconciliation observes a missing Runtime, it first preserves the current
checkpoint metadata and last sampled process/directory, then records
`lifecycle=ended` and `endReason`. It does not remove the spool, transcript,
Agent binding, or checkpoint.

## Host protocol

Roster Session objects include the durable fields and the computed `recovery`
projection. The protocol adds three typed operations.

### `session.history`

Request:

```json
{"session":"<warren-session-id>"}
```

Response:

```json
{
  "session": "<warren-session-id>",
  "lifecycle": "ended",
  "endReason": "runtimeMissing",
  "checkpoint": {
    "format": "ansi-snapshot-v1",
    "capturedAt": "2026-08-24T08:42:00Z",
    "columns": 120,
    "rows": 36,
    "epoch": 3,
    "sequence": 48121
  },
  "payload": "<base64 ANSI bytes>",
  "bestEffort": false
}
```

The operation accepts running or ended Sessions and never creates an output
subscription, Attachment, Input Lease, or viewport owner. The response uses
the existing binary output envelope when practical; JSON base64 above defines
the semantic payload, not a required transport encoding.

### `agent.history`

For an ended Session, paginated Agent history reads the persisted transcript
path on demand with the existing safe transcript reader. It does not start a
watcher and does not require a live Runtime. Missing, malformed, symlinked, or
unsupported transcripts produce an inspectable error without hiding the
Session or falling back to cwd and mtime inference.

### `session.resume`

Request:

```json
{"session":"<ended-warren-session-id>","requestId":"<uuid>"}
```

The Host validates lifecycle, recovery capability, Session scope, workspace or
group existence, provider binding uniqueness, executable launch spec, and
request idempotency. It then creates and returns the new Session. Failure
leaves the ended Session unchanged and removes any partially created Runtime.

CLI surfaces are:

```text
warren session history SESSION_ID
warren agent resume AGENT_ID [--wait] [--timeout DURATION]
```

`agent resume` prints the old and new Warren Session IDs, the provider
conversation ID, and the effective resume command. `session list --ended` and
`agent list --ended` include recovery capability and end reason.

## Client behavior

### Tabs and navigation

Desktop and Web retain an ended Session as a stopped Tab when its recovery
capability is `inspectable` or `resumable`. Stopped Tabs keep their original
scope, order, pin, title, and navigation memory. They use a gray stopped state
and never contribute `working`, attention, or failure activity to Workspace
status aggregation.

An ended Session with `unavailable` recovery is listed in history and CLI
rosters but does not have to remain an open Tab.

### Read-only presentation

Opening a stopped terminal Tab:

1. clears the renderer;
2. requests `session.history`;
3. fits the terminal to the saved columns and rows when possible;
4. writes the resetting ANSI checkpoint once;
5. disables terminal input, focus claims, resize messages, and Attachments;
6. displays a persistent `Stopped` banner with capture time and end reason.

Loading, missing, corrupt, and oversized checkpoints have explicit states and
a Retry action. Keyboard navigation, screen-reader labels, mobile layout, and
copy selection continue to work. A stopped terminal cannot appear connected
or accept invisible input.

An ended Agent Tab defaults to the structured Agent view when its transcript
is readable. The terminal checkpoint remains available through the normal
Terminal toggle. Transcript errors do not remove the terminal fallback.

### Actions

A resumable Agent shows `Resume`, `Copy resume command`, and `Remove`.
`Resume` calls `session.resume`; it never sends the displayed command as PTY
text. On success the client replaces the selected stopped Tab with the new
running Session while preserving the old record in history.

A shell or custom Session shows `New shell`, `Copy launch command` when one was
recorded, and `Remove`. It never offers automatic `Run again` in this RFC.

User-facing labels, documentation, and accessibility text are English.

## Security and privacy

- Checkpoints and transcripts remain Host-local and are never stored by the
  Relay.
- History operations require the same authenticated Host connection as live
  Session operations.
- Clients cannot supply checkpoint or transcript filesystem paths.
- Resume generation uses structured argv and a provider adapter; it never
  evaluates a stored shell string.
- Initial prompts, terminal input, raw transcript content, command arguments,
  and credentials never enter lifecycle or diagnostic logs.
- The launch command already persisted by legacy Sessions may contain an
  initial prompt. It may be shown only to an authenticated local/remote client
  with normal Session access and must not be reused as a resume source.
- Provider conversation IDs are identifiers, not Warren Session IDs. Every API
  and UI label keeps the distinction explicit.

## Performance and failure isolation

- PTY output recording performs an in-memory dirty transition only; it does
  not wait for capture, hashing, JSON persistence, or filesystem I/O.
- One Session has at most one active checkpoint capture.
- Global capture concurrency is bounded so many busy Sessions cannot saturate
  CPU, disk, or runtime RPC capacity.
- Checkpoint writes do not increase roster broadcast frequency while only the
  payload changes; roster metadata updates after a successful checkpoint.
- History payloads are bounded and are not inserted into ordinary roster
  snapshots.
- Agent history remains paginated and reads only the requested transcript
  projection.
- A missing or corrupt recovery artifact affects only that Session.

## Compatibility and migration

Version 1 Sessions migrate with no recovery metadata. Running Sessions begin
producing checkpoints after the upgraded Host adopts them. Ended legacy
Sessions become inspectable only when a safe transcript or complete bounded
spool fallback exists. No migration guesses a provider conversation ID.

Host, CLI, Web, and Desktop ship this protocol change together. A client that
does not understand stopped Tabs may continue to filter ended Sessions; it
must not attempt a live attach to them.

## Review requirements

- **Business intrusiveness:** no arbitrary command is executed automatically;
  explicit delete remains the only destructive cleanup authority.
- **Interaction impact:** stopped loading, ready, empty, corrupt, retry,
  resume-conflict, keyboard, accessibility, and responsive states are covered.
- **Performance impact:** checkpoint scheduling and capture concurrency are
  measured with continuous-output Sessions and many idle Sessions.
- **Out-of-the-box usability:** a fresh install uses the existing Runtime
  adapter and Host data directory with no shell plugin, extra daemon, or hidden
  credential requirement.
- **Functional coupling:** Runtime adapters capture bounded snapshots,
  provider adapters build resumes, the Host owns persistence and lifecycle,
  and clients only render projections and issue typed intents.

## Acceptance criteria

1. Simulating a Host restart with a missing Runtime changes a running Session
   to ended without deleting its checkpoint, spool, transcript, or binding.
2. Desktop and Web show a recoverable ended Session in its original context
   and render its checkpoint without creating an Attachment or accepting
   input.
3. A hard stop after at least one successful periodic checkpoint restores the
   last committed checkpoint; an interrupted checkpoint write leaves the
   previous checkpoint valid.
4. Continuous terminal output does not cause more than one capture every
   thirty seconds and does not measurably block input or output broadcast.
5. Ended Codex and Claude history is pageable directly from the persisted
   transcript after a daemon restart.
6. Resume preserves the configured executable and reusable options, excludes
   the old initial prompt and continuation flags, and shell-escapes the
   displayed command.
7. Resuming creates a new linked Warren Session and rejects a second running
   owner of the same provider conversation.
8. Shell and custom Sessions never execute the old command automatically.
9. Explicit Session, Workspace, and Terminal Group removal cleans up the
   corresponding Warren-owned history artifacts.
10. Schema 1 migrates atomically to schema 2; a failed migration leaves the
    original state file usable.
11. Go, Web, and Swift tests cover normal, empty, missing, corrupt, oversized,
    conflict, cancellation, and cleanup paths.
12. Existing live attach, output recovery, Agent send/read/wait, Session move,
    and explicit deletion behavior remains unchanged for running Sessions.
