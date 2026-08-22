const NAVIGATION_PARAM = "navigation";
const VIEW_TABS = ["diff", "file"];
const DIFF_STYLES = ["split", "unified"];

function encode(value) {
  return value === null || value === undefined ? "" : encodeURIComponent(String(value));
}

function decode(value) {
  try {
    return value ? decodeURIComponent(String(value)) : "";
  } catch {
    return "";
  }
}

function decodeRaw(value) {
  return decode(value ? String(value).replace(/\+/g, " ") : value);
}

function normalizeQuery(query) {
  const value = String(query || "");
  return value.startsWith("?") ? value.slice(1) : value;
}

function readRawQueryParameter(query, name) {
  const rawQuery = normalizeQuery(query);
  if (!rawQuery) return null;
  for (const entry of rawQuery.split("&")) {
    if (!entry) continue;
    const separator = entry.indexOf("=");
    const rawKey = separator === -1 ? entry : entry.slice(0, separator);
    if (decodeRaw(rawKey) !== name) continue;
    return separator === -1 ? "" : entry.slice(separator + 1);
  }
  return null;
}

function appendValue(parts, key, value) {
  if (value) parts.push(`${key}=${encode(value)}`);
}

function structuredPairs(state) {
  if (!state || typeof state !== "object") return [];
  const parts = [];
  appendValue(parts, "project", state.projectID);
  appendValue(parts, "workspace", state.workspaceID);
  appendValue(parts, "session", state.sessionID);
  if (state.fileView && typeof state.fileView.path === "string" && state.fileView.path) {
    appendValue(parts, "file", state.fileView.path);
    if (typeof state.fileView.commit === "string" && state.fileView.commit) {
      appendValue(parts, "commit", state.fileView.commit);
    } else {
      parts.push(`staged=${state.fileView.staged ? "true" : "false"}`);
    }
  }
  if (VIEW_TABS.includes(state.viewTab)) parts.push(`view=${state.viewTab}`);
  if (DIFF_STYLES.includes(state.diffStyle)) parts.push(`diff=${state.diffStyle}`);
  return parts;
}

function parseStructuredNavigation(rawValue) {
  const encodedValue = String(rawValue || "");
  const firstKeyIsEncoded = /^[^=;&]+%3d/i.test(encodedValue);
  const value = !encodedValue.includes("=") || firstKeyIsEncoded
    ? decodeRaw(encodedValue)
    : encodedValue;
  const values = new Map();
  for (const pair of value.split(";")) {
    if (!pair) continue;
    const separator = pair.indexOf("=");
    if (separator < 1) continue;
    const key = pair.slice(0, separator);
    if (!values.has(key)) values.set(key, decodeRaw(pair.slice(separator + 1)));
  }

  const state = {};
  const projectID = values.get("project");
  if (projectID) state.projectID = projectID;
  const workspaceID = values.get("workspace");
  if (workspaceID) state.workspaceID = workspaceID;
  const sessionID = values.get("session");
  if (sessionID) state.sessionID = sessionID;

  const path = values.get("file");
  if (path) {
    const commit = values.get("commit");
    const staged = values.get("staged");
    state.fileView = commit
      ? { path, staged: false, commit }
      : { path, staged: staged === "true", commit: null };
  }

  const viewTab = values.get("view");
  if (VIEW_TABS.includes(viewTab)) state.viewTab = viewTab;
  const diffStyle = values.get("diff");
  if (DIFF_STYLES.includes(diffStyle)) state.diffStyle = diffStyle;
  return state;
}

/**
 * Serialize navigation into one descriptive query parameter. Values are
 * encoded individually so the semicolon-separated key/value structure stays
 * readable in a copied URL.
 */
export function uiStateToQuery(state) {
  const parts = structuredPairs(state);
  return parts.length ? `?${NAVIGATION_PARAM}=${parts.join(";")}` : "";
}

export function uiStateFromQuery(query) {
  const rawNavigation = readRawQueryParameter(query, NAVIGATION_PARAM);
  return rawNavigation === null ? {} : parseStructuredNavigation(rawNavigation);
}

export function hasNavigationQuery(query) {
  return readRawQueryParameter(query, NAVIGATION_PARAM) !== null;
}

/**
 * Replace only Warren's navigation parameter, preserving other query values.
 * The authentication fragment is intentionally untouched by this helper.
 */
export function replaceNavigationQuery(query, state) {
  const entries = normalizeQuery(query)
    .split("&")
    .filter(Boolean)
    .filter(entry => {
      const separator = entry.indexOf("=");
      const rawKey = separator === -1 ? entry : entry.slice(0, separator);
      return decodeRaw(rawKey) !== NAVIGATION_PARAM;
    });
  const navigation = uiStateToQuery(state);
  if (navigation) entries.push(navigation.slice(1));
  return entries.length ? `?${entries.join("&")}` : "";
}

export function navigationLocationKey(search) {
  return String(search || "");
}
