export function normalizeGitPanel(payload) {
  const changes = payload?.changes || [];
  return {
    branch: payload?.branch || "",
    upstream: payload?.upstream || "",
    ahead: payload?.ahead || 0,
    behind: payload?.behind || 0,
    aheadOfMain: payload?.aheadOfMain || 0,
    remote: payload?.remote || "",
    mainBranch: payload?.mainBranch || "",
    merged: Boolean(payload?.merged),
    operation: payload?.operation || "",
    staged: changes.filter(change => change.staged),
    unstaged: changes.filter(change => !change.staged),
    commits: (payload?.commits || []).map(commit => ({
      ...commit,
      files: commit.files || [],
    })),
    unmergedCommits: (payload?.unmergedCommits || []).map(commit => ({
      ...commit,
      files: commit.files || [],
    })),
    branches: {
      local: (payload?.branches || []).filter(branch => !branch.remote).map(branch => branch.name),
      remote: (payload?.branches || []).filter(branch => branch.remote).map(branch => branch.name),
    },
    pullRequest: payload?.pullRequest ? { ...payload.pullRequest } : null,
    pullRequestError: payload?.pullRequestError || "",
    refreshing: Boolean(payload?.refreshing),
  };
}

export const statusLabels = {
  M: "Modified",
  A: "Added",
  D: "Deleted",
  R: "Renamed",
  C: "Copied",
  U: "Unmerged",
  T: "Type change",
  "?": "Untracked",
  "??": "Untracked",
  "!": "Ignored",
  I: "Intent to add",
};

export function statusLabel(status) {
  return statusLabels[status] || status;
}

export function statusSymbol(status) {
  return status === "?" || status === "??" ? "??" : status;
}

const fileKindByExtension = {
  js: "javascript",
  jsx: "react",
  mjs: "javascript",
  cjs: "javascript",
  ts: "typescript",
  tsx: "react",
  mts: "typescript",
  cts: "typescript",
  vue: "vue",
  svelte: "svelte",
  html: "html",
  htm: "html",
  css: "css",
  scss: "css",
  sass: "css",
  less: "css",
  styl: "css",
  json: "json",
  jsonc: "json",
  json5: "json",
  yaml: "yaml",
  yml: "yaml",
  toml: "config",
  ini: "config",
  conf: "config",
  env: "config",
  md: "markdown",
  mdx: "markdown",
  rst: "markdown",
  txt: "text",
  csv: "data",
  tsv: "data",
  xml: "xml",
  svg: "svg",
  png: "image",
  jpg: "image",
  jpeg: "image",
  gif: "image",
  webp: "image",
  ico: "image",
  avif: "image",
  py: "python",
  pyw: "python",
  go: "go",
  rs: "rust",
  java: "java",
  kt: "kotlin",
  kts: "kotlin",
  swift: "swift",
  rb: "ruby",
  php: "php",
  c: "c",
  h: "c",
  cc: "cpp",
  cpp: "cpp",
  cxx: "cpp",
  hpp: "cpp",
  cs: "csharp",
  fs: "fsharp",
  fsx: "fsharp",
  sh: "shell",
  bash: "shell",
  zsh: "shell",
  fish: "shell",
  ps1: "powershell",
  sql: "sql",
  graphql: "graphql",
  gql: "graphql",
  proto: "proto",
  lock: "lock",
  wasm: "wasm",
};

export const fileKindLabels = {
  javascript: "JavaScript",
  react: "React",
  typescript: "TypeScript",
  vue: "Vue",
  svelte: "Svelte",
  html: "HTML",
  css: "Stylesheet",
  json: "JSON",
  yaml: "YAML",
  config: "Configuration",
  markdown: "Markdown",
  text: "Text",
  data: "Data",
  xml: "XML",
  svg: "SVG",
  image: "Image",
  python: "Python",
  go: "Go",
  rust: "Rust",
  java: "Java",
  kotlin: "Kotlin",
  swift: "Swift",
  ruby: "Ruby",
  php: "PHP",
  c: "C",
  cpp: "C++",
  csharp: "C#",
  fsharp: "F#",
  shell: "Shell",
  powershell: "PowerShell",
  sql: "SQL",
  graphql: "GraphQL",
  proto: "Protocol Buffers",
  lock: "Lock file",
  wasm: "WebAssembly",
  file: "File",
};

export const fileKindGlyphs = {
  javascript: "JS",
  react: "JSX",
  typescript: "TS",
  vue: "V",
  svelte: "S",
  html: "<>",
  css: "#",
  json: "{}",
  yaml: "YAML",
  config: "⚙",
  markdown: "MD",
  text: "TXT",
  data: "CSV",
  xml: "XML",
  svg: "SVG",
  image: "IMG",
  python: "PY",
  go: "GO",
  rust: "RS",
  java: "JV",
  kotlin: "KT",
  swift: "SW",
  ruby: "RB",
  php: "PHP",
  c: "C",
  cpp: "C++",
  csharp: "C#",
  fsharp: "F#",
  shell: "SH",
  powershell: "PS",
  sql: "SQL",
  graphql: "GQL",
  proto: "RPC",
  lock: "LOCK",
  wasm: "WASM",
  file: "·",
};

export function fileKind(path) {
  const name = String(path || "").replaceAll("\\", "/").split("/").at(-1) || "";
  const lowerName = name.toLowerCase();
  if (lowerName === "dockerfile" || lowerName === "makefile" || lowerName === ".gitignore") {
    return "config";
  }
  const extension = lowerName.includes(".") ? lowerName.split(".").at(-1) : "";
  return fileKindByExtension[extension] || "file";
}

export function relativeTime(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds < 60) return "just now";
  const units = [
    [60, "minute"],
    [3600, "hour"],
    [86400, "day"],
    [604800, "week"],
    [2592000, "month"],
    [31536000, "year"],
  ];
  for (let i = units.length - 1; i >= 0; i--) {
    const [size, name] = units[i];
    if (seconds >= size) {
      const count = Math.floor(seconds / size);
      return `${count} ${name}${count === 1 ? "" : "s"} ago`;
    }
  }
}

export function diffSummary(changes) {
  return (changes || []).reduce(
    (total, change) => ({
      added: total.added + (change.added || 0),
      deleted: total.deleted + (change.deleted || 0),
    }),
    { added: 0, deleted: 0 },
  );
}

export function parseDiff(text) {
  const rawLines = String(text || "").split("\n");
  if (rawLines.at(-1) === "") rawLines.pop();
  const lines = [];
  let oldLine = 0;
  let newLine = 0;
  for (const raw of rawLines) {
    if (raw.startsWith("@@")) {
      const match = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
      if (match) {
        oldLine = Number(match[1]);
        newLine = Number(match[2]);
      }
      lines.push({ kind: "hunk", oldLine: "", newLine: "", text: raw });
    } else if (
      raw.startsWith("diff --git") ||
      raw.startsWith("index ") ||
      raw.startsWith("--- ") ||
      raw.startsWith("+++ ") ||
      raw.startsWith("new file mode") ||
      raw.startsWith("deleted file mode") ||
      raw.startsWith("\\ No newline") ||
      raw.startsWith("Binary files")
    ) {
      lines.push({ kind: "meta", oldLine: "", newLine: "", text: raw });
    } else if (raw.startsWith("+")) {
      lines.push({ kind: "add", oldLine: "", newLine, text: raw.slice(1) });
      newLine += 1;
    } else if (raw.startsWith("-")) {
      lines.push({ kind: "del", oldLine, newLine: "", text: raw.slice(1) });
      oldLine += 1;
    } else {
      lines.push({ kind: "context", oldLine, newLine, text: raw.slice(1) });
      oldLine += 1;
      newLine += 1;
    }
  }
  return lines;
}
