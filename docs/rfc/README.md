# Warren RFCs

Design proposals that changed, or are proposing to change, a Warren boundary:
the resource model, the protocol, a runtime, or a client surface. An RFC records
why a boundary is where it is, so the reasoning does not have to be re-derived
from the code.

Superseded and abandoned RFCs move to [`../archive/rfc/`](../archive/rfc/). They
are kept because a later RFC's rationale usually depends on what was rejected
first, but they describe no current behavior.

## Status vocabulary

| Status | What it means |
| --- | --- |
| **Draft** | Being written. The design may still change shape; do not build against it. |
| **Proposed** | Complete and ready for review. Not accepted, not built. |
| **Accepted** | Agreed as the direction. Implementation may be partial or not started. |
| **Implemented** | Shipped and describing current behavior. |
| **Superseded** / **Abandoned** | No longer current. Lives in `../archive/rfc/`. |

## Active

| # | Title | Status | Created |
| --- | --- | --- | --- |
| [0002](0002-one-way-desktop-rendering.md) | One-way desktop rendering and terminal lifecycle | Implemented | 2026-08-17 |
| [0003](0003-terminal-groups.md) | Terminal Groups for standalone shells | Implemented | 2026-08-17 |
| [0005](0005-resource-links-notice-center.md) | Resource links and the desktop notice center | Implemented | 2026-08-22 |
| [0006](0006-agent-activity-attention.md) | Agent activity and human attention | Implemented ¹ | 2026-08-22 |
| [0007](0007-durable-session-memory.md) | Durable Session memory after Host restart | Accepted | 2026-08-24 |
| [0008](0008-native-tab-splits.md) | Desktop split windows for independent terminal Sessions | Implemented ² | 2026-08-25 |
| [0009](0009-own-relay-and-public-tunnel.md) | Relay-owned access and public routes | Implemented | — |
| [0010](0010-ios-agent-view-presentation-parity.md) | Agent View parity across iOS and Web | Implemented ³ | 2026-08-31 |
| [0011](0011-session-process-inventory.md) | Per-session process inventory | Proposed | 2026-09-02 |
| [0012](0012-antigravity-cli-agent-support.md) | Antigravity CLI Agent support | Proposed | 2026-09-03 |
| [0013](0013-agent-interaction-architecture-and-pty-guarding.md) | Dual-track Agent architecture and PTY input guardrails | Proposed | 2026-09-03 |
| [0014](0014-autonomous-engineering-pipeline.md) | Autonomous engineering pipeline and declarative execution engine | Proposed | 2026-09-03 |
| [0015](0015-cloud-agent-daemon-and-scheduled-bots.md) | 24/7 cloud Agent daemon, webhook workers, and scheduled bots | Proposed ⁴ | 2026-09-03 |
| [0016](0016-canonical-agent-execution-protocol.md) | Canonical Agent execution protocol and client event replicas | Implemented | 2026-09-05 |
| [0017](0017-agent-task-handoff.md) | Agent Task handoff and structured context synthesis | Implemented | 2026-09-06 |
| [0018](0018-multi-host-sidebar-projects.md) | Multi-Host Project and Workspace sidebar | Draft | 2026-09-08 |
| [0019](0019-lan-host-discovery-and-pairing.md) | LAN Host discovery, Host-armed pairing, and multi-network routing | Draft | 2026-09-08 |
| [0020](0020-host-owned-pane-groups.md) | Host-owned Pane Groups for split terminal layouts | Draft | 2026-09-16 |
| [0021](0021-embedded-editor-sidebar.md) | Embedded editor sidebar and Workspace pane integration | Draft | 2026-09-16 |
| [0022](0022-warren-browser.md) | Warren Browser: an embedded Chromium runtime with an agent action surface | Draft | 2026-09-20 |

¹ Amended 2026-09-16: the `stalled` activity and the `warning` attention kind were removed.
² Layout ownership and persistence are superseded by [RFC 0020](0020-host-owned-pane-groups.md).
³ Written in Chinese, unlike every other RFC. Its `agent.turn.interrupt` references describe a pre-4.0 design; [RFC 0016](0016-canonical-agent-execution-protocol.md) is authoritative and the canonical method is `agent.turn.cancel`.
⁴ Baseline draft, subject to active iteration.

## Archived

| # | Title | Status |
| --- | --- | --- |
| [0001](../archive/rfc/0001-terminal-surface-retention.md) | Retain terminal surfaces across tab switches | Superseded by [0002](0002-one-way-desktop-rendering.md) |
| [0004](../archive/rfc/0004-headless-flow-orchestration.md) | Headless flow orchestration and optional extensions | Abandoned, superseded by [0014](0014-autonomous-engineering-pipeline.md) |
| [0011](../archive/rfc/0011-cloud-agent-runs.md) | Cloud Agent runs and runner control plane | Abandoned, superseded by [0015](0015-cloud-agent-daemon-and-scheduled-bots.md) |

> [!NOTE]
> The archived `0011` (Cloud Agent runs) and the active
> [`0011`](0011-session-process-inventory.md) (per-session process inventory)
> once shared a number. `0011` now refers to the active one; cite the archived
> document by its full path.

## Writing one

Number the file after the highest existing number, active or archived, and open
it with the metadata block the current RFCs use:

```markdown
# RFC 00NN: Title in sentence case

- Status: Draft
- Owner: the components that have to change
- Created: YYYY-MM-DD
- Scope: what boundary this moves
- Protocol baseline: the Warren protocol version it assumes
- Depends on / Supersedes: links to other RFCs
```

Keep the status line current as the work lands, and add a row here in the same
change. When an RFC stops describing a direction Warren still intends to take,
move it to `../archive/rfc/`, fix the relative links inside it, and move its row
to **Archived** rather than deleting it.

Related: [`../decisions/`](../decisions/) records narrower choices that did not
need a full RFC, [`../adr/`](../adr/) records architecture decisions, and
[`../backlog.md`](../backlog.md) records work deliberately deferred.
