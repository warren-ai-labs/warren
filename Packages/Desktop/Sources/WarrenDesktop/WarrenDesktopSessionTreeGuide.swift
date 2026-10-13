import SwiftUI
import WarrenDesignSystem

/// The geometry a worktree row and the Session lines under it share.
///
/// Every row of a worktree group starts with the same leading slot: the
/// project avatar's slot, so a worktree's status column sits under the avatar's
/// center and the text that follows starts on the project name's column. A
/// worktree row puts its name there; a Session line puts its app icon there.
/// That is what lines a branch name up with the agent lines beneath it, and
/// what keeps a row's text from moving when a dot comes or goes.
///
/// The tree rail that used to tie leaves to their workspace sat on this same
/// column. It was removed with the gutter: the dots are the column now, and the
/// group is told apart by its tight 2pt rhythm and the larger gap between
/// project sections instead of by a drawn bracket.
enum WarrenDesktopSidebarRowLayout {
    /// The leading slot every worktree-tier row reserves. The 14pt status
    /// gutter is centered inside it.
    static let leadingSlotWidth = WarrenLayoutMetrics.sidebarRowIconSlotSize
    /// From the leading slot to the row's content.
    static let slotToContentSpacing = WarrenSpacing.compact
    /// From a Session line's icon tile to its title.
    static let tileToTitleSpacing = WarrenSpacing.small
    /// Between the rows inside one worktree group.
    static let rowSpacing = WarrenSpacing.xxs
    /// Between one project section and the next.
    static let projectSectionSpacing = WarrenSpacing.standard
    /// The selection and hover shape of a sidebar row.
    static let cornerRadius = WarrenRadius.panelRow

    /// The selected row's fill.
    ///
    /// The shared selection wash is tuned for dense lists and reads too faint
    /// on the floating navigation panel, so the selected row lifts to a
    /// brighter plate. Dark lifts with a white wash because the panel is the
    /// darkest thing behind it; light cannot lift with white over a light
    /// panel, so it takes the raised surface instead (`DESIGN.md` §12,
    /// invariant 3).
    static func selectedFill(
        colorScheme: ColorScheme,
        tokens: WarrenColorTokens
    ) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : tokens.popoverSurface
    }
}

/// The leading status column a sidebar row draws its dot in.
///
/// Only the states that ask something of a person are drawn: the actionable
/// tier (approval, input, unnamed attention, failure) in the attention hue with
/// a soft glow, and a completion the person has not seen yet in the success
/// hue. A working Agent needs no one, so it leaves the column empty, as do an
/// exited Session and a plain shell. No status word is drawn beside the dot:
/// the row's own text already says what the Session is, and the full sentence
/// still reaches assistive technology and the hover tooltip.
struct WarrenDesktopSidebarStatusGutter: View {
    let mark: WarrenActivityMark?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        ZStack {
            if let mark, Self.draws(mark) {
                let color = mark.color(tokens)
                let isActionable = mark.tier == .actionable
                WarrenActivityMarkView(
                    mark: mark,
                    color: color,
                    dotSize: WarrenLayoutMetrics.sidebarStatusDotSize
                )
                .shadow(
                    color: isActionable ? color.opacity(0.6) : .clear,
                    radius: isActionable ? 3 : 0
                )
                .help(mark.accessibilityLabel)
            }
        }
        .frame(width: WarrenLayoutMetrics.sidebarStatusGutterWidth)
        .frame(width: WarrenDesktopSidebarRowLayout.leadingSlotWidth)
    }

    /// Whether the gutter draws a dot for `mark`.
    static func draws(_ mark: WarrenActivityMark) -> Bool {
        mark.isDrawn
    }
}

/// A workspace row and the Session lines it owns.
///
/// The row and its leaves are one group, so they are built as one: the stack's
/// spacing is the group's 2pt rhythm, and both the current Host's tree and a
/// scoped Host's render their leaves through here, so the two cannot drift
/// apart.
struct WarrenDesktopSessionLeafGroup<Row: View, Leaves: View>: View {
    let leafCount: Int
    let row: Row
    let leaves: Leaves

    init(
        leafCount: Int,
        @ViewBuilder row: () -> Row,
        @ViewBuilder leaves: () -> Leaves
    ) {
        self.leafCount = leafCount
        self.row = row()
        self.leaves = leaves()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenDesktopSidebarRowLayout.rowSpacing) {
            row
            if leafCount > 0 {
                VStack(alignment: .leading, spacing: WarrenDesktopSidebarRowLayout.rowSpacing) {
                    leaves
                }
            }
        }
    }
}
