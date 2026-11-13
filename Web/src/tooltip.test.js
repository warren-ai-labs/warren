import test from "node:test";
import assert from "node:assert/strict";
import {
  TOOLTIP_LEAVE_GRACE,
  TOOLTIP_SHOW_DELAY,
  TOOLTIP_WARM_WINDOW,
  createTooltipCenter,
  tooltipPosition,
} from "./tooltip.js";

/// A center on a fake clock. `advance(ms)` runs every timer that falls due.
function harness() {
  let clock = 0;
  let nextID = 1;
  const timers = new Map();
  const events = [];
  const center = createTooltipCenter({
    show: (anchor, glides) => events.push(["show", anchor, glides]),
    hide: () => events.push(["hide"]),
    now: () => clock,
    schedule: (callback, delay) => {
      const id = nextID++;
      timers.set(id, { at: clock + delay, callback });
      return id;
    },
    cancel: id => timers.delete(id),
  });
  const advance = ms => {
    const end = clock + ms;
    for (;;) {
      const due = [...timers.entries()].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      timers.delete(due[0]);
      clock = due[1].at;
      due[1].callback();
    }
    clock = end;
  };
  return { center, events, advance };
}

test("the first tooltip waits for the dwell", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  advance(TOOLTIP_SHOW_DELAY - 1);
  assert.deepEqual(events, []);
  advance(1);
  assert.deepEqual(events, [["show", "a", false]]);
});

test("leaving before the dwell ends shows nothing", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  advance(100);
  center.leave("a");
  advance(TOOLTIP_SHOW_DELAY);
  assert.deepEqual(events, []);
});

test("a neighbour answers at once and the bubble glides to it", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  advance(TOOLTIP_SHOW_DELAY);
  // The neighbour's enter can arrive before the old control's leave.
  center.enter("b");
  center.leave("a");
  advance(TOOLTIP_LEAVE_GRACE * 2);
  assert.deepEqual(events, [["show", "a", false], ["show", "b", true]]);
  assert.equal(center.current, "b");
});

test("crossing a gap shorter than the leave grace does not blink", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  advance(TOOLTIP_SHOW_DELAY);
  center.leave("a");
  advance(TOOLTIP_LEAVE_GRACE - 10);
  center.enter("b");
  advance(TOOLTIP_LEAVE_GRACE);
  assert.deepEqual(events, [["show", "a", false], ["show", "b", true]]);
});

test("within the warm window the next control shows without the dwell", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  advance(TOOLTIP_SHOW_DELAY);
  center.leave("a");
  advance(TOOLTIP_LEAVE_GRACE + TOOLTIP_WARM_WINDOW - 1);
  center.enter("b");
  assert.deepEqual(events, [["show", "a", false], ["hide"], ["show", "b", false]]);
});

test("after the warm window the dwell applies again", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  advance(TOOLTIP_SHOW_DELAY);
  center.leave("a");
  advance(TOOLTIP_LEAVE_GRACE + TOOLTIP_WARM_WINDOW);
  center.enter("b");
  assert.deepEqual(events, [["show", "a", false], ["hide"]]);
  advance(TOOLTIP_SHOW_DELAY);
  assert.deepEqual(events.at(-1), ["show", "b", false]);
});

test("dismiss hides at once and skips the warm window", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  advance(TOOLTIP_SHOW_DELAY);
  center.dismiss();
  assert.deepEqual(events, [["show", "a", false], ["hide"]]);
  center.enter("b");
  assert.equal(events.length, 2);
  advance(TOOLTIP_SHOW_DELAY);
  assert.deepEqual(events.at(-1), ["show", "b", false]);
});

test("dismiss cancels a pending dwell", () => {
  const { center, events, advance } = harness();
  center.enter("a");
  center.dismiss();
  advance(TOOLTIP_SHOW_DELAY);
  assert.deepEqual(events, []);
});

const viewport = { width: 1000, height: 600 };
const size = { width: 100, height: 24 };

test("tooltipPosition centres the bubble under the control", () => {
  assert.deepEqual(
    tooltipPosition({ left: 400, right: 440, top: 100, bottom: 120 }, size, viewport),
    { left: 370, top: 126 },
  );
});

test("tooltipPosition flips above when there is no room below", () => {
  assert.deepEqual(
    tooltipPosition({ left: 400, right: 440, top: 560, bottom: 580 }, size, viewport),
    { left: 370, top: 530 },
  );
});

test("tooltipPosition keeps the bubble inside the viewport", () => {
  assert.equal(tooltipPosition({ left: 0, right: 20, top: 100, bottom: 120 }, size, viewport).left, 8);
  assert.equal(tooltipPosition({ left: 980, right: 1000, top: 100, bottom: 120 }, size, viewport).left, 892);
  // A full-height control leaves no room on either side.
  assert.equal(tooltipPosition({ left: 400, right: 440, top: 0, bottom: 600 }, size, viewport).top, 8);
});
