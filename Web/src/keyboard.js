import { useEffect, useState } from "react";
import { keyboardInset } from "./viewport.js";

// Applies the soft-keyboard inset to a host element so the terminal, agent
// conversation, and shortcut bar stay above the keyboard. The inset is
// applied at discrete open/close points instead of on every visualViewport
// event: during the keyboard animation those events fire per frame, and
// following them continuously reflows the xterm canvas and causes flicker.
export function useKeyboardInset(hostRef, { maxWidth = 1023 } = {}) {
  const [enabled, setEnabled] = useState(
    () => typeof window !== "undefined" && window.matchMedia(`(max-width:${maxWidth}px)`).matches,
  );

  useEffect(() => {
    const query = `(max-width:${maxWidth}px)`;
    const media = window.matchMedia(query);
    const onChange = event => setEnabled(event.matches);
    media.addEventListener("change", onChange);
    setEnabled(media.matches);
    return () => media.removeEventListener("change", onChange);
  }, [maxWidth]);

  useEffect(() => {
    if (!enabled) return undefined;
    const host = hostRef.current;
    const viewport = window.visualViewport;
    if (!host || !viewport) return undefined;

    // Android resizes the layout viewport (covered ~= 0, bottom stays 0),
    // iOS keeps the layout height and pans the visual viewport (covered ==
    // keyboard height). Shrink the host with bottom padding so content sits
    // above the keyboard; clear it again once the keyboard collapses.
    const OPEN_THRESHOLD_PX = 24;
    const SETTLE_MS = 100;
    let keyboardOpen = false;
    let appliedInset = 0;
    let settleTimer = null;
    const apply = inset => {
      host.style.paddingBottom = inset > 0 ? `${inset}px` : "";
      host.dataset.keyboardInset = inset > 0 ? "open" : "";
    };
    const clearSettle = () => {
      if (settleTimer !== null) {
        clearTimeout(settleTimer);
        settleTimer = null;
      }
    };
    const update = () => {
      const inset = keyboardInset(window.innerHeight, viewport.height, viewport.offsetTop);
      if (keyboardOpen) {
        if (inset === 0) {
          clearSettle();
          keyboardOpen = false;
          appliedInset = 0;
          apply(0);
          return;
        }
        if (Math.abs(inset - appliedInset) <= 8) return;
        // A keyboard that changes height (IME/emoji/layout switch) streams
        // resize events per frame. Wait for the stream to settle so the shell
        // does not reflow on every frame, then adjust to the final height.
        clearSettle();
        settleTimer = setTimeout(() => {
          settleTimer = null;
          appliedInset = inset;
          apply(inset);
        }, SETTLE_MS);
      } else if (inset > OPEN_THRESHOLD_PX) {
        clearSettle();
        keyboardOpen = true;
        appliedInset = inset;
        apply(inset);
      }
    };
    update();
    viewport.addEventListener("resize", update);
    viewport.addEventListener("scroll", update);
    window.addEventListener("resize", update);
    return () => {
      clearSettle();
      viewport.removeEventListener("resize", update);
      viewport.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
      apply(0);
    };
  }, [enabled, hostRef]);
}
