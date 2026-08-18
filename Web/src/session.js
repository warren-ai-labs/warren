export const defaultPresetCommands = {
  shell: "",
  claude: "claude",
  codex: "codex --dangerously-bypass-hook-trust",
};

export const sessionPresets = [
  { kind: "shell", label: "Shell", title: "Shell" },
  { kind: "claude", label: "Claude", title: "Claude Code" },
  { kind: "codex", label: "Codex", title: "Codex" },
];

export function firstAIPreset(presets = sessionPresets) {
  return presets.find(preset => preset.kind === "claude" || preset.kind === "codex") || null;
}

export function automaticSessionKind({ tabs, pending, explicit }) {
  if (!explicit || tabs.length || pending) return null;
  return firstAIPreset()?.kind || null;
}

export function reserveWorkspaceSession(pendingWorkspaceIDs, workspaceID) {
  if (!workspaceID || pendingWorkspaceIDs.has(workspaceID)) return false;
  pendingWorkspaceIDs.add(workspaceID);
  return true;
}

export function releaseWorkspaceSession(pendingWorkspaceIDs, workspaceID) {
  pendingWorkspaceIDs.delete(workspaceID);
}

export function shouldAttachCreatedSession(activeWorkspaceID, createdWorkspaceID) {
  return Boolean(createdWorkspaceID && activeWorkspaceID === createdWorkspaceID);
}
