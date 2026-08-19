import test from "node:test";
import assert from "node:assert/strict";
import {
  automaticSessionKind,
  firstAIPreset,
  loadSessionPresetOrder,
  moveSessionPreset,
  normalizeSessionPresetOrder,
  orderedSessionPresets,
  releaseWorkspaceSession,
  reserveWorkspaceSession,
  shouldAttachCreatedSession,
} from "./session.js";

test("empty explicit workspace entry selects Claude", () => {
  assert.equal(firstAIPreset().kind, "claude");
  assert.equal(automaticSessionKind({ tabs: [], pending: false, explicit: true }), "claude");
});

test("persisted preset order is normalized", () => {
  assert.deepEqual(
    normalizeSessionPresetOrder(["codex", "shell", "codex", "future"]),
    ["codex", "shell", "claude"],
  );
  assert.deepEqual(normalizeSessionPresetOrder(null), ["shell", "claude", "codex"]);
});

test("loading preset order repairs persisted data", () => {
  const storage = {
    value: '["codex","shell","codex","future"]',
    getItem() { return this.value; },
    setItem(_key, value) { this.value = value; },
  };

  assert.deepEqual(loadSessionPresetOrder(storage, "preset-order"), ["codex", "shell", "claude"]);
  assert.equal(storage.value, '["codex","shell","claude"]');

  storage.value = "invalid-json";
  assert.deepEqual(loadSessionPresetOrder(storage, "preset-order"), ["shell", "claude", "codex"]);
  assert.equal(storage.value, '["shell","claude","codex"]');
});

test("preset order controls presentation and automatic AI selection", () => {
  const presets = orderedSessionPresets(["shell", "codex", "claude"]);

  assert.deepEqual(presets.map(preset => preset.kind), ["shell", "codex", "claude"]);
  assert.equal(automaticSessionKind({
    tabs: [],
    pending: false,
    explicit: true,
    presets,
  }), "codex");
});

test("preset order moves within bounds", () => {
  const order = ["shell", "claude", "codex"];

  assert.deepEqual(moveSessionPreset(order, "codex", -1), ["shell", "codex", "claude"]);
  assert.deepEqual(moveSessionPreset(order, "shell", -1), order);
  assert.deepEqual(moveSessionPreset(order, "codex", 1), order);
});

test("existing or pending workspace does not start a session", () => {
  assert.equal(automaticSessionKind({ tabs: [{}], pending: false, explicit: true }), null);
  assert.equal(automaticSessionKind({ tabs: [], pending: true, explicit: true }), null);
});

test("passive workspace restoration does not start a session", () => {
  assert.equal(automaticSessionKind({ tabs: [], pending: false, explicit: false }), null);
});

test("workspace reservation prevents duplicate requests and can be released", () => {
  const pending = new Set();

  assert.equal(reserveWorkspaceSession(pending, "workspace"), true);
  assert.equal(reserveWorkspaceSession(pending, "workspace"), false);
  assert.deepEqual([...pending], ["workspace"]);

  releaseWorkspaceSession(pending, "workspace");
  assert.equal(reserveWorkspaceSession(pending, "workspace"), true);
});

test("workspace reservation rejects a missing workspace id", () => {
  assert.equal(reserveWorkspaceSession(new Set(), ""), false);
  assert.equal(reserveWorkspaceSession(new Set(), null), false);
});

test("created session attaches only while its workspace remains selected", () => {
  assert.equal(shouldAttachCreatedSession("workspace", "workspace"), true);
  assert.equal(shouldAttachCreatedSession("other", "workspace"), false);
  assert.equal(shouldAttachCreatedSession(null, "workspace"), false);
});
