export function projectMenuItems(project, actions) {
  return [
    {
      label: project.pinned ? "Unpin project" : "Pin project",
      action: () => actions.togglePin(project),
    },
    { label: "Rename project", action: () => actions.rename(project) },
    { label: "Import existing worktrees…", action: () => actions.openImport(project) },
    {
      label: project.autoImportGitWorktrees
        ? "Disable automatic worktree import"
        : "Enable automatic worktree import (no confirmation)",
      action: () => actions.toggleAutoImport(project),
    },
  ];
}

export function workspaceMenuItems(workspace, actions) {
  return [
    {
      label: workspace.pinned ? "Unpin workspace" : "Pin workspace",
      action: () => actions.togglePin(workspace),
    },
    { label: "Rename workspace", action: () => actions.rename(workspace) },
  ];
}

export function sessionMenuItems(session, actions) {
  return [
    {
      label: session.pinned ? "Unpin session" : "Pin session",
      action: () => actions.togglePin(session),
    },
    { label: "Rename session", action: () => actions.rename(session) },
    ...(actions.search ? [{ label: "Search terminal", action: () => actions.search(session) }] : []),
    { label: "Delete session", danger: true, action: () => actions.delete(session) },
  ];
}

/// The mobile command bar's overflow menu: the global actions that do not earn
/// a permanent slot at phone width, then the open Session's own actions.
export function mobileMoreMenuItems(session, { gitOpen, openSearch, toggleGit, ...sessionActions }) {
  return [
    { label: "Search projects", action: openSearch },
    { label: gitOpen ? "Hide Git panel" : "Show Git panel", action: toggleGit },
    ...(session ? sessionMenuItems(session, sessionActions) : []),
  ];
}

/// Where a desktop menu opened at `point` actually goes: flipped to the other
/// side of the pointer when it would overflow, and clamped to keep `margin`
/// clear of every viewport edge.
export function placeMenu(point, size, viewport, margin = 8) {
  const axis = (start, length, limit) => {
    let value = start;
    if (value + length > limit - margin && start - length >= margin) value = start - length;
    return Math.max(margin, Math.min(value, limit - margin - length));
  };
  return {
    x: axis(point.x, size.width, viewport.width),
    y: axis(point.y, size.height, viewport.height),
  };
}
