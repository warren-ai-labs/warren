export const agentEventLimit = 2000;

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
