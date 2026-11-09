import assert from "node:assert/strict";
import test from "node:test";

import {
  boltholeWebSocketClass,
  pairRemote,
  parseRemoteLink,
  readRemoteProfile,
  remoteConnectionString,
  writeRemoteProfile,
} from "./remote.js";

const code = "A".repeat(43);

function memoryStorage() {
  const values = new Map();
  return {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: key => values.delete(key),
  };
}

test("a hosted link names its relay in the fragment", () => {
  const link = parseRemoteLink(
    `https://app.warrenai.xyz/#r=${encodeURIComponent("https://relay.example.com/")}&k=${code}&host=h1&invite=inv&name=Studio`,
    "https://app.warrenai.xyz",
  );
  assert.deepEqual(link, {
    relayURL: "https://relay.example.com",
    connectCode: code,
    hostID: "h1",
    invite: "inv",
    hostName: "Studio",
  });
});

test("the app's QR link is its own relay", () => {
  const link = parseRemoteLink(`https://relay.example.com/#k=${code}&host=h1&invite=inv`, "https://app.warrenai.xyz");
  assert.equal(link.relayURL, "https://relay.example.com");
  assert.equal(link.invite, "inv");
});

test("a link without a relay, code or Host is not a remote link", () => {
  const origin = "https://app.warrenai.xyz";
  assert.equal(parseRemoteLink(`https://app.warrenai.xyz/#k=${code}&host=h1`, origin), null);
  assert.equal(parseRemoteLink("https://relay.example.com/#k=short&host=h1", origin), null);
  assert.equal(parseRemoteLink(`https://relay.example.com/#k=${code}`, origin), null);
  assert.equal(parseRemoteLink("https://host.local:8789/#t=token", origin), null);
  assert.equal(parseRemoteLink("not a url", origin), null);
  assert.equal(parseRemoteLink(`https://app.warrenai.xyz/#r=ftp%3A%2F%2Fx&k=${code}&host=h1`, origin), null);
});

test("the connection string carries only the relay and the code", () => {
  assert.equal(
    remoteConnectionString({ relayURL: "https://relay.example.com", connectCode: code }),
    `https://relay.example.com/#k=${code}`,
  );
});

test("a profile survives a reload and can be forgotten", () => {
  const storage = memoryStorage();
  const profile = { relayURL: "https://relay.example.com", connectCode: code, hostID: "h1", hostName: "Studio", token: "tok" };
  writeRemoteProfile(profile, storage);
  assert.deepEqual(readRemoteProfile(storage), profile);
  writeRemoteProfile(null, storage);
  assert.equal(readRemoteProfile(storage), null);
});

test("a malformed profile is ignored", () => {
  const storage = memoryStorage();
  storage.setItem("warren.remote.profile", JSON.stringify({ relayURL: "https://r", connectCode: "x", hostID: "h" }));
  assert.equal(readRemoteProfile(storage), null);
  storage.setItem("warren.remote.profile", "{");
  assert.equal(readRemoteProfile(storage), null);
});

function fakeResponse(status, body) {
  return { status, ok: status >= 200 && status < 300, json: async () => body };
}

test("pairing sends the invite and returns the device token", async () => {
  let request;
  const client = {
    fetch: async (path, init) => {
      request = { path, ...init, body: JSON.parse(init.body) };
      return fakeResponse(200, { token: "device-token" });
    },
  };
  const token = await pairRemote(client, { hostID: "h1", invite: "inv", clientID: "c1", clientName: "Warren Web (Mac)" });
  assert.equal(token, "device-token");
  assert.equal(request.path, "/v1/pairing/request");
  assert.equal(request.method, "POST");
  assert.deepEqual(request.body, { host_id: "h1", client_id: "c1", invite: "inv", client_name: "Warren Web (Mac)" });
});

test("an expired invite says so", async () => {
  const client = { fetch: async () => fakeResponse(409, {}) };
  await assert.rejects(
    pairRemote(client, { hostID: "h1", invite: "inv", clientID: "c1" }),
    error => error.status === 409 && /expired/.test(error.message),
  );
  await assert.rejects(pairRemote(client, { hostID: "h1", invite: "", clientID: "c1" }), /cannot pair/);
});

function fakeStream(messages) {
  const sent = [];
  let closed = false;
  const queue = [...messages];
  let wake = null;
  return {
    sent,
    get closed() { return closed; },
    push(message) {
      queue.push(message);
      wake?.();
    },
    async read() {
      while (!queue.length) await new Promise(resolve => { wake = resolve; });
      return queue.shift();
    },
    async send(payload) { sent.push(payload); },
    async close() { closed = true; },
    closeInfo: null,
  };
}

const tick = () => new Promise(resolve => setTimeout(resolve, 0));

test("a Bolthole stream looks like a WebSocket to WarrenConnection", async () => {
  const stream = fakeStream([{ text: "{\"t\":\"welcome\"}" }, { data: new Uint8Array([1, 2, 3]) }]);
  let closes = 0;
  const client = { websocket: async path => (assert.equal(path, "/v1/ws"), stream), close: () => closes++ };
  const Socket = boltholeWebSocketClass(() => client);
  const socket = new Socket("bolthole://h1/v1/ws");
  const events = [];
  socket.onopen = () => events.push("open");
  socket.onmessage = event => events.push(event.data);
  socket.onclose = event => events.push(`close ${event.code}`);
  assert.equal(socket.readyState, Socket.CONNECTING);
  await tick();
  await tick();
  assert.equal(socket.readyState, Socket.OPEN);
  assert.equal(events[0], "open");
  assert.equal(events[1], "{\"t\":\"welcome\"}");
  assert.deepEqual([...new Uint8Array(events[2])], [1, 2, 3]);

  socket.send("{\"t\":\"auth\"}");
  socket.send(new Uint8Array([9]).buffer);
  assert.equal(stream.sent[0], "{\"t\":\"auth\"}");
  assert.deepEqual([...stream.sent[1]], [9]);

  socket.close();
  assert.equal(socket.readyState, Socket.CLOSED);
  assert.ok(stream.closed);
  assert.equal(closes, 1, "a local close drops the session so the next socket redials");
  assert.equal(events.at(-1), "close 1000");
});

test("a peer close keeps the session for the next socket", async () => {
  const stream = fakeStream([null]);
  stream.closeInfo = { code: 4001, reason: "" };
  let closes = 0;
  const Socket = boltholeWebSocketClass(() => ({ websocket: async () => stream, close: () => closes++ }));
  const socket = new Socket();
  const codes = [];
  socket.onclose = event => codes.push(event.code);
  await tick();
  await tick();
  assert.deepEqual(codes, [4001]);
  assert.equal(closes, 0);
});

test("a failed dial closes the socket abnormally and redials next time", async () => {
  let closes = 0;
  const Socket = boltholeWebSocketClass(() => ({
    websocket: async () => { throw new Error("unreachable"); },
    close: () => closes++,
  }));
  const socket = new Socket();
  const codes = [];
  socket.onclose = event => codes.push(event.code);
  await tick();
  assert.deepEqual(codes, [1006]);
  assert.equal(closes, 1);
  assert.equal(socket.readyState, Socket.CLOSED);
});

test("closing before the stream opens reports one close and discards the stream", async () => {
  const stream = fakeStream([]);
  let resolveOpen;
  const Socket = boltholeWebSocketClass(() => ({
    websocket: () => new Promise(resolve => { resolveOpen = resolve; }),
    close: () => {},
  }));
  const socket = new Socket();
  const codes = [];
  socket.onclose = event => codes.push(event.code);
  socket.onopen = () => codes.push("open");
  socket.close();
  resolveOpen(stream);
  await tick();
  assert.deepEqual(codes, [1000]);
  assert.ok(stream.closed);
});
