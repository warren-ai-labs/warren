import test from "node:test";
import assert from "node:assert/strict";
import {
  handleUnixTextEditingKey,
  InputQueue,
  MobileInputDeduper,
} from "./input.js";

function encoded(value) {
  return new TextEncoder().encode(value);
}

test("enqueues input while attaching and replays it in order", () => {
  const sent = [];
  const queue = new InputQueue({
    send: data => {
      sent.push(new TextDecoder().decode(data));
      return true;
    },
  });
  queue.enqueue("session-a", encoded("he"));
  queue.enqueue("session-a", encoded("llo"));
  assert.equal(sent.length, 0, "nothing sends before the session is ready");

  assert.equal(queue.flush("session-a"), true);
  assert.deepEqual(sent, ["he", "llo"]);
  assert.equal(queue.size, 0);
});

test("flushing one session preserves another session's pending input", () => {
  const sent = [];
  const queue = new InputQueue({
    send: data => {
      sent.push(new TextDecoder().decode(data));
      return true;
    },
  });
  queue.enqueue("session-b", encoded("b"));
  queue.enqueue("session-a", encoded("a"));

  assert.equal(queue.flush("session-a"), true);
  assert.deepEqual(sent, ["a"]);
  assert.equal(queue.size, 1);

  assert.equal(queue.flush("session-b"), true);
  assert.deepEqual(sent, ["a", "b"]);
});

test("send failure keeps the failed frame and everything after it", () => {
  const sent = [];
  let failures = 0;
  let failAttempts = 0;
  const queue = new InputQueue({
    send: data => {
      const value = new TextDecoder().decode(data);
      if (value === "fail" && failAttempts === 0) {
        failAttempts += 1;
        return false;
      }
      sent.push(value);
      return true;
    },
    onSendFailure: () => {
      failures += 1;
    },
  });
  queue.enqueue("session-a", encoded("ok"));
  queue.enqueue("session-a", encoded("fail"));
  queue.enqueue("session-a", encoded("after"));
  queue.enqueue("session-b", encoded("other"));

  assert.equal(queue.flush("session-a"), false);
  assert.equal(failures, 1);
  assert.deepEqual(sent, ["ok"]);
  assert.equal(queue.size, 3);

  // The retry starts at the failed frame; bytes already delivered are gone.
  assert.equal(queue.flush("session-a"), true);
  assert.deepEqual(sent, ["ok", "fail", "after"]);
  assert.equal(queue.size, 1);
  assert.equal(queue.flush("session-b"), true);
});

test("clear drops queued input on an explicit session switch", () => {
  const queue = new InputQueue({ send: () => true });
  queue.enqueue("session-a", encoded("x"));
  queue.clear();
  assert.equal(queue.size, 0);
});

test("overflow evicts the oldest queued bytes", () => {
  const queue = new InputQueue({ limit: 10, send: () => true });
  queue.enqueue("session-a", encoded("12345"));
  queue.enqueue("session-a", encoded("67890"));
  queue.enqueue("session-a", encoded("abc"));
  assert.equal(queue.size, 2);
  assert.equal(queue.flush("session-a"), true);
  assert.equal(queue.size, 0);
});

test("send exceptions are treated as failures and keep the frame", () => {
  let failures = 0;
  const queue = new InputQueue({
    send: () => {
      throw new Error("socket closing");
    },
    onSendFailure: () => {
      failures += 1;
    },
  });
  queue.enqueue("session-a", encoded("x"));
  assert.equal(queue.flush("session-a"), false);
  assert.equal(failures, 1);
  assert.equal(queue.size, 1);
});

test("mobile deduper drops exact duplicates inside the composition window", () => {
  let now = 0;
  const deduper = new MobileInputDeduper({ isTouch: true, windowMs: 150, now: () => now });

  assert.equal(deduper.shouldSend("a"), true);
  now += 20;
  assert.equal(deduper.shouldSend("a"), false);
  now += 200;
  assert.equal(deduper.shouldSend("a"), true);
});

test("mobile deduper keeps different characters and respects IME composition", () => {
  let now = 0;
  const deduper = new MobileInputDeduper({ isTouch: false, windowMs: 150, now: () => now });

  deduper.onCompositionStart();
  assert.equal(deduper.shouldSend("h"), true);
  now += 10;
  assert.equal(deduper.shouldSend("e"), true);
  now += 10;
  assert.equal(deduper.shouldSend("l"), true);
  now += 10;
  assert.equal(deduper.shouldSend("l"), false);

  deduper.onCompositionEnd();
  now += 10;
  assert.equal(deduper.shouldSend("l"), false);
  now += 200;
  assert.equal(deduper.shouldSend("l"), true);
});

test("mobile deduper does not gate desktop key repeat", () => {
  let now = 0;
  const deduper = new MobileInputDeduper({ isTouch: false, windowMs: 150, now: () => now });

  assert.equal(deduper.shouldSend("a"), true);
  now += 20;
  assert.equal(deduper.shouldSend("a"), true);
});

test("mobile deduper keeps genuine fast repeats outside composition", () => {
  let now = 0;
  const deduper = new MobileInputDeduper({ isTouch: true, windowMs: 150, now: () => now });

  assert.equal(deduper.shouldSend("!"), true);
  now += 60;
  assert.equal(deduper.shouldSend("!"), true);
  now += 20;
  // A true OS echo of the same keystroke still lands inside the tiny window.
  assert.equal(deduper.shouldSend("!"), false);
});

function editableTarget(value) {
  return {
    tagName: "INPUT",
    type: "text",
    value,
    selectionStart: value.length,
    selectionEnd: value.length,
    classList: { contains: () => false },
    setSelectionRange(start, end) {
      this.selectionStart = start;
      this.selectionEnd = end;
    },
    setRangeText(text, start, end, selectionMode) {
      this.value = `${this.value.slice(0, start)}${text}${this.value.slice(end)}`;
      const cursor = start + text.length;
      this.setSelectionRange(selectionMode === "end" ? cursor : start, cursor);
    },
    dispatchEvent() {},
  };
}

function keyEvent(target, key, modifiers = {}) {
  return {
    target,
    key,
    ...modifiers,
    preventDefault() { this.prevented = true; },
  };
}

test("Unix editing handles command select-all and control line movement", () => {
  const target = editableTarget("hello world");
  const selectAll = keyEvent(target, "a", { metaKey: true });
  assert.equal(handleUnixTextEditingKey(selectAll), true);
  assert.deepEqual([target.selectionStart, target.selectionEnd], [0, 11]);

  const beginning = keyEvent(target, "a", { ctrlKey: true });
  handleUnixTextEditingKey(beginning);
  assert.deepEqual([target.selectionStart, target.selectionEnd], [0, 0]);

  const end = keyEvent(target, "e", { ctrlKey: true });
  handleUnixTextEditingKey(end);
  assert.deepEqual([target.selectionStart, target.selectionEnd], [11, 11]);
});

test("Unix editing kills the active range without intercepting xterm", () => {
  const target = editableTarget("hello world");
  target.selectionStart = 5;
  target.selectionEnd = 5;
  const kill = keyEvent(target, "k", { ctrlKey: true });
  assert.equal(handleUnixTextEditingKey(kill), true);
  assert.equal(target.value, "hello");

  const terminalTarget = {
    ...editableTarget("shell"),
    tagName: "TEXTAREA",
    classList: { contains: className => className === "xterm-helper-textarea" },
  };
  assert.equal(handleUnixTextEditingKey(keyEvent(terminalTarget, "a", { ctrlKey: true })), false);
});

test("Unix editing falls back when a control does not expose range editing", () => {
  const target = {
    ...editableTarget("hello world"),
    setRangeText: undefined,
  };
  target.selectionStart = 5;
  target.selectionEnd = 5;

  assert.equal(handleUnixTextEditingKey(keyEvent(target, "k", { ctrlKey: true })), true);
  assert.equal(target.value, "hello");
});
