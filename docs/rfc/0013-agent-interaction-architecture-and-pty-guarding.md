# RFC 0013: Dual-track Agent architecture, PTY input guardrails, and active attention surfacing

- Status: Proposed
- Owner: Warren Headless, Desktop, Web, and iOS
- Created: 2026-09-03
- Scope: Agent driver architecture, PTY write safety, and cross-platform attention surfacing
- Protocol baseline: Warren protocol 2.0 with capability negotiation
- Depends on: RFC 0006 (Agent activity and attention), RFC 0010 (iOS/Web presentation parity), RFC 0011 (Cloud Agent runs)

---

## 1. Summary

This RFC establishes the foundational architectural resolution for running AI coding agents inside Warren without compromising either the **native terminal experience** or the **rich Agent View**.

It addresses the fundamental trilemma among:
1. **Terminal-First Native TUI** (real PTY, zero latency, raw shortcuts, vendor themes/animations);
2. **Structured Rich-Text Agent View** (clean Markdown, collapsible thinking trees, tool call cards, diffs);
3. **Standardized Bidirectional Protocol** (ACP / JSON-RPC 2.0).

To build a reliable foundation while the codebase is still young, this RFC introduces three concrete pillars:

1. **The Dual-Track Driver Architecture**:
   - **Track 1 (Interactive TUI Sessions)**: PTY is the sole input and display authority. Transcript parsing is treated strictly as an asynchronous, read-only sidecar observer.
   - **Track 2 (Autonomous / Cloud Runs)**: Headless execution via standardized Agent Client Protocol (ACP) over stdio or WebSocket, with no PTY allocation.
2. **PTY Write Guardrails & Input Protection**:
   - Eliminates blind keystroke injection into PTYs.
   - Enforces a status-based prompt mutex (`agent_blocked` error when attention or approval is pending).
   - Enforces terminal Bracketed Paste Mode for all prompt submissions.
   - Implements deterministic approval gates via blocking hook IPC where supported, and honest fallback to terminal keyboard input when unsupported.
3. **Active Attention Surfacing for Small / Folded Interfaces (iOS & Mobile)**:
   - Extends RFC 0006 by introducing a Host-wide `host.attention` broadcast stream.
   - Specifies a root-level floating attention pill/banner that penetrates deep navigation stacks.
   - Implements one-tap deep-link routing from alerts directly to blocked interaction cards.
   - Adds badge cascading on back buttons and drawer menus, plus background local notifications.

---

## 2. Motivation & The Architectural Trilemma

### 2.1 The Upstream Reality

Current state-of-the-art coding agent CLIs (such as Claude Code, Codex, and OpenCode) are monolithic TUI applications. They bind their internal state machine, LLM streaming, and terminal rasterization (via curses, Ink, or Ratatui) into a single process.

- Their `stdout` is dedicated to ANSI escape sequences for human viewing;
- They do not emit structured event streams over a public secondary channel while running in interactive TUI mode;
- The only structured persistence they produce is their private on-disk session transcript (e.g., JSONL or SQLite).

This creates an inherent **trilemma**:

```text
                  [A] Native TUI Experience (Terminal-First)
                            ▲
                           / \
                          /   \
                         /     \
                        /       \
[B] Structured Rich Agent View  ◄─────►  [C] Clean Bidirectional Protocol (ACP)
```

1. **Choosing [A] + [C] (Native TUI + Clean Protocol, sacrificing Agent View)**:
   - Exemplified by terminal multiplexers like **Herdr**.
   - Inspects raw PTY screen buffers and regex-matches bottom lines to produce coarse state badges (`working`, `blocked`, `idle`).
   - **Fatal Flaw for Warren**: Cannot power an Agent View. It cannot reconstruct clean Markdown, multi-turn conversation trees, or tool parameters from an ANSI byte stream without severe parsing fragility, high CPU overhead from spinner animations, and tearing issues.
2. **Choosing [B] + [C] (Rich Agent View + Clean Protocol, sacrificing Native TUI)**:
   - Exemplified by **Zed with ACP**, Cursor, and standalone web chats.
   - Runs the agent as a headless background RPC daemon via ACP.
   - **Fatal Flaw for Warren**: Destroys Warren's terminal-first identity. Users cannot switch tabs to interact with Claude's native curses UI, slash commands, or local terminal bindings.
3. **Choosing [A] + [B] (Native TUI + Rich Agent View, compromising Protocol)**:
   - Warren's historical approach: Run CLI in a real PTY, tail disk transcripts for the Agent View, and inject simulated keystrokes into the PTY for interactive approvals.
   - **Fatal Flaw**: An asymmetrical communication architecture. Reading is structured (JSONL), but writing is chaotic (blind PTY string injection). An errant keystroke or race condition easily corrupts terminal state.

### 2.2 The Resolution

Warren will not attempt to force every session into all three vertices. Instead, Warren explicitly bifurcates its execution into **two distinct, first-class tracks**, and hardens the interactive track against input corruption.

---

## 3. Detailed Design

### 3.1 Dual-Track Architecture & Driver Model

Session execution is separated into two explicit driver categories:

```text
                               Warren Host
                                    │
           ┌────────────────────────┴────────────────────────┐
           ▼                                                 ▼
[ Track 1: TUI Interactive Session ]             [ Track 2: Autonomous Cloud Run ]
  Driver: TUIAgentDriver                           Driver: ACPAgentDriver
  ───────────────────────────────                  ───────────────────────────────
  • PTY: Required (Host PTY Master)                • PTY: None (Headless process)
  • Display Authority: Raw PTY terminal            • Display Authority: Agent View canvas
  • Semantic Source: Transcript tailer             • Semantic Source: ACP JSON-RPC 2.0
  • Capabilities:                                  • Capabilities:
      - timeline: true (observed)                      - timeline: true (native)
      - interactions: hook-only / false                - interactions: true
      - interrupt: true (SIGINT / 0x03)                - interrupt: true (RPC interrupt)
      - attachments: true (filesystem path)            - attachments: true (native bytes/URI)
```

#### 3.1.1 Capability Set Contracts

A Session must advertise only the capabilities its underlying driver can actually execute safely:

```go
type Capability string

const (
    CapabilityAgentTimeline     Capability = "timeline"
    CapabilityAgentInteractions Capability = "interactions"
    CapabilityAgentInterrupt    Capability = "interrupt"
    CapabilityAgentAttachments  Capability = "attachments"
)
```

- If `CapabilityAgentInteractions` is absent, clients (Web, iOS, Desktop) **must disable interactive form submissions** in the Agent View and instruct the user: `"Respond directly in the terminal."`
- Under no circumstances will Warren pretend to support structured interactions by blindly translating form submissions into PTY keystrokes.

---

### 3.2 PTY Input Guardrails & Write Safety

For `TUIAgentDriver` sessions, the PTY write pathway must be strictly protected against input collisions, form corruption, and premature command execution.

#### 3.2.1 Status Mutex Guard (Prompt Blocker)

Before transmitting prompt text to a PTY runtime, the Host verifies the session's active `AgentStatus` (defined in RFC 0006):

```go
func (s *Service) sendAgentMessage(ctx context.Context, req api.AgentMessageSendRequest) (api.AgentMessageSendResult, error) {
    status := s.sessionAgentStatus(req.Session)
    
    // Guard 1: Do not inject text if the terminal is blocked on human attention
    if status.Activity == api.AgentActivityBlocked || status.Attention != nil {
        return api.AgentMessageSendResult{}, api.ErrAgentBlocked
    }
    
    // Guard 2: If the turn is actively working, reject or queue deterministically
    if status.Activity == api.AgentActivityWorking {
        if !s.sessionSupportsCapability(req.Session, CapabilityAgentQueue) {
            return api.AgentMessageSendResult{}, api.ErrAgentBusy
        }
    }
    
    return s.dispatchAgentMessage(ctx, req)
}
```

When `api.ErrAgentBlocked` is returned, the client presents an explicit toast:
> *"Agent is currently awaiting an answer in the terminal. Resolve the prompt or cancel it before sending a new message."*

#### 3.2.2 Terminal Bracketed Paste Mode Framing

All multi-line prompts and user messages sent to a PTY must be framed using ANSI Bracketed Paste sequences:

- Opening sequence: `\x1b[200~`
- Content: Normalized text (newlines converted to `\r`)
- Closing sequence: `\x1b[201~`
- Submission trigger: `\r` (or modern Kitty keyboard protocol enter `\x1b[13u`)

```go
func sendAgentMessageInput(ctx context.Context, runtime Runtime, sessionID, text string) error {
    var buf bytes.Buffer
    buf.WriteString("\x1b[200~")
    buf.WriteString(strings.ReplaceAll(text, "\n", "\r"))
    buf.WriteString("\x1b[201~\r")
    return runtime.Input(ctx, sessionID, buf.Bytes())
}
```

This prevents terminal readline implementations from interpreting tabs as autocomplete triggers or newlines as premature execution commands.

---

### 3.3 Deterministic Interaction Interception

To support structured approvals (Permission / Question cards) in Track 1 sessions without injecting simulated keystrokes into the PTY:

#### 3.3.1 The Blocking Hook Gate (For Hook-Enabled Agents)

For agents supporting pre-execution hooks (e.g., Claude Code's `PreToolUse` or custom extensions):

```text
[ Agent CLI in PTY ]
         │
         │ (evaluating tool call)
         ▼
[ Warren Hook Script ] ─── Unix Domain Socket RPC ───► [ Warren Headless ]
(Process paused, waiting)                                      │
                                                               ▼
                                                    [ Broadcasts Attention ]
                                                               │
                                                               ▼
[ User Clicks "Approve" on Web/iOS ] ─── RPC ────────► [ Releases Hook Gate ]
                                                               │
                                                               ▼
[ Hook exits with code 0 ] ◄───────────────────────────────────┘
         │
         ▼
[ Agent CLI continues execution ]
```

1. Warren configures the agent's native hook to invoke a lightweight binary or script with `WARREN_SESSION_ID` and `WARREN_SOCKET_PATH`.
2. The hook script connects to Warren's local Unix Domain Socket and sends a `tool_permission_request` message containing the tool name and arguments.
3. The hook process **blocks synchronously**, waiting for Warren's response.
4. Warren emits an RFC 0006 `AgentStatus` with `attention: { kind: "approval", requestId: "..." }`.
5. When the user approves in the GUI, Warren sends an approval packet over the socket.
6. The hook script exits with status `0` (allow) or `1` (deny).
7. **Zero keystrokes are written to the PTY.** The terminal stays completely clean and free of input races.

#### 3.3.2 Fallback for Unhooked CLIs

If an agent CLI does not support blocking pre-tool hooks:
- Warren detects the blocked condition via transcript/activity heuristics;
- Warren displays the attention state in the GUI;
- Warren explicitly renders the GUI card with a note:
  > *"This agent does not support out-of-band approvals. Please switch to the Terminal tab to confirm."*
- PTY keystroke simulation is strictly disallowed.

---

### 3.4 Active Attention Surfacing for Small / Folded Interfaces

RFC 0006 established the status and attention data model (`ready | working | blocked | stalled | failed | exited` and `attention: input | approval | warning`). On desktop displays with horizontal sidebars, visual dot indicators are sufficient.

On mobile devices (iOS) and collapsed sidebar layouts, deep navigation hierarchies conceal blocked sessions. This section specifies the proactive surfacing mechanism.

#### 3.4.1 Host-Wide Attention Event Stream

Warren Headless will broadcast attention transitions over the primary client connection:

```json
{
  "event": "host.attention",
  "sessionId": "ses_019543ab",
  "workspaceId": "ws_core_api",
  "terminalGroupId": "tg_main",
  "agentKind": "claude",
  "agentName": "Reviewer",
  "attention": {
    "kind": "approval",
    "reason": "permission",
    "requestId": "call_987",
    "title": "Bash command approval",
    "summary": "Execute 'git push origin main --force'?",
    "since": "2026-09-03T15:30:00Z"
  }
}
```

When an attention condition is resolved, `host.attention` is emitted with `"attention": null`.

#### 3.4.2 Root-Level Floating Attention Banner / Pill

iOS and mobile Web clients must register a persistent listener at the application root window level, outside any nested navigation stack or sheet.

1. **Presentation**:
   - Slides down from the top safe area when a new `host.attention` event arrives for a session other than the currently active, focused view.
   - Styled with Warren Amber/Warning tokens, showing agent name, icon, and truncated summary.
   - Includes a direct dismiss/snooze swipe gesture.
2. **Deep-Link Navigation (One-Tap Routing)**:
   - Tapping the banner triggers immediate navigation:
     `Workspace -> Tab / Terminal Group -> Session -> Scroll to Attention Card`.
3. **Badge Cascading**:
   - When the user navigates within the app, any parent navigational element leading to a blocked session (e.g., `< Back` button in navigation bars, hamburger menu icon) displays an amber breathing badge until all attention items within that branch are resolved.
4. **Local Notifications (Background Mode)**:
   - If the iOS application is in the background or device is locked, an incoming `host.attention` event triggers an iOS system `UNNotificationRequest` with sound:
     - Title: `[Reviewer] Permission Request`
     - Body: `Execute 'git push origin main --force'?`
     - UserInfo payload: `{"sessionId": "ses_019543ab", "action": "focus_attention"}`.

---

## 4. Security & Isolation Considerations

1. **No Sensitive Content in Global Events**:
   - `host.attention` payloads must contain only sanitized summaries and permission titles. Full command outputs, file contents, and environment credentials must never appear in global attention broadcasts.
2. **Local Socket Permission**:
   - The Unix Domain Socket (`WARREN_SOCKET_PATH`) used by blocking hook scripts must be restricted to file mode `0600` (owned by the Warren user) to prevent local cross-user tampering.
3. **Idempotent Token Verification**:
   - Every approval request dispatched through the socket must carry a unique `requestId` and session verification nonce.

---

## 5. Non-Goals

- Eliminating disk transcripts for existing stock Claude/Codex TUI sessions (it remains the only source of truth for their rich timeline in Track 1).
- Reverse-engineering ANSI escape sequences to rebuild chat bubbles from raw PTY output (Herdr-style screen parsing).
- Forcing ACP compliance onto external CLI binaries that do not natively support it.

---

## 6. Implementation Roadmap

1. **Phase 1: PTY Guardrails (Headless)**
   - Add status check mutex in `Headless/internal/server/agent_view.go`.
   - Implement Bracketed Paste Mode framing in `sendAgentMessageInput`.
   - Reject plain text message sends when session is in `attention` or `blocked` state.
2. **Phase 2: Provider & Driver Contract Refactor (Headless)**
   - Finalize `AgentProvider` and `AgentHandle` in `Headless/internal/server/agent_provider.go`.
   - Separate `TUIAgentDriver` (Track 1) and stub `ACPAgentDriver` (Track 2).
   - Enforce typed capability negotiation (`CapabilityAgentInteractions`).
3. **Phase 3: Active Attention Surfacing (Headless + iOS/Web)**
   - Add `host.attention` event broadcaster in Headless.
   - Implement root `AttentionBannerView` in `Packages/WarrenIOS`.
   - Wire deep-link routing and badge cascading.
