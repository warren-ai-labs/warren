# RFC 0024: Lead Agent

- Status: Proposed
- Owner: Warren Desktop, iOS, and Headless
- Created: 2026-10-22
- Scope: one Agent in a Task that assigns work to other Agents, coordinates
  them, and brings decisions and checks back to the user
- Supersedes: [RFC 0014](0014-autonomous-engineering-pipeline.md) (deprecated)

This RFC defines what the feature does. It does not define layout or
interaction; those come from design.

## 1. Summary

A Task can have a **Lead**: an ordinary Agent Session whose job is to split the
Task into pieces, start other Agents (the **Crew**) to do them, check their
results, and come back to the user only for decisions and acceptance. The user
talks to the Lead; the Crew keeps running in its own Sessions.

The Lead coordinates through the existing CLI (`warren agent create`,
`agent send`, `agent list`, `agent cancel`, `workspace create/remove`). Warren
adds one thing: it reads a few markers in the Lead's messages and presents them
as structured information instead of plain text.

## 2. Terms

| Term | Meaning |
| --- | --- |
| Lead | The one Agent Session a Task marks as its coordinator. Any provider. |
| Crew member | An Agent Session the Lead started for the Task. An ordinary Session in its own Workspace. |
| Decision | A question the Lead needs the user to answer before it can go on. |
| Check | Something the Lead has finished and wants the user to verify on main. |

## 3. Functions

1. **Assign.** The Lead starts Crew members with the CLI. Each one is a normal
   Session; nothing about it is special.
2. **Coordinate.** The Lead reads Crew results, sends follow-ups, cancels or
   replaces members, and merges their work. The user can also send a message to
   any Crew member directly.
3. **Route.** A Lead message can refer to a Crew member. The reference resolves
   to that Session, shows its live status, and opens it.
4. **Decide.** The Lead can ask the user a question with fixed options. The
   user's answer goes back to the Lead as an ordinary message.
5. **Accept.** The Lead can hand the user a list of checks. Each check is
   passed or reported as a problem, optionally with a note; the result goes
   back to the Lead as an ordinary message.
6. **Take over.** The user can enter any Crew member's Session and work in it as
   in any other Session. The Lead is not involved.

## 4. Markers

The Lead writes markers inline in its message text. Clients parse them; the
Host and the protocol do not change.

| Marker | Meaning |
| --- | --- |
| `[#agent:<session-id>]` or `[#agent:<session-id>\|<title>]` | A reference to a Crew member. |
| `[#ask:<question>\|<option>\|<option>…]` | A decision with two or more options. |
| `[#accept:<what to check>\|<where to check it>]` | One check. Consecutive markers form one list. |

Rules:

1. Markers inside code blocks or inline code are not parsed.
2. `#agent` resolves only to an existing Session; status comes from that
   Session's live activity, never from the text.
3. A malformed marker, or one whose Session does not exist, is shown as
   written.
4. An answer or check result is sent to the Lead as a plain user message (for
   example `Decision: <option>` or `Check passed: <what>`), so it works the
   same for every provider.
5. Markers are honoured only in the Lead's own messages.

## 5. Attention

- Only a message containing `#ask` or `#accept` notifies the user and marks the
  Task as needing them. Crew progress, completions, retries, and Lead messages
  without those markers do not notify.
- An answered decision or a resolved check no longer counts as needing the user.

## 6. Becoming a Lead

- The user marks an Agent Session in a Task as its Lead. One Lead per Task.
- Warren gives the Lead a prompt that explains the markers, the CLI commands it
  coordinates with, and the Task's ground rules. The prompt also states what the
  Lead is authorised to do without asking (for example merging to main); there
  is no separate permission system.
- Ground rules every Crew member must follow (stay in its worktree, never kill
  processes by name or pattern, never touch the user's app, daemon, or
  `~/.warren`, verify before reporting) are part of the Lead's prompt and are
  passed on by the Lead when it starts a member.

## 7. What every client must show

Without prescribing layout:

1. For a Task with a Lead: the Lead's conversation, the list of Crew members
   with each one's live status and latest result sentence, and which members
   or items need the user.
2. Rendered markers: references, decisions with their options, and checks with
   pass / problem.
3. A way to open a Crew member's Session and to send it a message.
4. Executor Sessions stay in the sidebar tree where they are today; the feature
   adds no new top-level entry.

Desktop is first; iOS follows with the same functions.

## 8. Out of scope for the first version

- Host-side parent/child records, a persisted Task ledger, and new CLI
  primitives such as waiting on any Crew member. The Lead keeps its own state
  for now; these can follow once the feature is in use.
- Automatic Lead handover when its provider runs out of quota.
- Pipelines, DAGs, or Agents talking to each other directly.

## 9. Open questions

- Whether Desktop's Conversation surface renders TUI Agents fully enough to show
  the Lead and Crew without the terminal, or only ACP Sessions today
  ([RFC 0023](0023-acp-agent-sessions.md)).
- How the user marks a Session as Lead, and whether a Task can start with one.
