import AppKit
import SwiftUI

/// Shows a pointer shape while the pointer is over a view.
///
/// Two implementations, because the good one needs macOS 15 and Warren supports
/// 13. On 15 and later SwiftUI's own `pointerStyle` owns the pointer for the
/// region and restores it on exit. Before that there is only `NSCursor`, driven
/// from `onHover`.
///
/// `NSCursor.set()` rather than `push()`/`pop()`: a drag keeps the pointer while
/// hover comes and goes, so a stack would push more than it pops and leave a
/// resize cursor current long after the pointer had left. Setting the arrow back
/// is idempotent, which is what survives that.
///
/// A cursor rect would look like the tidier answer and does not work here: the
/// region has to be hit-testable for either mechanism to see the pointer, and a
/// rect additionally has to be re-registered by hand on every geometry change —
/// SwiftUI creates a representable at zero size and frames it afterwards, so the
/// only rect it ever registers is empty.
extension View {
    /// Shows `cursor` while the pointer is over this view.
    ///
    /// The caller is responsible for the view being hit-testable — usually with
    /// `contentShape`. A view the pointer cannot reach cannot change it.
    /// Both mechanisms are applied, not one or the other.
    ///
    /// `pointerStyle` is the better answer where it exists: the system owns the
    /// pointer for the region and restores it without the region observing the
    /// exit. The `onHover` fallback is not only for macOS 13 and 14 — it is also
    /// what this code path is known to have worked with before, so it stays as a
    /// backstop on every version. They agree: both set a resize pointer on
    /// entry and give it back on exit, so whichever one the system honours
    /// produces the same result.
    func warrenCursor(_ cursor: NSCursor) -> some View {
        modifier(WarrenCursorModifier(cursor: cursor))
    }
}

private struct WarrenCursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        applyPointerStyle(to: content)
            .onHover { hovering in
                (hovering ? cursor : .arrow).set()
            }
    }

    @ViewBuilder
    private func applyPointerStyle(to content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(WarrenPointerShape(cursor).pointerStyle)
        } else {
            content
        }
    }
}

/// Maps the cursors Warren asks for onto SwiftUI's pointer styles.
///
/// A small enum rather than a raw `NSCursor` comparison chain, so that a cursor
/// with no matching style is a compile-time choice instead of a silent default.
struct WarrenPointerShape {
    enum Shape: Equatable {
        case resizeLeftRight
        case resizeUpDown
        case other
    }

    let shape: Shape

    init(_ cursor: NSCursor) {
        switch cursor {
        case NSCursor.resizeLeftRight:
            shape = .resizeLeftRight
        case NSCursor.resizeUpDown:
            shape = .resizeUpDown
        default:
            shape = .other
        }
    }

    /// `columnResize`/`rowResize` are the styles for a boundary between two
    /// regions, which is what every divider here is. `frameResize` describes a
    /// handle on the edge of one object and draws a different pointer.
    @available(macOS 15, *)
    var pointerStyle: PointerStyle? {
        switch shape {
        case .resizeLeftRight:
            return .columnResize
        case .resizeUpDown:
            return .rowResize
        case .other:
            return nil
        }
    }
}
