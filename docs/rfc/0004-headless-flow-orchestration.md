# RFC 0004: Headless flow orchestration and optional extensions

- Status: Proposed
- Owner: Warren Headless and clients
- Created: 2026-08-21
- Scope: flow orchestration, agent tasks, and plugin boundaries

## Summary

Warren will add a recoverable Flow layer to `warren-headless`. Headless remains
the sole authority for Flow definitions, runs, Workspace allocation, Session
creation, execution, and recovery. Desktop and Web are projections that render
state and send typed intents; they never execute agents or commands directly.

The Flow layer is optional and lazy. A Host without flows keeps the existing
resource and session behavior and does not start a scheduler or plugin process.

## Goals

- Create a new Warren Workspace for a run by default, with explicit reuse of
  the current or a selected Workspace.
- Create a new Warren Terminal Session for each Agent node by default, with
  explicit Session reuse.
- Orchestrate Codex and Claude conversations through the existing Session and
  Runtime boundaries.
- Pause at approvals and gates, retry individual nodes, and resume after Host
  or client restarts.
- Leave stable extension points for new node types, Agent providers, triggers,
  and external adapters.

## Non-goals

- A second Workspace, Session, or Runtime resource model.
- A separate robot service for merge or release actions.
- A plugin marketplace, remote plugin execution, or dynamic UI plugins in the
  first phase.
- Making Desktop or Web a second execution authority.

## Domain model

```text
Host
├── Projects / Workspaces / Terminal Sessions
└── Flow Service
    ├── FlowDefinition
    ├── FlowRun
    └── NodeRun
```

### FlowDefinition

A versioned graph containing nodes, dependencies, parameters, and policies.
Definitions are Host-owned. A project may keep definitions under
`.warren/flows/`; Headless validates and writes them, while clients edit them
through typed intents.

### FlowRun

An immutable snapshot of a FlowDefinition execution. It stores the selected
Project, the allocated Workspace, run parameters, status, and retention data.

### NodeRun

The execution record for one node. Its status is one of:
`queued`, `running`, `waiting`, `succeeded`, `failed`, `cancelled`, or
`skipped`. Every asynchronous action carries immutable `runID`, `nodeID`,
`targetID`, and `requestID` values.

### AgentProfile

A configuration for an Agent invocation: provider (`codex` or `claude`), model,
prompt template, capabilities, environment policy, and completion policy. A
merge or release “robot” is an AgentProfile, not a new Warren resource.

## Execution

The default run sequence is:

```text
allocate Workspace
  → run Agent / Command nodes by dependency
  → wait for Approval or Gate
  → resume downstream nodes
  → retain the Workspace and run records
```

Workspace allocation supports `new` (default), `current`, and `selected`
modes. A new Workspace is retained by default for inspection and recovery;
cleanup is an explicit policy or action.

An `agent.run` node creates a new Warren Terminal Session by default, starts
the configured Agent CLI, records its external Conversation ID, and converts
structured events and process exit into the standard NodeRun status. Reuse is
explicit and serialized so two nodes cannot concurrently write to one Agent
conversation.

The first built-in node set is:

- `workspace.create`
- `agent.run`
- `command.run`
- `approval`
- `gate`

## Optional activation

Flow and plugin support are controlled by Host settings:

```json
{
  "features": {
    "flows": "auto",
    "plugins": "auto"
  }
}
```

Values are `off`, `auto`, or `on`.

- `off`: the protocol reports the capability as unavailable.
- `auto`: Headless starts Flow services on the first Flow request or when a
  Flow definition is discovered; otherwise no scheduler is started.
- `on`: Flow services are initialized during Host startup.

Desktop and Web use a capability handshake to hide or show Flow controls.

## Plugin boundary

Plugins run outside the Headless process and communicate through a versioned
JSON request/event protocol. A manifest declares:

```json
{
  "id": "gitlab-bot",
  "apiVersion": 1,
  "capabilities": ["node.merge"],
  "entrypoint": "gitlab-bot"
}
```

A plugin receives typed node input and approved capability handles. It cannot
write Host state directly; it returns events and a result that Headless maps
to NodeRun state. Built-in executors use the same boundary conceptually, so a
future adapter can replace them without changing Flow persistence or client
protocols.

## Client and protocol boundary

Headless exposes Flow definitions, runs, node events, capabilities, and typed
intents through the existing versioned protocol. Clients may request create,
start, approve, cancel, retry, and definition-edit operations. They do not
start a process, mutate a Workspace, or infer completion from terminal text or
Tabs.

Web may initially expose read-only run projections. Desktop may provide the
full Canvas and control surface without becoming an execution owner.

## CLI

The initial CLI surface is:

```text
warren flow list
warren flow run FLOW_ID --project PROJECT_ID
warren flow status RUN_ID
warren flow approve RUN_ID
warren flow retry RUN_ID NODE_ID
warren flow cancel RUN_ID
```

## Acceptance criteria

1. Existing Hosts with no Flow definitions preserve current startup and
   Session behavior.
2. A Flow can create a new Workspace and run Codex or Claude without client
   connectivity.
3. A run survives Headless and client restarts with its Workspace, Sessions,
   and NodeRun states intact.
4. Approval and Gate nodes block downstream work until explicitly released.
5. Desktop and Web consume the same Headless projections and cannot become a
   second source of truth.
6. A failing plugin or Agent becomes a standard failed NodeRun and does not
   crash the Headless process.
