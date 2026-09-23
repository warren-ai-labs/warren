const connecting = 0;
const open = 1;
export const protocolVersion = "4.0";

export const agentCapabilities = [
  "agent-timeline-v1",
  "agent-interactions-v1",
  "agent-interrupt-v1",
  "agent-attachments-v1",
  "agent-goals-v1",
];
export const appHeartbeatCapability = "app-heartbeat-v1";
// Host-wide, not per-Session: a user message echoed by the provider carries the
// commandId that sent it, which is how a local bubble knows it has landed.
export const agentCausationCapability = "agent-causation-v1";

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

// Headless WebSocket errors use the response envelope's `error` field,
// while Relay control plane errors use `message`. Accept both so
// error classification and automatic token refresh work reliably.
export function connectionErrorDetail(message, fallback = "Error") {
  return message?.error?.message || message?.error || message?.message || fallback;
}

export function relativeTimeLabel(milliseconds) {
  const seconds = Math.round(Math.max(0, milliseconds) / 1000);
  if (seconds < 45) return "just now";
  const units = [
    { limit: 60, size: 1, name: "second" },
    { limit: 3_600, size: 60, name: "minute" },
    { limit: 86_400, size: 3_600, name: "hour" },
    { limit: Number.POSITIVE_INFINITY, size: 86_400, name: "day" },
  ];
  const unit = units.find(candidate => seconds < candidate.limit);
  const value = Math.max(1, Math.round(seconds / unit.size));
  return `${value} ${unit.name}${value === 1 ? "" : "s"} ago`;
}

// How long an authenticated socket may show "Authenticating…" before the copy
// admits what it is actually doing. Relay holds a client socket while it waits
// for an absent Host, so past this point the delay is the Host being away, not
// authentication being slow.
//
// It has to land *inside* the settle grace, and earlier than the reconnect that
// preceded it: the grace is already counting down from the socket that died, so
// a copy that arrives after it promotes would only ever be seen as
// "interrupted · Authenticating…". Measured against a real Relay, a Host that
// died mid-session showed exactly that for 13s before the real reason arrived.
export const hostWaitCopyDelayMs = 1_000;

export function waitingForHostMessage(hostName) {
  const name = typeof hostName === "string" && hostName.trim() ? hostName.trim() : "";
  return name ? `Waiting for ${name}…` : "Waiting for the Host…";
}

// Relay reports an absent Host only after waiting for it to come back, and
// includes when it was last seen. "Mac is offline · last seen 3 minutes ago"
// tells the user whether to wake their machine; "host offline" does not.
export function hostOfflineDetail(message, now = Date.now()) {
  if (message?.code !== "host_offline") return "";
  const name = typeof message.host_name === "string" && message.host_name.trim()
    ? message.host_name.trim()
    : "Host";
  const lastSeen = Date.parse(message.last_seen_at ?? "");
  if (!Number.isFinite(lastSeen)) return `${name} is offline`;
  return `${name} is offline · last seen ${relativeTimeLabel(now - lastSeen)}`;
}

// What the user is told about the connection, as opposed to what the transport
// is doing. The transport flaps on every sub-second hiccup; a banner that flaps
// with it trains the user to distrust it.
export const connectionLive = "live";
// Retrying, but not yet worth mentioning: the dot breathes, copy and content
// stay as they were.
export const connectionSettling = "settling";
// Confirmed loss: show the reason.
export const connectionInterrupted = "interrupted";

// How long the transport may be unusable before the user hears about it. It has
// to outlast a *successful* reconnect, or the banner flashes for the last
// moments of a recovery that was already working. Measured against a local Relay
// behind a 160ms RTT link with jitter, a full socket replacement (backoff, TCP,
// WS upgrade, auth, welcome) took 0.85s–1.28s, so a 1.2s budget flashed on half
// the attempts. 3s covers that with room for a slower mobile link and still
// reports a real outage promptly.
// Mirrors `warrenConnectionSettleGrace` in WarrenTransport.
export const connectionSettleGraceMs = 3_000;

// Maps transport events onto the three presentation states: degrade slowly,
// recover instantly. Owns one timer; the caller is told only when the state
// actually changes.
export class ConnectionPresenter {
  constructor({
    onChange = () => {},
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    graceMs = connectionSettleGraceMs,
  } = {}) {
    this.onChange = onChange;
    this.setTimer = (...args) => setTimer(...args);
    this.clearTimer = (...args) => clearTimer(...args);
    this.graceMs = graceMs;
    // A cold start is settling, not interrupted: the first attempt must not
    // paint "Offline" before it has had a chance to succeed.
    this.state = connectionSettling;
    this.detail = "";
    this.timer = null;
  }

  // The transport can carry traffic. Recovery is immediate and unconditional.
  live() {
    this.clearDeadline();
    this.publish(connectionLive, "");
  }

  // Connecting, reconnecting or probing. Starts the grace period; a flap that
  // resolves inside it is never shown.
  unsettled(detail = "") {
    // Once the user has been told, stay told until the transport is
    // demonstrably live: a notice that blinks with the backoff is worse than
    // one that stays put. Its reason is kept too — a generic "Reconnecting…"
    // must not overwrite "unauthorized".
    if (this.state === connectionInterrupted) return;
    if (detail) this.detail = detail;
    if (this.state === connectionSettling) {
      // Keep the original deadline. Re-arming on every retry would let a fast
      // reconnect loop postpone the notice forever.
      if (this.timer === null) this.armDeadline();
      return;
    }
    this.publish(connectionSettling, this.detail);
    this.armDeadline();
  }

  // A known absence rather than a flap, so skip the grace period. Relay only
  // reports `host_offline` after waiting ~15s for the Host to come back.
  lost(detail = "") {
    this.clearDeadline();
    this.publish(connectionInterrupted, detail || this.detail);
  }

  stop() {
    this.clearDeadline();
  }

  armDeadline() {
    this.timer = this.setTimer(() => {
      this.timer = null;
      this.publish(connectionInterrupted, this.detail);
    }, this.graceMs);
  }

  clearDeadline() {
    if (this.timer !== null) {
      this.clearTimer(this.timer);
      this.timer = null;
    }
  }

  publish(state, detail) {
    if (this.state === state && this.detail === detail) return;
    this.state = state;
    this.detail = detail;
    this.onChange({ state, detail });
  }
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
    clock = () => Date.now(),
    capabilities = ["roster-delta"],
    heartbeatIntervalMs = 20_000,
    heartbeatTimeoutMs = 10_000,
    resumeThrottleMs = 1_000,
    // Longer than Relay's 15s wait for an absent Host, so a Host that comes
    // back inside that window is not cut off by this deadline.
    welcomeTimeoutMs = 25_000,
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
    this.clock = typeof clock === "function" ? clock : () => Date.now();
    this.heartbeatIntervalMs = Math.max(1_000, heartbeatIntervalMs);
    this.heartbeatTimeoutMs = Math.max(1_000, heartbeatTimeoutMs);
    this.resumeThrottleMs = Math.max(0, resumeThrottleMs);
    this.lastResumeAt = Number.NEGATIVE_INFINITY;
    this.welcomeTimeoutMs = Math.max(1_000, welcomeTimeoutMs);
    this.welcomeTimer = null;
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
    this.cancelWelcomeTimer();
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

  // A phone that was backgrounded or a laptop that changed networks must not
  // wait out a delay that was computed before the transport went stale. An open
  // socket is probed instead of replaced: a frozen socket usually still reports
  // OPEN until a write fails, and discovering that through the regular
  // heartbeat can take a full interval. A closed socket reconnects at once,
  // throttled so several lifecycle events firing together dial only once.
  resume({ resetBackoff = false } = {}) {
    if (!this.running) return false;
    if (this.socket && this.socket.readyState <= open) {
      if (this.socket.readyState === open) {
        if (this.pendingHeartbeatID === null) {
          this.sendHeartbeatProbe();
        } else {
          // A probe was already outstanding when the environment changed. Its
          // deadline was computed before the freeze, so a phone returning to
          // the foreground had that timer fire immediately and close a socket
          // that had just come back. Re-arm the same probe instead of leaving
          // the stale deadline armed, and do not duplicate it: several
          // lifecycle events fire together.
          this.rearmHeartbeatDeadline();
        }
        this.scheduleHeartbeat();
      }
      return false;
    }
    const now = this.clock();
    if (now - this.lastResumeAt < this.resumeThrottleMs) return false;
    this.lastResumeAt = now;
    if (resetBackoff) this.attempt = 0;
    this.cancelTimer();
    this.connect();
    return true;
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
      this.sendHeartbeatProbe();
      this.scheduleHeartbeat();
    }, this.heartbeatIntervalMs);
  }

  // Keep at most one probe outstanding. A caller may configure an interval
  // shorter than its timeout; replacing the pending ID would otherwise orphan
  // the first deadline and let a half-open socket live forever.
  sendHeartbeatProbe() {
    if (!this.supportsCapability(appHeartbeatCapability)) return false;
    const socket = this.socket;
    if (!socket || socket.readyState !== open) return false;
    if (this.pendingHeartbeatID !== null) return true;
    const id = `web-ping-${Date.now()}-${++this.heartbeatSequence}`;
    this.pendingHeartbeatID = id;
    if (!this.sendJSON({ t: "ping", id })) {
      socket.close();
      return false;
    }
    this.armHeartbeatDeadline(id, socket);
    return true;
  }

  armHeartbeatDeadline(id, socket) {
    this.heartbeatDeadlineTimer = this.setTimer(() => {
      this.heartbeatDeadlineTimer = null;
      if (this.pendingHeartbeatID === id && this.socket === socket) socket.close();
    }, this.heartbeatTimeoutMs);
  }

  // Gives the outstanding probe a fresh window without changing its identity,
  // so a late pong is still matchable.
  rearmHeartbeatDeadline() {
    const id = this.pendingHeartbeatID;
    const socket = this.socket;
    if (id === null || !socket) return;
    if (this.heartbeatDeadlineTimer !== null) {
      this.clearTimer(this.heartbeatDeadlineTimer);
      this.heartbeatDeadlineTimer = null;
    }
    this.armHeartbeatDeadline(id, socket);
  }

  acceptHeartbeat(message) {
    if (message?.t !== "pong" || message.id !== this.pendingHeartbeatID) return false;
    this.clearHeartbeatDeadline();
    return true;
  }

  clearHeartbeatDeadline() {
    this.pendingHeartbeatID = null;
    if (this.heartbeatDeadlineTimer !== null) {
      this.clearTimer(this.heartbeatDeadlineTimer);
      this.heartbeatDeadlineTimer = null;
    }
  }

  // Any inbound frame proves the far end is alive, so it satisfies the probe in
  // flight and defers the next one. Waiting for a matching pong while terminal
  // output was streaming closed healthy sockets: the Host answers control
  // requests one at a time per stream, so a slow request can delay a pong past
  // its deadline while output keeps arriving.
  noteInboundActivity() {
    this.clearHeartbeatDeadline();
    this.scheduleHeartbeat();
  }

  cancelHeartbeatTimer() {
    if (this.heartbeatTimer !== null) {
      this.clearTimer(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  cancelWelcomeTimer() {
    if (this.welcomeTimer === null) return;
    this.clearTimer(this.welcomeTimer);
    this.welcomeTimer = null;
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

  sendFrame(data) {
    return this.send(typeof data === "string" ? new TextEncoder().encode(data) : data);
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
      // An authenticated socket can still be handed a Host tunnel that Relay
      // has not yet noticed is dead: the auth frame lands in a socket buffer
      // and no welcome ever arrives, which shows as a spinner until Relay's own
      // read deadline expires. Bound that wait and reconnect instead.
      this.cancelWelcomeTimer();
      this.welcomeTimer = this.setTimer(() => {
        this.welcomeTimer = null;
        if (socket === this.socket) socket.close();
      }, this.welcomeTimeoutMs);
    };
    socket.onmessage = event => {
      if (socket !== this.socket) return;
      this.noteInboundActivity();
      if (typeof event.data === "string") {
        try {
          const message = JSON.parse(event.data);
          // Heartbeat traffic is transport bookkeeping and never reaches the
          // application. A pong whose id no longer matches (data already
          // satisfied the probe, or it answered a superseded one) is swallowed
          // all the same rather than surfacing as an unknown message.
          if (message?.t === "pong") {
            this.acceptHeartbeat(message);
            return;
          }
          // Any answer from the far end ends the welcome wait: a welcome means
          // the Host is live, an error means it answered with a refusal.
          if (message?.t === "welcome" || message?.t === "error") this.cancelWelcomeTimer();
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
      this.cancelWelcomeTimer();
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
