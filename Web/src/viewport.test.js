import test from "node:test";
import assert from "node:assert/strict";
import { keyboardInset } from "./viewport.js";

test("keyboardInset is zero on desktop-sized viewports", () => {
  assert.equal(keyboardInset(800, 800, 0), 0);
});

test("keyboardInset is zero when the layout viewport already resized", () => {
  // Android Chrome with interactive-widget=resizes-content shrinks the
  // layout viewport, so the visible area matches it exactly.
  assert.equal(keyboardInset(450, 450, 0), 0);
});

test("keyboardInset returns the covered area on iOS", () => {
  assert.equal(keyboardInset(800, 450, 0), 350);
});

test("keyboardInset accounts for visual viewport panning", () => {
  // iOS pans the visual viewport upward when focusing an input, so the
  // covered area shrinks by the same amount.
  assert.equal(keyboardInset(800, 450, 100), 250);
});

test("keyboardInset clamps stale panning offsets after dismissal", () => {
  // iOS 26 can leave visualViewport.offsetTop > 0 after the keyboard
  // collapses; the computed inset must not push the bar off screen.
  assert.equal(keyboardInset(800, 800, 100), 0);
});

test("keyboardInset ignores sub-pixel float noise", () => {
  assert.equal(keyboardInset(800, 450, 348), 0);
  assert.equal(keyboardInset(800, 450, 347.5), 2.5);
});

test("keyboardInset clamps negative overscroll offsetTop", () => {
  assert.equal(keyboardInset(800, 800, -24), 0);
  assert.equal(keyboardInset(800, 450, -10), 350);
});
