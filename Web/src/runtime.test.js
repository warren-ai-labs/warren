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
