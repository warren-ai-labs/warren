import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const srcDir = dirname(fileURLToPath(import.meta.url));
const read = name => readFileSync(resolve(srcDir, name), "utf8");

test("web app never calls browser-native prompts", () => {
  for (const name of ["App.jsx", "components.jsx"]) {
    assert.doesNotMatch(read(name), /window\.(prompt|confirm|alert)\s*\(/, name);
  }
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
