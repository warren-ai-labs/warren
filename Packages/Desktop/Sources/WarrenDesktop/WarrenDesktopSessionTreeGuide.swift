import SwiftUI
import WarrenDesignSystem

/// Where a group's rows sit, and how the bracket that ties them is drawn.
///
/// A bare hairline beside the leaves answered nothing: it began below the
/// parent's glyph and touched no child, so it read as a mark in the margin
/// rather than as containment. This guide is a real tree glyph — it ticks into
/// the workspace icon, drops into the gutter, and elbows into every leaf — so
/// the figure's extent is the group's extent, and two workspaces in a row stop
/// reading as one flat list.
///
/// Every row center is measured from the group's own top. That is what lets the
/// bracket be drawn behind the workspace row and its leaves instead of on top of
/// them: a line crossing a 5pt dot or a laptop glyph reads as damage, while a
/// line that disappears behind them reads as attachment.
struct WarrenDesktopSessionTreeGuide: Equatable, Sendable {
    /// The row rhythm the group is laid out on.
    ///
    /// The leaves, their workspace row, and the bracket all read the same
    /// height, so an elbow lands on the row it points at.
    let rowHeight: CGFloat
    /// The gap between two rows of the group.
    let rowSpacing: CGFloat
    /// The glyph the workspace row above the leaves draws. The rail has to
    /// reach it, and the glyphs are different widths.
    let workspaceGlyph: WarrenDesktopWorkspaceGlyph

    /// The rail's horizontal center, on the gutter the whole tree starts from.
    ///
    /// The rail is a stroked path, so `sessionGuide` reads as the line's center
    /// rather than as the leading edge a filled rectangle would need.
    var railX: CGFloat { WarrenDesktopSidebarIndent.sessionGuide }

    /// The glyph's optical leading inset inside its 18pt row slot.
    ///
    /// Measured from the shipped symbol artwork at the size the row draws:
    /// `laptopcomputer` fills the slot, `arrow.triangle.merge` starts 4.5pt in,
    /// and the plain worktree dot starts 6.5pt in.
    private var workspaceGlyphInset: CGFloat {
        switch workspaceGlyph {
        case .checkout: 0
        case .mergedWorktree: 4.5
        case .worktree: 6.5
        }
    }

    /// How far the short tick into the workspace icon reaches.
    ///
    /// The tick only has to bridge the sliver between the rail and the glyph it
    /// hangs from, but the glyphs sit at different insets, so the reach is the
    /// glyph's inset plus a hairline of overlap. The checkout glyph is the
    /// widest, and its tick keeps the length the rail was tuned with.
    var workspaceConnectorLength: CGFloat {
        max(workspaceGlyphInset + WarrenSpacing.hairline, WarrenSpacing.xs)
    }

    /// How far an elbow reaches out of the rail.
    ///
    /// With the rail in the gutter this is a full branch instead of a stub: it
    /// lands on the leaf icon's slot without crossing it, so the figure says
    /// which row each leaf hangs from.
    var branchLength: CGFloat {
        WarrenDesktopSidebarIndent.session + WarrenSpacing.compact
            - WarrenDesktopSidebarIndent.sessionGuide
    }

    /// The row center of the leaf at `index`, from the group's top.
    ///
    /// Index 0 is the workspace row that owns the leaves; the leaves start at 1.
    func rowCenter(at index: Int) -> CGFloat {
        guard index > 0 else { return rowHeight / 2 }
        let step = rowHeight + rowSpacing
        return rowHeight + rowSpacing + CGFloat(index - 1) * step + rowHeight / 2
    }

    /// The rail's stroke, resting or under the pointer.
    ///
    /// In rich mode the workspace row does not navigate, so the group's hover
    /// feedback is spent on the figure rather than on the row's background. The
    /// emphasis is resolved next to the geometry so the rendered rail stays the
    /// single thing that has to be read to know what hover looks like.
    func railColor(isHovered: Bool, tokens: WarrenColorTokens) -> Color {
        isHovered ? tokens.sidebarTreeGuideHighlight : tokens.sidebarTreeGuide
    }
}

/// Draws the bracket for a group whose workspace row is followed by leaves.
struct WarrenDesktopSessionTreeGuideShape: Shape {
    let guide: WarrenDesktopSessionTreeGuide
    let leafCount: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard leafCount > 0 else { return path }
        let railX = guide.railX
        // The rail spans the workspace row's center to the last leaf's center,
        // where its final elbow closes the figure. The top end also grows a
        // short tick into the workspace icon, so the figure reads as hanging
        // from that row instead of starting beside it.
        path.move(to: CGPoint(x: railX, y: guide.rowCenter(at: 0)))
        path.addLine(to: CGPoint(x: railX, y: guide.rowCenter(at: leafCount)))
        path.move(to: CGPoint(x: railX, y: guide.rowCenter(at: 0)))
        path.addLine(
            to: CGPoint(
                x: railX + guide.workspaceConnectorLength,
                y: guide.rowCenter(at: 0)
            )
        )
        for index in 1...leafCount {
            let center = guide.rowCenter(at: index)
            path.move(to: CGPoint(x: railX, y: center))
            path.addLine(to: CGPoint(x: railX + guide.branchLength, y: center))
        }
        return path
    }
}

/// A workspace row and the Session leaves it owns, tied together by the guide.
///
/// The row, its leaves, and the bracket are one figure, so they are built as
/// one: the stack's spacing is the guide's spacing, and nothing can move a row
/// without moving the elbow that points at it. Both the current Host's tree and
/// a scoped Host's render their leaves through here, so the two cannot drift
/// apart.
///
/// The same figure carries the emphasis: the pointer anywhere in the group
/// lights the whole rail, because the group is what is being pointed at, and so
/// does the workspace the center is showing, because that is the row the figure
/// hangs from. The workspace row above it does not navigate on a click, so this
/// is the only place the pointer can be answered, and answering it needs a
/// sensor rather than `.onHover`; see `WarrenDesktopHoverSensor`.
struct WarrenDesktopSessionLeafGroup<Row: View, Leaves: View>: View {
    let leafCount: Int
    let guide: WarrenDesktopSessionTreeGuide
    /// True when the navigation scope is this workspace: the workspace itself,
    /// or one of the Sessions under it. The rail then stays lit with no pointer
    /// on it, the same way the workspace row's own text stays bright.
    let isCurrentScope: Bool
    let row: Row
    let leaves: Leaves

    init(
        leafCount: Int,
        mode: WarrenDesktopWorkspaceDisplayMode,
        workspaceGlyph: WarrenDesktopWorkspaceGlyph,
        isCurrentScope: Bool = false,
        @ViewBuilder row: () -> Row,
        @ViewBuilder leaves: () -> Leaves
    ) {
        self.leafCount = leafCount
        self.guide = WarrenDesktopSessionTreeGuide(
            rowHeight: mode.rowHeight,
            rowSpacing: WarrenSpacing.xxs,
            workspaceGlyph: workspaceGlyph
        )
        self.isCurrentScope = isCurrentScope
        self.row = row()
        self.leaves = leaves()
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.warrenForceHover) private var forceHover
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: guide.rowSpacing) {
            row
            if leafCount > 0 {
                VStack(alignment: .leading, spacing: guide.rowSpacing) {
                    leaves
                }
            }
        }
        // The guide is a background, not an overlay: it has to be behind the
        // glyphs it leaves, and behind the leaf fills it spans. It takes no
        // pointer or accessibility surface of its own.
        .background(alignment: .topLeading) {
            rail
        }
        .overlay {
            // The rows cannot report hover themselves, and a click still has to
            // reach them; the sensor answers both. See
            // WarrenDesktopHoverSensor.
            WarrenDesktopHoverSensor { isHovered = $0 }
                .accessibilityHidden(true)
        }
    }

    /// The figure at rest, with the emphasis faded in over it.
    ///
    /// Two strokes rather than one color swap: hover then reads as the line
    /// lifting instead of snapping to a different grey, and the fade is an
    /// opacity the compositor can animate.
    @ViewBuilder
    private var rail: some View {
        if leafCount > 0 {
            let tokens = WarrenColorTokens.resolved(for: colorScheme)
            let stroke = StrokeStyle(
                lineWidth: WarrenLayoutMetrics.sidebarRailWidth,
                lineCap: .round,
                lineJoin: .round
            )
            ZStack {
                shape.stroke(guide.railColor(isHovered: false, tokens: tokens), style: stroke)
                shape
                    .stroke(guide.railColor(isHovered: true, tokens: tokens), style: stroke)
                    .opacity(isEmphasized ? 1 : 0)
                    .animation(
                        WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion),
                        value: isEmphasized
                    )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var shape: WarrenDesktopSessionTreeGuideShape {
        WarrenDesktopSessionTreeGuideShape(guide: guide, leafCount: leafCount)
    }

    /// Whether the rail is painted with the emphasis.
    ///
    /// The offscreen probe has no pointer, so it forces the hover state every
    /// other hover-revealed control reads; see `WarrenForceHoverKey`.
    private var isEmphasized: Bool { isHovered || forceHover || isCurrentScope }
}
