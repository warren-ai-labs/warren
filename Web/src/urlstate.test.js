import test from "node:test";
import assert from "node:assert/strict";
import {
  hasNavigationQuery,
  navigationLocationKey,
  replaceNavigationQuery,
  uiStateFromQuery,
  uiStateToQuery,
} from "./urlstate.js";

const navigationState = {
  projectID: "project-a",
  workspaceID: "ws-a",
  sessionID: "sess-1",
  fileView: { path: "src/a.js", staged: true, commit: null },
  viewTab: "diff",
  diffStyle: "split",
};

test("uiStateToQuery keeps navigation in one readable key/value parameter", () => {
  assert.equal(
    uiStateToQuery(navigationState),
    "?navigation=project=project-a;workspace=ws-a;session=sess-1;file=src%2Fa.js;staged=true;view=diff;diff=split",
  );
});

test("uiStateFromQuery restores structured navigation", () => {
  const query = "?navigation=project=project-a;workspace=ws-a;session=sess-1;file=src%2Fa.js;staged=true;view=diff;diff=split";
  assert.deepEqual(uiStateFromQuery(query), navigationState);
  assert.equal(navigationLocationKey(query), query);
});

test("structured navigation encodes delimiters, plus signs, and unicode in values", () => {
  const state = {
    workspaceID: "团队;workspace=1+2",
    fileView: { path: "src/a b#中&文;=+ .go", staged: false, commit: null },
  };
  assert.deepEqual(uiStateFromQuery(uiStateToQuery(state)), state);
});

test("uiStateFromQuery accepts a URL-encoded structured value", () => {
  const encoded = encodeURIComponent("workspace=ws-a;view=diff;diff=unified");
  assert.deepEqual(uiStateFromQuery(`?navigation=${encoded}`), {
    workspaceID: "ws-a",
    viewTab: "diff",
    diffStyle: "unified",
  });
});

test("uiStateFromQuery ignores short and fragment navigation formats", () => {
  assert.deepEqual(uiStateFromQuery("?w=ws-a&s=sess-1&f=src%2Fa.js&t=1"), {});
  assert.deepEqual(uiStateFromQuery("#w=ws-a&s=sess-1"), {});
});

test("replaceNavigationQuery preserves other query values", () => {
  const query = "?host=127.0.0.1%3A8789&navigation=workspace=old";
  const next = replaceNavigationQuery(query, { workspaceID: "ws-new" });
  assert.equal(next, "?host=127.0.0.1%3A8789&navigation=workspace=ws-new");
  assert.equal(hasNavigationQuery(next), true);
  const publicURL = new URL(`https://example.test/${next}#t=secret`);
  assert.equal(publicURL.search, next);
  assert.equal(publicURL.hash, "#t=secret");
});

test("replaceNavigationQuery removes navigation when state is empty", () => {
  assert.equal(
    replaceNavigationQuery("?host=127.0.0.1%3A8789&navigation=workspace=old", {}),
    "?host=127.0.0.1%3A8789",
  );
});

test("auth fragments are outside the navigation parser", () => {
  const url = new URL("https://example.test/?navigation=workspace=ws-a#t=web-secret");
  assert.deepEqual(uiStateFromQuery(url.search), { workspaceID: "ws-a" });
  assert.equal(url.hash, "#t=web-secret");
});
