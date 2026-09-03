# RFC 0014: Autonomous Software Engineering Pipeline and Declarative Execution Engine

- Status: Proposed
- Owner: Warren Headless, Desktop, Web, and iOS
- Created: 2026-09-03
- Scope: Autonomous task and workflow execution, Git worktree isolation, declarative pipeline primitives, explicit context injection, self-repair loops, human gates, and data-driven UI/UX.
- Supersedes: [RFC 0004](0004-headless-flow-orchestration.md)
- Protocol baseline: Warren protocol 2.0 with capability negotiation
- Depends on: [RFC 0006](0006-agent-activity-attention.md) (Agent activity and attention), [RFC 0010](0010-ios-agent-view-presentation-parity.md) (Agent view presentation parity), [RFC 0013](0013-agent-interaction-architecture-and-pty-guarding.md) (Dual-track agent architecture)

---

## 1. Summary

This RFC establishes Warren's core autonomous execution engine for software engineering tasks. It replaces the speculative, generic Directed Acyclic Graph (DAG) model of RFC 0004 with a pragmatic, developer-first pipeline architecture designed to solve the real-world adoption problem: **making autonomous coding effortless to launch, completely transparent to monitor, and friction-free to steer or take over.**

The architecture rests on five foundational pillars:

1. **Zero-Configuration Entrypoint**: Users can trigger autonomous tasks via a single CLI command (`warren run ...`) or a minimalist keyboard-driven Launchpad popover (`⌘K`), with zero mandatory YAML or setup.
2. **Strict Git Worktree Isolation**: All autonomous operations execute within dedicated, isolated Git worktrees (`.worktrees/task-<slug>`). The user's active working directory, current branch, and uncommitted edits are never touched or dirtied.
3. **Three Atomic Primitives with Self-Repair Loops**: Workflows are composed of only three fundamental building blocks:
   - `agent`: autonomous LLM execution with specified role and instructions;
   - `command`: local shell execution (`test`, `build`, `lint`, `benchmark`);
   - `gate`: human verification checkpoint.
   Commands support an automatic `retry_with_agent` modifier that feeds test failures and stack traces back into the developer agent for iterative self-healing.
4. **Explicit, Tangible Context Injection**: Replaces open-ended multi-agent chitchat with clean, artifact-based handoffs. Context is strictly injected via four physical data sources: `${input}`, `context.files`, `context.diff`, and `${command.output}`. The filesystem and Git repository remain the sole authority of truth.
5. **Data-Driven, Native UI/UX**: The user interface (Desktop, Web, iOS) dynamically adapts its layout and stepper to the exact steps being executed, featuring real-time incremental diff inspection, non-blocking agent steering (`⌘J`), and a one-click escape hatch to native terminal sessions (`⌘T`).

---

## 2. Motivation & Lessons Learned

### 2.1 Why Traditional Workflow Tools Fail in Software Engineering

Previous attempts at automated agent workflows (such as heavy DAG engines, AutoGPT, and conversational multi-agent frameworks) consistently fail to gain adoption among practicing developers due to five core friction points:

1. **Configuration Overload**: Requiring developers to author complex DAG manifests, declare node parameters, and configure custom plugins before writing a line of code creates unacceptable friction.
2. **The Black-Box Anxiety**: Tasks vanish into an opaque background process. Developers cannot see incremental progress, cannot determine whether the agent has gone down an unproductive rabbit hole, and cannot intervene until failure occurs.
3. **Working Tree Contamination**: Running agents directly in the user's primary working directory frequently mutates unstaged edits, corrupts local states, or produces messy Git merge conflicts.
4. **Fragile Multi-Agent Conversation (Pseudo-Collaboration)**: Frameworks where multiple agents engage in free-form chat suffer from compounding hallucinations, excessive token consumption, and diluted focus. In software engineering, engineers collaborate via specifications, code reviews, and test suites—not unconstrained chatter.
5. **Lack of Terminal Interoperability**: When an autonomous tool struggles, developers cannot easily jump into the environment to inspect files or execute manual commands, forcing a painful context switch.

### 2.2 Why RFC 0004 Was Abandoned

RFC 0004 proposed a heavy DAG orchestration engine (`FlowDefinition`, `FlowRun`, `NodeRun`, `gitlab-bot` plugins) modeled after enterprise CI/CD systems (like Airflow or Argo). Crucially, RFC 0004 defaulted `agent.run` nodes to interactive PTY Terminal Sessions. This created an irreconcilable contradiction:
- Interactive PTYs expect human keyboard interaction and ANSI screen rendering;
- Background autonomous workflows require structured event streams, headless process execution, deterministic verification, and clean worktree isolation.

RFC 0014 formally replaces RFC 0004 by adopting the **Track 2 (Autonomous / Headless Runs)** model defined in RFC 0013, completely untethering automated execution from interactive PTY allocation while preserving on-demand terminal access.

---

## 3. Domain Model & Primitives

### 3.1 The Three Atomic Building Blocks

Every engineering workflow—from a 30-second bugfix to a multi-stage RFC implementation—is expressed as a linear or looped sequence of three atomic primitives:

```text
┌──────────────────────────────────────────────────────────────┐
│                    Warren Pipeline                           │
│                                                              │
│   ┌───────────────┐     ┌───────────────┐   ┌────────────┐   │
│   │  1. `agent`   │ ──► │ 2. `command`  │ ─►│ 3. `gate`  │   │
│   │  (Autonomous) │     │ (Verification)│   │  (Human)   │   │
│   └───────────────┘     └───────────────┘   └────────────┘   │
│           ▲                     │                            │
│           └──── retry on fail ──┘                            │
│              (Self-Repair Loop)                              │
└──────────────────────────────────────────────────────────────┘
```

#### 1. `agent` (Autonomous Model Turn)
Executes an autonomous LLM turn within the isolated worktree.
- `role`: Functional persona (e.g., `coder`, `architect`, `reviewer`, `documenter`).
- `prompt`: Actionable instructions for this step.
- `context`: Explicit contextual references (files, diffs, inputs).
- `tools`: Allowed tool capability handles (read, edit, bash, search).

#### 2. `command` (Shell Verification)
Executes a deterministic shell command inside the worktree directory.
- `command`: Exact command line (e.g., `go test -v ./...`, `npm run build`, `cargo test`).
- `timeout`: Maximum duration before cancellation (e.g., `5m`).
- `env`: Explicit environment variables.
- `on_fail`: Failure handling policy (abort, continue, or trigger self-repair).

#### 3. `gate` (Human Verification Checkpoint)
Suspends pipeline execution and elevates an `Attention` signal (per RFC 0006/0010) to the user.
- `type`: `review` (inspect diff and approve), `choice` (select between options), or `input` (solicit clarification).
- `timeout`: Optional grace period.
- `actions`: Available user decisions (e.g., `approve`, `steer`, `discard`).

### 3.2 The Self-Repair Loop Modifier (`on_fail: retry_with_agent`)

Unlike traditional CI systems that fail immediately upon test failure, the pipeline links `command` verification directly to the `agent` implementation step via bounded feedback loops:

```yaml
- id: test
  name: "Run Automated Test Suite"
  command: "go test ./..."
  on_fail:
    retry_with_agent:
      target: dev                  # Target agent step to invoke
      prompt: |
        The test suite failed with the following error output:
        ```
        ${command.output}
        ```
        Please analyze the failure, inspect the code, and apply the necessary fixes.
      max_attempts: 3              # Bounded retry ceiling
```

If the command succeeds (exit code 0), the pipeline smoothly transitions to the next step. If it fails, the error output is injected into the agent, which inspects the failure and modifies files in the worktree. If `max_attempts` is exhausted, the pipeline pauses and transitions to `gate: human` with an urgent attention notification.

---

## 4. Explicit Context Injection Model

### 4.1 The Four Tangible Context Sources

To eliminate the unpredictability of conversational multi-agent systems, Warren mandates that all inter-step communication be explicit and backed by physical filesystem or execution state:

| Context Source | Identifier | Description | Example Usage |
| :--- | :--- | :--- | :--- |
| **Input Source** | `${input}` | The raw trigger intent (issue body, URL, or CLI prompt). | `prompt: "Address issue: ${input}"` |
| **Physical Files** | `context.files` | Array of concrete file paths created by upstream steps or existing in the repo. | `files: ["docs/plan.md", "AGENTS.md"]` |
| **Accumulated Diff** | `context.diff` | The live Git diff between the current worktree `HEAD` and base commit. | `diff: true` (for reviewer agents) |
| **Command Output** | `${command.output}` | The combined `stdout`/`stderr` of a completed shell command step. | Used in `on_fail` retry prompts |

```text
[ Trigger Input ] ─────────────► ${input}
                                   │
                                   ▼
[ Step 1: Architect ] ────────► docs/plan.md (physical file)
                                   │
                                   ▼
[ Step 2: Coder ] ────────────► Git Worktree Commits / Dirty Edits
                                   │
                                   ▼
[ Step 3: Test Command ] ────► Exit Code 1 + Error Output (${command.output})
                                   │
                                   ├── (if failed: loop back to Step 2 with error)
                                   ▼ (if passed)
[ Step 4: Security Reviewer ] ◄─ context.diff (inspected independently)
```

### 4.2 Separation of Concerns via Independent Contexts

Each `agent` step runs with a **clean, focused prompt context** rather than inheriting hundreds of lines of intermediate chatter:
- **The Coder Agent** focuses strictly on writing functional code based on the task description and specified reference files;
- **The Test Step** runs deterministically on native host tooling;
- **The Reviewer Agent** is instantiated in a fresh, unpolluted context, receiving only the generated `git diff` and strict review criteria (e.g. concurrency safety, error handling, invariants from `AGENTS.md`). This overcomes LLM self-confirmation bias.

---

## 5. Declarative Pipeline Specification & Recipes

### 5.1 Project-Level Recipes (`.warren/pipelines/*.yaml`)

Pipelines can be stored in the repository under `.warren/pipelines/`. They are lightweight, human-readable YAML documents.

#### Example 1: Issue-to-Release Recipe (`issue-to-release.yaml`)
```yaml
version: 1
name: issue-to-release
description: "Resolve an issue in an isolated worktree, verify with tests, and ship a PR"
isolation: worktree

parameters:
  issue:
    type: string
    description: "Issue number or description"

steps:
  - id: dev
    name: "Implement Solution"
    agent:
      role: coder
      prompt: "Resolve the following issue cleanly: ${input}"
      context:
        files:
          - "AGENTS.md"

  - id: verify
    name: "Automated Test Suite"
    command: "go test -race ./..."
    on_fail:
      retry_with_agent:
        target: dev
        max_attempts: 3

  - id: review
    name: "Human Review Gate"
    gate: review

  - id: ship
    name: "Create Pull Request"
    command: "gh pr create --fill --head ${worktree.branch}"
```

#### Example 2: RFC-to-Product Recipe (`rfc-to-product.yaml`)
```yaml
version: 1
name: rfc-to-product
description: "Transform an RFC into architecture specs, code, and verified delivery"
isolation: worktree

steps:
  - id: spec
    name: "Architectural Planning"
    agent:
      role: architect
      prompt: "Read ${input} and write an implementation plan into .warren/plan.md."
      context:
        files:
          - "AGENTS.md"
          - "${input}"

  - id: dev
    name: "Feature Implementation"
    agent:
      role: coder
      prompt: "Implement the feature according to the plan in .warren/plan.md."
      context:
        files:
          - ".warren/plan.md"

  - id: test
    name: "Run Unit & Integration Tests"
    command: "go test ./..."
    on_fail:
      retry_with_agent:
        target: dev
        max_attempts: 3

  - id: audit
    name: "Adversarial Code Audit"
    agent:
      role: reviewer
      prompt: "Audit this diff for security, performance regressions, and style invariants."
      context:
        diff: true

  - id: review
    name: "Final Verification Gate"
    gate: review
```

### 5.2 Zero-Config Ad-Hoc Execution

If no pipeline recipe is specified, Warren executes in **Ad-Hoc Mode**:
```bash
warren run "Fix memory leak in spool watcher"
```
Under ad-hoc mode, Warren:
1. Automatically provisions `.worktrees/task-<slug>` and branch `task/<slug>`;
2. Detects the project toolchain (e.g., presence of `go.mod`, `package.json`, `Cargo.toml`, or `AGENTS.md`);
3. Executes a single `agent` implementation step;
4. Automatically runs the detected test suite (with 2 auto-repair iterations if tests fail);
5. Concludes at an interactive Review Gate.

---

## 6. UI/UX Design & Ergonomics

Warren's user experience adheres to the **Superset Ember Dark Theme**, Apple Human Interface Guidelines (HIG), and strict typographic restraint. All playful or low-density emojis are strictly forbidden. Visual hierarchy is established via typography (SF Pro / SF Mono), hairline borders (`muted/35`), quiet semantic status markers, and native SF Symbols.

### 6.1 The Four Core Touchpoints

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. The Launchpad (⌘K) ──► 2. In-Flight Cockpit ──► 3. Self-Repair ──► 4. Review Gate│
│    (0-Friction Start)        (Dual-Pane Stream)      (Diagnostics)    (1-Click Ship)│
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Touchpoint 1: The Launchpad Popover (HUD Style)
Invoked via `⌘K` or the project toolbar, presented as an ultra-thin elevated HUD popover:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│  warren / abcdlsj / warren                                                  │
│                                                                             │
│  Task Intent                                                                │
│  [ Fix #142: memory leak in spool watcher                                ]  │
│                                                                             │
│  PIPELINE RECIPE                       TARGET ISOLATION                     │
│  [ issue-to-release          ▾ ]       Branch:   task/spool-leak-142        │
│                                        Worktree: .worktrees/task-142        │
│                                                                             │
│  [x] Run automated test suite          [x] Stop at review gate              │
├─────────────────────────────────────────────────────────────────────────────┤
│  esc Cancel                                               ⏎ Launch Pipeline │
└─────────────────────────────────────────────────────────────────────────────┘
```
- **Smart URL Parsing**: Pasting a GitHub/GitLab issue URL automatically populates the task title, description, and issue reference.
- **Recipe Selection**: Seamlessly switches between ad-hoc execution and declared `.warren/pipelines/*.yaml` recipes.

#### Touchpoint 2: The In-Flight Cockpit (Data-Driven Layout)
When a pipeline runs, the main window transforms into a focused dual-pane engineering workbench. The stepper dynamically reflects the pipeline's configured steps:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ ⑂ task/spool-leak-142  ·  #142 Memory leak in spool watcher                 │
│                                                                             │
│ ● 1. Worktree   ──   ● 2. Implementation   ──   ◐ 3. Verification   ──   ○ 4. Review
│   .worktrees/task-142     3 files modified          Attempt 2/3 (tests)       Pending
├──────────────────────────────────────┬──────────────────────────────────────┤
│ TIMELINE & DIAGNOSTICS               │ LIVE WORKTREE DIFF (3 files, +38 -12)│
│                                      │                                      │
│ ✓ [Worktree] Allocated at a8f21c     │ spool.go  spool_test.go  types.go    │
│                                      │                                      │
│ ✓ [Dev Agent] Applied memory guard   │ @@ -45,8 +45,18 @@                   │
│   · Headless/internal/server/spool.go│   type Spool struct {                │
│   · Eviction queue bound to 256 frames│ +     ring       []Frame             │
│                                      │ +     maxFrames  int                 │
│ ⟳ [Verification] Attempt 1/3 (Fail)  │ -     frames     []Frame             │
│   ✖ go test ./...                    │                                      │
│     spool_test.go:88: timeout        │ + func (s *Spool) EvictOldest() {    │
│                                      │ +     s.mu.Lock()                    │
│ ⟳ [Verification] Attempt 2/3 (Active)│ +     defer s.mu.Unlock()            │
│   · Analyzing test timeout failure   │ +     // ...                         │
│   · Increasing ticker grace period   │                                      │
│                                      │                                      │
├──────────────────────────────────────┴──────────────────────────────────────┤
│ [ 💬 Steer (⌘J) ]    [ ⎋ Cancel Pipeline ]    [ ⌧ Open Terminal in Worktree (⌘T) ]
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Touchpoint 3: Interactive Super-Controls
1. **`Steer (⌘J)`**: Opens an inline prompt bar at the bottom. Injects instructions into the active agent step without resetting its scratchpad or breaking the pipeline flow.
2. **`Open Terminal in Worktree (⌘T)` (The Escape Hatch)**: Instantly splits the bottom pane with an authentic Ghostty PTY terminal rooted directly inside `.worktrees/task-142`. Developers can run `git status`, test manually, or inspect files with zero barrier between AI and manual workflows.
3. **`Cancel Pipeline (Esc)`**: Gracefully terminates running processes and prompts whether to retain or remove the worktree.

#### Touchpoint 4: The Review & Delivery Gate (The Polish Finisher)
Once all steps and verification checks succeed, the cockpit transitions into an actionable Review & Delivery sheet:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ ● Ready for Review · All 24 tests passed · 0 lint warnings · Elapsed: 2m 14s │
├─────────────────────────────────────────────────────────────────────────────┤
│ SUMMARY OF CHANGES                                                          │
│ • Enforced a 256-frame upper bound on terminal spool buffer to avoid leaks. │
│ • Added TestSpoolEviction suite covering buffer overflow under high load.   │
│                                                                             │
│ TOUCHED FILES                                                               │
│ [x] Headless/internal/server/spool.go                 +28  -8               │
│ [x] Headless/internal/server/spool_test.go            +45  -0               │
│ [x] Headless/internal/api/types.go                    +4   -1               │
│                                                                             │
│ REVIEW ACTIONS                                                              │
│ [ Create Pull Request (gh) ]      [ Merge to main ]      [ Discard Worktree ]
│ (Secondary: Keep Worktree as Workspace)                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```
- **Create Pull Request**: Automates branch pushing and invokes GitHub CLI (`gh pr create`) with a pre-filled, high-quality description.
- **Keep as Workspace**: Promotes the temporary worktree into a permanent Warren Workspace in the desktop sidebar for continued manual hacking.
- **Discard Worktree**: Executes `git worktree remove --force` cleanly, removing all temporary branches and storage.

### 6.2 Mobile (iOS) Experience Parity

- **Attention Notifications**: When a pipeline reaches `gate: review` or encounters an unresolvable test failure, a native push notification is delivered to the user's iOS device.
- **Portable Review Surface**: Opening Warren iOS displays the review sheet:
  - Collapsible summary card and test pass verification badge;
  - File diff inspector with syntax highlighting;
  - Bottom action bar: `[Approve & Ship]`, `[Steer / Leave Note]`, `[Discard]`.
  - Enables true *“dispatch on Mac, verify and ship on iPhone”* capability.

---

## 7. Protocol & Architecture

### 7.1 Protocol 2.0 Capability Negotiation

The autonomous pipeline engine is exposed over the Warren Protocol 2.0 WebSocket/HTTP interface via capability negotiation:
- `CapabilityPipelines = "pipelines-v1"`
- `CapabilityWorktreeManagement = "worktrees-v1"`

### 7.2 Message Types & Envelopes

#### 1. Start Pipeline (`pipeline.start`)
```json
{
  "t": "pipeline.start",
  "requestId": "req-101",
  "project": "proj-uuid",
  "recipe": "issue-to-release",
  "input": "Fix #142: memory leak in spool watcher",
  "isolation": "worktree",
  "options": {
    "autoTest": true,
    "stopAtGate": true
  }
}
```

#### 2. Live Pipeline Status (`pipeline.status`)
Broadcast to clients to power the dynamic stepper:
```json
{
  "t": "pipeline.status",
  "pipelineId": "pipe-uuid",
  "status": "working",
  "currentStepIndex": 2,
  "steps": [
    { "id": "dev", "name": "Implement Solution", "state": "completed", "durationMs": 34200 },
    { "id": "verify", "name": "Automated Test Suite", "state": "running", "attempt": 2, "maxAttempts": 3 },
    { "id": "review", "name": "Human Review Gate", "state": "pending" }
  ],
  "worktree": {
    "path": "/path/to/.worktrees/task-142",
    "branch": "task/spool-leak-142",
    "filesChanged": 3,
    "additions": 38,
    "deletions": 12
  }
}
```

#### 3. Resolve Gate (`pipeline.gate.resolve`)
```json
{
  "t": "pipeline.gate.resolve",
  "pipelineId": "pipe-uuid",
  "stepId": "review",
  "decision": "approve",
  "action": "create_pr"
}
```

---

## 8. Acceptance Criteria

1. **Zero-Configuration Run**: Executing `warren run "<prompt>"` in a valid Git repository successfully allocates a worktree, completes the implementation, runs detected tests, and renders a diff without requiring any configuration files.
2. **Worktree Isolation**: At no point during pipeline execution are uncommitted changes or branch pointers in the user's primary working directory modified or deleted.
3. **Context Injection Correctness**:
   - Explicit `context.files` are available to downstream agents.
   - Command failure outputs (`stderr`/`stdout`) are verbatim forwarded into the retry prompt of the target agent.
   - Diff contexts for reviewer agents accurately match `git diff HEAD~1` within the worktree.
4. **Bounded Self-Repair**: Failing commands trigger agent repairs up to `max_attempts`; exceeding this threshold reliably suspends the pipeline in `needs_attention` without crashing.
5. **Terminal Escape Hatch**: Activating `Open in Terminal` spawns a native PTY session initialized to the worktree root path with valid environment variables.
6. **Clean Teardown**: Selecting `Discard Worktree` removes the worktree via `git worktree remove` and prunes temporary branch references cleanly.

---

## 9. References

- [RFC 0004: Headless Flow Orchestration (Abandoned)](0004-headless-flow-orchestration.md)
- [RFC 0006: Agent Activity and Attention](0006-agent-activity-attention.md)
- [RFC 0010: Agent View Presentation Parity in iOS/Web](0010-ios-agent-view-presentation-parity.md)
- [RFC 0013: Dual-track Agent Architecture and PTY Guarding](0013-agent-interaction-architecture-and-pty-guarding.md)
- [RFC 0015: Cloud Agent Daemon and Scheduled Bots (Pending)](0015-cloud-agent-daemon-and-scheduled-bots.md)
