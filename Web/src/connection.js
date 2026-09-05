const connecting = 0;
const open = 1;
export const protocolVersion = "3.0";

export const agentCapabilities = [
  "agent-timeline-v1",
  "agent-interactions-v1",
  "agent-interrupt-v1",
  "agent-attachments-v1",
];
export const appHeartbeatCapability = "app-heartbeat-v1";

export function reconnectDelay(attempt, random = Math.random) {
  const base = Math.min(30_000, 500 * (2 ** attempt));
  return Math.round(base * (0.8 + random() * 0.4));
}

export function rejectPendingRequests(
  pending,
  detail = "Connection lost",
  metadata = { code: "connection_lost", indeterminate: true, requeue: true },
) {
  const handlers = [...pending.values()];
  pending.clear();
  for (const handler of handlers) {
    if (handler?.timer !== undefined && handler?.timer !== null) {
      clearTimeout(handler.timer);
    }
    handler?.onError?.(detail, metadata);
  }
}

// Headless WebSocket errors use the response envelope's `error` field.
export function connectionErrorDetail(message, fallback = "Error") {
  return message?.error?.message || message?.error || fallback;
}

export class WarrenConnection {
  constructor({
    url,
    token,
    getToken,
    clientID,
    WebSocketClass = WebSocket,
    onMessage = () => {},
    onState = () => {},
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    random = Math.random,
    capabilities = ["roster-delta"],
    heartbeatIntervalMs = 20_000,
    heartbeatTimeoutMs = 10_000,
  }) {
    this.url = url;
    this.token = token;
    this.getToken = typeof getToken === "function" ? getToken : null;
    this.clientID = typeof clientID === "string" ? clientID : "";
    this.WebSocketClass = WebSocketClass;
    this.onMessage = onMessage;
    this.onState = onState;
    // Keep the injected timers behind wrappers: native `setTimeout` and
    // `clearTimeout` reject calls with a non-Window receiver.
    this.setTimer = (...args) => setTimer(...args);
    this.clearTimer = (...args) => clearTimer(...args);
    this.random = random;
    this.heartbeatIntervalMs = Math.max(1_000, heartbeatIntervalMs);
    this.heartbeatTimeoutMs = Math.max(1_000, heartbeatTimeoutMs);
    this.capabilities = [...new Set(capabilities.filter(value => typeof value === "string" && value.trim()))];
    this.negotiatedCapabilities = new Set();
    this.socket = null;
    this.timer = null;
    this.attempt = 0;
    this.requestSequence = 0;
    this.running = false;
    this.heartbeatTimer = null;
    this.heartbeatDeadlineTimer = null;
    this.heartbeatSequence = 0;
    this.pendingHeartbeatID = null;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.connect();
  }

  stop() {
    this.running = false;
    this.cancelTimer();
    this.cancelHeartbeat();
    const socket = this.socket;
    this.socket = null;
    if (socket && socket.readyState <= open) socket.close();
  }

  reconnectNow() {
    if (!this.running) return;
    this.cancelTimer();
    if (!this.socket || this.socket.readyState > open) this.connect();
  }

  markStable() {
    this.attempt = 0;
  }

  reset() {
    if (!this.running) return;
    this.cancelTimer();
    if (this.socket) {
      this.socket.close();
      return;
    }
    this.connect();
  }

  scheduleHeartbeat() {
    this.cancelHeartbeatTimer();
    if (!this.running || !this.supportsCapability(appHeartbeatCapability)) return;
    this.heartbeatTimer = this.setTimer(() => {
      this.heartbeatTimer = null;
      const socket = this.socket;
      if (!socket || socket.readyState !== open) return;
      // Keep at most one probe outstanding. A caller may configure an
      // interval shorter than its timeout; replacing the pending ID would
      // otherwise orphan the first deadline and let a half-open socket live
      // forever.
      if (this.pendingHeartbeatID !== null) {
        this.scheduleHeartbeat();
        return;
      }
      const id = `web-ping-${Date.now()}-${++this.heartbeatSequence}`;
      this.pendingHeartbeatID = id;
      if (!this.sendJSON({ t: "ping", id })) {
        socket.close();
        return;
      }
      this.heartbeatDeadlineTimer = this.setTimer(() => {
        this.heartbeatDeadlineTimer = null;
        if (this.pendingHeartbeatID === id && this.socket === socket) socket.close();
      }, this.heartbeatTimeoutMs);
      this.scheduleHeartbeat();
    }, this.heartbeatIntervalMs);
  }

  acceptHeartbeat(message) {
    if (message?.t !== "pong" || message.id !== this.pendingHeartbeatID) return false;
    this.pendingHeartbeatID = null;
    if (this.heartbeatDeadlineTimer !== null) {
      this.clearTimer(this.heartbeatDeadlineTimer);
      this.heartbeatDeadlineTimer = null;
    }
    return true;
  }

  cancelHeartbeatTimer() {
    if (this.heartbeatTimer !== null) {
      this.clearTimer(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  cancelHeartbeat() {
    this.cancelHeartbeatTimer();
    if (this.heartbeatDeadlineTimer !== null) {
      this.clearTimer(this.heartbeatDeadlineTimer);
      this.heartbeatDeadlineTimer = null;
    }
    this.pendingHeartbeatID = null;
  }

  sendJSON(message) {
    return this.send(JSON.stringify(message));
  }

  request(method, params = {}) {
    this.requestSequence += 1;
    const id = `web-${Date.now()}-${this.requestSequence}`;
    return this.sendJSON({ t: "request", id, method, params }) ? id : null;
  }

  sendBinary(data) {
    return this.send(new TextEncoder().encode(data));
  }

  send(data) {
    if (this.socket?.readyState !== open) return false;
    try {
      this.socket.send(data);
      return true;
    } catch {
      // A socket that is closing can reject send() after readyState passed
      // the OPEN check. Treat it like a closed transport so the caller queues
      // the bytes and reconnects instead of losing the input.
      return false;
    }
  }

  connect() {
    if (!this.running || this.socket?.readyState <= open) return;
    this.onState("connecting");
    const socket = new this.WebSocketClass(this.url);
    socket.binaryType = "arraybuffer";
    this.socket = socket;
    this.negotiatedCapabilities = new Set();

    socket.onopen = () => {
      if (socket !== this.socket) return;
      this.onState("open");
      const auth = {
        t: "auth",
        version: protocolVersion,
        capabilities: this.capabilities,
        terminalStateFormats: ["ghostline-vt-replay-v1"],
      };
      const currentToken = this.getToken ? this.getToken() : this.token;
      if (this.url.includes("/v1/client/connect")) {
        auth.access_token = currentToken;
        auth.client_id = this.clientID || globalThis.crypto?.randomUUID?.() || `web-${Date.now()}`;
      } else {
        auth.token = currentToken;
      }
      this.sendJSON(auth);
    };
    socket.onmessage = event => {
      if (socket !== this.socket) return;
      if (typeof event.data === "string") {
        try {
          const message = JSON.parse(event.data);
          if (this.acceptHeartbeat(message)) return;
          if (message?.t === "welcome" && Array.isArray(message.capabilities)) {
            this.negotiatedCapabilities = new Set(
              message.capabilities.filter(value => typeof value === "string"),
            );
            this.scheduleHeartbeat();
          }
        } catch {
          // The application owns protocol error reporting.
        }
      }
      this.onMessage(event);
    };
    socket.onerror = () => socket.close();
    socket.onclose = () => {
      if (socket !== this.socket) return;
      this.cancelHeartbeat();
      this.socket = null;
      if (!this.running) return;
      this.onState("waiting");
      const delay = reconnectDelay(this.attempt++, this.random);
      this.timer = this.setTimer(() => {
        this.timer = null;
        this.connect();
      }, delay);
    };
  }

  supportsCapability(capability) {
    return this.negotiatedCapabilities.has(capability);
  }

  cancelTimer() {
    if (this.timer === null) return;
    this.clearTimer(this.timer);
    this.timer = null;
  }
}
