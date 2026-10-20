import test from "node:test";
import assert from "node:assert/strict";

// A minimal in-process IndexedDB: enough of the API for agent-store.js to run
// its IndexedDB path (array keys, indexes, cursors, auto-commit and abort
// rollback). Requests resolve on later macrotasks, as in a browser.

function compareKeys(left, right) {
  if (Array.isArray(left) && Array.isArray(right)) {
    for (let index = 0; index < Math.min(left.length, right.length); index += 1) {
      const order = compareKeys(left[index], right[index]);
      if (order) return order;
    }
    return left.length - right.length;
  }
  if (typeof left !== typeof right) return typeof left === "number" ? -1 : 1;
  return left < right ? -1 : left > right ? 1 : 0;
}

class FakeKeyRange {
  constructor(lower, upper) { this.lower = lower; this.upper = upper; }
  static bound(lower, upper) { return new FakeKeyRange(lower, upper); }
  includes(key) { return compareKeys(key, this.lower) >= 0 && compareKeys(key, this.upper) <= 0; }
}

const keyOf = (value, path) => (Array.isArray(path) ? path.map(part => value[part]) : value[path]);
const later = callback => setTimeout(callback, 0);

class FakeRequest {
  constructor(tx, run) {
    tx.pending += 1;
    later(() => {
      if (tx.finished) return;
      try {
        this.result = run();
        this.onsuccess?.({ target: this });
      } catch (error) {
        this.error = error;
        this.onerror?.({ target: this });
        tx.abort(error);
      }
      tx.pending -= 1;
      tx.settle();
    });
  }
}

class FakeStoreData {
  constructor(keyPath) { this.keyPath = keyPath; this.rows = new Map(); this.indexes = new Map(); }
  clone() {
    const copy = new FakeStoreData(this.keyPath);
    copy.rows = new Map(this.rows);
    copy.indexes = this.indexes;
    return copy;
  }
  sorted() { return [...this.rows.values()].sort((left, right) => compareKeys(left.key, right.key)); }
}

class FakeIndex {
  constructor(tx, data, spec) { this.tx = tx; this.data = data; this.spec = spec; }
  entries(range) {
    return [...this.data.rows.values()]
      .map(row => ({ key: keyOf(row.value, this.spec.keyPath), primaryKey: row.key, value: row.value }))
      .filter(entry => !range || range.includes(entry.key))
      .sort((left, right) => compareKeys(left.key, right.key) || compareKeys(left.primaryKey, right.primaryKey));
  }
  openCursor(range, direction = "next") { return this.cursor(range, direction, true); }
  openKeyCursor(range, direction = "next") { return this.cursor(range, direction, false); }
  cursor(range, direction, withValue) {
    const tx = this.tx;
    const index = this;
    let last = null;
    const step = () => {
      const entries = index.entries(range);
      const ordered = direction === "prev" ? entries.reverse() : entries;
      const next = ordered.find(entry => last === null
        || (direction === "prev" ? compareKeys(entry.key, last) < 0 : compareKeys(entry.key, last) > 0));
      if (!next) return null;
      last = next.key;
      return {
        key: next.key,
        primaryKey: next.primaryKey,
        value: withValue ? structuredClone(next.value) : undefined,
        continue: () => { tx.pending += 1; later(() => fire(request)); },
        delete: () => index.data.rows.delete(JSON.stringify(next.primaryKey)),
      };
    };
    const fire = target => {
      if (tx.finished) return;
      target.result = step();
      target.onsuccess?.({ target });
      tx.pending -= 1;
      tx.settle();
    };
    const request = {};
    tx.pending += 1;
    later(() => fire(request));
    return request;
  }
  count(range) { return new FakeRequest(this.tx, () => this.entries(range).length); }
}

class FakeObjectStore {
  constructor(tx, data) { this.tx = tx; this.data = data; }
  get(key) { return new FakeRequest(this.tx, () => structuredClone(this.data.rows.get(JSON.stringify(key))?.value)); }
  put(value) {
    return new FakeRequest(this.tx, () => {
      const key = keyOf(value, this.data.keyPath);
      for (const spec of this.data.indexes.values()) {
        if (!spec.unique) continue;
        const indexKey = JSON.stringify(keyOf(value, spec.keyPath));
        for (const row of this.data.rows.values()) {
          if (JSON.stringify(keyOf(row.value, spec.keyPath)) === indexKey && compareKeys(row.key, key)) {
            throw new Error("ConstraintError");
          }
        }
      }
      this.data.rows.set(JSON.stringify(key), { key, value: structuredClone(value) });
      return key;
    });
  }
  delete(key) { return new FakeRequest(this.tx, () => { this.data.rows.delete(JSON.stringify(key)); }); }
  index(name) { return new FakeIndex(this.tx, this.data, this.data.indexes.get(name)); }
  openKeyCursor(range) {
    return new FakeIndex(this.tx, this.data, { keyPath: this.data.keyPath }).openKeyCursor(range);
  }
}

class FakeTransaction {
  constructor(db, names) {
    this.db = db;
    this.pending = 0;
    this.finished = false;
    this.working = new Map((Array.isArray(names) ? names : [names]).map(name => [name, db.stores.get(name).clone()]));
    this.pending += 1;
    later(() => { this.pending -= 1; this.settle(); });
  }
  objectStore(name) { return new FakeObjectStore(this, this.working.get(name)); }
  settle() {
    if (this.finished || this.pending > 0) return;
    later(() => {
      if (this.finished || this.pending > 0) return;
      this.finished = true;
      for (const [name, data] of this.working) this.db.stores.set(name, data);
      this.oncomplete?.();
    });
  }
  abort(error) {
    if (this.finished) return;
    this.finished = true;
    this.error = error || null;
    later(() => this.onabort?.());
  }
}

class FakeDatabase {
  constructor() {
    this.stores = new Map();
    this.objectStoreNames = { contains: name => this.stores.has(name) };
  }
  createObjectStore(name, { keyPath }) {
    const data = new FakeStoreData(keyPath);
    this.stores.set(name, data);
    return { createIndex: (indexName, path, options = {}) => data.indexes.set(indexName, { keyPath: path, unique: Boolean(options.unique) }) };
  }
  deleteObjectStore(name) { this.stores.delete(name); }
  transaction(names) { return new FakeTransaction(this, names); }
}

const fakeDatabase = new FakeDatabase();
const fakeIndexedDB = {
  open() {
    const request = {};
    later(() => {
      request.result = fakeDatabase;
      request.onupgradeneeded?.({ target: request });
      request.onsuccess?.({ target: request });
    });
    return request;
  },
};

globalThis.IDBKeyRange = FakeKeyRange;
globalThis.indexedDB = fakeIndexedDB;
const {
  agentReplicaNamespace,
  saveAgentEventsForStream,
  loadRecentAgentEventsForStream,
  getAgentSyncState,
  installAgentHistoryBoundary,
  MAX_EVENTS_PER_STREAM,
} = await import("./agent-store.js");

function event(sequence, payload = {}) {
  return { sequence, eventId: `evt-${sequence}`, streamId: "exec-1", executionId: "exec-1", type: "message.delta", payload, occurredAt: "2026-01-01T00:00:00Z", recordedAt: "2026-01-01T00:00:00Z", origin: { kind: "host", confidence: "native" } };
}

/// Runs one save against the in-memory store, which still folds every held
/// row, as the reference for the incremental IndexedDB path.
async function inMemory(run) {
  delete globalThis.indexedDB;
  try {
    return await run();
  } finally {
    globalThis.indexedDB = fakeIndexedDB;
  }
}

const cursorFields = state => ({
  retainedFromSequence: state.retainedFromSequence,
  headSequence: state.headSequence,
  contiguousThrough: state.contiguousThrough,
});

test("IndexedDB replica advances the cursor incrementally and closes gaps from held rows", async () => {
  const scope = agentReplicaNamespace("idb-host", "owner");
  await saveAgentEventsForStream(scope, "exec-1", [event(1), event(2), event(4), event(5)]);
  let state = await getAgentSyncState(scope, "exec-1");
  assert.deepEqual(cursorFields(state), { retainedFromSequence: 1, headSequence: 5, contiguousThrough: 2 });

  state = await saveAgentEventsForStream(scope, "exec-1", [event(3)]);
  assert.deepEqual(cursorFields(state), { retainedFromSequence: 1, headSequence: 5, contiguousThrough: 5 });
  await assert.rejects(saveAgentEventsForStream(scope, "exec-1", [event(3, { changed: true })]), /conflict/);
  assert.equal((await loadRecentAgentEventsForStream(scope, "exec-1")).length, 5);
});

test("IndexedDB replica keeps the same cursor as a full fold for any batch order", async () => {
  let seed = 7;
  const random = () => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed / 2147483648;
  };
  for (let round = 0; round < 8; round += 1) {
    const stream = `idb-round-${round}`;
    const idbScope = agentReplicaNamespace("idb-equivalence", stream);
    const memoryScope = agentReplicaNamespace("memory-equivalence", stream);
    const sequences = Array.from({ length: 60 }, (_, index) => index + 1).sort(() => random() - 0.5);
    while (sequences.length) {
      const batch = sequences.splice(0, 1 + Math.floor(random() * 6)).map(sequence => event(sequence));
      const replay = random() < 0.3 ? [event(1 + Math.floor(random() * 60))] : [];
      const idbState = await saveAgentEventsForStream(idbScope, "exec-1", batch);
      const memoryState = await inMemory(() => saveAgentEventsForStream(memoryScope, "exec-1", batch));
      assert.deepEqual(cursorFields(idbState), cursorFields(memoryState));
      if (replay.length) {
        // A replayed row may or may not be held yet; either way both stores
        // must agree on it.
        const idbReplay = await saveAgentEventsForStream(idbScope, "exec-1", replay);
        const memoryReplay = await inMemory(() => saveAgentEventsForStream(memoryScope, "exec-1", replay));
        assert.deepEqual(cursorFields(idbReplay), cursorFields(memoryReplay));
      }
    }
    assert.equal((await getAgentSyncState(idbScope, "exec-1")).contiguousThrough, 60);
  }
});

test("IndexedDB history boundary matches the in-memory replacement cursor", async () => {
  const idbScope = agentReplicaNamespace("idb-boundary", "owner");
  const memoryScope = agentReplicaNamespace("memory-boundary", "owner");
  const boundary = { retainedFromSequence: 3, headSequence: 5, checkpointSequence: 5, checkpoint: { status: { activity: "ready" } } };
  await saveAgentEventsForStream(idbScope, "exec-1", [event(1), event(7)]);
  await inMemory(() => saveAgentEventsForStream(memoryScope, "exec-1", [event(1), event(7)]));
  const idbState = await installAgentHistoryBoundary(idbScope, "exec-1", boundary);
  const memoryState = await inMemory(() => installAgentHistoryBoundary(memoryScope, "exec-1", boundary));
  assert.deepEqual(cursorFields(idbState), cursorFields(memoryState));
  assert.equal(idbState.checkpointSequence, 5);
  assert.deepEqual((await loadRecentAgentEventsForStream(idbScope, "exec-1")).map(row => row.sequence), [7]);
  // The next live row walks through the held row past the checkpoint.
  const next = await saveAgentEventsForStream(idbScope, "exec-1", [event(6)]);
  assert.equal(next.contiguousThrough, 7);
});

test("IndexedDB replica prunes to the same newest rows as the in-memory store", async () => {
  const idbScope = agentReplicaNamespace("idb-prune", "owner");
  const memoryScope = agentReplicaNamespace("memory-prune", "owner");
  const total = MAX_EVENTS_PER_STREAM + 150;
  let idbState;
  let memoryState;
  for (let start = 1; start <= total; start += 500) {
    const batch = Array.from({ length: Math.min(500, total - start + 1) }, (_, index) => event(start + index));
    idbState = await saveAgentEventsForStream(idbScope, "exec-1", batch);
    memoryState = await inMemory(() => saveAgentEventsForStream(memoryScope, "exec-1", batch));
  }
  assert.equal(idbState.retainedFromSequence, total - MAX_EVENTS_PER_STREAM + 1);
  assert.equal(idbState.hasMoreBefore, true);
  assert.equal(idbState.contiguousThrough, total);
  const held = await loadRecentAgentEventsForStream(idbScope, "exec-1", total);
  assert.equal(held.length, MAX_EVENTS_PER_STREAM);
  assert.equal(held[0].sequence, idbState.retainedFromSequence);
  const memoryHeld = await inMemory(() => loadRecentAgentEventsForStream(memoryScope, "exec-1", total));
  assert.equal(memoryHeld.length, held.length);
  assert.equal(memoryHeld[0].sequence, held[0].sequence);
  assert.equal(memoryState.contiguousThrough, idbState.contiguousThrough);
});
