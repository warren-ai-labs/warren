import assert from "node:assert/strict";
import test from "node:test";

import {
  ACTIVITY_MARKS,
  activityMarkIsDrawn,
  activityMarkIsAcknowledgeable,
  activityMarkIsAnimated,
  activityMarkLabel,
  activityMarkLifecycle,
  activityMarkPriority,
  activityMarkTier,
  activityMarkWord,
  resolveActivityMark,
} from "./activity.js";

// The order is the rollup order, so a Workspace summary is a max over it.
// Pinning it keeps the ladder from drifting away from DESIGN.md §8.2 or from
// `WarrenActivityMark` in the Design System, which the native clients read.
test("priority ladder matches the documented order", () => {
  assert.deepEqual(ACTIVITY_MARKS, [
    "exited",
    "ready",
    "working",
    "attentionUnspecified",
    "inputNeeded",
    "approvalNeeded",
    "failed",
  ]);
  const priorities = ACTIVITY_MARKS.map(activityMarkPriority);
  assert.deepEqual(priorities, [...priorities].sort((a, b) => a - b));
  // A Session with no Agent bound sits below every mark, including `exited`.
  assert.equal(activityMarkPriority(null), 0);
  assert.ok(activityMarkPriority("exited") > activityMarkPriority(null));
});

// A plain shell reports no activity Warren can observe, so it draws nothing.
test("a session with no agent status resolves to no mark", () => {
  assert.equal(resolveActivityMark(null), null);
  assert.equal(resolveActivityMark(undefined), null);
  assert.equal(resolveActivityMark({}), null);
  assert.equal(resolveActivityMark({ activity: "nonsense" }), null);
});

test("lifecycle without attention maps straight through", () => {
  assert.equal(resolveActivityMark({ activity: "working" }), "working");
  assert.equal(resolveActivityMark({ activity: "ready" }), "ready");
  assert.equal(resolveActivityMark({ activity: "exited" }), "exited");
  assert.equal(resolveActivityMark({ activity: "failed" }), "failed");
});

// The Host can report an attention payload beside a lifecycle value that has not
// caught up. Reading the lifecycle first drew the quiet idle dot on the one row
// that needed someone.
test("attention outranks the lifecycle it arrives with", () => {
  assert.equal(
    resolveActivityMark({ activity: "ready", attention: { kind: "approval" } }),
    "approvalNeeded",
  );
  assert.equal(
    resolveActivityMark({ activity: "working", attention: { kind: "input" } }),
    "inputNeeded",
  );
});

// A turn that already ended badly is the more specific fact, so it keeps
// outranking a stale request the Host has not withdrawn yet.
test("failed outranks attention", () => {
  assert.equal(
    resolveActivityMark({ activity: "failed", attention: { kind: "approval" } }),
    "failed",
  );
});

// The live Host only ever sets `blocked` by marking attention, so a `blocked`
// with no payload comes from an older or partial snapshot. It must not borrow
// another kind's word and name a request Warren cannot see.
test("a request Warren cannot name stays unspecified", () => {
  for (const status of [
    { activity: "blocked" },
    { activity: "blocked", attention: { kind: "" } },
    { activity: "ready", attention: { kind: "something-new" } },
  ]) {
    const mark = resolveActivityMark(status);
    assert.equal(mark, "attentionUnspecified");
    assert.equal(activityMarkTier(mark), "actionable");
  }
});

// Motion now means exactly one thing: work is progressing. `blocked` used to
// pulse as well, which left the pulse marking "not ready, failed, or exited" —
// no single fact — and left a halted Session animating while it waited.
test("only progressing work animates", () => {
  assert.ok(activityMarkIsAnimated("working"));
  for (const mark of ACTIVITY_MARKS.filter((mark) => mark !== "working")) {
    assert.ok(!activityMarkIsAnimated(mark), `${mark} must not animate`);
  }
});

test("tiers cover every mark", () => {
  assert.equal(activityMarkTier("ready"), "idle");
  assert.equal(activityMarkTier("exited"), "idle");
  assert.equal(activityMarkTier("working"), "live");
  for (const mark of ["attentionUnspecified", "inputNeeded", "approvalNeeded", "failed"]) {
    assert.equal(activityMarkTier(mark), "actionable", `${mark} must be actionable`);
  }
});

// The lifecycle a mark reduces to is what `is:` filters and the Host's own
// per-session state still speak, so all three attention marks answer to
// `blocked`.
test("marks reduce to the lifecycle the host reports", () => {
  assert.equal(activityMarkLifecycle("approvalNeeded"), "blocked");
  assert.equal(activityMarkLifecycle("inputNeeded"), "blocked");
  assert.equal(activityMarkLifecycle("attentionUnspecified"), "blocked");
  assert.equal(activityMarkLifecycle("working"), "working");
  assert.equal(activityMarkLifecycle("ready"), "ready");
  assert.equal(activityMarkLifecycle("failed"), "failed");
  assert.equal(activityMarkLifecycle("exited"), "exited");
});

// Two marks sharing a label would make them indistinguishable to a screen
// reader now that the dot carries no glyph to tell them apart.
test("labels are distinct per mark", () => {
  const words = ACTIVITY_MARKS.map(activityMarkWord);
  assert.equal(new Set(words).size, words.length);
  const labels = ACTIVITY_MARKS.map(activityMarkLabel);
  assert.equal(new Set(labels).size, labels.length);
  assert.ok(labels.every((label) => typeof label === "string" && label.length > 0));
});

// A completion notice is news once. Every idle Agent reports `ready`, so without
// this the loudest thing in the tree is the one state that needs nothing.
test("a seen completion stops drawing", () => {
  assert.equal(resolveActivityMark({ activity: "ready" }), "ready");
  assert.equal(resolveActivityMark({ activity: "ready" }, "ready"), null);
  // The status itself is untouched by a caller that only wants the mark.
  assert.equal(String(resolveActivityMark({ activity: "ready", attention: null })), "ready");
});

// Looking is not answering, and a failure does not un-fail because it was seen.
test("only the idle tier can be retired by being seen", () => {
  assert.ok(activityMarkIsAcknowledgeable("ready"));
  // An ended Session is a permanent state, not an event.
  assert.ok(!activityMarkIsAcknowledgeable("exited"));
  const cases = [
    ["approvalNeeded", { activity: "blocked", attention: { kind: "approval" } }],
    ["inputNeeded", { activity: "ready", attention: { kind: "input" } }],
    ["attentionUnspecified", { activity: "blocked" }],
    ["failed", { activity: "failed" }],
    ["working", { activity: "working" }],
  ];
  for (const [mark, status] of cases) {
    assert.equal(resolveActivityMark(status), mark, "the case list must produce " + mark);
    assert.ok(!activityMarkIsAcknowledgeable(mark), mark + " must not be acknowledgeable");
    // Even an explicit acknowledgment of its own lifecycle leaves it drawn.
    assert.equal(
      resolveActivityMark(status, activityMarkLifecycle(mark)),
      mark,
      mark + " must survive an acknowledgment of its own lifecycle",
    );
  }
});

// The record self-invalidates, so `ready → (seen) → working → ready` lights up
// again: the Agent did something new in between.
test("an acknowledgment only matches its own state", () => {
  assert.equal(resolveActivityMark({ activity: "ready" }, "working"), "ready");
  assert.equal(resolveActivityMark({ activity: "ready" }, "exited"), "ready");
});

// An ended Session is permanent rather than an event, so every Session that ever
// ended would otherwise carry a grey dot forever.
test("an ended session never draws", () => {
  assert.equal(resolveActivityMark({ activity: "exited" }), "exited");
  assert.ok(!activityMarkIsDrawn("exited"));
  for (const mark of ACTIVITY_MARKS.filter((mark) => mark !== "exited")) {
    assert.ok(activityMarkIsDrawn(mark), mark + " must draw");
  }
  // Nothing about an ended Session becomes actionable later.
  assert.equal(
    resolveActivityMark({ activity: "exited", attention: { kind: "approval" } }),
    "approvalNeeded",
  );
  assert.ok(activityMarkIsDrawn("approvalNeeded"));
});
