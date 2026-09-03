# RFC 0012: Antigravity CLI Agent Support

- Status: Proposed
- Owner: Warren Headless, Web, Desktop, and CLI clients
- Created: 2026-09-03
- Scope: First-class `antigravity-cli` (`agy`) interactive agent integration
- Protocol baseline: Warren protocol 2.0
- Depends on: RFC 0006 (Agent activity and attention), RFC 0010 (Agent view presentation parity)

---

## 1. Summary

Warren will add first-class support for **Antigravity CLI** (`agy`), enabling users to launch, inspect, and monitor Antigravity agent sessions across all Warren surfaces (macOS Desktop, Web/PWA, and CLI).

Like Warren's existing Codex, Claude Code, OpenCode, and Qoder integrations, Antigravity CLI runs in the Host's durable PTY as the execution authority. Warren binds the session to the external CLI conversation, watches the JSONL transcript emitted by the Antigravity engine, normalizes it into structured `AgentEvent` streams over WebSocket protocol 2.0, and drives the conversation view, attention lights, and automatic session title generation without sacrificing terminal fidelity.

---

## 2. Motivation & Background

### 2.1 The Antigravity CLI Architecture
Antigravity CLI (`agy`) is Google's terminal-based AI pair programming tool. Key properties relevant to Warren:

1. **Execution & Command Binary**:
   - Binary name: `agy` (installed to `~/.local/bin/agy` or available in `$PATH`).
   - Interactive prompt launch: `agy -i "<prompt>"` or `agy --prompt-interactive "<prompt>"`. Runs an initial prompt while keeping the session open in the interactive TUI.
   - Non-interactive / print flags: `-p`, `--print`, `--prompt`, `--input-format`, `--output-format`. These run headlessly or output NDJSON and must be disallowed for Warren terminal sessions.
   - Session reuse flags: `--conversation <id>`, `-c`, `--continue`. These resume past sessions and must be disallowed during initial session creation to prevent detached conversations.

2. **Data Storage & Directory Structure**:
   - Config directory: `~/.gemini/config/`
   - Application data directory: `~/.gemini/antigravity-cli/`
   - Conversations:
     - SQLite storage: `~/.gemini/antigravity-cli/conversations/<conversation-id>.db`
     - Global metadata: `~/.gemini/antigravity-cli/conversation_summaries.db` (contains `conversation_id`, `workspace_uris`, `last_modified_time`, `title`).
     - Transcript directory: `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl` (compact) and `transcript_full.jsonl` (untruncated).

3. **Lifecycle Hooks Contract**:
   Antigravity CLI discovers lifecycle hooks from `~/.gemini/config/hooks.json` (global) or `.agents/hooks.json` (workspace).
   - Hook events: `PreInvocation`, `PostInvocation`, `Stop`, `PreToolUse`, `PostToolUse`.
   - Payload delivered over `stdin`:
     ```json
     {
       "conversationId": "3241a15e-a251-4809-8627-9891e518ece8",
       "workspacePaths": ["/Users/user/workspace/repo"],
       "transcriptPath": "/Users/user/.gemini/antigravity-cli/brain/3241a15e-a251-4809-8627-9891e518ece8/.system_generated/logs/transcript.jsonl",
       "artifactDirectoryPath": "/Users/user/.gemini/antigravity-cli/brain/3241a15e-a251-4809-8627-9891e518ece8",
       "modelName": "auto"
     }
     ```
   - Exit output: JSON object over `stdout` (e.g. `{}`).
   - Environment inheritance: Child hook commands run via `sh -c` and inherit process environment variables, including `WARREN_SESSION_ID`, `WARREN_BIND_FILE`, and `WARREN_STATE_FILE`.

---

## 3. Architecture & Integration Design

```text
Warren Host PTY (injected env: WARREN_SESSION_ID, WARREN_BIND_FILE, WARREN_STATE_FILE)
  │
  ├──> Launches `agy` (Interactive TUI) ──────────> Ghostty / xterm Terminal Surface
  │
  ├──> Antigravity Lifecycle Hook (PreInvocation)
  │      │
  │      ├──> Reads {conversationId, transcriptPath} from stdin
  │      └──> Atomically writes to $WARREN_BIND_FILE:
  │             {"provider":"antigravity","sessionId":"...","transcriptPath":"...","cwd":"..."}
  │
  └──> Warren Headless Watcher
         │
         ├──> Tails ~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl
         ├──> `parseAntigravity`: normalizes to []api.AgentEvent (message, reasoning, tool_call, tool_output)
         ├──> `ActivityTracker`: marks lifecycle (working, ready, blocked, stalled)
         └──> WebSocket protocol 2.0 ──────────────> Desktop & Web Agent Conversation View
```

### 3.1 Session Lifecycle & Binding Strategy

Every Warren session receives runtime environment variables injected by `BindEnvironment`:
- `WARREN_SESSION_ID`: Warren durable session UUID.
- `WARREN_BIND_FILE`: `~/.warren/agent-bind/<session-id>.json`.
- `WARREN_STATE_FILE`: `~/.warren/agent-bind/<session-id>.state`.
- `WARREN_AGENT_KIND`: `antigravity`.

#### Primary Binding Path: Managed Hook
1. During daemon startup or session preflight, Warren calls `EnsureAntigravityBindHook(configDir)`.
2. It merges a Warren hook entry into `~/.gemini/config/hooks.json` under key `"warren-bind"`:
   ```json
   {
     "warren-bind": {
       "PreInvocation": [
         {
           "type": "command",
           "command": "bash '/Users/.../.warren/hooks/agent-bind.sh' warren-agent-bind-v1 antigravity"
         }
       ],
       "Stop": [
         {
           "type": "command",
           "command": "bash '/Users/.../.warren/hooks/agent-bind.sh' warren-agent-bind-v1 antigravity"
         }
       ]
     }
   }
   ```
3. When `PreInvocation` fires:
   - The hook extracts `conversationId` and `transcriptPath` from `stdin`.
   - It writes `{provider: "antigravity", sessionId, transcriptPath, cwd, updatedAt}` to `$WARREN_BIND_FILE`.
   - It updates `$WARREN_STATE_FILE` with activity `"working"`.
   - It prints `{}` to `stdout` and exits 0.
4. When `Stop` fires:
   - The hook updates `$WARREN_STATE_FILE` with activity `"ready"`.
   - It prints `{}` to `stdout` and exits 0.

#### Secondary Fallback Path: CWD + Metadata Scanning
If hooks are disabled or `agy` is started manually in an unmanaged shell:
1. Warren checks `~/.gemini/antigravity-cli/conversation_summaries.db`.
2. It executes:
   ```sql
   SELECT conversation_id, workspace_uris, last_modified_time 
   FROM conversation_summaries 
   WHERE workspace_uris LIKE '%<workspacePath>%' 
     AND last_modified_time >= ? 
   ORDER BY last_modified_time DESC LIMIT 1;
   ```
3. If matched, the transcript path is resolved to:
   `~/.gemini/antigravity-cli/brain/<conversation_id>/.system_generated/logs/transcript.jsonl`.

---

### 3.2 Command Validation Rules

The CLI launcher and Host API validate `command` before spawning:

```go
var antigravitySessionReuseFlags = map[string]bool{
    "--conversation": true,
    "--continue":     true,
    "-c":             true,
}

var antigravityNonInteractiveFlags = map[string]bool{
    "-p":              true,
    "--print":         true,
    "--prompt":        true,
    "--input-format":  true,
    "--output-format": true,
}
```

1. **Empty Command**: Defaults to `agy`.
2. **Session Reuse**: Any command containing `--conversation`, `-c`, or `--continue` is rejected with:
   `"Antigravity command must start a new session; session resume flags are not supported"`.
3. **Non-Interactive Modes**: Any command containing `-p`, `--print`, or `--prompt` without `-i` is rejected with:
   `"Antigravity command must use interactive mode; print and non-interactive flags are not supported"`.
4. **Shell Safety**: Reject commands containing shell operators (`;`, `&&`, `|`, `` ` ``, `$`).

---

### 3.3 Transcript Normalization Specification

Antigravity CLI emits newline-delimited JSON records (`transcript.jsonl`) with this base schema:

```json
{
  "step_index": 1,
  "source": "USER_EXPLICIT" | "MODEL" | "SYSTEM",
  "type": "USER_INPUT" | "PLANNER_RESPONSE" | "GENERIC" | "SYSTEM_MESSAGE",
  "status": "DONE" | "ERROR",
  "created_at": "2026-09-03T05:12:12Z",
  "content": "...",
  "thinking": "...",
  "tool_calls": [
    {
      "name": "view_file",
      "args": { "AbsolutePath": "/path/to/file" }
    }
  ]
}
```

#### Event Mapping Table

| Antigravity Step | Parsed Warren `api.AgentEvent` | Lifecycle / Tracker Effect |
| :--- | :--- | :--- |
| `type: "USER_INPUT"` | `Type: "message", Role: "user"`<br>Strip `<USER_REQUEST>` tags to obtain pure prompt | `tracker.TurnStarted()`, Status: `working` |
| `type: "PLANNER_RESPONSE"` with `thinking` | `Type: "reasoning", Content: thinking` | Preserved in timeline for agent view reasoning drawer |
| `type: "PLANNER_RESPONSE"` with `tool_calls` | `Type: "tool_call", ToolName: tc.Name, ToolInput: tc.Args, CallID: fmt.Sprintf("%d_%d", step_index, i)` | `tracker.toolStarted()`, Pending call ID pushed to FIFO queue |
| `type: "GENERIC"` (Tool result) | `Type: "tool_output", ToolName, Output: content, Error: (if status == "ERROR"), ToolStatus: completed/error` | Matches head of FIFO queue, `tracker.toolFinished()` |
| `type: "PLANNER_RESPONSE"` with `content` | `Type: "message", Role: "assistant", Content: content, StopReason: "stop"` | If final text turn, `tracker.TurnComplete()`, Status: `ready` |
| `tc.Name == "ask_question"` | Normalizes to RFC 0010 structured `question` event | Status: `blocked`, `attention: { kind: "input", reason: "question" }` |

#### Cleaning User Prompts
Antigravity wraps user messages with metadata blocks:
```text
<USER_REQUEST>
Actual user question here
</USER_REQUEST>
<ADDITIONAL_METADATA>...</ADDITIONAL_METADATA>
```
The parser extracts only the text between `<USER_REQUEST>` and `</USER_REQUEST>`. If tags are absent, the trimmed raw content is preserved.

---

### 3.4 Attention & Activity Tracking

1. **Turn Boundaries**:
   - Starting a turn: `USER_INPUT` triggers `TurnStarted()` (activity `working`).
   - Ending a turn: `PLANNER_RESPONSE` containing assistant message without subsequent tool calls triggers `TurnComplete()` (activity `ready`).
2. **Blocked on Input / Approval**:
   - If `PreToolUse` observes an interactive tool (e.g. `ask_question`), or the transcript contains an `ask_question` tool call:
     Status becomes `blocked` with `attention: { kind: "input", reason: "question" }`.
   - When the corresponding `GENERIC` tool result arrives, attention is cleared and status transitions back to `working`.
3. **Session Exited**:
   - When the `agy` process terminates or a `Stop` hook with terminal exit occurs, activity transitions to `ready` or `exited`.

---

## 4. Subsystem Implementation Breakdown

### 4.1 Go Daemon & Agent Core (`Headless/internal/`)

1. **`Headless/internal/agent/antigravity.go`** (New File):
   - `ValidateAntigravityCommand(command string) error`
   - `AntigravityHome() string`, `AntigravityConfigDir() string`
   - `FindAntigravityTranscript(sessionID, workspacePath string) string`
   - `EnsureAntigravityBindHook(configDir string) (bool, error)`
   - `parseAntigravity(line []byte) []api.AgentEvent`
   - `cleanAntigravityUserContent(content string) string`
2. **`Headless/internal/agent/transcript.go`**:
   - In `newParserWithContentLimit`: initialize `antigravityCallTool` and `antigravityPendingCalls`.
   - In `parseLine`: add `case "antigravity": return p.parseAntigravity(line)`.
   - In `DefaultFinder.Find`: add `case "antigravity": return f.findAntigravity(...)`.
3. **`Headless/internal/agent/binding.go`**:
   - Add `"antigravity"` to `BindEnvironment`:
     ```go
     if kind == "codex" || kind == "claude" || kind == "antigravity" {
         entries = append(entries, BindEnvKind+"="+kind)
     }
     ```
   - Support `antigravity` in `agentBindHookScript` for JSON hook inputs.
4. **`Headless/internal/agent/read.go`**:
   - In `ReadTranscript`: permit `provider == "antigravity"`.
5. **`Headless/internal/server/service.go`**:
   - In `CreateSession`: handle `kind == "antigravity"` (default command `agy`, validation, display title `"Antigravity"`).
   - In `ensureAgentWithState`: add `antigravity` handling for dedicated sessions and shell overlays.
   - In `boundTranscript`: support `binding.Provider == "antigravity"`.
   - Register `session.Kind == "antigravity"` in all dedicated agent guards (`isDedicatedAgent`, auto title triggers).

### 4.2 Warren CLI (`Headless/cmd/warren/`)

1. **`Headless/cmd/warren/main.go`**:
   - Update `agentCreateCommand`: allow `--provider antigravity`.
   - Update `appendAgentInitialPromptForProvider`:
     ```go
     if strings.EqualFold(strings.TrimSpace(provider), "antigravity") {
         return command + " -i " + shellQuote(prompt)
     }
     ```
   - Update usage text and flag validation maps to recognize `antigravity`.

### 4.3 macOS Desktop (`Packages/Domain/`, `Packages/Desktop/`)

1. **`Packages/Domain/Sources/WarrenDomain/Models.swift`**:
   - Add `case antigravity` to `TerminalSessionKind`.
   - In `displayName`: `case .antigravity: "Antigravity"`.
   - In `TerminalSessionLaunchRequest`: add `public static let antigravity = Self(kind: .antigravity, command: "agy")`.
2. **`Packages/Domain/Sources/WarrenDomain/TerminalDisplayTitle.swift`**:
   - Add `case "antigravity": "Antigravity"`.
3. **`Packages/Desktop/Sources/WarrenDesktop/WarrenDesktopSessionPreset.swift`**:
   - Add `Self(id: "antigravity", title: "Antigravity", subtitle: "Launch the agy CLI in this project", symbolName: "globe", createButtonTitle: "Start Antigravity", request: .antigravity, isPinned: true)` to `builtIns`.
   - Map `presetBarTitle`: `"Antigravity"`.
   - Map `presetBarIconName`: `"preset-antigravity"`.
   - In `isAI`: include `.antigravity`.
4. **`Packages/Desktop/Sources/WarrenDesktop/WarrenDesktopPresetBarView.swift` & `WarrenDesktopSettingsView.swift`**:
   - Add `@AppStorage(WarrenPreferenceKey.presetCommandAntigravity)` override support (defaulting to `"agy"`).
5. **`Packages/Desktop/Sources/WarrenDesktop/Resources/preset-antigravity.svg`**:
   - Add desktop SVG artwork.

### 4.4 Web Client (`Web/`)

1. **`Web/src/session.js`**:
   - `defaultPresetCommands`: `antigravity: "agy"`.
   - `sessionPresets`: `{ kind: "antigravity", label: "Antigravity", title: "Antigravity", isAgent: true }`.
   - `isAgentSession`: `|| kind === "antigravity"`.
2. **`Web/src/title.js`**:
   - `kindLabels`: `antigravity: "antigravity"`.
   - `tabPurpose`: include `|| kind === "antigravity"`.
3. **`Web/public/preset-antigravity.svg`**:
   - Add Web preset vector icon.
4. **`Web/src/components.jsx`**:
   - Add `"antigravity"` to preset search keywords.

---

## 5. Verification Strategy & Test Cases

Any engineer picking up this task should verify changes against this test matrix:

### 5.1 Unit Tests (Go)

- **Command Validation (`Headless/internal/agent/antigravity_test.go`)**:
  - Valid commands: `agy`, `agy -i "fix bug"`, `agy --model gemini-2.5-pro`.
  - Rejected reuse flags: `agy --conversation 123`, `agy -c`, `agy --continue`.
  - Rejected non-interactive flags: `agy -p "hi"`, `agy --print "hi"`, `agy --output-format json`.
  - Rejected syntax: shell operators (`;`, `&&`, `|`, etc.).
- **Hook Idempotency (`Headless/internal/agent/antigravity_test.go`)**:
  - Install hook into empty / non-existing `hooks.json`.
  - Install hook into `hooks.json` that already contains existing user hooks. Ensure user hooks are untouched.
  - Run repeated installs; ensure no duplicate entries are appended.
- **Transcript Parser (`Headless/internal/agent/antigravity_test.go`)**:
  - Test synthetic `testdata/antigravity-v1.jsonl` fixture containing:
    1. `USER_INPUT` wrapped in `<USER_REQUEST>`: verify content is cleaned.
    2. `PLANNER_RESPONSE` with `thinking`: verify reasoning event emitted.
    3. `PLANNER_RESPONSE` with 2 `tool_calls`: verify both `tool_call` events emitted with distinct CallIDs.
    4. Two subsequent `GENERIC` tool outputs: verify correct pairing to prior CallIDs.
    5. Final `PLANNER_RESPONSE` assistant text: verify `assistant` event and `TurnComplete` status.
- **Server Integration (`Headless/internal/server/`)**:
  - Dedicated Antigravity session creation returns `Session.Kind == "antigravity"`, default title `"Antigravity"`.
  - Automatic session title generation: triggers on first user + assistant exchange.
  - Shell adoption: starting `agy` in a plain shell updates session with `agentSessionId` and agent status overlay.

### 5.2 Client Tests (Web & Desktop)

- **Web Unit Tests (`node --test Web/src/*.test.js`)**:
  - Verify `normalizeSessionPresetOrder` and `loadSessionPresetOrder` include `"antigravity"`.
  - Verify `isAgentSession({ kind: "antigravity" }) === true`.
  - Verify preset bar renders the Antigravity button and icon.
- **Desktop Tests (`swift test`)**:
  - Verify `TerminalSessionKind.antigravity` roundtrips through JSON encoding/decoding.
  - Verify `WarrenDesktopSessionPreset.builtIns` contains `"antigravity"` and `isAI == true`.

### 5.3 Live Artifact & E2E Validation

1. **CLI Agent Create**:
   ```bash
   warren agent create --provider antigravity --prompt "inspect README.md"
   ```
   - Verify `agy` launches inside Ghostty PTY.
   - Verify `$WARREN_BIND_FILE` is written to `~/.warren/agent-bind/<session-id>.json`.
2. **Web / Desktop Conversation View**:
   - Open Web UI (`http://localhost:3000`) or Warren macOS Desktop app.
   - Open the Antigravity tab: verify user message, thinking drawer, and tool call outputs appear incrementally.
   - Verify session title updates automatically from the prompt.
3. **Shell Overlay Adoption**:
   - Open an interactive Shell tab.
   - Type `agy`.
   - Verify the tab header displays the Antigravity badge and the Agent View button becomes active.

---

## 6. Phased Implementation Plan

| Phase | Tasks | Expected Output |
| :--- | :--- | :--- |
| **Phase 1: Backend & Core Parser** | 1. Implement `Headless/internal/agent/antigravity.go`<br>2. Wire into `transcript.go`, `read.go`, `binding.go`<br>3. Implement `antigravity_test.go` with fixture<br>4. Wire into `Headless/internal/server/service.go` | `go test ./Headless/internal/agent/...` and `go test ./Headless/internal/server/...` pass |
| **Phase 2: Warren CLI** | 1. Update `Headless/cmd/warren/main.go` flags & prompt handling<br>2. Add CLI tests in `main_test.go` | `warren agent create --provider antigravity` succeeds |
| **Phase 3: Web Client** | 1. Update `Web/src/session.js`, `title.js`, `components.jsx`<br>2. Add `Web/public/preset-antigravity.svg`<br>3. Update `session.test.js`, `catalog.test.js` | `node --test Web/src/*.test.js` passes |
| **Phase 4: macOS Desktop** | 1. Update `Models.swift`, `TerminalDisplayTitle.swift`<br>2. Update `WarrenDesktopSessionPreset.swift` & Settings<br>3. Add `preset-antigravity.svg` to Resources<br>4. Update Swift test suites | `swift test` passes |
| **Phase 5: E2E Verification** | 1. Live test against real `agy` on macOS<br>2. Verify memory consumption, PTY keystroke responsiveness, and title generation<br>3. Commit and update documentation | Production-ready Antigravity integration |

---

## 7. Open Considerations & Risks

1. **Permission Boundaries in CLI**:
   - `agy` may prompt users interactively in the terminal for file write or command execution permissions.
   - Design implication: Warren leaves tool approval authority with the TUI running in the PTY. Warren only tracks attention when an explicit question/prompt tool is active.
2. **Environment Overrides**:
   - If a host defines custom `GEMINI_HOME` or `ANTIGRAVITY_HOME`, Warren's directory helpers should respect these environment variables before falling back to `~/.gemini/antigravity-cli`.
3. **Hook Script Portability**:
   - The hook command is executed by `sh -c` on Unix. The hook script must use POSIX shell syntax (`sh`), avoiding bash-isms, to run reliably across Linux and macOS hosts.
