import CoreGraphics
import WarrenDesignSystem

/// Device-local Sidebar geometry. An outer app can persist this value without
/// making it part of Host state.
///
/// Collapsing keeps the width the user dragged to. The rail renders at zero
/// width while collapsed, and the peek overlay reuses the stored width so
/// revealing the sidebar does not jump to a default.
public struct WarrenDesktopSidebarState: Equatable, Sendable {
    /// The expanded width. Always a width the policy would display for a drag,
    /// even while the sidebar is collapsed.
    public private(set) var width: CGFloat
    public private(set) var isCollapsed: Bool

    public init(
        width: CGFloat = WarrenLayoutMetrics.sidebarExpandedWidth,
        isCollapsed: Bool = false
    ) {
        let normalized = WarrenLayoutMetrics.sidebarWidth(for: width)
        self.width = normalized == WarrenLayoutMetrics.sidebarCollapsedWidth
            ? WarrenLayoutMetrics.sidebarExpandedWidth
            : normalized
        self.isCollapsed = isCollapsed
    }

    public var renderedWidth: CGFloat {
        isCollapsed ? WarrenLayoutMetrics.sidebarCollapsedWidth : width
    }

    public mutating func setWidth(_ proposedWidth: CGFloat) {
        let normalized = WarrenLayoutMetrics.sidebarWidth(for: proposedWidth)
        if normalized == WarrenLayoutMetrics.sidebarCollapsedWidth {
            // A drag below the snap threshold collapses the rail, but the last
            // expanded width is kept: the peek reveals the sidebar at the
            // width the user chose rather than at a default.
            isCollapsed = true
        } else {
            width = normalized
            isCollapsed = false
        }
    }

    public mutating func toggleCollapsed() {
        isCollapsed.toggle()
    }

    /// Restores the expanded rail at its default width. The resize handle's
    /// double-click resets a drag gone wrong, so it also clears a collapse the
    /// drag may have run into.
    public mutating func restoreExpanded() {
        width = WarrenLayoutMetrics.sidebarExpandedWidth
        isCollapsed = false
    }
}
