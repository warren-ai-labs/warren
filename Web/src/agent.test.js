import test from "node:test";
import assert from "node:assert/strict";

import {
  agentDraftKey,
  agentEventLimit,
  agentLaunchCommand,
  defaultAgentLaunchCommand,
  agentModelSwitchCommand,
  agentQueueKey,
  agentReasoningResetCommand,
  agentReasoningSwitchCommand,
  agentSettingsKey,
  agentComposerAction,
  composerHeightForText,
  deleteAgentQueueItem,
  displayToolName,
  editAgentQueueItem,
  enqueueAgentMessage,
  extractPatchFiles,
  formatAgentModel,
  formatAgentReasoning,
  getAvailableAgentModels,
  groupAgentEvents,
  isCommandTool,
  latestAgentAction,
  loadAgentDraft,
  loadAgentSettings,
  mergeAgentEvents,
  normalizeCanonicalAgentEvent,
  moveAgentQueueItem,
  projectAgentEvents,
  projectAgentControlState,
  retryAgentQueueItem,
  saveAgentSettings,
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
    canonicalEvent(1, "system", "started"),
    canonicalEvent(2, "user", "hello"),
  ];
  const incoming = [
    canonicalEvent(2, "user", "hello"),
    canonicalEvent(3, "assistant", "hi"),
  ];
  const merged = mergeAgentEvents(existing.map(normalizeCanonicalAgentEvent), incoming);
  assert.deepEqual(merged.map(event => event.sequence), [1, 2, 3]);
  assert.deepEqual(merged.map(event => event.content), ["started", "hello", "hi"]);
});

test("mergeAgentEvents keeps the first event at an immutable sequence", () => {
  const merged = mergeAgentEvents(
    [normalizeCanonicalAgentEvent(canonicalEvent(7, "assistant", "first"))],
    [canonicalEvent(7, "assistant", "rewritten")],
  );
  assert.equal(merged[0].content, "first");
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
  const existing = Array.from({ length: agentEventLimit }, (_, index) => (canonicalEvent(index + 1, "system", "")));
  const incoming = [canonicalEvent(agentEventLimit, "user", "new")];
  const merged = mergeAgentEvents(existing.map(normalizeCanonicalAgentEvent), incoming);
  assert.equal(merged.length, agentEventLimit);
  assert.equal(merged[0].sequence, 1);
  assert.equal(merged.at(-1).sequence, agentEventLimit);
});

test("mergeAgentEvents keeps older pages intact when paginating", () => {
  const existing = Array.from({ length: agentEventLimit }, (_, index) => normalizeCanonicalAgentEvent(canonicalEvent(index + 2001)));
  const olderPage = Array.from({ length: 200 }, (_, index) => canonicalEvent(index + 1801, "user", `old-${index}`));
  const merged = mergeAgentEvents(existing, olderPage, { cap: false });
  assert.equal(merged.length, agentEventLimit + 200);
  assert.equal(merged[0].sequence, 1801);
  assert.equal(merged.at(-1).sequence, 4000);
  // No middle gap: every sequence from the oldest loaded event to the newest
  // live event is still present.
  assert.deepEqual(
    merged.map(event => event.sequence),
    Array.from({ length: agentEventLimit + 200 }, (_, index) => index + 1801),
  );
});

test("groupAgentEvents pairs tool calls with their outputs", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, type: "user", content: "hello" },
    { sequence: 2, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
    { sequence: 3, type: "tool_output", callId: "call-1", toolStatus: "success", output: "file.txt\n" },
    { sequence: 4, type: "assistant", content: "done" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "activity_group", "assistant"]);
  assert.equal(blocks[1].tools[0].call.toolName, "shell");
  assert.equal(blocks[1].tools[0].outputs.length, 1);
  assert.equal(blocks[1].tools[0].outputs[0].output, "file.txt\n");
});

test("groupAgentEvents splits activity at each visible message", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, type: "user", content: "hello" },
    { sequence: 2, type: "reasoning", content: "think one" },
    { sequence: 3, type: "assistant", content: "checking" },
    { sequence: 4, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
    { sequence: 5, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { sequence: 6, type: "reasoning", content: "think two" },
    { sequence: 7, type: "assistant", content: "done" },
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
    { sequence: 1, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
    { sequence: 2, type: "tool_output", callId: "call-1", toolStatus: "success", output: "a\n" },
    { sequence: 3, type: "tool_call", callId: "call-2", toolName: "edit", toolInput: { file_path: "x.ts" } },
    { sequence: 4, type: "tool_output", callId: "call-2", toolStatus: "success", output: "ok" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group"]);
  assert.equal(blocks[0].tools.length, 2);
  assert.deepEqual(blocks[0].tools.map(item => item.call.toolName), ["shell", "edit"]);
});

test("groupAgentEvents resets folding at each user message", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, type: "tool_call", callId: "call-1", toolName: "shell", toolInput: { command: "ls" } },
    { sequence: 2, type: "user", content: "again" },
    { sequence: 3, type: "tool_call", callId: "call-2", toolName: "edit", toolInput: { file_path: "x.ts" } },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "user", "activity_group"]);
  assert.equal(blocks[0].tools.length, 1);
  assert.equal(blocks[2].tools.length, 1);
});

test("groupAgentEvents keeps unmatched tool outputs standalone", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, type: "tool_output", callId: "unknown", output: "orphan" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].kind, "tool_output");
});

test("groupAgentEvents does not attach a late tool output to an earlier message", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, type: "tool_call", callId: "call-1", toolName: "shell" },
    { sequence: 2, type: "assistant", content: "partial reply" },
    { sequence: 3, type: "tool_output", callId: "call-1", output: "late result" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "assistant", "tool_output"]);
  assert.equal(blocks[0].tools[0].outputs.length, 0);
  assert.equal(blocks[2].event.output, "late result");
});

test("projectAgentEvents keeps structured cards as activity boundaries", () => {
  const blocks = projectAgentEvents([
    { sequence: 1, type: "tool_call", callId: "call-1", toolName: "shell" },
    { sequence: 2, id: "question-1", type: "question", payload: { state: "pending" } },
    { sequence: 3, type: "reasoning", content: "after the question" },
    { sequence: 4, id: "question-1", type: "question", payload: { state: "resolved" } },
    { sequence: 5, type: "reasoning", content: "after resolution" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "structured", "activity_group"]);
  assert.equal(blocks[1].event.payload.state, "resolved");
  assert.deepEqual(blocks[2].reasoning.map(event => event.content), ["after resolution"]);
});

test("groupAgentEvents treats role-only messages as visible message boundaries", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, type: "tool_call", callId: "call-1", toolName: "shell" },
    { sequence: 2, type: "message", role: "assistant", content: "progress" },
    { sequence: 3, type: "reasoning", content: "next step" },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["activity_group", "assistant", "activity_group"]);
});

test("groupAgentEvents coalesces OpenCode content deltas by part", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, id: "user-part", type: "user", content: "fix" },
    { sequence: 2, id: "assistant-part", type: "assistant", content: "hel" },
    { sequence: 3, id: "assistant-part", type: "assistant", content: "lo", contentDelta: true },
    { sequence: 4, id: "reasoning-part", type: "reasoning", content: "think" },
    { sequence: 5, id: "reasoning-part", type: "reasoning", content: " more", contentDelta: true },
  ]);
  assert.deepEqual(blocks.map(block => block.kind), ["user", "assistant", "activity_group"]);
  assert.equal(blocks[1].event.content, "hello");
  assert.equal(blocks[2].reasoning[0].content, "think more");
});

test("groupAgentEvents replaces a rewritten OpenCode part", () => {
  const blocks = groupAgentEvents([
    { sequence: 1, id: "assistant-part", type: "assistant", content: "draft" },
    { sequence: 2, id: "assistant-part", type: "assistant", content: "final" },
  ]);
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].event.content, "final");
});

test("latestAgentAction extracts recent tool call and output summaries", () => {
  assert.equal(latestAgentAction([]), "");
  assert.equal(latestAgentAction([{ sequence: 1, type: "user", content: "hi" }]), "");

  assert.equal(
    latestAgentAction([
      { sequence: 1, type: "tool_call", toolName: "shell", toolInput: { command: "npm test" } },
    ]),
    "Shell npm test",
  );

  assert.equal(
    latestAgentAction([
      { sequence: 1, type: "tool_call", toolName: "shell", toolInput: { command: "npm test" } },
      { sequence: 2, type: "tool_call", toolName: "edit", toolInput: { file_path: "src/math.ts" } },
    ]),
    "Edit file src/math.ts",
  );

  assert.equal(
    latestAgentAction([
      { sequence: 1, type: "tool_call", toolName: "edit", toolInput: { file_path: "src/math.ts" } },
      { sequence: 2, type: "tool_output", toolName: "edit" },
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
    { sequence: 1, type: "user", content: "inspect" },
    { sequence: 2, type: "reasoning", content: "think step 1" },
    { sequence: 3, type: "tool_call", callId: "c1", toolName: "view_file", toolInput: { AbsolutePath: "/a.js" } },
    { sequence: 4, type: "tool_output", callId: "c1", output: "ok" },
    { sequence: 5, type: "reasoning", content: "think step 2" },
    { sequence: 6, type: "tool_call", callId: "c2", toolName: "grep_search", toolInput: { query: "foo" } },
    { sequence: 7, type: "tool_output", callId: "c2", output: "ok" },
    { sequence: 8, type: "assistant", content: "done" },
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

test("getAvailableAgentModels returns provider-appropriate presets", () => {
  const claudeModels = getAvailableAgentModels("claude");
  assert.ok(claudeModels.some(m => m.id === "claude-3-7-sonnet"));

  const codexModels = getAvailableAgentModels("codex");
  assert.ok(codexModels.some(m => m.id === "gpt-5"));

  const antigravityModels = getAvailableAgentModels("antigravity");
  assert.ok(antigravityModels.some(m => m.id === "gemini-2.5-pro"));

  const fallbackModels = getAvailableAgentModels("unknown-provider");
  assert.ok(fallbackModels.length > 0);
});

test("formatAgentReasoning formats labels correctly", () => {
  assert.equal(formatAgentReasoning("default"), "Default");
  assert.equal(formatAgentReasoning("off"), "Off");
  assert.equal(formatAgentReasoning("low"), "Low");
  assert.equal(formatAgentReasoning("medium"), "Medium");
  assert.equal(formatAgentReasoning("high"), "High");
  assert.equal(formatAgentReasoning("unknown"), "Default");
});

test("agentModelSwitchCommand generates /model command", () => {
  assert.equal(agentModelSwitchCommand("gpt-5"), "/model gpt-5");
  assert.equal(agentModelSwitchCommand("claude-3-7-sonnet"), "/model claude-3-7-sonnet");
  assert.equal(agentModelSwitchCommand(""), "");
  assert.equal(agentModelSwitchCommand("   "), "");
  assert.equal(agentModelSwitchCommand("model\n-id"), "/model model -id");
});

test("agentReasoningSwitchCommand formats /effort or /thinking commands", () => {
  assert.equal(agentReasoningSwitchCommand("default", "codex"), "");
  assert.equal(agentReasoningSwitchCommand("high", "codex"), "/effort high");
  assert.equal(agentReasoningSwitchCommand("low", "claude"), "/effort low");
  assert.equal(agentReasoningSwitchCommand("high", "pi"), "/thinking high");
  assert.equal(agentReasoningSwitchCommand("high", "PI"), "/thinking high");
  assert.equal(agentReasoningSwitchCommand("off", "pi"), "/thinking off");
  assert.equal(agentReasoningSwitchCommand("invalid", "codex"), "");
  assert.equal(agentReasoningResetCommand("pi"), "/thinking default");
  assert.equal(agentReasoningResetCommand("claude-code"), "/effort default");
  assert.equal(agentReasoningResetCommand("codex"), "/effort default");
});

test("agentLaunchCommand leaves defaults unchanged and adds provider flags", () => {
  assert.equal(agentLaunchCommand("codex --dangerously-bypass-hook-trust", "codex"), "codex --dangerously-bypass-hook-trust");
  assert.equal(
    agentLaunchCommand("claude", "claude", { model: "claude-3-7-sonnet", reasoning: "high" }),
    "claude --model 'claude-3-7-sonnet' --effort high",
  );
  assert.equal(
    agentLaunchCommand("pi", "pi", { model: "provider/model", reasoning: "off" }),
    "pi --model 'provider/model' --thinking off",
  );
  assert.equal(
    agentLaunchCommand("qoder", "qoder", { model: "m", reasoning: "medium" }),
    "qoder --model 'm' --reasoning-effort medium",
  );
  assert.equal(
    agentLaunchCommand("", "codex", { model: "gpt-5" }),
    "codex --dangerously-bypass-hook-trust --model 'gpt-5'",
  );
  assert.equal(
    agentLaunchCommand("", "codex", { reasoning: "off" }),
    "codex --dangerously-bypass-hook-trust",
  );
  assert.equal(
    agentLaunchCommand("", "opencode", { model: "provider/it's-model" }),
    "opencode --model 'provider/it'\\''s-model'",
  );
  assert.equal(defaultAgentLaunchCommand("claude-code"), "claude");
});

test("loadAgentSettings and saveAgentSettings round-trip settings in storage", () => {
  const mockStorage = {
    _data: {},
    getItem(key) { return this._data[key] || null; },
    setItem(key, value) { this._data[key] = value; },
    removeItem(key) { delete this._data[key]; },
  };

  const endpoint = "ws://localhost:8080/v1/ws";
  const sessionID = "sess-123";

  assert.equal(loadAgentSettings(mockStorage, endpoint, sessionID), null);

  const settings = { model: "claude-3-7-sonnet", reasoning: "high" };
  const saved = saveAgentSettings(mockStorage, endpoint, sessionID, settings);
  assert.equal(saved, true);

  const loaded = loadAgentSettings(mockStorage, endpoint, sessionID);
  assert.deepEqual(loaded, settings);
});

function canonicalEvent(sequence, role = "assistant", content = "") {
  return { sequence, eventId: `evt-${sequence}`, streamId: "exec-1", executionId: "exec-1", type: "message.created", occurredAt: "2026-01-01T00:00:00Z", recordedAt: "2026-01-01T00:00:00Z", origin: { kind: "host", confidence: "native" }, payload: { role, content } };
}

test("control projection waits for missing events and applies unknown types in order", () => {
  const first = { ...canonicalEvent(1), type: "status.changed", payload: { activity: "working" } };
  const missing = { ...canonicalEvent(2), type: "status.changed", payload: { activity: "ready" } };
  const future = { ...canonicalEvent(3), type: "future.event" };
  const gapped = projectAgentControlState([first, future]);
  assert.equal(gapped.projectionThrough, 1);
  assert.equal(gapped.status.activity, "working");
  const recovered = projectAgentControlState([first, missing, future], gapped);
  assert.equal(recovered.projectionThrough, 3);
  assert.equal(recovered.status.activity, "ready");
});
