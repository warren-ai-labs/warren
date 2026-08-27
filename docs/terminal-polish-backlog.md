# Terminal Polish Backlog — Lossless Must-Add

Date: 2026-08-28
Branch: `feat/persistent-warm-runtime`
Status: proposal — no behavior change yet, additive only
Source: conversation on top of `docs/terminal-experience-progress.md` and `docs/decisions/2026-08-26-terminal-rendering-comparison-and-direction.md`

This file collects polish that is **lossless** (presentation-only, no change to `prepareAttach`/`reanchorAtomicOutput` atomic boundary, no protocol change) and worth doing after the warm-runtime core lands.

## Principles

- One stable frame: tab switch is `reparent+present` (`Packages/GhosttyAdapter/TerminalSurfaceManager.swift:122`), cold recovery stays behind `recoveryPhase=.recovering` (`TerminalSurfaceManager.swift:394`) and only reveals at `present_complete` (`TerminalSurfaceManager.swift:748`).
- Sticky intent: `viewportY==baseY` means pinned to live output (`Web/src/App.jsx:1704`), otherwise preserve user scroll.
- One owner: only the focused/key-window surface may `Input/Resize` (`Sources/Warren/WarrenRemoteApplicationModel.swift:244 ownsTerminalFocus`, `WarrenResizeRequestBuffer:309`).
- Zeno's paradox (decision point): warm promotion captures a **fixed** target at `schedulePresent:687` (`targetSequence = enqueuedSequence` at that moment) and drains hidden until that target, then reveals once. Chasing a moving `max(enqueued)` would never finish when codex continuously produces output — the tortoise always moves a bit. Fixed target makes the 50ms budget achievable; live bytes after the capture stream in normally instead of being fast-forwarded. Chosen: **1. fixed target** over **2. wait for quiescence**.
- Keep canvas on demote (decision point): `demote:625` keeps warm view hidden in place instead of `removeFromSuperview → clearSurface → surfaceReady=false → drain stall → backlog`. Warm backlog must drain hidden, not accumulate. Chosen: **keep hidden** over **tear down**.
- Reveal on draw, not feed (decision point): `present:726 outputHasReached` previously used `renderedSequence` (feed) as ready, causing reveal before Ghostty drew. Reveal must wait for `ghostty_surface_draw` success. Chosen: **draw-complete** over **feed-complete**.
- Shell readiness probe (decision point): `ghostline.go:52` fixed 400ms wasted on fast machines and raced on slow ones. Poll `Status.Alive` every 50ms up to 1.5s + 100ms grace. CLI path tolerates latency, so generous deadline is acceptable. Chosen: **poll liveness** over **fixed sleep**.

## Backlog

### P1 — High signal, low risk

#### 1. Sticky scroll + "N lines new output" pill
**Problem:** User scrolls up to read history, new output silently arrives with no cue; current code already preserves viewport but gives no affordance.
**Proposal:** When `viewportY < baseY`, show a bottom-right pill `N new lines ●` (count from `enqueuedSequence - renderedSequence`). Click → `scrollToBottom()`. When pinned, auto-follow as today.
**No conflict with agent TUI:** Pill tracks Warren view pin state; Claude/Codex scrolling via escape sequences (`cup`/`alt screen`) flows through `WarrenGhosttyOutputWriter.swift:250 receive` into the grid and does not trigger view auto-scroll. If `activity==.working` while scrolled up, do not auto-follow; flash pill only.
**Files:** `TerminalSurfaceManager.swift:682 schedulePresent`, `GhosttySurface.swift:214`, `Web/src/App.jsx:1704`, `Web/src/output.js`
**Effort:** S · Risk: none

#### 2. Generic process indicator (extends existing agent activity)
**Problem:** `WarrenDesktopTabItemView.swift:101` and `WarrenDesktopSidebarRowsView.swift:379` only show `AgentActivityState` (codex/claude). Plain shells running `npm dev`/`vim`/`htop` have no tab cue.
**Proposal:** Add a 3px process dot next to `WarrenDesktopActivityIndicator`: solid green = `RosterVersion:730 session.Process != ""`, dim = idle, orange overlay = `agentStatus.attention`. Reuse `Service.focusedPeers:156`/`metadataCache` already in roster.
**Files:** `WarrenDesktopTabItemView.swift:88`, `WarrenDesktopFixture.swift:150`, `Headless/internal/server/service.go:730`
**Effort:** S

#### 3. Link hover + Cmd+Click to open
**Problem:** `lessons.md:002` fixed the `openUrl` storm, but no hover affordance.
**Proposal:** Expose `linkAt(row,col)` via `TerminalSurfaceCoordinator`, show `pointingHand + underline` on hover, open only on `Cmd+Click` via `NSWorkspace`. Web mirrors with `xterm-addon-web-links`.
**Files:** `Packages/Vendor/GhosttyEmbedding/.../TerminalController+Callbacks.swift`, `GhosttySurface.swift`, `Web/src/terminal.js`
**Effort:** S

#### 4. Selection preservation + "Copied" HUD
**Problem:** Warm `demote:625 captureReattachAnchor` saves viewport/anchor but not selection. Web `App.jsx:1821` copies on `mouseup`, Desktop has no feedback.
**Proposal:** Save/restore `TerminalSelectionAnchor` across `demote`/`attach:618`, add 800ms HUD `Copied` on copy. No clipboard policy change.
**Files:** `TerminalSurfaceManager.swift:625`, `GhosttySurface.swift`, `Web/src/App.jsx:1821`
**Effort:** S

#### 5. Delayed loading gate (200ms threshold)
**Problem:** Cold recovery shows `alpha=0` with no spinner; fast path (50–120ms local `AtomicState:4215` + one rAF) needs no loader, slow large snapshot (up to 64MiB `wire.go:MAX_ATOMIC`) does.
**Proposal:** Show spinner only if `present_complete` not reached within 200ms after `attached`. Implemented as `asyncAfter 200ms` check in `TerminalSurfaceManager.swift:698` and `App.jsx:134 terminalRecoveryTimeoutMs`.
**Files:** `TerminalSurfaceManager.swift:698`, `Web/src/App.jsx:134`
**Effort:** S

### P2 — Small chrome, high clarity

#### 6. Focus-owner badge in preset bar
**Problem:** Multi-peer viewing a shared PTY has no indicator of who holds `Input/Resize`.
**Proposal:** 2×2px dot in `WarrenDesktopPresetBarView.swift:16` below the preset bar, driven by `Service.focusedPeers:156` via roster, styled like `WarrenStatusIndicator`.
**Files:** `WarrenDesktopPresetBarView.swift:16`, `WarrenDesktopRootView.swift:629`, `WarrenDesktopTabBarView.swift:30`
**Effort:** S

#### 7. Unsaved/dirty dot on Editor tab
**Problem:** `WarrenEmbeddedEditor.swift:60 nonPersistentDataStore` discards workbench local state on cache eviction with no warning.
**Proposal:** Listen to code-server dirty via `WKScriptMessageHandler`, map to `WarrenDesktopEditorTabItem:234` `●` next to `Editor` title. Keep ephemeral, no persistence.
**Files:** `Sources/Warren/WarrenEmbeddedEditor.swift:60`, `Packages/Desktop/WarrenDesktopTabItemView.swift:234`
**Effort:** M (needs JS bridge)

#### 8. Hard-upgrade notice + menubar hint
**Problem:** Protocol 2 `http.go:923 upgrade required` currently surfaces as generic `Reconnecting…`.
**Proposal:** Promote to `WarrenRemoteApplicationModel.swift:905 notices` (`NoticeKind.upgradeRequired`) + top-bar `EndpointControl:698` amber badge. `disconnected(String):353` already carries the string.
**Files:** `Headless/internal/server/http.go:923`, `Sources/Warren/WarrenRemoteApplicationModel.swift:737`, `Packages/Desktop/WarrenDesktopTabBarView.swift:698`
**Effort:** S

#### 9. Focus cursor shape
**Problem:** Lost focus still shows solid blinking block.
**Proposal:** On `window.didResignKey` (`TerminalSurfaceManager.swift:870`) set hollow/underline and pause blink; restore on `didBecomeKey`.
**Files:** `TerminalSurfaceManager.swift:669`, `GhosttySurface.swift`
**Effort:** S

#### 10. Live title/path via OSC 0/7
**Problem:** Tab title `WarrenDesktopContentViews.swift:288 titleContext` updates only on `metadataLoop:501 750ms` throttle.
**Proposal:** Forward `OSC 0` (title) and `OSC 7` (cwd) from `WarrenGhosttyOutputWriter` observer to `titleContext` for immediate tab rename, keep `metadataLoop` as fallback.
**Files:** `WarrenDesktopContentViews.swift:288`, `Headless/internal/runtime/env.go`, `Packages/GhosttyAdapter/WarrenGhosttyOutputWriter.swift:250`
**Effort:** S

### P3 — Nice to have

#### 11. Search overview ruler + result count
Expose `SearchAddon` overview ruler and `resultIndex/count` in the find bar for warm surfaces.
**Files:** `Web/src/App.jsx:134 terminalSearchDecorations`, `GhosttySurface.swift`

#### 12. Automated lifecycle verification
Add `scripts/verify-terminal-lifecycle.sh` asserting `rg '"event":"present_complete"' ~/Library/Logs/Warren/terminal-diagnostics.log` + `headless.log:3893 recovery outcome` to enforce "warm switch = zero attach, resize = zero capture" in CI.
**Files:** `docs/terminal-rendering-runbook.md:109`, `Headless/internal/server/service.go:3893`

## Non-goals (intentionally out)

- Warm eviction user-visible hint — keep silent per product decision.
- Branch/diff size reduction — deferred.

## Suggested order

P1: 2 → 1 → 4 → 5 → 3, then P2: 6 → 8 → 9 → 7 → 10, then P3: 11 → 12.
