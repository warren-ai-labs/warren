# RFC 0023: ACP Agent Sessions and the attention-first Conversation surface

- Status: Implemented (phases 1–6)
- Owner: Warren Headless, Desktop, Web, iOS, and CLI
- Created: 2026-09-28
- Scope: a second Agent driver that speaks the Agent Client Protocol, a Session
  that has no PTY, and one Conversation surface shared by every client
- Protocol baseline: Warren protocol 4.0 and the canonical Agent protocol of
  [RFC 0016](0016-canonical-agent-execution-protocol.md)
- Depends on: [RFC 0006](0006-agent-activity-attention.md) (activity and
  attention), [RFC 0016](0016-canonical-agent-execution-protocol.md) (canonical
  execution protocol), [RFC 0020](0020-host-owned-pane-groups.md) (pane
  leaves name Sessions)
- Supersedes: the "Track 2" sketch in
  [RFC 0013](0013-agent-interaction-architecture-and-pty-guarding.md) §3.1

"ACP" in this document is the **Agent Client Protocol**
(<https://agentclientprotocol.com>), the JSON-RPC protocol spoken by Zed and by
the Claude, Codex, and OpenCode ACP adapters. It is not IBM's Agent
Communication Protocol.

---

## 1. Summary

Warren drives every Agent today through its terminal. The Host starts the
provider's TUI in a Ghostline PTY, tails the provider's private transcript file
to build the Agent View, and writes prompts, approvals, and interrupts back as
keystrokes. That design keeps the native TUI, but every structured feature is
reverse-engineered: each provider needs its own transcript parser, binding
hooks, prompt-shape heuristics, and PTY write guards, and each provider release
can silently break one of them.

ACP removes the reverse engineering. An ACP agent is a subprocess that speaks
JSON-RPC 2.0 over stdio. The client sends `session/prompt`; the agent streams
`session/update` notifications (message chunks, reasoning chunks, tool calls,
plans), asks `session/request_permission` when it needs a decision, and answers
the prompt with an explicit `stopReason`. Every fact Warren currently infers is
delivered as data.

This RFC makes ACP a first-class Agent driver **beside** the TUI driver, not a
replacement for it:

1. **One provider, two handlers.** `claude`, `codex`, and `opencode` can each be
   started as a TUI Session (unchanged) or as an ACP Session. The handler is
   chosen at creation and is fixed for the life of the Session.
2. **An ACP Session has no PTY.** Warren Headless is the ACP client. The agent
   process is a child of the Host, its conversation is the Session's canonical
   event stream, and the Session survives process and Host restarts through
   `session/resume` or `session/load`.
3. **No new client event format.** The ACP driver emits the same canonical
   events RFC 0016 already journals and replays. A client that renders a TUI
   Agent View can render an ACP Session with no protocol change.
4. **One Conversation surface, designed for attention.** Desktop gains its
   first structured Agent surface. Desktop, Web, and iOS render ACP Sessions
   with one shared presentation contract (§9) whose single goal is to spend the
   user's attention only on what needs them.

## 2. Motivation

### 2.1 What the TUI track costs

| Capability | TUI driver today | Source of truth |
| --- | --- | --- |
| Conversation timeline | Tail and parse a provider-private JSONL or SQLite file | Undocumented file format per provider |
| Session binding | Lifecycle hooks write `~/.warren/agent-bind/*` | Hook scripts installed into each CLI |
| Turn boundaries | Heuristics per provider (`Stop`, `turn_aborted`, idle) | Transcript rows and hook state files |
| Approvals | Detect a prompt, then type the key the TUI expects | Screen and transcript shape |
| Prompt submission | Bracketed paste plus a separate Enter | Terminal line discipline |
| Interrupt | `Ctrl-C` byte | TUI keymap |

Six providers times these rows is most of `Headless/internal/agent` and much of
`agent_view.go`. Every row is a place where a CLI update can make Warren show
the wrong state without an error.

### 2.2 What ACP gives instead

| Capability | ACP |
| --- | --- |
| Timeline | `session/update`: `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan` |
| Binding | The `sessionId` returned by `session/new` |
| Turn boundaries | The `session/prompt` response and its `stopReason` |
| Approvals | `session/request_permission`, answered with an `optionId` |
| Prompt submission | `session/prompt` with typed content blocks |
| Interrupt | `session/cancel`, confirmed by `stopReason: "cancelled"` |
| Resume | `session/resume` (no replay) or `session/load` (replay) |

The TUI track remains the right tool when the user wants the provider's own
terminal UI: slash commands, its keymap, its rendering. ACP is the right tool
when the user wants a conversation: remote use from a phone, reading work
instead of watching a terminal, answering approvals from anywhere. Warren
offers both because they serve different moments of the same work, and
[DESIGN.md](../../DESIGN.md) §8 already names both tracks.

### 2.3 Why this changes the whole app

Until now every Session tab on Desktop is a terminal, and the Agent View exists
only on Web and iOS as an alternate projection of a terminal. An ACP Session
has no terminal to fall back to, so Desktop needs a structured surface of its
own, and every client needs a Session kind whose primary surface is a
conversation. That is a new kind of pane, a new creation choice, and a new
default for how Agents appear on every client.

## 3. Goals and non-goals

### 3.1 Goals

- Run Claude Code, Codex, and OpenCode as ACP Sessions on any Host.
- Keep the TUI handler for the same providers, unchanged, side by side.
- Reuse the RFC 0016 journal, replay, cursor, command, and capability contract.
- Survive client disconnect, app quit, agent crash, and Host restart without
  losing the conversation.
- Answer approvals and questions from Desktop, Web, and iOS through the native
  ACP channel, never through keystrokes.
- Give Desktop a Conversation surface, and give all three clients one shared
  presentation contract for it.

### 3.2 Non-goals

- Converting an existing TUI Session to ACP in place, or the reverse. A Session
  has one handler for its whole life; §6.12 replaces a chat with a terminal
  Session instead.
- Implementing ACP for Pi, Qoder, or Antigravity. None of them ships an ACP
  server; their Sessions stay TUI-only.
- Acting as an ACP **agent**. Warren is only an ACP client here.
- Offering the ACP file-system client capability (§6.6).
- Changing the TUI Agent View. It keeps its current presentation; adopting the
  Conversation surface for TUI Sessions is a separate decision.
- In-app provider login. An agent that needs authentication tells the user to
  log in with the provider's own CLI (§6.9).

## 4. Domain model

### 4.1 Terms

- **ACP Session**: a Warren Session whose `agentHandler` is `acp`. It belongs to
  one Session Scope, appears as a Tab and a pane leaf, and has an Agent
  Execution like any Agent Session. It owns no Ghostline runtime.
- **ACP agent process**: the subprocess that serves ACP on stdio. It is a
  disposable worker of the ACP Session, not the Session itself.
- **ACP session ID**: the agent's `sessionId`. It is provider conversation
  metadata, stored in `Session.agentSessionId`, and never used as a client key.

These terms are added to [GLOSSARY.md](../../GLOSSARY.md).

### 4.2 Session record

An ACP Session is recorded with:

| Field | Value |
| --- | --- |
| `kind` | the provider family: `claude`, `codex`, or `opencode` |
| `agentProvider` | the same family |
| `agentHandler` | `acp` |
| `runtimeKind` | `acp` |
| `runtime` | empty; there is no Ghostline runtime |
| `command` | the ACP server command line that was launched |
| `agentSessionId` | the ACP `sessionId`, once `session/new` returns |
| `agentExecutionId` | the Host execution and stream ID (RFC 0016) |

`runtimeKind = "acp"` makes the Session self-describing: every Host path that
assumes a Ghostline runtime (output streams, resize, metadata probe, runtime
reconciliation, terminal subscribe) branches on it exactly the way it already
branches on `browser`.

### 4.3 Identity across restarts

    Warren Session (durable, one handler)
      '- Agent Execution (stream of canonical events)
            '- ACP session ID (provider conversation)
                  '- ACP agent process (disposable)

The Session and the execution outlive the process. When a process is replaced
and the agent resumes the same ACP session ID, the execution continues: same
stream, next sequence. When the agent cannot resume and a new ACP session ID is
created, that is a new provider conversation, so the Host starts a new
execution exactly as RFC 0016 §3 requires for `/new`.

## 5. Host architecture

### 5.1 Components

    Service.createSession(handler = acp)
        |
        v
    ACPAgentProvider.Ensure  ---->  acpAgentHandle
                                        |  owns
                                        v
                                   acp.Conn (JSON-RPC 2.0, NDJSON over stdio)
                                        |
                                        v
                                   agent process (login shell, workspace cwd)

- `Headless/internal/acp` is a new package: the JSON-RPC connection, the ACP
  wire types Warren uses, and the process launcher. It knows nothing about
  Warren Sessions.
- `acpAgentHandle` in `Headless/internal/server` implements the existing
  `AgentHandle` contract (`Start`, `SendMessage`, `Interrupt`,
  `RespondInteraction`, `BindingKey`, `Close`). It translates ACP into the
  `api.AgentEvent` observations the Host already normalizes, journals, and
  broadcasts.

No other Host layer learns about ACP. The journal, the replay path, command
admission, idempotency, stale-interaction checks, attention projection, title
generation, and roster projection are reused unchanged.

### 5.2 Process launch

The agent is launched through the user's login shell, in the Session's working
directory, exactly as a TUI Session's shell would see the world:

    $SHELL -il -c 'printf "\n%s\n" <sentinel>; exec <command> <&3 3<&-'

- **Environment.** A login interactive shell loads the same startup files a
  terminal Session loads, so `PATH`, version managers, and provider API keys
  match what the user has in a terminal. The Host's own `RuntimeEnv` settings
  are applied as they are for PTYs.
- **Protected stdin.** The shell's own stdin is `/dev/null`; the agent's stdin
  is a pipe passed as fd 3 and moved into place by the `exec`. A startup file
  that reads input — or that `exec`s another interactive shell, a common
  `.zshrc` idiom — can never consume protocol messages.
- **Sentinel.** Startup files may print to stdout. The launcher discards stdout
  until it reads the per-launch random sentinel line, so a greeting in
  `.zshrc` can never corrupt the JSON-RPC stream.
- **Fallback.** When the interactive shell ends or stalls (10 s) before the
  sentinel, the launcher retries once with a non-interactive login shell
  (`-l`). The PATH check for a default adapter uses the same two steps.
- **No binding environment.** ACP processes do not receive
  `WARREN_SESSION_ID` or the hook binding variables. The ACP stream is the only
  source of truth for this Session; a provider hook writing a TUI state file for
  it would create a second, conflicting authority.
- **Process group.** The shell runs in its own process group. Closing the
  Session signals the group (`SIGTERM`, then `SIGKILL` after a grace period),
  so the adapter and anything it spawned end together.
- **stderr.** Kept in a bounded in-memory tail (last 64 KiB) and logged only on
  abnormal exit, never broadcast, never journaled.

### 5.3 Provider commands

| Provider | Default ACP command | Adapter |
| --- | --- | --- |
| `claude` | `claude-agent-acp` | `@agentclientprotocol/claude-agent-acp` |
| `codex` | `codex-acp` | `@zed-industries/codex-acp` |
| `opencode` | `opencode acp` | built into OpenCode |

`--command` (CLI) or the request's `command` overrides the default and is
validated with the same rule as TUI commands: no shell operators, no command
substitution. Warren does not download adapters on the user's behalf. When the
default executable is not on the login shell's `PATH`, creation fails with a
message that names the package to install. An implicit `npx -y` would run
network-fetched code the user did not choose.

Creating an ACP Session for a provider without an entry in this table fails
with `acp is not available for provider <kind>`.

### 5.4 Connection lifecycle

    start process
      -> initialize { protocolVersion: 1, clientCapabilities, clientInfo }
      -> if agentSessionId is empty:  session/new { cwd, mcpServers: [] }
         else if sessionCapabilities.resume: session/resume { sessionId, cwd }
         else if agentCapabilities.loadSession: session/load { sessionId, cwd }
         else: session/new, and the Host starts a new execution
      -> ready

- `initialize` is bounded by 30 s, session setup by 60 s. A failure ends the
  attempt with a `turn`-less error event and `activity: failed`.
- `session/load` replays history as `session/update` notifications. The Host
  already holds that history in the journal, so the handle **drops** every
  update received before the `session/load` response. The journal stays the
  authority; replay is never re-journaled.
- Protocol version: Warren sends `1`. An agent that answers with a different
  major version is rejected with a clear error.

### 5.5 Lazy start and restart

The process is started when the Session is created and runs in a **holder**:
`warren-headless --acp-hold`, a detached process in its own session that owns
the agent's stdio and serves it on a Unix socket named after the Session, the
way Ghostline owns a PTY. The Host speaks ACP through the socket. The holder
forwards lines unchanged but tracks their ids: the Host requests the agent has
not answered, and the agent requests the Host has not answered. Agent output
that arrives while no Host is attached is queued. The Host stores its
`initialize` answer and the current selectors in the holder.

- **Host restart.** Shutdown detaches: the holder stops forwarding, the Host
  journals what it already received, and the agent keeps running. On the next
  `Start` the Host attaches again without `initialize` or `session/resume`. When
  the journal's open turn is a `session/prompt` the agent is still answering,
  the turn is adopted: it stays `started`, queued output is journaled, and the
  agent's answer finishes it. Agent requests the previous Host never answered
  are delivered again under the same interaction ID. Text streamed after the
  restart is journaled under new message IDs, so it never replaces what was
  shown before. When no holder answers (the agent exited while the Host was
  away), the process starts on the first command that needs it and resumes the
  conversation (§5.4); a turn left open then fails. A Host crash can lose the
  lines already written to it but not yet journaled; a prompt answer lost that
  way fails its turn.
- **Agent crash.** An unexpected exit while a turn is running ends that turn
  as `failed`, expires every pending interaction, publishes
  `activity: failed`, and journals one error event with the exit status. The
  Session stays `running`. The next prompt starts a new process and resumes the
  same ACP session ID (§5.4).
- **Close.** Deleting the Session tells the holder to end the agent (close
  stdin, signal the process group); an ending holder refuses new attaches.
  The Session is removed exactly like any other.

The conversation is durable, and so is the process across Host restarts; an
agent that exits is never presented as still working.

Terminals the agent created with `terminal/create` are still released when the
Host shuts down, so a command running through one ends with the Host.

### 5.6 Streaming and coalescing

ACP adapters stream text a few tokens at a time. Journaling every chunk would
write thousands of rows per turn and make every client re-render per token. The
handle coalesces:

- Consecutive `agent_message_chunk` updates for one message are buffered and
  flushed as one delta event at most every **120 ms**, and immediately before
  any other update, a permission request, or the end of the turn.
- `agent_thought_chunk` is coalesced the same way.
- A message identity is the ACP `messageId` when the agent sends one. Otherwise
  the handle allocates `acp-<turn>-<n>`, starting a new segment after any
  non-text update, so text before and after a tool call are separate messages.
- Repeated `tool_call_update` notifications that change nothing visible
  (identical status, title, and content) are dropped.

The first flush of a message is a `message.created`; later flushes are
`message.delta` with the same `messageId`; the end of the turn emits
`message.completed`.

## 6. ACP to Warren mapping

### 6.1 Session updates

| ACP `sessionUpdate` | Warren observation | Canonical event |
| --- | --- | --- |
| `agent_message_chunk` | `assistant`, coalesced delta | `message.created` / `message.delta` |
| `agent_thought_chunk` | `reasoning` | `reasoning.delta` |
| `user_message_chunk` | dropped outside `session/load` replay | — |
| `tool_call` | `tool_call` | `tool.started` |
| `tool_call_update` (`pending`, `in_progress`) | `tool_updated` | `tool.updated` |
| `tool_call_update` (`completed`) | `tool_completed` | `tool.completed` |
| `tool_call_update` (`failed`) | `tool_failed` | `tool.failed` |
| `plan` | `plan` | `plan.updated` |
| `available_commands_update` | `commands.updated` | `commands.updated` |
| `current_mode_update`, `config_option_update` | `config` | `config.updated` |
| `usage_update` | `context.updated` | `context.updated` |
| `session_info_update` | ignored; Warren's own title generation names the Session | — |
| anything else | ignored, counted in a debug counter | — |

User messages are not echoed by ACP agents during a live prompt. The handle
emits the user's `message.created` itself when `session/prompt` is sent, with
`causedBy` set to the command ID (`agent-causation-v1`).

### 6.2 Tool calls

| ACP field | Warren payload |
| --- | --- |
| `toolCallId` | `callId` |
| `title` | `toolName` and the display title |
| `kind` | `toolKind`: `read→read`, `edit→edit`, `delete→delete`, `move→move`, `search→grep`, `execute→ran`, `fetch→fetch`, `think→think`, `switch_mode→mode`, `other→tool` |
| `rawInput.command` / first `locations[].path` | `toolDetail` (bounded) |
| `locations[].path` | `files` |
| `content[]` text | `output`, clipped to the existing tool output limit |
| `content[]` `diff` | `diff`: `{ file, additions, deletions, diff }` in the `AgentDiff` shape |
| `rawInput` | `toolInput`, bounded |
| `rawOutput` | not forwarded; it is provider-shaped and duplicates `content` |

### 6.3 Turns

| Host action / ACP result | Turn observation |
| --- | --- |
| `session/prompt` sent | `turn.started` (turn = previous + 1) |
| `stopReason: end_turn` | `turn.completed` |
| `stopReason: max_tokens`, `max_turn_requests` | `turn.completed`, `stopReason` kept in payload |
| `stopReason: refusal` | `turn.failed` |
| `stopReason: cancelled` | `turn.interrupted`, which the Host upgrades to `turn.cancelled` when it matches an accepted cancel/steer (RFC 0016 §6.2) |
| JSON-RPC error or process exit | `turn.failed` plus one error event |

When the prompt response carries `usage`, the handle attaches it to the last
assistant message as `AgentUsage` (`inputTokens`, `outputTokens`,
`cachedReadTokens → cacheReadInputTokens`), so Usage accounting works for ACP
Sessions without reading any transcript.

### 6.4 Status and attention

- `working` from `session/prompt` until its response.
- `ready` after a completed or cancelled turn.
- `failed` after a failed turn or a process exit.
- A pending `session/request_permission` sets `blocked` with
  `attention: { kind: approval, reason: permission, requestId }`. Resolving the
  last pending request returns to `working`.

These are the RFC 0006 values; every existing status mark, notification, and
sidebar rollup works unchanged.

### 6.5 Permissions

`session/request_permission` is a JSON-RPC request from the agent. The handle
keeps it open, and journals an `interaction.requested`. The interaction ID is
derived from the holder's ID and the JSON-RPC ID: a request delivered again
after a Host restart keeps its ID, while a restarted agent, which numbers its
requests from zero again, has a new holder:

    {
      "interactionId": "acp-perm-<holder>-<hash of request id>",
      "kind": "permission",
      "version": 1,
      "title": "<toolCall.title>",
      "toolKind": "<mapped kind>",
      "toolDetail": "<command or path>",
      "diff": { ... },                       // when the tool call carries one
      "options": [
        { "id": "<optionId>", "label": "<name>", "kind": "allow_once" },
        ...
      ],
      "state": "pending"
    }

`agent.interaction.resolve` with `{ "decision": "<optionId>" }` answers the
request with `{ outcome: { outcome: "selected", optionId } }`. The existing
command path validates the option against the request, enforces
first-resolution-wins, and journals `interaction.resolved`.

A `turn.cancel` answers every pending request with
`{ outcome: { outcome: "cancelled" } }`, as the ACP spec requires, and each
becomes `interaction.expired`. A process exit expires them too.

Option kinds are carried to clients so they can order and color choices by
meaning (`allow_*` vs `reject_*`) instead of by label text.

### 6.6 Client capabilities offered to the agent

Warren advertises `fs.readTextFile = false` and `fs.writeTextFile = false`:
the agent reads and writes files with its own tools, exactly as it does in a
terminal. Offering them would make Warren an editor buffer authority, which
it is not.

Warren advertises `terminal = true` when its runtime can run a command as a
PTY's process (Ghostline can). A terminal the agent creates is a **visible
terminal Session**, never a hidden subprocess:

| ACP method | Warren |
| --- | --- |
| `terminal/create` | A `shell` Session in the chat's Workspace or Group, titled with the command line. Its PTY process is the command itself, run through the login shell (`$SHELL -l -c 'exec …'`) so it sees a terminal Session's environment. A command without `args` is evaluated by `/bin/sh -c`, the shell agents write command lines for, whatever the login shell is. The Session is not focused. |
| `terminal/output` | The command's output as plain text: escape sequences dropped, CRLF as LF, a bare CR rewriting its line. Bounded by `outputByteLimit` (default 1 MiB, at most 4 MiB), truncated from the start at a character boundary. |
| `terminal/wait_for_exit` | The process's exit code, or its signal. |
| `terminal/kill` | Ends the process; the Session and its output stay. |
| `terminal/release` | Ends the process if needed and removes the Session. |

- **Why the command is the PTY process.** A terminal Session normally runs an
  interactive shell with the command typed into it. That keeps a usable shell
  after the command, but the agent needs the command's own output and exit
  status, which a typed line inside a shell cannot report without shell
  hooks. The trade is that the Session ends with its command.
- **Lifetime.** The Session is visible while the command runs and ends when it
  exits, like any terminal Session whose process ends. The terminal itself
  lives until the agent releases it, as ACP specifies: the Host keeps its
  output and exit status for the agent after the Session has ended. When the
  agent process exits, or the chat Session is closed or handed off, the Host
  releases every terminal that agent created.
- **Linking.** A tool call whose content is `{ "type": "terminal" }` carries
  `terminalSessionId` in its payload, and clients open that Session from the
  step while it exists. When the tool completes without text content, its `output` is the
  terminal's output, clipped from the start.
- **Adoption.** None of the three shipped adapters calls `terminal/create`
  today: Claude Code and Codex run commands themselves and report them as
  tool calls, and OpenCode only bundles the SDK method. The capability costs
  nothing when unused and serves any agent that does use it.

### 6.7 Prompts and attachments

- Text becomes one `text` content block.
- An image attachment becomes an `image` block (base64) when the agent
  advertises `promptCapabilities.image`; otherwise a `resource_link`.
- Any other attachment becomes a `resource_link` to the Host-stored attachment
  file, which every ACP agent must accept.

The existing attachment upload path (`agent.attachment.*`) is reused.

### 6.8 Commands

| Canonical command | ACP |
| --- | --- |
| `agent.turn.start` | `session/prompt` (rejected with `agent is currently working` while a turn runs) |
| `agent.turn.cancel` | `session/cancel` notification; pending permissions answered `cancelled` |
| `agent.turn.steer` | `session/cancel`, wait for that prompt to return (bounded 10 s), then `session/prompt` |
| `agent.interaction.resolve` | the pending `session/request_permission` response |
| `agent.config.set` | `session/set_config_option`, or `session/set_mode` for a legacy mode (§6.11) |
| `agent.execution.resume` | not supported for ACP in this RFC |
| `agent.goal.*` | not supported; the capability is not advertised |

### 6.9 Errors and authentication

- An ACP JSON-RPC error on `session/new` with code `-32000`
  (`auth_required`) produces the error event
  `"<Agent> needs you to sign in. Run <login hint> in a terminal on this Host, then send your message again."`
  The hint is taken from the agent's `authMethods[].description`.
- Other setup errors surface verbatim in one error event, bounded to 2 KiB.
- A missing adapter executable is a creation error (§5.3), not an event.

### 6.10 Capabilities advertised to clients

An ACP Session advertises `agent-timeline-v1`, `agent-interactions-v1`,
`agent-interrupt-v1`, `agent-attachments-v1`, and `agent-config-v1`. It never
advertises `agent-goals-v1`.

### 6.11 Session selectors: model and mode

Every shipped adapter publishes its selectors as ACP `configOptions` in the
`session/new`, `session/resume`, and `session/load` responses: OpenCode a
model; Codex a mode and a model; Claude Code a mode, a model, a reasoning
effort, and a fast toggle. Older agents publish only the legacy `modes` list.

- **Snapshot.** The handle normalizes both into one list and journals it as a
  `config.updated` event whose payload is the complete set:

      {
        "configId": "acp-config",
        "configOptions": [
          {
            "id": "model", "name": "Model", "category": "model",
            "currentValue": "opus",
            "options": [{ "value": "opus", "name": "Opus", "group": "…" }]
          }
        ]
      }

  A client only ever reads the latest one. Grouped values are flattened, each
  keeping its group name. A legacy mode list becomes a selector with
  `id: "mode"` and `category: "mode"` unless a config option already covers
  that category. The set is bounded to 16 selectors of 500 values.
- **Updates.** `config_option_update` replaces the snapshot and
  `current_mode_update` changes the current value of the mode selector. An
  unchanged snapshot is not journaled again.
- **Changing a selector.** `agent.config.set { configId, value }` is admitted
  like any canonical command and validated against the snapshot. The handle
  sends `session/set_config_option` and journals the agent's answer, which
  replaces the snapshot because one change can alter another selector (a
  model narrows its effort levels). A synthesized mode selector is changed
  with `session/set_mode`. A Session whose agent exited has no process; the
  command starts one first, because the selectors are only known once the
  agent answers. Changes are allowed while a turn runs; the agent decides when
  they take effect.
- **Capability.** `agent-config-v1` is negotiated like the other Agent
  capabilities. A client that has not negotiated it never sees the command.
- **Presentation.** One quiet control in the Conversation header (§9.3), not a
  new rail or toolbar.

### 6.12 Hand-off to a terminal

A conversation that started as a chat can continue in the provider's own TUI.
`session.handoff { id, command? }` replaces the ACP Session with a TUI Session
that resumes the same provider conversation:

| Provider | Terminal command |
| --- | --- |
| `claude` | `claude --resume <sessionId>` |
| `codex` | `codex resume <sessionId>` |
| `opencode` | `opencode --session <sessionId>` |

Each adapter's ACP `sessionId` is the provider's own conversation ID, so the
TUI resumes it directly. `command` is an optional base (a client's terminal
preset, which may carry flags); it must start the provider's executable and
pass the ACP command validation. The conversation ID must match
`[A-Za-z0-9][A-Za-z0-9._-]*` before it is typed into a shell.

**Never two writers.** The Host:

1. Refuses while a turn runs or a decision is pending: stopping is the user's
   call.
2. Marks the Session as moving, so no command can start an agent process for
   it, then closes the agent process and waits until it has exited.
3. Creates the TUI Session in the same Workspace or Group, bound to the
   provider conversation (`agentSessionId`). The provider validators that
   refuse a user-chosen conversation (OpenCode's `--session`) are bypassed
   only here, because Warren owns this conversation.
4. Removes the ACP Session. The TUI Session takes its tab position, its pane
   leaves, and its pin.

If the TUI cannot start, the ACP Session stays and its next prompt resumes the
conversation as after any process exit. The ACP journal is not copied: the
TUI Session's Agent View reads the provider transcript, which holds the whole
conversation. Hand-off is one way; a TUI Session does not become a chat.

## 7. Protocol changes

Phases 1–4 need no new method and no new message type. Phase 5 adds two
methods, both additive: `agent.config.set` under the new `agent-config-v1`
capability (§6.11), and `session.handoff` (§6.12).

1. `session.create` accepts `agentHandler: "acp"` for `claude`, `codex`, and
   `opencode`. The response is the Session record of §4.2.
2. `session.subscribe` on an ACP Session succeeds with no terminal stream, the
   same courtesy a browser Session gets, so a client that subscribes to
   everything it displays does not fail on it.
3. `session.input`, `session.resize`, and raw terminal operations on an ACP
   Session fail with `session has no terminal`.
4. Three canonical event types become explicit (they were already accepted as
   pass-through dotted types): `commands.updated`, `config.updated`, and
   `context.updated`. Clients that do not render them ignore them, as RFC 0016
   §7.3 requires.
5. `protocol/warren.schema.json` documents `agentHandler: "acp"`,
   `runtimeKind: "acp"`, and the three payloads.
6. `agent.events.history` and `agent.events.subscribe` results carry
   `stateEvents`: for `config.updated`, `plan.updated`, `context.updated`, and
   `commands.updated`, the latest event older than the page. A client that
   loads only recent history still knows the Session's selectors, plan, and
   context. Clients merge them into the conversation projection by sequence;
   they do not extend the replica's contiguous range.

The Warren protocol version stays 4.0: every change is additive.

## 8. CLI

    warren agent create [WORKSPACE_ID] --provider claude --agent-handler acp --prompt "…"
    warren agent send AGENT_ID "…"
    warren agent read AGENT_ID
    warren agent wait AGENT_ID

`agent send`, `read`, and `wait` already use the canonical protocol and work
unchanged. `agent attach` and `session attach` on an ACP Session fail with a
message that points to `agent read`.

## 9. The Conversation surface

### 9.1 Principle

An Agent conversation competes for the scarcest thing Warren manages: the
user's attention. The TUI and most chat UIs spend it freely — a spinner per
tool, a card per file read, a wall of streamed tokens, reasoning in full. The
user then has to find the one line that needs them.

The Conversation surface inverts that. **Everything is quiet unless it needs
the user, and exactly one thing at a time is allowed to ask.** It extends the
two rules DESIGN.md §8.2 already states for status marks — motion means
progress, color means a request — to the whole transcript.

### 9.2 Seven rules

1. **One loud place.** A pending decision (permission or question) is shown in
   the **decision dock**, pinned directly above the composer, never only
   inline in the scroll. It is the only element that uses the attention hue.
   The composer is disabled with the reason shown while a decision is pending.
   Multiple pending decisions queue in the dock ("1 of 2").
2. **A turn is the unit.** Each turn renders as: the user's prompt, one
   collapsed **work trail**, and the final answer. The final answer is the
   only full-contrast body text in the turn.
3. **Work is summarized, not narrated.** Consecutive tool calls and the
   assistant's in-between narration fold into one work trail line, for
   example `Read 4 files · Ran 2 commands · Edited 3 files`. Expanding it lists
   one line per step (verb, target, result mark); expanding a step shows its
   output or diff. While the turn runs, the trail is a live `Working for 12s`
   line over a rolling window of at most three step lines; it never grows a
   card per call. When the turn ends, the window **settles**: it folds into
   the one-line summary, `Worked for 1m 12s · Read 4 files · Ran 2 commands`,
   and a hairline separates the work from the answer.
4. **Reasoning is opt-in.** Reasoning collapses to `Thought for 12s` and never
   expands by itself.
5. **Motion only for progress.** The single animated element is a slow,
   stepped highlight sweep across the live `Working for …` line (adapted from
   Synara). It stops while the turn waits on a decision, because waiting is
   not progress, and the status dot is static. The settle when a turn ends is
   a one-time transition of the transcript only; the status line and
   composer never move. No spinners, no typing indicator per message.
   Streamed text is appended in whole-word steps at a steady cadence, never
   per token. Reduced-motion settings remove both.
6. **The reader owns the scroll.** The view follows new output only while the
   user is at the bottom. Once they scroll up, it stays put and a single
   `New activity` pill offers the jump. A pending decision never scrolls the
   view; the dock is already visible.
7. **Facts, not decoration.** No avatars, no emoji, no role labels on every
   message. Errors are one line: what failed, and the action that retries or
   explains it. Completion is a status change, not a toast.

### 9.3 Layout

The surface has no header of its own; the Session's tab names it. Every
control sits in the composer, after Synara's composer.

    ┌───────────────────────────────────────────────────────────┐
    │                                                           │
    │          ╭──────────────────────────────────────────────╮ │
    │          │ Refactor the session reaper to use the clock │ │  user prompt: trailing bubble
    │          ╰──────────────────────────────────────────────╯ │
    │   Worked for 1m 12s · Read 4 files · Ran 2 commands  +42 −7 ›│  work trail: one line, secondary
    │   ─────────────────────────────────────────────────────── │
    │   The reaper now takes a Clock. I moved the two sleeps     │  final answer: body text
    │   into tests/… and the suite passes.                       │
    │   ┌─────────────────────────────────────────────────────┐ │
    │   │ Edited 3 files  +42 −7                              │ │  files card, one row per file
    │   │ Sources/Reaper.swift                       +30 −5 ⌄ │ │
    │   └─────────────────────────────────────────────────────┘ │
    │   ⧉ 14:02                                                  │  copy and time
    │                                                           │
    │ ┌───────────────────────────────────────────────────────┐ │
    │ │ ● Run this command?  git push origin feat/reaper      │ │  decision (only when pending)
    │ └───────────────────────────────────────────────────────┘ │
    │ ╭───────────────────────────────────────────────────────╮ │
    │ │ Plan 3/7 · Update tests                             ⌄ │ │  plan, on the composer's edge
    │ │ Message Claude…                                       │ │
    │ │ ＋  ⛉ Auto ⌄                  ◔ 3%  Opus 5.5 · High ⌄ ● │ │  composer row
    │ ╰───────────────────────────────────────────────────────╯ │
    └───────────────────────────────────────────────────────────┘

- **Timeline.** Readable measure: at most 72ch of body text, centered on wide
  panes. Older turns keep the same structure; nothing is auto-collapsed except
  work trails and reasoning.
- **Prompt.** A compact bubble on the trailing side, so the answers own the
  reading column.
- **Work trail steps.** A step line is `verb target result`: `Ran git status`,
  `Read Sources/…/Reaper.swift`, `Edited 2 files +12 −3`. Paths under the
  Session's directory are relative and a leading `cd <dir> &&` is dropped.
  The result mark is a small dot: neutral for success, attention hue only for
  a failed step. A step backed by an agent terminal (§6.6) offers
  `Open terminal` when its Session still exists.
- **Files card.** `Edited n files +a −d`, then one row per file that opens its
  diff; long lists show the first few and a `Show n more files` row.
- **Answer footer.** Copy and the time the answer landed, in tertiary text.
- **Decision.** A question on the first line (`Run this command?`,
  `Allow this change?`) with the tool title beside it, the diff or command
  preview (bounded, scrollable) when present, then the options, ordered
  `allow_once`, `allow_always`, `reject_once`, `reject_always`. It rests on the
  composer, which is disabled with the reason while it is pending. `⏎` takes
  the default and `Esc` rejects once; `⌘1…4` choose a row on Desktop.
- **Composer.** One card: the plan on its top edge when the agent published
  one, the draft, and one row. The row's leading side holds attach and the
  permission mode chip; its trailing side the context meter (ring and
  percentage), the model chip (`Opus 5.5 · High`, the effort hidden when it
  is the agent's default), and send, which becomes stop while a turn runs.
  The model chip opens every non-mode selector, on/off ones as switches, and
  `Continue in terminal` (§6.12), disabled with its reason while a turn runs.
  Chips are secondary text, never the attention hue. `⏎` sends, `⇧⏎` inserts a
  newline, and `Esc` or `⌘.` stops. There is no separate status line: working
  is the live trail and the stop button, and only `Failed` or `Ended` shows as
  a note in the row.

### 9.4 Platform notes

- **Desktop.** The Conversation surface is a pane like the terminal and the
  browser (RFC 0020 leaves name Sessions; the pane body branches on the
  Session). Keyboard first: `⌘L` focuses the composer, `⌘.` stops, `⌘↑/⌘↓` move
  between turns.
- **Web and iOS.** One Agent view renders every Agent Session, chat or
  terminal: its timeline is this surface's turns, projected from the
  canonical events, and it keeps the Agent View's queue, attachments,
  history paging, and docked interaction card. A chat Session opens it with
  no terminal behind it, no terminal toggle, and no mobile key bar; on iOS
  the docked card sits above the keyboard and the RFC 0013 root attention
  banner routes to it.

### 9.5 Creation

Every client adds the handler choice to the existing creation path rather than
new provider entries:

- **Desktop.** The preset bar keeps one preset per provider. A Settings
  choice, `Launch As`, decides how Claude, Codex, and OpenCode start:
  `Terminal (CLI)`, `Chat (ACP)`, or `Ask each time` (the default), which
  stacks `Terminal` and `Chat` in a popover under the clicked preset. An
  automatic launch has no click to answer, so it uses Chat only when that is
  the setting and the CLI otherwise.
- **Web and iOS.** The new-Session sheet offers `Terminal` or `Chat` for the
  same providers.

## 10. Testing

- **Unit (Go).** A fake ACP agent (a Go test helper started as a subprocess)
  scripts `initialize`, `session/new`, chunked messages, tool calls,
  permission requests, cancellation, crashes, and `session/resume`. Tests
  assert the journaled canonical events, the status and attention sequence,
  first-resolution-wins, coalescing bounds, replay suppression on
  `session/load`, and that a process exit fails the turn and expires pending
  interactions.
- **Real agent (Go, opt-in).** `WARREN_ACP_REAL=1` runs one prompt through
  `opencode acp` end to end.
- **Clients.** Reducer tests for the work-trail and decision-dock projections
  on Web and in Swift; a real Desktop render check with the in-process
  renderer; the Web view against a live Host; iOS in the simulator against a
  live Host.

## 11. Rollout

| Phase | Scope |
| --- | --- |
| 1 | Host: `internal/acp`, the ACP handle, Session creation and lifecycle without a PTY, CLI, tests |
| 2 | Web: Conversation surface for ACP Sessions, creation choice |
| 3 | Desktop: Conversation pane, creation presets |
| 4 | iOS: Conversation surface for ACP Sessions, creation choice |
| 5 | Session selectors (§6.11), agent terminals (§6.6), hand-off to a terminal (§6.12), on the Host and every client |
| 6 | Controls move into the composer (§9.3); Web and iOS render every Agent through one view; history carries state events (§7) |

Each phase is independently shippable; a client that has not reached its phase
still renders an ACP Session through its existing Agent View, because the
events are the ones it already understands.

## 12. Acceptance

1. `warren agent create --provider opencode --agent-handler acp --prompt …`
   produces a Session with `runtimeKind: acp`, no Ghostline runtime, and a
   completed turn whose answer `warren agent read` prints.
2. A TUI Session and an ACP Session of the same provider run side by side in
   one Workspace.
3. A permission request answered from one client resolves once; a second
   client receives `stale_interaction`.
4. Killing the agent process mid-turn fails that turn, expires its pending
   interactions, and the next prompt resumes the same conversation.
5. Restarting the Host, gracefully or by a crash, keeps the agent process: a
   running turn finishes, and a pending permission is answerable under the same
   interaction ID.
6. No ACP chunk produces more than one journal row per 120 ms per message.
7. Desktop, Web, and iOS show the decision dock for a pending permission and
   nowhere else use the attention hue for that Session.
8. Changing the model from any client journals one `config.updated` with the
   agent's new snapshot, and every client's header shows it.
9. `Continue in terminal` on an idle chat ends its agent process before the
   TUI starts, and the TUI Session shows the same conversation.
