import test from "node:test";
import assert from "node:assert/strict";
import { buildCatalog, moveInCatalog, rosterFromMessage, workspaceTabs } from "./catalog.js";
import {
  captureNavigationPosition,
  resolveRestoredWorkspace,
  restoreNavigationPosition,
} from "./navigation.js";
import {
  abbreviateDirectory,
  renderCompactTerminalTitle,
  renderTerminalTitle,
  sessionDisplayTitle,
  terminalTabTitle,
} from "./title.js";
import { escapeHTML } from "./view.js";

test("catalog indexes workspaces and open tabs", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [{ id: "workspace", project: "project" }],
    tabs: [{ id: "tab", session: "session", workspace: "workspace", title: "Shell" }],
  }));

  assert.equal(catalog.workspacesByProject.get("project")[0].id, "workspace");
  assert.deepEqual(workspaceTabs(catalog, "workspace"), [{
    id: "session",
    session: "session",
    workspace: "workspace",
    tabID: "tab",
    title: "Shell",
    kind: undefined,
  }]);
});

test("catalog keeps agent binding fields on sessions", () => {
  const catalog = buildCatalog(rosterFromMessage({
    state: {
      projects: [{ id: "project" }],
      workspaces: [{ id: "workspace", project: "project" }],
      sessions: [{
        id: "session",
        workspace: "workspace",
        title: "Codex",
        kind: "codex",
        command: "codex",
        lifecycle: "running",
        agentSessionId: "thread-1",
        transcriptPath: "/work/rollout.jsonl",
        agentStatus: { activity: "working", attention: null },
      }],
    },
  }));
  const session = catalog.sessions.get("session");
  assert.equal(session.kind, "codex");
  assert.equal(session.agentSessionId, "thread-1");
  assert.equal(session.transcriptPath, "/work/rollout.jsonl");
  assert.deepEqual(session.agentStatus, { activity: "working", attention: null });
});

test("catalog keeps merge state on workspaces", () => {
  const catalog = buildCatalog(rosterFromMessage({
    state: {
      projects: [{ id: "project" }],
      workspaces: [{ id: "workspace", project: "project", mergeState: "merged" }],
    },
  }));
  assert.equal(catalog.workspaces[0].mergeState, "merged");
});

test("roster carries live process and directory over launch command", () => {
  const catalog = buildCatalog(rosterFromMessage({
    state: {
      projects: [{ id: "project" }],
      workspaces: [{ id: "workspace", project: "project", path: "/work/start" }],
      sessions: [{
        id: "session",
        workspace: "workspace",
        title: "Shell",
        kind: "shell",
        command: "zsh",
        process: "codex",
        directory: "/work/live",
        lifecycle: "running",
      }],
    },
  }));
  const session = catalog.sessions.get("session");
  assert.equal(session.process, "codex");
  assert.equal(session.directory, "/work/live");
  assert.equal(
    terminalTabTitle(session, { path: "/work/start" }),
    "codex · live",
  );
});

test("roster falls back to launch command when process is absent", () => {
  const session = workspaceTabs(buildCatalog(rosterFromMessage({
    state: {
      workspaces: [{ id: "workspace", project: "project", path: "/work/start" }],
      sessions: [{
        id: "session",
        workspace: "workspace",
        title: "Codex",
        kind: "codex",
        command: "codex",
        lifecycle: "running",
      }],
    },
  })), "workspace")[0];
  assert.equal(session.process, "codex");
  assert.equal(terminalTabTitle(session, { path: "/work/start" }), "codex · start");
});

test("managed agent tab keeps its purpose when the foreground process is a shell", () => {
  for (const kind of ["claude", "codex", "trae"]) {
    assert.equal(
      terminalTabTitle(
        { title: kind, kind, process: "zsh", directory: "/work/warren" },
        {},
      ),
      `${kind} · warren`,
    );
  }
  assert.equal(
    terminalTabTitle(
      { title: "Codex", kind: "codex", process: "node", directory: "/work/warren" },
      {},
    ),
    "codex · warren",
  );
});

test("custom session titles win over derived tab titles", () => {
  assert.equal(
    terminalTabTitle(
      { title: "Codex", customTitle: "My Agent", process: "codex", directory: "/work/warren" },
      {},
    ),
    "My Agent",
  );
});

test("catalog keeps pinned workspaces and sessions first", () => {
  const catalog = buildCatalog(rosterFromMessage({
    projects: [
      { id: "project-b", name: "B", pinned: false },
      { id: "project-a", name: "A", pinned: true },
    ],
    workspaces: [
      { id: "workspace-b", project: "project-a", name: "B" },
      { id: "workspace-a", project: "project-a", name: "A", pinned: true },
    ],
    tabs: [
      { id: "tab-b", session: "session-b", workspace: "workspace-a", title: "B" },
      { id: "tab-a", session: "session-a", workspace: "workspace-a", title: "A", pinned: true },
    ],
  }));

  assert.equal(catalog.projects[0].id, "project-a");
  assert.equal(catalog.workspaces[0].id, "workspace-a");
  assert.equal(workspaceTabs(catalog, "workspace-a")[0].id, "session-a");
});

test("moveInCatalog reorders projects before a target", () => {
  const catalog = buildCatalog(rosterFromMessage({
    projects: [{ id: "project-a" }, { id: "project-b" }, { id: "project-c" }],
    workspaces: [],
  }));

  const moved = moveInCatalog(catalog, "projects", "project-c", "project-a");

  assert.deepEqual(moved.projects.map(project => project.id), [
    "project-c",
    "project-a",
    "project-b",
  ]);
});

test("moveInCatalog moves workspaces to the end of their project", () => {
  const catalog = buildCatalog(rosterFromMessage({
    projects: [{ id: "project" }],
    workspaces: [
      { id: "workspace-one", project: "project" },
      { id: "workspace-two", project: "project" },
      { id: "workspace-three", project: "project" },
    ],
  }));

  const moved = moveInCatalog(catalog, "workspaces", "workspace-one", null);

  assert.deepEqual(moved.workspaces.map(workspace => workspace.id), [
    "workspace-two",
    "workspace-three",
    "workspace-one",
  ]);
  assert.deepEqual(
    moved.workspacesByProject.get("project").map(workspace => workspace.id),
    ["workspace-two", "workspace-three", "workspace-one"],
  );
});

test("moveInCatalog is a no-op for an unknown id", () => {
  const catalog = buildCatalog(rosterFromMessage({
    projects: [{ id: "project-a" }],
    workspaces: [],
  }));

  assert.equal(moveInCatalog(catalog, "projects", "missing", null), catalog);
});

test("terminal title removes empty separators", () => {
  assert.equal(
    renderTerminalTitle("{command} — {directoryName}", { title: "Session" }),
    "shell",
  );
  assert.equal(
    renderTerminalTitle("{command} — {directoryName}", { process: "codex", directory: "/work/warren" }),
    "codex — warren",
  );
});

test("compact pane titles abbreviate parent directories and preserve full titles", () => {
  const directory = "/Users/lisongjian/Workspace/gh/abcdlsj/warren";
  assert.equal(abbreviateDirectory(directory), "/U/l/W/g/a/warren");
  assert.equal(
    renderCompactTerminalTitle(
      "{command} — {directory}",
      { process: "zsh", directory },
    ),
    "zsh — /U/l/W/g/a/warren",
  );
  assert.equal(
    renderTerminalTitle("{command} — {directory}", { process: "zsh", directory }),
    `zsh — ${directory}`,
  );
});

test("compact directory titles stay within the hard limit", () => {
  const directory = `/${Array.from({ length: 40 }, (_, index) => `segment-${index}`).join("/")}`;
  const compact = abbreviateDirectory(directory);
  assert.ok(compact.length <= 32);
  assert.match(compact, /^\/.+….+$/);
});

test("terminal tab title uses directory name for interactive shells", () => {
  assert.equal(
    terminalTabTitle(
      { title: "Shell", process: "zsh", directory: "/Users/me/Workspace/warren" },
      {},
    ),
    "warren",
  );
});

test("terminal tab title shows running process alongside directory", () => {
  assert.equal(
    terminalTabTitle(
      { title: "Codex", process: "codex", directory: "/Users/me/Workspace/superset" },
      {},
    ),
    "codex · superset",
  );
});

test("terminal tab title falls back without a directory", () => {
  assert.equal(terminalTabTitle({ title: "Shell" }, {}), "Shell");
});

test("terminal tab title falls back to agent kind without a directory", () => {
  assert.equal(terminalTabTitle({ title: "Codex", kind: "codex", process: "" }, {}), "codex");
});

test("session display title prefers custom title", () => {
  assert.equal(sessionDisplayTitle({ title: "Codex", customTitle: "My Agent" }), "My Agent");
  assert.equal(sessionDisplayTitle({ title: "Codex" }), "Codex");
  assert.equal(sessionDisplayTitle({ title: "Codex", customTitle: "   " }), "Codex");
  assert.equal(sessionDisplayTitle({}), "");
});

test("HTML escaping is safe for text and attributes", () => {
  assert.equal(escapeHTML(`<a title="x">&</a>`), "&lt;a title=&quot;x&quot;&gt;&amp;&lt;/a&gt;");
});

test("settings return restores the last workspace and session", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [
      { id: "workspace-main", project: "project" },
      { id: "workspace-review", project: "project" },
    ],
    tabs: [
      { id: "tab-main", session: "session-main", workspace: "workspace-main", title: "Main" },
      { id: "tab-review", session: "session-review", workspace: "workspace-review", title: "Review" },
    ],
  }));

  const position = captureNavigationPosition({
    activeWorkspace: "workspace-review",
    activeSession: "session-review",
  });
  assert.deepEqual(restoreNavigationPosition(position, catalog), {
    workspaceID: "workspace-review",
    sessionID: "session-review",
  });
});

test("settings return keeps the workspace when its previous session disappeared", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [{ id: "workspace-main", project: "project" }],
    tabs: [],
  }));

  assert.deepEqual(
    restoreNavigationPosition({ workspaceID: "workspace-main", sessionID: "deleted" }, catalog),
    { workspaceID: "workspace-main", sessionID: null },
  );
  assert.equal(
    restoreNavigationPosition({ workspaceID: "deleted", sessionID: "deleted" }, catalog),
    null,
  );
});

test("refresh restore prefers the saved session's workspace", () => {
  const catalog = buildCatalog(rosterFromMessage({
    workspaces: [
      { id: "workspace-main", project: "project" },
      { id: "workspace-review", project: "project" },
    ],
    tabs: [
      { id: "tab-main", session: "session-main", workspace: "workspace-main", title: "Main" },
      { id: "tab-review", session: "session-review", workspace: "workspace-review", title: "Review" },
    ],
  }));

  assert.equal(
    resolveRestoredWorkspace(catalog, "workspace-main", "session-review"),
    "workspace-review",
  );
  assert.equal(
    resolveRestoredWorkspace(catalog, "workspace-main", "deleted"),
    "workspace-main",
  );
  assert.equal(
    resolveRestoredWorkspace(catalog, "deleted", "deleted"),
    "workspace-main",
  );
});
