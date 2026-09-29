import assert from "node:assert/strict";
import test from "node:test";

import {
  composerChips,
  withStateEvents,
  displayPath,
  displayTarget,
  formatElapsed,
  isACPSession,
  orderDecisionOptions,
  projectConversation,
  stepLine,
  summarizeSteps,
  visibleStreamingText,
} from "./conversation.js";

let sequence = 0;
function event(type, payload = {}, turnId = "1", extra = {}) {
  sequence += 1;
  return { canonicalType: type, type, payload, turnId, sequence, occurredAt: new Date(1_000_000 + sequence * 1000).toISOString(), ...extra };
}

test("a turn separates the prompt, the work, the narration, and the answer", () => {
  const events = [
    event("message.created", { role: "user", content: "fix the reaper", messageId: "u1" }),
    event("turn.started"),
    event("reasoning.delta", { content: "think", messageId: "r1" }),
    event("message.created", { role: "assistant", content: "Looking", messageId: "m1" }),
    event("message.delta", { role: "assistant", content: " first.", messageId: "m1" }),
    event("tool.started", { callId: "c1", toolKind: "read", toolName: "Read", toolDetail: "a.go" }),
    event("tool.completed", { callId: "c1", toolKind: "read", output: "package a" }),
    event("tool.started", { callId: "c2", toolKind: "ran", toolDetail: "go test" }),
    event("tool.completed", { callId: "c2", toolKind: "ran", output: "ok" }),
    event("tool.completed", { callId: "c3", toolKind: "edit", toolDetail: "a.go", diff: { file: "a.go", additions: 3, deletions: 1, diff: "+x" } }),
    event("message.created", { role: "assistant", content: "Done.", messageId: "m2" }),
    event("message.completed", { role: "assistant", content: "Done.", messageId: "m2" }),
    event("turn.completed"),
  ];
  const { turns } = projectConversation(events);
  assert.equal(turns.length, 1);
  const [turn] = turns;
  assert.equal(turn.user.text, "fix the reaper");
  assert.equal(turn.answer, "Done.");
  assert.equal(turn.answerComplete, true);
  assert.deepEqual(turn.narration.map(message => message.text), ["Looking first."]);
  assert.equal(turn.summary, "Read 1 file · Edited 1 file · Ran 1 command");
  assert.deepEqual(turn.files.map(file => [file.file, file.additions, file.deletions]), [["a.go", 3, 1]]);
  assert.equal(turn.status, "completed");
  assert.equal(turn.reasoning.count, 1);
});

test("a pending permission is a decision, not a timeline row, until it resolves", () => {
  const pending = [
    event("message.created", { role: "user", content: "clean", messageId: "u" }, "2"),
    event("interaction.requested", {
      interactionId: "p1", kind: "permission", version: 1, title: "Run rm", toolKind: "ran", toolDetail: "rm -rf build",
      options: [
        { id: "no", label: "Reject", kind: "reject_once" },
        { id: "yes", label: "Allow once", kind: "allow_once" },
      ],
      state: "pending",
    }, "2"),
  ];
  let projection = projectConversation(pending);
  assert.equal(projection.decisions.length, 1);
  assert.equal(projection.decisions[0].detail, "rm -rf build");
  assert.equal(projection.turns[0].steps.length, 0);

  // The agent may answer before the Host journals the resolution.
  projection = projectConversation([
    ...pending,
    event("message.created", { role: "assistant", content: "chose yes", messageId: "a" }, "2"),
    event("interaction.resolved", { interactionId: "p1", response: { decision: "yes" } }, ""),
  ]);
  assert.equal(projection.decisions.length, 0);
  assert.equal(projection.turns[0].answer, "chose yes");
  const [step] = projection.turns[0].steps;
  assert.deepEqual(stepLine(step), ["Allowed", "rm -rf build"]);
  assert.equal(projection.turns[0].summary, "1 decision");
});

test("the plan reports progress and the current step", () => {
  const { plan } = projectConversation([event("plan.updated", { items: [
    { title: "Look", state: "completed" },
    { title: "Fix", state: "in_progress" },
    { title: "Test", state: "pending" },
  ] })]);
  assert.deepEqual([plan.done, plan.total, plan.current], [1, 3, "Fix"]);
});

test("errors and notices stay with their turn", () => {
  const { turns } = projectConversation([
    event("message.created", { role: "user", content: "go", messageId: "u" }, "3"),
    event("error", { error: "the agent exited" }, "3"),
    event("message.created", { role: "system", content: "Stopped at the token limit." }, "3"),
    event("turn.failed", {}, "3"),
  ]);
  assert.deepEqual(turns[0].errors.map(error => error.text), ["the agent exited"]);
  assert.deepEqual(turns[0].notices.map(notice => notice.text), ["Stopped at the token limit."]);
  assert.equal(turns[0].status, "failed");
});

test("summaries count unique files and fold unknown tools", () => {
  assert.equal(summarizeSteps([
    { kind: "tool", toolKind: "read", detail: "a" },
    { kind: "tool", toolKind: "read", detail: "a" },
    { kind: "tool", toolKind: "read", detail: "b" },
    { kind: "tool", toolKind: "grep", detail: "x" },
    { kind: "tool", toolKind: "grep", detail: "y" },
    { kind: "tool", toolKind: "tool", detail: "mcp" },
  ]), "Read 2 files · Searched 2 times · 1 other step");
});

test("step lines use a present verb while running", () => {
  assert.deepEqual(stepLine({ kind: "tool", toolKind: "ran", status: "running", detail: "make" }), ["Running", "make"]);
  assert.deepEqual(stepLine({ kind: "tool", toolKind: "ran", status: "completed", detail: "make" }), ["Ran", "make"]);
  assert.deepEqual(stepLine({ kind: "tool", toolKind: "tool", status: "completed", title: "mcp_x", detail: "mcp_x" }), ["mcp_x", ""]);
});

test("streaming text grows in whole words", () => {
  assert.equal(visibleStreamingText("Hello wor", false), "Hello ");
  assert.equal(visibleStreamingText("Hello wor", true), "Hello wor");
  assert.equal(visibleStreamingText("你好，世界", false), "你好，");
  assert.equal(visibleStreamingText("partial", false), "");
});

test("helpers", () => {
  assert.equal(formatElapsed(72_000), "1m 12s");
  assert.equal(formatElapsed(5_000), "5s");
  assert.deepEqual(orderDecisionOptions([{ kind: "reject_once" }, { kind: "allow_always" }, { kind: "allow_once" }]).map(option => option.kind), ["allow_once", "allow_always", "reject_once"]);
  assert.equal(isACPSession({ runtimeKind: "acp" }), true);
  assert.equal(isACPSession({ agentHandler: "tui" }), false);
});

test("the latest config.updated is the agent's whole selector set", () => {
  const events = [
    event("config.updated", { configId: "acp-config", configOptions: [
      { id: "model", name: "Model", category: "model", currentValue: "small", options: [{ value: "small", name: "Small" }] },
    ] }, "0"),
    event("config.updated", { configId: "acp-config", configOptions: [
      { id: "effort", name: "Effort", category: "thought_level", currentValue: "high", options: [{ value: "high", name: "High" }] },
      { id: "model", name: "Model", category: "model", currentValue: "large", options: [{ value: "small", name: "Small" }, { value: "large", name: "Large", group: "Smart" }] },
      { id: "mode", name: "Mode", category: "mode", currentValue: "auto", options: [{ value: "auto", name: "Auto" }] },
      { id: "empty", name: "Empty", options: [] },
    ] }, "0"),
  ];
  const { config, turns } = projectConversation(events);
  assert.equal(turns.length, 0);
  assert.deepEqual(config.map(option => option.id), ["effort", "model", "mode"]);
  assert.equal(config[1].currentName, "Large");
  assert.equal(config[1].options[1].group, "Smart");
  assert.equal(composerChips(config).mode?.id, config.find(option => option.category === "mode")?.id);
  assert.equal(composerChips(config).modelSummary.startsWith("Large"), true);
  assert.equal(composerChips([]).modelSummary, "");
});

test("a tool step keeps the terminal Session it ran in", () => {
  const { turns } = projectConversation([
    event("turn.started"),
    event("tool.started", { callId: "t1", toolKind: "ran", toolDetail: "npm test", terminalSessionId: "s-term" }),
    event("tool.completed", { callId: "t1", toolKind: "ran", output: "ok" }),
    event("turn.completed"),
  ]);
  assert.equal(turns[0].steps[0].terminalSessionId, "s-term");
});

test("step targets drop the cd prefix and the Session directory", () => {
  assert.equal(displayTarget("cd /repo/wt && git status", "/repo/wt"), "git status");
  assert.equal(displayTarget("/repo/wt/Sources/A.swift", "/repo/wt"), "Sources/A.swift");
  assert.equal(displayPath("/tmp/x.md", "/repo/wt"), "/tmp/x.md");
});

test("composer chips put the model before its effort and hide a default effort", () => {
  const option = (id, category, current, choices) => ({ id, name: id, category, currentValue: current, currentName: choices.find(c => c[0] === current)[1], options: choices.map(([value, name]) => ({ value, name })) });
  const config = [
    option("mode", "mode", "auto", [["auto", "Auto"]]),
    option("fast", "model_config", "off", [["on", "On"], ["off", "Off"]]),
    option("effort", "thought_level", "default", [["default", "Default"], ["high", "High"]]),
    option("model", "model", "default", [["default", "Default (recommended)"], ["opus", "Opus 5.5"]]),
  ];
  const chips = composerChips(config);
  assert.deepEqual(chips.modelOptions.map(item => item.id), ["model", "effort", "fast"]);
  assert.equal(chips.modelSummary, "Default");
});

test("state events from before the loaded window reach the projection", () => {
  const config = { sequence: 3, type: "config.updated", payload: { configOptions: [{ id: "model", category: "model", currentValue: "a", options: [{ value: "a", name: "A" }] }] } };
  const page = [{ sequence: 40, type: "turn.started", turnId: "9" }];
  const merged = withStateEvents(page, [config]);
  assert.deepEqual(merged.map(event => event.sequence), [3, 40]);
  assert.equal(projectConversation(merged).config[0].id, "model");
  assert.equal(withStateEvents(page, []), page);
});
