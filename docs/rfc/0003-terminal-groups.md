# RFC 0003: Terminal Groups for standalone shells

- Status: Implemented
- Owner: Warren Host and Desktop clients
- Created: 2026-08-17
- Scope: phase-one standalone shell organization

## Summary

Warren will add Terminal Groups as a second session context alongside
Projects and Workspaces. A Terminal Group organizes standalone shell Sessions
that are not tied to a Git repository or Workspace.

Terminal Groups reuse the existing Terminal Session, Runtime Binding,
Attachment, output recovery, and Ghostty lifecycle. They do not introduce a
second terminal runtime model.

## Motivation

The current Workspace-first navigation is appropriate for Git-aware work, but
it makes short-lived general-purpose shells awkward to discover and reuse. A
user should be able to keep a small set of terminals for home-directory work,
system inspection, or unrelated repositories without creating a Project or
Workspace for each shell.

## Domain model

```text
Host
├── Projects
│   └── Workspaces
│       └── Terminal Session (scope: workspace)
└── Terminal Groups
    └── Terminal Session (scope: terminalGroup)
```

### Terminal Group

A Terminal Group is a Host-owned, ordered resource with:

- stable ID;
- editable name;
- Host-local optional default startup directory;
- persistent order.

The first ordered Group is the default destination for newly created
standalone Sessions. The initial migration creates a normal Group named
`Inbox`; it has no special lifecycle or undeletable status.

When a Group has no configured home, the Host user's home directory is used as
the new Session's working directory. The configured home is a working
directory default, not an instruction to modify the child process's `HOME`
environment variable.

### Session Scope

Every Terminal Session has exactly one scope:

```text
workspace(WorkspaceID)
terminalGroup(TerminalGroupID)
```

Existing Sessions decode as `workspace` scope. A Session never belongs to both
a Workspace and a Terminal Group. Runtime identity, output recovery, and
attachments remain keyed by the Session ID.

## Desktop interaction

The Sidebar adds a fixed-height `Terminals` section above `Projects`.

- Each row represents one Terminal Group, not an individual Session.
- The section shows at most three rows in its normal height.
- Additional Groups scroll inside the section and do not move the Projects section.
- The header can collapse or expand its rows. This device-local preference is
  scoped per Endpoint, like the other sidebar section disclosure states.
- A row shows the Group name, running Session count, and aggregate activity.
- Selecting a Group changes the active Session Context and filters the existing
  top Tab Bar to that Group's Sessions.
- Selecting an empty Group does not start a process; the Tab Bar add button and
  `Command+T` remain the explicit ways to create a Terminal in that Group.

When the active Session Context is a Terminal Group, `Command+T` creates a
shell in that Group. Workspace mode keeps the existing `Command+T` behavior.
Every create request carries the selected context ID captured at invocation;
completion never derives its target from a later selection.

The active Group and active Tab are device-local presentation state. Group
identity, order, home, and Session ownership are Host state, so Local and
remote endpoints each have independent Group lists.

## Lifecycle and deletion

Standalone Group Sessions are durable until explicitly closed, just like
Workspace Sessions. “Standalone” means not Project-bound; it does not mean the
runtime is killed when Warren quits.

Deleting an empty Group is immediate. Deleting a Group with Sessions requires
an explicit choice to move those Sessions to another Group or terminate them.
Deleting the first Group promotes the next ordered Group. If no Group remains,
the Host creates `Inbox` before the next standalone Session is created.

Moving a Session between Terminal Groups preserves its runtime, working
directory, output history, and Session ID. The same applies when moving a
Session between a Workspace and a Terminal Group: the move only re-parents the
durable record, so the tab appears under the destination context while the
process, cwd, output history, and Session ID remain untouched.

## Protocol and persistence

The Host roster exposes Terminal Groups and each Session's scope. Session
creation accepts a scope rather than requiring a Workspace ID, and
`session.move` re-parents an existing Session between scopes. The JSON state
schema migrates existing `workspace` Sessions without changing their identity
or runtime.

The Host is the single writer for:

- Terminal Groups and their order;
- Group home paths;
- Session scope and runtime state.

The Client Layout Store remains the single writer for Window selection, Group
views, Tab order, and active Tabs.

## CLI surface

The CLI will expose a `terminal-group` resource with the same Host endpoint
and JSON conventions as Projects, Workspaces, and Sessions:

```text
warren terminal-group list
warren terminal-group create [--name NAME] [--home PATH]
warren terminal-group rename GROUP_ID --name NAME
warren terminal-group home GROUP_ID --path PATH
warren terminal-group move GROUP_ID [--before OTHER_GROUP_ID]
warren terminal-group remove GROUP_ID [--force]
warren session create --group GROUP_ID
warren session move SESSION_ID --workspace WORKSPACE_ID --confirm
warren session move SESSION_ID --group GROUP_ID --confirm
# From a Warren-managed session, prefer the binding-backed target:
warren session move --current --workspace WORKSPACE_ID
```

The existing `session create WORKSPACE_ID` form remains supported for
Workspace Sessions. The implementation may add a short `group` alias after
the canonical resource is stable.

## Non-goals

- Group-specific retention policies such as close-on-quit;
- drag-and-drop of Sessions between Groups;
- Group-level environment profiles or initial commands;
- runtime panes or tmux windows exposed as Group children;
- multi-client synchronized active Group or Tab selection.

## Acceptance criteria

1. Existing Workspace Sessions and their tabs behave exactly as before.
2. A fresh or migrated Host exposes `Inbox` as the first Terminal Group.
3. A Group Session starts in its Group home or the Host user's home directory.
4. The Desktop renders no more than three Group rows before an inner scroll.
5. `Command+T` in Group mode creates in the selected Group, even if selection
   changes before the request completes.
6. Group deletion never silently kills running Sessions.
7. CLI and Desktop consume the same versioned Host protocol.
8. Host restart and Client restart recover Group Sessions through the existing
   Runtime Binding and output recovery path.
