import test from "node:test";
import assert from "node:assert/strict";
import { uiStateToHash, uiStateFromHash } from "./urlstate.js";

test("uiStateToHash serializes the full positioning state", () => {
  const hash = uiStateToHash({
    projectID: "project-a",
    workspaceID: "ws-a",
    sessionID: "sess-1",
    fileView: { path: "src/a.js", staged: true, commit: null },
    viewTab: "diff",
    diffStyle: "split",
  });
  assert.equal(
    hash,
    "#p=project-a&w=ws-a&s=sess-1&f=src%2Fa.js&t=1&v=diff&d=split",
  );
});

test("uiStateToHash emits commit instead of staged when present", () => {
  const hash = uiStateToHash({
    workspaceID: "ws-a",
    fileView: { path: "a.go", staged: false, commit: "abc123" },
  });
  assert.ok(hash.includes("&g=abc123"));
  assert.ok(!hash.includes("&t="));
});

test("uiStateToHash returns empty string for an empty state", () => {
  assert.equal(uiStateToHash({}), "");
  assert.equal(uiStateToHash(null), "");
});

test("uiStateToHash encodes special characters in paths", () => {
  const hash = uiStateToHash({
    workspaceID: "ws-a",
    fileView: { path: "src/a b#中&文.go", staged: false, commit: null },
  });
  const state = uiStateFromHash(hash);
  assert.equal(state.fileView.path, "src/a b#中&文.go");
});

test("uiStateFromHash restores the full state", () => {
  const state = uiStateFromHash("#w=ws-a&s=sess-1&f=src%2Fa.js&t=1&v=diff&d=split");
  assert.deepEqual(state, {
    workspaceID: "ws-a",
    sessionID: "sess-1",
    fileView: { path: "src/a.js", staged: true, commit: null },
    viewTab: "diff",
    diffStyle: "split",
  });
});

test("uiStateFromHash accepts a name selector at every resource level", () => {
  assert.deepEqual(
    uiStateFromHash("#p=Warren&w=feature&s=Claude%20Code"),
    { projectID: "Warren", workspaceID: "feature", sessionID: "Claude Code" },
  );
});

test("uiStateFromHash drops invalid enums and unknown keys", () => {
  const state = uiStateFromHash("#w=ws-a&f=x.txt&v=sideways&d=unified&bogus=1");
  assert.deepEqual(state, {
    workspaceID: "ws-a",
    fileView: { path: "x.txt", staged: false, commit: null },
    diffStyle: "unified",
  });
});

test("uiStateFromHash tolerates empty or corrupt hashes", () => {
  assert.deepEqual(uiStateFromHash(""), {});
  assert.deepEqual(uiStateFromHash("#"), {});
  assert.deepEqual(uiStateFromHash("#w=%zz"), {});
  assert.deepEqual(uiStateFromHash(null), {});
});

test("uiStateFromHash treats a bare workspace hash as navigation only", () => {
  const state = uiStateFromHash("#w=ws-b");
  assert.deepEqual(state, { workspaceID: "ws-b" });
});
