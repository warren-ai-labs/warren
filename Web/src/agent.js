export const agentEventLimit = 2000;

/** Formats wire model identifiers for compact human-facing metadata. */
export function formatAgentModel(raw) {
  const value = String(raw || "").trim();
  if (!value) return "";
  const leaf = value.split("/").at(-1) || value;
  const words = leaf
    .replaceAll("_", "-")
    .split("-")
    .filter(Boolean);
  return words.map(word => {
    const lower = word.toLowerCase();
    if (lower === "gpt") return "GPT";
    if (lower === "llm") return "LLM";
    if (lower === "sol") return "Sol";
    if (lower === "sonnet") return "Sonnet";
    if (lower === "haiku") return "Haiku";
    if (lower === "opus") return "Opus";
    return `${word.charAt(0).toUpperCase()}${word.slice(1)}`;
  }).join(" ");
}

/**
 * Computes the textarea height without touching the DOM. The composer starts
 * at two lines, grows to six, and then lets the textarea scroll internally.
 */
export function composerHeightForText(text = "", {
  lineHeight = 22,
  minLines = 2,
  maxLines = 6,
  verticalPadding = 16,
} = {}) {
  const lines = Math.max(1, String(text).split("\n").reduce((total, line) => total + Math.max(1, Math.ceil(line.length / 80)), 0));
  const visibleLines = Math.min(maxLines, Math.max(minLines, lines));
  return visibleLines * lineHeight + verticalPadding;
}

export function agentComposerAction(status, { hasControl = true, hasText = false } = {}) {
  if (!hasControl) return "unavailable";
  const activity = String(status?.activity || "").toLowerCase();
  if (["failed", "stalled", "exited", "unknown"].includes(activity)) return "unavailable";
  if (activity === "working") return "interrupt";
  if (status?.attention && status.attention.kind !== "input") return "unavailable";
  if (activity === "blocked" && status?.attention?.kind !== "input") return "unavailable";
  return hasText ? "send" : "unavailable";
}

function queueItemID() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return `queue-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export function enqueueAgentMessage(queue = [], text, id = queueItemID()) {
  const value = String(text || "").trim();
  if (!value) return [...queue];
  return [...queue, { id, text: value }];
}

export function editAgentQueueItem(queue = [], id, text) {
  const value = String(text || "").trim();
  if (!value) return queue.filter(item => item.id !== id);
  return queue.map(item => item.id === id ? { ...item, text: value } : item);
}

export function deleteAgentQueueItem(queue = [], id) {
  return queue.filter(item => item.id !== id);
}

export function moveAgentQueueItem(queue = [], from, to) {
  if (!Number.isInteger(from) || from < 0 || from >= queue.length) return [...queue];
  const target = Math.min(Math.max(Number.isInteger(to) ? to : 0, 0), queue.length);
  const next = [...queue];
  const [item] = next.splice(from, 1);
  const adjusted = target > from ? target - 1 : target;
  next.splice(Math.min(Math.max(adjusted, 0), next.length), 0, item);
  return next;
}

export function retryAgentQueueItem(queue = [], id) {
  const index = queue.findIndex(item => item.id === id);
  if (index < 0) return [...queue];
  return moveAgentQueueItem(queue, index, 0);
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
    if (event && Number.isFinite(event.seq)) bySequence.set(event.seq, event);
  }
  for (const event of incoming || []) {
    if (event && Number.isFinite(event.seq)) bySequence.set(event.seq, event);
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
    if (event.type === "tool_call") {
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
