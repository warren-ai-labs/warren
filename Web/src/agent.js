export const agentEventLimit = 2000;
export const agentAttachmentMaximumBytes = 64 * 1024 * 1024;
export const agentAttachmentChunkSize = 256 * 1024;
export const agentStructuredEventTypes = new Set([
  "question",
  "permission",
  "plan",
  "todo",
  "activity",
  "plugin",
  "subagent",
  "attachment",
]);

export function normalizeAgentEventType(type) {
  return String(type || "").trim().toLowerCase().replaceAll("-", "_");
}

export function isStructuredAgentEvent(event) {
  return agentStructuredEventTypes.has(normalizeAgentEventType(event?.type));
}

/**
 * Merges agent event batches by sequence number. Transcripts are append-only,
 * but a replayed history can overlap a live batch after a reconnect, so the
 * sequence is the stable identity. When `cap` is false (an explicit "load
 * earlier" page), the merged array is not truncated: trimming the newest
 * events would silently drop a middle chunk of the existing conversation and
 * create a gap the user can never scroll back into.
 */
export function mergeAgentEvents(existing = [], incoming = [], { cap = true } = {}) {
  const bySequence = new Map();
  for (const event of existing || []) {
    if (event && Number.isFinite(event.seq) && !bySequence.has(event.seq)) {
      bySequence.set(event.seq, event);
    }
  }
  for (const event of incoming || []) {
    // Sequence numbers identify immutable positions in an epoch. A replayed
    // history/live overlap must retain the first observed event rather than
    // letting a later payload rewrite that position.
    if (event && Number.isFinite(event.seq) && !bySequence.has(event.seq)) {
      bySequence.set(event.seq, event);
    }
  }
  return [...bySequence.values()]
    .sort((left, right) => left.seq - right.seq)
    .slice(cap ? -agentEventLimit : undefined);
}

/**
 * Groups a flat transcript into renderable blocks. A tool_call and its
 * matching tool_output(s) become one tool block so the UI can show the call
 * and its result as a single compact step instead of two separate cards.
 * Every user message opens a turn. All reasoning steps and tool blocks
 * produced inside that turn fold into one activity strip placed where the
 * turn's last activity actually happened, so assistant commentary before the
 * final answer stays in front and the strip lands between the messages that
 * surround the work.
 */
export function groupAgentEvents(events = []) {
  const blocks = [];
  const pending = new Map();
  for (const event of coalesceAgentContent(events)) {
    if (isStructuredAgentEvent(event)) {
      blocks.push({ kind: "structured", event });
    } else if (event.type === "tool_call") {
      const block = { kind: "tool", call: event, outputs: [] };
      blocks.push(block);
      if (event.callId) pending.set(event.callId, block);
    } else if (event.type === "tool_output") {
      const block = event.callId ? pending.get(event.callId) : null;
      if (block) {
        block.outputs.push(event);
      } else {
        blocks.push({ kind: "tool_output", event });
      }
    } else {
      blocks.push({ kind: event.type, event });
    }
  }
  return foldTurns(blocks);
}

/**
 * Shared live/history reducer. Unknown events remain in `events` and advance
 * `lastSequence`, while a new epoch starts a clean projection. This is kept
 * independent from React so iOS/Web fixtures can assert identical semantics.
 */
export function reduceAgentTimeline(
  state = { epoch: null, events: [], lastSequence: 0 },
  { epoch = 0, events = [] } = {},
) {
  const nextEpoch = Number(epoch) || 0;
  const reset = state.epoch !== null && nextEpoch !== 0 && state.epoch !== nextEpoch;
  const bySequence = new Map((reset ? [] : state.events || []).map(event => [event.seq, event]));
  let lastSequence = reset ? 0 : Number(state.lastSequence) || 0;
  for (const event of events || []) {
    if (!event || !Number.isFinite(event.seq)) continue;
    lastSequence = Math.max(lastSequence, event.seq);
    if (!bySequence.has(event.seq)) bySequence.set(event.seq, event);
  }
  return {
    epoch: nextEpoch || (reset ? null : state.epoch),
    lastSequence,
    events: [...bySequence.values()].sort((left, right) => left.seq - right.seq),
  };
}

/** Returns renderable blocks with one card per structured object ID. */
export function projectAgentEvents(events = []) {
  const latestStructured = new Map();
  const regular = [];
  for (const event of events || []) {
    if (isStructuredAgentEvent(event)) {
      const type = normalizeAgentEventType(event.type);
      const stableID = String(event.id || `seq-${event.seq}`);
      latestStructured.set(`${type}:${stableID}`, event);
    } else {
      regular.push(event);
    }
  }
  const blocks = groupAgentEvents(regular);
  for (const event of latestStructured.values()) blocks.push({ kind: "structured", event });
  return blocks.sort((left, right) => {
    const leftSeq = left.event?.seq ?? left.call?.seq ?? left.tools?.[0]?.call?.seq ?? 0;
    const rightSeq = right.event?.seq ?? right.call?.seq ?? right.tools?.[0]?.call?.seq ?? 0;
    return leftSeq - rightSeq;
  });
}

export class AgentMessageQueue {
  constructor(items = []) {
    this.items = items.map(item => ({
      id: item.id || globalThis.crypto?.randomUUID?.() || `agent-${Date.now()}-${Math.random()}`,
      text: String(item.text || ""),
      attachments: Array.isArray(item.attachments) ? [...item.attachments] : [],
      createdAt: item.createdAt || new Date().toISOString(),
      status: item.status || "queued",
      failureReason: item.failureReason || null,
    }));
  }

  enqueue(item) {
    const value = item instanceof Object ? item : { text: String(item || "") };
    const next = new AgentMessageQueue([...this.items, value]);
    this.items = next.items;
    return this.items.at(-1);
  }

  edit(id, text, attachments) {
    const item = this.items.find(value => value.id === id);
    if (!item || item.status === "sending") return false;
    item.text = String(text || "");
    if (attachments) item.attachments = [...attachments];
    item.status = "queued";
    item.failureReason = null;
    return true;
  }

  remove(id) {
    const index = this.items.findIndex(value => value.id === id);
    if (index < 0 || this.items[index].status === "sending") return false;
    this.items.splice(index, 1);
    return true;
  }

  deliver(id) {
    const index = this.items.findIndex(value => value.id === id);
    if (index < 0) return false;
    this.items.splice(index, 1);
    return true;
  }

  moveToFront(id) {
    const index = this.items.findIndex(value => value.id === id);
    if (index < 0 || this.items[index].status === "sending") return false;
    if (index === 0) return true;
    const [item] = this.items.splice(index, 1);
    this.items.unshift(item);
    return true;
  }

  reorder(id, beforeID = null) {
    const index = this.items.findIndex(value => value.id === id);
    if (index < 0 || this.items[index].status === "sending") return false;
    const [item] = this.items.splice(index, 1);
    const destination = beforeID ? this.items.findIndex(value => value.id === beforeID) : this.items.length;
    this.items.splice(destination < 0 ? this.items.length : destination, 0, item);
    return true;
  }

  markSending(id) {
    const item = this.items.find(value => value.id === id);
    if (!item || item.status !== "queued") return false;
    item.status = "sending";
    item.failureReason = null;
    return true;
  }

  markFailed(id, reason) {
    const item = this.items.find(value => value.id === id);
    if (!item) return false;
    item.status = "failed";
    item.failureReason = String(reason || "Send failed");
    return true;
  }

  // A request can be in flight when the selected Session or control lease is
  // withdrawn. In that case delivery is unknown, so keep the same local ID
  // queued for a later focused drain instead of leaving a permanent spinner.
  markQueued(id) {
    const item = this.items.find(value => value.id === id);
    if (!item || item.status !== "sending") return false;
    item.status = "queued";
    item.failureReason = null;
    return true;
  }

  retry(id) {
    const item = this.items.find(value => value.id === id);
    if (!item || item.status !== "failed") return false;
    item.status = "queued";
    item.failureReason = null;
    return true;
  }
}

/**
 * Returns a collision-safe local queue identity for one Host and Session.
 * Endpoint identity is deliberately metadata (for example the WebSocket
 * URL), never an authentication token.
 */
export function agentQueueKey(endpointIdentity, sessionID) {
  return JSON.stringify([String(endpointIdentity || ""), String(sessionID || "")]);
}

export const agentDraftMaximumBytes = 64 * 1024;

function encodeAgentDraftKeyPart(value) {
  return [...new TextEncoder().encode(String(value || ""))]
    .map(byte => byte.toString(16).padStart(2, "0"))
    .join("");
}

export function agentDraftKey(endpointIdentity, sessionID) {
  // Encode both components, not only slashes: endpoint/session punctuation
  // must never collide with the dot separator used by the storage key.
  return `warren.agent-draft.${encodeAgentDraftKeyPart(endpointIdentity)}.${encodeAgentDraftKeyPart(sessionID)}`;
}

export function loadAgentDraft(storage, endpointIdentity, sessionID) {
  try { return storage?.getItem(agentDraftKey(endpointIdentity, sessionID)) || ""; } catch { return ""; }
}

export function saveAgentDraft(storage, endpointIdentity, sessionID, text, maxBytes = agentDraftMaximumBytes) {
  const value = String(text || "");
  if (new TextEncoder().encode(value).length > maxBytes) return false;
  try {
    storage?.setItem(agentDraftKey(endpointIdentity, sessionID), value);
    return true;
  } catch {
    return false;
  }
}

export function removeAgentDraft(storage, endpointIdentity, sessionID) {
  try { storage?.removeItem(agentDraftKey(endpointIdentity, sessionID)); } catch { /* best effort */ }
}

/**
 * Validates the browser-facing metadata before a file reaches the Host. The
 * Host repeats these checks; keeping the pure helper here lets the composer
 * reject paths, empty MIME values, and oversized files without a request.
 */
export function validateAgentAttachment(file, maxBytes = agentAttachmentMaximumBytes) {
  if (!file || typeof file.name !== "string" || !file.name.trim()) {
    return { ok: false, error: "Attachment name is required" };
  }
  if (file.name !== file.name.trim()) {
    return { ok: false, error: "Attachment name must not have leading or trailing spaces" };
  }
  if (file.name.includes("/") || file.name.includes("\\") || /[\u0000\r\n]/.test(file.name)) {
    return { ok: false, error: "Attachment name must be a file name" };
  }
  const size = Number(file.size);
  if (!Number.isFinite(size) || size < 0 || size > maxBytes) {
    return { ok: false, error: `Attachment must be no larger than ${maxBytes} bytes` };
  }
  if (typeof file.type !== "string" || !file.type.trim()) {
    return { ok: false, error: "Attachment MIME type is required" };
  }
  if (file.type !== file.type.trim() || /[\u0000-\u001f\u007f]/.test(file.type)) {
    return { ok: false, error: "Attachment MIME type is invalid" };
  }
  return { ok: true };
}

/** Encodes one bounded Uint8Array without relying on spread-call limits. */
export function encodeAgentAttachmentChunk(bytes) {
  let binary = "";
  const step = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += step) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + step, bytes.length)));
  }
  return globalThis.btoa ? globalThis.btoa(binary) : Buffer.from(bytes).toString("base64");
}

export function agentAttachmentReference(result, file) {
  const attachmentID = String(result?.attachmentId || result?.attachmentID || "").trim();
  if (!attachmentID) return null;
  return {
    attachmentId: attachmentID,
    name: String(file?.name || ""),
    mime: String(file?.type || "application/octet-stream"),
    size: Number(file?.size || 0),
  };
}

export function copyableAgentText(event) {
  const type = normalizeAgentEventType(event?.type);
  const role = normalizeAgentEventType(event?.role);
  if (type !== "user" && type !== "assistant" && role !== "user" && role !== "assistant") return "";
  return String(event?.content || "").trim();
}

export function assistantProse(events = [], turn = null) {
  return events
    .filter(event => (normalizeAgentEventType(event?.type) === "assistant" || String(event?.role || "").toLowerCase() === "assistant")
      && (turn === null || event.turn === turn))
    .map(event => String(event.content || "").trim())
    .filter(Boolean)
    .join("\n\n");
}

/** Copies text without reading from the user's existing clipboard. */
export async function copyAgentText(text, clipboard = globalThis.navigator?.clipboard) {
  const value = String(text || "");
  if (!value) return false;
  try {
    if (clipboard?.writeText) {
      await clipboard.writeText(value);
      return true;
    }
  } catch {
    // Fall through to the browser's explicit selection fallback.
  }
  if (typeof document === "undefined" || !document.body) return false;
  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  let copied = false;
  try { copied = Boolean(document.execCommand?.("copy")); } catch { copied = false; }
  textarea.remove();
  return copied;
}

// OpenCode stores a mutable part and the Host exposes each observed update as
// an append-only event. Fold those deltas back into one renderable message so
// streaming replies do not produce a bubble (or React key) per database poll.
// Other providers already emit one event per message and pass through intact.
function coalesceAgentContent(events) {
  const result = [];
  const positions = new Map();
  for (const source of events || []) {
    if (!source) continue;
    if (!isOpenCodeContentEvent(source) || !source.id) {
      result.push(source);
      continue;
    }
    const key = `${source.provider}:${source.type}:${source.id}`;
    const position = positions.get(key);
    if (position === undefined) {
      const event = { ...source };
      result.push(event);
      positions.set(key, result.length - 1);
      continue;
    }
    const previous = result[position];
    const event = {
      ...previous,
      ...source,
      // Keep the first sequence so the merged block stays at the point where
      // the provider first emitted the part. The latest metadata (especially
      // model and stopReason) still comes from the newest update.
      seq: previous.seq,
      content: source.contentDelta
        ? `${previous.content || ""}${source.content || ""}`
        : (source.content || previous.content || ""),
    };
    if (!source.stopReason && previous.stopReason) event.stopReason = previous.stopReason;
    result[position] = event;
  }
  return result;
}

function isOpenCodeContentEvent(event) {
  return event.provider === "opencode"
    && (event.type === "user" || event.type === "assistant" || event.type === "reasoning");
}

function foldTurns(blocks) {
  const result = [];
  let turn = [];

  const flush = () => {
    if (!turn.length) return;
    const order = [];
    let lastActivityIndex = -1;
    for (let index = 0; index < turn.length; index += 1) {
      const block = turn[index];
      if (block.kind === "reasoning") {
        order.push({ kind: "reasoning", event: block.event });
        lastActivityIndex = index;
      } else if (block.kind === "tool") {
        order.push({ kind: "tool", block });
        lastActivityIndex = index;
      }
    }
    if (order.length === 0) {
      result.push(...turn);
    } else {
      const group = {
        kind: "activity_group",
        reasoning: order.filter(item => item.kind === "reasoning").map(item => item.event),
        tools: order.filter(item => item.kind === "tool").map(item => item.block),
        order,
      };
      for (let index = 0; index < turn.length; index += 1) {
        if (index === lastActivityIndex) {
          result.push(group);
        } else if (turn[index].kind !== "reasoning" && turn[index].kind !== "tool") {
          result.push(turn[index]);
        }
      }
    }
    turn = [];
  };

  for (const block of blocks) {
    if (block.kind === "user") {
      flush();
      result.push(block);
    } else {
      turn.push(block);
    }
  }
  flush();
  return result;
}
