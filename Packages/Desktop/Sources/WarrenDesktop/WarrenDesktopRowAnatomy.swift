import SwiftUI
import WarrenDesignSystem

/// The anatomy every sidebar row is built from.
///
/// A row used to assemble itself: each one picked its own height, its own
/// horizontal padding, its own radius, and its own trailing arrangement. The
/// numbers happened to agree often enough that the tree looked intentional, but
/// nothing held them together — and the places they disagreed (a control that
/// gave its width back on hover, a chevron whose column moved when a row
/// folded) were exactly the places the rail looked untidy.
///
/// This type names the row's parts once, in the order a row draws them:
///
///     [ horizontal padding ][ leading icon column ][ gap ][ label ][ trailing rail ]
///
/// Every row kind reads it instead of restating it, so a row cannot drift from
/// its neighbours without changing the anatomy for all of them.
enum WarrenDesktopRowAnatomy {
    /// The row's own inset from the card edge.
    static let horizontalPadding = WarrenDesktopSidebarMetrics.rowHorizontalPadding
    /// The column every leading icon is centred in, at every depth.
    ///
    /// It is the widest leading mark — a group's tile — so a smaller mark (a
    /// 12pt branch glyph, a 16pt Session tile) is centred in it rather than
    /// starting on its own edge. A mark drawn outside this frame is what makes
    /// a child sit left or right of the row that contains it.
    static let iconColumn = WarrenDesktopSidebarMetrics.groupIconSize
    /// The gap between the icon column and the label.
    static let labelGap = WarrenDesktopSidebarMetrics.iconTextSpacing
    /// Where a label starts, measured from the row's leading edge. Every tier
    /// that draws a name shares it, which is what makes the tree's text read as
    /// one column instead of one column per depth.
    static var labelInset: CGFloat { horizontalPadding + iconColumn + labelGap }
    /// The gap between two trailing slots. Shared with the workspace row's
    /// accessory arithmetic, so a fold chevron and an editor entry sit on the
    /// same pitch.
    static let slotGap: CGFloat = WarrenSpacing.xs
    /// The row's corner.
    static let radius = WarrenDesktopSidebarMetrics.rowRadius

    /// Heights, one per row kind, all on the same ladder.
    static let groupRowHeight = WarrenDesktopSidebarMetrics.groupRowHeight
    static let workspaceRowHeight = WarrenDesktopSidebarMetrics.worktreeRowHeight
    static let sessionRowHeight = WarrenDesktopSidebarMetrics.sessionRowHeight
    static let shellRowHeight = WarrenDesktopSidebarMetrics.shellRowHeight
    static let summaryRowHeight = WarrenDesktopSidebarMetrics.summaryRowHeight

    /// The widths a trailing slot can take.
    ///
    /// Fixed widths rather than intrinsic ones: an icon that measures itself
    /// moves its neighbours when it appears, and a column of rows whose right
    /// edges disagree is the most legible kind of untidiness.
    enum Slot {
        /// A bare glyph: a pin, a status mark.
        static let glyph: CGFloat = 12
        /// An actionable glyph inside its hit area: `+`, a disclosure chevron.
        static let control: CGFloat = 18
        /// A short readout: a time, a badge.
        static let readout: CGFloat = 30
    }
}

/// The trailing rail a row ends in.
///
/// Slots keep their width whether or not their control is drawn. A hover-only
/// action therefore cannot re-measure the label beside it: the name truncates
/// once, at rest, and stays put when the pointer arrives. That costs the label
/// the width of the resting slots — a deliberate trade of a few points of name
/// for a row that never moves under the pointer.
struct WarrenDesktopRowRail<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = WarrenDesktopRowAnatomy.slotGap, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension View {
    /// Reserves one trailing slot.
    ///
    /// `isVisible: false` keeps the slot and hides the control, which is what
    /// makes a hover-only action free of layout cost. Pass `reserved: false`
    /// only when a control must genuinely give its room back.
    func warrenRowSlot(
        width: CGFloat,
        isVisible: Bool = true,
        reserved: Bool = true
    ) -> some View {
        self
            .frame(width: width)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .frame(width: reserved ? width : (isVisible ? width : 0))
            .clipped()
    }
}
