import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { projectConversation } from "./conversation.js";

// The same fixture the Swift fold is measured against
// (Packages/Transport/Tests/WarrenTransportTests/WarrenConversationConformanceTests.swift).
// The two folds are independent implementations of RFC 0023 §9; this test makes
// a change that only lands in one of them visible.
const fixture = JSON.parse(
  readFileSync(new URL("../../protocol/fixtures/agent/conversation-basic.json", import.meta.url), "utf8"),
);

// The web fold reads merged events: the canonical type beside the payload it
// already carries on the wire.
const events = fixture.events.map((event) => ({
  canonicalType: event.type,
  type: event.type,
  payload: event.payload ?? {},
  turnId: event.turnId,
  sequence: event.sequence,
  occurredAt: event.occurredAt,
}));

test("the shared fixture projects the same conversation in Swift and web", () => {
  const { turns } = projectConversation(events);

  assert.equal(turns.length, fixture.expect.turns.length);
  for (const [index, expected] of fixture.expect.turns.entries()) {
    const turn = turns[index];
    assert.equal(turn.user?.text, expected.prompt);
    assert.equal(turn.answer, expected.answer);
    assert.equal(turn.answerComplete, expected.answerComplete);
    assert.equal(turn.status, expected.status);
    assert.deepEqual(turn.narration.map((message) => message.text), expected.narration);
    assert.equal(turn.summary, expected.summary);
    assert.equal(turn.reasoning.count, expected.reasoningCount);
    assert.deepEqual(
      turn.files.map(({ file, additions, deletions }) => ({ file, additions, deletions })),
      expected.files,
    );
  }
});
