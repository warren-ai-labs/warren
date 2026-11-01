import { activityMarkTier, resolveActivityMark } from "./activity.js";
import { resolvedCommand } from "./title.js";

// The phone's home screen: every Session on the Host, sorted by what it asks
// of the person holding the phone. It mirrors the iOS inbox
// (ios-ux/warren-ios-redesign-spec.md §1), so moving between the two needs no
// relearning.

export const inboxGroupings = ["status", "project"];

/// Which section a Session belongs to.
///
/// A Session waiting on a person outranks everything. An Agent at work is
/// running. A finished turn is idle even while its command is still the
/// shell's foreground process: the row then reads "Done", so it must not sit
/// under "Running". Only a Session reporting no activity at all falls back to
/// what its terminal is running.
///
/// Acknowledgments are ignored on purpose: having read a completion does not
/// change what the Session is doing, and the row must not move when it is read.
export function inboxBucket(session = {}) {
  const mark = resolveActivityMark(session.agentStatus);
  if (mark) {
    const tier = activityMarkTier(mark);
    if (tier === "actionable") return "attention";
    return tier === "live" ? "running" : "idle";
  }
  const kind = String(session.kind || "").toLowerCase();
  if ((!kind || kind === "shell" || kind === "custom") && resolvedCommand(session)) return "running";
  return "idle";
}

function rowFor(catalog, tab) {
  const workspace = catalog.workspaces.find(candidate => candidate.id === tab.workspace) || null;
  const project = workspace ? catalog.projectsByID.get(workspace.project) || null : null;
  return { session: tab, workspace, project };
}

/// Sessions grouped the way the inbox shows them, empty sections left out.
///
/// `status` keeps the Host's own order inside a section (pinned first), which
/// is stable while the person reads it; `project` follows the sidebar's tree.
export function inboxSections(catalog, grouping = "status") {
  const tabs = (catalog?.tabs || []).filter(tab => !tab.lifecycle || tab.lifecycle === "running");
  if (grouping === "project") {
    const sections = [];
    for (const project of catalog?.projects || []) {
      const rows = [];
      for (const workspace of catalog.workspacesByProject?.get(project.id) || []) {
        for (const tab of catalog.tabsByWorkspace?.get(workspace.id) || []) {
          if (tab.lifecycle && tab.lifecycle !== "running") continue;
          rows.push({ session: tab, workspace, project });
        }
      }
      if (rows.length) sections.push({ id: `project:${project.id}`, title: project.name, rows });
    }
    return sections;
  }
  const buckets = { attention: [], running: [], idle: [] };
  for (const tab of tabs) {
    buckets[inboxBucket(tab)].push(rowFor(catalog, tab));
  }
  return [
    { id: "attention", title: "Needs you", rows: buckets.attention },
    { id: "running", title: "Running", rows: buckets.running },
    { id: "idle", title: "Idle", rows: buckets.idle },
  ].filter(section => section.rows.length);
}

/// The line under the inbox title: "3 running · 1 needs you", or a calm word
/// when nothing is happening.
export function inboxSummary(catalog) {
  let running = 0;
  let attention = 0;
  let total = 0;
  for (const tab of catalog?.tabs || []) {
    if (tab.lifecycle && tab.lifecycle !== "running") continue;
    total += 1;
    const bucket = inboxBucket(tab);
    if (bucket === "running") running += 1;
    if (bucket === "attention") attention += 1;
  }
  if (!total) return "No sessions";
  const parts = [];
  if (attention) parts.push(`${attention} need${attention === 1 ? "s" : ""} you`);
  if (running) parts.push(`${running} running`);
  return parts.length ? parts.join(" · ") : `${total} idle`;
}
