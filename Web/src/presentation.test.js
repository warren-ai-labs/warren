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

test("web dispatches roster deltas through the catalog synchronizer", () => {
  assert.match(read("App.jsx"), /case "roster":\s*case "roster\.delta":\s*acceptRoster\(message\)/);
});

test("dialogs and menus wire initial focus", () => {
  const components = read("components.jsx");
  assert.match(components, /inputRef\.current\?\.focus\(\)/);
  assert.match(components, /first\?\.focus\(\)/);
  assert.match(components, /cancelRef\.current\?\.focus\(\)/);
  assert.match(components, /querySelectorAll\([\s\S]*?\[role="menuitem"\]:not\(:disabled\)/);
  assert.match(read("agent.jsx"), /addEventListener\("pointerdown", handlePointerDown, true\)/);
});

test("canonical control-plane events render as timeline markers", () => {
  // The Host emits dotted canonical types such as `compaction.updated`; the
  // marker check must fold the separator or the row falls through to the
  // generic structured card.
  const agent = read("agent.jsx");
  assert.match(agent, /const markerType = type\.replaceAll\("\.", "_"\);/);
  assert.match(
    agent,
    /\["config", "config_updated", "compaction", "compaction_updated"\]\.includes\(markerType\)/,
  );
});

test("style uses semantic layer variables for z-index", () => {
  const css = read("style.css");
  const raw = [...css.matchAll(/z-index:\s*(\d+(?:\.\d+)?)/g)];
  assert.deepEqual(raw.map(match => match[0]), [], "raw z-index literal in style.css");
  assert.match(css, /--layer-(content|inline|inline-overlay|drawer|popover|command|modal|menu):/);
});

test("chrome borders stay hairline on Retina", () => {
  const css = read("style.css");
  assert.match(css, /--border-hairline: 1px;/);
  assert.match(css, /@media \(min-resolution: 2dppx\)[\s\S]*?--border-hairline: 0\.5px;/);
  assert.match(css, /@media \(min-resolution: 3dppx\)[\s\S]*?--border-hairline: 0\.3333px;/);
  // Structural chrome separators opt into the hairline token; the spacing
  // token it was cloned from stays at 1px for Swift parity.
  assert.match(css, /border-inline-end: var\(--border-hairline\) solid var\(--color-border-separator\)/);
  assert.match(css, /border-bottom: var\(--border-hairline\) solid var\(--color-border-separator\)/);
});

test("chrome scroll edges use the 7-stop ramp and drift with the scroll offset", () => {
  const css = read("style.css");
  // Non-linear sampling of the alpha ramp, rather than transparent -> black.
  for (const stop of ["#0000000d", "#00000026", "#0000004d", "#00000080", "#000000b3", "#000000d9"]) {
    assert.ok(css.includes(stop), stop);
  }
  // The fade distance is a registered length so the offset can interpolate it.
  assert.match(css, /@property --scroll-fade-top \{[\s\S]*?syntax: "<length>"/);
  // Zero-JS scroll-driven masks, gated on real overflow so a short list is
  // never faded.
  assert.match(css, /animation-timeline: scroll\(self block\)/);
  assert.match(css, /animation-timeline: scroll\(self inline\)/);
  assert.match(css, /\.sidebar-scroll\[data-overflow="true"\]/);
});

test("chrome press feedback and focus halo share the spring and accent tokens", () => {
  const css = read("style.css");
  assert.match(css, /--ease-spring: linear\(0, 0\.2459/);
  assert.match(css, /--shadow-focus-halo:/);
  assert.match(css, /\.chrome-button:active:not\(:disabled\)[\s\S]*?scale: 0\.94;/);
  // Dark-only client: medium/semibold are nudged down to counter bloom.
  assert.match(css, /--weight-medium: 465;/);
  assert.match(css, /--weight-semibold: 560;/);
});

test("composite chrome strips expose a single roving tab stop", () => {
  const components = read("components.jsx");
  assert.match(components, /import \{ rovingIndex, rovingTabIndex \} from "\.\/roving\.js";/);
  assert.match(components, /function useRovingFocus\(/);
  assert.match(components, /node\.tabIndex = index === active \? 0 : -1;/);
  // Desktop and mobile tab strips are both ARIA tablists; exactly the selected
  // tab stays in the Tab order.
  const stops = components.match(/tabIndex=\{active \? 0 : -1\}/g) || [];
  assert.equal(stops.length, 2);
  assert.match(components, /data-overflow=\{scrollOverflows \? "true" : undefined\}/);
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
  // Motion policy lives in activity.js, where activity.test.js pins it: only
  // progressing work moves. The dot must keep delegating rather than reviving a
  // second copy of that rule.
  assert.match(read("components.jsx"), /activityMarkIsAnimated\(mark\) \? "pulse" : ""/);
  // A glyph badge for the actionable tier read worse at the size a row actually
  // uses, so the mark is one dot again and the kind of a request lives in the
  // word rather than in a shape.
  assert.doesNotMatch(css, /\.activity-glyph/);
  assert.doesNotMatch(read("components.jsx"), /activityMarkGlyph/);
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
  assert.match(app, /pending\.onError\?\.\(`\$\{method\} timed out; retry\.`,\s*\{/);
  assert.match(app, /gitLoadGenerationRef\.current !== generation/);
  assert.match(app, /focusRequestGenerationRef\.current !== generation/);
  assert.match(app, /agentHistoryRequestRef\.current\.get\(sessionID\) !== token/);
  assert.match(app, /worktreeImportInFlightRef\.current/);
  assert.match(app, /gitWorkspaceGenerationRef\.current === workspaceGeneration/);
  assert.doesNotMatch(app, /const sendAgentInput = useCallback/);
  assert.match(app, /"agent\.turn\.start"/);
  assert.match(app, /"agent\.turn\.steer"/);
  assert.match(app, /"agent\.turn\.cancel"/);
  assert.match(app, /attachedSession !== sessionID/);
  assert.match(read("connection.js"), /clearTimeout\(handler\.timer\)/);
});

test("web attachment mutations use canonical command identities", () => {
  const app = read("App.jsx");
  assert.match(app, /agent\.attachment\.prepare[\s\S]*?executionId:\s*executionID[\s\S]*?commandId:\s*commandID/);
  assert.match(app, /agent\.attachment\.chunk[\s\S]*?executionId:\s*executionID[\s\S]*?commandId:\s*`\$\{uploadID\}-chunk-\$\{sequence\}`[\s\S]*?chunk:\s*sequence/);
  assert.match(app, /agent\.attachment\.complete[\s\S]*?executionId:\s*executionID[\s\S]*?commandId:\s*`\$\{uploadID\}-complete`/);
  assert.match(app, /agent\.attachment\.abort[\s\S]*?executionId:\s*executionID[\s\S]*?commandId:\s*`\$\{uploadID\}-abort`/);
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
  // The one native alert is the mounted disk image's install question. It
  // needs a blocking Install/Cancel choice before the image replaces the app,
  // and a posted notice cannot answer that.
  const warrenMain = readFileSync(resolve(repoRoot, "Sources/Warren/WarrenMain.swift"), "utf8");
  const diskImagePrompt = warrenMain.match(/private enum WarrenDiskImagePrompt \{[\s\S]*?\n\}/)?.[0];
  assert.ok(diskImagePrompt, "Sources/Warren/WarrenMain.swift: WarrenDiskImagePrompt");
  assert.match(diskImagePrompt, /NSAlert\(\)/, "WarrenDiskImagePrompt.confirm");
  for (const relative of files) {
    const content = readFileSync(resolve(repoRoot, relative), "utf8");
    assert.doesNotMatch(content, /\.sheet\s*\(/, relative);
    const withoutDiskImagePrompt = relative === "Sources/Warren/WarrenMain.swift"
      ? content.replace(diskImagePrompt, "")
      : content;
    assert.doesNotMatch(withoutDiskImagePrompt, /NSAlert\(\)/, relative);
  }
  // The SSH host picker is a Workbench menu page, not a native sheet: the
  // Host panel drills into it and the Desktop draws it on the shared menu
  // surface. The app only supplies the catalog through a page model.
  const compositionRoot = readFileSync(resolve(repoRoot, "Sources/Warren/WarrenCompositionRoot.swift"), "utf8");
  assert.doesNotMatch(compositionRoot, /NSAlert\(\)/, "Sources/Warren/WarrenCompositionRoot.swift");
  assert.match(compositionRoot, /sshHostPage/);
  assert.doesNotMatch(compositionRoot, /WarrenSSHHostPicker\(/);
  const hostPage = readFileSync(
    resolve(repoRoot, "Packages/Desktop/Sources/WarrenDesktop/WarrenDesktopSSHHostPage.swift"),
    "utf8",
  );
  assert.match(hostPage, /WarrenDesktopSSHHostListView/);
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
