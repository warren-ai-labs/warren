// The Visual Viewport API reports the area of the layout viewport that is
// currently visible on screen. Mobile soft keyboards overlay the layout
// viewport (iOS, and Android Chrome without interactive-widget support), so
// the difference between the two heights is the keyboard inset. When the
// layout viewport itself resizes (Android Chrome with
// interactive-widget=resizes-content), the inset is zero and the regular
// CSS bottom:0 anchoring is already correct.
export function keyboardInset(layoutHeight, viewportHeight, viewportOffsetTop = 0) {
  if (!Number.isFinite(layoutHeight) || !Number.isFinite(viewportHeight)) return 0;
  // Clamp negative offsetTop (iOS rubber-band overscroll at top) so it never
  // invents a phantom keyboard inset.
  const offset = Math.max(0, Number.isFinite(viewportOffsetTop) ? viewportOffsetTop : 0);
  const covered = layoutHeight - (viewportHeight + offset);
  return covered > 2 ? covered : 0;
}
