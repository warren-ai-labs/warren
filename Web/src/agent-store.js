/**
 * Append-only Agent event replica for Web.
 *
 * Host identity and access scope are part of every key. Endpoint URLs,
 * workspace names, and client profile IDs are deliberately excluded from the
 * event namespace.
 */

const DB_NAME = "warren_agent_db";
const DB_VERSION = 3;
const EVENTS_STORE = "agent_events";
const STATE_STORE = "agent_sync_state";
export const MAX_EVENTS_PER_STREAM = 5000;

const memoryEvents = new Map();
const memoryState = new Map();
let dbPromise = null;

function hasIndexedDB() {
  return typeof indexedDB !== "undefined";
}

function requiredPart(value, name) {
  const result = String(value || "").trim();
  if (!result) throw new Error(`${name} is required for Agent event persistence`);
  return result;
}

/** Returns the only valid local identity for one authenticated Host scope. */
export function agentReplicaNamespace(hostId, accessScopeId) {
  return {
    hostId: requiredPart(hostId, "hostId"),
    accessScopeId: requiredPart(accessScopeId, "accessScopeId"),
  };
}

function streamIdentity(namespace, streamId) {
  const scope = agentReplicaNamespace(namespace?.hostId, namespace?.accessScopeId);
  return { ...scope, streamId: requiredPart(streamId, "streamId") };
}

function eventSequence(event) {
  const value = event?.sequence;
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

function eventID(event, streamId, sequence) {
  return event.eventId;
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function validateCanonicalAgentEvent(event, streamId = event?.streamId) {
  if (!eventSequence(event) || typeof event.eventId !== "string" || !event.eventId
      || event.streamId !== streamId || !streamId || !event.executionId
      || typeof event.type !== "string" || !event.type || !event.occurredAt || !event.recordedAt
      || !event.origin?.kind || !event.origin?.confidence
      || !event.payload || typeof event.payload !== "object" || Array.isArray(event.payload)) {
    throw new Error("Invalid canonical Agent event envelope");
  }
  return event;
}

function initialState() {
  return {
    retainedFromSequence: 0,
    headSequence: 0,
    contiguousThrough: 0,
    checkpointSequence: 0,
    checkpoint: null,
    hasMoreBefore: false,
    updatedAt: Date.now(),
  };
}

function stateKey(identity) {
  return `${identity.hostId}\u0000${identity.accessScopeId}\u0000${identity.streamId}`;
}

function eventKey(identity, sequence) {
  return `${identity.hostId}\u0000${identity.accessScopeId}\u0000${identity.streamId}\u0000${sequence}`;
}

function advanceState(state, events, { baselineSequence = 0 } = {}) {
  const next = { ...initialState(), ...state };
  const ordered = [...events].sort((left, right) => eventSequence(left) - eventSequence(right));
  if (ordered.length) {
    const first = eventSequence(ordered[0]);
    next.retainedFromSequence = next.retainedFromSequence > 0
      ? Math.min(next.retainedFromSequence, first)
      : first;
  }
  if (baselineSequence > 0) {
    next.retainedFromSequence = next.retainedFromSequence > 0
      ? Math.min(next.retainedFromSequence, baselineSequence)
      : baselineSequence;
    // A retention boundary is an explicit statement that the prefix before
    // it is no longer required for continuity. Ordinary late batches must
    // never get this treatment, or a dropped event would be silently skipped.
    next.contiguousThrough = Math.max(next.contiguousThrough, baselineSequence - 1);
  }
  for (const event of ordered) {
    const sequence = eventSequence(event);
    if (!sequence) continue;
    next.headSequence = Math.max(next.headSequence, sequence);
    if (next.retainedFromSequence === 0) next.retainedFromSequence = sequence;
  }
  // A zero contiguous cursor means that the first retained row is not known
  // to be the beginning of the Host stream. Once sequence 1 (or the retained
  // boundary) is present, advance through all adjacent rows in this batch.
  const present = new Set(ordered.map(eventSequence));
  let cursor = next.contiguousThrough;
  while (present.has(cursor + 1)) cursor += 1;
  next.contiguousThrough = Math.max(next.contiguousThrough, cursor);
  next.updatedAt = Date.now();
  return next;
}

function pruneMemory(identity) {
  const rows = [];
  const through = memoryState.get(stateKey(identity))?.contiguousThrough || 0;
  for (const [key, value] of memoryEvents) {
    if (value.hostId === identity.hostId
      && value.accessScopeId === identity.accessScopeId
      && value.streamId === identity.streamId) {
      rows.push({ key, sequence: value.sequence });
    }
  }
  if (rows.length <= MAX_EVENTS_PER_STREAM) return;
  rows.sort((left, right) => right.sequence - left.sequence);
  const retained = rows.slice(0, MAX_EVENTS_PER_STREAM);
  for (const row of rows.slice(MAX_EVENTS_PER_STREAM)) { if (row.sequence <= through) memoryEvents.delete(row.key); }
  const state = memoryState.get(stateKey(identity));
  if (state) {
    state.retainedFromSequence = Math.min(...retained.map(row => row.sequence));
    state.hasMoreBefore = state.retainedFromSequence > 1;
    memoryState.set(stateKey(identity), state);
  }
}

export function openAgentDB() {
  if (!hasIndexedDB()) return Promise.resolve(null);
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = event => {
      const db = event.target.result;
      // The previous schema keyed rows by session/epoch. It cannot be safely
      // interpreted under the canonical namespace, so the disposable cache is
      // replaced rather than migrated heuristically.
      for (const name of [EVENTS_STORE, STATE_STORE]) {
        if (db.objectStoreNames.contains(name)) db.deleteObjectStore(name);
      }
      const events = db.createObjectStore(EVENTS_STORE, {
        keyPath: ["hostId", "accessScopeId", "streamId", "sequence"],
      });
      events.createIndex("by_stream_sequence", ["hostId", "accessScopeId", "streamId", "sequence"]);
      events.createIndex("by_stream_event", ["hostId", "accessScopeId", "streamId", "eventId"], { unique: true });
      db.createObjectStore(STATE_STORE, {
        keyPath: ["hostId", "accessScopeId", "streamId"],
      });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  return dbPromise;
}

/**
 * Persist one canonical batch. Existing positions are immutable: an identical
 * duplicate is ignored, while a different payload at the same position fails.
 */
export async function saveAgentEventsForStream(namespace, streamId, events = [], {
  checkpointSequence = 0,
  checkpoint = null,
  historyBoundary = null,
} = {}) {
  const identity = streamIdentity(namespace, streamId);
  const incoming = events.map(event => validateCanonicalAgentEvent(event, identity.streamId));
  if (incoming.length === 0 && !checkpoint && !historyBoundary) return getAgentSyncState(identity, identity.streamId);

  const boundary = historyBoundary && {
    retainedFromSequence: Math.max(0, Number(historyBoundary.retainedFromSequence) || 0),
    headSequence: Math.max(0, Number(historyBoundary.headSequence) || 0),
    checkpointSequence: Math.max(0, Number(historyBoundary.checkpointSequence) || Number(checkpointSequence) || 0),
  };

  if (!hasIndexedDB()) {
    let state = memoryState.get(stateKey(identity)) || initialState();
    const accepted = [];
    const staged = new Map(memoryEvents);
    if (boundary?.retainedFromSequence > 0) {
      for (const [key, value] of staged) {
        if (value.hostId === identity.hostId
          && value.accessScopeId === identity.accessScopeId
          && value.streamId === identity.streamId
          && value.sequence < boundary.retainedFromSequence) staged.delete(key);
      }
      state = {
        ...state,
        retainedFromSequence: boundary.retainedFromSequence,
        headSequence: Math.max(state.headSequence, boundary.headSequence),
        contiguousThrough: Math.max(state.contiguousThrough, boundary.checkpointSequence),
      };
      for (const [key, value] of memoryEvents) {
        if (value.hostId === identity.hostId
          && value.accessScopeId === identity.accessScopeId
          && value.streamId === identity.streamId
          && value.sequence < boundary.retainedFromSequence) memoryEvents.delete(key);
      }
    }
    for (const event of incoming) {
      const sequence = eventSequence(event);
      const key = eventKey(identity, sequence);
      const duplicate = [...staged.values()].find(row => row.hostId === identity.hostId && row.accessScopeId === identity.accessScopeId && row.streamId === identity.streamId && row.event.eventId === event.eventId);
      if (duplicate && stableJSON(duplicate.event) !== stableJSON(event)) throw new Error(`Agent event ID conflict in ${identity.streamId}`);
      const existing = staged.get(key);
      if (existing) {
        if (stableJSON(existing.event) !== stableJSON(event)) {
          throw new Error(`Agent event sequence conflict at ${identity.streamId}:${sequence}`);
        }
        continue;
      }
      staged.set(key, { ...identity, sequence, event });
      accepted.push(event);
    }
    for (const event of accepted) memoryEvents.set(eventKey(identity, event.sequence), { ...identity, sequence: event.sequence, event });
    const allEvents = [...memoryEvents.values()]
      .filter(value => value.hostId === identity.hostId
        && value.accessScopeId === identity.accessScopeId
        && value.streamId === identity.streamId)
      .map(value => value.event);
    state = advanceState(state, allEvents, {
      baselineSequence: boundary?.retainedFromSequence || 0,
    });
    if (boundary) {
      state.headSequence = Math.max(state.headSequence, boundary.headSequence);
      state.contiguousThrough = Math.max(state.contiguousThrough, boundary.checkpointSequence);
      state.retainedFromSequence = boundary.retainedFromSequence || state.retainedFromSequence;
    }
    if (checkpoint) {
      state.checkpoint = checkpoint;
      state.checkpointSequence = Number(checkpointSequence) || state.checkpointSequence;
    }
    memoryState.set(stateKey(identity), state);
    pruneMemory(identity);
    return state;
  }

  const db = await openAgentDB();
  if (!db) return undefined;
  return new Promise((resolve, reject) => {
    const tx = db.transaction([EVENTS_STORE, STATE_STORE], "readwrite");
    const eventStore = tx.objectStore(EVENTS_STORE);
    const stateStore = tx.objectStore(STATE_STORE);
    const accepted = [];
    let state;
    let failed = null;
    let index = 0;

    const fail = error => {
      if (failed) return;
      failed = error;
      try { tx.abort(); } catch { /* transaction already finished */ }
    };
    const visit = () => {
      if (failed) return;
      if (index >= incoming.length) {
        const stateRequest = stateStore.get([identity.hostId, identity.accessScopeId, identity.streamId]);
        stateRequest.onsuccess = () => {
          const range = IDBKeyRange.bound(
            [identity.hostId, identity.accessScopeId, identity.streamId, 0],
            [identity.hostId, identity.accessScopeId, identity.streamId, Number.MAX_SAFE_INTEGER],
          );
          const cursorRequest = eventStore.index("by_stream_sequence").openCursor(range);
          const rows = [];
          cursorRequest.onsuccess = cursorEvent => {
            const cursor = cursorEvent.target.result;
            if (cursor) {
              rows.push(cursor.value.event);
              cursor.continue();
              return;
            }
            state = advanceState(stateRequest.result || initialState(), rows, {
              baselineSequence: boundary?.retainedFromSequence || 0,
            });
            if (boundary) {
              state.headSequence = Math.max(state.headSequence, boundary.headSequence);
              state.contiguousThrough = Math.max(state.contiguousThrough, boundary.checkpointSequence);
              state.retainedFromSequence = boundary.retainedFromSequence || state.retainedFromSequence;
              state.hasMoreBefore = false;
            }
            if (checkpoint) {
              state.checkpoint = checkpoint;
              state.checkpointSequence = Number(checkpointSequence) || state.checkpointSequence;
            }
            state.hostId = identity.hostId;
            state.accessScopeId = identity.accessScopeId;
            state.streamId = identity.streamId;
            stateStore.put(state);
          };
          cursorRequest.onerror = () => fail(cursorRequest.error || new Error("unable to read Agent events"));
        };
        stateRequest.onerror = () => fail(stateRequest.error || new Error("unable to read Agent sync state"));
        return;
      }
      const event = incoming[index++];
      const sequence = eventSequence(event);
      const key = [identity.hostId, identity.accessScopeId, identity.streamId, sequence];
      const existingRequest = eventStore.get(key);
      existingRequest.onsuccess = () => {
        const existing = existingRequest.result;
        if (existing) {
          if (stableJSON(existing.event) !== stableJSON(event)) {
            fail(new Error(`Agent event sequence conflict at ${identity.streamId}:${sequence}`));
            return;
          }
        } else {
          eventStore.put({
            ...identity,
            sequence,
            event,
            eventId: eventID(event, identity.streamId, sequence),
            recordedAt: event.recordedAt || null,
          });
          accepted.push(event);
        }
        visit();
      };
      existingRequest.onerror = () => fail(existingRequest.error || new Error("unable to read Agent event"));
    };
    tx.oncomplete = () => resolve(state);
    tx.onerror = () => reject(failed || tx.error || new Error("unable to persist Agent events"));
    tx.onabort = () => reject(failed || tx.error || new Error("unable to persist Agent events"));
    const start = () => visit();
    if (boundary?.retainedFromSequence > 0) {
      const range = IDBKeyRange.bound(
        [identity.hostId, identity.accessScopeId, identity.streamId, 0],
        [identity.hostId, identity.accessScopeId, identity.streamId, boundary.retainedFromSequence - 1],
      );
      const cursorRequest = eventStore.index("by_stream_sequence").openCursor(range);
      cursorRequest.onsuccess = cursorEvent => {
        const cursor = cursorEvent.target.result;
        if (cursor) {
          cursor.delete();
          cursor.continue();
          return;
        }
        start();
      };
      cursorRequest.onerror = () => fail(cursorRequest.error || new Error("unable to install Agent history boundary"));
    } else {
      start();
    }
  });
}

/**
 * Installs the Host replacement checkpoint returned by a structured
 * history_boundary error. This is the only operation allowed to move a zero
 * cursor to an explicit retention baseline.
 */
export function installAgentHistoryBoundary(namespace, streamId, boundary = {}) {
  return saveAgentEventsForStream(namespace, streamId, [], {
    checkpointSequence: Number(boundary.checkpointSequence) || 0,
    checkpoint: boundary.checkpoint || null,
    historyBoundary: boundary,
  });
}

export async function getAgentSyncState(namespace, streamId) {
  const identity = streamIdentity(namespace, streamId);
  if (!hasIndexedDB()) return memoryState.get(stateKey(identity)) || initialState();
  const db = await openAgentDB();
  if (!db) return initialState();
  return new Promise(resolve => {
    const tx = db.transaction(STATE_STORE, "readonly");
    const request = tx.objectStore(STATE_STORE).get([identity.hostId, identity.accessScopeId, identity.streamId]);
    request.onsuccess = () => resolve(request.result || initialState());
    request.onerror = () => resolve(initialState());
  });
}

export async function loadRecentAgentEventsForStream(namespace, streamId, limit = 100) {
  const identity = streamIdentity(namespace, streamId);
  const boundedLimit = Math.max(0, Number(limit) || 0);
  if (!hasIndexedDB()) {
    return [...memoryEvents.values()]
      .filter(value => value.hostId === identity.hostId
        && value.accessScopeId === identity.accessScopeId
        && value.streamId === identity.streamId)
      .sort((left, right) => left.sequence - right.sequence)
      .slice(-boundedLimit)
      .map(value => value.event);
  }
  const db = await openAgentDB();
  if (!db) return [];
  return new Promise((resolve, reject) => {
    const tx = db.transaction(EVENTS_STORE, "readonly");
    const index = tx.objectStore(EVENTS_STORE).index("by_stream_sequence");
    const range = IDBKeyRange.bound(
      [identity.hostId, identity.accessScopeId, identity.streamId, 0],
      [identity.hostId, identity.accessScopeId, identity.streamId, Number.MAX_SAFE_INTEGER],
    );
    const results = [];
    const request = index.openCursor(range, "prev");
    request.onsuccess = event => {
      const cursor = event.target.result;
      if (cursor && results.length < boundedLimit) {
        results.push(cursor.value.event);
        cursor.continue();
      } else {
        resolve(results.reverse());
      }
    };
    request.onerror = () => reject(request.error);
  });
}

export async function clearAgentStream(namespace, streamId) {
  const identity = streamIdentity(namespace, streamId);
  if (!hasIndexedDB()) {
    for (const [key, value] of memoryEvents) {
      if (value.hostId === identity.hostId
        && value.accessScopeId === identity.accessScopeId
        && value.streamId === identity.streamId) memoryEvents.delete(key);
    }
    memoryState.delete(stateKey(identity));
    return;
  }
  const db = await openAgentDB();
  if (!db) return;
  return new Promise((resolve, reject) => {
    const tx = db.transaction([EVENTS_STORE, STATE_STORE], "readwrite");
    const store = tx.objectStore(EVENTS_STORE);
    const index = store.index("by_stream_sequence");
    const range = IDBKeyRange.bound(
      [identity.hostId, identity.accessScopeId, identity.streamId, 0],
      [identity.hostId, identity.accessScopeId, identity.streamId, Number.MAX_SAFE_INTEGER],
    );
    const request = index.openKeyCursor(range);
    request.onsuccess = event => {
      const cursor = event.target.result;
      if (cursor) {
        store.delete(cursor.primaryKey);
        cursor.continue();
      }
    };
    tx.objectStore(STATE_STORE).delete([identity.hostId, identity.accessScopeId, identity.streamId]);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export async function clearAgentNamespace(namespace) {
  const scope = agentReplicaNamespace(namespace?.hostId, namespace?.accessScopeId);
  if (!hasIndexedDB()) {
    for (const [key, value] of memoryEvents) {
      if (value.hostId === scope.hostId && value.accessScopeId === scope.accessScopeId) memoryEvents.delete(key);
    }
    for (const [key, value] of memoryState) {
      if (value.hostId === scope.hostId && value.accessScopeId === scope.accessScopeId) memoryState.delete(key);
    }
    return;
  }
  const db = await openAgentDB();
  if (!db) return;
  return new Promise((resolve, reject) => {
    const tx = db.transaction([EVENTS_STORE, STATE_STORE], "readwrite");
    const events = tx.objectStore(EVENTS_STORE);
    const eventIndex = events.index("by_stream_sequence");
    const eventRange = IDBKeyRange.bound(
      [scope.hostId, scope.accessScopeId, "", 0],
      [scope.hostId, scope.accessScopeId, "\uffff", Number.MAX_SAFE_INTEGER],
    );
    const request = eventIndex.openKeyCursor(eventRange);
    request.onsuccess = event => {
      const cursor = event.target.result;
      if (cursor) {
        events.delete(cursor.primaryKey);
        cursor.continue();
      }
    };
    const states = tx.objectStore(STATE_STORE);
    const stateRange = IDBKeyRange.bound(
      [scope.hostId, scope.accessScopeId, ""],
      [scope.hostId, scope.accessScopeId, "\uffff"],
    );
    const stateRequest = states.openKeyCursor(stateRange);
    stateRequest.onsuccess = event => {
      const cursor = event.target.result;
      if (cursor) {
        states.delete(cursor.primaryKey);
        cursor.continue();
      }
    };
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}
