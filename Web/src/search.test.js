import test from "node:test";
import assert from "node:assert/strict";
import { buildCatalog } from "./catalog.js";
import {
  buildIndex,
  createSearch,
  fieldRole,
  highlightRanges,
  highlightSegments,
  mergeRanges,
  normalize,
  parseQuery,
  searchIndex,
  suggestFromIndex,
} from "./search.js";

function index(descriptors) {
  return buildIndex(descriptors);
}

function keys(results) {
  return results.map(result => result.key);
}

function run(descriptors, raw, options) {
  return keys(searchIndex(index(descriptors), parseQuery(raw), options));
}

test("normalization folds case and diacritics", () => {
  assert.equal(normalize("  Feature/Search  "), "feature/search");
  assert.equal(normalize("Café"), "cafe");
});

test("a diacritic-insensitive query matches an accented title", () => {
  assert.deepEqual(
    run([{ key: "a", scope: "project", title: "Café Server" }], "cafe"),
    ["a"],
  );
});

test("a title match outranks a context match", () => {
  const descriptors = [
    { key: "project", scope: "project", title: "Warren", path: "/tmp/warren" },
    {
      key: "workspace",
      scope: "workspace",
      title: "feature/palette",
      aliases: ["warren-search"],
      context: ["Warren"],
    },
  ];
  assert.equal(run(descriptors, "warren")[0], "project");
});

test("a word prefix outranks a mid-word substring", () => {
  const descriptors = [
    { key: "mid", scope: "session", title: "unreviewed notes" },
    { key: "word", scope: "session", title: "code review" },
  ];
  assert.equal(run(descriptors, "review")[0], "word");
});

test("every token must match, but tokens may span different fields", () => {
  const descriptors = [
    { key: "hit", scope: "session", title: "Deploy API", context: ["Warren"] },
    { key: "miss", scope: "session", title: "Deploy Worker" },
  ];
  assert.deepEqual(run(descriptors, "warren deploy"), ["hit"]);
});

test("a contiguous phrase outranks scattered tokens", () => {
  const descriptors = [
    { key: "phrase", scope: "session", title: "run dev server" },
    { key: "scattered", scope: "session", title: "run", context: ["dev"] },
  ];
  assert.equal(run(descriptors, "run dev")[0], "phrase");
});

test("an abbreviation matches at word boundaries only", () => {
  const descriptors = [{ key: "a", scope: "session", title: "warren desktop command" }];
  assert.deepEqual(run(descriptors, "wdc"), ["a"]);
  // Two characters would match almost anything.
  assert.deepEqual(run(descriptors, "wc"), []);
  // Present, but reached through the middle of a word.
  assert.deepEqual(run(descriptors, "wnd"), []);
});

test("an abbreviation ranks below a real substring", () => {
  const descriptors = [
    { key: "loose", scope: "session", title: "warren desktop command" },
    { key: "tight", scope: "session", title: "wdc" },
  ];
  assert.equal(run(descriptors, "wdc")[0], "tight");
});

test("a scope prefix narrows the results", () => {
  const descriptors = [
    { key: "project", scope: "project", title: "Review" },
    { key: "workspace", scope: "workspace", title: "Review" },
  ];
  assert.deepEqual(run(descriptors, "w:review"), ["workspace"]);
  assert.equal(run(descriptors, "review").length, 2);
});

test("a filter with no text lists everything that survives it", () => {
  const query = parseQuery("w:");
  assert.equal(query.isFilterOnly, true);
  const descriptors = [
    { key: "a", scope: "workspace", title: "Alpha" },
    { key: "b", scope: "workspace", title: "Beta" },
    { key: "c", scope: "project", title: "Gamma" },
  ];
  assert.deepEqual(run(descriptors, "w:").sort(), ["a", "b"]);
});

test("a status filter is parsed and applied by the caller", () => {
  const query = parseQuery("@blocked deploy");
  assert.deepEqual([...query.statuses], ["blocked"]);
  assert.deepEqual(query.tokens, ["deploy"]);
  const descriptors = [
    { key: "blocked", scope: "session", title: "Deploy API" },
    { key: "ready", scope: "session", title: "Deploy Worker" },
  ];
  assert.deepEqual(
    run(descriptors, "@blocked deploy", { accepts: key => key === "blocked" }),
    ["blocked"],
  );
});

test("an unknown prefix stays literal text", () => {
  const query = parseQuery("http://host");
  assert.equal(query.scopes.size, 0);
  assert.deepEqual(
    run([{ key: "a", scope: "project", title: "http://host:8080" }], "http://host"),
    ["a"],
  );
});

test("evidence names the field that explains the match", () => {
  const descriptors = [
    { key: "a", scope: "session", title: "Shell", aliases: ["npm run dev"] },
  ];
  const [result] = searchIndex(index(descriptors), parseQuery("npm"));
  assert.equal(result.evidence.role, fieldRole.alias);
  assert.equal(result.evidence.text, "npm run dev");
  assert.deepEqual(result.evidence.ranges, [[0, 3]]);
});

test("a title match carries no evidence because the title is already visible", () => {
  const descriptors = [{ key: "a", scope: "session", title: "Deploy API" }];
  const [result] = searchIndex(index(descriptors), parseQuery("deploy"));
  assert.equal(result.evidence, null);
  // The title still reports where it matched, so a view never has to re-derive
  // it while rendering.
  assert.deepEqual(result.titleRanges, [[0, 6]]);
});

test("title ranges cover every token and survive diacritic folding", () => {
  const descriptors = [
    { key: "a", scope: "session", title: "Deploy staging API" },
    { key: "b", scope: "session", title: "Café runner" },
  ];
  const built = index(descriptors);

  const [multi] = searchIndex(built, parseQuery("deploy api"));
  assert.deepEqual(multi.titleRanges, [[0, 6], [15, 18]]);

  const accented = searchIndex(built, parseQuery("cafe"))[0];
  assert.deepEqual(
    highlightSegments(accented.title, accented.titleRanges)
      .filter(segment => segment.isMatch)
      .map(segment => segment.text),
    ["Café"],
  );
});

test("a row matched only through an alias has no title ranges", () => {
  const descriptors = [
    { key: "a", scope: "session", title: "Deploy API", aliases: ["npm run dev"] },
  ];
  const [result] = searchIndex(index(descriptors), parseQuery("npm"));
  assert.deepEqual(result.titleRanges, []);
});

test("evidence highlights every token in the winning field", () => {
  const descriptors = [
    { key: "a", scope: "session", title: "Shell", aliases: ["npm run dev"] },
  ];
  const [result] = searchIndex(index(descriptors), parseQuery("npm dev"));
  assert.deepEqual(result.evidence.ranges, [[0, 3], [8, 11]]);
});

test("a kind matches but never outranks a named resource", () => {
  const descriptors = [
    { key: "unnamed", scope: "session", title: "tmp", kinds: ["shell"] },
    { key: "named", scope: "session", title: "shell audit", kinds: ["shell"] },
  ];
  const results = run(descriptors, "shell");
  assert.equal(results[0], "named");
  assert.ok(results.includes("unnamed"));
});

test("boost reorders without rebuilding the index", () => {
  const built = index([
    { key: "quiet", scope: "workspace", title: "review one" },
    { key: "blocked", scope: "workspace", title: "review two" },
  ]);
  assert.equal(keys(searchIndex(built, parseQuery("review")))[0], "quiet");
  assert.equal(
    keys(searchIndex(built, parseQuery("review"), {
      boost: key => (key === "blocked" ? 500 : 0),
    }))[0],
    "blocked",
  );
});

test("suggestions only include boosted entries", () => {
  const built = index([
    { key: "pinned", scope: "workspace", title: "Pinned" },
    { key: "idle", scope: "workspace", title: "Idle" },
  ]);
  assert.deepEqual(
    keys(suggestFromIndex(built, { boost: key => (key === "pinned" ? 30 : 0) })),
    ["pinned"],
  );
});

test("bounded results equal the prefix of the full ranking", () => {
  const built = index(Array.from({ length: 200 }, (_, position) => ({
    key: `entry-${position}`,
    scope: "workspace",
    title: `feature/${position}`,
    subtitle: `Project ${position}`,
  })));
  const bounded = searchIndex(built, parseQuery("feature"), { limit: 20 });
  const full = searchIndex(built, parseQuery("feature"), { limit: 5000 });
  assert.deepEqual(keys(bounded), keys(full).slice(0, 20));
  assert.deepEqual(searchIndex(built, parseQuery("feature"), { limit: 0 }), []);
});

test("visually identical rows collapse", () => {
  const descriptors = [
    { key: "one", scope: "session", title: "Shell", subtitle: "Warren › main" },
    { key: "two", scope: "session", title: "Shell", subtitle: "Warren › main" },
    { key: "three", scope: "session", title: "Shell", subtitle: "Warren › review" },
  ];
  assert.equal(run(descriptors, "shell").length, 2);
});

test("duplicate facets do not inflate the score", () => {
  const repeated = searchIndex(
    index([{
      key: "a",
      scope: "workspace",
      title: "review",
      aliases: ["review", "Review", " review "],
    }]),
    parseQuery("review"),
  );
  const single = searchIndex(
    index([{ key: "a", scope: "workspace", title: "review" }]),
    parseQuery("review"),
  );
  assert.equal(repeated[0].score, single[0].score);
});

test("an empty query yields nothing", () => {
  assert.deepEqual(run([{ key: "a", scope: "project", title: "Warren" }], "   "), []);
});

test("highlight segments split on matched runs", () => {
  const segments = highlightSegments("Deploy API", highlightRanges("Deploy API", ["api"]));
  assert.deepEqual(segments.map(segment => segment.text), ["Deploy ", "API"]);
  assert.deepEqual(segments.map(segment => segment.isMatch), [false, true]);
});

test("highlight merges overlapping ranges", () => {
  assert.deepEqual(mergeRanges([[0, 4], [2, 6], [8, 9]]), [[0, 6], [8, 9]]);
});

test("a catalog search finds sessions, workspaces, and projects", () => {
  const search = createSearch(buildCatalog({
    projects: [{ id: "project", name: "Warren", path: "/tmp/warren", pinned: false }],
    workspaces: [{
      id: "workspace",
      project: "project",
      name: "Review",
      path: "/tmp/warren-review",
      branch: "feature/search",
    }],
    tabs: [{
      id: "tab",
      session: "session",
      workspace: "workspace",
      title: "Shell",
      customTitle: "Deploy API",
      kind: "shell",
      lifecycle: "running",
      commandLine: "npm run dev",
      process: "npm",
      directory: "/tmp/warren-review",
      agentStatus: { activity: "blocked" },
    }],
  }));

  assert.equal(search.results("deploy")[0].target.kind, "session");
  assert.equal(search.results("deploy")[0].target.workspace, "workspace");
  assert.equal(search.results("warren")[0].target.kind, "project");
  assert.ok(
    search.results("feature/search").some(row => row.target.kind === "workspace"),
  );

  // The row is named "Deploy API", so the running command is the only thing that
  // can explain why "npm" found it.
  assert.equal(search.results("npm")[0].evidence.text, "npm run dev");

  // A workspace reports the state of the work inside it.
  const blocked = search.results("@blocked").map(row => row.target.kind);
  assert.ok(blocked.includes("session"));
  assert.ok(blocked.includes("workspace"));
  assert.ok(!blocked.includes("project"));
});

test("a session row carries the provider that owns its icon", () => {
  const search = createSearch(buildCatalog({
    tabs: [
      { id: "a", session: "agent", title: "Review", kind: "codex", lifecycle: "running" },
      // The binding wins over the durable kind: a promoted shell reads as the
      // Agent that is running, not as what Warren launched.
      {
        id: "b",
        session: "promoted",
        title: "Review runner",
        kind: "shell",
        agentProvider: "claude-code",
        lifecycle: "running",
      },
      { id: "c", session: "plain", title: "Review shell", kind: "shell", lifecycle: "running" },
      // A binding the Host has not reported can still be recognized from the
      // command the session launched.
      {
        id: "d",
        session: "inferred",
        title: "Review inferred",
        kind: "shell",
        commandLine: "opencode --resume",
        lifecycle: "running",
      },
    ],
  }));

  const provider = id => search.results("review").find(row => row.target.id === id)?.provider;
  assert.equal(provider("agent"), "codex");
  assert.equal(provider("promoted"), "claude");
  assert.equal(provider("plain"), "shell");
  assert.equal(provider("inferred"), "opencode");
});

test("non-session rows have no provider and keep their scope glyph", () => {
  const search = createSearch(buildCatalog({
    projects: [{ id: "project", name: "Warren", path: "/tmp/warren" }],
    workspaces: [{
      id: "workspace",
      project: "project",
      name: "Warren review",
      path: "/tmp/warren-review",
    }],
  }));

  for (const row of search.results("warren")) {
    assert.equal(row.provider, "", `${row.scope} is not a session`);
  }
});

test("an ended session never reaches the catalog and so is unsearchable", () => {
  const search = createSearch(buildCatalog({
    tabs: [{
      id: "tab",
      session: "session",
      title: "Deploy API",
      lifecycle: "exited",
      kind: "shell",
    }],
  }));

  assert.deepEqual(search.results("deploy"), []);
});

test("an empty query offers only what the live state singled out", () => {
  const search = createSearch(buildCatalog({
    projects: [{ id: "project", name: "Warren", path: "/tmp/warren" }],
    workspaces: [
      { id: "quiet", project: "project", name: "Quiet", path: "/tmp/quiet" },
      { id: "pinned", project: "project", name: "Pinned", path: "/tmp/pinned", pinned: true },
    ],
  }));

  assert.deepEqual(
    search.results("").map(row => row.target.id),
    ["pinned"],
  );
});

test("highlight survives diacritic folding", () => {
  const segments = highlightSegments("Café", highlightRanges("Café", ["cafe"]));
  assert.deepEqual(segments.map(segment => segment.text), ["Café"]);
  assert.deepEqual(segments.map(segment => segment.isMatch), [true]);
});

test("highlight without ranges leaves text intact", () => {
  assert.deepEqual(
    highlightSegments("Café", []).map(segment => segment.text),
    ["Café"],
  );
});
