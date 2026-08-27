import test from "node:test";
import assert from "node:assert/strict";

import {
  AgentCompletionEventChannel,
  AgentTurnCompletionTracker,
  agentCompletionSoundStorageKey,
  loadAgentCompletionSoundEnabled,
  saveAgentCompletionSoundEnabled,
} from "./notifications.js";

test("agent completion event channel publishes and unsubscribes listeners", () => {
  const channel = new AgentCompletionEventChannel();
  const received = [];
  const unsubscribe = channel.subscribe(event => received.push(event));

  channel.emit({ sessionID: "session-1" });
  unsubscribe();
  channel.emit({ sessionID: "session-2" });

  assert.deepEqual(received, [{ sessionID: "session-1" }]);
});

test("agent completion tracker seeds its initial roster without a notification", () => {
  const tracker = new AgentTurnCompletionTracker();

  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 4, status: "completed" } },
  ]), []);
});

test("agent completion tracker emits each successful turn once", () => {
  const tracker = new AgentTurnCompletionTracker();
  tracker.observe([{ id: "session-1", agentTurn: { id: 4, status: "started" } }]);

  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 4, status: "completed" } },
  ]), ["session-1"]);
  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 4, status: "completed" } },
  ]), []);
  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 5, status: "completed" } },
  ]), ["session-1"]);
});

test("agent completion tracker ignores failed, aborted, and reset turns", () => {
  const tracker = new AgentTurnCompletionTracker();
  tracker.observe([{ id: "session-1", agentTurn: { id: 5, status: "completed" } }]);

  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 6, status: "failed" } },
    { id: "session-2", agentTurn: { id: 1, status: "aborted" } },
  ]), []);
  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 1, status: "completed" } },
  ]), []);
  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 2, status: "completed" } },
  ]), ["session-1"]);
});

test("agent completion tracker treats a reconnect roster as a fresh baseline", () => {
  const tracker = new AgentTurnCompletionTracker();
  tracker.observe([{ id: "session-1", agentTurn: { id: 4, status: "started" } }]);

  tracker.reset();
  assert.deepEqual(tracker.observe([
    { id: "session-1", agentTurn: { id: 4, status: "completed" } },
  ]), []);
});

test("agent completion sound preference defaults on and persists explicit values", () => {
  const values = new Map();
  const storage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };

  assert.equal(loadAgentCompletionSoundEnabled(storage), true);
  saveAgentCompletionSoundEnabled(false, storage);
  assert.equal(values.get(agentCompletionSoundStorageKey), "false");
  assert.equal(loadAgentCompletionSoundEnabled(storage), false);
  saveAgentCompletionSoundEnabled(true, storage);
  assert.equal(loadAgentCompletionSoundEnabled(storage), true);
});
