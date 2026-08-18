import test from "node:test";
import assert from "node:assert/strict";
import {
  automaticSessionKind,
  firstAIPreset,
  releaseWorkspaceSession,
  reserveWorkspaceSession,
  shouldAttachCreatedSession,
} from "./session.js";

test("empty explicit workspace entry selects Claude", () => {
  assert.equal(firstAIPreset().kind, "claude");
  assert.equal(automaticSessionKind({ tabs: [], pending: false }), "claude");
});

test("existing or pending workspace does not start a session", () => {
  assert.equal(automaticSessionKind({ tabs: [{}], pending: false }), null);
  assert.equal(automaticSessionKind({ tabs: [], pending: true }), null);
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
