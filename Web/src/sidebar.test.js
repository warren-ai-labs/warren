import assert from "node:assert/strict";
import test from "node:test";

import { branchParts, identityTint, identityTints, monogram, partitionWorkspaces, sessionRowSummary } from "./sidebar.js";

test("a request for a person leads the second line in the attention tone", () => {
  assert.deepEqual(
    sessionRowSummary({ kind: "claude", agentStatus: { activity: "blocked", attention: { kind: "approval", reason: "permission" } } }),
    { tone: "attention", text: "Approval needed · Permission" },
  );
  assert.deepEqual(
    sessionRowSummary({ kind: "claude", agentStatus: { activity: "working", attention: { kind: "input" } } }),
    { tone: "attention", text: "Input needed" },
  );
  assert.equal(sessionRowSummary({ agentStatus: { activity: "failed" } }).tone, "danger");
});

test("working, done, and plain shells name what runs", () => {
  assert.deepEqual(sessionRowSummary({ kind: "claude", agentStatus: { activity: "working" } }), { tone: "live", text: "Working" });
  assert.deepEqual(sessionRowSummary({ kind: "shell", commandLine: "npm run dev", agentStatus: { activity: "ready" } }), { tone: "plain", text: "Done · npm run dev" });
  // Acknowledging a completion retires the dot, not the line: the row keeps its
  // height when the person selects it.
  assert.deepEqual(
    sessionRowSummary({ kind: "shell", commandLine: "npm run dev", agentStatus: { activity: "ready" } }),
    { tone: "plain", text: "Done · npm run dev" },
  );
  assert.deepEqual(sessionRowSummary({ kind: "shell", process: "zsh" }), { tone: "plain", text: "" });
  // A resting Agent reads the Host's sentence about the turn, as the Desktop does.
  assert.deepEqual(
    sessionRowSummary({
      kind: "claude",
      commandLine: "/usr/local/bin/claude",
      resultSentence: "Fixed the resize race, added 3 tests",
      agentStatus: { activity: "ready" },
    }),
    { tone: "plain", text: "Fixed the resize race, added 3 tests" },
  );
});

test("idle worktrees fold, the main checkout, the selection, and busy ones stay", () => {
  const workspaces = [{ id: "main" }, { id: "busy" }, { id: "idle-a" }, { id: "picked" }, { id: "idle-b" }];
  const counts = { busy: 2 };
  const { shown, idle } = partitionWorkspaces(workspaces, id => counts[id] || 0, "picked");
  assert.deepEqual(shown.map(w => w.id), ["main", "busy", "picked"]);
  assert.deepEqual(idle.map(w => w.id), ["idle-a", "idle-b"]);
});

test("monograms take the first letter or digit", () => {
  assert.equal(monogram("warren"), "W");
  assert.equal(monogram("  _bili-gateway"), "B");
  assert.equal(monogram("动态"), "动");
  assert.equal(monogram(""), "·");
});

test("a Project's tint follows the Desktop's FNV-1a pick", () => {
  // FNV-1a("") is the offset basis, 2166136261, which is 5 modulo 8.
  assert.equal(identityTint(""), identityTints[2166136261 % 8]);
  assert.equal(identityTint("p1"), identityTint("p1"));
  assert.ok(identityTints.includes(identityTint("动态")));
});

test("a branch's prefix is everything through its last slash", () => {
  assert.deepEqual(branchParts("feat/web/sidebar"), { prefix: "feat/web/", name: "sidebar" });
  assert.deepEqual(branchParts("main"), { prefix: "", name: "main" });
  assert.deepEqual(branchParts("trailing/"), { prefix: "", name: "trailing/" });
  assert.deepEqual(branchParts(""), { prefix: "", name: "" });
});
