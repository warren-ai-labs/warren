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
