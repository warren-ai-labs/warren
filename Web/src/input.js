// Queues terminal input while a session is attaching or the transport is
// down, then replays it in order once the attachment is ready. Input typed
// during a reconnect must not be lost, but it must also never cross sessions:
// flushing one session keeps every other session's queued bytes intact.
export class InputQueue {
  constructor({
    limit = 64 * 1024,
    send,
    onSendFailure = () => {},
  } = {}) {
    this.limit = limit;
    this.send = send;
    this.onSendFailure = onSendFailure;
    this.pending = [];
  }

  enqueue(sessionID, data) {
    this.pending.push({ sessionID, data });
    let size = this.pending.reduce((total, item) => total + item.data.length, 0);
    while (size > this.limit && this.pending.length) {
      size -= this.pending.shift().data.length;
    }
  }

  // Sends every queued byte for the given session in order. Bytes for other
  // sessions stay queued. When the transport rejects a frame, the failed item
  // and everything after it are kept so a reconnect can replay them exactly
  // once; the caller is notified through onSendFailure.
  flush(sessionID) {
    const remaining = [];
    for (let index = 0; index < this.pending.length; index += 1) {
      const item = this.pending[index];
      if (item.sessionID !== sessionID) {
        remaining.push(item);
        continue;
      }
      let delivered = false;
      try {
        delivered = this.send(item.data);
      } catch {
        delivered = false;
      }
      if (!delivered) {
        remaining.push(item, ...this.pending.slice(index + 1));
        this.pending = remaining;
        this.onSendFailure();
        return false;
      }
    }
    this.pending = remaining;
    return true;
  }

  clear() {
    this.pending = [];
  }

  get size() {
    return this.pending.length;
  }
}

// Mobile soft keyboards and CJK IMEs can make xterm fire onData twice for the
// same keystroke (compositionend plus the following input event). This tracks
// composition state and drops exact duplicates inside a short window.
export class MobileInputDeduper {
  constructor({
    isTouch = false,
    windowMs = 150,
    touchWindowMs = 40,
    now = Date.now,
  } = {}) {
    this.isTouch = isTouch;
    this.windowMs = windowMs;
    this.touchWindowMs = touchWindowMs;
    this.now = now;
    this.isComposing = false;
    this.compositionEndTime = Number.NEGATIVE_INFINITY;
    this.lastData = "";
    this.lastTime = 0;
  }

  onCompositionStart() {
    this.isComposing = true;
  }

  onCompositionEnd() {
    this.isComposing = false;
    this.compositionEndTime = this.now();
  }

  shouldSend(data) {
    const time = this.now();
    const inCompositionWindow = this.isComposing
      || time - this.compositionEndTime < this.windowMs;
    // Inside a composition the duplicate window stays wide because the IME
    // echo arrives right after compositionend. Touch keyboards can also echo
    // one plain key twice, but genuine fast repeats like `!!` or `&&` are
    // slower than ~40ms, so keep that window tiny. Desktop repeats are never
    // gated outside composition.
    const duplicateWindow = inCompositionWindow
      ? this.windowMs
      : (this.isTouch ? this.touchWindowMs : 0);
    if (data === this.lastData && time - this.lastTime < duplicateWindow) {
      return false;
    }
    this.lastData = data;
    this.lastTime = time;
    return true;
  }
}

/**
 * Applies the small readline/AppKit editing vocabulary to normal Web inputs.
 * The xterm helper textarea is intentionally excluded by the caller so
 * Control-A/Control-E continue to reach the shell through the PTY.
 */
export function handleUnixTextEditingKey(event) {
  const target = event?.target;
  if (!isEditableTextTarget(target) || event.isComposing) return false;
  const key = String(event.key || "").toLowerCase();
  const meta = Boolean(event.metaKey);
  const control = Boolean(event.ctrlKey);
  const alt = Boolean(event.altKey);
  if (alt || (meta && control)) return false;

  if (meta && key === "a") {
    selectRange(target, 0, target.value.length);
    event.preventDefault();
    return true;
  }
  if (!control || meta) return false;

  const start = Number.isInteger(target.selectionStart) ? target.selectionStart : 0;
  const end = Number.isInteger(target.selectionEnd) ? target.selectionEnd : start;
  switch (key) {
  case "a":
    selectRange(target, 0, 0);
    event.preventDefault();
    return true;
  case "e":
    selectRange(target, target.value.length, target.value.length);
    event.preventDefault();
    return true;
  case "f":
    selectRange(target, Math.min(target.value.length, end + 1), Math.min(target.value.length, end + 1));
    event.preventDefault();
    return true;
  case "b":
    selectRange(target, Math.max(0, start - 1), Math.max(0, start - 1));
    event.preventDefault();
    return true;
  case "k":
    replaceRange(target, start, target.value.length, "");
    event.preventDefault();
    return true;
  case "u":
    replaceRange(target, 0, start, "");
    event.preventDefault();
    return true;
  case "w": {
    let deleteStart = start;
    while (deleteStart > 0 && /\s/.test(target.value[deleteStart - 1])) deleteStart -= 1;
    while (deleteStart > 0 && !/\s/.test(target.value[deleteStart - 1])) deleteStart -= 1;
    replaceRange(target, deleteStart, end, "");
    event.preventDefault();
    return true;
  }
  default:
    return false;
  }
}

export function isEditableTextTarget(target) {
  if (!target || target.disabled || target.readOnly) return false;
  const tag = String(target.tagName || "").toLowerCase();
  if (tag === "textarea") return !target.classList?.contains("xterm-helper-textarea");
  if (tag !== "input") return false;
  return !["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"].includes(
    String(target.type || "text").toLowerCase(),
  );
}

function selectRange(target, start, end) {
  try {
    if (typeof target.setSelectionRange === "function") {
      target.setSelectionRange(start, end);
      return;
    }
    target.select?.();
  } catch {
    target.select?.();
  }
}

function replaceRange(target, start, end, value) {
  if (typeof target.setRangeText === "function") {
    target.setRangeText(value, start, end, "end");
    target.dispatchEvent(new Event("input", { bubbles: true }));
  } else {
    selectRange(target, start, end);
  }
}
