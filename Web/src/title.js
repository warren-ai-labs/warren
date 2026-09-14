export const defaultTitleTemplate = "{session} · {directory} · {command}";

export const titlePlaceholders = {
  session: "Session name",
  command: "Current command",
  directory: "Full directory",
  directoryName: "Directory name",
  workspace: "Workspace name",
  branch: "Git branch",
  host: "Host name",
  user: "User name",
  os: "Operating system",
};

export const compactDirectoryMaxLength = 32;
export const compactPlaceholderMaxLength = 32;

const placeholderPattern = new RegExp(`\\{(${Object.keys(titlePlaceholders).join("|")})\\}`, "g");
const separators = "—|·:-";
const separatorPattern = `[${separators}]|/(?!\\S)`;
const shellProcessNames = new Set([
  "zsh", "bash", "sh", "dash", "fish", "ksh", "csh", "tcsh",
  "pwsh", "powershell", "cmd", "nu", "elvish", "xonsh", "oil", "osh",
]);
const kindLabels = {
  claude: "claude",
  codex: "codex",
  opencode: "opencode",
  pi: "pi",
  qoder: "qoder",
  antigravity: "antigravity",
  trae: "trae",
  custom: "Custom",
};
const managedPurposes = new Set([
  "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae",
]);

export function renderTerminalTitle(template, session = {}, workspace = {}, host = {}) {
  const directory = session.directory || workspace.path || "";
  return renderTitleTemplate(template, titleValues(session, workspace, host, directory));
}

export function renderCompactTerminalTitle(template, session = {}, workspace = {}, host = {}) {
  const directory = session.directory || workspace.path || "";
  return renderTitleTemplate(
    template,
    compactTitleValues(session, workspace, host, directory),
  );
}

function titleValues(session, workspace, host, directory) {
  return {
    session: sessionDisplayTitle(session) || "Session",
    command: resolvedCommand(session),
    directory,
    directoryName: directoryName(directory),
    workspace: workspace.name || "",
    branch: workspace.branch || "",
    host: host.name || "",
    user: host.user || "",
    os: host.os || "",
  };
}

function compactTitleValues(session, workspace, host, directory) {
  const values = titleValues(session, workspace, host, directory);
  return {
    ...values,
    session: abbreviate(values.session),
    command: abbreviate(values.command),
    directory: abbreviateDirectory(values.directory, compactDirectoryMaxLength),
    directoryName: abbreviate(values.directoryName),
    workspace: abbreviate(values.workspace),
    branch: abbreviate(values.branch),
    host: abbreviate(values.host),
    user: abbreviate(values.user),
    os: abbreviate(values.os),
  };
}

function abbreviate(value, maxLength = compactPlaceholderMaxLength) {
  const text = String(value || "");
  return Array.from(text).length > maxLength ? fitMiddle(text, maxLength) : text;
}

function renderTitleTemplate(template, values) {
  const title = template
    .replace(placeholderPattern, (_, key) => values[key] || "")
    .replace(new RegExp(`\\s+(${separatorPattern})\\s*(?=(${separatorPattern}|$))`, "g"), "")
    .replace(/\s{2,}/g, " ")
    .replace(new RegExp(`^[\\s${separators}]+|[\\s${separators}]+$`, "g"), "");

  return title || values.session;
}

export function abbreviateDirectory(path, maxLength = compactDirectoryMaxLength) {
  const value = String(path || "");
  if (!value || maxLength <= 0 || value.length <= maxLength) return value;

  const absolute = value.startsWith("/");
  const segments = value.split("/").filter(Boolean);
  if (segments.length === 0) return value;

  const parents = segments.slice(0, -1).map(segment => Array.from(segment)[0] || "");
  const last = segments[segments.length - 1];
  const compact = `${absolute ? "/" : ""}${[...parents, last].join("/")}`;
  if (compact.length <= maxLength) return compact;
  return fitMiddle(compact, maxLength);
}

function fitMiddle(value, maxLength) {
  if (maxLength <= 1) return Array.from(value).slice(0, maxLength).join("");
  const visibleLength = maxLength - 1;
  const leftLength = Math.ceil(visibleLength / 2);
  const rightLength = visibleLength - leftLength;
  const characters = Array.from(value);
  return `${characters.slice(0, leftLength).join("")}…${characters.slice(-rightLength).join("")}`;
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
  return resolvedCommand(session);
}

/**
 * Resolves the command label shared by the pane title, tab, and sidebar.
 *
 * The full command line wins over the bare process name so a running
 * `npm run dev` reads better than `npm`. A foreground shell is not a command,
 * so it resolves empty and the caller falls back to the directory.
 */
export function resolvedCommand(session = {}) {
  const kind = String(session.kind || "").trim().toLowerCase();
  if (managedPurposes.has(kind)) return kindLabels[kind] || kind;
  const commandLine = String(session.commandLine || "").trim();
  if (commandLine && !shellProcessNames.has(executableName(commandLine))) {
    return commandLine;
  }
  const process = String(session.process || "").trim();
  if (process && !shellProcessNames.has(executableName(process))) {
    return process;
  }
  if (!commandLine && !process) {
    return kind && kind !== "shell" ? (kindLabels[kind] || kind) : "";
  }
  return "";
}

function executableName(value) {
  const token = String(value || "").trim().split(/\s+/)[0] || "";
  const base = token.split("/").pop() || token;
  return (base.startsWith("-") ? base.slice(1) : base).toLowerCase();
}

function directoryName(path) {
  return String(path).split("/").filter(Boolean).pop() || "";
}
