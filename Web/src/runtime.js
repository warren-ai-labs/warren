const parameterMeta = document.querySelector('meta[name="warren-injected-params"]');
const relayHostMeta = document.querySelector('meta[name="warren-relay-host-id"]');

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
const usesControlPlane = !relayHostID.startsWith("__WARREN_");
// The daemon can serve the UI from a path prefix (for example gnar's
// /t/<name>), so app-level URLs must resolve relative to the current
// directory instead of the origin root.
const appBase = location.pathname.endsWith("/")
  ? location.pathname
  : `${location.pathname}/`;
const suppliedToken = authFragment?.get("t") || "";
const memoryToken = { value: "" };
const tokenStorageKey = usesControlPlane ? "" : "warren.accessToken";
if (!usesControlPlane) {
  memoryToken.value = suppliedToken || (() => {
    try {
      return localStorage.getItem(tokenStorageKey) || "";
    } catch {
      return "";
    }
  })();
  if (suppliedToken) {
    try {
      localStorage.setItem(tokenStorageKey, suppliedToken);
    } catch {
      // Storage may be unavailable in private or embedded browser contexts.
    }
  }
}

const relaySessionBase = usesControlPlane
  ? `/h/${encodeURIComponent(relayHostID)}/v1/session`
  : "";

// Relay links carry a one-time pairing ticket in the fragment. Exchange it
// immediately over HTTPS and scrub the URL before rendering or navigating;
// only the short-lived access capability remains in memory. The fallback keeps
// old #t=<access-token> links working during the migration window without
// persisting their value.
export const tokenReady = usesControlPlane
  ? (suppliedToken
      ? fetch(`${relaySessionBase}/exchange`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          credentials: "include",
          body: JSON.stringify({ pairing_ticket: suppliedToken }),
        })
          .then(response => (response.ok ? response.json() : Promise.reject(new Error("ticket exchange failed"))))
          .then(result => {
            memoryToken.value = result.access_token || "";
            return memoryToken.value;
          })
          .catch(() => {
            // A pairing ticket is one-use state, not a client capability. Do
            // not send it to the WebSocket endpoint when exchange fails. The
            // dotted shape is retained only for the old access-token fragment
            // compatibility window.
            memoryToken.value = suppliedToken.includes(".") ? suppliedToken : "";
            return memoryToken.value;
          })
      : refreshRelayToken().catch(() => ""))
  : Promise.resolve("");

export async function refreshRelayToken() {
  if (!usesControlPlane) return memoryToken.value;
  const response = await fetch(`${relaySessionBase}/refresh`, {
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
  relayHostID,
  usesControlPlane,
  get token() { return memoryToken.value; },
  set token(value) {
    memoryToken.value = value || "";
    if (!usesControlPlane && tokenStorageKey) {
      try {
        if (memoryToken.value) localStorage.setItem(tokenStorageKey, memoryToken.value);
        else localStorage.removeItem(tokenStorageKey);
      } catch {
        // Storage may be unavailable in private or embedded browser contexts.
      }
    }
  },
  tokenReady,
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
    ? `/h/${encodeURIComponent(relayHostID)}/v1/client/connect`
    : `${appBase}v1/ws`;
  return `${protocol}//${host}${port ? `:${port}` : ""}${path}`;
}

export function serviceWorkerURL() {
  return usesControlPlane
    ? `/h/${encodeURIComponent(relayHostID)}/service-worker.js`
    : `${appBase}service-worker.js`;
}

export function webAssetURL(name) {
  const resource = String(name).replace(/^\/+/, "");
  return usesControlPlane
    ? `/h/${encodeURIComponent(relayHostID)}/${resource}`
    : `${appBase}${resource}`;
}
