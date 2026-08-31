import test from "node:test";
import assert from "node:assert/strict";

import {
  agentDraftKey,
  agentEventLimit,
  agentQueueKey,
  groupAgentEvents,
  mergeAgentEvents,
  projectAgentEvents,
} from "./agent.js";

test("mergeAgentEvents keeps sequence order and deduplicates overlap", () => {
  const existing = [
    { seq: 1, type: "system", content: "started" },
    { seq: 2, type: "user", content: "hello" },
  ];
  const incoming = [
    { seq: 2, type: "user", content: "hello" },
    { seq: 3, type: "assistant", content: "hi" },
  ];
  const merged = mergeAgentEvents(existing, incoming);
  assert.deepEqual(merged.map(event => event.seq), [1, 2, 3]);
  assert.deepEqual(merged.map(event => event.content), ["started", "hello", "hi"]);
});

test("mergeAgentEvents keeps the first event at an immutable sequence", () => {
  const merged = mergeAgentEvents(
    [{ seq: 7, type: "assistant", content: "first" }],
    [{ seq: 7, type: "assistant", content: "rewritten" }],
  );
  assert.deepEqual(merged, [{ seq: 7, type: "assistant", content: "first" }]);
});

test("agentQueueKey isolates endpoint and session identities", () => {
  assert.notEqual(agentQueueKey("wss://one.example", "session"), agentQueueKey("wss://two.example", "session"));
  assert.notEqual(agentQueueKey("wss://one.example", "session"), agentQueueKey("wss://one.example", "other"));
});

test("agentDraftKey keeps separator punctuation collision-safe", () => {
  assert.notEqual(agentDraftKey("host.a", "session"), agentDraftKey("host", "a.session"));
  assert.notEqual(agentDraftKey("wss://host", "session"), agentDraftKey("wss:/host", "session"));
});

test("mergeAgentEvents caps history at the agent event limit", () => {
  const existing = Array.from({ length: agentEventLimit }, (_, index) => ({ seq: index, type: "system" }));
  const incoming = [{ seq: agentEventLimit, type: "user", content: "new" }];
  const merged = mergeAgentEvents(existing, incoming);
  assert.equal(merged.length, agentEventLimit);
  assert.equal(merged[0].seq, 1);
  assert.equal(merged.at(-1).seq, agentEventLimit);
});

test("mergeAgentEvents keeps older pages intact when paginating", () => {
  const existing = Array.from({ length: agentEventLimit }, (_, index) => ({
    seq: index,
    type: "system",
  }));
  const olderPage = Array.from({ length: 200 }, (_, index) => ({
    seq: index - 200,
    type: "user",
    content: `old-${index}`,
  }));
  const merged = mergeAgentEvents(existing, olderPage, { cap: false });
  assert.equal(merged.length, agentEventLimit + 200);
  assert.equal(merged[0].seq, -200);
  assert.equal(merged.at(-1).seq, agentEventLimit - 1);
  // No middle gap: every sequence from the oldest loaded event to the newest
  // live event is still present.
  assert.deepEqual(
    merged.map(event => event.seq),
    Array.from({ length: agentEventLimit + 200 }, (_, index) => index - 200),
  );
});

test("groupAgentEvents pairs tool calls with their outputs", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "hello" },
    { seq: 2, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 3, type: "tool_output", callId: "call-1", toolStatus: "success", output: "file.txt\n" },
    { seq: 4, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "activity_group", "assistant"]);
  assert.equal(blocks[1].tools[0].call.toolName, "Bash");
  assert.equal(blocks[1].tools[0].outputs.length, 1);
  assert.equal(blocks[1].tools[0].outputs[0].output, "file.txt\n");
});

test("groupAgentEvents splits activity at each visible message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "hello" },
    { seq: 2, type: "reasoning", content: "think one" },
    { seq: 3, type: "assistant", content: "checking" },
    { seq: 4, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 5, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { seq: 6, type: "reasoning", content: "think two" },
    { seq: 7, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "activity_group", "assistant", "activity_group", "assistant"]);
  assert.deepEqual(blocks[1].reasoning.map(event => event.content), ["think one"]);
  assert.equal(blocks[1].tools.length, 0);
  assert.equal(blocks[3].reasoning.length, 1);
  assert.deepEqual(blocks[3].reasoning.map(event => event.content), ["think two"]);
  assert.equal(blocks[3].tools.length, 1);
  assert.equal(blocks[3].tools[0].call.toolName, "Bash");
  assert.deepEqual(blocks[3].order.map(item => item.kind), ["tool", "reasoning"]);
});

test("groupAgentEvents folds standalone tool runs without a user message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 2, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "Edit", toolInput: { file_path: "x.ts" } },
    { seq: 4, type: "tool_output", callId: "call-2", toolStatus: "success", output: "ok" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group"]);
  assert.equal(blocks[0].tools.length, 2);
  assert.deepEqual(blocks[0].tools.map(item => item.call.toolName), ["Bash", "Edit"]);
});

test("groupAgentEvents resets folding at each user message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash", toolInput: { command: "ls" } },
    { seq: 2, type: "user", content: "again" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "Edit", toolInput: { file_path: "x.ts" } },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "user", "activity_group"]);
  assert.equal(blocks[0].tools.length, 1);
  assert.equal(blocks[2].tools.length, 1);
});

test("groupAgentEvents keeps unmatched tool outputs standalone", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_output", callId: "unknown", output: "orphan" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, "tool_output");
});

test("groupAgentEvents does not attach a late tool output to an earlier message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash" },
    { seq: 2, type: "assistant", content: "partial reply" },
    { seq: 3, type: "tool_output", callId: "call-1", output: "late result" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "assistant", "tool_output"]);
  assert.equal(blocks[0].tools[0].outputs.length, 0);
  assert.equal(blocks[2].event.output, "late result");
});

test("projectAgentEvents keeps structured cards as activity boundaries", () => {
  const blocks = projectAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash" },
    { seq: 2, id: "question-1", type: "question", payload: { state: "pending" } },
    { seq: 3, type: "reasoning", content: "after the question" },
    { seq: 4, id: "question-1", type: "question", payload: { state: "resolved" } },
    { seq: 5, type: "reasoning", content: "after resolution" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "structured", "activity_group"]);
  assert.equal(blocks[1].event.payload.state, "resolved");
  assert.deepEqual(blocks[2].reasoning.map(event => event.content), ["after resolution"]);
});

test("groupAgentEvents treats role-only messages as visible message boundaries", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "Bash" },
    { seq: 2, type: "message", role: "assistant", content: "progress" },
    { seq: 3, type: "reasoning", content: "next step" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "assistant", "activity_group"]);
});

test("groupAgentEvents coalesces OpenCode content deltas by part", () => {
  const blocks = groupAgentEvents([
    { seq: 1, provider: "opencode", id: "user-part", type: "user", content: "fix" },
    { seq: 2, provider: "opencode", id: "assistant-part", type: "assistant", content: "hel" },
    { seq: 3, provider: "opencode", id: "assistant-part", type: "assistant", content: "lo", contentDelta: true },
    { seq: 4, provider: "opencode", id: "reasoning-part", type: "reasoning", content: "think" },
    { seq: 5, provider: "opencode", id: "reasoning-part", type: "reasoning", content: " more", contentDelta: true },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "assistant", "activity_group"]);
  assert.equal(blocks[1].event.content, "hello");
  assert.equal(blocks[2].reasoning[0].content, "think more");
});

test("groupAgentEvents replaces a rewritten OpenCode part", () => {
  const blocks = groupAgentEvents([
    { seq: 1, provider: "opencode", id: "assistant-part", type: "assistant", content: "draft" },
    { seq: 2, provider: "opencode", id: "assistant-part", type: "assistant", content: "final" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].event.content, "final");
});
