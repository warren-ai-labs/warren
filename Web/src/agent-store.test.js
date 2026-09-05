import test from "node:test";
import assert from "node:assert/strict";
import {
  agentReplicaNamespace,
  saveAgentEventsForStream,
  loadRecentAgentEventsForStream,
  getAgentSyncState,
  clearAgentStream,
} from "./agent-store.js";

test("namespace-aware replica isolates scopes and advances the contiguous cursor", async () => {
  const owner = agentReplicaNamespace("host-a", "scope-owner");
  const shared = agentReplicaNamespace("host-a", "scope-shared");
  await saveAgentEventsForStream(owner, "exec-1", [
    { sequence: 1, eventId: "evt-1", type: "message.created" },
    { sequence: 2, eventId: "evt-2", type: "message.delta" },
    { sequence: 4, eventId: "evt-4", type: "message.delta" },
  ]);
  await saveAgentEventsForStream(shared, "exec-1", [
    { sequence: 1, eventId: "shared-evt-1", type: "message.created" },
  ]);

  let state = await getAgentSyncState(owner, "exec-1");
  assert.equal(state.headSequence, 4);
  assert.equal(state.contiguousThrough, 2);
  assert.equal((await loadRecentAgentEventsForStream(shared, "exec-1")).length, 1);
  assert.equal((await loadRecentAgentEventsForStream(owner, "exec-1")).length, 3);

  await saveAgentEventsForStream(owner, "exec-1", [
    { sequence: 3, eventId: "evt-3", type: "message.delta" },
  ]);
  state = await getAgentSyncState(owner, "exec-1");
  assert.equal(state.contiguousThrough, 4);
  await assert.rejects(
    saveAgentEventsForStream(owner, "exec-1", [{ sequence: 3, eventId: "evt-3", type: "message.delta", payload: { changed: true } }]),
    /sequence conflict/,
  );
  await clearAgentStream(owner, "exec-1");
});
