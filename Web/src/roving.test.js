import test from "node:test";
import assert from "node:assert/strict";
import { rovingIndex, rovingTabIndex } from "./roving.js";

test("rovingIndex moves within a vertical group and wraps", () => {
  assert.equal(rovingIndex("ArrowDown", 0, 3), 1);
  assert.equal(rovingIndex("ArrowUp", 0, 3), 2);
  assert.equal(rovingIndex("ArrowDown", 2, 3), 0);
  assert.equal(rovingIndex("ArrowUp", 2, 3), 1);
});

test("rovingIndex jumps to the ends and honours loop: false", () => {
  assert.equal(rovingIndex("Home", 2, 5), 0);
  assert.equal(rovingIndex("PageUp", 2, 5), 0);
  assert.equal(rovingIndex("End", 1, 5), 4);
  assert.equal(rovingIndex("PageDown", 1, 5), 4);
  assert.equal(rovingIndex("ArrowUp", 0, 3, { loop: false }), 0);
  assert.equal(rovingIndex("ArrowDown", 2, 3, { loop: false }), 2);
});

test("rovingIndex ignores keys that do not belong to the orientation", () => {
  assert.equal(rovingIndex("ArrowRight", 1, 3), -1);
  assert.equal(rovingIndex("ArrowUp", 1, 3, { orientation: "horizontal" }), -1);
  assert.equal(rovingIndex("ArrowDown", 1, 3, { orientation: "horizontal" }), -1);
  assert.equal(rovingIndex("Enter", 1, 3), -1);
  assert.equal(rovingIndex("Tab", 1, 3), -1);
  assert.equal(rovingIndex("a", 1, 3), -1);
});

test("rovingIndex handles a horizontal group and an empty group", () => {
  assert.equal(rovingIndex("ArrowRight", 0, 3, { orientation: "horizontal" }), 1);
  assert.equal(rovingIndex("ArrowLeft", 0, 3, { orientation: "horizontal" }), 2);
  assert.equal(rovingIndex("ArrowDown", 0, 0), -1);
  assert.equal(rovingIndex("Home", 0, 0), -1);
});

test("rovingTabIndex keeps the single tab stop on a live item", () => {
  assert.equal(rovingTabIndex(1, 3), 1);
  assert.equal(rovingTabIndex(-1, 3), 0);
  assert.equal(rovingTabIndex(9, 3), 0);
  assert.equal(rovingTabIndex(0, 0), -1);
});
