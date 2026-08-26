// Coalesces terminal bytes into one xterm.write() per animation frame.
//
// Directly calling terminal.write() for every WebSocket binary frame makes
// high-throughput PTY output thrash the renderer. This batcher keeps a small,
// strictly ordered pending list, merges it on requestAnimationFrame, and can
// flush synchronously before control messages, exit messages, or recovery
// markers so control ordering never races with buffered terminal bytes.
export class OutputBatcher {
  constructor({
    write,
    requestFrame = requestAnimationFrame,
    cancelFrame = cancelAnimationFrame,
    maxPending = 16 * 1024 * 1024,
    isHidden = () => document.hidden,
    onOverflow = () => {},
  }) {
    this.write = write;
    // Keep the injected frame callbacks behind wrappers: native
    // `requestAnimationFrame` and `cancelAnimationFrame` reject calls with a
    // non-Window receiver.
    this.requestFrame = (...args) => requestFrame(...args);
    this.cancelFrame = (...args) => cancelFrame(...args);
    this.maxPending = maxPending;
    this.isHidden = isHidden;
    this.onOverflow = onOverflow;
    this.pending = [];
    this.pendingBytes = 0;
    this.frame = null;
  }

  enqueue(bytes) {
    if (!bytes?.length) return;
    if (this.pendingBytes + bytes.length > this.maxPending) {
      // A hidden tab has no rAF ticks, so without this bound a background
      // session could accumulate output forever. Overflow is a deliberate
      // reanchor: clear memory, ask the app to reconnect without an anchor,
      // and let Host resend a Ghostline checkpoint.
      this.reset();
      this.onOverflow();
      return;
    }
    this.pending.push(bytes);
    this.pendingBytes += bytes.length;
    this.schedule();
  }

  schedule() {
    if (this.frame !== null || this.isHidden()) return;
    this.frame = this.requestFrame(() => {
      this.frame = null;
      this.flushNow();
    });
  }

  // Called when the page becomes visible again. Pending bytes may have been
  // accumulated while rAF was paused; schedule a frame so the terminal
  // resumes without waiting for the next WebSocket message.
  wake() {
    this.schedule();
  }

  flush() {
    if (this.frame !== null) {
      this.cancelFrame(this.frame);
      this.frame = null;
    }
    this.flushNow();
  }

  flushNow() {
    if (this.pending.length === 0) return;
    const chunks = this.pending;
    this.pending = [];
    this.pendingBytes = 0;
    let total = 0;
    for (const chunk of chunks) total += chunk.length;
    const merged = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      merged.set(chunk, offset);
      offset += chunk.length;
    }
    this.write(merged);
  }

  reset() {
    if (this.frame !== null) {
      this.cancelFrame(this.frame);
      this.frame = null;
    }
    this.pending = [];
    this.pendingBytes = 0;
  }

  get hasPending() {
    return this.pending.length > 0;
  }

  dispose() {
    this.reset();
    this.write = () => {};
  }
}
