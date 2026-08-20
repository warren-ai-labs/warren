import test from "node:test";
import assert from "node:assert/strict";
import {
  gitPanelUIStorageKey,
  normalizeGitPanelUI,
  loadGitPanelUI,
  saveGitPanelUI,
  gitPanelUIFileView,
} from "./gitui.js";

function fakeStorage(initial = {}) {
  const data = new Map(Object.entries(initial));
  return {
    getItem: key => (data.has(key) ? data.get(key) : null),
    setItem: (key, value) => data.set(key, String(value)),
    removeItem: key => data.delete(key),
  };
}

test("gitPanelUIStorageKey scopes the key by workspace", () => {
  assert.equal(gitPanelUIStorageKey("ws-a"), "warren.gitPanelUI.ws-a");
  assert.equal(gitPanelUIStorageKey("ws-b"), "warren.gitPanelUI.ws-b");
});

test("normalizeGitPanelUI drops out-of-whitelist panes and values", () => {
  const ui = normalizeGitPanelUI({
    openPanes: ["pr", "nope", "changes", 42],
    selectedKey: "u:src/a.js",
    expanded: ["abc", "", 7, "def"],
    branch: "feature/x",
    viewTab: "file",
    diffStyle: "sideways",
  });
  assert.deepEqual(ui.openPanes, ["pr", "changes"]);
  assert.equal(ui.selectedKey, "u:src/a.js");
  assert.deepEqual(ui.expanded, ["abc", "def"]);
  assert.equal(ui.branch, "feature/x");
  assert.equal(ui.viewTab, "file");
  assert.equal(ui.diffStyle, undefined);
});

test("normalizeGitPanelUI validates fileView", () => {
  const valid = normalizeGitPanelUI({ fileView: { path: "a b.js", staged: true, commit: "abc123" } });
  assert.deepEqual(valid.fileView, { path: "a b.js", staged: true, commit: "abc123" });

  const missingPath = normalizeGitPanelUI({ fileView: { staged: true } });
  assert.equal(missingPath.fileView, undefined);

  const nullView = normalizeGitPanelUI({ fileView: null });
  assert.equal(nullView.fileView, null);
});

test("normalizeGitPanelUI tolerates garbage input", () => {
  assert.deepEqual(normalizeGitPanelUI(null), {});
  assert.deepEqual(normalizeGitPanelUI("nope"), {});
  assert.deepEqual(normalizeGitPanelUI(undefined), {});
});

test("saveGitPanelUI then loadGitPanelUI round-trips", () => {
  const storage = fakeStorage();
  const ui = {
    openPanes: ["changes"],
    selectedKey: "s:pkg/a.go",
    expanded: ["abc"],
    branch: "main",
    viewTab: "diff",
    diffStyle: "split",
    fileView: { path: "pkg/a.go", staged: true, commit: null },
  };
  saveGitPanelUI(storage, "ws-a", ui);
  assert.deepEqual(loadGitPanelUI(storage, "ws-a"), ui);
});

test("loadGitPanelUI returns {} on missing or corrupt storage", () => {
  const storage = fakeStorage();
  assert.deepEqual(loadGitPanelUI(storage, "ws-a"), {});

  const corrupt = fakeStorage({ "warren.gitPanelUI.ws-a": "{not json" });
  assert.deepEqual(loadGitPanelUI(corrupt, "ws-a"), {});
});

test("saveGitPanelUI removes the key when nothing meaningful remains", () => {
  const storage = fakeStorage();
  saveGitPanelUI(storage, "ws-a", {});
  assert.equal(storage.getItem("warren.gitPanelUI.ws-a"), null);
});

test("saveGitPanelUI never stores a workspace it was not asked about", () => {
  const storage = fakeStorage();
  saveGitPanelUI(storage, "ws-a", { openPanes: ["pr"] });
  assert.equal(storage.getItem("warren.gitPanelUI.ws-b"), null);
});

test("gitPanelUIFileView extracts a storable fileView subset", () => {
  assert.deepEqual(
    gitPanelUIFileView({ key: "k", path: "src/a.js", staged: true, commit: "abc" }),
    { path: "src/a.js", staged: true, commit: "abc" },
  );
  assert.deepEqual(
    gitPanelUIFileView({ key: "k", path: "src/a.js", staged: false }),
    { path: "src/a.js", staged: false, commit: null },
  );
  assert.equal(gitPanelUIFileView(null), null);
  assert.equal(gitPanelUIFileView({ staged: true }), null);
});
