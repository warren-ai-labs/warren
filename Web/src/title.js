export const defaultTitleTemplate = "{command} — {directoryName}";

export const titlePlaceholders = {
  session: "Session name",
  command: "Current process",
  directory: "Full directory",
  directoryName: "Directory name",
  workspace: "Workspace name",
  branch: "Git branch",
  host: "Host name",
  user: "User name",
  os: "Operating system",
};

const placeholderPattern = new RegExp(`\\{(${Object.keys(titlePlaceholders).join("|")})\\}`, "g");
const separators = "—|·:/-";
const shellProcessNames = new Set([
  "zsh", "bash", "sh", "dash", "fish", "ksh", "csh", "tcsh",
  "pwsh", "powershell", "cmd", "nu", "elvish", "xonsh", "oil", "osh",
]);
const kindLabels = {
  claude: "claude",
  codex: "codex",
  trae: "trae",
  custom: "Custom",
};

export function renderTerminalTitle(template, session = {}, workspace = {}, host = {}) {
  const directory = session.directory || workspace.path || "";
  const values = {
    session: sessionDisplayTitle(session) || "Session",
    command: session.process || session.kind || "shell",
    directory,
    directoryName: directoryName(directory),
    workspace: workspace.name || "",
    branch: workspace.branch || "",
    host: host.name || "",
    user: host.user || "",
    os: host.os || "",
  };

  const title = template
    .replace(placeholderPattern, (_, key) => values[key] || "")
    .replace(new RegExp(`\\s+([${separators}])\\s*(?=([${separators}]|$))`, "g"), "")
    .replace(/\s{2,}/g, " ")
    .replace(new RegExp(`^[\\s${separators}]+|[\\s${separators}]+$`, "g"), "");

  return title || values.session;
}

/**
 * Single display-name rule shared by non-tab surfaces: a user-set
 * CustomTitle wins, otherwise the generated default Title is shown.
 */
export function sessionDisplayTitle(session = {}) {
  const customTitle = String(session.customTitle || "").trim();
  return customTitle || String(session.title || "").trim();
}

/**
 * Tab title matching Superset's GroupStrip: interactive shells read as their
 * directory, while a meaningful purpose is shown as "purpose · directory".
 */
export function terminalTabTitle(session = {}, workspace = {}) {
  const customTitle = String(session.customTitle || "").trim();
  if (customTitle) return customTitle;
  const dirName = directoryName(session.directory || workspace.path || "");
  const command = tabPurpose(session);
  if (!dirName) return command || sessionDisplayTitle(session) || "Shell";
  return command ? `${command} · ${dirName}` : dirName;
}

function tabPurpose(session = {}) {
  const kind = String(session.kind || "").trim().toLowerCase();
  const process = String(session.process || "").trim();

  // Managed agents keep their stable launch kind even when the foreground
  // process is a shell or another implementation detail.
  if (kind === "claude" || kind === "codex" || kind === "trae") {
    return kindLabels[kind];
  }
  if (process && !shellProcessNames.has(process)) return process;
  return kind && kind !== "shell" ? kindLabels[kind] || kind : "";
}

function directoryName(path) {
  return String(path).split("/").filter(Boolean).pop() || "";
}
