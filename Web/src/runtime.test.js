import assert from "node:assert/strict";
import test from "node:test";

test("Relay runtime preserves a reverse-proxy path prefix", async () => {
  globalThis.document = {
    querySelector(selector) {
      if (selector === 'meta[name="warren-relay-host-id"]') {
        return { content: "00000000-0000-4000-8000-000000000001" };
      }
      return { content: "" };
    },
  };
  globalThis.location = {
    pathname: "/relay/h/00000000-0000-4000-8000-000000000001/",
    search: "",
    hash: "",
    protocol: "https:",
    host: "relay.example.test",
    hostname: "relay.example.test",
    port: "",
  };
  globalThis.history = { replaceState() {} };
  globalThis.fetch = async () => ({
    ok: true,
    json: async () => ({ access_token: "" }),
  });

  const runtime = await import(`./runtime.js?prefix-test=${Date.now()}`);
  assert.equal(
    runtime.webSocketURL(),
    "wss://relay.example.test/relay/h/00000000-0000-4000-8000-000000000001/v1/client/connect",
  );
  assert.equal(
    runtime.serviceWorkerURL(),
    "/relay/h/00000000-0000-4000-8000-000000000001/service-worker.js",
  );
  assert.equal(
    runtime.webAssetURL("/assets/app.js"),
    "/relay/h/00000000-0000-4000-8000-000000000001/assets/app.js",
  );
});

test("opaque Relay invite exchanges before opening a Host-scoped socket", async () => {
  const inviteID = "Abc_123-def";
  const requests = [];
  globalThis.document = {
    querySelector(selector) {
      if (selector === 'meta[name="warren-relay-invite-id"]') {
        return { content: inviteID };
      }
      return { content: "" };
    },
  };
  globalThis.location = {
    pathname: `/relay/invite/${inviteID}/`,
    search: "",
    hash: "",
    protocol: "https:",
    host: "relay.example.test",
    hostname: "relay.example.test",
    port: "",
  };
  globalThis.history = { replaceState() {} };
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options });
    return {
      ok: true,
      json: async () => ({
        host_id: "00000000-0000-4000-8000-000000000001",
        access_token: "memory-only",
      }),
    };
  };

  const runtime = await import(`./runtime.js?invite-test=${Date.now()}`);
  await runtime.tokenReady;
  assert.equal(
    requests[0].url,
    "/relay/invite/Abc_123-def/v1/session/exchange",
  );
  const exchangeBody = JSON.parse(requests[0].options.body);
  assert.equal(exchangeBody.invite_id, inviteID);
  assert.equal(typeof exchangeBody.client_id, "string");
  assert.ok(exchangeBody.client_id.length > 0);
  assert.equal(runtime.runtime.relayHostID, "00000000-0000-4000-8000-000000000001");
  assert.equal(
    runtime.webSocketURL(),
    "wss://relay.example.test/relay/h/00000000-0000-4000-8000-000000000001/v1/client/connect",
  );
  assert.equal(
    runtime.serviceWorkerURL(),
    "/relay/invite/Abc_123-def/service-worker.js",
  );
});

test("parseAuthInput handles URLs, fragments, and raw tokens", async () => {
  const { parseAuthInput } = await import(`./runtime.js?parse-test=${Date.now()}`);

  assert.deepEqual(parseAuthInput(""), { token: "", url: null });
  assert.deepEqual(parseAuthInput(null), { token: "", url: null });
  assert.deepEqual(parseAuthInput("my-raw-token"), { token: "my-raw-token", url: null });
  assert.deepEqual(parseAuthInput("#t=fragment-token"), { token: "fragment-token", url: null });
  assert.deepEqual(parseAuthInput("t=param-token"), { token: "param-token", url: null });
  assert.deepEqual(parseAuthInput("?t=query-token"), { token: "query-token", url: null });
  assert.deepEqual(parseAuthInput("  #t=trimmed-token  "), { token: "trimmed-token", url: null });

  const parsedUrl = parseAuthInput("http://127.0.0.1:8789/#t=url-token");
  assert.equal(parsedUrl.token, "url-token");
  assert.ok(parsedUrl.url instanceof URL);
  assert.equal(parsedUrl.url.origin, "http://127.0.0.1:8789");

  const parsedQueryUrl = parseAuthInput("https://remote.warren.test:9000/?t=query-url-token");
  assert.equal(parsedQueryUrl.token, "query-url-token");
  assert.ok(parsedQueryUrl.url instanceof URL);
});

test("direct daemon runtime persists and restores token from storage across reloads", async () => {
  const mockStorage = new Map();
  globalThis.document = {
    querySelector() {
      return { content: "" };
    },
  };
  globalThis.sessionStorage = {
    getItem(key) { return mockStorage.get(key) || null; },
    setItem(key, value) { mockStorage.set(key, String(value)); },
    removeItem(key) { mockStorage.delete(key); },
  };
  globalThis.localStorage = {
    getItem(key) { return mockStorage.get(key) || null; },
    setItem(key, value) { mockStorage.set(key, String(value)); },
    removeItem(key) { mockStorage.delete(key); },
  };
  globalThis.location = {
    pathname: "/",
    search: "",
    hash: "#t=initial-secret-token",
    protocol: "http:",
    host: "127.0.0.1:8789",
    hostname: "127.0.0.1",
    port: "8789",
  };
  globalThis.history = { replaceState() {} };

  // 1. Initial load with #t= token in URL fragment
  const firstLoad = await import(`./runtime.js?direct-test-1=${Date.now()}`);
  assert.equal(firstLoad.runtime.token, "initial-secret-token");
  assert.equal(mockStorage.get("warren.daemon.token"), "initial-secret-token");

  // 2. Simulated reload: URL fragment is now scrubbed (#t= gone)
  globalThis.location.hash = "";
  const reload = await import(`./runtime.js?direct-test-2=${Date.now()}`);
  assert.equal(reload.runtime.token, "initial-secret-token");

  // 3. Clear token on unauthorized error
  reload.runtime.clearToken();
  assert.equal(reload.runtime.token, "");
  assert.equal(mockStorage.get("warren.daemon.token"), undefined);

  // 4. Update runtime token manually (e.g. from reconnect input)
  reload.runtime.token = "new-recovered-token";
  assert.equal(reload.runtime.token, "new-recovered-token");
  assert.equal(mockStorage.get("warren.daemon.token"), "new-recovered-token");
});
