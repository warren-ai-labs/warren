import test from "node:test";
import assert from "node:assert/strict";
import {
  ConnectionPresenter,
  WarrenConnection,
  appHeartbeatCapability,
  connectionErrorDetail,
  connectionInterrupted,
  connectionLive,
  connectionSettleGraceMs,
  connectionSettling,
  hostOfflineDetail,
  hostWaitCopyDelayMs,
  reconnectDelay,
  rejectPendingRequests,
  relativeTimeLabel,
  waitingForHostMessage,
} from "./connection.js";

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
  assert.equal(connection.request("session.subscribe", { id: "session-1" }), null);
  socket.open();
  assert.deepEqual(JSON.parse(socket.sent[0]), {
    t: "auth",
    token: "secret",
    version: "4.0",
    capabilities: ["roster-delta"],
    terminalStateFormats: ["ghostline-vt-replay-v1"],
  });
  socket.onmessage({ data: "roster" });
  assert.deepEqual(messages, ["roster"]);
  assert.match(connection.request("session.subscribe", { id: "session-1", claim: true }), /^web-/);
  assert.equal(JSON.parse(socket.sent[1]).method, "session.subscribe");
  assert.match(connection.request("session.unsubscribe", { id: "session-1" }), /^web-/);
  assert.equal(JSON.parse(socket.sent[2]).method, "session.unsubscribe");
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
  const firstRetry = timers.at(-1);
  assert.equal(firstRetry.delay, 500);
  firstRetry.callback();
  assert.equal(FakeSocket.instances.length, 2);
  FakeSocket.instances[1].open();
  FakeSocket.instances[1].disconnect();
  const secondRetry = timers.at(-1);
  assert.equal(secondRetry.delay, 1_000, "an unauthenticated socket must not reset backoff");
  connection.stop();
  assert.equal(secondRetry.cancelled, true);
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
  timers.at(-1).callback();
  FakeSocket.instances[1].open();
  connection.markStable();
  FakeSocket.instances[1].disconnect();
  assert.equal(timers.at(-1).delay, 500);
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
    ["a", { onError: (detail, metadata) => errors.push([`a:${detail}`, metadata]) }],
    ["b", { onError: (detail, metadata) => errors.push([`b:${detail}`, metadata]) }],
    ["c", {}],
  ]);
  rejectPendingRequests(pending, "offline");
  assert.equal(pending.size, 0);
  assert.deepEqual(errors, [
    ["a:offline", { code: "connection_lost", indeterminate: true, requeue: true }],
    ["b:offline", { code: "connection_lost", indeterminate: true, requeue: true }],
  ]);
});

test("connection errors prefer the envelope error field and fall back to message", () => {
  assert.equal(connectionErrorDetail({ error: "unauthorized" }), "unauthorized");
  assert.equal(connectionErrorDetail({ error: "server failed", message: "old" }), "server failed");
  assert.equal(connectionErrorDetail({ message: "unauthorized" }), "unauthorized");
  assert.equal(connectionErrorDetail({ message: "legacy" }), "legacy");
  assert.equal(connectionErrorDetail({}), "Error");
});

test("browser heartbeat starts after negotiation and closes a half-open socket", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    capabilities: ["roster-delta", appHeartbeatCapability],
    heartbeatIntervalMs: 10,
    heartbeatTimeoutMs: 5,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.onmessage({ data: JSON.stringify({ t: "welcome", capabilities: [appHeartbeatCapability] }) });
  const heartbeatTimer = timers.find(item => item.delay === 1_000);
  assert.ok(heartbeatTimer, "interval is clamped to the safe minimum");
  heartbeatTimer.callback();
  const ping = JSON.parse(socket.sent.at(-1));
  assert.equal(ping.t, "ping");
  const deadline = timers.find(item => item.delay === 1_000 && item !== heartbeatTimer);
  assert.ok(deadline);
  deadline.callback();
  assert.equal(socket.readyState, 3);
});

test("an authenticated socket that never receives a welcome is replaced", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/client/connect",
    token: "secret",
    WebSocketClass: FakeSocket,
    welcomeTimeoutMs: 2_000,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  const welcomeTimer = timers.find(item => item.delay === 2_000);
  assert.ok(welcomeTimer, "auth starts a welcome deadline");
  welcomeTimer.callback();
  assert.equal(socket.readyState, 3, "a silent Host tunnel is abandoned");

  socket.onclose();
  timers.at(-1).callback();
  const second = FakeSocket.instances[1];
  second.open();
  second.onmessage({ data: JSON.stringify({ t: "welcome", capabilities: [] }) });
  const secondDeadline = timers.filter(item => item.delay === 2_000).at(-1);
  assert.equal(secondDeadline.cancelled, true, "a welcome ends the deadline");
});

test("an error answer also ends the welcome deadline", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/client/connect",
    token: "secret",
    WebSocketClass: FakeSocket,
    welcomeTimeoutMs: 2_000,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.onmessage({ data: JSON.stringify({ t: "error", error: "host offline", code: "host_offline" }) });
  assert.equal(timers.find(item => item.delay === 2_000).cancelled, true);
});

test("resume reconnects a closed socket immediately and throttles repeats", () => {
  FakeSocket.instances = [];
  const timers = [];
  let now = 10_000;
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
    clock: () => now,
    random: () => 0.5,
  });

  connection.start();
  FakeSocket.instances[0].open();
  FakeSocket.instances[0].disconnect();
  FakeSocket.instances[0].disconnect();
  const pendingRetry = timers.at(-1);
  assert.equal(pendingRetry.delay, 500);
  assert.equal(connection.attempt, 1);

  assert.equal(connection.resume({ resetBackoff: true }), true);
  assert.equal(pendingRetry.cancelled, true, "the pending wait is abandoned");
  assert.equal(FakeSocket.instances.length, 2);
  assert.equal(connection.attempt, 0, "a network transition starts a fresh sequence");

  FakeSocket.instances[1].disconnect();
  assert.equal(connection.resume(), false, "a second event within the window is ignored");
  now += 1_000;
  assert.equal(connection.resume(), true);
  assert.equal(FakeSocket.instances.length, 3);
});

test("resume probes an open socket instead of replacing it", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    capabilities: ["roster-delta", appHeartbeatCapability],
    heartbeatIntervalMs: 10,
    heartbeatTimeoutMs: 5,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.onmessage({ data: JSON.stringify({ t: "welcome", capabilities: [appHeartbeatCapability] }) });
  const sentBeforeResume = socket.sent.length;
  const timersBeforeResume = timers.length;

  assert.equal(connection.resume(), false);
  assert.equal(FakeSocket.instances.length, 1, "an open socket is kept");
  const ping = JSON.parse(socket.sent.at(-1));
  assert.equal(ping.t, "ping");
  assert.equal(socket.sent.length, sentBeforeResume + 1);

  // The probe already outstanding is not duplicated by another lifecycle event.
  connection.resume();
  assert.equal(socket.sent.length, sentBeforeResume + 1);

  // resume registers the probe deadline first, then re-arms the interval.
  timers[timersBeforeResume].callback();
  assert.equal(socket.readyState, 3, "an unanswered probe closes the stale socket");
});

test("a host offline error explains itself with the Host name and last-seen time", () => {
  const now = Date.parse("2026-01-01T12:00:00Z");
  assert.equal(hostOfflineDetail({ code: "other" }, now), "");
  assert.equal(
    hostOfflineDetail({ code: "host_offline", host_name: "Mac", last_seen_at: "2026-01-01T11:57:00Z" }, now),
    "Mac is offline · last seen 3 minutes ago",
  );
  assert.equal(
    hostOfflineDetail({ code: "host_offline", last_seen_at: "not-a-date" }, now),
    "Host is offline",
  );
  assert.equal(hostOfflineDetail({ code: "host_offline", host_name: "  " }, now), "Host is offline");
});

test("the waiting notice names the Host when it is known", () => {
  assert.equal(waitingForHostMessage("Mac"), "Waiting for Mac…");
  assert.equal(waitingForHostMessage("  Mac mini  "), "Waiting for Mac mini…");
  assert.equal(waitingForHostMessage(""), "Waiting for the Host…");
  assert.equal(waitingForHostMessage("   "), "Waiting for the Host…");
  assert.equal(waitingForHostMessage(undefined), "Waiting for the Host…");
  // The notice replaces "Authenticating…" only after that claim stops being
  // plausible, and must stay well inside Relay's own wait for the Host.
  assert.ok(hostWaitCopyDelayMs >= 1_000 && hostWaitCopyDelayMs <= 5_000);
  // It also has to land inside the settle grace: the grace is already counting
  // down from the socket that died, so a copy that arrives after the promotion
  // is only ever read as "interrupted · Authenticating…".
  assert.ok(hostWaitCopyDelayMs < connectionSettleGraceMs);
});

// A Host that dies mid-session leaves the client waiting on an authenticated
// socket for the whole time Relay holds it. Rewriting the reason must not
// postpone the deadline, or a reconnect loop would keep the stale copy.
test("the waiting copy rewrites the reason without re-arming the grace", () => {
  const presenter = new ConnectionPresenter();
  presenter.unsettled("Reconnecting…");
  presenter.unsettled("Connecting…");
  presenter.unsettled("Authenticating…");
  const waiting = waitingForHostMessage("Mac");
  presenter.unsettled(waiting);
  assert.equal(presenter.state, connectionSettling);
  assert.equal(presenter.detail, waiting);
});

test("relative time labels stay short and read naturally", () => {
  assert.equal(relativeTimeLabel(0), "just now");
  assert.equal(relativeTimeLabel(44_000), "just now");
  assert.equal(relativeTimeLabel(50_000), "50 seconds ago");
  assert.equal(relativeTimeLabel(60_000), "1 minute ago");
  assert.equal(relativeTimeLabel(3 * 60_000), "3 minutes ago");
  assert.equal(relativeTimeLabel(2 * 3_600_000), "2 hours ago");
  assert.equal(relativeTimeLabel(5 * 86_400_000), "5 days ago");
});

test("browser heartbeat accepts only the matching pong", () => {
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
  });
  connection.pendingHeartbeatID = "ping-1";
  assert.equal(connection.acceptHeartbeat({ t: "pong", id: "other" }), false);
  assert.equal(connection.acceptHeartbeat({ t: "pong", id: "ping-1" }), true);
  assert.equal(connection.pendingHeartbeatID, null);
});

test("inbound data satisfies the probe so a busy stream is not closed", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    capabilities: ["roster-delta", appHeartbeatCapability],
    heartbeatIntervalMs: 10,
    heartbeatTimeoutMs: 5,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.onmessage({ data: JSON.stringify({ t: "welcome", capabilities: [appHeartbeatCapability] }) });

  // Probe goes out, then terminal output arrives instead of a pong. The Host
  // answers control requests one at a time per stream, so a slow request can
  // delay the pong past its deadline while output keeps flowing.
  const deadlineBefore = timers.length;
  connection.sendHeartbeatProbe();
  assert.equal(JSON.parse(socket.sent.at(-1)).t, "ping");
  socket.onmessage({ data: JSON.stringify({ t: "roster", state: {} }) });

  // The probe deadline was cancelled by the data, so firing it is a no-op.
  timers[deadlineBefore].callback();
  assert.equal(socket.readyState, 1, "data kept the socket alive");
  assert.equal(connection.pendingHeartbeatID, null);
});

test("a silent socket is still closed once its probe deadline expires", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    capabilities: ["roster-delta", appHeartbeatCapability],
    heartbeatIntervalMs: 10,
    heartbeatTimeoutMs: 5,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.onmessage({ data: JSON.stringify({ t: "welcome", capabilities: [appHeartbeatCapability] }) });
  const deadlineBefore = timers.length;
  connection.sendHeartbeatProbe();
  timers[deadlineBefore].callback();
  assert.equal(socket.readyState, 3, "silence still closes a half-open socket");
});

test("resume re-arms a stale probe deadline instead of firing it", () => {
  FakeSocket.instances = [];
  const timers = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    capabilities: ["roster-delta", appHeartbeatCapability],
    heartbeatIntervalMs: 10,
    heartbeatTimeoutMs: 5,
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.onmessage({ data: JSON.stringify({ t: "welcome", capabilities: [appHeartbeatCapability] }) });

  // A probe is outstanding when the tab is frozen.
  const staleDeadline = timers.length;
  connection.sendHeartbeatProbe();
  const probeID = connection.pendingHeartbeatID;
  const sentBeforeResume = socket.sent.length;
  const timersBeforeResume = timers.length;

  // Returning to the foreground must not duplicate the probe, and must not let
  // the deadline computed before the freeze close a socket that just came back.
  connection.resume();
  assert.equal(socket.sent.length, sentBeforeResume, "the probe is not duplicated");
  assert.equal(connection.pendingHeartbeatID, probeID, "the probe keeps its identity");
  // The deadline computed before the freeze is cancelled, so the backlog of
  // timers a browser releases on unfreeze can no longer close this socket.
  assert.equal(timers[staleDeadline].cancelled, true, "the stale deadline was cancelled");
  assert.equal(socket.readyState, 1, "the socket survived returning to the foreground");

  // resume arms the replacement deadline first, then re-arms the interval, so
  // the timeout is still enforced for the same probe.
  timers[timersBeforeResume].callback();
  assert.equal(socket.readyState, 3, "an unanswered probe still closes the socket");
});

test("a late pong that data already answered is not surfaced to the application", () => {
  FakeSocket.instances = [];
  const timers = [];
  const received = [];
  const connection = new WarrenConnection({
    url: "ws://relay/v1/ws",
    token: "secret",
    WebSocketClass: FakeSocket,
    capabilities: ["roster-delta", appHeartbeatCapability],
    heartbeatIntervalMs: 10,
    heartbeatTimeoutMs: 5,
    onMessage: event => received.push(event.data),
    setTimer: (callback, delay) => {
      timers.push({ callback, delay, cancelled: false });
      return timers.length - 1;
    },
    clearTimer: id => { timers[id].cancelled = true; },
  });
  connection.start();
  const socket = FakeSocket.instances[0];
  socket.open();
  socket.onmessage({ data: JSON.stringify({ t: "welcome", capabilities: [appHeartbeatCapability] }) });
  connection.sendHeartbeatProbe();
  const probeID = connection.pendingHeartbeatID;
  received.length = 0;

  socket.onmessage({ data: JSON.stringify({ t: "roster", state: {} }) });
  socket.onmessage({ data: JSON.stringify({ t: "pong", id: probeID }) });
  assert.deepEqual(
    received.map(value => JSON.parse(value).t),
    ["roster"],
    "the stale pong is swallowed, not delivered as an unknown message",
  );
});

// A controllable clock for the presenter: `run()` fires the timers a virtual
// advance would have fired, so grace-period rules are tested without waiting.
function fakeTimers() {
  const timers = new Map();
  let nextID = 1;
  let now = 0;
  return {
    setTimer(callback, delay) {
      const id = nextID++;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    clearTimer(id) { timers.delete(id); },
    advance(milliseconds) {
      now += milliseconds;
      for (const [id, timer] of [...timers.entries()]) {
        if (timer.at <= now) {
          timers.delete(id);
          timer.callback();
        }
      }
    },
    get pending() { return timers.size; },
  };
}

function presenterUnderTest(timers) {
  const changes = [];
  const presenter = new ConnectionPresenter({
    onChange: change => changes.push(change),
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
  });
  return { presenter, changes };
}

test("a sub-second flap never reaches the user", () => {
  const timers = fakeTimers();
  const { presenter, changes } = presenterUnderTest(timers);
  presenter.live();
  changes.length = 0;

  presenter.unsettled("Reconnecting…");
  timers.advance(900);
  presenter.live();
  timers.advance(5_000);

  assert.equal(presenter.state, connectionLive);
  assert.deepEqual(
    changes.map(change => change.state),
    [connectionSettling, connectionLive],
    "the dot breathes and settles; no interruption is ever announced",
  );
});

test("a loss that outlasts the grace period is announced with its reason", () => {
  const timers = fakeTimers();
  const { presenter, changes } = presenterUnderTest(timers);
  presenter.live();
  changes.length = 0;

  presenter.unsettled("Reconnecting…");
  timers.advance(connectionSettleGraceMs);

  assert.equal(presenter.state, connectionInterrupted);
  assert.deepEqual(changes.at(-1), { state: connectionInterrupted, detail: "Reconnecting…" });
});

test("a reconnect that succeeds inside the grace period stays silent", () => {
  const timers = fakeTimers();
  const { presenter, changes } = presenterUnderTest(timers);
  presenter.live();
  changes.length = 0;

  // A measured worst case against a real Relay over a 160ms RTT link: the
  // socket is replaced end to end in 1.3s. The user must not see a banner for
  // a recovery that was already working.
  presenter.unsettled("Reconnecting…");
  timers.advance(1_300);
  presenter.live();

  assert.deepEqual(
    changes.map(change => change.state),
    [connectionSettling, connectionLive],
  );
});

test("a reconnect loop cannot postpone the notice forever", () => {
  const timers = fakeTimers();
  const { presenter } = presenterUnderTest(timers);
  presenter.live();

  // Each failed attempt reports unsettled again. Re-arming the deadline every
  // time would hide an outage for as long as the backoff keeps trying.
  const attempts = Math.ceil(connectionSettleGraceMs / 400) + 1;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    presenter.unsettled("Reconnecting…");
    timers.advance(400);
  }

  assert.equal(presenter.state, connectionInterrupted);
});

test("host_offline skips the grace period", () => {
  const timers = fakeTimers();
  const { presenter, changes } = presenterUnderTest(timers);
  presenter.live();
  changes.length = 0;

  // Relay already waited ~15s for the Host before saying this.
  presenter.lost("Mac is offline · last seen 3 minutes ago");

  assert.equal(presenter.state, connectionInterrupted);
  assert.equal(presenter.detail, "Mac is offline · last seen 3 minutes ago");
  assert.equal(timers.pending, 0, "no deadline is left armed behind a known absence");
});

test("recovery from an announced interruption is immediate", () => {
  const timers = fakeTimers();
  const { presenter, changes } = presenterUnderTest(timers);
  presenter.lost("unauthorized");
  changes.length = 0;

  presenter.live();

  assert.equal(presenter.state, connectionLive);
  assert.deepEqual(changes, [{ state: connectionLive, detail: "" }]);
});

test("a generic retry does not overwrite a specific reason", () => {
  const timers = fakeTimers();
  const { presenter } = presenterUnderTest(timers);
  presenter.lost("Mac is offline · last seen 3 minutes ago");

  presenter.unsettled("Reconnecting…");

  assert.equal(presenter.state, connectionInterrupted, "already told; stay told until live");
  assert.equal(presenter.detail, "Mac is offline · last seen 3 minutes ago");
});

test("a cold start is settling, so the first connect cannot flash Offline", () => {
  const timers = fakeTimers();
  const { presenter, changes } = presenterUnderTest(timers);

  assert.equal(presenter.state, connectionSettling);
  presenter.unsettled("Connecting…");
  timers.advance(900);
  presenter.live();

  assert.deepEqual(
    changes.map(change => change.state),
    [connectionLive],
    "nothing is published before the connection is usable",
  );
});
