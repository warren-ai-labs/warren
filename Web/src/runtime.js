import {
  boltholeWebSocketClass,
  createRemoteClient,
  pairRemote,
  parseRemoteLink,
  readRemoteProfile,
  writeRemoteProfile,
} from "./remote.js";

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

export { hasRelayHostID, hasRelayInviteID };
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
const daemonTokenStorageKey = "warren.daemon.token";

export function readStoredDaemonToken() {
  try {
    return (
      globalThis.sessionStorage?.getItem?.(daemonTokenStorageKey) ||
      globalThis.localStorage?.getItem?.(daemonTokenStorageKey) ||
      ""
    );
  } catch {
    return "";
  }
}

export function persistDaemonToken(token) {
  try {
    if (token) {
      globalThis.sessionStorage?.setItem?.(daemonTokenStorageKey, token);
      globalThis.localStorage?.setItem?.(daemonTokenStorageKey, token);
    } else {
      globalThis.sessionStorage?.removeItem?.(daemonTokenStorageKey);
      globalThis.localStorage?.removeItem?.(daemonTokenStorageKey);
    }
  } catch {
    // Restricted environments may disallow storage access.
  }
}

// Serverless remote access: a share link in the fragment, or the Host this
// browser paired with earlier. A profile only exists on an origin that once
// opened such a link, so a page served by a Host never enters this mode.
const remoteLink = usesControlPlane ? null : parseRemoteLink(location.href);
const remoteProfile = (() => {
  if (usesControlPlane) return null;
  const stored = readRemoteProfile();
  if (!remoteLink) return stored;
  const sameHost = stored && stored.hostID === remoteLink.hostID && stored.connectCode === remoteLink.connectCode;
  return {
    relayURL: remoteLink.relayURL,
    connectCode: remoteLink.connectCode,
    hostID: remoteLink.hostID,
    hostName: remoteLink.hostName || stored?.hostName || "",
    token: sameHost ? stored.token : "",
  };
})();
const usesRemote = Boolean(remoteProfile);
// The hosted page that remote access links open. It is never served by a
// Host, so its Welcome screen explains remote links instead of the menu bar.
export const remoteAppHostname = "app.warrenai.xyz";
let remoteClient = null;
const sharedRemoteClient = () => {
  remoteClient ??= createRemoteClient(remoteProfile);
  return remoteClient;
};
const remoteState = { error: "" };

const suppliedToken = authFragment?.get("t") || "";
const memoryToken = { value: "" };
if (usesRemote) {
  memoryToken.value = remoteProfile.token;
} else if (!usesControlPlane) {
  if (suppliedToken) {
    memoryToken.value = suppliedToken;
    persistDaemonToken(suppliedToken);
  } else {
    memoryToken.value = readStoredDaemonToken();
  }
}
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

// An invite page exchanges its opaque invite as soon as it loads, and scrubs any
// legacy fragment before rendering; only the short-lived access capability and
// the Host record id Relay returns remain in memory. The invite stays valid for
// the Relay's sharing window, so another device can use the same link.
const inviteIDPattern = /^[A-Za-z0-9_-]{1,128}$/;

// Resolves an opaque invite from a full pairing link or a bare invite id.
export function inviteIDFromInput(input) {
  const trimmed = String(input ?? "").trim().replace(/^["']|["']$/g, "");
  if (!trimmed) return "";
  const match = trimmed.match(/\/invite\/([A-Za-z0-9_-]{1,128})\/?/);
  if (match) return match[1];
  return inviteIDPattern.test(trimmed) ? trimmed : "";
}

// Exchanges one invite for a capability bound to this browser's client id.
async function exchangeInvite(inviteID) {
  const response = await fetch(
    relayPath(`/invite/${encodeURIComponent(inviteID)}/v1/session/exchange`),
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ client_id: relayClientID }),
    },
  );
  if (!response.ok) throw new Error("invite exchange failed");
  const result = await response.json();
  if (!result.host_id) throw new Error("invite exchange returned no Host");
  resolvedRelayHostID = result.host_id;
  memoryToken.value = result.access_token || "";
  return memoryToken.value;
}

function remoteClientName() {
  const agent = globalThis.navigator?.userAgent || "";
  const platform = /iPhone|iPad/.test(agent) ? "iPhone" : /Android/.test(agent) ? "Android" : /Mac/.test(agent) ? "Mac" : "browser";
  return `Warren Web (${platform})`;
}

// Exchanges the link's invite once. A browser that already holds a token for
// this Host keeps it when the invite has expired, so reopening an old link
// still connects.
async function pairRemoteHost() {
  if (!remoteLink?.invite) return memoryToken.value;
  try {
    const token = await pairRemote(sharedRemoteClient(), {
      hostID: remoteProfile.hostID,
      invite: remoteLink.invite,
      clientID: relayClientID,
      clientName: remoteClientName(),
    });
    memoryToken.value = token;
    remoteProfile.token = token;
  } catch (error) {
    if (!memoryToken.value) remoteState.error = error?.message || "Warren could not pair with this Host.";
  }
  writeRemoteProfile(remoteProfile);
  return memoryToken.value;
}

export const tokenReady = usesRemote ? pairRemoteHost() : usesControlPlane
  ? (hasRelayInviteID
    ? exchangeInvite(relayInviteID).catch(() => {
        memoryToken.value = "";
        return memoryToken.value;
      })
    : refreshRelayToken().catch(() => ""))
  : Promise.resolve(memoryToken.value);

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

export function parseAuthInput(input) {
  if (typeof input !== "string") return { token: "", url: null };
  const trimmed = input.trim().replace(/^["']|["']$/g, "");
  if (!trimmed) return { token: "", url: null };

  try {
    if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
      const url = new URL(trimmed);
      const hashParams = new URLSearchParams(url.hash.replace(/^[#]/, ""));
      const token = hashParams.get("t") || url.searchParams.get("t") || "";
      return { token, url };
    }
  } catch {
    // Fall back to parameter or raw token parsing.
  }

  if (trimmed.startsWith("#") || trimmed.startsWith("?")) {
    const params = new URLSearchParams(trimmed.slice(1));
    const token = params.get("t");
    if (token) return { token, url: null };
  } else if (trimmed.startsWith("t=")) {
    const params = new URLSearchParams(trimmed);
    const token = params.get("t");
    if (token) return { token, url: null };
  }

  return { token: trimmed, url: null };
}

// Reopens this page on a pasted remote access link in either shape, so the
// link is handled exactly as if it had been opened directly.
export function openRemoteLink(input) {
  const link = parseRemoteLink(input);
  if (!link) return false;
  const fragment = new URLSearchParams({ r: link.relayURL, k: link.connectCode, host: link.hostID });
  if (link.invite) fragment.set("invite", link.invite);
  if (link.hostName) fragment.set("name", link.hostName);
  history.replaceState(history.state, document.title, `${location.pathname}${location.search}#${fragment}`);
  location.reload();
  return true;
}

export async function authenticateToken(tokenOrTicket) {
  const token = typeof tokenOrTicket === "string" ? tokenOrTicket.trim() : "";
  if (!token) throw new Error("No token provided");
  if (usesRemote) {
    // A remote page can only be given a new share link; a bare token has no
    // encrypted session to ride on.
    throw new Error("Paste a remote access link from the Host.");
  }
  if (usesControlPlane) {
    // A Host-scoped page holds no invite, so the only thing a paste can add is
    // an invite link or id for this Relay.
    const inviteID = inviteIDFromInput(token);
    if (!inviteID) throw new Error("No pairing invite provided");
    return exchangeInvite(inviteID);
  }
  memoryToken.value = token;
  persistDaemonToken(token);
  return token;
}

if (typeof history !== "undefined" && (suppliedToken || remoteLink)) {
  const clean = `${location.pathname}${location.search}`;
  history.replaceState(history.state, document.title, clean);
}

export const runtime = {
  get relayHostID() { return resolvedRelayHostID; },
  relayInviteID: hasRelayInviteID ? relayInviteID : "",
  usesControlPlane,
  usesRemote,
  remoteApp: usesRemote || (!usesControlPlane && globalThis.location?.hostname === remoteAppHostname),
  get remoteHostName() { return remoteProfile?.hostName || ""; },
  get remoteError() { return remoteState.error; },
  // WarrenConnection's socket class: Bolthole streams on a remote page, the
  // browser's WebSocket otherwise.
  WebSocketClass: usesRemote ? boltholeWebSocketClass(sharedRemoteClient) : undefined,
  get token() { return memoryToken.value; },
  set token(value) {
    const normalized = value || "";
    memoryToken.value = normalized;
    if (usesRemote) {
      remoteProfile.token = normalized;
      writeRemoteProfile(remoteProfile);
    } else if (!usesControlPlane) {
      persistDaemonToken(normalized);
    }
  },
  tokenReady,
  get clientID() { return relayClientID; },
  refresh: refreshRelayToken,
  clearToken() {
    memoryToken.value = "";
    if (usesRemote) {
      remoteProfile.token = "";
      writeRemoteProfile(remoteProfile);
    } else if (!usesControlPlane) {
      persistDaemonToken("");
    }
  },
  authenticate: authenticateToken,
};

export function webSocketURL() {
  // A remote page has no socket URL of its own; this identifies the Host for
  // per-endpoint storage keys.
  if (usesRemote) return `bolthole://${encodeURIComponent(remoteProfile.hostID)}/v1/ws`;
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
