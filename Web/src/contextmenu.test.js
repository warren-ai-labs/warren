import test from "node:test";
import assert from "node:assert/strict";
import { projectMenuItems, sessionMenuItems, taskMenuItems, workspaceMenuItems } from "./contextmenu.js";

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
  assert.deepEqual(items.map(item => item.label), ["Unpin workspace", "Rename workspace", "No tasks — create one first"]);
  assert.ok(items.every(item => !item.danger));
  assert.ok(items.at(-1).disabled);
});

test("task menu exposes lifecycle actions", () => {
  const calls = [];
  const task = { id: "task", pinned: false };
  const items = taskMenuItems(task, {
    togglePin: value => calls.push(["pin", value.id]),
    rename: value => calls.push(["rename", value.id]),
    delete: value => calls.push(["delete", value.id]),
  });
  items.forEach(item => item.action());
  assert.deepEqual(calls, [["pin", "task"], ["rename", "task"], ["delete", "task"]]);
});

test("workspace menu attaches and detaches task membership", () => {
  const calls = [];
  const task = { id: "task", name: "Delivery" };
  const attachItems = workspaceMenuItems({ id: "workspace" }, {
    togglePin() {},
    rename() {},
    tasks: [task],
    attach: (workspace, selectedTask) => calls.push(["attach", workspace.id, selectedTask.id]),
  });
  attachItems.at(-1).action();
  const detachItems = workspaceMenuItems({ id: "workspace", task: "task" }, {
    togglePin() {},
    rename() {},
    detach: workspace => calls.push(["detach", workspace.id]),
  });
  detachItems.at(-1).action();
  assert.deepEqual(calls, [["attach", "workspace", "task"], ["detach", "workspace"]]);
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
