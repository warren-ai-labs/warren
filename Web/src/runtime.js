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
const tokenStorageKey = usesControlPlane
  ? `warren.accessToken.${relayHostID}`
  : "warren.accessToken";
const suppliedToken = authFragment?.get("t") || "";

if (suppliedToken) localStorage.setItem(tokenStorageKey, suppliedToken);

export const runtime = {
  relayHostID,
  usesControlPlane,
  token: suppliedToken || localStorage.getItem(tokenStorageKey) || "",
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
    ? `/v1/client/connect?host_id=${encodeURIComponent(relayHostID)}`
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
