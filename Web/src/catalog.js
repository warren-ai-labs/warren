export function rosterFromMessage(message = {}) {
  if (message.state) {
    const state = message.state;
    return {
      host: state.host || {},
      projects: state.projects || [],
      workspaces: state.workspaces || [],
      tabs: (state.sessions || [])
        .filter(session => session.lifecycle === "running")
        .map(session => ({
          id: session.id,
          session: session.id,
          workspace: session.workspace,
          title: session.title,
          customTitle: session.customTitle,
          kind: session.kind,
          lifecycle: session.lifecycle,
          process: session.process || session.command || "",
          directory: session.directory || "",
          agentSessionId: session.agentSessionId || "",
          transcriptPath: session.transcriptPath || "",
          agentStatus: session.agentStatus || null,
          pinned: session.pinned || false,
        })),
    };
  }
  return {
    host: message.host || {},
    projects: message.projects || [],
    workspaces: message.workspaces || [],
    tabs: message.tabs || [],
  };
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
    host: catalog.host,
    projects: catalog.projects,
    workspaces: catalog.workspaces,
    tabs,
  });
}

export function buildCatalog(roster = rosterFromMessage()) {
  const sessions = new Map();
  const tabsByWorkspace = new Map();
  const workspacesByProject = new Map();
  const projects = [...roster.projects].sort(pinnedFirst);
  const workspaces = [...roster.workspaces].sort(pinnedFirst);
  const tabs = [...roster.tabs].sort(pinnedFirst);

  for (const tab of tabs) {
    sessions.set(tab.session, { ...tab, id: tab.session });
    append(tabsByWorkspace, tab.workspace, tab);
  }
  for (const workspace of workspaces) {
    append(workspacesByProject, workspace.project, workspace);
  }

  return { ...roster, projects, workspaces, sessions, tabsByWorkspace, workspacesByProject };
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
    host: catalog.host,
    projects: kind === "projects" ? next : catalog.projects,
    workspaces: kind === "workspaces" ? next : catalog.workspaces,
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
