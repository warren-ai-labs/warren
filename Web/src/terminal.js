export function terminalSize(terminal) {
  const cols = Number(terminal?.cols);
  const rows = Number(terminal?.rows);
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0) {
    return null;
  }
  return { cols, rows };
}

export function attachTerminalMessage(session, terminal, anchor = null, claimControl = true) {
  // Protocol 2 subscriptions carry the measured viewport and claim control
  // before the Host captures its atomic terminal state. There is no legacy
  // attach/replay fallback: every new Web/mobile client starts at a snapshot
  // boundary.
  const size = terminalSize(terminal);
  const params = { id: session, claim: claimControl, wireOptions: { omitFields: ["output"] } };
  if (size) {
    params.cols = size.cols;
    params.rows = size.rows;
  }
  if (anchor) {
    params.epoch = anchor.epoch;
    params.sequence = anchor.sequence;
  }
  return { method: "session.subscribe", params };
}

export function fitTerminalToHost(fitAddon, host) {
  if (!host?.clientWidth || !host.clientHeight || !fitAddon?.fit) return false;
  fitAddon.fit();
  return true;
}

const FONT_SETTLE_TIMEOUT_MS = 2000;

/**
 * Wait until the configured terminal font is available so xterm measures
 * cell dimensions against the glyphs it will actually render (including
 * CJK fallback fonts) instead of a half-loaded font stack.
 */
export function waitForTerminalFont({ fontFamily, fontSize, timeoutMs = FONT_SETTLE_TIMEOUT_MS } = {}) {
  if (typeof document === "undefined" || !document.fonts?.load) return Promise.resolve();
  const spec = `${fontSize}px ${fontFamily}`;
  let timeoutId = null;
  const timeout = new Promise(resolve => {
    timeoutId = setTimeout(resolve, timeoutMs);
  });
  const loaded = Promise.resolve(document.fonts.load(spec)).catch(() => {});
  return Promise.race([loaded, timeout]).finally(() => clearTimeout(timeoutId));
}

export function terminalSearchSummary(resultIndex, resultCount, hasQuery) {
  if (!hasQuery) return "";
  if (resultCount <= 0) return "No results";
  if (resultIndex >= 0) return `${resultIndex + 1}/${resultCount}`;
  return `${resultCount} found`;
}
