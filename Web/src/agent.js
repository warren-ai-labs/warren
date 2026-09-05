import { validateCanonicalAgentEvent } from "./agent-store.js";

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

export function agentEventSequence(event) {
  const value = event?.sequence;
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

/** Applies Host control facts only through the contiguous event prefix. */
export function projectAgentControlState(events, current = {}, checkpoint = null) {
  let projectionThrough = current.projectionThrough || 0;
  let status = current.status || null;
  let turn = current.turn || null;
  if (checkpoint && checkpoint.sequence >= projectionThrough) {
    projectionThrough = checkpoint.sequence;
    status = checkpoint.state?.status || status;
    if (checkpoint.state?.turnId) turn = { id: Number(checkpoint.state.turnId), status: checkpoint.state.turnStatus };
  }
  for (const event of events) {
    if (event.sequence <= projectionThrough) continue;
    if (event.sequence !== projectionThrough + 1) break;
    projectionThrough = event.sequence;
    if (event.type === "status.changed") status = event.payload;
    if (["turn.started", "turn.completed", "turn.failed", "turn.cancelled"].includes(event.type)) {
      turn = { id: Number(event.turnId), status: event.type === "turn.cancelled" ? "aborted" : event.type.slice(5) };
    }
  }
  return { projectionThrough, status, turn };
}

/**
 * Converts the Host-owned canonical envelope into the provider-neutral shape
 * consumed by the existing presentation reducer. No transcript parsing occurs
 * here: payload fields are selected solely by the canonical event type.
 */
export function normalizeCanonicalAgentEvent(event) {
  validateCanonicalAgentEvent(event);
  const sequence = agentEventSequence(event);
  const payload = event.payload && typeof event.payload === "object" ? event.payload : {};
  const originProvider = event.origin?.provider || "";
  const type = String(event.type || "").trim().toLowerCase();
  let projectedType = type;
  let role = payload.role || null;
  let content = payload.content ?? payload.contentDelta ?? null;
  let contentDelta = type === "message.delta";
  const projected = { ...event, sequence, eventId: event.eventId };
  if (!projected.provider && originProvider) projected.provider = originProvider;
  switch (type) {
    case "message.created":
      projectedType = "message";
      break;
    case "message.delta":
      projectedType = "message";
      break;
    case "message.completed":
      projectedType = "message";
      contentDelta = false;
      break;
    case "reasoning.delta":
      projectedType = "reasoning";
      break;
    case "tool.started":
      projectedType = "tool_call";
      break;
    case "tool.updated":
      projectedType = "tool_call";
      break;
    case "tool.completed":
      projectedType = "tool_output";
      break;
    case "tool.failed":
      projectedType = "tool_output";
      break;
    case "interaction.requested":
      projectedType = payload.kind || "question";
      break;
    case "interaction.resolved":
      projectedType = "response";
      break;
    case "plan.updated":
      projectedType = "plan";
      break;
    case "tasks.updated":
      projectedType = "todo";
      break;
    case "context.updated":
      projectedType = "context";
      break;
    default:
      break;
  }
  if (projectedType === "message" && !role) role = "assistant";
  projected.type = projectedType;
  if (role) projected.role = role;
  if (content !== null && content !== undefined) projected.content = String(content);
  if (contentDelta) projected.contentDelta = true;
  projected.id = String(payload.messageId || payload.callId || payload.interactionId || event.eventId);
  if (payload.toolName !== undefined) projected.toolName = payload.toolName;
  if (payload.toolInput !== undefined) projected.toolInput = payload.toolInput;
  if (payload.toolStatus !== undefined) projected.toolStatus = payload.toolStatus;
  if (payload.callId !== undefined) projected.callId = payload.callId;
  if (payload.output !== undefined) projected.output = payload.output;
  if (payload.error !== undefined) projected.error = payload.error;
  if (payload.files !== undefined) projected.files = payload.files;
  if (payload.model !== undefined) projected.model = payload.model;
  if (payload.stopReason !== undefined) projected.stopReason = payload.stopReason;
  if (payload.usage !== undefined) projected.usage = payload.usage;
  return projected;
}

export function normalizeAgentEventType(type) {
  return String(type || "").trim().toLowerCase().replaceAll("-", "_");
}

export function isStructuredAgentEvent(event) {
  return agentStructuredEventTypes.has(normalizeAgentEventType(event?.type));
}

/** Formats wire model identifiers for compact human-facing metadata. */
export function formatAgentModel(raw) {
  const value = String(raw || "").trim();
  if (!value) return "";
  let leaf = value.split("/").at(-1) || value;
  // Strip tags like :free, :latest, @...
  leaf = leaf.replace(/:(?:latest|free)$/i, "").replace(/@.*$/, "");
  // Strip snapshot/date suffixes like -20250219, -2024-10-22, -latest
  leaf = leaf.replace(/-(?:20\d{6}|20\d{2}-\d{2}-\d{2}|latest)$/i, "");
  // Convert hyphens between digits to decimal dots: e.g. 3-7 -> 3.7, 3-5 -> 3.5
  leaf = leaf.replace(/(\d)-(\d)/g, "$1.$2");

  const words = leaf
    .replaceAll("_", "-")
    .replaceAll(" ", "-")
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
    if (lower === "claude") return "Claude";
    if (lower === "gemini") return "Gemini";
    if (lower === "deepseek") return "DeepSeek";
    if (lower === "qwen") return "Qwen";
    if (lower === "llama") return "Llama";
    if (lower === "mistral") return "Mistral";
    if (lower === "codestral") return "Codestral";
    if (lower === "dbrx") return "DBRX";
    if (lower === "glm") return "Glm";
    if (/^o[1-9]$/i.test(word)) return word.toLowerCase();
    if (/^r\d+$/i.test(word)) return word.toUpperCase();
    if (/^v\d+$/i.test(word)) return word.toUpperCase();
    if (/^\d+b$/i.test(word)) return `${word.slice(0, -1)}${word.slice(-1).toUpperCase()}`;
    return `${word.charAt(0).toUpperCase()}${word.slice(1).toLowerCase()}`;
  }).join(" ");
}

export const AGENT_MODELS_BY_PROVIDER = {
  codex: [
    { id: "gpt-5", label: "GPT-5" },
    { id: "gpt-5-mini", label: "GPT-5 mini" },
    { id: "o3", label: "o3" },
    { id: "o3-mini", label: "o3-mini" },
    { id: "o1", label: "o1" },
    { id: "gpt-4.1", label: "GPT-4.1" },
  ],
  claude: [
    { id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet" },
    { id: "claude-3-5-sonnet", label: "Claude 3.5 Sonnet" },
    { id: "claude-3-5-haiku", label: "Claude 3.5 Haiku" },
    { id: "claude-3-opus", label: "Claude 3 Opus" },
  ],
  antigravity: [
    { id: "gemini-2.5-pro", label: "Gemini 2.5 Pro" },
    { id: "gemini-2.5-flash", label: "Gemini 2.5 Flash" },
    { id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet" },
    { id: "auto", label: "Auto" },
  ],
  opencode: [
    { id: "anthropic/claude-3-7-sonnet", label: "Claude 3.7 Sonnet" },
    { id: "openai/gpt-5", label: "GPT-5" },
    { id: "openai/o3-mini", label: "o3-mini" },
    { id: "deepseek/deepseek-r1", label: "DeepSeek R1" },
    { id: "deepseek/deepseek-chat", label: "DeepSeek V3" },
  ],
  pi: [
    { id: "anthropic/claude-3-7-sonnet", label: "Claude 3.7 Sonnet" },
    { id: "openai/gpt-5", label: "GPT-5" },
    { id: "deepseek/deepseek-r1", label: "DeepSeek R1" },
  ],
  qoder: [
    { id: "efficient", label: "Efficient" },
    { id: "performance", label: "Performance" },
    { id: "gpt-5", label: "GPT-5" },
    { id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet" },
  ],
};

export const DEFAULT_COMMON_MODELS = [
  { id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet" },
  { id: "claude-3-5-sonnet", label: "Claude 3.5 Sonnet" },
  { id: "gpt-5", label: "GPT-5" },
  { id: "o3-mini", label: "o3-mini" },
  { id: "gemini-2.5-pro", label: "Gemini 2.5 Pro" },
  { id: "deepseek-r1", label: "DeepSeek R1" },
];

export const AGENT_REASONING_OPTIONS = [
  { id: "default", label: "Default", description: "Standard reasoning effort" },
  { id: "off", label: "Off", description: "Disable extended thinking" },
  { id: "low", label: "Low", description: "Fast, minimal reasoning" },
  { id: "medium", label: "Medium", description: "Balanced reasoning effort" },
  { id: "high", label: "High", description: "Deep, thorough reasoning" },
];

const AGENT_REASONING_IDS = new Set(AGENT_REASONING_OPTIONS.map(option => option.id));

export function getAvailableAgentModels(provider) {
  const normalized = normalizeAgentProvider(provider);
  return AGENT_MODELS_BY_PROVIDER[normalized] || DEFAULT_COMMON_MODELS;
}

export function formatAgentReasoning(effort) {
  const normalized = String(effort || "default").trim().toLowerCase();
  const found = AGENT_REASONING_OPTIONS.find(opt => opt.id === normalized);
  return found ? found.label : "Default";
}

function normalizeAgentModelID(modelId) {
  // Model IDs are sent through a provider's command parser. Keep them on one
  // line so a pasted control character cannot turn one setting into several
  // commands.
  return String(modelId || "").replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, " ").trim();
}

function normalizeAgentProvider(provider) {
  const normalized = String(provider || "").trim().toLowerCase();
  if (normalized === "claude-code") return "claude";
  if (normalized === "agy") return "antigravity";
  if (normalized === "open-code") return "opencode";
  return normalized;
}

export function defaultAgentLaunchCommand(provider) {
  switch (normalizeAgentProvider(provider)) {
    case "claude": return "claude";
    case "codex": return "codex --dangerously-bypass-hook-trust";
    case "antigravity": return "agy";
    case "opencode": return "opencode";
    case "pi": return "pi";
    case "qoder": return "qoder";
    case "trae": return "trae-cli interactive";
    default: return "";
  }
}

export function agentModelSwitchCommand(modelId) {
  const model = normalizeAgentModelID(modelId);
  if (!model) return "";
  return `/model ${model}`;
}

export function agentReasoningSwitchCommand(effort, provider) {
  const normalized = String(effort || "default").trim().toLowerCase();
  if (!AGENT_REASONING_IDS.has(normalized) || normalized === "default") return "";
  const prov = normalizeAgentProvider(provider);
  if (prov === "pi") {
    return `/thinking ${normalized}`;
  }
  return `/effort ${normalized}`;
}

export function agentReasoningResetCommand(provider) {
  return normalizeAgentProvider(provider) === "pi"
    ? "/thinking default"
    : "/effort default";
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

/**
 * Adds optional launch-time settings without changing the configured command
 * when the user leaves both controls at their defaults.
 */
export function agentLaunchCommand(command, provider, { model = "", reasoning = "default" } = {}) {
  const kind = normalizeAgentProvider(provider);
  const configuredBase = String(command || "").trim();
  const base = configuredBase || defaultAgentLaunchCommand(kind);
  const args = [];
  const modelID = normalizeAgentModelID(model);
  const effort = String(reasoning || "default").trim().toLowerCase();

  if (modelID && ["claude", "codex", "antigravity", "opencode", "pi", "qoder"].includes(kind)) {
    args.push("--model", shellQuote(modelID));
  }
  if (effort !== "default" && AGENT_REASONING_IDS.has(effort)) {
    if (kind === "codex" && effort !== "off") args.push("-c", `model_reasoning_effort=${effort}`);
    else if (["claude", "antigravity"].includes(kind) && effort !== "off") args.push("--effort", effort);
    else if (kind === "pi") args.push("--thinking", effort);
    else if (kind === "qoder" && effort !== "off") args.push("--reasoning-effort", effort);
  }
  return [base, ...args].filter(Boolean).join(" ");
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
    const normalized = event;
    const sequence = agentEventSequence(normalized);
    if (normalized && sequence && !bySequence.has(sequence)) {
      bySequence.set(sequence, normalized);
    }
  }
  for (const event of incoming || []) {
    // Sequence numbers identify immutable positions in a stream. A replayed
    // history/live overlap must retain the first observed event rather than
    // letting a later payload rewrite that position.
    const normalized = normalizeCanonicalAgentEvent(event);
    const sequence = agentEventSequence(normalized);
    if (normalized && sequence && !bySequence.has(sequence)) {
      bySequence.set(sequence, normalized);
    }
  }
  return [...bySequence.values()]
    .sort((left, right) => agentEventSequence(left) - agentEventSequence(right))
    .slice(cap ? -agentEventLimit : undefined);
}

/**
 * Groups a flat transcript into renderable blocks. A tool_call and its
 * matching tool_output(s) become one tool block so the UI can show the call
 * and its result as a single compact step instead of two separate cards.
 * Reasoning and tool blocks are folded only while they are contiguous in the
 * transcript. Any visible message or protocol event closes that activity
 * segment, matching the iOS projection instead of hiding work from later
 * assistant messages in one turn-wide disclosure.
 */
export function groupAgentEvents(events = []) {
  const blocks = [];
  const activity = [];
  const pending = new Map();

  const flushActivity = () => {
    if (activity.length === 0) return;
    const order = [...activity];
    blocks.push({
      kind: "activity_group",
      reasoning: order
        .filter(item => item.kind === "reasoning")
        .map(item => item.event),
      tools: order
        .filter(item => item.kind === "tool")
        .map(item => item.block),
      order,
    });
    activity.length = 0;
    pending.clear();
  };

  for (const event of coalesceAgentContent(events)) {
    if (isStructuredAgentEvent(event)) {
      flushActivity();
      blocks.push({ kind: "structured", event });
    } else if (isToolCallAgentEvent(event)) {
      const block = { kind: "tool", call: event, outputs: [] };
      activity.push({ kind: "tool", block });
      const correlationID = agentCorrelationID(event);
      if (correlationID) pending.set(correlationID, block);
    } else if (isToolOutputAgentEvent(event)) {
      const correlationID = agentCorrelationID(event);
      const block = correlationID ? pending.get(correlationID) : null;
      if (block) {
        block.outputs.push(event);
      } else {
        flushActivity();
        blocks.push({ kind: "tool_output", event });
      }
    } else if (isReasoningAgentEvent(event)) {
      if (!hasRenderableActivityContent(event)) continue;
      activity.push({ kind: "reasoning", event });
    } else {
      const kind = conversationBlockKind(event);
      if ((kind === "user" || kind === "assistant") && !hasRenderableConversationContent(event)) continue;
      flushActivity();
      blocks.push({ kind, event });
    }
  }
  flushActivity();
  const consolidated = [];
  for (const block of blocks) {
    const prev = consolidated.at(-1);
    if (prev && prev.kind === "activity_group" && block.kind === "activity_group") {
      prev.reasoning.push(...block.reasoning);
      prev.tools.push(...block.tools);
      prev.order.push(...block.order);
    } else {
      consolidated.push(block);
    }
  }
  return consolidated;
}

/** Returns renderable blocks with one card per structured object ID. */
export function projectAgentEvents(events = []) {
  const latestStructured = new Map();
  const projected = [];
  for (const event of events || []) {
    if (isStructuredAgentEvent(event)) {
      const type = normalizeAgentEventType(event.type);
      const stableID = String(event.id || `sequence-${event.sequence}`);
      latestStructured.set(`${type}:${stableID}`, event);
    } else {
      projected.push(event);
    }
  }
  // Keep the latest structured update in the timeline before grouping. The
  // structured event is also a message boundary: removing it first would let
  // activity from either side of a question/plan card collapse into one row.
  projected.push(...latestStructured.values());
  projected.sort((left, right) => (left?.sequence ?? 0) - (right?.sequence ?? 0));
  return groupAgentEvents(projected);
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

export function agentSettingsKey(endpointIdentity, sessionID) {
  return `warren.agent-settings.${encodeAgentDraftKeyPart(endpointIdentity)}.${encodeAgentDraftKeyPart(sessionID)}`;
}

export function loadAgentSettings(storage, endpointIdentity, sessionID) {
  try {
    const raw = storage?.getItem(agentSettingsKey(endpointIdentity, sessionID));
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

export function saveAgentSettings(storage, endpointIdentity, sessionID, settings) {
  try {
    storage?.setItem(agentSettingsKey(endpointIdentity, sessionID), JSON.stringify(settings));
    return true;
  } catch {
    return false;
  }
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

function hasRenderableActivityContent(event) {
  return [event?.content, event?.output, event?.error]
    .some(value => String(value || "").trim() !== "");
}

function hasRenderableConversationContent(event) {
  return String(event?.content || "").trim() !== "";
}

function conversationBlockKind(event) {
  const type = normalizeAgentEventType(event?.type);
  const role = normalizeAgentEventType(event?.role);
  if (type === "user" || role === "user") return "user";
  if (type === "assistant" || role === "assistant") return "assistant";
  return event?.type;
}

function isReasoningAgentEvent(event) {
  const type = normalizeAgentEventType(event?.type);
  return type === "reasoning" || type.includes("thinking") || type.includes("reason");
}

function isToolCallAgentEvent(event) {
  const type = normalizeAgentEventType(event?.type);
  return type === "tool_call" || type === "toolcall";
}

function isToolOutputAgentEvent(event) {
  const type = normalizeAgentEventType(event?.type);
  return type === "tool_output" || type === "tooloutput";
}

function agentCorrelationID(event) {
  const callID = String(event?.callId || "").trim();
  if (callID) return callID;
  return String(event?.id || "").trim();
}

// Conversation-shaped events that providers stream as a seed plus
// contentDelta updates: user, assistant, and reasoning text. Tool and
// structured events carry their own lifecycle and are not folded here.
function isCoalescibleAgentEvent(event) {
  const type = normalizeAgentEventType(event?.type);
  return type === "user" || type === "assistant" || isReasoningAgentEvent(event);
}

// Some providers (notably OpenCode) store a mutable part and the Host
// exposes each observed update as an append-only event: a seed followed by
// contentDelta=true updates. Fold those updates back into one renderable
// message so streaming replies do not produce a bubble (or React key) per
// database poll. Seeds and deltas share the same (type,id) key; providers
// that emit one event per message still pass through intact.
function coalesceAgentContent(events) {
  const result = [];
  const positions = new Map();
  for (const source of events || []) {
    if (!source || !source.id || !isCoalescibleAgentEvent(source)) {
      result.push(source);
      continue;
    }
    const key = `${source.type}:${source.id}`;
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
      sequence: previous.sequence,
      content: source.contentDelta
        ? `${previous.content || ""}${source.content || ""}`
        : (source.content || previous.content || ""),
    };
    if (!source.stopReason && previous.stopReason) event.stopReason = previous.stopReason;
    result[position] = event;
  }
  return result;
}

// displayToolName maps a canonical tool name (already normalized by the
// parser) to a human-friendly label.
export function displayToolName(name) {
  const labels = {
    shell: "Shell",
    edit: "Edit file",
    write: "Write file",
    read: "Read file",
    grep: "Search files",
    glob: "Find files",
    web_search: "Web search",
    fetch: "Web fetch",
    subagent: "Subagent",
    ask_user_question: "Question",
    permission_request: "Permission",
    apply_patch: "Apply patch",
    exec: "Shell",
    execute: "Shell",
    run_command: "Shell",
    replace_file_content: "Edit file",
    write_to_file: "Write file",
    view_file: "Read file",
    grep_search: "Search files",
    find_by_name: "Find files",
    list_dir: "Find files",
    search_web: "Web search",
    read_url_content: "Web fetch",
    invoke_subagent: "Subagent",
    ask_question: "Question",
  };
  return labels[name] || name || "Tool";
}

export function isCommandTool(toolName, toolInput = null) {
  const name = (toolName || "").toLowerCase().trim();
  if (["shell", "exec", "execute", "run_command", "bash", "local_shell_call"].includes(name)) {
    return true;
  }
  if (toolInput && typeof toolInput === "object") {
    return Boolean(toolInput.command || toolInput.cmd || toolInput.CommandLine);
  }
  return false;
}

export function basename(path) {
  if (typeof path !== "string") return "";
  const clean = path.replace(/^["']|["']$/g, "").trim();
  const index = Math.max(clean.lastIndexOf("/"), clean.lastIndexOf("\\"));
  return index >= 0 ? clean.slice(index + 1) : clean;
}

export function cleanDisplayPath(path) {
  if (typeof path !== "string") return "";
  const clean = path.replace(/^["']|["']$/g, "").trim();
  if (clean.startsWith("/") && (clean.length > 30 || clean.startsWith("/Users/") || clean.startsWith("/home/"))) {
    return basename(clean);
  }
  return clean;
}

export function extractPatchFiles(patch) {
  if (typeof patch !== "string") return [];
  const files = [];
  for (const line of patch.split("\n")) {
    for (const marker of ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "+++ b/", "--- a/"]) {
      if (line.startsWith(marker)) {
        const name = line.slice(marker.length).trim();
        if (name && !files.includes(name) && name !== "/dev/null" && name !== "dev/null") {
          files.push(name);
        }
        break;
      }
    }
  }
  return files;
}

export function formatFileList(list) {
  if (!Array.isArray(list) || list.length === 0) return "";
  const valid = list.filter(Boolean);
  if (valid.length === 0) return "";
  if (valid.length === 1) return truncatePreview(cleanDisplayPath(valid[0]));
  if (valid.length <= 3) return valid.map(f => truncatePreview(basename(f))).join(", ");
  return `${valid.slice(0, 2).map(f => truncatePreview(basename(f))).join(", ")} (+${valid.length - 2} more)`;
}

export function truncatePreview(value, maxLength = 140) {
  if (typeof value !== "string") return "";
  if (value.length <= maxLength) return value;
  return `${value.slice(0, maxLength)}…`;
}

export function extractExecCommands(raw) {
  if (typeof raw !== "string") return [];
  const commands = [];
  const pattern = /(?:exec_command|exec|execute)\s*\(\s*\{[^\n}]*["']?(?:cmd|command)["']?\s*:\s*"(?:[^"\\]|\\.)*"/g;
  let match;
  while ((match = pattern.exec(raw))) {
    const body = match[0];
    const value = body.match(/["']?(?:cmd|command)["']?\s*:\s*"((?:[^"\\]|\\.)*)"/);
    if (value) {
      commands.push(value[1].replace(/\\(["\\])/g, "$1"));
    }
  }
  if (commands.length === 0) {
    const jsonPattern = /["'](?:cmd|command)["']\s*:\s*"((?:[^"\\]|\\.)*)"/g;
    while ((match = jsonPattern.exec(raw))) {
      commands.push(match[1].replace(/\\(["\\])/g, "$1"));
    }
  }
  return commands;
}

export function toolSummary(call) {
  if (!call) return "";
  const input = call.toolInput;
  const files = Array.isArray(call.files) ? call.files.filter(Boolean) : [];

  if (typeof input === "string" && input.trim()) {
    const raw = input.trim();
    const commands = extractExecCommands(raw);
    if (commands.length > 0) {
      const first = truncatePreview(commands[0]);
      const summary = commands.length > 1 ? `${first}  (+${commands.length - 1} more)` : first;
      return files.length > 0 ? `${summary} · ${formatFileList(files)}` : summary;
    }
    return truncatePreview(raw);
  }

  if (input && typeof input === "object") {
    const action = input.toolAction || input.toolSummary || input.action;
    const cleanAction = typeof action === "string" ? action.replace(/^["']|["']$/g, "").trim() : "";

    const cmd = input.command || input.cmd || input.CommandLine;
    if (typeof cmd === "string" && cmd.trim()) {
      const commandStr = truncatePreview(cmd.trim());
      if (files.length > 0) {
        return `${commandStr} · ${formatFileList(files)}`;
      }
      return commandStr;
    }
    if (Array.isArray(cmd)) {
      const parts = cmd.filter(c => typeof c === "string").join(" ");
      if (parts) return truncatePreview(parts);
    }

    if (typeof input.raw === "string") {
      const commands = extractExecCommands(input.raw);
      if (commands.length > 0) {
        const first = truncatePreview(commands[0]);
        const summary = commands.length > 1 ? `${first}  (+${commands.length - 1} more)` : first;
        if (files.length > 0) return `${summary} · ${formatFileList(files)}`;
        return summary;
      }
      return input.raw.length > 200
        ? `${input.raw.slice(0, 200)}…`
        : input.raw;
    }

    const filePath = input.file_path || input.path || input.TargetFile || input.AbsolutePath || input.file || input.filename || input.target;
    if (typeof filePath === "string" && filePath.trim()) {
      const cleanP = cleanDisplayPath(filePath);
      if (cleanAction) return `${cleanAction}: ${cleanP}`;
      return truncatePreview(cleanP);
    }

    if (files.length > 0) {
      const fileSummary = formatFileList(files);
      if (cleanAction) return `${cleanAction}: ${fileSummary}`;
      return fileSummary;
    }

    if (typeof input.patch === "string" && input.patch.trim()) {
      const patchFiles = extractPatchFiles(input.patch);
      if (patchFiles.length > 0) {
        return formatFileList(patchFiles);
      }
    }

    const query = input.query || input.Query || input.pattern || input.Pattern;
    if (typeof query === "string" && query.trim()) {
      const cleanQ = query.replace(/^["']|["']$/g, "").trim();
      const scope = input.SearchPath || input.SearchDirectory || input.path;
      if (typeof scope === "string" && scope.trim()) {
        return `"${truncatePreview(cleanQ, 50)}" in ${truncatePreview(basename(scope.trim()))}`;
      }
      return `"${truncatePreview(cleanQ)}"`;
    }
    if (Array.isArray(input.queries)) return input.queries.join(", ");

    const url = input.url || input.Url;
    if (typeof url === "string" && url.trim()) {
      return truncatePreview(url.replace(/^["']|["']$/g, "").trim());
    }

    const text = input.prompt || input.instruction || input.Instruction || input.description || input.Description;
    if (typeof text === "string" && text.trim()) {
      return truncatePreview(text.trim());
    }

    if (cleanAction) {
      return cleanAction;
    }
  }

  if (files.length > 0) {
    return formatFileList(files);
  }

  return "";
}

/** Extracts the latest active tool or action summary from agent events. */
export function latestAgentAction(events = []) {
  if (!Array.isArray(events)) return "";
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const event = events[i];
    if (!event) continue;
    if (isToolCallAgentEvent(event)) {
      const name = displayToolName(event.toolName);
      const summary = toolSummary(event);
      return summary ? `${name} ${summary}` : name;
    }
    if (isToolOutputAgentEvent(event)) {
      const name = displayToolName(event.toolName);
      return name;
    }
  }
  return "";
}
