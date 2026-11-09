// Serverless remote access (docs/remote.md) from a browser.
//
// A Host shares a link whose fragment carries the Bolthole connect code, the
// Host ID, a pairing invite and the Host name. The fragment never reaches a
// server: this page reads it, opens an end-to-end encrypted session to the
// Host through the relay, exchanges the invite for this browser's own
// paired-client token, and then speaks the normal Warren protocol over a
// Bolthole `ws` stream. The relay only forwards ciphertext.
//
// Two link shapes are accepted:
//   https://app.warrenai.xyz/#r=<relay>&k=<code>&host=<id>&invite=<invite>&name=<name>
//   https://<relay>/#k=<code>&host=<id>&invite=<invite>&name=<name>   (the app's QR link)

import { Client } from "bolthole";

const profileStorageKey = "warren.remote.profile";
const connectCodePattern = /^[A-Za-z0-9_-]{43}$/;

function fragmentParameters(hash) {
  return new URLSearchParams(String(hash ?? "").replace(/^#/, ""));
}

function normalizeRelayURL(value) {
  try {
    const url = new URL(String(value ?? "").trim());
    if (url.protocol !== "https:" && url.protocol !== "http:") return "";
    if (url.username || url.password) return "";
    return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
  } catch {
    return "";
  }
}

/**
 * Parses a remote access link. `pageOrigin` is the origin this page is served
 * from; a link on that origin must name its relay with `r`, while any other
 * origin is itself the relay.
 * @returns {{relayURL: string, connectCode: string, hostID: string, invite: string, hostName: string} | null}
 */
export function parseRemoteLink(input, pageOrigin = globalThis.location?.origin ?? "") {
  let url;
  try {
    url = new URL(String(input ?? "").trim());
  } catch {
    return null;
  }
  const parameters = fragmentParameters(url.hash);
  const connectCode = (parameters.get("k") || "").trim();
  const hostID = (parameters.get("host") || "").trim();
  if (!connectCodePattern.test(connectCode) || !hostID) return null;
  const relayURL = parameters.has("r")
    ? normalizeRelayURL(parameters.get("r"))
    : (url.origin === pageOrigin ? "" : normalizeRelayURL(`${url.origin}${url.pathname}`));
  if (!relayURL) return null;
  return {
    relayURL,
    connectCode,
    hostID,
    invite: (parameters.get("invite") || "").trim(),
    hostName: (parameters.get("name") || "").trim(),
  };
}

export function remoteConnectionString(profile) {
  return `${profile.relayURL}/#k=${profile.connectCode}`;
}

/** The remembered Host, or null. The record holds the connect code and the
 * paired-client token, so it is as sensitive as the share link. */
export function readRemoteProfile(storage = globalThis.localStorage) {
  try {
    const value = JSON.parse(storage?.getItem?.(profileStorageKey) || "null");
    if (!value || typeof value !== "object") return null;
    if (!normalizeRelayURL(value.relayURL) || !connectCodePattern.test(value.connectCode || "") || !value.hostID) {
      return null;
    }
    return {
      relayURL: normalizeRelayURL(value.relayURL),
      connectCode: value.connectCode,
      hostID: String(value.hostID),
      hostName: String(value.hostName || ""),
      token: String(value.token || ""),
    };
  } catch {
    return null;
  }
}

export function writeRemoteProfile(profile, storage = globalThis.localStorage) {
  try {
    if (profile) {
      storage?.setItem?.(profileStorageKey, JSON.stringify({
        relayURL: profile.relayURL,
        connectCode: profile.connectCode,
        hostID: profile.hostID,
        hostName: profile.hostName || "",
        token: profile.token || "",
      }));
    } else {
      storage?.removeItem?.(profileStorageKey);
    }
  } catch {
    // Restricted browser contexts may refuse storage; the session still works
    // until the page is closed.
  }
}

export class RemotePairingError extends Error {
  constructor(message, status = 0) {
    super(message);
    this.name = "RemotePairingError";
    this.status = status;
  }
}

/**
 * Exchanges the link's invite for this browser's own token, inside the
 * encrypted session, exactly as the iOS app does.
 */
export async function pairRemote(client, { hostID, invite, clientID, clientName }) {
  if (!invite) {
    throw new RemotePairingError("This link cannot pair a new device. Create a new one with Share on the Host.");
  }
  const body = { host_id: hostID, client_id: clientID, invite };
  if (clientName) body.client_name = clientName;
  const response = await client.fetch("/v1/pairing/request", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (response.status === 409) {
    throw new RemotePairingError("The link has expired or was replaced. Create a new one on the Host.", 409);
  }
  if (!response.ok) {
    throw new RemotePairingError(`The Host refused the pairing (HTTP ${response.status}).`, response.status);
  }
  const result = await response.json().catch(() => null);
  if (!result?.token) throw new RemotePairingError("The Host returned an invalid pairing response.");
  return result.token;
}

const CONNECTING = 0;
const OPEN = 1;
const CLOSING = 2;
const CLOSED = 3;

/**
 * Makes a WebSocket-shaped class whose sockets are Bolthole `ws` streams to
 * `path` on the Host, so WarrenConnection runs unchanged over the encrypted
 * session. `getClient` returns the shared Bolthole client; it redials the
 * relay on its own when the session is gone.
 */
export function boltholeWebSocketClass(getClient, path = "/v1/ws") {
  return class BoltholeWebSocket {
    static CONNECTING = CONNECTING;
    static OPEN = OPEN;
    static CLOSING = CLOSING;
    static CLOSED = CLOSED;

    constructor() {
      this.readyState = CONNECTING;
      this.binaryType = "arraybuffer";
      this.onopen = null;
      this.onmessage = null;
      this.onerror = null;
      this.onclose = null;
      this.stream = null;
      this.closeReported = false;
      this.open();
    }

    async open() {
      const client = getClient();
      let stream;
      try {
        stream = await client.websocket(path);
      } catch {
        // The session could not be dialed or the Host refused the stream.
        // Drop it so the next attempt redials instead of reusing it.
        client.close();
        this.finish(1006);
        return;
      }
      if (this.readyState !== CONNECTING) {
        stream.close().catch(() => {});
        return;
      }
      this.stream = stream;
      this.readyState = OPEN;
      this.onopen?.({ type: "open" });
      this.readLoop(client, stream);
    }

    async readLoop(client, stream) {
      try {
        for (;;) {
          const message = await stream.read();
          if (message === null) break;
          if (this.readyState !== OPEN) return;
          const data = message.text ?? message.data.buffer.slice(
            message.data.byteOffset,
            message.data.byteOffset + message.data.byteLength,
          );
          this.onmessage?.({ type: "message", data });
        }
        this.finish(stream.closeInfo?.code ?? 1005);
      } catch {
        client.close();
        this.finish(1006);
      }
    }

    send(data) {
      if (this.readyState !== OPEN) throw new Error("WebSocket is not open");
      const payload = typeof data === "string"
        ? data
        : (data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
      this.stream.send(payload).catch(() => this.close());
    }

    close() {
      if (this.readyState >= CLOSING) return;
      const wasConnecting = this.readyState === CONNECTING;
      this.readyState = CLOSING;
      // A local close is how WarrenConnection gives up on a stalled socket
      // (heartbeat or welcome deadline). The session under it may be just as
      // stalled, so the next socket dials a fresh one.
      if (!wasConnecting && this.stream) this.stream.close().catch(() => {});
      getClient().close();
      this.finish(1000);
    }

    finish(code) {
      this.readyState = CLOSED;
      if (this.closeReported) return;
      this.closeReported = true;
      this.onclose?.({ type: "close", code });
    }
  };
}

/** Creates the shared Bolthole client for a profile. */
export function createRemoteClient(profile, options = {}) {
  return new Client(remoteConnectionString(profile), { name: "Warren Web", ...options });
}
