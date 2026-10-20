// One Agent status as the thing a row actually draws.
//
// This mirrors `WarrenActivityMark` in `Packages/DesignSystem`, which both
// native clients read. The encoding rule it enforces: motion says whether work
// is progressing and color says what a state asks of a person. A mark that only
// reports progress takes the working hue and pulses; a mark that wants someone
// takes the attention hue and holds still.
//
// The rule answers a measured collision. Both halves of an Agent status used to
// be folded into one hue ramp, but their orderings are nearly opposite: the
// lifecycle's most common value is `ready` — an idle Agent, which needs nothing
// — while the rarest attention payload is the one that needs an answer now.

/// Priority order, lowest first, so a rollup is a max over this list.
///
/// It matches `DESIGN.md` §8.2 — `failed > attention/blocked > working > ready >
/// exited` — with the attention tier split by what is being asked.
export const ACTIVITY_MARKS = [
  "exited",
  "ready",
  "working",
  // A `blocked` lifecycle with no attention payload to explain it. The live Host
  // always sends the two together, because `blocked` is only ever set by marking
  // attention; this covers the snapshot that arrives without one. It is
  // deliberately not folded into `inputNeeded`, because naming a request Warren
  // cannot see would put a wrong word on the row.
  "attentionUnspecified",
  "inputNeeded",
  "approvalNeeded",
  "failed",
];

const MARK_PRIORITY = Object.fromEntries(ACTIVITY_MARKS.map((mark, index) => [mark, index]));

/// How loudly a mark reads, and therefore which channel carries it.
///
/// `live` is the only tier that moves, and `actionable` is the only tier that
/// takes the attention hue.
export const ACTIVITY_MARK_TIER = {
  exited: "idle",
  ready: "idle",
  working: "live",
  attentionUnspecified: "actionable",
  inputNeeded: "actionable",
  approvalNeeded: "actionable",
  failed: "actionable",
};

/// The short state word a row shows.
const MARK_WORD = {
  approvalNeeded: "Approval needed",
  inputNeeded: "Input needed",
  attentionUnspecified: "Needs attention",
  failed: "Failed",
  working: "Working",
  // "Done", not "Idle": this mark is drawn only while it is news, and the news is
  // that a turn finished. Calling it Idle described a state rather than the event
  // that put it on screen.
  ready: "Done",
  exited: "Exited",
};

/// The label assistive technology and the tooltip receive. Unlike the word it
/// names its subject, because it is read without the row's surrounding context.
const MARK_LABEL = {
  approvalNeeded: "Agent needs approval",
  inputNeeded: "Agent needs input",
  attentionUnspecified: "Session needs attention",
  failed: "Session failed",
  working: "Agent working",
  ready: "Agent finished",
  exited: "Session exited",
};

/// The lifecycle value a mark reduces to.
///
/// Lossy on purpose: all three attention marks reduce to `blocked`, which is the
/// lifecycle the Host reports alongside every attention payload.
const MARK_LIFECYCLE = {
  approvalNeeded: "blocked",
  inputNeeded: "blocked",
  attentionUnspecified: "blocked",
  failed: "failed",
  working: "working",
  ready: "ready",
  exited: "exited",
};

const LIFECYCLES = new Set(["working", "blocked", "failed", "ready", "exited"]);

/// Folds a Host status into the mark to draw, or `null` for a Session with no
/// Agent bound: a plain shell reports no activity Warren can observe, and
/// inventing a mark for it would claim knowledge of a process the Host does not
/// track.
///
/// An attention payload outranks the lifecycle value it arrives with, so a stale
/// `ready` or `working` snapshot still reads as actionable until the Host clears
/// the request. A `failed` lifecycle outranks attention, because a turn that
/// already ended badly is the more specific fact.
export function resolveActivityMark(status, acknowledgedLifecycle = null) {
  const mark = resolveIgnoringAcknowledgment(status);
  // A completion notice is news once. Every idle Agent reports `ready`, so
  // without this the loudest thing in the tree is the one state that needs
  // nothing.
  if (
    mark &&
    activityMarkIsAcknowledgeable(mark) &&
    acknowledgedLifecycle === activityMarkLifecycle(mark)
  ) {
    return null;
  }
  return mark;
}

function resolveIgnoringAcknowledgment(status) {
  if (!status) return null;
  const lifecycle = String(status.activity || "").toLowerCase();
  if (lifecycle === "failed") return "failed";
  const kind = status.attention ? String(status.attention.kind || "").toLowerCase() : "";
  if (kind === "approval") return "approvalNeeded";
  if (kind === "input") return "inputNeeded";
  // An attention payload whose kind the Host did not name still needs a person.
  if (status.attention) return "attentionUnspecified";
  if (lifecycle === "blocked") return "attentionUnspecified";
  return LIFECYCLES.has(lifecycle) ? lifecycle : null;
}

export function activityMarkPriority(mark) {
  // One above the list index, so a Session with no mark at all stays below
  // `exited` rather than tying with it.
  return mark ? MARK_PRIORITY[mark] + 1 : 0;
}

export function activityMarkTier(mark) {
  return mark ? ACTIVITY_MARK_TIER[mark] : null;
}

export function activityMarkWord(mark) {
  return mark ? MARK_WORD[mark] || null : null;
}

export function activityMarkLabel(mark) {
  return mark ? MARK_LABEL[mark] || null : null;
}

export function activityMarkLifecycle(mark) {
  return mark ? MARK_LIFECYCLE[mark] || null : null;
}

/// Motion means one thing: work is progressing. `blocked` used to pulse as well,
/// which left the pulse carrying no information — it marked "not ready, failed,
/// or exited" rather than any single fact — and left a halted Session animating
/// indefinitely while it waited for a person.
export function activityMarkIsAnimated(mark) {
  return activityMarkTier(mark) === "live";
}

/// Whether reading the Session retires this mark.
///
/// `ready` is news exactly once — a turn just finished — and stops being news
/// once the person has seen it, so it is acknowledgeable. `exited` is the
/// opposite kind of fact: a Session that ended stays ended, so it is never news.
/// A request is not acknowledgeable either, because glancing at a row does not
/// answer it.
export function activityMarkIsAcknowledgeable(mark) {
  return mark === "ready";
}

/// Whether the mark is worth a dot at all.
///
/// An ended Session is a permanent state rather than an event, so it draws
/// nothing. Every Session that ever ended would otherwise carry a grey dot
/// forever, which is exactly the background noise this encoding removes.
export function activityMarkIsDrawn(mark) {
  return mark !== "exited";
}

/// The mark a row draws: acknowledgment applied, and nothing for a mark that is
/// never worth a dot.
export function resolveDrawnActivityMark(status, acknowledgedLifecycle = null) {
  const mark = resolveActivityMark(status, acknowledgedLifecycle);
  return mark && activityMarkIsDrawn(mark) ? mark : null;
}

// Acknowledgments are what this person has already seen, per Session, on this
// device: a plain `{ [sessionID]: lifecycle }` record. It mirrors
// `WarrenDesktopActivityAcknowledgments` (DESIGN.md §8.2.6). It is device-local
// on purpose — which completions this screen showed is not something the Host
// or another client can know — and it never expires by time, only by the Agent
// moving past the lifecycle that was read.

function statusLifecycle(status) {
  const lifecycle = String(status?.activity || "").toLowerCase();
  return LIFECYCLES.has(lifecycle) ? lifecycle : null;
}

/// Records that this person has seen the Session in its current state.
///
/// Only an acknowledgeable mark is recorded: looking at a pending approval does
/// not answer it, and a failure does not un-fail because it was visited.
/// Returns the same record when nothing changed, so a caller can skip a render.
export function acknowledgeActivity(acknowledgments, sessionID, status) {
  if (!sessionID) return acknowledgments;
  const mark = resolveActivityMark(status);
  if (!mark || !activityMarkIsAcknowledgeable(mark)) return acknowledgments;
  const lifecycle = activityMarkLifecycle(mark);
  if (acknowledgments[sessionID] === lifecycle) return acknowledgments;
  return { ...acknowledgments, [sessionID]: lifecycle };
}

/// Drops acknowledgments the Host has moved past, so `ready → (seen) → working
/// → ready` lights up again, and — when `prune` is set because the roster is
/// authoritative — forgets Sessions the Host no longer lists.
///
/// `sessions` is any iterable of `{ id, agentStatus }`. Returns the same record
/// when nothing changed.
export function reconcileActivityAcknowledgments(acknowledgments, sessions, { prune = true } = {}) {
  const lifecycles = new Map();
  for (const session of sessions) lifecycles.set(session.id, statusLifecycle(session.agentStatus));
  let changed = false;
  const next = {};
  for (const [sessionID, lifecycle] of Object.entries(acknowledgments)) {
    const listed = lifecycles.has(sessionID);
    if ((listed && lifecycles.get(sessionID) !== lifecycle) || (!listed && prune)) {
      changed = true;
      continue;
    }
    next[sessionID] = lifecycle;
  }
  return changed ? next : acknowledgments;
}

function activityAcknowledgmentsKey(endpointIdentity) {
  // Scoped per endpoint, like the Desktop store, because Session IDs belong to
  // one Host.
  return `warren.activity-acknowledgments.${encodeURIComponent(String(endpointIdentity || ""))}`;
}

export function loadActivityAcknowledgments(storage, endpointIdentity) {
  try {
    const parsed = JSON.parse(storage?.getItem(activityAcknowledgmentsKey(endpointIdentity)) || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return Object.fromEntries(
      Object.entries(parsed).filter(([, lifecycle]) => LIFECYCLES.has(lifecycle)),
    );
  } catch {
    return {};
  }
}

export function saveActivityAcknowledgments(storage, endpointIdentity, acknowledgments) {
  const key = activityAcknowledgmentsKey(endpointIdentity);
  try {
    if (!Object.keys(acknowledgments || {}).length) storage?.removeItem(key);
    else storage?.setItem(key, JSON.stringify(acknowledgments));
  } catch {
    // Best effort: restricted contexts can reject writes, and the record is a
    // convenience rather than state the Host depends on.
  }
}
