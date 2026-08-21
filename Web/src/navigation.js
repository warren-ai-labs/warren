import { workspaceTabs } from "./catalog.js";

export function createNavigationMemory(raw = {}) {
  const normalize = value => Object.fromEntries(
    Object.entries(value && typeof value === "object" ? value : {}).filter(
      ([key, item]) => typeof key === "string" && typeof item === "string" && item,
    ),
  );
  return {
    workspaceByProjectID: normalize(raw.workspaceByProjectID),
    sessionByWorkspaceID: normalize(raw.sessionByWorkspaceID),
  };
}

export function rememberNavigation(memory, catalog, workspaceID, sessionID = null) {
  const next = createNavigationMemory(memory);
  const workspace = catalog?.workspaces?.find(value => value.id === workspaceID);
  if (!workspace) return next;

  next.workspaceByProjectID[workspace.project] = workspaceID;
  const tabs = workspaceTabs(catalog, workspaceID);
  if (sessionID && tabs.some(tab => tab.id === sessionID)) {
    next.sessionByWorkspaceID[workspaceID] = sessionID;
  }
  return next;
}

export function resolveProjectWorkspace(catalog, projectID, memory = {}) {
  const workspaces = catalog?.workspacesByProject?.get(projectID) || [];
  const normalized = createNavigationMemory(memory);
  const rememberedID = normalized.workspaceByProjectID[projectID];
  return workspaces.find(workspace => workspace.id === rememberedID)?.id
    || workspaces[0]?.id
    || null;
}

export function resolveWorkspaceSession(
  catalog,
  workspaceID,
  memory = {},
  preferredSessionID = null,
) {
  if (!catalog || !workspaceID) return null;
  const tabs = workspaceTabs(catalog, workspaceID);
  if (preferredSessionID && tabs.some(tab => tab.id === preferredSessionID)) {
    return preferredSessionID;
  }
  const normalized = createNavigationMemory(memory);
  const rememberedID = normalized.sessionByWorkspaceID[workspaceID];
  return tabs.find(tab => tab.id === rememberedID)?.id
    || tabs[0]?.id
    || null;
}

export function captureNavigationPosition(state = {}) {
  return {
    workspaceID: state.activeWorkspace || null,
    sessionID: state.activeSession || null,
  };
}

export function restoreNavigationPosition(position, catalog) {
  if (!position || !catalog) return null;

  const workspaceID = position.workspaceID && catalog.workspaces.some(
    workspace => workspace.id === position.workspaceID,
  )
    ? position.workspaceID
    : null;
  if (!workspaceID) return null;

  const sessionID = position.sessionID && workspaceTabs(catalog, workspaceID).some(
    session => session.id === position.sessionID,
  )
    ? position.sessionID
    : null;

  return { workspaceID, sessionID };
}

// Resolves the workspace to restore after a full page reload. The session the
// user was viewing is the anchor: if it still exists, its workspace wins even
// when the saved workspace no longer matches (for example after the user
// switched sessions just before refresh).
export function resolveRestoredWorkspace(catalog, preferredWorkspaceID, sessionID) {
  const session = sessionID ? catalog.sessions.get(sessionID) : null;
  const sessionWorkspaceID = session?.workspace || null;
  if (sessionWorkspaceID && catalog.workspaces.some(workspace => workspace.id === sessionWorkspaceID)) {
    return sessionWorkspaceID;
  }
  if (preferredWorkspaceID && catalog.workspaces.some(workspace => workspace.id === preferredWorkspaceID)) {
    return preferredWorkspaceID;
  }
  return catalog.workspaces[0]?.id || null;
}

// Link selectors may be either stable UUIDs or the current user-facing name.
// Names are intentionally resolved against the live catalog: a renamed
// resource makes an old name link fail instead of silently choosing a sibling.
export function resolveProjectID(catalog, selector) {
  return uniqueSelectorMatch(
    catalog?.projects || [],
    selector,
    project => project.id,
    project => [project.name],
  )?.id || null;
}

export function resolveWorkspaceID(catalog, selector, projectID = null) {
  const workspaces = (catalog?.workspaces || []).filter(workspace => (
    !projectID || workspace.project === projectID || workspace.projectID === projectID
  ));
  return uniqueSelectorMatch(
    workspaces,
    selector,
    workspace => workspace.id,
    workspace => [workspace.name],
  )?.id || null;
}

export function resolveSessionID(catalog, selector, workspaceID = null, projectID = null) {
  const sessions = [...(catalog?.sessions?.values?.() || [])].filter(session => {
    const sessionWorkspaceID = session.workspace || session.workspaceID || null;
    if (workspaceID && sessionWorkspaceID !== workspaceID) return false;
    if (projectID) {
      const workspace = catalog?.workspaces?.find(value => value.id === sessionWorkspaceID);
      if (!workspace || (workspace.project !== projectID && workspace.projectID !== projectID)) return false;
    }
    return true;
  });
  return uniqueSelectorMatch(
    sessions,
    selector,
    session => session.id,
    session => [session.customTitle, session.title],
  )?.id || null;
}

/**
 * Resolves a hash/deep-link positioning state without mutating navigation.
 * `error` is set whenever a requested selector is missing or ambiguous.
 */
export function resolveNavigationTarget(catalog, state = {}) {
  const requestedProject = state.projectID || null;
  const requestedWorkspace = state.workspaceID || null;
  const requestedSession = state.sessionID || null;
  const projectID = requestedProject
    ? resolveProjectID(catalog, requestedProject)
    : null;
  if (requestedProject && !projectID) {
    return { error: `Project “${requestedProject}” was not found or is ambiguous.` };
  }

  let workspaceID = requestedWorkspace
    ? resolveWorkspaceID(catalog, requestedWorkspace, projectID)
    : null;
  if (requestedWorkspace && !workspaceID) {
    return { error: `Workspace “${requestedWorkspace}” was not found or is ambiguous.` };
  }

  let sessionID = requestedSession
    ? resolveSessionID(catalog, requestedSession, workspaceID, projectID)
    : null;
  if (requestedSession && !sessionID) {
    return { error: `Session “${requestedSession}” was not found or is ambiguous.` };
  }

  if (sessionID) {
    const session = catalog.sessions.get(sessionID);
    const sessionWorkspaceID = session?.workspace || null;
    if (workspaceID && sessionWorkspaceID !== workspaceID) {
      return { error: `Session “${requestedSession}” is outside the requested workspace.` };
    }
    workspaceID = sessionWorkspaceID || workspaceID;
  }
  if (!workspaceID && projectID) workspaceID = resolveProjectWorkspace(catalog, projectID);
  if (workspaceID && projectID) {
    const workspace = catalog.workspaces.find(value => value.id === workspaceID);
    if (!workspace || (workspace.project !== projectID && workspace.projectID !== projectID)) {
      return { error: "The requested project and workspace do not belong together." };
    }
  }
  return { projectID, workspaceID, sessionID };
}

function uniqueSelectorMatch(values, selector, id, names) {
  if (!selector) return null;
  const normalized = String(selector).trim().toLocaleLowerCase();
  if (!normalized) return null;
  const matches = values.filter(value => {
    const candidates = [id(value), ...names(value)].filter(Boolean);
    return candidates.some(candidate => String(candidate).toLocaleLowerCase() === normalized);
  });
  return matches.length === 1 ? matches[0] : null;
}
