import test from "node:test";
import assert from "node:assert/strict";
import { normalizeGitPanel, statusLabel, statusSymbol, relativeTime, diffSummary, parseDiff } from "./git.js";

test("normalizeGitPanel groups staged and unstaged changes", () => {
  const panel = normalizeGitPanel({
    workspace: "w1",
    branch: "main",
    ahead: 2,
    behind: 1,
    changes: [
      { path: "a.txt", status: "M", staged: true },
      { path: "b.txt", status: "M", staged: false },
      { path: "c.txt", status: "?", staged: false },
    ],
    commits: [{ hash: "abc", files: [{ path: "x", status: "A" }] }],
    branches: [
      { name: "main", remote: false },
      { name: "origin/main", remote: true },
    ],
  });

  assert.equal(panel.branch, "main");
  assert.equal(panel.ahead, 2);
  assert.equal(panel.behind, 1);
  assert.deepEqual(panel.staged.map(c => c.path), ["a.txt"]);
  assert.deepEqual(panel.unstaged.map(c => c.path), ["b.txt", "c.txt"]);
  assert.deepEqual(panel.branches.local, ["main"]);
  assert.deepEqual(panel.branches.remote, ["origin/main"]);
  assert.deepEqual(panel.commits[0].files, [{ path: "x", status: "A" }]);
});

test("normalizeGitPanel tolerates missing payload", () => {
  const panel = normalizeGitPanel(null);
  assert.equal(panel.branch, "");
  assert.deepEqual(panel.staged, []);
  assert.deepEqual(panel.commits, []);
  assert.deepEqual(panel.branches.local, []);
  assert.equal(panel.pullRequest, null);
  assert.equal(panel.pullRequestError, "");
});

test("normalizeGitPanel passes through pull request info", () => {
  const panel = normalizeGitPanel({
    pullRequest: { number: 42, title: "Add PR panel", state: "open", url: "https://github.com/abcdlsj/warren/pull/42" },
    pullRequestError: "",
    aheadOfMain: 7,
  });
  assert.equal(panel.pullRequest.number, 42);
  assert.equal(panel.pullRequest.title, "Add PR panel");
  assert.equal(panel.pullRequest.state, "open");
  assert.equal(panel.pullRequest.url, "https://github.com/abcdlsj/warren/pull/42");
  assert.equal(panel.pullRequestError, "");
  assert.equal(panel.aheadOfMain, 7);
});

test("statusLabel maps letters and falls back to raw", () => {
  assert.equal(statusLabel("M"), "Modified");
  assert.equal(statusLabel("?"), "Untracked");
  assert.equal(statusLabel("Q"), "Q");
});

test("statusSymbol keeps git letters and doubles untracked", () => {
  assert.equal(statusSymbol("M"), "M");
  assert.equal(statusSymbol("?"), "??");
  assert.equal(statusSymbol("A"), "A");
});

test("relativeTime formats past timestamps", () => {
  const minute = 60 * 1000;
  const hour = 60 * minute;
  assert.equal(relativeTime(new Date(Date.now() - 30 * 1000).toISOString()), "just now");
  assert.equal(relativeTime(new Date(Date.now() - 5 * minute).toISOString()), "5 minutes ago");
  assert.equal(relativeTime(new Date(Date.now() - 2 * hour).toISOString()), "2 hours ago");
  assert.equal(relativeTime(new Date(Date.now() + 5 * minute).toISOString()), "just now");
  assert.equal(relativeTime(""), "");
  assert.equal(relativeTime("not-a-date"), "");
});

test("diffSummary totals added and deleted lines", () => {
  assert.deepEqual(diffSummary([
    { path: "a.txt", added: 3, deleted: 1 },
    { path: "b.txt", added: 2, deleted: 0 },
    { path: "c.txt", added: 0, deleted: 5 },
  ]), { added: 5, deleted: 6 });
});

test("diffSummary ignores missing or zero counts", () => {
  assert.deepEqual(diffSummary([
    { path: "untracked.txt" },
    { path: "bin.dat", added: 0, deleted: 0 },
  ]), { added: 0, deleted: 0 });
  assert.deepEqual(diffSummary(null), { added: 0, deleted: 0 });
  assert.deepEqual(diffSummary([]), { added: 0, deleted: 0 });
});

test("normalizeGitPanel passes line counts through", () => {
  const panel = normalizeGitPanel({
    changes: [{ path: "a.txt", status: "M", staged: true, added: 3, deleted: 1 }],
    commits: [{ hash: "abc", files: [{ path: "x", status: "A", added: 4 }] }],
  });
  assert.equal(panel.staged[0].added, 3);
  assert.equal(panel.staged[0].deleted, 1);
  assert.equal(panel.commits[0].files[0].added, 4);
});

test("parseDiff splits unified diff into highlighted lines", () => {
  const lines = parseDiff([
    "diff --git a/a.txt b/a.txt",
    "index 0000000..1111111 100644",
    "--- a/a.txt",
    "+++ b/a.txt",
    "@@ -1,2 +1,2 @@",
    "-old",
    "+new",
    " same",
  ].join("\n"));
  assert.equal(lines[0].kind, "meta");
  assert.equal(lines[4].kind, "hunk");
  assert.deepEqual(lines[5], { kind: "del", oldLine: 1, newLine: "", text: "old" });
  assert.deepEqual(lines[6], { kind: "add", oldLine: "", newLine: 1, text: "new" });
  assert.deepEqual(lines[7], { kind: "context", oldLine: 2, newLine: 2, text: "same" });
});

test("parseDiff tracks line numbers across hunks", () => {
  const lines = parseDiff([
    "@@ -10,2 +10,2 @@",
    " ctx",
    "-gone",
    "+added",
    "@@ -30 +30,2 @@",
    " tail",
  ].join("\n"));
  assert.deepEqual(lines[1], { kind: "context", oldLine: 10, newLine: 10, text: "ctx" });
  assert.deepEqual(lines[2], { kind: "del", oldLine: 11, newLine: "", text: "gone" });
  assert.deepEqual(lines[3], { kind: "add", oldLine: "", newLine: 11, text: "added" });
  assert.deepEqual(lines[5], { kind: "context", oldLine: 30, newLine: 30, text: "tail" });
});

test("parseDiff tolerates empty and null input", () => {
  assert.deepEqual(parseDiff(""), []);
  assert.deepEqual(parseDiff(null), []);
  assert.deepEqual(parseDiff(undefined), []);
});
