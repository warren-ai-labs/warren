const connecting = 0;
const open = 1;

export function reconnectDelay(attempt, random = Math.random) {
  const base = Math.min(30_000, 500 * (2 ** attempt));
  return Math.round(base * (0.8 + random() * 0.4));
}

export function rejectPendingRequests(pending, detail = "Connection lost") {
  const handlers = [...pending.values()];
  pending.clear();
  for (const handler of handlers) handler?.onError?.(detail);
}

export class WarrenConnection {
  constructor({
    url,
    token,
    WebSocketClass = WebSocket,
    onMessage = () => {},
    onState = () => {},
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    random = Math.random,
  }) {
    this.url = url;
    this.token = token;
    this.WebSocketClass = WebSocketClass;
    this.onMessage = onMessage;
    this.onState = onState;
    // Keep the injected timers behind wrappers: native `setTimeout` and
    // `clearTimeout` reject calls with a non-Window receiver.
    this.setTimer = (...args) => setTimer(...args);
    this.clearTimer = (...args) => clearTimer(...args);
    this.random = random;
    this.socket = null;
    this.timer = null;
    this.attempt = 0;
    this.requestSequence = 0;
    this.running = false;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.connect();
  }

  stop() {
    this.running = false;
    this.cancelTimer();
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

    socket.onopen = () => {
      if (socket !== this.socket) return;
      this.onState("open");
      this.sendJSON({ t: "auth", token: this.token, version: "1.0" });
    };
    socket.onmessage = event => {
      if (socket === this.socket) this.onMessage(event);
    };
    socket.onerror = () => socket.close();
    socket.onclose = () => {
      if (socket !== this.socket) return;
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

  cancelTimer() {
    if (this.timer === null) return;
    this.clearTimer(this.timer);
    this.timer = null;
  }
}
