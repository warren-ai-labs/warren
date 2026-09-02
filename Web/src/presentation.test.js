import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  popRole,
  presentationLayer,
  pushRole,
  shouldDismissOnBackdrop,
  shouldDismissOnEscape,
  topRole,
} from "./presentation.js";

const srcDir = dirname(fileURLToPath(import.meta.url));
const read = name => readFileSync(resolve(srcDir, name), "utf8");

test("web app never calls browser-native prompts", () => {
  for (const name of ["App.jsx", "components.jsx"]) {
    assert.doesNotMatch(read(name), /window\.(prompt|confirm|alert)\s*\(/, name);
  }
});

test("dialogs and menus wire initial focus", () => {
  const components = read("components.jsx");
  assert.match(components, /inputRef\.current\?\.focus\(\)/);
  assert.match(components, /first\?\.focus\(\)/);
  assert.match(components, /cancelRef\.current\?\.focus\(\)/);
  assert.match(components, /querySelectorAll\([\s\S]*?\[role="menuitem"\]:not\(:disabled\)/);
  assert.match(read("agent.jsx"), /addEventListener\("pointerdown", handlePointerDown, true\)/);
});

test("style uses semantic layer variables for z-index", () => {
  const css = read("style.css");
  const raw = [...css.matchAll(/z-index:\s*(\d+(?:\.\d+)?)/g)];
  assert.deepEqual(raw.map(match => match[0]), [], "raw z-index literal in style.css");
  assert.match(css, /--layer-(content|inline|inline-overlay|drawer|popover|command|modal|menu):/);
});

test("agent surfaces keep semantic state aliases and touch-safe tablet/mobile contracts", () => {
  const css = read("style.css");
  for (const token of [
    "--color-agent-card-surface",
    "--color-agent-input-surface",
    "--fill-agent-selected",
    "--shadow-agent-popover",
    "--color-mobile-surface",
    "--color-accent",
    "--font-mono",
  ]) {
    assert.match(css, new RegExp(`${token}:`), token);
  }
  assert.match(css, /\.agent-input-surface:focus-within/);
  assert.match(css, /\.agent-send:not\(:disabled\)/);
  assert.match(css, /\.agent-send:disabled/);
  assert.match(css, /\.agent-tool-card\s*\{[\s\S]*?padding: var\(--space-lg\);[\s\S]*?border-radius: var\(--radius-md\);/);
  assert.match(css, /\.agent-tool-group \.agent-tool-card\s*\{[\s\S]*?background: transparent;/);
  assert.match(css, /@media \(min-width: 768px\) and \(max-width: 900px\)/);
  assert.match(css, /\.mobile-tab\.active::after/);
  assert.match(css, /\.context-menu\s*\{[\s\S]*?left: 0 !important;[\s\S]*?right: 0 !important;/);
  assert.match(css, /\.context-menu button:disabled/);
  assert.match(css, /\.context-menu-scrim\s*\{[\s\S]*?z-index: calc\(var\(--layer-menu\) - 1\)/);
  assert.match(css, /\.search-overlay\.open\s*\{[\s\S]*?animation: scrim-in var\(--duration-overlay\)/);
  assert.match(css, /\.worktree-dialog-overlay\s*\{[\s\S]*?animation: scrim-in var\(--duration-overlay\)/);
  assert.match(read("components.jsx"), /const pulse = activity === "working" \? " pulse" : ""/);
});

test("feedback states gate repeated actions and preserve actionable failures", () => {
  const app = read("App.jsx");
  const components = read("components.jsx");
  const agent = read("agent.jsx");
  const gitPanel = read("gitpanel.jsx");
  assert.match(app, /pendingSessionRef\.current === sessionID/);
  assert.match(app, /gitActionRef\.current\?\.workspaceID === workspaceID/);
  assert.match(app, /renamePendingRef\.current/);
  assert.match(app, /deletePendingRef\.current/);
  assert.match(app, /clearPendingSession\(\)/);
  assert.match(app, /appStateRef\.current\.activeWorkspace === workspaceID/);
  assert.match(components, /disabled=\{Boolean\(pendingSessionID\) \|\| creatingSession\}/);
  assert.match(components, /aria-busy=\{creating \|\| undefined\}/);
  assert.match(components, /className="project-add"[\s\S]*?disabled=\{creatingSession/);
  assert.match(components, /terminal-empty\$\{switching \? " switching" : ""\}/);
  assert.match(app, /hasNewTerminalOutput/);
  assert.match(app, /terminal-new-output/);
  assert.match(app, /buffer\.viewportY >= buffer\.baseY/);
  assert.match(components, /onPointerCancel=/);
  assert.match(components, /className="transient-feedback/);
  assert.match(components, /role="alert"/);
  assert.match(agent, /submissionInFlightRef\.current/);
  assert.match(agent, /Send failed — retry/);
  assert.match(agent, /cancelPending/);
  assert.match(gitPanel, /const submitCommit = \(\) => \{\s*if \(busy\) return;/);
  assert.match(gitPanel, /const submitCheckout = \(\) => \{\s*if \(busy\) return;/);
  assert.doesNotMatch(gitPanel, /setCommitOpen\(false\);\s*onCommit/);
  assert.doesNotMatch(gitPanel, /setPrOpen\(false\);\s*onCreatePR/);
  assert.match(read("style.css"), /\.terminal-empty\.switching\s*\{[\s\S]*?background: transparent;/);
  assert.match(read("style.css"), /\.terminal-new-output\s*\{[\s\S]*?min-height: 44px;/);
});

test("async UI requests expire and reject stale workspace/session callbacks", () => {
  const app = read("App.jsx");
  assert.match(app, /REQUEST_TIMEOUT_MS\s*=\s*30_000/);
  assert.match(app, /pending\.onError\?\.\(`\$\{method\} timed out; retry\.`\)/);
  assert.match(app, /gitLoadGenerationRef\.current !== generation/);
  assert.match(app, /focusRequestGenerationRef\.current !== generation/);
  assert.match(app, /agentHistoryRequestRef\.current\.get\(sessionID\) !== token/);
  assert.match(app, /worktreeImportInFlightRef\.current/);
  assert.match(app, /gitWorkspaceGenerationRef\.current === workspaceGeneration/);
  assert.match(app, /const sendAgentInput = useCallback\(async text/);
  assert.match(app, /attachedSession !== sessionID/);
  assert.match(read("connection.js"), /clearTimeout\(handler\.timer\)/);
});

test("context-menu Escape handling does not depend on sheet-only state", () => {
  const components = read("components.jsx");
  const contextMenu = components.slice(components.indexOf("export function ContextMenu"), components.indexOf("export function PresetBar"));
  assert.doesNotMatch(contextMenu, /pendingKind/);
});

test("app-owned overlays restore focus after dismissal", () => {
  assert.match(read("components.jsx"), /function useFocusRestore\(active\)/);
  assert.match(read("components.jsx"), /useFocusRestore\(Boolean\(menu\)\)/);
  assert.match(read("components.jsx"), /useFocusRestore\(Boolean\(dialog\)\)/);
  assert.match(read("components.jsx"), /function useBodyScrollLock\(active\)/);
  assert.match(read("components.jsx"), /useBodyScrollLock\(open\)/);
  assert.match(read("components.jsx"), /useBodyScrollLock\(true\)/);
  assert.match(read("components.jsx"), /const onCloseRef = useRef\(onClose\)/);
  assert.match(read("components.jsx"), /nextSurface = document\.querySelector\('\[role="dialog"\]\[aria-modal="true"\], \[role="menu"\]'\)/);
  assert.match(read("components.jsx"), /onPointerDown=\{event => \{\n\s*if \(event\.target === event\.currentTarget\) onClose\(\);/);
  assert.match(read("agent.jsx"), /onCloseRef\.current\(\)/);
  assert.match(read("App.jsx"), /target\?\.focus\(\{ preventScroll: true \}\)/);
  assert.match(read("components.jsx"), /firstAvailableIndex = candidates\.findIndex/);
  assert.match(read("App.jsx"), /nearestFocusable\(event\.target\)[\s\S]*?nearestFocusable\(event\.currentTarget\)/);
  assert.match(read("agent.jsx"), /setShowQueue\(previous => !previous\)/);
  assert.match(read("agent.jsx"), /pendingAttachments = selectedAttachments\.filter/);
  assert.match(read("agent.jsx"), /completedReferencesByIndex = new Map/);
  assert.match(read("agent.jsx"), /item\.status === "ready" && item\.reference/);
  assert.match(read("App.jsx"), /onProgress\(index, 1, "", reference\)/);
  assert.match(read("agent.jsx"), /uploadGenerationRef = useRef\(0\)/);
  assert.match(read("agent.jsx"), /sessionIdentityRef\.current === uploadSessionIdentity/);
});

test("macOS app surfaces avoid native business sheets and alerts", () => {
  const repoRoot = resolve(srcDir, "..", "..");
  const files = [
    "Sources/Warren/WarrenMain.swift",
    "Packages/Desktop/Sources/WarrenDesktop/WarrenDesktopRootView.swift",
  ];
  for (const relative of files) {
    const content = readFileSync(resolve(repoRoot, relative), "utf8");
    assert.doesNotMatch(content, /\.sheet\s*\(/, relative);
    assert.doesNotMatch(content, /NSAlert\(\)/, relative);
  }
  // The SSH host picker is an OS-adjacent configuration flow that remains a
  // native sheet by design. Keep the broad alert guard above while scoping
  // this sheet assertion to Warren-owned business surfaces.
  const compositionRoot = readFileSync(resolve(repoRoot, "Sources/Warren/WarrenCompositionRoot.swift"), "utf8");
  assert.doesNotMatch(compositionRoot, /NSAlert\(\)/, "Sources/Warren/WarrenCompositionRoot.swift");
  assert.match(compositionRoot, /if isSSHHostPickerPresented/);
  assert.match(compositionRoot, /WarrenSheetSurface\s*\{[\s\S]*WarrenSSHHostPicker\(/);
  assert.match(compositionRoot, /WarrenSSHHostPicker\(/);
});

test("presentation stack keeps the topmost role", () => {
  let stack = [];
  stack = pushRole(stack, "popover");
  stack = pushRole(stack, "modal");
  assert.equal(topRole(stack), "modal");
  stack = popRole(stack);
  assert.equal(topRole(stack), "popover");
});

test("modal never dismisses on backdrop", () => {
  assert.equal(shouldDismissOnBackdrop("modal", true), false);
  assert.equal(shouldDismissOnBackdrop("modal", false), false);
});

test("sheet backdrop dismissal requires no edits", () => {
  assert.equal(shouldDismissOnBackdrop("sheet", true), false);
  assert.equal(shouldDismissOnBackdrop("sheet", false), true);
});

test("escape dismissal is limited to interactive surfaces", () => {
  for (const role of ["modal", "sheet", "commandSurface", "popover", "menu"]) {
    assert.equal(shouldDismissOnEscape(role), true, role);
  }
  assert.equal(shouldDismissOnEscape("status"), false);
  assert.equal(shouldDismissOnEscape("inline"), false);
});

test("semantic layer map matches the plan", () => {
  assert.equal(presentationLayer("modal"), 50);
  assert.equal(presentationLayer("commandSurface"), 40);
  assert.equal(presentationLayer("menu"), 60);
  assert.equal(presentationLayer("popover"), 30);
});
