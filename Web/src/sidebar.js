import {
  activityMarkTier,
  activityMarkWord,
  resolveActivityMark,
} from "./activity.js";
import { resolvedCommand } from "./title.js";

// The sidebar reads like the Desktop's: a Project, its Workspaces, and under
// each Workspace the Sessions running there on two lines. These helpers decide
// what those lines say; the component only lays them out.

const attentionReasonWords = {
  question: "Question",
  permission: "Permission",
  approval: "Permission",
};

/// The second line of a Session row, and the tone it is drawn in.
///
/// A request for a person comes first and is drawn in the attention tone, since
/// it is the one thing on the line worth acting on. A finished or failed turn
/// says so. Otherwise the line names what the terminal is running, and a plain
/// idle shell leaves it empty rather than restating "Shell".
///
/// Acknowledgments are ignored on purpose: reading a Session retires its dot,
/// not the fact the line states, so a row never collapses under the pointer
/// that just selected it.
export function sessionRowSummary(session = {}) {
  const mark = resolveActivityMark(session.agentStatus);
  const tier = activityMarkTier(mark);
  if (tier === "actionable") {
    const word = activityMarkWord(mark) || "Needs attention";
    const reason = String(session.agentStatus?.attention?.reason || "").trim().toLowerCase();
    const detail = attentionReasonWords[reason];
    return { tone: mark === "failed" ? "danger" : "attention", text: detail && detail !== word ? `${word} · ${detail}` : word };
  }
  // An Agent's command is its own name, which the row's icon and title already
  // carry; only a shell's command adds anything.
  const resolved = resolvedCommand(session);
  const command = resolved.toLowerCase() === String(session.kind || "").toLowerCase() ? "" : resolved;
  if (tier === "live") return { tone: "live", text: command ? `Working · ${command}` : "Working" };
  // A resting Agent says what its turn accomplished when the Host could ask a
  // model for a sentence. That is the line the Desktop draws, and it is worth
  // more than restating the state the dot already carries.
  const accomplished = String(session.resultSentence || "").trim();
  if (accomplished) return { tone: "plain", text: accomplished };
  if (mark === "ready") return { tone: "plain", text: command ? `Done · ${command}` : "Done" };
  return { tone: "plain", text: command };
}

/// Splits a Project's Workspaces into the ones the sidebar always shows and the
/// idle ones it folds behind "N idle worktrees".
///
/// The first Workspace is the Project's main checkout and always shows, as does
/// the selected one and any with a Session; a worktree with nothing running is
/// noise until asked for.
export function partitionWorkspaces(workspaces = [], sessionCount = () => 0, activeWorkspaceID = null) {
  const shown = [];
  const idle = [];
  workspaces.forEach((workspace, index) => {
    if (index === 0 || workspace.id === activeWorkspaceID || sessionCount(workspace.id) > 0) {
      shown.push(workspace);
    } else {
      idle.push(workspace);
    }
  });
  return { shown, idle };
}

/// A Project's Workspaces split the way the Desktop splits them, and the
/// Projects themselves in three bands: pinned, active, and everything else.
///
/// A Project is active while one of its Workspaces holds a Session, or while it
/// is the one on screen: a row someone is looking at is never folded away.
/// Active Projects keep the Host's own order (`activeSince`) so rows do not
/// move while they are read; the rest are ordered by when they last had
/// activity, newest first, and drawn behind one folded row.
export function projectBands(projects = [], { isActive = () => false, lastActiveAt = () => null } = {}) {
  const pinned = [];
  const active = [];
  const inactive = [];
  projects.forEach((project, offset) => {
    if (project.pinned) pinned.push({ project, offset });
    else if (isActive(project)) active.push({ project, offset });
    else inactive.push({ project, offset, last: lastActiveAt(project) });
  });
  const stamp = entry => {
    const value = entry.project.activeSince;
    const time = value ? Date.parse(value) : NaN;
    return Number.isFinite(time) ? time : Number.POSITIVE_INFINITY;
  };
  active.sort((lhs, rhs) => {
    const left = stamp(lhs);
    const right = stamp(rhs);
    return left === right ? lhs.offset - rhs.offset : left - right;
  });
  inactive.sort((lhs, rhs) => {
    const left = lhs.last ?? Number.NEGATIVE_INFINITY;
    const right = rhs.last ?? Number.NEGATIVE_INFINITY;
    return left === right ? lhs.offset - rhs.offset : right - left;
  });
  return {
    pinned: pinned.map(entry => entry.project),
    active: active.map(entry => entry.project),
    inactive: inactive.map(entry => entry.project),
  };
}

/// When a Project last had activity, from its Workspaces' own stamps.
export function projectLastActiveAt(workspaces = []) {
  let latest = null;
  for (const workspace of workspaces) {
    const time = workspace?.lastActiveAt ? Date.parse(workspace.lastActiveAt) : NaN;
    if (Number.isFinite(time) && (latest === null || time > latest)) latest = time;
  }
  return latest;
}

/// The letter a Project or Host tile carries.
export function monogram(name) {
  const match = String(name || "").trim().match(/[\p{L}\p{N}]/u);
  return match ? match[0].toUpperCase() : "·";
}

/// The Desktop's identity hues for a Project tile (WarrenColorTokens.dark's
/// identityTints), in the Desktop's order so a Project wears the same colour in
/// both clients.
export const identityTints = [
  "#689dbc",
  "#b280ad",
  "#89ae7e",
  "#c69d6a",
  "#9189be",
  "#69b1a8",
  "#bb857c",
  "#91a06f",
];

/// The tint a Project wears, picked as WarrenDesktopProjectAvatar picks it: a
/// 32-bit FNV-1a hash of the Project's ID over its UTF-8 bytes, modulo the
/// palette. Stable across reloads and reorderings.
export function identityTint(identity) {
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(String(identity ?? ""))) {
    hash = Math.imul(hash ^ byte, 16777619) >>> 0;
  }
  return identityTints[hash % identityTints.length];
}

/// A branch cut where the Desktop dims it: everything up to the last slash is
/// the quieter prefix, the rest is the name.
export function branchParts(branch) {
  const text = String(branch || "");
  const cut = text.lastIndexOf("/");
  if (cut <= 0 || cut === text.length - 1) return { prefix: "", name: text };
  return { prefix: text.slice(0, cut + 1), name: text.slice(cut + 1) };
}
