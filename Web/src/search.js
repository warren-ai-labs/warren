/**
 * Search semantics shared with the Swift clients.
 *
 * This is a port of `WarrenDomain.WarrenSearchIndex`: the same role weights, the
 * same match tiers, the same query grammar, and the same rule for what a row
 * shows as its reason for matching. A query typed in the browser must rank its
 * results the way the Desktop and iOS clients rank theirs, so the numbers here
 * are not free to drift.
 */

import { resolvedCommand, terminalTabTitle } from "./title.js";

/** Where a matched value came from. The value is its ranking weight. */
export const fieldRole = {
  title: 500,
  alias: 350,
  context: 180,
  path: 80,
  kind: 20,
};

const tier = {
  exact: 400,
  prefix: 300,
  wordPrefix: 220,
  substring: 100,
  subsequence: 40,
  /** Below three characters nearly everything matches something. */
  minimumSubsequenceLength: 3,
};

/** Grouping order. Tasks and Sessions lead because work is resumed there. */
const scopeOrder = {
  task: 0,
  session: 1,
  workspace: 2,
  project: 3,
  terminalGroup: 4,
  tab: 5,
};

const scopeLabels = {
  task: "Task",
  session: "Session",
  workspace: "Workspace",
  project: "Project",
  terminalGroup: "Terminal Group",
  tab: "Tab",
};

/** Query prefixes that narrow to one scope, e.g. `w:review`. */
const scopeKeywords = {
  t: "task",
  task: "task",
  s: "session",
  session: "session",
  w: "workspace",
  workspace: "workspace",
  branch: "workspace",
  p: "project",
  project: "project",
  g: "terminalGroup",
  group: "terminalGroup",
  tab: "tab",
};

export function scopeLabel(scope) {
  return scopeLabels[scope] || scope;
}

/**
 * Folds a value for matching: trimmed, lowercased, and diacritic-insensitive.
 * The matcher and the highlighter both read this so they can never disagree
 * about which characters were involved.
 */
export function normalize(value) {
  return String(value ?? "")
    .trim()
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase();
}

function isWordCharacter(character) {
  return /[\p{L}\p{N}]/u.test(character);
}

/**
 * The trimmed display text alongside its folded form, plus whether the two align
 * character for character. Alignment lets a match range map straight back onto
 * the text the row displays; folding away a diacritic breaks it.
 */
function foldField(value) {
  const text = String(value ?? "").trim();
  const folded = normalize(text);
  return { text, folded, aligned: folded.length === text.length };
}

function wordStarts(folded) {
  const starts = [];
  for (let index = 0; index < folded.length; index += 1) {
    const isWord = isWordCharacter(folded[index]);
    if (isWord && (index === 0 || !isWordCharacter(folded[index - 1]))) starts.push(index);
  }
  return starts;
}

/**
 * Splits a raw query into free text plus the narrowing the user typed.
 *
 * Unknown prefixes stay literal text, so searching `http://host` is not silently
 * filtered down to nothing.
 */
export function parseQuery(raw) {
  const tokens = [];
  const scopes = new Set();
  const statuses = new Set();
  const folded = normalize(raw);
  for (const token of folded.split(/\s+/)) {
    if (!token) continue;
    if (token.startsWith("@") && token.length > 1) {
      statuses.add(token.slice(1));
      continue;
    }
    const separator = token.indexOf(":");
    if (separator > 0) {
      const scope = scopeKeywords[token.slice(0, separator)];
      if (scope) {
        scopes.add(scope);
        const remainder = token.slice(separator + 1);
        if (remainder) tokens.push(remainder);
        continue;
      }
    }
    tokens.push(token);
  }
  const hasFilter = scopes.size > 0 || statuses.size > 0;
  return {
    tokens,
    phrase: tokens.join(" "),
    scopes,
    statuses,
    isEmpty: tokens.length === 0 && !hasFilter,
    isFilterOnly: tokens.length === 0 && hasFilter,
  };
}

/**
 * Pre-normalizes every searchable resource once.
 *
 * A descriptor is `{ key, scope, title, subtitle, path, aliases, context, kinds }`
 * in plain strings; the index owns all folding and duplicate collapsing so the
 * three clients cannot drift on what counts as a word.
 */
export function buildIndex(descriptors = []) {
  const entries = [];
  for (const descriptor of descriptors) {
    const title = String(descriptor.title ?? "").trim();
    if (!title) continue;
    const fields = [];
    const characters = new Set();
    const seen = new Set();
    const append = (value, role) => {
      const { text, folded, aligned } = foldField(value);
      // Duplicate facets are common: a workspace whose name equals its branch, a
      // session whose title equals its command. Keeping both would double the
      // match work and double-count the score.
      if (!folded || seen.has(folded)) return;
      seen.add(folded);
      for (const character of folded) characters.add(character);
      fields.push({ role, text, folded, aligned, words: wordStarts(folded) });
    };
    append(title, fieldRole.title);
    for (const alias of descriptor.aliases || []) append(alias, fieldRole.alias);
    for (const value of descriptor.context || []) append(value, fieldRole.context);
    if (descriptor.path) append(descriptor.path, fieldRole.path);
    for (const kind of descriptor.kinds || []) append(kind, fieldRole.kind);
    append(scopeLabel(descriptor.scope), fieldRole.kind);
    entries.push({
      key: descriptor.key,
      scope: descriptor.scope,
      title,
      subtitle: String(descriptor.subtitle ?? "").trim(),
      fields,
      characters,
      ordinal: entries.length,
    });
  }
  return { entries };
}

/**
 * Matches an abbreviation like `wdc` against `warren-desktop-command`.
 *
 * Every matched character must either continue the previous one or start a word.
 * A plain subsequence scan lets `wnd` match `warren desktop` through the middle
 * of a word, and then almost every long path matches almost every short token.
 */
function subsequenceScore(token, field, weight) {
  if (token.length < tier.minimumSubsequenceLength) return 0;
  const { folded } = field;
  let matched = 0;
  let runs = 0;
  let previous = -2;
  for (let index = 0; index < folded.length && matched < token.length; index += 1) {
    if (folded[index] !== token[matched]) continue;
    const continues = index === previous + 1;
    const startsWord = index === 0 || !isWordCharacter(folded[index - 1]);
    if (!continues && !startsWord) continue;
    if (!continues) runs += 1;
    previous = index;
    matched += 1;
  }
  if (matched !== token.length) return 0;
  return weight + tier.subsequence + Math.max(0, 60 - (runs - 1) * 15);
}

/**
 * Scores one token against one field, returning the best tier it reaches.
 * Tiers are tested in descending value and the first hit wins.
 */
function fieldScore(token, field) {
  const { folded, words } = field;
  if (token.length > folded.length) return 0;
  const weight = field.role;
  if (folded.startsWith(token)) {
    return weight + (token.length === folded.length ? tier.exact : tier.prefix);
  }
  for (const start of words) {
    if (start !== 0 && folded.startsWith(token, start)) return weight + tier.wordPrefix;
  }
  if (folded.includes(token)) return weight + tier.substring;
  return subsequenceScore(token, field, weight);
}

/**
 * Locates each token inside one already-folded field.
 *
 * The index folded this text at build time, so this is a scan rather than
 * another normalization pass — the difference lands on keystroke latency.
 */
function matchRanges(field, tokens) {
  if (!field || !tokens.length) return [];
  // Folding away a diacritic loses the one-to-one mapping, so offsets from the
  // folded form cannot be trusted; fall back to the display text.
  if (!field.aligned) return highlightRanges(field.text, tokens);
  const ranges = [];
  for (const token of tokens) {
    const start = field.folded.indexOf(token);
    if (start >= 0) ranges.push([start, start + token.length]);
  }
  return mergeRanges(ranges);
}

/**
 * The row's reason for being here. A title match returns nothing: the title is
 * already the loudest thing in the row, so repeating it wastes the space a
 * compact result has for new information.
 */
function evidenceFor(field, tokens) {
  if (!field || field.role === fieldRole.title) return null;
  return { role: field.role, text: field.text, ranges: matchRanges(field, tokens) };
}

function comparePrecedence(left, right) {
  if (left.score !== right.score) return right.score - left.score;
  const leftOrder = scopeOrder[left.entry.scope] ?? 99;
  const rightOrder = scopeOrder[right.entry.scope] ?? 99;
  if (leftOrder !== rightOrder) return leftOrder - rightOrder;
  const byTitle = left.entry.title.localeCompare(right.entry.title, undefined, {
    numeric: true,
    sensitivity: "base",
  });
  if (byTitle !== 0) return byTitle;
  return left.entry.ordinal - right.entry.ordinal;
}

/**
 * Ranks the index against a parsed query.
 *
 * `boost` and `accepts` are read here rather than baked into the index so live
 * agent status can reorder and filter results without a rebuild.
 */
export function searchIndex(index, query, options = {}) {
  const { limit = 60, boost = () => 0, accepts = () => true } = options;
  if (limit <= 0 || query.isEmpty || !index.entries.length) return [];

  const candidates = [];
  const scoped = query.scopes.size > 0;
  for (const entry of index.entries) {
    if (scoped && !query.scopes.has(entry.scope)) continue;
    if (!accepts(entry.key)) continue;

    if (query.isFilterOnly) {
      candidates.push({ entry, score: boost(entry.key), field: null });
      continue;
    }
    if (!query.tokens.every(token => coversToken(entry, token))) continue;

    let total = 0;
    let best = -1;
    let bestField = null;
    let lastScore = 0;
    let matchedEvery = true;
    for (const token of query.tokens) {
      let tokenBest = 0;
      let tokenField = null;
      for (const field of entry.fields) {
        const score = fieldScore(token, field);
        if (score > tokenBest) {
          tokenBest = score;
          tokenField = field;
        }
      }
      if (!tokenBest) {
        matchedEvery = false;
        break;
      }
      total += tokenBest;
      lastScore = tokenBest;
      if (tokenBest > best) {
        best = tokenBest;
        bestField = tokenField;
      }
    }
    if (!matchedEvery) continue;

    // A multi-token query also scores the contiguous phrase, so tokens scattered
    // across unrelated metadata lose to the row that contains the whole thing.
    if (query.tokens.length > 1) {
      let phraseBest = 0;
      for (const field of entry.fields) {
        phraseBest = Math.max(phraseBest, fieldScore(query.phrase, field));
      }
      total += phraseBest;
    } else {
      total += lastScore;
    }
    candidates.push({ entry, score: total + boost(entry.key), field: bestField });
  }
  return finish(candidates, limit, query);
}

/**
 * Every match tier needs each of a token's characters to appear somewhere in the
 * entry, so this rejects an entry before any field is scanned.
 */
function coversToken(entry, token) {
  for (const character of token) {
    if (!entry.characters.has(character)) return false;
  }
  return true;
}

/**
 * Resources worth offering before anything is typed: only those the live state
 * has singled out. Listing the whole resource tree would just be a second,
 * unranked sidebar.
 */
export function suggestFromIndex(index, options = {}) {
  const { limit = 8, boost = () => 0, accepts = () => true } = options;
  if (limit <= 0) return [];
  const candidates = [];
  for (const entry of index.entries) {
    const score = boost(entry.key);
    if (score <= 0 || !accepts(entry.key)) continue;
    candidates.push({ entry, score, field: null });
  }
  return finish(candidates, limit, parseQuery(""));
}

/** Sorts, collapses rows a user cannot tell apart, and attaches explanations. */
function finish(candidates, limit, query) {
  candidates.sort(comparePrecedence);
  const seenKeys = new Set();
  const seenRows = new Set();
  const results = [];
  for (const candidate of candidates) {
    const { entry } = candidate;
    if (seenKeys.has(entry.key)) continue;
    seenKeys.add(entry.key);
    // Two rows with the same title, ancestry, and kind read as one duplicated
    // row no matter which resource each points at.
    const row = `${entry.title}${entry.subtitle}${entry.scope}`;
    if (seenRows.has(row)) continue;
    seenRows.add(row);
    results.push({
      key: entry.key,
      scope: entry.scope,
      title: entry.title,
      // Resolved here, where the title is already folded, so a view never
      // normalizes a string per row per frame.
      titleRanges: matchRanges(entry.fields[0], query.tokens),
      subtitle: entry.subtitle,
      evidence: evidenceFor(candidate.field, query.tokens),
      score: candidate.score,
    });
    if (results.length >= limit) break;
  }
  return results;
}

export function mergeRanges(ranges) {
  if (ranges.length < 2) return ranges;
  const sorted = [...ranges].sort((left, right) => left[0] - right[0]);
  const merged = [sorted[0]];
  for (const range of sorted.slice(1)) {
    const last = merged[merged.length - 1];
    if (range[0] <= last[1]) last[1] = Math.max(last[1], range[1]);
    else merged.push(range);
  }
  return merged;
}

/**
 * Locates each token inside arbitrary display text. Used for the row title, which
 * the index reports no evidence for: it is always visible, so it is highlighted
 * directly rather than carried through the result.
 */
export function highlightRanges(text, tokens) {
  const { folded, aligned } = foldField(text);
  if (!aligned || !folded) return [];
  const ranges = [];
  for (const token of tokens) {
    if (!token) continue;
    const start = folded.indexOf(token);
    if (start >= 0) ranges.push([start, start + token.length]);
  }
  return mergeRanges(ranges);
}

/**
 * Ranking weight for live state. Blocked work is what a user opens search to
 * find, so it leads; a pin is an explicit signal that stacks on top.
 */
export function activityBoost(activity, pinned) {
  const base = {
    blocked: 70,
    stalled: 65,
    failed: 60,
    working: 50,
    ready: 20,
  }[activity] || 0;
  return base + (pinned ? 30 : 0);
}

function dominantActivity(left, right) {
  return activityBoost(right, false) > activityBoost(left, false) ? right : left;
}

/** Provider aliases the Host may report, mapped to Warren's icon names. */
const providerAliases = {
  claude: "claude",
  "claude-code": "claude",
  codex: "codex",
  antigravity: "antigravity",
  agy: "antigravity",
  opencode: "opencode",
  "open-code": "opencode",
  pi: "pi",
  qoder: "qoder",
  trae: "trae",
  "trae-cli": "trae",
  shell: "shell",
};

/**
 * The Agent family whose mark names this Session.
 *
 * The binding wins over the durable kind, so a shell the Host has promoted to
 * Claude Code reads as Claude — the row names what is running, not what Warren
 * launched. This mirrors `sessionProviderID` on iOS and `presentedKind` on the
 * Desktop; a plain shell resolves to the shell mark rather than to nothing.
 */
export function sessionProvider(session = {}) {
  const kind = normalize(session.kind);
  const bound = normalize(session.agentProvider);
  if (bound && bound !== "shell" && bound !== "custom" && providerAliases[bound]) {
    return providerAliases[bound];
  }
  if (kind && kind !== "shell" && kind !== "custom" && providerAliases[kind]) {
    return providerAliases[kind];
  }
  // A promoted shell whose binding the Host has not reported can still be
  // recognized from the handler it runs under or the command it launched.
  const handler = normalize(session.agentHandler);
  for (const known of Object.keys(providerAliases)) {
    if (known !== "shell" && handler.includes(known)) return providerAliases[known];
  }
  const command = normalize(session.commandLine || session.command).split(/\s+/)[0] || "";
  const executable = command.split("/").pop();
  if (executable && providerAliases[executable] && executable !== "shell") {
    return providerAliases[executable];
  }
  return "shell";
}

function abbreviateHome(path) {
  const value = String(path || "");
  const match = value.match(/^\/(?:Users|home)\/[^/]+(\/.*)?$/);
  return match ? `~${match[1] || ""}` : value;
}

function basename(path) {
  return String(path || "").split("/").filter(Boolean).pop() || "";
}

/**
 * Builds the searchable set from a catalog.
 *
 * Only what the web client renders is indexed. The catalog already drops ended
 * Sessions at the wire boundary, so a result can never point at something the
 * client cannot open. Tasks are absent because the web client shows none.
 */
export function searchDescriptors(catalog) {
  const descriptors = [];
  const targets = new Map();
  const activities = new Map();
  const providers = new Map();
  const pinned = new Set();
  const workspaceActivities = new Map();

  const projectsByID = catalog.projectsByID || new Map();
  const workspacesByID = new Map(
    (catalog.workspaces || []).map(workspace => [workspace.id, workspace]),
  );

  const clean = values => (values || [])
    .map(value => String(value || "").trim())
    .filter(Boolean);

  const add = ({ key, target, activity, pinned: isPinned, provider, ...descriptor }) => {
    descriptors.push({
      ...descriptor,
      key,
      aliases: clean(descriptor.aliases),
      context: clean(descriptor.context),
      kinds: clean(descriptor.kinds),
    });
    targets.set(key, target);
    if (activity) activities.set(key, activity);
    if (isPinned) pinned.add(key);
    if (provider) providers.set(key, provider);
  };

  for (const tab of catalog.tabs || []) {
    // The wire boundary already drops ended Sessions, but the rule is restated
    // here so a result can never point at something the client cannot open,
    // whatever built the catalog.
    if (!tab.session || (tab.lifecycle && tab.lifecycle !== "running")) continue;
    const workspace = workspacesByID.get(tab.workspace);
    const project = workspace ? projectsByID.get(workspace.project) : null;
    const activity = tab.agentStatus?.activity || "";
    if (workspace) {
      workspaceActivities.set(
        workspace.id,
        dominantActivity(workspaceActivities.get(workspace.id) || "", activity),
      );
    }
    const branch = workspace?.branch || workspace?.name || "";
    const context = project && workspace ? `${project.name} › ${branch}` : "";
    add({
      key: `session.${tab.session}`,
      target: { kind: "session", id: tab.session, workspace: tab.workspace },
      scope: "session",
      title: terminalTabTitle(tab, workspace || {}),
      subtitle: context,
      path: tab.directory ? abbreviateHome(tab.directory) : null,
      aliases: [
        tab.customTitle,
        searchableSessionTitle(tab),
        resolvedCommand(tab),
        tab.commandLine,
        basename(tab.directory),
      ],
      context: [context, project?.name, workspace?.name, workspace?.branch],
      kinds: [tab.kind],
      provider: sessionProvider(tab),
      activity,
      pinned: Boolean(tab.pinned),
    });
  }

  for (const project of catalog.projects || []) {
    add({
      key: `project.${project.id}`,
      target: { kind: "project", id: project.id },
      scope: "project",
      title: project.name,
      subtitle: abbreviateHome(project.path),
      path: abbreviateHome(project.path),
      aliases: [basename(project.path)],
      pinned: Boolean(project.pinned),
    });
  }

  for (const workspace of catalog.workspaces || []) {
    const project = projectsByID.get(workspace.project);
    const title = workspace.branch || workspace.name || "Workspace";
    const projectName = project?.name || "";
    const subtitle = title.toLowerCase() === String(workspace.name || "").toLowerCase()
      ? projectName
      : [projectName, workspace.name].filter(Boolean).join(" › ");
    add({
      key: `workspace.${workspace.id}`,
      target: { kind: "workspace", id: workspace.id },
      scope: "workspace",
      title,
      subtitle,
      path: abbreviateHome(workspace.path),
      aliases: [workspace.name, workspace.branch, basename(workspace.path)],
      context: [projectName, workspace.name, workspace.branch],
      activity: workspaceActivities.get(workspace.id) || "",
      pinned: Boolean(workspace.pinned),
    });
  }

  return { descriptors, targets, activities, providers, pinned };
}

/**
 * The Host fixes a Session's title at creation from its kind, so an unnamed
 * shell carries the literal word "Shell". Indexing that would make every unnamed
 * session match "shell" and would offer the word back as the reason it matched,
 * which explains nothing.
 */
function searchableSessionTitle(session) {
  const title = String(session.title || "").trim();
  if (!title) return "";
  const kind = String(session.kind || "").trim();
  return normalize(title) === normalize(kind) ? "" : title;
}

/**
 * One ready-to-render search surface over a catalog: the index, the live state
 * it ranks by, and the navigation target behind each row.
 */
export function createSearch(catalog) {
  const { descriptors, targets, activities, providers, pinned } = searchDescriptors(catalog);
  const index = buildIndex(descriptors);
  const boost = key => activityBoost(activities.get(key) || "", pinned.has(key));
  const accepts = (key, statuses) => {
    if (!statuses.size) return true;
    if (statuses.has(activities.get(key) || " ")) return true;
    return statuses.has("pinned") && pinned.has(key);
  };
  const decorate = results => results.map(result => ({
    ...result,
    target: targets.get(result.key),
    activity: activities.get(result.key) || "",
    provider: providers.get(result.key) || "",
    pinned: pinned.has(result.key),
  }));
  return {
    size: index.entries.length,
    results(raw, limit = 40) {
      const query = parseQuery(raw);
      if (query.isEmpty) return decorate(suggestFromIndex(index, { limit: 8, boost }));
      return decorate(searchIndex(index, query, {
        limit,
        boost,
        accepts: key => accepts(key, query.statuses),
      }));
    },
  };
}

/** Splits display text into `{ text, isMatch }` runs for rendering. */
export function highlightSegments(text, ranges) {
  const value = String(text ?? "");
  if (!value) return [];
  if (!ranges || !ranges.length) return [{ text: value, isMatch: false }];
  const segments = [];
  let cursor = 0;
  for (const [start, end] of mergeRanges(ranges)) {
    if (start < cursor || end > value.length) continue;
    if (start > cursor) segments.push({ text: value.slice(cursor, start), isMatch: false });
    segments.push({ text: value.slice(start, end), isMatch: true });
    cursor = end;
  }
  if (cursor < value.length) segments.push({ text: value.slice(cursor), isMatch: false });
  return segments.length ? segments : [{ text: value, isMatch: false }];
}
