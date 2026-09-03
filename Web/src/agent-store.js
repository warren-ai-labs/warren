/**
 * Agent Event Store for Web.
 * Provides client-side persistence using IndexedDB (with in-memory fallback for test runners).
 * Enables instant (<10ms) cold-start rendering and sequence gap detection.
 */

const DB_NAME = "warren_agent_db";
const DB_VERSION = 1;
const EVENTS_STORE = "agent_events";
const STATE_STORE = "agent_sync_state";
export const MAX_EVENTS_PER_SESSION = 5000;

const memoryEvents = new Map(); // `${sessionId}:${epoch}:${seq}` -> record
const memoryState = new Map();  // sessionId -> { epoch, maxSequence }

function hasIndexedDB() {
  return typeof indexedDB !== "undefined";
}

let dbPromise = null;

export function openAgentDB() {
  if (!hasIndexedDB()) return Promise.resolve(null);
  if (dbPromise) return dbPromise;

  dbPromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onupgradeneeded = (event) => {
      const db = event.target.result;
      if (!db.objectStoreNames.contains(EVENTS_STORE)) {
        const store = db.createObjectStore(EVENTS_STORE, { keyPath: ["sessionId", "epoch", "seq"] });
        store.createIndex("by_session_seq", ["sessionId", "seq"]);
        store.createIndex("by_session_epoch", ["sessionId", "epoch"]);
      }
      if (!db.objectStoreNames.contains(STATE_STORE)) {
        db.createObjectStore(STATE_STORE, { keyPath: "sessionId" });
      }
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });

  return dbPromise;
}

export async function saveAgentEvents(sessionId, epoch, events = []) {
  if (!sessionId || !events || events.length === 0) return;
  const numEpoch = Number(epoch) || 0;

  if (!hasIndexedDB()) {
    let maxSeq = memoryState.get(sessionId)?.maxSequence || 0;
    for (const ev of events) {
      if (!ev || typeof ev.seq !== "number") continue;
      memoryEvents.set(`${sessionId}:${numEpoch}:${ev.seq}`, {
        sessionId,
        epoch: numEpoch,
        seq: ev.seq,
        event: ev,
      });
      if (ev.seq > maxSeq) maxSeq = ev.seq;
    }
    memoryState.set(sessionId, { epoch: numEpoch, maxSequence: maxSeq });

    // Prune if over MAX_EVENTS_PER_SESSION
    const sessionKeys = [];
    for (const [k, v] of memoryEvents.entries()) {
      if (v.sessionId === sessionId && v.epoch === numEpoch) {
        sessionKeys.push({ key: k, seq: v.seq });
      }
    }
    if (sessionKeys.length > MAX_EVENTS_PER_SESSION) {
      sessionKeys.sort((a, b) => b.seq - a.seq);
      const toRemove = sessionKeys.slice(MAX_EVENTS_PER_SESSION);
      for (const item of toRemove) {
        memoryEvents.delete(item.key);
      }
    }
    return;
  }

  const db = await openAgentDB();
  if (!db) return;

  return new Promise((resolve, reject) => {
    const tx = db.transaction([EVENTS_STORE, STATE_STORE], "readwrite");
    const eventStore = tx.objectStore(EVENTS_STORE);
    const stateStore = tx.objectStore(STATE_STORE);

    let maxSeq = 0;
    for (const ev of events) {
      if (!ev || typeof ev.seq !== "number") continue;
      eventStore.put({
        sessionId,
        epoch: numEpoch,
        seq: ev.seq,
        event: ev,
      });
      if (ev.seq > maxSeq) maxSeq = ev.seq;
    }

    const stateGet = stateStore.get(sessionId);
    stateGet.onsuccess = () => {
      const existing = stateGet.result;
      const newMax = Math.max(existing?.maxSequence || 0, maxSeq);
      stateStore.put({
        sessionId,
        epoch: numEpoch,
        maxSequence: newMax,
        updatedAt: Date.now(),
      });
    };

    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export async function loadRecentAgentEvents(sessionId, limit = 100) {
  if (!sessionId) return [];

  if (!hasIndexedDB()) {
    const results = [];
    for (const v of memoryEvents.values()) {
      if (v.sessionId === sessionId) {
        results.push(v.event);
      }
    }
    results.sort((a, b) => a.seq - b.seq);
    return results.slice(-limit);
  }

  const db = await openAgentDB();
  if (!db) return [];

  return new Promise((resolve, reject) => {
    const tx = db.transaction(EVENTS_STORE, "readonly");
    const store = tx.objectStore(EVENTS_STORE);
    const index = store.index("by_session_seq");
    const range = IDBKeyRange.bound([sessionId, 0], [sessionId, Number.MAX_SAFE_INTEGER]);

    const results = [];
    // Open cursor backwards to grab latest `limit` records
    const request = index.openCursor(range, "prev");

    request.onsuccess = (event) => {
      const cursor = event.target.result;
      if (cursor && results.length < limit) {
        results.push(cursor.value.event);
        cursor.continue();
      } else {
        // Reverse back to ascending sequence order
        results.reverse();
        resolve(results);
      }
    };
    request.onerror = () => reject(request.error);
  });
}

export async function getAgentMaxSequence(sessionId, epoch) {
  if (!sessionId) return 0;
  const numEpoch = Number(epoch) || 0;

  if (!hasIndexedDB()) {
    const state = memoryState.get(sessionId);
    if (state && (!numEpoch || state.epoch === numEpoch)) {
      return state.maxSequence || 0;
    }
    let max = 0;
    for (const v of memoryEvents.values()) {
      if (v.sessionId === sessionId && (!numEpoch || v.epoch === numEpoch)) {
        if (v.seq > max) max = v.seq;
      }
    }
    return max;
  }

  const db = await openAgentDB();
  if (!db) return 0;

  return new Promise((resolve) => {
    const tx = db.transaction(STATE_STORE, "readonly");
    const store = tx.objectStore(STATE_STORE);
    const req = store.get(sessionId);
    req.onsuccess = () => {
      const result = req.result;
      if (result && (!numEpoch || result.epoch === numEpoch)) {
        resolve(result.maxSequence || 0);
      } else {
        resolve(0);
      }
    };
    req.onerror = () => resolve(0);
  });
}

export async function clearAgentSession(sessionId) {
  if (!sessionId) return;

  if (!hasIndexedDB()) {
    for (const [k, v] of memoryEvents.entries()) {
      if (v.sessionId === sessionId) {
        memoryEvents.delete(k);
      }
    }
    memoryState.delete(sessionId);
    return;
  }

  const db = await openAgentDB();
  if (!db) return;

  return new Promise((resolve, reject) => {
    const tx = db.transaction([EVENTS_STORE, STATE_STORE], "readwrite");
    const store = tx.objectStore(EVENTS_STORE);
    const index = store.index("by_session_seq");
    const range = IDBKeyRange.bound([sessionId, 0], [sessionId, Number.MAX_SAFE_INTEGER]);

    const req = index.openKeyCursor(range);
    req.onsuccess = (e) => {
      const cursor = e.target.result;
      if (cursor) {
        store.delete(cursor.primaryKey);
        cursor.continue();
      }
    };

    tx.objectStore(STATE_STORE).delete(sessionId);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}
