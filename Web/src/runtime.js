const parameterMeta = document.querySelector('meta[name="warren-injected-params"]');
const relayHostMeta = document.querySelector('meta[name="warren-relay-host-id"]');
const relayInviteMeta = document.querySelector('meta[name="warren-relay-invite-id"]');

const injectedParams = parameterMeta?.content || "__WARREN_INJECTED_PARAMS__";
const hasInjectedParams = !injectedParams.startsWith("__WARREN_");
const params = new URLSearchParams(
  (hasInjectedParams ? injectedParams : location.search).replace(/^[?#]/, ""),
);
// Warren navigation lives in the query string, while the Web auth token
// intentionally remains in the fragment. Do not let navigation state hide or
// replace the token when both are present in a public URL.
const authFragment = location.hash.startsWith("#t=")
  ? new URLSearchParams(location.hash.slice(1))
  : null;
const relayHostID = relayHostMeta?.content || "__WARREN_RELAY_HOST_ID__";
const relayInviteID = relayInviteMeta?.content || "__WARREN_RELAY_INVITE_ID__";
const hasRelayHostID = !relayHostID.startsWith("__WARREN_");
const hasRelayInviteID = !relayInviteID.startsWith("__WARREN_");
const usesControlPlane = hasRelayHostID || hasRelayInviteID;
// A Relay may be mounted below a reverse-proxy path prefix (for example
// /relay). Preserve that prefix for every browser request; absolute root URLs
// would otherwise escape the mounted Relay and lose the host namespace.
const relayInvitePath = hasRelayInviteID ? `/invite/${encodeURIComponent(relayInviteID)}` : "";
const relayHostPath = hasRelayHostID ? `/h/${encodeURIComponent(relayHostID)}` : "";
const relayScopePath = relayInvitePath || relayHostPath;
const relayPathPrefix = usesControlPlane
  ? (() => {
      const marker = relayScopePath;
      const index = location.pathname.indexOf(marker);
      return index >= 0 ? location.pathname.slice(0, index).replace(/\/+$/, "") : "";
    })()
  : "";
const relayPath = (value) => `${relayPathPrefix}/${String(value).replace(/^\/+/, "")}`;
// The daemon can serve the UI from a path prefix (for example a Relay route's
// /t/<name>), so app-level URLs must resolve relative to the current
// directory instead of the origin root.
const appBase = location.pathname.endsWith("/")
  ? location.pathname
  : `${location.pathname}/`;
const suppliedToken = authFragment?.get("t") || "";
const memoryToken = { value: "" };
if (!usesControlPlane) memoryToken.value = suppliedToken;
let resolvedRelayHostID = hasRelayHostID ? relayHostID : "";

const relayClientID = (() => {
  const fallback = () => globalThis.crypto?.randomUUID?.() || `web-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  try {
    const storageKey = "warren.relay.client-id";
    if (!globalThis.localStorage?.getItem || !globalThis.localStorage?.setItem) return fallback();
    const existing = globalThis.localStorage?.getItem(storageKey);
    if (existing) return existing;
    const value = fallback();
    globalThis.localStorage?.setItem(storageKey, value);
    return value;
  } catch {
    return fallback();
  }
})();

const relaySessionBase = () => usesControlPlane
  ? relayPath(`${relayScopePath}/v1/session`)
  : "";

// Relay links carry a shareable pairing ticket in the fragment. Exchange it
// immediately over HTTPS and scrub the URL before rendering or navigating;
// only the short-lived access capability remains in memory. The ticket remains
// valid for the Relay's configured sharing window so another device can use
// the same link.
export const tokenReady = usesControlPlane
  ? (hasRelayInviteID
      ? fetch(`${relaySessionBase()}/exchange`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({ invite_id: relayInviteID, client_id: relayClientID }),
        })
          .then(response => (response.ok ? response.json() : Promise.reject(new Error("invite exchange failed"))))
          .then(result => {
            if (!result.host_id) throw new Error("invite exchange returned no Host");
            resolvedRelayHostID = result.host_id;
            memoryToken.value = result.access_token || "";
            return memoryToken.value;
          })
          .catch(() => {
            memoryToken.value = "";
            return memoryToken.value;
          })
      : (suppliedToken
      ? fetch(`${relaySessionBase()}/exchange`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({ pairing_ticket: suppliedToken, client_id: relayClientID }),
        })
          .then(response => (response.ok ? response.json() : Promise.reject(new Error("ticket exchange failed"))))
          .then(result => {
            memoryToken.value = result.access_token || "";
            return memoryToken.value;
          })
          .catch(() => {
            memoryToken.value = "";
            return memoryToken.value;
          })
      : refreshRelayToken().catch(() => "")))
  : Promise.resolve("");

export async function refreshRelayToken() {
  if (!usesControlPlane) return memoryToken.value;
  const response = await fetch(`${relaySessionBase()}/refresh`, {
    method: "POST",
    credentials: "include",
  });
  if (!response.ok) throw new Error("refresh capability failed");
  const result = await response.json();
  memoryToken.value = result.access_token || "";
  return memoryToken.value;
}

if (typeof history !== "undefined" && suppliedToken) {
  const clean = `${location.pathname}${location.search}`;
  history.replaceState(history.state, document.title, clean);
}

export const runtime = {
  get relayHostID() { return resolvedRelayHostID; },
  relayInviteID: hasRelayInviteID ? relayInviteID : "",
  usesControlPlane,
  get token() { return memoryToken.value; },
  set token(value) {
    memoryToken.value = value || "";
  },
  tokenReady,
  get clientID() { return relayClientID; },
  refresh: refreshRelayToken,
};

export function webSocketURL() {
  const hostParam = params.get("host");
  const protocol = usesControlPlane
    ? (location.protocol === "https:" ? "wss:" : "ws:")
    : (hostParam ? "wss:" : (location.protocol === "https:" ? "wss:" : "ws:"));
  const host = usesControlPlane
    ? location.host
    : (hostParam || location.hostname || "127.0.0.1");
  const port = usesControlPlane || hostParam ? "" : (location.port || "8789");
  const path = usesControlPlane
    ? relayPath(`${resolvedRelayHostID ? `/h/${encodeURIComponent(resolvedRelayHostID)}` : ""}/v1/client/connect`)
    : `${appBase}v1/ws`;
  return `${protocol}//${host}${port ? `:${port}` : ""}${path}`;
}

export function serviceWorkerURL() {
  return usesControlPlane
    ? relayPath(`${relayScopePath}/service-worker.js`)
    : `${appBase}service-worker.js`;
}

export function webAssetURL(name) {
  const resource = String(name).replace(/^\/+/, "");
  return usesControlPlane
    ? relayPath(`${relayScopePath}/${resource}`)
    : `${appBase}${resource}`;
}
