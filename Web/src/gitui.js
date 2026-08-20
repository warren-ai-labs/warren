const PANE_KEYS = ["checkout", "pr", "changes", "history"];
const VIEW_TABS = ["diff", "file"];
const DIFF_STYLES = ["split", "unified"];

export function gitPanelUIStorageKey(workspaceID) {
  return `warren.gitPanelUI.${workspaceID}`;
}

export function normalizeGitPanelUI(raw) {
  if (!raw || typeof raw !== "object") return {};
  const ui = {};
  if (Array.isArray(raw.openPanes)) {
    ui.openPanes = raw.openPanes.filter(key => PANE_KEYS.includes(key));
  }
  if (typeof raw.selectedKey === "string" && raw.selectedKey) {
    ui.selectedKey = raw.selectedKey;
  }
  if (Array.isArray(raw.expanded)) {
    ui.expanded = raw.expanded.filter(hash => typeof hash === "string" && hash);
  }
  if (typeof raw.branch === "string" && raw.branch) {
    ui.branch = raw.branch;
  }
  if (VIEW_TABS.includes(raw.viewTab)) ui.viewTab = raw.viewTab;
  if (DIFF_STYLES.includes(raw.diffStyle)) ui.diffStyle = raw.diffStyle;
  if (raw.fileView === null) {
    ui.fileView = null;
  } else if (raw.fileView && typeof raw.fileView.path === "string" && raw.fileView.path) {
    ui.fileView = {
      path: raw.fileView.path,
      staged: Boolean(raw.fileView.staged),
      commit: typeof raw.fileView.commit === "string" && raw.fileView.commit
        ? raw.fileView.commit
        : null,
    };
  }
  return ui;
}

export function loadGitPanelUI(storage, workspaceID) {
  try {
    return normalizeGitPanelUI(
      JSON.parse(storage.getItem(gitPanelUIStorageKey(workspaceID)) || "null"),
    );
  } catch {
    return {};
  }
}

export function saveGitPanelUI(storage, workspaceID, ui) {
  try {
    const normalized = normalizeGitPanelUI(ui);
    const key = gitPanelUIStorageKey(workspaceID);
    if (Object.keys(normalized).length === 0) storage.removeItem(key);
    else storage.setItem(key, JSON.stringify(normalized));
  } catch {
    // Snapshot persistence is best-effort; storage may be unavailable.
  }
}

export function gitPanelUIFileView(fileView) {
  if (!fileView || typeof fileView.path !== "string" || !fileView.path) return null;
  return {
    path: fileView.path,
    staged: Boolean(fileView.staged),
    commit: typeof fileView.commit === "string" && fileView.commit ? fileView.commit : null,
  };
}
