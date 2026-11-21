// xterm only listens to mouse-wheel events for scrollback, so touch devices
// have no built-in way to reach history; the browser would rather pan the
// page or visual viewport. This attaches one-finger drag scrolling to the
// terminal host, converting vertical finger movement into terminal.scrollLines
// with a short momentum tail.

const DRAG_THRESHOLD_PX = 8;
const MOMENTUM_START = 0.25; // px per ms
const MOMENTUM_DECAY = 0.95;
const MOMENTUM_MIN = 0.05; // px per ms
const MOMENTUM_FRAME_MS = 16;

// Converts a stream of pixel deltas into whole terminal lines. Partial lines
// stay pending so slow drags accumulate smoothly instead of jittering.
export class PixelScrollAccumulator {
  constructor({ getStep, onLine = () => {} }) {
    this.getStep = getStep;
    this.onLine = onLine;
    this.pending = 0;
  }

  add(pixels) {
    this.pending += pixels;
    const step = this.getStep();
    if (!step) return;
    let lines = 0;
    while (this.pending >= step) {
      this.pending -= step;
      lines += 1;
    }
    while (this.pending <= -step) {
      this.pending += step;
      lines -= 1;
    }
    if (lines) this.onLine(lines);
  }

  reset() {
    this.pending = 0;
  }
}

export function enableTerminalTouchScroll(terminal, host) {
  if (!terminal || !host) return () => {};
  if (typeof window === "undefined") return () => {};
  if (!("ontouchstart" in window) && !(navigator.maxTouchPoints > 0)) return () => {};

  let startY = 0;
  let lastY = 0;
  let lastTime = 0;
  let velocity = 0;
  let dragging = false;
  let frame = null;
  let cachedStep = 0;
  const measureStep = () => {
    const rows = terminal.element?.querySelector(".xterm-rows");
    const rowHeight = rows?.clientHeight;
    if (rowHeight && terminal.rows > 0) return rowHeight / terminal.rows;
    return terminal.options.fontSize * terminal.options.lineHeight || 16;
  };
  const accumulator = new PixelScrollAccumulator({
    getStep: () => cachedStep || (cachedStep = measureStep()),
    onLine: lines => terminal.scrollLines(lines),
  });

  const cancelMomentum = () => {
    if (frame !== null) {
      cancelAnimationFrame(frame);
      frame = null;
    }
  };

  const onTouchStart = event => {
    if (event.touches.length !== 1) return;
    const touch = event.touches[0];
    startY = lastY = touch.clientY;
    lastTime = Date.now();
    velocity = 0;
    dragging = false;
    cachedStep = measureStep();
    accumulator.reset();
    cancelMomentum();
  };

  const onTouchMove = event => {
    if (event.touches.length !== 1) return;
    const touch = event.touches[0];
    const now = Date.now();
    const delta = lastY - touch.clientY;
    const elapsed = Math.max(1, now - lastTime);
    velocity = velocity * 0.8 + (delta / elapsed) * 0.2;
    lastY = touch.clientY;
    lastTime = now;
    if (!dragging) {
      if (Math.abs(touch.clientY - startY) < DRAG_THRESHOLD_PX) return;
      dragging = true;
    }
    // Keep the browser from panning the page/visual viewport while the
    // gesture is scrolling terminal history.
    event.preventDefault();
    accumulator.add(delta);
  };

  const startMomentum = () => {
    if (Math.abs(velocity) < MOMENTUM_START) return;
    let speed = velocity;
    let previousTimestamp = null;
    const step = timestamp => {
      const dt = previousTimestamp === null
        ? MOMENTUM_FRAME_MS
        : Math.min(48, Math.max(1, timestamp - previousTimestamp));
      previousTimestamp = timestamp;
      speed *= Math.pow(MOMENTUM_DECAY, dt / MOMENTUM_FRAME_MS);
      accumulator.add(speed * dt);
      if (Math.abs(speed) > MOMENTUM_MIN) {
        frame = requestAnimationFrame(step);
      } else {
        frame = null;
      }
    };
    frame = requestAnimationFrame(step);
  };

  const onTouchEnd = () => {
    if (!dragging) return;
    dragging = false;
    startMomentum();
  };

  host.addEventListener("touchstart", onTouchStart, { passive: true });
  host.addEventListener("touchmove", onTouchMove, { passive: false });
  host.addEventListener("touchend", onTouchEnd);
  host.addEventListener("touchcancel", cancelMomentum);
  // Let the gesture handler own vertical panning so iOS Safari cannot
  // preempt touchmove with its own scroll/zoom behavior.
  const previousTouchAction = host.style.touchAction;
  host.style.touchAction = "none";

  return () => {
    cancelMomentum();
    host.removeEventListener("touchstart", onTouchStart);
    host.removeEventListener("touchmove", onTouchMove);
    host.removeEventListener("touchend", onTouchEnd);
    host.removeEventListener("touchcancel", cancelMomentum);
    host.style.touchAction = previousTouchAction;
  };
}
