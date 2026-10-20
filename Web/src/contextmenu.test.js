import test from "node:test";
import assert from "node:assert/strict";
import {
  mobileMoreMenuItems,
  placeMenu,
  projectMenuItems,
  sessionMenuItems,
  workspaceMenuItems,
} from "./contextmenu.js";

test("project context actions keep the shared order", () => {
  const calls = [];
  const project = { id: "p1", name: "warren", pinned: false, autoImportGitWorktrees: false };
  const items = projectMenuItems(project, {
    togglePin: value => calls.push(["pin", value.id]),
    rename: value => calls.push(["rename", value.id]),
    openImport: value => calls.push(["import", value.id]),
    toggleAutoImport: value => calls.push(["auto", value.id]),
  });
  assert.deepEqual(items.map(item => item.label), [
    "Pin project",
    "Rename project",
    "Import existing worktrees…",
    "Enable automatic worktree import (no confirmation)",
  ]);
  items[2].action();
  assert.deepEqual(calls, [["import", "p1"]]);
});

test("workspace context actions never mark a destructive item", () => {
  const items = workspaceMenuItems({ pinned: true }, {
    togglePin() {},
    rename() {},
  });
  assert.deepEqual(items.map(item => item.label), ["Unpin workspace", "Rename workspace"]);
  assert.ok(items.every(item => !item.danger));
});

test("session deletion is the only destructive context action", () => {
  const items = sessionMenuItems({ id: "s1", pinned: false }, {
    togglePin() {},
    rename() {},
    delete() {},
  });
  assert.deepEqual(
    items.map(item => [item.label, Boolean(item.danger)]),
    [
      ["Pin session", false],
      ["Rename session", false],
      ["Delete session", true],
    ],
  );
});

test("sessionMenuItems includes search action when provided", () => {
  let searched = false;
  const items = sessionMenuItems({ id: "s1", pinned: false }, {
    togglePin() {},
    rename() {},
    search() { searched = true; },
    delete() {},
  });
  assert.equal(items.length, 4);
  const searchItem = items.find(item => item.label === "Search terminal");
  assert.ok(searchItem);
  searchItem.action();
  assert.equal(searched, true);
});

test("the mobile overflow menu leads with search and git, then the session", () => {
  const calls = [];
  const actions = {
    gitOpen: false,
    openSearch: () => calls.push("search"),
    toggleGit: () => calls.push("git"),
    togglePin: () => calls.push("pin"),
    rename: () => calls.push("rename"),
    delete: () => calls.push("delete"),
  };
  const items = mobileMoreMenuItems({ id: "s1", pinned: false }, actions);
  assert.deepEqual(items.map(item => item.label), [
    "Search projects",
    "Show Git panel",
    "Pin session",
    "Rename session",
    "Delete session",
  ]);
  items[0].action();
  items[1].action();
  assert.deepEqual(calls, ["search", "git"]);

  // Without a Session the global actions remain, and the label names the state.
  assert.deepEqual(
    mobileMoreMenuItems(null, { ...actions, gitOpen: true }).map(item => item.label),
    ["Search projects", "Hide Git panel"],
  );
});

test("a desktop menu flips and clamps to stay on screen", () => {
  const viewport = { width: 1000, height: 800 };
  const size = { width: 200, height: 300 };
  // Room on both axes: opens at the pointer.
  assert.deepEqual(placeMenu({ x: 100, y: 100 }, size, viewport), { x: 100, y: 100 });
  // Near the right and bottom edges: flips to the other side of the pointer.
  assert.deepEqual(placeMenu({ x: 950, y: 750 }, size, viewport), { x: 750, y: 450 });
  // Too big to flip: clamped to the margin instead of leaving the viewport.
  assert.deepEqual(
    placeMenu({ x: 150, y: 200 }, { width: 200, height: 790 }, viewport),
    { x: 150, y: 8 },
  );
  assert.deepEqual(placeMenu({ x: 2, y: 2 }, size, viewport), { x: 8, y: 8 });
});
