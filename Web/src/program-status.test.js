import assert from "node:assert/strict";
import test from "node:test";

import { programStatusDetail, programStatusMarkLabel, resolveProgramStatusMark } from "./program-status.js";

test("draws nothing without a status, or for an idle or unknown program", () => {
  assert.equal(resolveProgramStatusMark(null), null);
  assert.equal(resolveProgramStatusMark(undefined), null);
  assert.equal(resolveProgramStatusMark({ state: "idle" }), null);
  assert.equal(resolveProgramStatusMark({ state: "paused" }), null);
});

test("resolves program states into the Agent activity marks", () => {
  assert.equal(resolveProgramStatusMark({ state: "working" }), "working");
  assert.equal(resolveProgramStatusMark({ state: "error" }), "failed");
  assert.equal(resolveProgramStatusMark({ state: "done" }), "ready");
  assert.equal(resolveProgramStatusMark({ state: "blocked", kind: "permission" }), "approvalNeeded");
  assert.equal(resolveProgramStatusMark({ state: "blocked", kind: "question" }), "inputNeeded");
  assert.equal(resolveProgramStatusMark({ state: "blocked", kind: "auth" }), "attentionUnspecified");
  assert.equal(resolveProgramStatusMark({ state: "blocked" }), "attentionUnspecified");
});

test("labels name the program and the tooltip prefers its message", () => {
  assert.equal(programStatusMarkLabel("approvalNeeded"), "Program needs approval");
  assert.equal(
    programStatusDetail({ state: "blocked", kind: "permission", message: "Apply 3 to add?" }, "approvalNeeded"),
    "Apply 3 to add?",
  );
  assert.equal(programStatusDetail({ state: "error", message: "  " }, "failed"), "Program failed");
  assert.equal(programStatusDetail({ state: "idle" }, null), "");
});
