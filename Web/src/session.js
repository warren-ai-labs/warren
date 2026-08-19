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

export const defaultSessionPresetOrder = sessionPresets.map(preset => preset.kind);

export function normalizeSessionPresetOrder(order, presets = sessionPresets) {
  const knownKinds = new Set(presets.map(preset => preset.kind));
  const seen = new Set();
  const normalized = [];

  for (const kind of Array.isArray(order) ? order : []) {
    if (!knownKinds.has(kind) || seen.has(kind)) continue;
    seen.add(kind);
    normalized.push(kind);
  }
  for (const preset of presets) {
    if (seen.has(preset.kind)) continue;
    seen.add(preset.kind);
    normalized.push(preset.kind);
  }
  return normalized;
}

export function loadSessionPresetOrder(storage, key, presets = sessionPresets) {
  const fallback = presets.map(preset => preset.kind);
  try {
    const rawValue = storage.getItem(key);
    if (rawValue === null) return fallback;
    const normalized = normalizeSessionPresetOrder(JSON.parse(rawValue), presets);
    storage.setItem(key, JSON.stringify(normalized));
    return normalized;
  } catch {
    try {
      storage.setItem(key, JSON.stringify(fallback));
    } catch {
      // Restricted browser contexts can expose localStorage while rejecting writes.
    }
    return fallback;
  }
}

export function orderedSessionPresets(order, presets = sessionPresets) {
  const presetsByKind = new Map(presets.map(preset => [preset.kind, preset]));
  return normalizeSessionPresetOrder(order, presets).map(kind => presetsByKind.get(kind));
}

export function moveSessionPreset(order, kind, offset, presets = sessionPresets) {
  const normalized = normalizeSessionPresetOrder(order, presets);
  const index = normalized.indexOf(kind);
  const destination = index + offset;
  if (index < 0 || destination < 0 || destination >= normalized.length) return normalized;
  [normalized[index], normalized[destination]] = [normalized[destination], normalized[index]];
  return normalized;
}

export function firstAIPreset(presets = sessionPresets) {
  return presets.find(preset => preset.kind === "claude" || preset.kind === "codex") || null;
}

export function automaticSessionKind({ tabs, pending, explicit, presets = sessionPresets }) {
  if (!explicit || tabs.length || pending) return null;
  return firstAIPreset(presets)?.kind || null;
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
