import AppKit
import SwiftUI

/// Publishes a pointer shape for the region it is attached to.
///
/// `NSCursor.set()` from a SwiftUI `.onHover` was the previous approach, and it
/// has no arbitration: the cursor is global, so the last view to call `set`
/// wins. Two adjacent regions that both want a cursor — a divider abutting a
/// terminal surface, which now publishes an I-beam of its own — then fight over
/// it, and whichever hover callback SwiftUI happens to run last leaves its
/// cursor behind after the pointer has moved on.
///
/// A cursor rect is AppKit's own answer to that. The window resolves overlapping
/// rects by view order, restores the pointer on exit without the region having
/// to observe the exit, and leaves the cursor alone for the duration of a drag —
/// which is what a resize handle wants anyway, since hover can drop while the
/// drag still owns the pointer.
struct WarrenDesktopCursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView {
        let view = CursorView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ view: CursorView, context: Context) {
        guard view.cursor !== cursor else { return }
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var cursor: NSCursor = .arrow

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: cursor)
        }

        /// The region watches the pointer, it does not take it. Cursor rects are
        /// tracking-based and do not go through hit testing, so returning nil
        /// keeps every click and drag on the control underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Shows `cursor` while the pointer is over this view.
    func warrenCursor(_ cursor: NSCursor) -> some View {
        overlay {
            WarrenDesktopCursorRegion(cursor: cursor)
                .allowsHitTesting(false)
        }
    }
}
