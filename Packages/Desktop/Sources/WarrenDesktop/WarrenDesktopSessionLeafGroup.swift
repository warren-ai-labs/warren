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

/// The order and gaps of one group's worktrees.
///
/// The tree spaces by four steps: 0 inside a block, 2 between one-line
/// summary rows, 10 between blocks within a group, 20 between groups. A
/// worktree that lists Sessions is a block; one that lists none (folded, or
/// with no Session) is a one-line summary, as is the idle row. Blocks come
/// first and summaries after, so a summary never sits between two blocks
/// where neither gap would fit it.
enum WarrenDesktopWorktreeGap {
    /// `items` with the blocks first, each part keeping its order.
    static func ordered<Item>(
        _ items: [Item],
        leafCount: (Item) -> Int
    ) -> (items: [Item], leafCounts: [Int]) {
        let counted = items.map { ($0, leafCount($0)) }
        let ordered = counted.filter { $0.1 > 0 } + counted.filter { $0.1 == 0 }
        return (ordered.map(\.0), ordered.map(\.1))
    }

    /// The gap above the worktree at `index` of an ordered list.
    static func above(_ index: Int, leafCounts: [Int]) -> CGFloat {
        guard index > 0, index < leafCounts.count else { return 0 }
        return leafCounts[index - 1] == 0 && leafCounts[index] == 0
            ? WarrenDesktopSidebarMetrics.summarySpacing
            : WarrenDesktopSidebarMetrics.worktreeSpacing
    }

    /// Above the idle-worktrees row, the last summary: the block gap after a
    /// worktree that lists Sessions, the summary gap after one that lists
    /// none, and none at all directly under the group's own row.
    static func aboveIdleRow(lastLeafCount: Int?) -> CGFloat {
        guard let lastLeafCount else { return 0 }
        return lastLeafCount > 0
            ? WarrenDesktopSidebarMetrics.worktreeSpacing
            : WarrenDesktopSidebarMetrics.summarySpacing
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
    static let chevronWidth: CGFloat = WarrenDesktopSidebarMetrics.chevronSize

    /// The marks a folded row draws, capped at `maximumDots`. An idle or
    /// exited Session draws nothing.
    var visibleMarks: [WarrenActivityMark] {
        guard !isExpanded else { return [] }
        return WarrenDesktopTreeFoldDots.visibleMarks(of: marks)
    }

    /// The width the accessory takes at the row's trailing edge, so the title
    /// truncates before it instead of running underneath.
    var accessoryWidth: CGFloat {
        guard !isExpanded else { return Self.chevronWidth }
        let summary = WarrenDesktopFoldSummary.width(marks: marks, count: marks.count)
        return Self.chevronWidth + (summary > 0 ? WarrenDesktopFoldSummary.spacing + summary : 0)
    }
}

/// The trailing chevron, plus the fold summary while folded.
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
        HStack(spacing: WarrenDesktopFoldSummary.spacing) {
            if !disclosure.isExpanded {
                WarrenDesktopFoldSummary(marks: disclosure.marks, count: disclosure.marks.count)
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
