import test from "node:test";
import assert from "node:assert/strict";
import { WarrenConnection, reconnectDelay, rejectPendingRequests } from "./connection.js";

class FakeSocket {
  static instances = [];

  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sent = [];
    FakeSocket.instances.push(this);
  }

  send(data) {
    this.sent.push(data);
  }

  close() {
    this.readyState = 3;
  }

  open() {
    this.readyState = 1;
    this.onopen?.();
  }

  disconnect() {
    this.readyState = 3;
    this.onclose?.();
  }
}

test("connection authenticates and forwards messages", () => {
  FakeSocket.instances = [];
  const messages = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    onMessage: event => messages.push(event.data),
  });

  connection.start();
  const socket = FakeSocket.instances[0];
  assert.equal(socket.binaryType, "arraybuffer");
  assert.equal(connection.request("session.attach", { id: "session-1" }), null);
  socket.open();
  assert.deepEqual(socket.sent, ['{"t":"auth","token":"secret","version":"1.0"}']);
  socket.onmessage({ data: "roster" });
  assert.deepEqual(messages, ["roster"]);
  assert.match(connection.request("session.detach"), /^web-/);
  assert.equal(JSON.parse(socket.sent[1]).method, "session.detach");
});

test("connection retries after a close and stop cancels retry", () => {
  FakeSocket.instances = [];
  const timers = [];
  const states = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    onState: state => states.push(state),
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
    random: () => 0.5,
  });

  connection.start();
  FakeSocket.instances[0].disconnect();
  assert.deepEqual(states, ["connecting", "waiting"]);
  assert.equal(timers[0].delay, 500);
  timers[0].callback();
  assert.equal(FakeSocket.instances.length, 2);
  FakeSocket.instances[1].open();
  FakeSocket.instances[1].disconnect();
  assert.equal(timers[1].delay, 1_000, "an unauthenticated socket must not reset backoff");
  connection.stop();
  assert.equal(timers[1].cancelled, true);
});

test("a stable authenticated connection resets backoff", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay });
      return timers.length - 1;
    },
    random: () => 0.5,
  });

  connection.start();
  FakeSocket.instances[0].disconnect();
  timers[0].callback();
  FakeSocket.instances[1].open();
  connection.markStable();
  FakeSocket.instances[1].disconnect();
  assert.equal(timers[1].delay, 500);
});

test("retry delay is bounded and jittered", () => {
  assert.equal(reconnectDelay(0, () => 0), 400);
  assert.equal(reconnectDelay(0, () => 1), 600);
  assert.equal(reconnectDelay(20, () => 0.5), 30_000);
});

test("send treats a throwing socket as a closed transport", () => {
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
  });
  connection.socket = {
    readyState: 1,
    send() {
      throw new Error("socket closing");
    },
  };
  assert.equal(connection.send("payload"), false);
});

test("rejectPendingRequests clears and fails every in-flight request", () => {
  const errors = [];
  const pending = new Map([
    ["a", { onError: detail => errors.push(`a:${detail}`) }],
    ["b", { onError: detail => errors.push(`b:${detail}`) }],
    ["c", {}],
  ]);
  rejectPendingRequests(pending, "offline");
  assert.equal(pending.size, 0);
  assert.deepEqual(errors, ["a:offline", "b:offline"]);
});
