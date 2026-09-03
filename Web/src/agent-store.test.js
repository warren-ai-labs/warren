import test from "node:test";
import assert from "node:assert/strict";
import {
  saveAgentEvents,
  loadRecentAgentEvents,
  getAgentMaxSequence,
  clearAgentSession,
} from "./agent-store.js";

test("saveAgentEvents and loadRecentAgentEvents round trips events", async () => {
  const sessionID = "sess-web-1";
  const epoch = 100;

  const events = [
    { seq: 1, type: "user", role: "user", content: "hello" },
    { seq: 2, type: "message", role: "assistant", content: "world" },
    { seq: 3, type: "tool_call", toolName: "view_file" },
  ];

  await saveAgentEvents(sessionID, epoch, events);

  const maxSeq = await getAgentMaxSequence(sessionID, epoch);
  assert.equal(maxSeq, 3);

  const loaded = await loadRecentAgentEvents(sessionID, 10);
  assert.equal(loaded.length, 3);
  assert.equal(loaded[0].seq, 1);
  assert.equal(loaded[0].content, "hello");
  assert.equal(loaded[1].seq, 2);
  assert.equal(loaded[1].content, "world");
  assert.equal(loaded[2].seq, 3);
  assert.equal(loaded[2].toolName, "view_file");
});

test("clearAgentSession removes stored events and reset maxSequence", async () => {
  const sessionID = "sess-web-clear";
  const epoch = 200;

  await saveAgentEvents(sessionID, epoch, [{ seq: 1, content: "to be cleared" }]);
  let loaded = await loadRecentAgentEvents(sessionID, 10);
  assert.equal(loaded.length, 1);

  await clearAgentSession(sessionID);

  loaded = await loadRecentAgentEvents(sessionID, 10);
  assert.equal(loaded.length, 0);
  const maxSeq = await getAgentMaxSequence(sessionID, epoch);
  assert.equal(maxSeq, 0);
});
