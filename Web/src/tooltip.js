// One drawn tooltip for the whole page, mirroring the Desktop app's
// WarrenTooltip.
//
// The native `title` tooltip cannot be styled and makes every control wait on
// its own, so sweeping along a row of icon buttons means waiting again at each
// one. Here the first tooltip waits a short dwell; while it is up, or for a
// moment after it goes, the next control answers at once and the single bubble
// glides across to it.
//
// A control opts in with `data-tooltip="Text"` and, when it has a shortcut,
// `data-tooltip-shortcut="⌘K"`. The bubble is hidden from assistive
// technology, so the control keeps its own accessible name (visible text or
// `aria-label`).

/// The first tooltip's dwell, shared with the Desktop hover detail card.
export const TOOLTIP_SHOW_DELAY = 450;
/// How long after a tooltip goes the next control still answers at once.
export const TOOLTIP_WARM_WINDOW = 300;
/// Grace between leaving one control and entering its neighbour, so the bubble
/// glides instead of blinking out and back.
export const TOOLTIP_LEAVE_GRACE = 60;
/// Gap between the control and the bubble, and the bubble's minimum distance
/// from the viewport edge.
export const TOOLTIP_GAP = 6;
export const TOOLTIP_MARGIN = 8;

/**
 * The bubble's top-left corner: centred under the control, above it when there
 * is no room below, and kept inside the viewport.
 */
export function tooltipPosition(anchor, size, viewport) {
  const clamp = (value, low, high) => Math.min(Math.max(value, low), Math.max(low, high));
  const midX = (anchor.left + anchor.right) / 2;
  const left = clamp(midX - size.width / 2, TOOLTIP_MARGIN, viewport.width - size.width - TOOLTIP_MARGIN);
  const below = anchor.bottom + TOOLTIP_GAP;
  const top = below + size.height <= viewport.height - TOOLTIP_MARGIN
    ? below
    : anchor.top - TOOLTIP_GAP - size.height;
  // A control taller than the room around it (a full-height pane edge) still
  // keeps the bubble on screen.
  return { left, top: clamp(top, TOOLTIP_MARGIN, viewport.height - size.height - TOOLTIP_MARGIN) };
}

/**
 * The timing rules, apart from the DOM. `show(anchor, glides)` puts the bubble
 * on `anchor`; `glides` is true when it moves there from another control.
 * `hide()` takes it away.
 */
export function createTooltipCenter({
  show,
  hide,
  now = () => Date.now(),
  schedule = (callback, delay) => setTimeout(callback, delay),
  cancel = timer => clearTimeout(timer),
}) {
  let current = null;
  let pending = null;
  let showTimer = null;
  let hideTimer = null;
  let warmUntil = -Infinity;

  const cancelShow = () => {
    if (showTimer !== null) cancel(showTimer);
    showTimer = null;
    pending = null;
  };
  const cancelHide = () => {
    if (hideTimer !== null) cancel(hideTimer);
    hideTimer = null;
  };

  return {
    get current() {
      return current;
    },
    enter(anchor) {
      cancelShow();
      cancelHide();
      if (current !== null || now() < warmUntil) {
        const glides = current !== null && current !== anchor;
        current = anchor;
        show(anchor, glides);
        return;
      }
      pending = anchor;
      showTimer = schedule(() => {
        showTimer = null;
        pending = null;
        current = anchor;
        show(anchor, false);
      }, TOOLTIP_SHOW_DELAY);
    },
    leave(anchor) {
      // Leaving one control must not cancel a neighbour's dwell, which can
      // start before this exit arrives.
      if (pending === anchor) cancelShow();
      if (current !== anchor) return;
      cancelHide();
      hideTimer = schedule(() => {
        hideTimer = null;
        current = null;
        hide();
        warmUntil = now() + TOOLTIP_WARM_WINDOW;
      }, TOOLTIP_LEAVE_GRACE);
    },
    /// A click, a keystroke or a scroll ends the tooltip outright, without the
    /// warm window: the person has moved on from reading.
    dismiss() {
      cancelShow();
      cancelHide();
      warmUntil = -Infinity;
      if (current !== null) {
        current = null;
        hide();
      }
    },
  };
}

const ANCHOR_SELECTOR = "[data-tooltip]";

function anchorOf(node) {
  return node instanceof Element ? node.closest(ANCHOR_SELECTOR) : null;
}

/**
 * Installs the shared bubble and the delegated listeners on `doc`. Returns a
 * function that removes both.
 */
export function installTooltips(doc = document) {
  const win = doc.defaultView;
  let bubble = null;
  let textNode = null;
  let shortcutNode = null;

  const ensureBubble = () => {
    if (bubble) return bubble;
    bubble = doc.createElement("div");
    bubble.className = "tooltip";
    bubble.setAttribute("aria-hidden", "true");
    textNode = doc.createElement("span");
    textNode.className = "tooltip-text";
    shortcutNode = doc.createElement("span");
    shortcutNode.className = "tooltip-shortcut";
    bubble.append(textNode, shortcutNode);
    doc.body.append(bubble);
    return bubble;
  };

  const center = createTooltipCenter({
    show(anchor, glides) {
      const text = anchor.getAttribute("data-tooltip");
      if (!anchor.isConnected || !text) {
        center.dismiss();
        return;
      }
      const shortcut = anchor.getAttribute("data-tooltip-shortcut") || "";
      const node = ensureBubble();
      textNode.textContent = text;
      shortcutNode.textContent = shortcut;
      shortcutNode.hidden = !shortcut;
      // Without a glide the bubble lands in place; the position transition
      // only runs between two controls.
      node.classList.toggle("glides", glides);
      const size = node.getBoundingClientRect();
      const { left, top } = tooltipPosition(
        anchor.getBoundingClientRect(),
        { width: size.width, height: size.height },
        { width: doc.documentElement.clientWidth, height: doc.documentElement.clientHeight },
      );
      node.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
      node.classList.add("visible");
    },
    hide() {
      bubble?.classList.remove("visible", "glides");
    },
  });

  const onOver = event => {
    // Touch has no hover; a tap must not leave a bubble behind.
    if (event.pointerType === "touch") return;
    const anchor = anchorOf(event.target);
    // Crossing between a control's own children is not a new arrival.
    if (!anchor || anchorOf(event.relatedTarget) === anchor) return;
    center.enter(anchor);
  };
  const onOut = event => {
    if (event.pointerType === "touch") return;
    const from = anchorOf(event.target);
    if (!from || anchorOf(event.relatedTarget) === from) return;
    center.leave(from);
  };
  const dismiss = () => center.dismiss();

  doc.addEventListener("pointerover", onOver);
  doc.addEventListener("pointerout", onOut);
  doc.addEventListener("pointerdown", dismiss, true);
  doc.addEventListener("keydown", dismiss, true);
  doc.addEventListener("scroll", dismiss, true);
  doc.addEventListener("wheel", dismiss, { capture: true, passive: true });
  win?.addEventListener("blur", dismiss);
  win?.addEventListener("resize", dismiss);

  return () => {
    center.dismiss();
    doc.removeEventListener("pointerover", onOver);
    doc.removeEventListener("pointerout", onOut);
    doc.removeEventListener("pointerdown", dismiss, true);
    doc.removeEventListener("keydown", dismiss, true);
    doc.removeEventListener("scroll", dismiss, true);
    doc.removeEventListener("wheel", dismiss, { capture: true });
    win?.removeEventListener("blur", dismiss);
    win?.removeEventListener("resize", dismiss);
    bubble?.remove();
    bubble = null;
  };
}
