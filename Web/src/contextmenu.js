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
    { label: "Delete session", danger: true, action: () => actions.delete(session) },
  ];
}
