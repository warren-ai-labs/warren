// The attention-first Conversation projection (RFC 0023 §9).
//
// It folds canonical Agent events into turns. A turn is the unit a person
// reads: what they asked, a one-line summary of the work, and the answer. Work
// is summarized rather than narrated, reasoning is opt-in, and the only thing
// allowed to ask for attention is a pending decision, which is lifted out of
// the timeline into the decision dock.
//
// Input rows are the normalized events `mergeAgentEvents` returns; this module
// reads their canonical type, payload, turn ID, and time only.

const TURN_TERMINAL = {
  "turn.completed": "completed",
  "turn.failed": "failed",
  "turn.cancelled": "cancelled",
  "turn.interrupted": "interrupted",
  "turn.aborted": "cancelled",
};

function canonicalType(event) {
  return String(event?.canonicalType || event?.type || "").trim().toLowerCase();
}

function payloadOf(event) {
  return event?.payload && typeof event.payload === "object" ? event.payload : {};
}

function text(value) {
  return typeof value === "string" ? value : value == null ? "" : String(value);
}

function timeOf(event) {
  const value = Date.parse(event?.occurredAt || event?.recordedAt || "");
  return Number.isFinite(value) ? value : 0;
}

function newTurn(id) {
  return {
    id,
    user: null,
    messages: [],
    steps: [],
    reasoning: { text: "", startedAt: 0, endedAt: 0, count: 0 },
    notices: [],
    errors: [],
    status: "running",
    startedAt: 0,
    endedAt: 0,
  };
}

/// Folds message rows into ordered text by message ID: created and completed
/// rows replace, deltas append.
function applyMessage(list, id, type, content) {
  let message = list.find(item => item.id === id);
  if (!message) {
    message = { id, text: "", complete: false };
    list.push(message);
  }
  if (type === "message.delta") message.text += content;
  else if (content || type === "message.created") message.text = content || message.text;
  if (type === "message.completed") message.complete = true;
  return message;
}

function stepFromTool(existing, event) {
  const payload = payloadOf(event);
  const type = canonicalType(event);
  const step = existing || {
    kind: "tool",
    id: text(payload.callId || event.id),
    toolKind: "tool",
    title: "",
    detail: "",
    status: "pending",
    output: "",
    error: "",
    diff: null,
    terminalSessionId: "",
    order: event.sequence || 0,
  };
  if (payload.toolKind) step.toolKind = text(payload.toolKind);
  if (payload.toolName) step.title = text(payload.toolName);
  if (payload.toolDetail) step.detail = text(payload.toolDetail);
  if (payload.output) step.output = text(payload.output);
  if (payload.error) step.error = text(payload.error);
  if (payload.diff && typeof payload.diff === "object") step.diff = payload.diff;
  if (payload.terminalSessionId) step.terminalSessionId = text(payload.terminalSessionId);
  if (type === "tool.completed") step.status = "completed";
  else if (type === "tool.failed") step.status = "failed";
  else if (payload.toolStatus === "in_progress") step.status = "running";
  return step;
}

function interactionID(event) {
  const payload = payloadOf(event);
  return text(payload.interactionId || payload.requestId || event.id);
}

/// Adds the Host's state events (the selectors, plan, and context from before
/// the loaded window) to a page of events, in sequence order.
export function withStateEvents(events = [], stateEvents = []) {
  if (!stateEvents.length) return events;
  const held = new Set(events.map(event => Number(event?.sequence)));
  const missing = stateEvents.filter(event => !held.has(Number(event?.sequence)));
  if (!missing.length) return events;
  return [...missing, ...events].sort((left, right) => (Number(left?.sequence) || 0) - (Number(right?.sequence) || 0));
}

// What each projected turn was folded from: the events that touched it and
// the size of what they produced. Events are immutable by sequence, so an
// equal signature means an equal turn.
const turnSignatures = new WeakMap();

/// Hands back the previous projection's turn objects wherever a turn is
/// unchanged, so a memoized turn view skips the turns a batch did not touch.
export function reuseUnchangedTurns(previous = [], turns = []) {
  if (!previous.length) return turns;
  const byID = new Map(previous.map(turn => [turn.id, turn]));
  return turns.map(turn => {
    const prior = byID.get(turn.id);
    return prior && turnSignatures.has(turn) && turnSignatures.get(prior) === turnSignatures.get(turn) ? prior : turn;
  });
}

// Claude Code records a local slash command and its output as markup envelopes
// in system-role rows. Rows journaled before the parser unwrapped them still
// arrive raw, so the projection unwraps them here too. Anything it does not
// recognize keeps its text rather than disappearing.
function commandLine(name, args) {
  return args ? `${name} ${args}` : name;
}

// Splits a value made only of <tag>inner</tag> elements, in any order and
// separated by whitespace. Returns null as soon as anything outside a tag
// appears, so a partially understood envelope is left as-is.
function tagFields(value) {
  const fields = {};
  let rest = value.trim();
  while (rest) {
    if (!rest.startsWith("<")) return null;
    const open = rest.indexOf(">");
    if (open < 0) return null;
    const tag = rest.slice(1, open);
    if (!tag || /[\s/]/.test(tag)) return null;
    const closing = `</${tag}>`;
    const end = rest.indexOf(closing, open + 1);
    if (end < 0) return null;
    fields[tag] = rest.slice(open + 1, end);
    rest = rest.slice(end + closing.length).trim();
  }
  return fields;
}

function legacyLocalCommand(content) {
  if (!content.trim().startsWith("<")) return null;
  const fields = tagFields(content);
  if (!fields || !Object.keys(fields).length) return null;
  const only = allowed => Object.keys(fields).every(key => allowed.includes(key));
  if (fields["local-command-stdout"] != null && only(["local-command-stdout", "command-stdout", "local-command-caveat"])) {
    return { kind: "output", text: fields["local-command-stdout"] || fields["command-stdout"] || "" };
  }
  if (fields["command-name"] != null && only(["command-name", "command-message", "command-args", "local-command-caveat"])) {
    const name = fields["command-name"].trim();
    if (!name) return null;
    const args = (fields["command-args"] || "").trim();
    return { kind: "command", name, args };
  }
  if (only(["local-command-caveat"])) return { kind: "caveat" };
  return null;
}

// The quiet row a local command envelope projects to. Null means the row is
// ordinary conversation text, so the caller keeps it as-is.
function localCommandNotice(id, payload, content) {
  const command = payload.localCommand && typeof payload.localCommand === "object" ? payload.localCommand : null;
  const kind = text(command?.kind).toLowerCase();
  if (kind === "command") {
    const name = text(command.name).trim();
    if (name) {
      const args = text(command.args).trim();
      return { notice: { id, text: commandLine(name, args), kind, command: name, args } };
    }
  }
  if (kind === "output") {
    const summary = content.trim();
    return { hidden: true, notice: summary ? { id, text: summary, kind } : null };
  }
  const legacy = legacyLocalCommand(content);
  if (legacy?.kind === "caveat") return { hidden: true };
  if (legacy?.kind === "output") {
    const summary = legacy.text.trim();
    return { hidden: true, notice: summary ? { id, text: summary, kind: "output" } : null };
  }
  if (legacy?.kind === "command") {
    return { notice: { id, text: commandLine(legacy.name, legacy.args), kind: "command", command: legacy.name, args: legacy.args } };
  }
  return null;
}

/// Projects canonical events into a conversation.
export function projectConversation(events = []) {
  const turns = [];
  const byID = new Map();
  let plan = null;
  let context = null;
  let commands = [];
  let config = [];
  const interactions = new Map();
  const compactions = new Set();
  const touches = new Map();
  let applying = 0;

  const turnFor = event => {
    const id = text(event?.turnId || event?.turn || "");
    const key = id || (turns.at(-1)?.id ?? "0");
    let turn = byID.get(key);
    if (!turn) {
      turn = newTurn(key);
      byID.set(key, turn);
      turns.push(turn);
    }
    const touch = touches.get(turn) || { count: 0, first: applying, last: 0 };
    touch.count += 1;
    touch.last = applying;
    touches.set(turn, touch);
    return turn;
  };

  for (const event of events) {
    if (!event) continue;
    applying = Number(event.sequence) || 0;
    const type = canonicalType(event);
    const payload = payloadOf(event);
    switch (type) {
      case "turn.started": {
        const turn = turnFor(event);
        turn.startedAt = timeOf(event);
        turn.status = "running";
        break;
      }
      case "turn.completed":
      case "turn.failed":
      case "turn.cancelled":
      case "turn.interrupted":
      case "turn.aborted": {
        const turn = turnFor(event);
        turn.status = TURN_TERMINAL[type];
        turn.endedAt = timeOf(event);
        break;
      }
      case "message.created":
      case "message.delta":
      case "message.completed": {
        const role = text(payload.role || event.role || "assistant");
        const turn = turnFor(event);
        const id = text(payload.messageId || event.id);
        const content = text(payload.content);
        if (role === "user") {
          // A legacy local-command row was journaled under the user role. It is
          // provider markup, not a prompt, so it becomes a quiet notice or
          // disappears entirely when it is only the caveat.
          const local = localCommandNotice(id, payload, content);
          if (local) {
            if (local.notice) turn.notices.push(local.notice);
            break;
          }
          if (!turn.user) turn.user = { id, text: "", attachments: [], causedBy: text(event.causedBy) };
          turn.user.text = type === "message.delta" ? turn.user.text + content : (content || turn.user.text);
          if (Array.isArray(payload.attachments)) turn.user.attachments = payload.attachments;
        } else if (role === "system") {
          const local = localCommandNotice(id, payload, content);
          if (local) {
            if (local.notice) turn.notices.push(local.notice);
          } else if (content) {
            turn.notices.push({ id, text: content });
          }
        } else {
          const message = applyMessage(turn.messages, id, type, content);
          // Narration is assistant text that began before a later step; the
          // answer is decided once the turn's shape is known.
          message.order = message.order || event.sequence || 0;
        }
        break;
      }
      case "reasoning.delta": {
        const turn = turnFor(event);
        const at = timeOf(event);
        turn.reasoning.text += text(payload.content);
        turn.reasoning.count += 1;
        if (!turn.reasoning.startedAt) turn.reasoning.startedAt = at;
        turn.reasoning.endedAt = at;
        break;
      }
      case "tool.started":
      case "tool.updated":
      case "tool.completed":
      case "tool.failed": {
        const turn = turnFor(event);
        const id = text(payload.callId || event.id);
        const index = turn.steps.findIndex(step => step.kind === "tool" && step.id === id);
        const step = stepFromTool(index >= 0 ? turn.steps[index] : null, event);
        if (index < 0) turn.steps.push(step);
        break;
      }
      case "interaction.requested":
      case "interaction.resolved":
      case "interaction.expired": {
        const id = interactionID(event);
        const previous = interactions.get(id) || {};
        const merged = { ...previous.payload, ...payload };
        const state = type === "interaction.requested"
          ? text(merged.state || "pending")
          : type === "interaction.resolved" ? "resolved" : "expired";
        const turn = turnFor(previous.event || event);
        const record = { id, event: previous.event || event, payload: merged, state, turnID: turn.id, order: previous.order || event.sequence || 0 };
        interactions.set(id, record);
        if (state !== "pending") {
          const index = turn.steps.findIndex(step => step.kind === "decision" && step.id === id);
          const step = decisionStep(record);
          if (index >= 0) turn.steps[index] = step;
          else turn.steps.push(step);
        }
        break;
      }
      case "plan.updated":
        plan = projectPlan(payload);
        break;
      case "context.updated":
        context = { used: Number(payload.used) || 0, size: Number(payload.size) || 0, cost: payload.cost || null };
        break;
      case "commands.updated":
        commands = Array.isArray(payload.commands) ? payload.commands : [];
        break;
      case "config.updated":
        // Each row is the agent's complete selector set (RFC 0023 §6.11).
        if (Array.isArray(payload.configOptions)) config = projectConfig(payload.configOptions);
        break;
      case "compaction.updated": {
        // One notice per compaction, however often it is re-reported.
        const turn = turnFor(event);
        const id = text(payload.compactionId || event.eventId || event.id);
        if (!compactions.has(id)) {
          compactions.add(id);
          turn.notices.push({ id: `compaction-${id}`, text: "Context compacted" });
        }
        break;
      }
      case "error": {
        const turn = turnFor(event);
        const message = text(payload.error || payload.content);
        if (message) turn.errors.push({ id: text(event.eventId || event.id), text: message });
        break;
      }
      default:
        break;
    }
  }

  for (const turn of turns) {
    finishTurn(turn);
    const touch = touches.get(turn) || { count: 0, first: 0, last: 0 };
    turnSignatures.set(turn, [
      touch.count, touch.first, touch.last, turn.status, turn.messages.length, turn.steps.length,
      turn.notices.length, turn.errors.length, turn.answer.length, turn.user?.text.length ?? -1, turn.reasoning.count,
    ].join(":"));
  }

  const decisions = [...interactions.values()]
    .filter(record => record.state === "pending")
    .map(record => ({
      id: record.id,
      version: Number(record.payload.version) || 1,
      kind: text(record.payload.kind || "permission"),
      title: text(record.payload.title || "Permission"),
      toolKind: text(record.payload.toolKind),
      detail: text(record.payload.toolDetail),
      diff: record.payload.diff && typeof record.payload.diff === "object" ? record.payload.diff : null,
      options: Array.isArray(record.payload.options) ? record.payload.options.map(option => ({
        id: text(option?.id),
        label: text(option?.label || option?.id),
        kind: text(option?.kind),
      })).filter(option => option.id) : [],
    }));

  return { turns: turns.filter(turn => turn.user || turn.messages.length || turn.steps.length || turn.errors.length || turn.notices.length), plan, context, commands, config, decisions };
}

function projectConfig(options) {
  return options.map(option => {
    const choices = (Array.isArray(option?.options) ? option.options : [])
      .map(choice => ({ value: text(choice?.value), name: text(choice?.name || choice?.value), description: text(choice?.description), group: text(choice?.group) }))
      .filter(choice => choice.value);
    const current = text(option?.currentValue);
    return {
      id: text(option?.id),
      name: text(option?.name || option?.id),
      category: text(option?.category),
      currentValue: current,
      currentName: choices.find(choice => choice.value === current)?.name || current,
      options: choices,
    };
  }).filter(option => option.id && option.options.length);
}

/// The current choice without a trailing note, so "Default (recommended)"
/// reads "Default" in a chip.
export function shortChoiceName(option) {
  const name = text(option?.currentName);
  const open = name.lastIndexOf(" (");
  return name.endsWith(")") && open > 0 ? name.slice(0, open) : name;
}

/// An on/off selector reads better as a toggle than as a list.
export function isToggleOption(option) {
  const values = (option?.options || []).map(choice => choice.value.toLowerCase()).sort();
  return values.length === 2 && values[0] === "off" && values[1] === "on";
}

/// The composer's chips (the same grouping as Swift's WarrenConversation):
/// the permission mode alone; the model first, then its effort, then any
/// other selector; and the model chip's label, "Opus 5.5 · High", without
/// the effort when it is the agent's default.
export function composerChips(config = []) {
  const mode = config.find(option => option.category === "mode") || null;
  const rank = { model: 0, thought_level: 1 };
  const modelOptions = config
    .map((option, index) => ({ option, index }))
    .filter(({ option }) => option.category !== "mode")
    .sort((a, b) => ((rank[a.option.category] ?? 2) - (rank[b.option.category] ?? 2)) || a.index - b.index)
    .map(({ option }) => option);
  const parts = [];
  const model = config.find(option => option.category === "model");
  if (model) parts.push(shortChoiceName(model));
  const effort = config.find(option => option.category === "thought_level");
  if (effort && effort.currentValue !== "default") parts.push(shortChoiceName(effort));
  if (!parts.length && modelOptions.length) parts.push(shortChoiceName(modelOptions[0]));
  return { mode, modelOptions, modelSummary: parts.filter(Boolean).join(" · ") };
}

/// A step's target as a person reads it: without the `cd <dir> &&` an agent
/// prefixes to every command, and with `root/` stripped from paths.
export function displayTarget(target, root) {
  let value = text(target).trim();
  if (value.startsWith("cd ")) {
    const joiner = value.indexOf(" && ");
    if (joiner > 0) value = value.slice(joiner + 4);
  }
  const prefix = rootPrefix(root);
  return prefix ? value.split(prefix).join("") : value;
}

/// A changed file's path relative to `root` when it sits under it.
export function displayPath(path, root) {
  const value = text(path);
  const prefix = rootPrefix(root);
  return prefix && value.startsWith(prefix) ? value.slice(prefix.length) : value;
}

function rootPrefix(root) {
  const value = text(root);
  if (!value || value === "/") return "";
  return value.endsWith("/") ? value : `${value}/`;
}

function decisionStep(record) {
  const response = record.payload.response && typeof record.payload.response === "object" ? record.payload.response : {};
  const choice = text(response.decision || response.value);
  const option = (Array.isArray(record.payload.options) ? record.payload.options : []).find(item => text(item?.id) === choice);
  const kind = text(option?.kind);
  let outcome = "expired";
  if (record.state === "resolved") outcome = kind.startsWith("reject") ? "rejected" : "allowed";
  return {
    kind: "decision",
    id: record.id,
    toolKind: text(record.payload.toolKind),
    title: text(record.payload.title || "Permission"),
    detail: text(record.payload.toolDetail),
    outcome,
    choice: text(option?.label || choice),
    status: outcome === "rejected" || outcome === "expired" ? "failed" : "completed",
    // A decision sits where it was asked, not where its answer was recorded.
    order: record.order,
  };
}

/// Splits a turn's assistant text into narration and the final answer. The
/// answer is the text after the last step; text before a later step is
/// narration and belongs to the work trail.
function finishTurn(turn) {
  const lastStep = turn.steps.reduce((latest, step) => Math.max(latest, step.order || 0), 0);
  const answer = turn.messages.filter(message => message.order > lastStep && message.text.trim());
  const narration = turn.messages.filter(message => message.order <= lastStep && message.text.trim());
  turn.answer = answer.map(message => message.text).join("\n\n");
  turn.answerComplete = answer.length > 0 && answer.every(message => message.complete);
  turn.narration = narration;
  turn.files = filesChanged(turn.steps);
  turn.summary = summarizeSteps(turn.steps);
}

function projectPlan(payload) {
  const items = Array.isArray(payload.items) ? payload.items : [];
  const entries = items.map(item => ({
    title: text(item?.title || item?.label),
    state: text(item?.state || "pending"),
  })).filter(item => item.title);
  const done = entries.filter(item => item.state === "completed").length;
  const current = entries.find(item => item.state === "in_progress") || entries.find(item => item.state === "pending") || null;
  return { entries, done, total: entries.length, current: current?.title || "" };
}

/// Totals the file changes a turn made, one row per file.
export function filesChanged(steps = []) {
  const files = new Map();
  for (const step of steps) {
    const diff = step.diff;
    if (!diff || step.status === "failed") continue;
    const name = text(diff.file || step.detail);
    if (!name) continue;
    const row = files.get(name) || { file: name, additions: 0, deletions: 0, diffs: [] };
    row.additions += Number(diff.additions) || 0;
    row.deletions += Number(diff.deletions) || 0;
    if (diff.diff) row.diffs.push(text(diff.diff));
    files.set(name, row);
  }
  return [...files.values()];
}

const SUMMARY_GROUPS = [
  { kinds: ["read"], one: "Read 1 file", many: n => `Read ${n} files`, unique: true },
  { kinds: ["edit", "write", "delete", "move"], one: "Edited 1 file", many: n => `Edited ${n} files`, unique: true },
  { kinds: ["ran"], one: "Ran 1 command", many: n => `Ran ${n} commands` },
  { kinds: ["grep", "glob", "search"], one: "Searched once", many: n => `Searched ${n} times` },
  { kinds: ["fetch"], one: "Fetched 1 page", many: n => `Fetched ${n} pages` },
];

/// One line for a turn's work: counts by kind of action, in a fixed order.
export function summarizeSteps(steps = []) {
  const tools = steps.filter(step => step.kind === "tool" && step.toolKind !== "think");
  const parts = [];
  const used = new Set();
  for (const group of SUMMARY_GROUPS) {
    const matching = tools.filter(step => group.kinds.includes(step.toolKind));
    matching.forEach(step => used.add(step));
    const count = group.unique ? new Set(matching.map(step => step.detail || step.id)).size : matching.length;
    if (count === 1) parts.push(group.one);
    else if (count > 1) parts.push(group.many(count));
  }
  const other = tools.filter(step => !used.has(step)).length;
  if (other === 1) parts.push("1 other step");
  else if (other > 1) parts.push(`${other} other steps`);
  const decisions = steps.filter(step => step.kind === "decision").length;
  if (decisions === 1) parts.push("1 decision");
  else if (decisions > 1) parts.push(`${decisions} decisions`);
  return parts.join(" · ");
}

const STEP_VERBS = {
  read: ["Reading", "Read"],
  edit: ["Editing", "Edited"],
  write: ["Writing", "Wrote"],
  delete: ["Deleting", "Deleted"],
  move: ["Moving", "Moved"],
  ran: ["Running", "Ran"],
  grep: ["Searching", "Searched"],
  glob: ["Listing", "Listed"],
  search: ["Searching", "Searched"],
  fetch: ["Fetching", "Fetched"],
  think: ["Thinking", "Thought"],
  mode: ["Switching mode", "Switched mode"],
};

/// The verb and target of one step, for example ["Ran", "git status"], with
/// paths under `root` (the Session's directory) shown relative to it.
export function stepLine(step, root = "") {
  if (step.kind === "decision") {
    const verb = step.outcome === "allowed" ? "Allowed" : step.outcome === "rejected" ? "Rejected" : "Expired";
    return [verb, displayTarget(step.detail || step.title, root)];
  }
  const verbs = STEP_VERBS[step.toolKind];
  const running = step.status === "pending" || step.status === "running";
  if (!verbs) return [step.title || "Tool", step.detail && step.detail !== step.title ? displayTarget(step.detail, root) : ""];
  return [running ? verbs[0] : verbs[1], displayTarget(step.detail || step.title, root)];
}

/// The text to show while an answer streams: hold back a trailing partial word
/// so the view grows in whole words rather than flickering per token.
export function visibleStreamingText(value, complete) {
  const source = text(value);
  if (complete) return source;
  const match = source.match(/^[\s\S]*[\s.,;:!?)\]}，。；：！？、]/);
  return match ? match[0] : "";
}

/// Splits a streaming answer into its finished top-level blocks and the open
/// tail, so a view can parse each finished block once and re-parse only the
/// tail as tokens arrive. A block ends at a blank line outside a code fence
/// before an unindented line that is not a list item; anything that could
/// reach across that line (an indented continuation, a list, a link
/// definition, raw HTML) keeps the blocks together. Joined, the parts are
/// the source.
export function streamingMarkdownBlocks(source) {
  const value = text(source);
  if (/^ {0,3}(\[[^\]]+\]:|<)/m.test(value)) return [value];
  const lines = value.split("\n");
  const blocks = [];
  let start = 0;
  let fence = null;
  let afterBlank = false;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (fence) {
      const close = line.match(/^ {0,3}(`{3,}|~{3,})\s*$/);
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null;
      afterBlank = false;
      continue;
    }
    if (afterBlank && index > start && /^[^\s]/.test(line) && !/^([*+-]|\d{1,9}[.)])(\s|$)/.test(line)) {
      blocks.push(lines.slice(start, index).join("\n"));
      start = index;
    }
    const open = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (open) fence = open[1];
    afterBlank = line.trim() === "";
  }
  blocks.push(lines.slice(start).join("\n"));
  return blocks.map((block, index) => (index < blocks.length - 1 ? `${block}\n` : block));
}

/// Elapsed time in the compact form the status line uses.
export function formatElapsed(milliseconds) {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  if (minutes < 60) return rest ? `${minutes}m ${rest}s` : `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ${minutes % 60}m`;
}

/// Orders permission options for the decision dock: allow before reject, once
/// before always. The Host already orders them; this keeps older rows right.
export function orderDecisionOptions(options = []) {
  const rank = { allow_once: 0, allow_always: 1, reject_once: 2, reject_always: 3 };
  return [...options].sort((left, right) => (rank[left.kind] ?? 4) - (rank[right.kind] ?? 4));
}

/// True for a Session driven over the Agent Client Protocol: it has no
/// terminal, so the Conversation surface is its only surface.
export function isACPSession(session) {
  return String(session?.runtimeKind || "").toLowerCase() === "acp"
    || String(session?.agentHandler || "").toLowerCase() === "acp";
}

/// Providers that ship an ACP server (RFC 0023 §5.3).
export const acpProviders = new Set(["claude", "codex", "opencode"]);
