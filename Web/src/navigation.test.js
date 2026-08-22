import test from "node:test";
import assert from "node:assert/strict";

import { buildCatalog, rosterFromMessage } from "./catalog.js";
import {
  rememberNavigation,
  resolveNavigationTarget,
  resolveProjectID,
  resolveSessionID,
  resolveWorkspaceID,
  resolveProjectWorkspace,
  resolveWorkspaceSession,
} from "./navigation.js";

function fixtureCatalog() {
  return buildCatalog(rosterFromMessage({
    projects: [
      { id: "project", name: "Warren" },
      { id: "other-project", name: "Other" },
    ],
    workspaces: [
      { id: "workspace-main", project: "project", name: "main", branch: "main" },
      { id: "workspace-feature", project: "project", name: "feature", branch: "feature" },
      { id: "workspace-other", project: "other-project", name: "other", branch: "other" },
    ],
    tabs: [
      { id: "session-main", session: "session-main", workspace: "workspace-main", title: "Shell" },
      { id: "session-feature", session: "session-feature", workspace: "workspace-feature", title: "Claude Code" },
      { id: "session-other", session: "session-other", workspace: "workspace-other", title: "Other" },
    ],
  }));
}

test("navigation memory restores the last tab for each workspace", () => {
  const catalog = fixtureCatalog();
  const memory = rememberNavigation({}, catalog, "workspace-main", "session-main");

  assert.equal(
    resolveWorkspaceSession(catalog, "workspace-main", memory),
    "session-main",
  );
  assert.equal(
    resolveWorkspaceSession(catalog, "workspace-feature", memory),
    "session-feature",
  );
});

test("navigation memory restores the last workspace for a project", () => {
  const catalog = fixtureCatalog();
  const memory = rememberNavigation({}, catalog, "workspace-feature", "session-feature");

  assert.equal(
    resolveProjectWorkspace(catalog, "project", memory),
    "workspace-feature",
  );
});

test("navigation memory falls back when remembered resources disappear", () => {
  const catalog = fixtureCatalog();
  const memory = {
    workspaceByProjectID: { project: "deleted-workspace" },
    sessionByWorkspaceID: { "workspace-main": "deleted-session" },
  };

  assert.equal(resolveProjectWorkspace(catalog, "project", memory), "workspace-main");
  assert.equal(resolveWorkspaceSession(catalog, "workspace-main", memory), "session-main");
});

test("resource link selectors resolve names and UUIDs at every level", () => {
  const catalog = fixtureCatalog();
  assert.equal(resolveProjectID(catalog, "Warren"), "project");
  assert.equal(resolveWorkspaceID(catalog, "feature", "project"), "workspace-feature");
  assert.equal(resolveSessionID(catalog, "Claude Code", "workspace-feature"), "session-feature");
  assert.deepEqual(
    resolveNavigationTarget(catalog, {
      projectID: "Warren",
      workspaceID: "feature",
      sessionID: "Claude Code",
    }),
    {
      projectID: "project",
      workspaceID: "workspace-feature",
      sessionID: "session-feature",
    },
  );
});

test("resource link selectors fail closed for stale names", () => {
  const catalog = fixtureCatalog();
  const result = resolveNavigationTarget(catalog, {
    projectID: "Warren",
    workspaceID: "renamed-feature",
  });
  assert.match(result.error, /Workspace/);
});

test("session selectors do not escape the requested project", () => {
  const catalog = fixtureCatalog();
  const result = resolveNavigationTarget(catalog, {
    projectID: "project",
    sessionID: "Other",
  });

  assert.match(result.error, /Session/);
});
