import SwiftUI
import WarrenDesignSystem

/// The pane group the pane bar draws.
///
/// A scope owns one split tree, so the bar draws at most one group at a time.
/// The value exists so the bar, the track's width, and the scroll follower all
/// read one membership and one mark slot instead of each recomputing them from
/// a bare set of Tab IDs.
struct WarrenDesktopSplitGroup: Equatable {
    /// The scope that owns the tree — a Workspace or a Terminal Group. The
    /// group's color is derived from it, so the same scope keeps its hue.
    let scopeKey: String
    let tree: SplitLayoutTree

    var tabIDs: [String] { tree.allTabIDs }

    /// Whether the group earns its mark. One pane is not a group: it draws no
    /// mark and no rule, because there is nothing to bind it to.
    var isDrawn: Bool { tree.count > 1 }
}

/// Which identity hue a group wears.
///
/// The mapping has to survive a relaunch, which rules out Swift's `hashValue`:
/// it is seeded per process, so a group would change color every time the app
/// started. FNV-1a over the scope key is stable for the life of the key.
enum WarrenDesktopSplitGroupPalette {
    static func colorIndex(for scopeKey: String, tintCount: Int) -> Int {
        guard tintCount > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in scopeKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(tintCount))
    }

    static func color(for scopeKey: String, tokens: WarrenColorTokens) -> Color {
        let tints = tokens.tabGroupTints
        guard !tints.isEmpty else { return tokens.mutedForeground }
        return tints[colorIndex(for: scopeKey, tintCount: tints.count)]
    }
}

/// The group's glyph: a miniature of the layout it labels.
///
/// The shape carries both facts the mark would otherwise have to spell out —
/// how many panes there are and how they are arranged — so the mark needs no
/// number and no text. A two-pane horizontal split draws one vertical rule, a
/// four-pane tree draws a cross, and a nested split draws the nested divider
/// only across the half it belongs to.
struct WarrenDesktopSplitGroupGlyph: View {
    let tree: SplitLayoutTree
    let color: Color
    /// The drawn size of the glyph's design square.
    ///
    /// The geometry below is authored in a 12pt square and scaled from it, so
    /// the rules keep their weight against the shape as the mark grows instead
    /// of thinning out. Sizes other than the token are for previews and tests.
    var size: CGFloat = WarrenLayoutMetrics.tabGroupMarkSize

    /// The square the geometry is authored in.
    static let designSide: CGFloat = 12
    /// Where the pane frame sits inside that square. Kept whole rather than
    /// derived so the glyph's shape is a decision, not an accident of metrics.
    static let designFrameRect = CGRect(x: 1.7, y: 3, width: 8.6, height: 6)
    /// Rules stop this far short of the frame, which is what makes them read
    /// as dividers inside one surface rather than as a grid of boxes. A
    /// divider that ends against its parent divider keeps the full length, so
    /// nested splits meet exactly.
    private static let designRuleEndInset: CGFloat = 1.1
    private static let designRuleWidth: CGFloat = 1.15
    private static let designFrameCornerRadius: CGFloat = 2.6

    private var scale: CGFloat { size / Self.designSide }

    var body: some View {
        let scale = size / Self.designSide
        ZStack {
            RoundedRectangle(cornerRadius: Self.designFrameCornerRadius * scale)
                .path(in: Self.designFrameRect.applying(CGAffineTransform(scaleX: scale, y: scale)))
                .stroke(color, lineWidth: Self.designRuleWidth * scale)
            Self.rulesPath(for: tree)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: Self.designRuleWidth * scale, lineCap: .round)
                )
        }
        .frame(width: size, height: size)
    }

    /// The dividers, built in the glyph's own design square.
    ///
    /// Scaling the finished path rather than the geometry it is built from is
    /// what keeps "an end that rests against a parent divider" a question about
    /// the glyph's frame instead of about the sub-rectangle a divider happens to
    /// live in.
    private static func rulesPath(for tree: SplitLayoutTree) -> Path {
        var path = Path()
        for segment in segments(for: tree, in: designFrameRect) {
            path.move(to: segment.start)
            path.addLine(to: segment.end)
        }
        return path
    }

    struct Segment: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    /// The divider segments the glyph draws, in the glyph's design square.
    /// Left internal so the inset rule — dividers stop short of the frame but
    /// meet their parent divider exactly — is held down by a test rather than
    /// by the eye.
    static func segments(for tree: SplitLayoutTree, in rect: CGRect) -> [Segment] {
        guard case .split(let axis, let rawRatio, let first, let second) = tree else {
            return []
        }
        // Persisted trees are decoded with a validated ratio, but the glyph is
        // the one place a bad value would silently draw a divider through the
        // frame's edge, so clamp rather than trust.
        let ratio = min(max(rawRatio.isFinite ? rawRatio : 0.5, 0.05), 0.95)
        let (segment, firstRect, secondRect): (Segment, CGRect, CGRect)
        switch axis {
        case .horizontal:
            let x = rect.minX + rect.width * ratio
            segment = Segment(
                start: CGPoint(
                    x: x,
                    y: Self.insetFromFrame(rect.minY, frameMin: designFrameRect.minY, frameMax: designFrameRect.maxY)
                ),
                end: CGPoint(
                    x: x,
                    y: Self.insetFromFrame(rect.maxY, frameMin: designFrameRect.minY, frameMax: designFrameRect.maxY)
                )
            )
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * ratio, height: rect.height)
            secondRect = CGRect(
                x: x,
                y: rect.minY,
                width: rect.width - rect.width * ratio,
                height: rect.height
            )
        case .vertical:
            let y = rect.minY + rect.height * ratio
            segment = Segment(
                start: CGPoint(
                    x: Self.insetFromFrame(rect.minX, frameMin: designFrameRect.minX, frameMax: designFrameRect.maxX),
                    y: y
                ),
                end: CGPoint(
                    x: Self.insetFromFrame(rect.maxX, frameMin: designFrameRect.minX, frameMax: designFrameRect.maxX),
                    y: y
                )
            )
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * ratio)
            secondRect = CGRect(
                x: rect.minX,
                y: y,
                width: rect.width,
                height: rect.height - rect.height * ratio
            )
        }
        return [segment]
            + segments(for: first, in: firstRect)
            + segments(for: second, in: secondRect)
    }

    /// Pulls a divider end away from the glyph's frame, and leaves an end that
    /// rests against a parent divider where it is. Only the frame's own edges
    /// count, and only along the axis the divider runs, so an interior divider
    /// can never be mistaken for one.
    private static func insetFromFrame(
        _ value: CGFloat,
        frameMin: CGFloat,
        frameMax: CGFloat
    ) -> CGFloat {
        if abs(value - frameMin) < 0.01 { return value + designRuleEndInset }
        if abs(value - frameMax) < 0.01 { return value - designRuleEndInset }
        return value
    }
}

/// The mark that labels a pane group from the front of its tabs.
///
/// It is the glyph alone, in the group's hue, with no box behind it. The shape
/// already says "these panes are one panel", and the rule already runs under
/// them; a tinted chip around the glyph would be a third statement of the same
/// fact, and a louder one than either.
struct WarrenDesktopSplitGroupMark: View {
    let tree: SplitLayoutTree
    let color: Color

    var body: some View {
        WarrenDesktopSplitGroupGlyph(tree: tree, color: color)
            .accessibilityHidden(true)
    }
}
