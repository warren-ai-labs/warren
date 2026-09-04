import test from "node:test";
import assert from "node:assert/strict";

import {
  agentDraftKey,
  agentEventLimit,
  agentQueueKey,
  agentComposerAction,
  composerHeightForText,
  deleteAgentQueueItem,
  displayToolName,
  editAgentQueueItem,
  enqueueAgentMessage,
  extractPatchFiles,
  formatAgentModel,
  groupAgentEvents,
  isCommandTool,
  latestAgentAction,
  mergeAgentEvents,
  moveAgentQueueItem,
  projectAgentEvents,
  retryAgentQueueItem,
  toolSummary,
} from "./agent.js";

test("formatAgentModel turns wire names into readable labels", () => {
  assert.equal(formatAgentModel("5.6-sol"), "5.6 Sol");
  assert.equal(formatAgentModel("openai/gpt-5.4"), "GPT 5.4");
  assert.equal(formatAgentModel("z-ai/xxx-xxx-xx"), "Xxx Xxx Xx");
  assert.equal(formatAgentModel("z-ai/glm-4-flash"), "Glm 4 Flash");
  assert.equal(formatAgentModel("anthropic/claude-3-7-sonnet-20250219"), "Claude 3.7 Sonnet");
  assert.equal(formatAgentModel("claude-3-5-haiku-20241022"), "Claude 3.5 Haiku");
  assert.equal(formatAgentModel("openai/gpt-4o"), "GPT 4o");
  assert.equal(formatAgentModel("deepseek/deepseek-r1"), "DeepSeek R1");
  assert.equal(formatAgentModel("deepseek-chat"), "DeepSeek Chat");
  assert.equal(formatAgentModel("google/gemini-2-5-pro"), "Gemini 2.5 Pro");
  assert.equal(formatAgentModel("qwen/qwen-2.5-coder-32b-instruct"), "Qwen 2.5 Coder 32B Instruct");
  assert.equal(formatAgentModel("o1-mini"), "o1 Mini");
  assert.equal(formatAgentModel(""), "");
});

test("composerHeightForText starts at two lines and caps at six", () => {
  assert.equal(composerHeightForText(""), 60);
  assert.equal(composerHeightForText("one\ntwo\nthree"), 82);
  assert.equal(composerHeightForText(Array.from({ length: 20 }, () => "line").join("\n")), 148);
});

test("agentComposerAction switches the primary button to interrupt while working", () => {
  assert.equal(agentComposerAction({ activity: "working" }, { hasControl: true }), "interrupt");
  assert.equal(agentComposerAction({ activity: "ready" }, { hasControl: true, hasText: true }), "send");
  assert.equal(agentComposerAction({ activity: "failed" }, { hasControl: true, hasText: true }), "unavailable");
  assert.equal(
    agentComposerAction({ activity: "blocked", attention: { kind: "approval" } }, { hasControl: true, hasText: true }),
    "unavailable",
  );
  assert.equal(agentComposerAction({ activity: "blocked" }, { hasControl: true, hasText: true }), "unavailable");
  assert.equal(
    agentComposerAction({ activity: "blocked", attention: { kind: "input" } }, { hasControl: true, hasText: true }),
    "send",
  );
});

test("agent queue remains immutable while editing, ordering and retrying", () => {
  let queue = enqueueAgentMessage([], " first ", "a");
  queue = enqueueAgentMessage(queue, "second", "b");
  assert.deepEqual(queue.map(item => item.text), ["first", "second"]);
  const edited = editAgentQueueItem(queue, "a", "updated");
  assert.deepEqual(queue.map(item => item.text), ["first", "second"]);
  assert.deepEqual(edited.map(item => item.text), ["updated", "second"]);
  const moved = moveAgentQueueItem(edited, 0, 2);
  assert.deepEqual(moved.map(item => item.id), ["b", "a"]);
  const retried = retryAgentQueueItem(moved, "a");
  assert.deepEqual(retried.map(item => item.id), ["a", "b"]);
  assert.deepEqual(deleteAgentQueueItem(retried, "a").map(item => item.id), ["b"]);
});

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
    { seq: 2, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
    { seq: 3, type: "tool_output", callId: "call-1", toolStatus: "success", output: "file.txt\n" },
    { seq: 4, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "activity_group", "assistant"]);
  assert.equal(blocks[1].tools[0].call.toolName, "shell");
  assert.equal(blocks[1].tools[0].outputs.length, 1);
  assert.equal(blocks[1].tools[0].outputs[0].output, "file.txt\n");
});

test("groupAgentEvents splits activity at each visible message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "hello" },
    { seq: 2, type: "reasoning", content: "think one" },
    { seq: 3, type: "assistant", content: "checking" },
    { seq: 4, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
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
  assert.equal(blocks[3].tools[0].call.toolName, "shell");
  assert.deepEqual(blocks[3].order.map(item => item.kind), ["tool", "reasoning"]);
});

test("groupAgentEvents folds standalone tool runs without a user message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
    { seq: 2, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "edit", toolInput: { file_path: "x.ts" } },
    { seq: 4, type: "tool_output", callId: "call-2", toolStatus: "success", output: "ok" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group"]);
  assert.equal(blocks[0].tools.length, 2);
  assert.deepEqual(blocks[0].tools.map(item => item.call.toolName), ["shell", "edit"]);
});

test("groupAgentEvents resets folding at each user message", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
    { seq: 2, type: "user", content: "again" },
    { seq: 3, type: "tool_call", callId: "call-2", toolName: "edit", toolInput: { file_path: "x.ts" } },
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
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "shell" },
    { seq: 2, type: "assistant", content: "partial reply" },
    { seq: 3, type: "tool_output", callId: "call-1", output: "late result" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "assistant", "tool_output"]);
  assert.equal(blocks[0].tools[0].outputs.length, 0);
  assert.equal(blocks[2].event.output, "late result");
});

test("projectAgentEvents keeps structured cards as activity boundaries", () => {
  const blocks = projectAgentEvents([
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "shell" },
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
    { seq: 1, type: "tool_call", callId: "call-1", toolName: "shell" },
    { seq: 2, type: "message", role: "assistant", content: "progress" },
    { seq: 3, type: "reasoning", content: "next step" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "assistant", "activity_group"]);
});

test("groupAgentEvents coalesces OpenCode content deltas by part", () => {
  const blocks = groupAgentEvents([
    { seq: 1, id: "user-part", type: "user", content: "fix" },
    { seq: 2, id: "assistant-part", type: "assistant", content: "hel" },
    { seq: 3, id: "assistant-part", type: "assistant", content: "lo", contentDelta: true },
    { seq: 4, id: "reasoning-part", type: "reasoning", content: "think" },
    { seq: 5, id: "reasoning-part", type: "reasoning", content: " more", contentDelta: true },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "assistant", "activity_group"]);
  assert.equal(blocks[1].event.content, "hello");
  assert.equal(blocks[2].reasoning[0].content, "think more");
});

test("groupAgentEvents replaces a rewritten OpenCode part", () => {
  const blocks = groupAgentEvents([
    { seq: 1, id: "assistant-part", type: "assistant", content: "draft" },
    { seq: 2, id: "assistant-part", type: "assistant", content: "final" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].event.content, "final");
});

test("latestAgentAction extracts recent tool call and output summaries", () => {
  assert.equal(latestAgentAction([]), "");
  assert.equal(latestAgentAction([{ seq: 1, type: "user", content: "hi" }]), "");

  assert.equal(
    latestAgentAction([
      { seq: 1, type: "tool_call", toolName: "shell", toolInput: { command: "npm test" } },
    ]),
    "Shell npm test",
  );

  assert.equal(
    latestAgentAction([
      { seq: 1, type: "tool_call", toolName: "shell", toolInput: { command: "npm test" } },
      { seq: 2, type: "tool_call", toolName: "edit", toolInput: { file_path: "src/math.ts" } },
    ]),
    "Edit file src/math.ts",
  );

  assert.equal(
    latestAgentAction([
      { seq: 1, type: "tool_call", toolName: "edit", toolInput: { file_path: "src/math.ts" } },
      { seq: 2, type: "tool_output", toolName: "edit" },
    ]),
    "Edit file",
  );
});

test("displayToolName maps provider tool names to human labels", () => {
  assert.equal(displayToolName("shell"), "Shell");
  assert.equal(displayToolName("exec"), "Shell");
  assert.equal(displayToolName("run_command"), "Shell");
  assert.equal(displayToolName("edit"), "Edit file");
  assert.equal(displayToolName("replace_file_content"), "Edit file");
  assert.equal(displayToolName("write_to_file"), "Write file");
  assert.equal(displayToolName("view_file"), "Read file");
  assert.equal(displayToolName("grep_search"), "Search files");
  assert.equal(displayToolName("find_by_name"), "Find files");
  assert.equal(displayToolName("search_web"), "Web search");
  assert.equal(displayToolName("read_url_content"), "Web fetch");
});

test("toolSummary extracts rich details across Codex and Antigravity tool shapes", () => {
  // Shell command with affected files
  assert.equal(
    toolSummary({
      toolName: "shell",
      toolInput: { command: "git checkout -b feature" },
      files: ["src/a.go", "src/b.go"],
    }),
    "git checkout -b feature · a.go, b.go",
  );

  // Codex raw exec
  assert.equal(
    toolSummary({
      toolName: "exec",
      toolInput: { raw: 'exec_command({"cmd": "npm run check"})' },
    }),
    "npm run check",
  );

  // Antigravity file read with action
  assert.equal(
    toolSummary({
      toolName: "view_file",
      toolInput: { AbsolutePath: "/Users/user/workspace/src/agent.js", toolAction: "Viewing agent.js" },
    }),
    "Viewing agent.js: agent.js",
  );

  // Antigravity replace_file_content
  assert.equal(
    toolSummary({
      toolName: "replace_file_content",
      toolInput: { TargetFile: "/Users/user/workspace/src/agent.jsx" },
    }),
    "agent.jsx",
  );

  // Antigravity run_command
  assert.equal(
    toolSummary({
      toolName: "run_command",
      toolInput: { CommandLine: "swift test" },
    }),
    "swift test",
  );

  // Patch extraction
  const patch = "*** Add File: src/new.ts\n+console.log('hi')\n*** Update File: src/old.ts\n-1\n+2";
  assert.deepEqual(extractPatchFiles(patch), ["src/new.ts", "src/old.ts"]);
  assert.equal(
    toolSummary({
      toolName: "apply_patch",
      toolInput: { patch },
    }),
    "new.ts, old.ts",
  );
});

test("groupAgentEvents coalesces adjacent activity groups", () => {
  const blocks = groupAgentEvents([
    { seq: 1, type: "user", content: "inspect" },
    { seq: 2, type: "reasoning", content: "think step 1" },
    { seq: 3, type: "tool_call", callId: "c1", toolName: "view_file", toolInput: { AbsolutePath: "/a.js" } },
    { seq: 4, type: "tool_output", callId: "c1", output: "ok" },
    { seq: 5, type: "reasoning", content: "think step 2" },
    { seq: 6, type: "tool_call", callId: "c2", toolName: "grep_search", toolInput: { query: "foo" } },
    { seq: 7, type: "tool_output", callId: "c2", output: "ok" },
    { seq: 8, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(b => b.kind), ["user", "activity_group", "assistant"]);
  assert.equal(blocks[1].reasoning.length, 2);
  assert.equal(blocks[1].tools.length, 2);
  assert.equal(blocks[1].tools[0].call.toolName, "view_file");
  assert.equal(blocks[1].tools[1].call.toolName, "grep_search");
});

test("isCommandTool identifies shell and command executions across providers", () => {
  assert.equal(isCommandTool("shell"), true);
  assert.equal(isCommandTool("exec"), true);
  assert.equal(isCommandTool("execute"), true);
  assert.equal(isCommandTool("run_command"), true);
  assert.equal(isCommandTool("bash"), true);
  assert.equal(isCommandTool("local_shell_call"), true);
  assert.equal(isCommandTool("read"), false);
  assert.equal(isCommandTool("view_file"), false);
  assert.equal(isCommandTool("apply_patch"), false);
  assert.equal(isCommandTool(null), false);

  assert.equal(isCommandTool("custom", { command: "pytest" }), true);
  assert.equal(isCommandTool("custom", { cmd: "npm test" }), true);
  assert.equal(isCommandTool("custom", { CommandLine: "go test ./..." }), true);
  assert.equal(isCommandTool("custom", { query: "foo" }), false);
});

