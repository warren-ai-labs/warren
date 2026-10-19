// Roving-focus index math for composite widgets (tablists, tree listings).
//
// A composite widget exposes one Tab stop and moves focus with the arrow keys
// while every non-current item keeps `tabIndex = -1`. Keeping the decision math
// here — separate from React — lets the same rules drive the desktop tab strip
// and the mobile tab strip, and lets the unit tests pin the wraparound and
// clamp behaviour without a DOM.

/**
 * Resolve the item index that `key` should move focus to.
 *
 * Returns -1 when the key is not a roving key for this orientation, so callers
 * can leave the event alone (Tab, Enter and typing must keep working).
 */
export function rovingIndex(key, index, count, { orientation = "vertical", loop = true } = {}) {
  if (count <= 0) return -1;
  const vertical = orientation === "vertical" || orientation === "both";
  const horizontal = orientation === "horizontal" || orientation === "both";

  let target;
  if (key === "Home" || key === "PageUp") target = 0;
  else if (key === "End" || key === "PageDown") target = count - 1;
  else if (vertical && key === "ArrowDown") target = index + 1;
  else if (vertical && key === "ArrowUp") target = index - 1;
  else if (horizontal && key === "ArrowRight") target = index + 1;
  else if (horizontal && key === "ArrowLeft") target = index - 1;
  else return -1;

  if (target < 0 || target >= count) {
    if (!loop) return Math.max(0, Math.min(count - 1, target));
    return ((target % count) + count) % count;
  }
  return target;
}

/**
 * The single tab stop of a roving group: the current item if it still exists,
 * otherwise the first item. Guards the case where the previously focused row
 * disappeared because a project collapsed or a session closed.
 */
export function rovingTabIndex(index, count) {
  if (count <= 0) return -1;
  return index >= 0 && index < count ? index : 0;
}
