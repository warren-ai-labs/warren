import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// A workspace row and the Session leaves it lists.
///
/// The leaves share the parent's left edge. Nothing is indented and no rail is
/// drawn: the leaf's type icon, its brighter title, and its second activity
/// line are what tell it apart from the row it hangs under. Both the current
/// Host's tree and a scoped Host's render through here, so their spacing
/// cannot drift apart.
struct WarrenDesktopSessionLeafGroup<Row: View, Leaves: View>: View {
    let leafCount: Int
    /// The gap between the row and its first leaf.
    var rowSpacing: CGFloat = WarrenDesktopSidebarMetrics.sessionSpacing
    let row: Row
    let leaves: Leaves

    init(
        leafCount: Int,
        rowSpacing: CGFloat = WarrenDesktopSidebarMetrics.sessionSpacing,
        @ViewBuilder row: () -> Row,
        @ViewBuilder leaves: () -> Leaves
    ) {
        self.leafCount = leafCount
        self.rowSpacing = rowSpacing
        self.row = row()
        self.leaves = leaves()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            row
            if leafCount > 0 {
                VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sessionSpacing) {
                    leaves
                }
            }
        }
    }
}

/// How a row folds its Session leaves away.
///
/// Folding is the user's call, never the tree's: the row only offers it when
/// it has leaves to fold, and a folded row keeps one dot per Session that has
/// a state so it stays visible.
struct WarrenDesktopLeafDisclosure {
    let isExpanded: Bool
    /// The marks of the Sessions the row lists, in row order. `nil` is a
    /// Session with no Agent state, which draws no dot.
    let marks: [WarrenActivityMark?]
    let toggle: () -> Void

    /// More dots than this stop reading as individual Sessions.
    static let maximumDots = WarrenDesktopSidebarMetrics.maximumFoldDots
    static let dotSize: CGFloat = WarrenDesktopSidebarMetrics.foldDotSize
    static let chevronWidth: CGFloat = 16

    /// The marks a folded row draws, capped at `maximumDots`. An idle or
    /// exited Session draws nothing.
    var visibleMarks: [WarrenActivityMark] {
        guard !isExpanded else { return [] }
        return WarrenDesktopTreeFoldDots.visibleMarks(of: marks)
    }

    /// The width the accessory takes at the row's trailing edge, so the title
    /// truncates before it instead of running underneath.
    var accessoryWidth: CGFloat {
        let dots = CGFloat(visibleMarks.count)
        guard dots > 0 else { return Self.chevronWidth }
        return Self.chevronWidth + WarrenDesktopSidebarMetrics.foldDotSpacing
            + dots * Self.dotSize
            + (dots - 1) * WarrenDesktopSidebarMetrics.foldDotSpacing
    }
}

/// The trailing chevron, plus one dot per Session while folded.
struct WarrenDesktopLeafDisclosureAccessory: View {
    let disclosure: WarrenDesktopLeafDisclosure
    /// Kept for callers; the chevron is always drawn now, because it is the
    /// only sign a row folds.
    let isRevealed: Bool
    let label: String
    let semanticID: String
    let isEnabled: Bool
    var chevronColor: Color? = nil

    var body: some View {
        HStack(spacing: WarrenDesktopSidebarMetrics.foldDotSpacing) {
            if !disclosure.visibleMarks.isEmpty {
                WarrenDesktopTreeFoldDots(marks: disclosure.visibleMarks)
            }
            Button(action: disclosure.toggle) {
                WarrenDesktopTreeChevron(isExpanded: disclosure.isExpanded, color: chevronColor)
                    .frame(
                        width: WarrenDesktopLeafDisclosure.chevronWidth,
                        height: WarrenDesktopLeafDisclosure.chevronWidth
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
            .warrenSemanticElement(
                id: semanticID,
                role: .button,
                label: accessibilityLabel,
                isEnabled: isEnabled,
                action: { if isEnabled { disclosure.toggle() } }
            )
        }
    }

    private var accessibilityLabel: String {
        disclosure.isExpanded ? "Collapse \(label)" : "Expand \(label)"
    }
}
