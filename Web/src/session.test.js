import test from "node:test";
import assert from "node:assert/strict";
import {
  automaticSessionKind,
  loadHiddenSessionPresetKinds,
  loadSessionPresetOrder,
  moveSessionPreset,
  normalizeHiddenSessionPresetKinds,
  normalizeSessionPresetOrder,
  orderedSessionPresets,
  releaseWorkspaceSession,
  reserveWorkspaceSession,
  isAgentSession,
  shouldAttachCreatedSession,
  visibleSessionPresets,
} from "./session.js";

test("automatic AI entry is opt-in, empty-only and follows preset order", () => {
  assert.equal(automaticSessionKind({ tabs: [], pending: false, explicit: true }), null);
  assert.equal(
    automaticSessionKind({
      tabs: [],
      pending: false,
      explicit: true,
      autoStartAI: true,
      presets: orderedSessionPresets(["shell", "codex", "claude"]),
    }),
    "codex",
  );
  assert.equal(
    automaticSessionKind({ tabs: [], pending: true, explicit: true, autoStartAI: true }),
    null,
  );
  assert.equal(
    automaticSessionKind({ tabs: [{ id: "existing" }], pending: false, explicit: true, autoStartAI: true }),
    null,
  );
  assert.equal(
    automaticSessionKind({ tabs: [], pending: false, explicit: false, autoStartAI: true }),
    null,
  );
});

test("persisted preset order is normalized", () => {
  assert.deepEqual(
    normalizeSessionPresetOrder(["codex", "shell", "codex", "future"]),
    ["codex", "shell", "claude", "trae"],
  );
  assert.deepEqual(normalizeSessionPresetOrder(null), ["shell", "claude", "codex", "trae"]);
});

test("loading preset order repairs persisted data", () => {
  const storage = {
    value: '["codex","shell","codex","future"]',
    getItem() { return this.value; },
    setItem(_key, value) { this.value = value; },
  };

  assert.deepEqual(loadSessionPresetOrder(storage, "preset-order"), ["codex", "shell", "claude", "trae"]);
  assert.equal(storage.value, '["codex","shell","claude","trae"]');

  storage.value = "invalid-json";
  assert.deepEqual(loadSessionPresetOrder(storage, "preset-order"), ["shell", "claude", "codex", "trae"]);
  assert.equal(storage.value, '["shell","claude","codex","trae"]');
});

test("preset order controls presentation", () => {
  const presets = orderedSessionPresets(["shell", "codex", "claude"]);

  assert.deepEqual(presets.map(preset => preset.kind), ["shell", "codex", "claude", "trae"]);
});

test("preset order moves within bounds", () => {
  const order = ["shell", "claude", "codex", "trae"];

  assert.deepEqual(moveSessionPreset(order, "codex", -1), ["shell", "codex", "claude", "trae"]);
  assert.deepEqual(moveSessionPreset(order, "shell", -1), order);
  assert.deepEqual(moveSessionPreset(order, "trae", 1), order);
});

test("Trae is hidden by default and visibility only accepts known presets", () => {
  const storage = {
    value: null,
    getItem() { return this.value; },
    setItem(_key, value) { this.value = value; },
  };

  assert.deepEqual(loadHiddenSessionPresetKinds(storage, "hidden-presets"), ["trae"]);
  assert.deepEqual(normalizeHiddenSessionPresetKinds(["future", "codex", "codex"]), ["codex"]);
  assert.deepEqual(
    visibleSessionPresets(orderedSessionPresets(null), ["trae"]).map(preset => preset.kind),
    ["shell", "claude", "codex"],
  );
});

test("Trae remains a shell preset when it is visible", () => {
  assert.equal(
    automaticSessionKind({
      tabs: [],
      pending: false,
      explicit: true,
      autoStartAI: true,
      presets: visibleSessionPresets(orderedSessionPresets(["trae", "shell"]), []),
    }),
    "claude",
  );
});

test("only Codex and Claude, plus bound shell overlays, are Agents", () => {
  assert.equal(isAgentSession({ kind: "codex" }), true);
  assert.equal(isAgentSession({ kind: "claude" }), true);
  assert.equal(isAgentSession({ kind: "shell", agentSessionId: "thread-shell" }), true);
  assert.equal(isAgentSession({ kind: "custom", agentSessionId: "thread-custom" }), true);
  assert.equal(isAgentSession({ kind: "trae", agentSessionId: "stale" }), false);
  assert.equal(isAgentSession({ kind: "shell" }), false);
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
