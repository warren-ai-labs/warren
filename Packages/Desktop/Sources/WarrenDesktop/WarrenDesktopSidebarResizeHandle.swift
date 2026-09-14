import AppKit
import SwiftUI
import WarrenDesignSystem

/// The sidebar's trailing resize edge.
///
/// `WarrenDesktopSidebarState` has always been able to take a width, and
/// `WarrenLayoutMetrics.sidebarWidth(for:)` has always known how to clamp and
/// snap one, but nothing ever called them: the rail was fixed at 280pt with the
/// collapse button as the only escape. As soon as the tree lists Sessions the
/// titles need more room than that, and there was no way to ask for it.
///
/// The handle is a 6pt hit strip that draws nothing until it is hovered, so the
/// rail keeps its hairline border at rest. Double-clicking returns to the
/// default width, which is the usual way out of a drag that went too far.
struct WarrenDesktopSidebarResizeHandle: View {
    let width: CGFloat
    let onResize: (CGFloat) -> Void
    let onReset: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenForceHover) private var forceHover
    @State private var isHovered = false
    @State private var dragStartWidth: CGFloat?

    /// Wide enough to catch the pointer, narrow enough that the rail's own rows
    /// keep their full click target.
    static let hitWidth: CGFloat = 6

    private var isActive: Bool { isHovered || dragStartWidth != nil || forceHover }

    /// The cursor is the affordance: there is no room for a visible grip at 6pt,
    /// so the pointer has to say the edge is draggable.
    ///
    /// `set` rather than `push`/`pop`. The handle tracks the pointer through a
    /// drag, so hover can re-enter more than once before the drag ends; a
    /// cursor stack would push once per re-entry and leave a resize cursor
    /// current after the pointer had already left the edge.
    private func updateCursor(onEdge: Bool) {
        (onEdge ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Rectangle()
            .fill(.clear)
            .frame(width: Self.hitWidth)
            .overlay(alignment: .center) {
                // A two-point rule reads as a grab target where the rail's own
                // one-point border reads as an edge.
                Rectangle()
                    .fill(isActive ? tokens.focusRing.opacity(0.55) : .clear)
                    .frame(width: 2)
            }
            .contentShape(.rect)
            .onHover { hovering in
                isHovered = hovering
                // Keep the resize cursor while a drag owns the pointer even if
                // hover has already dropped.
                updateCursor(onEdge: hovering || dragStartWidth != nil)
            }
            .gesture(
                // Translation is measured against the window, not the handle.
                // The handle tracks the rail's trailing edge, so a local
                // coordinate space moves with every update and feeds the
                // handle's own displacement back into the next translation —
                // the width alternates instead of following the pointer.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        guard let dragStartWidth else { return }
                        onResize(dragStartWidth + value.translation.width)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        updateCursor(onEdge: isHovered)
                    }
            )
            .onTapGesture(count: 2, perform: onReset)
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityHint("Drag to resize the sidebar, or double-click to reset it")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onResize(width + WarrenLayoutMetrics.sidebarIndentStep)
                case .decrement:
                    onResize(width - WarrenLayoutMetrics.sidebarIndentStep)
                @unknown default:
                    break
                }
            }
            .warrenSemanticElement(
                id: "sidebar.resize",
                role: .button,
                label: "Sidebar width",
                value: "\(Int(width)) points",
                action: onReset
            )
    }
}
