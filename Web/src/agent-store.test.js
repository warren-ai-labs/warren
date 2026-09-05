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
    event(1, "evt-1", "message.created"),
    event(2, "evt-2", "message.delta"),
    event(4, "evt-4", "message.delta"),
  ]);
  await saveAgentEventsForStream(shared, "exec-1", [
    event(1, "shared-evt-1", "message.created"),
  ]);

  let state = await getAgentSyncState(owner, "exec-1");
  assert.equal(state.headSequence, 4);
  assert.equal(state.contiguousThrough, 2);
  assert.equal((await loadRecentAgentEventsForStream(shared, "exec-1")).length, 1);
  assert.equal((await loadRecentAgentEventsForStream(owner, "exec-1")).length, 3);

  await saveAgentEventsForStream(owner, "exec-1", [
    event(3, "evt-3", "message.delta"),
  ]);
  state = await getAgentSyncState(owner, "exec-1");
  assert.equal(state.contiguousThrough, 4);
  await assert.rejects(
    saveAgentEventsForStream(owner, "exec-1", [event(3, "evt-3", "message.delta", { changed: true })]),
    /conflict/,
  );
  await clearAgentStream(owner, "exec-1");
});

function event(sequence, eventId, type, payload = {}) {
  return { sequence, eventId, streamId: "exec-1", executionId: "exec-1", type, payload, occurredAt: "2026-01-01T00:00:00Z", recordedAt: "2026-01-01T00:00:00Z", origin: { kind: "host", confidence: "native" } };
}

test("replica rejects malformed envelopes and rolls back a conflicting batch", async () => {
  const scope = agentReplicaNamespace("host-b", "owner");
  const first = event(1, "evt-1", "future.event");
  await saveAgentEventsForStream(scope, "exec-1", [first]);
  await assert.rejects(saveAgentEventsForStream(scope, "exec-1", [{ ...first, sequence: undefined, seq: 2 }]), /Invalid canonical/);
  await assert.rejects(saveAgentEventsForStream(scope, "exec-1", [event(2, "evt-2", "future.event"), { ...first, payload: { conflict: true } }]), /conflict/);
  assert.equal((await loadRecentAgentEventsForStream(scope, "exec-1")).length, 1);
  await assert.rejects(saveAgentEventsForStream(scope, "exec-1", [{ ...first, sequence: 2 }]), /conflict/);
});
