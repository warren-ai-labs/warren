export function rosterFromMessage(message = {}) {
  const source = isRecord(message?.state) ? message.state : message;
  const sessions = Array.isArray(source?.sessions) ? source.sessions : null;
  const tabs = sessions
    ? sessions
      .filter(session => session?.lifecycle === "running")
      .map(sessionToTab)
      .filter(Boolean)
    : normalizeLegacyTabs(source?.tabs);
  return normalizeRoster({
    revision: normalizeRevision(source?.revision),
    schema: source?.schema,
    host: isRecord(source?.host) ? source.host : {},
    tasks: arrayOrEmpty(source?.tasks),
    projects: arrayOrEmpty(source?.projects),
    workspaces: arrayOrEmpty(source?.workspaces),
    terminalGroups: arrayOrEmpty(source?.terminalGroups),
    ghostlineMigration: source?.ghostlineMigration || null,
    tabs,
  });
}

/**
 * Applies one Host `roster.delta` event to the last authoritative snapshot.
 * A null result means the delta cannot be safely applied (missing revision,
 * malformed entity data, or a revision gap); callers should request a full
 * roster in that case instead of presenting a partial catalog.
 */
export function applyRosterDelta(roster, message = {}) {
  if (!isRecord(roster) || message?.t !== "roster.delta") return null;
  const current = normalizeRoster(roster);
  const baseRevision = normalizeRevision(message.baseRevision);
  const revision = normalizeRevision(message.revision);
  if (current.revision === null || baseRevision === null || revision === null
    || current.revision !== baseRevision || revision <= baseRevision) {
    return null;
  }

  const entityKeys = ["tasks", "projects", "workspaces", "terminalGroups", "sessions"];
  const entityIDs = {
    tasks: value => value?.id,
    projects: value => value?.id,
    workspaces: value => value?.id,
    terminalGroups: value => value?.id,
    sessions: value => value?.id,
  };
  if (Object.prototype.hasOwnProperty.call(message, "host") && !isRecord(message.host)) {
    return null;
  }
  if (Object.prototype.hasOwnProperty.call(message, "ghostlineMigration")
    && message.ghostlineMigration !== null
    && !isRecord(message.ghostlineMigration)) {
    return null;
  }
  const terminalGroupChanges = Object.prototype.hasOwnProperty.call(message, "terminalGroups")
    ? message.terminalGroups
    : message.groups;
  if (Object.prototype.hasOwnProperty.call(message, "groups")
    && !Object.prototype.hasOwnProperty.call(message, "terminalGroups")
    && !validEntityChanges(message.groups, entityIDs.terminalGroups)) {
    return null;
  }
  for (const key of entityKeys) {
    if (Object.prototype.hasOwnProperty.call(message, key)
      && !validEntityChanges(message[key], entityIDs[key])) {
      return null;
    }
  }
  if (Object.prototype.hasOwnProperty.call(message, "sessions")
    && arrayOrEmpty(message.sessions.upsert).some(value => typeof value.lifecycle !== "string")) {
    return null;
  }

  const sessionChanges = normalizeSessionChanges(message.sessions);
  return normalizeRoster({
    ...current,
    revision,
    schema: current.schema,
    host: isRecord(message.host) ? message.host : current.host,
    tasks: applyEntityChanges(current.tasks, message.tasks, value => value?.id),
    projects: applyEntityChanges(current.projects, message.projects, value => value?.id),
    workspaces: applyEntityChanges(current.workspaces, message.workspaces, value => value?.id),
    terminalGroups: applyEntityChanges(
      current.terminalGroups,
      terminalGroupChanges,
      value => value?.id,
    ),
    ghostlineMigration: Object.prototype.hasOwnProperty.call(message, "ghostlineMigration")
      ? message.ghostlineMigration || null
      : current.ghostlineMigration,
    tabs: applyEntityChanges(current.tabs, sessionChanges, value => value?.session),
  });
}

/**
 * Applies a live agent status without waiting for the next roster snapshot.
 * The catalog keeps the raw tab list and all derived indexes coherent so
 * every navigation surface observes the same status immediately.
 */
export function updateSessionAgentStatus(catalog, sessionID, agentStatus) {
  if (!catalog.sessions.has(sessionID)) return catalog;
  const tabs = catalog.tabs.map(tab => (
    tab.session === sessionID ? { ...tab, agentStatus } : tab
  ));
  return buildCatalog({
    revision: catalog.revision,
    schema: catalog.schema,
    host: catalog.host,
    tasks: catalog.tasks,
    projects: catalog.projects,
    workspaces: catalog.workspaces,
    terminalGroups: catalog.terminalGroups,
    ghostlineMigration: catalog.ghostlineMigration,
    tabs,
  });
}

export function buildCatalog(roster = rosterFromMessage()) {
  const sessions = new Map();
  const tabsByWorkspace = new Map();
  const workspacesByTask = new Map();
  const workspacesByProject = new Map();
  const tasks = [...(roster.tasks || [])].sort(pinnedFirst);
  const projects = [...roster.projects].sort(pinnedFirst);
  const workspaces = [...roster.workspaces].sort(pinnedFirst);
  const tabs = [...roster.tabs].sort(pinnedFirst);

  for (const tab of tabs) {
    sessions.set(tab.session, { ...tab, id: tab.session });
    append(tabsByWorkspace, tab.workspace, tab);
  }
  for (const workspace of workspaces) {
    if (workspace.task) append(workspacesByTask, workspace.task, workspace);
    append(workspacesByProject, workspace.project, workspace);
  }

  const projectsByID = new Map(projects.map(project => [project.id, project]));
  return {
    ...roster,
    tasks,
    projects,
    workspaces,
    sessions,
    tabsByWorkspace,
    workspacesByTask,
    workspacesByProject,
    projectsByID,
  };
}

/**
 * Returns a new catalog with one project or workspace moved before another
 * entry (or to the end when beforeID is omitted). The Host persists the same
 * order; this is the acting client's optimistic preview until the next roster
 * confirms it.
 */
export function moveInCatalog(catalog, kind, id, beforeID) {
  const sourceList = kind === "projects" ? catalog.projects : catalog.workspaces;
  const source = sourceList.findIndex(item => item.id === id);
  if (source < 0) return catalog;
  let target = sourceList.length;
  if (beforeID) {
    const before = sourceList.findIndex(item => item.id === beforeID);
    if (before >= 0) target = before;
  }
  const next = [...sourceList];
  const [moved] = next.splice(source, 1);
  if (source < target) target -= 1;
  next.splice(target, 0, moved);
  return buildCatalog({
    revision: catalog.revision,
    schema: catalog.schema,
    host: catalog.host,
    tasks: catalog.tasks,
    projects: kind === "projects" ? next : catalog.projects,
    workspaces: kind === "workspaces" ? next : catalog.workspaces,
    terminalGroups: catalog.terminalGroups,
    ghostlineMigration: catalog.ghostlineMigration,
    tabs: catalog.tabs,
  });
}

export function workspaceTabs(catalog, workspaceID) {
  return (catalog.tabsByWorkspace.get(workspaceID) || []).flatMap(tab => {
    const session = catalog.sessions.get(tab.session);
    if (!session) return [];
    return [{
      ...session,
      tabID: tab.id,
      title: tab.title || session.title,
      kind: tab.kind || session.kind,
    }];
  }).sort(pinnedFirst);
}

function append(map, key, value) {
  const values = map.get(key) || [];
  values.push(value);
  map.set(key, values);
}

function pinnedFirst(left, right) {
  return Number(Boolean(right.pinned)) - Number(Boolean(left.pinned));
}

function isRecord(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function arrayOrEmpty(value) {
  return Array.isArray(value) ? value : [];
}

function normalizeRevision(value) {
  if (value === null || value === undefined || value === "") return null;
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function normalizeRoster(roster) {
  return {
    revision: normalizeRevision(roster?.revision),
    schema: Number.isSafeInteger(roster?.schema) ? roster.schema : null,
    host: isRecord(roster?.host) ? roster.host : {},
    tasks: arrayOrEmpty(roster?.tasks),
    projects: arrayOrEmpty(roster?.projects),
    workspaces: arrayOrEmpty(roster?.workspaces),
    terminalGroups: arrayOrEmpty(roster?.terminalGroups),
    ghostlineMigration: isRecord(roster?.ghostlineMigration) ? roster.ghostlineMigration : null,
    tabs: normalizeLegacyTabs(roster?.tabs),
  };
}

function normalizeLegacyTabs(tabs) {
  return arrayOrEmpty(tabs).filter(tab => (
    isRecord(tab) && typeof tab.session === "string" && tab.session
  ));
}

function sessionToTab(session = {}) {
  if (!isRecord(session) || typeof session.id !== "string" || !session.id) return null;
  const tab = {
    id: session.id,
    session: session.id,
    workspace: session.workspace,
    title: session.title,
    customTitle: session.customTitle,
    kind: session.kind,
    command: session.command || "",
    lifecycle: session.lifecycle,
    process: session.process || session.command || "",
    directory: session.directory || "",
    agentSessionId: session.agentSessionId || "",
    transcriptPath: session.transcriptPath || "",
    agentModel: session.agentModel || "",
    agentStatus: session.agentStatus || null,
    agentTurn: session.agentTurn || null,
    pinned: session.pinned || false,
  };
  // Session scope fields are optional in older Hosts. Preserve them when
  // present so group-scoped sessions do not lose their ownership metadata.
  for (const key of ["terminalGroup", "scope"]) {
    if (Object.prototype.hasOwnProperty.call(session, key)) tab[key] = session[key];
  }
  return tab;
}

function normalizeSessionChanges(changes) {
  if (!isRecord(changes)) return null;
  const upsert = [];
  const remove = new Set(arrayOrEmpty(changes.remove).filter(value => typeof value === "string"));
  for (const value of arrayOrEmpty(changes.upsert)) {
    const id = typeof value?.id === "string" ? value.id : "";
    if (!id) continue;
    if (value.lifecycle !== "running") {
      remove.add(id);
      continue;
    }
    const tab = sessionToTab(value);
    if (tab) upsert.push(tab);
  }
  return {
    upsert,
    remove: [...remove],
    order: Array.isArray(changes.order)
      ? changes.order.filter(value => typeof value === "string")
      : undefined,
  };
}

function applyEntityChanges(current, changes, id) {
  if (!isRecord(changes)) return arrayOrEmpty(current);
  const valuesByID = new Map();
  for (const value of arrayOrEmpty(current)) {
    const valueID = id(value);
    if (typeof valueID === "string" && valueID) valuesByID.set(valueID, value);
  }
  for (const value of arrayOrEmpty(changes.upsert)) {
    const valueID = id(value);
    if (typeof valueID === "string" && valueID) valuesByID.set(valueID, value);
  }
  for (const valueID of arrayOrEmpty(changes.remove)) {
    if (typeof valueID === "string") valuesByID.delete(valueID);
  }

  const result = [];
  const emitted = new Set();
  const appendID = valueID => {
    if (!valuesByID.has(valueID) || emitted.has(valueID)) return;
    emitted.add(valueID);
    result.push(valuesByID.get(valueID));
  };
  if (Array.isArray(changes.order)) changes.order.forEach(appendID);
  arrayOrEmpty(current).forEach(value => appendID(id(value)));
  arrayOrEmpty(changes.upsert).forEach(value => appendID(id(value)));
  return result;
}

function validEntityChanges(changes, id) {
  if (!isRecord(changes)) return false;
  if (changes.upsert !== undefined && !Array.isArray(changes.upsert)) return false;
  if (changes.remove !== undefined && !Array.isArray(changes.remove)) return false;
  if (changes.order !== undefined && !Array.isArray(changes.order)) return false;
  if (arrayOrEmpty(changes.upsert).some(value => {
    if (!isRecord(value)) return true;
    const valueID = id(value);
    return typeof valueID !== "string" || !valueID;
  })) return false;
  if (arrayOrEmpty(changes.remove).some(value => typeof value !== "string" || !value)) return false;
  if (arrayOrEmpty(changes.order).some(value => typeof value !== "string" || !value)) return false;
  return true;
}
