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
});

test("style uses semantic layer variables for z-index", () => {
  const css = read("style.css");
  const raw = [...css.matchAll(/z-index:\s*(\d+(?:\.\d+)?)/g)];
  assert.deepEqual(raw.map(match => match[0]), [], "raw z-index literal in style.css");
  assert.match(css, /--layer-(content|inline|inline-overlay|drawer|popover|command|modal|menu):/);
});

test("macOS app surfaces avoid native business sheets and alerts", () => {
  const repoRoot = resolve(srcDir, "..", "..");
  const files = [
    "Sources/Warren/WarrenCompositionRoot.swift",
    "Sources/Warren/WarrenMain.swift",
    "Packages/Desktop/Sources/WarrenDesktop/WarrenDesktopRootView.swift",
  ];
  for (const relative of files) {
    const content = readFileSync(resolve(repoRoot, relative), "utf8");
    assert.doesNotMatch(content, /\.sheet\s*\(/, relative);
    assert.doesNotMatch(content, /NSAlert\(\)/, relative);
  }
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
