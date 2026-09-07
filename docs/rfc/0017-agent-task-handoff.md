# RFC 0017: Agent Task Handoff and Structured Context Synthesis

- Status: Accepted and implemented
- Owner: Warren Desktop, iOS, and Headless
- Created: 2026-09-06
- Scope: Cross-agent task handoff, context distillation, physical ground truth extraction, negative context tracking, native Desktop/iOS review sheets, and client surface hierarchy
- Protocol baseline: Warren protocol 4.0
- Depends on: [RFC 0006](0006-agent-activity-attention.md) (Agent activity and attention), [RFC 0014](0014-autonomous-engineering-pipeline.md) (Autonomous software engineering pipeline), [RFC 0016](0016-canonical-agent-execution-protocol.md) (Canonical agent execution protocol)

---

## 1. Executive Summary

Warren hosts multiple agent runtimes (such as Codex, Claude Code, OpenCode, Qoder, and Antigravity). Historically, agent sessions have operated in complete isolation. When a developer wishes to transition an in-flight task to another agent—such as escalating a stuck problem to a reasoning model, handing off an implementation to an unpolluted reviewer agent, or switching toolchains—the developer is forced to manually re-explain the problem and copy terminal snippets.

This RFC introduces **Agent Task Handoff**: a first-class capability to transition an active task from one agent to another.

### The Core Architectural Axiom: Context & Prompt Over Mechanical Plumbing

Wiring a transport to launch a secondary agent process and transmit a string is mechanically trivial. The true engineering bottleneck and product value lies entirely in **Context Engineering and Prompt Synthesis**:
- **Dumping raw conversation history is an anti-pattern**: Transmitting 50k+ tokens of verbose chat logs, internal thinking loops, tool calls, and ANSI sequences leads to token exhaustion, context dilution ("Lost in the Middle"), and inherits the previous agent's hallucinations and circular failures.
- **Naive initial-prompt forwarding is an anti-pattern**: Passing only the original user request discards all physical progress, forcing the receiving agent to repeat already completed investigations.
- **Effective handoff requires structured, physical synthesis**: Context must be grounded in physical filesystem facts (Git diffs, touched files, test failure stack traces), distilled progress memos, and explicit negative context (what was attempted and why it failed).

### Client Surface Hierarchy

Warren's interaction design is strictly **Desktop & Mobile First**:
1. **macOS Desktop & iOS Mobile (Primary Surfaces)**: First-tier design, keyboard-driven ergonomics, native AppKit/SwiftUI components, and primary focus for Handoff review sheets and steerability.
2. **Web / PWA (Fallback Surface)**: Exclusively a fallback for the desktop client and a remote-access viewer for Public Access or Relay pairing; it does not hold first-class design or feature priority.

---

## 2. Motivation & Failure Modes of Naive Handoffs

### 2.1 The Need for Cross-Agent Handoff

In complex software engineering workflows, a single agent rarely suffices for the entire lifecycle:
1. **Model Escalation / Unsticking**: A fast, lightweight model (e.g. Claude 3.5 Sonnet) drafts code but becomes trapped in an algorithmic edge case or concurrency deadlock. The user wants to hand off to a deep reasoning model (e.g. Claude 3.7 Thinking, o3-mini) with exact failure context.
2. **Role Transitions (Separation of Concerns)**: Per [RFC 0014 Section 4.2](0014-autonomous-engineering-pipeline.md#42-separation-of-concerns-via-independent-contexts), code review must be performed in a clean, unpolluted context to overcome LLM self-confirmation bias. Handing off from a Coder agent to a Reviewer agent requires passing the physical `git diff` and acceptance criteria, without inheriting the coder's internal reasoning chatter.
3. **Ecosystem & Toolchain Switching**: An architect agent structures a plan, which is then handed off to a terminal-centric agent (such as Codex or Antigravity) that excels at local build, execution, and verification.

### 2.2 Why Raw Transcript Dumps Fail

| Approach | Token Cost | Failure Mode |
| :--- | :--- | :--- |
| **Raw JSONL / Chat Dump** | Extremely High (50k–150k tokens) | Context window saturation, attention dilution, format incompatibilities between providers (e.g. Claude XML vs Codex function calls). |
| **Piping PTY / ANSI Bytes** | High & Corrupting | Control sequences, escape codes, and TUI redraw noise confuse receiving LLMs. |
| **Original Prompt Only** | Zero Overhead | Discards all findings; target agent repeats redundant scans, re-reads files, and wastes time. |
| **Structured Physical Handoff (This RFC)** | Compact (400–800 tokens) | High-density signal, grounded in Git facts, explicit dead-ends, zero hallucination transfer. |

---

## 3. The Four Pillars of High-Fidelity Handoff Context

An effective handoff package is structured into four deterministic layers:

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        Structured Handoff Brief                        │
├────────────────────────────────────────────────────────────────────────┤
│ 1. Objective & Constraints                                             │
│    - Original user intent                                              │
│    - Intermediate human steering / constraints                         │
├────────────────────────────────────────────────────────────────────────┤
│ 2. Physical Ground Truth (Filesystem & Git State)                      │
│    - Current Git branch / worktree path                                │
│    - `git status` (untracked, modified, staged files)                  │
│    - Compact `git diff --stat` and key diff hunks                      │
│    - Touched files (from canonical edit/write events)                  │
├────────────────────────────────────────────────────────────────────────┤
│ 3. Findings, Verification & Dead Ends (Negative Context)               │
│    - What was verified to work                                         │
│    - What was attempted and failed (dead ends)                         │
│    - Non-zero exit code outputs & failing test stack traces           │
├────────────────────────────────────────────────────────────────────────┤
│ 4. Handover Call-to-Action (Target Milestone)                          │
│    - Specific task requested from the receiving agent                  │
└────────────────────────────────────────────────────────────────────────┘
```

### 3.1 Pillar 1: Objective & Scope Constraints
- **Original User Goal**: Extracted from the first turn of the execution.
- **Steering History**: User messages delivered during turns (e.g. "Do not change public API signatures") are isolated and elevated as active constraints.

### 3.2 Pillar 2: Physical Ground Truth (Filesystem Authority)
Per [RFC 0014](0014-autonomous-engineering-pipeline.md), the filesystem and Git repository remain the sole authority of truth:
- **Worktree State**: Headless queries `git status --porcelain` and `git diff --stat` in the workspace directory.
- **Canonical Touched Files**: Headless inspects canonical events (`edit`, `write`, `read`) from `CanonicalAgentEventStore` ([RFC 0016](0016-canonical-agent-execution-protocol.md)) to identify key touched files.
- **Physical Artifacts**: References to created plan files (e.g. `.warren/plan.md`) or documentation.

### 3.3 Pillar 3: Negative Context & Dead Ends (The Anti-Loop Guard)
The single biggest cause of agent failure during handoff is repeating previously failed approaches:
- **Discarded Approaches**: Key summaries of what failed and why.
- **Verification Failures**: If the last executed command failed (e.g., exit code 1 from `go test` or `swift test`), the trailing error snippet and stack trace are extracted directly from `${command.output}`. The receiving agent immediately sees the exact failing assertion without having to rediscover it.

### 3.4 Pillar 4: Call to Action
A concise, unambiguous instruction tailored to the handoff mode:
- *Continue*: "Resolve the failing assertion in `TestSessionLifecycle` while preserving existing invariants."
- *Review*: "Review the uncommitted diff against concurrency safety and error propagation rules."

---

## 4. Architecture & Data Flow

```text
[ Source Agent Session ] (macOS Desktop / iOS Mobile)
           │
           │ User triggers Handoff (⌘⌥H / Action Sheet)
           ▼
[ Headless: Handoff Synthesizer ]
   ├── 1. Query Canonical Event Store (User turns, failed tools, errors)
   ├── 2. Query Host Git Repository (`git status`, `git diff --stat`)
   └── 3. Synthesize Handoff Draft (Deterministic Template + optional LLM Distillation)
           │
           ▼
[ Native Handoff Review Sheet ] (AppKit / SwiftUI)
   ├── Target Agent Selector (Codex / Claude / OpenCode / Antigravity)
   ├── Target Worktree Scope (Same worktree vs Isolated branch)
   └── Editable Prompt Editor (Human-in-the-Loop review & adjustments)
           │
           │ User confirms "Dispatch Handoff"
           ▼
[ Headless: Target Agent Session ]
   └── Spawns / attaches target runtime with synthesized Handoff Prompt as Turn 1
```

### 4.1 Handoff Synthesis Modes

1. **Deterministic Fast Path (Zero Token, Instant)**:
   Synthesizes the Markdown memo using local metadata:
   - Initial user prompt;
   - Git status and diff stat;
   - Touched files extracted from canonical tool calls;
   - Last non-zero command output.
2. **Semantic Distillation Path (Compact LLM Summary)**:
   For complex multi-turn sessions, Headless optionally triggers a lightweight distillation prompt against a fast local or hosted model to compress intermediate reasoning into a 300-word structured memo.

---

## 5. Client Surface Design (Desktop & Mobile First)

### 5.1 macOS Desktop Experience
- **Trigger**: Session Pane Header button (`⇄ Handoff`), Tab Context Menu, or `⌘⌥H`.
- **Presentation**: A native AppKit/SwiftUI Sheet (`WarrenDesktopHandoffSheet`):
  - **Source Summary**: Shows source session title, active agent provider, and duration.
  - **Target Configuration**: Dropdown to select receiving agent preset (Claude Code, Codex, OpenCode, Antigravity) and target workspace/worktree mode.
  - **Editable Prompt**: Syntax-highlighted Markdown editor containing the synthesized handoff brief. The developer can edit, add constraints, or adjust instructions before sending.
  - **Action**: "Confirm & Start" spawns the target session in a split pane or new tab and focuses it immediately.

### 5.2 iOS Mobile Experience
- **Trigger**: Navigation bar action button (`⇄`) or chat overflow menu in `IOSAgentChatView`.
- **Presentation**: A native SwiftUI Sheet (`IOSAgentHandoffSheet`):
  - Segmented control for Handoff Mode (*Continue*, *Review*, *Test*).
  - Compact target agent picker.
  - Scrollable, editable text card with the synthesized prompt.
  - Primary "Start Handoff" action button.

### 5.3 Web Fallback
- The Web client acts strictly as a remote replica, exposing a basic modal dialog for parity when accessed remotely. It does not dictate protocol or feature semantics.

---

## 6. Protocol Extensions (Warren Protocol 4.0)

Headless exposes two RPC methods under the canonical Agent API:

### 6.1 `agent.handoff.draft`
Requests a synthesized handoff draft for an active session.

```json
{
  "sessionId": "sess-1234",
  "mode": "continue | review | test"
}
```

Response:
```json
{
  "sourceProvider": "claude",
  "worktreeBranch": "feat/canonical-events",
  "modifiedFiles": ["Sources/Warren/Agent.swift", "Headless/server.go"],
  "gitDiffStat": "2 files changed, 45 insertions(+), 12 deletions(-)",
  "lastFailure": "FAIL: TestAgentStream (0.12s)\n    agent_stream_test.go:42: timeout waiting for event",
  "synthesizedPrompt": "# Task Handoff from claude\n\n## Objective\n..."
}
```

### 6.2 `agent.handoff.dispatch`
Creates or attaches to the target session and initiates Turn 1.

```json
{
  "sourceSessionId": "sess-1234",
  "targetProvider": "codex",
  "workspaceScope": "same_worktree | new_branch",
  "prompt": "# Task Handoff from claude\n\n## Objective\n..."
}
```

---

## 7. Acceptance Criteria

1. **Physical Grounding**: A handoff package generated from a modified workspace must always include accurate `git diff --stat` and modified file paths.
2. **Negative Context Preservation**: If a session has a failed command execution in its canonical event log, the error snippet must be present in the synthesized handoff prompt.
3. **No Unbounded Chat Dumps**: The synthesized prompt must never dump raw provider transcripts or JSONL lines; token size must remain bounded under 1,500 tokens.
4. **Human Steerability**: Desktop and iOS clients must present an editable prompt surface before dispatch; silent automated handoffs without user approval are prohibited.
5. **Platform Priority**: Desktop and iOS implementations are delivered and verified first; Web changes remain secondary fallbacks.
