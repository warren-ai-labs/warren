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

export function taskMenuItems(task, actions) {
  return [
    {
      label: task.pinned ? "Unpin task" : "Pin task",
      action: () => actions.togglePin(task),
    },
    { label: "Rename task", action: () => actions.rename(task) },
    { label: "Delete task", danger: true, action: () => actions.delete(task) },
  ];
}

export function workspaceMenuItems(workspace, actions) {
  const tasks = actions.tasks || [];
  const membershipItems = workspace.task
    ? [{ label: "Detach from task", action: () => actions.detach(workspace) }]
    : tasks.length
      ? tasks.map(task => ({
        label: `Add to task: ${task.name}`,
        action: () => actions.attach(workspace, task),
      }))
      : [{ label: "No tasks — create one first", action: () => {}, disabled: true }];
  return [
    {
      label: workspace.pinned ? "Unpin workspace" : "Pin workspace",
      action: () => actions.togglePin(workspace),
    },
    { label: "Rename workspace", action: () => actions.rename(workspace) },
    ...membershipItems,
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
