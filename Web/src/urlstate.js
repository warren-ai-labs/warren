const VIEW_TABS = ["diff", "file"];
const DIFF_STYLES = ["split", "unified"];

function encode(value) {
  return value ? encodeURIComponent(value) : "";
}

function decode(value) {
  try {
    return value ? decodeURIComponent(value) : "";
  } catch {
    return "";
  }
}

export function uiStateToHash(state) {
  if (!state || typeof state !== "object") return "";
  const parts = [];
  if (state.projectID) parts.push(`p=${encode(state.projectID)}`);
  if (state.workspaceID) parts.push(`w=${encode(state.workspaceID)}`);
  if (state.sessionID) parts.push(`s=${encode(state.sessionID)}`);
  if (state.fileView && typeof state.fileView.path === "string" && state.fileView.path) {
    parts.push(`f=${encode(state.fileView.path)}`);
    if (typeof state.fileView.commit === "string" && state.fileView.commit) {
      parts.push(`g=${encode(state.fileView.commit)}`);
    } else {
      parts.push(`t=${state.fileView.staged ? "1" : "0"}`);
    }
  }
  if (VIEW_TABS.includes(state.viewTab)) parts.push(`v=${state.viewTab}`);
  if (DIFF_STYLES.includes(state.diffStyle)) parts.push(`d=${state.diffStyle}`);
  return parts.length ? `#${parts.join("&")}` : "";
}

export function uiStateFromHash(hash) {
  if (!hash || !hash.startsWith("#")) return {};
  const params = new URLSearchParams(hash.slice(1));
  const state = {};
  const projectID = decode(params.get("p"));
  if (projectID) state.projectID = projectID;
  const workspaceID = decode(params.get("w"));
  if (workspaceID) state.workspaceID = workspaceID;
  const sessionID = decode(params.get("s"));
  if (sessionID) state.sessionID = sessionID;

  const path = decode(params.get("f"));
  if (path) {
    const commit = decode(params.get("g"));
    state.fileView = commit
      ? { path, staged: false, commit }
      : { path, staged: params.get("t") === "1", commit: null };
  }

  const viewTab = params.get("v");
  if (VIEW_TABS.includes(viewTab)) state.viewTab = viewTab;
  const diffStyle = params.get("d");
  if (DIFF_STYLES.includes(diffStyle)) state.diffStyle = diffStyle;
  return state;
}
