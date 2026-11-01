import assert from "node:assert/strict";
import test from "node:test";

import { buildCatalog } from "./catalog.js";
import { inboxBucket, inboxSections, inboxSummary } from "./inbox.js";

function fixture() {
  return buildCatalog({
    projects: [{ id: "p1", name: "warren" }, { id: "p2", name: "dolly" }],
    workspaces: [
      { id: "w1", project: "p1", branch: "main" },
      { id: "w2", project: "p2", branch: "main" },
    ],
    tabs: [
      { id: "s1", session: "s1", workspace: "w1", kind: "claude", agentStatus: { activity: "working" } },
      { id: "s2", session: "s2", workspace: "w1", kind: "shell", process: "zsh" },
      { id: "s3", session: "s3", workspace: "w2", kind: "codex", agentStatus: { activity: "blocked", attention: { kind: "approval" } } },
      { id: "s4", session: "s4", workspace: "w2", kind: "shell", commandLine: "npm run dev" },
      { id: "s5", session: "s5", workspace: "w2", kind: "claude", agentStatus: { activity: "ready" } },
    ],
  });
}

test("a Session lands in the section that says what it asks of a person", () => {
  assert.equal(inboxBucket({ agentStatus: { activity: "blocked", attention: { kind: "input" } } }), "attention");
  assert.equal(inboxBucket({ agentStatus: { activity: "failed" } }), "attention");
  assert.equal(inboxBucket({ kind: "claude", agentStatus: { activity: "working" } }), "running");
  assert.equal(inboxBucket({ kind: "shell", commandLine: "npm run dev" }), "running");
  assert.equal(inboxBucket({ kind: "shell", process: "zsh" }), "idle");
  assert.equal(inboxBucket({ kind: "claude", agentStatus: { activity: "ready" } }), "idle");
  // A finished turn is idle even while its command is still the shell's
  // foreground process, which is what an Agent launched from a shell looks like.
  assert.equal(
    inboxBucket({ kind: "shell", commandLine: "/usr/local/bin/claude --resume", agentStatus: { activity: "ready" } }),
    "idle",
  );
  assert.equal(
    inboxBucket({ kind: "shell", commandLine: "/usr/local/bin/claude --resume", agentStatus: { activity: "working" } }),
    "running",
  );
});

test("status grouping orders Needs you, Running, Idle and drops empty sections", () => {
  const sections = inboxSections(fixture());
  assert.deepEqual(sections.map(section => [section.title, section.rows.map(row => row.session.id)]), [
    ["Needs you", ["s3"]],
    ["Running", ["s1", "s4"]],
    ["Idle", ["s2", "s5"]],
  ]);
  assert.equal(sections[0].rows[0].project.name, "dolly");
  assert.equal(sections[0].rows[0].workspace.branch, "main");
});

test("project grouping follows the sidebar tree", () => {
  const sections = inboxSections(fixture(), "project");
  assert.deepEqual(sections.map(section => [section.title, section.rows.map(row => row.session.id)]), [
    ["warren", ["s1", "s2"]],
    ["dolly", ["s3", "s4", "s5"]],
  ]);
});

test("the summary counts what needs a person first", () => {
  assert.equal(inboxSummary(fixture()), "1 needs you · 2 running");
  assert.equal(inboxSummary(buildCatalog({ projects: [], workspaces: [], tabs: [] })), "No sessions");
  assert.equal(
    inboxSummary(buildCatalog({ projects: [], workspaces: [], tabs: [{ id: "a", session: "a", workspace: "w", kind: "shell" }] })),
    "1 idle",
  );
});
