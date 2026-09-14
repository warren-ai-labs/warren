import AppKit
import SwiftUI
import XCTest
import WarrenDesignSystem
@testable import WarrenDesktop

/// The guide is what says a workspace owns the rows beneath it, so these tests
/// pin both halves of that claim: where the bracket is computed to sit, and
/// that it is actually painted that way.
final class WarrenDesktopSessionTreeGuideTests: XCTestCase {
    /// The bracket has to start in the gutter and touch every leaf. A bracket
    /// that starts in the margin or misses a row is the mark this replaced.
    func testSessionTreeGuideRunsThroughTheGutterAndReachesEveryLeaf() {
        let mode = WarrenDesktopWorkspaceDisplayMode.rich
        let guide = WarrenDesktopSessionTreeGuide(
            rowHeight: mode.rowHeight,
            rowSpacing: WarrenSpacing.xxs,
            workspaceGlyph: .checkout
        )

        XCTAssertEqual(
            guide.railX,
            WarrenDesktopSidebarIndent.sessionGuide,
            "The rail sits in the gutter every row starts from"
        )
        // An elbow stops at the leaf icon it points at, which is the same
        // clearance the leaf indent keeps for the rail. With the rail in the
        // gutter that reach is a full branch rather than a stub.
        XCTAssertEqual(
            guide.railX + guide.branchLength,
            WarrenDesktopSidebarIndent.session + WarrenSpacing.compact
        )
        XCTAssertGreaterThanOrEqual(
            guide.branchLength,
            WarrenLayoutMetrics.sidebarIndentStep,
            "A branch shorter than an indent step reads as a mark, not as a tree"
        )

        // The workspace row gets a tick instead of a branch. It only has to
        // bridge the sliver between the rail and the glyph it hangs from, so it
        // stays shorter than a leaf's branch.
        XCTAssertLessThan(
            guide.workspaceConnectorLength,
            guide.branchLength,
            "The workspace is what the figure hangs from, not one of its leaves"
        )

        // Row 0 is the workspace that owns the leaves; the leaves follow. Every
        // center is a real row's center, so no elbow can land in a gap.
        XCTAssertEqual(guide.rowCenter(at: 0), mode.rowHeight / 2)
        for index in 1...3 {
            XCTAssertEqual(
                guide.rowCenter(at: index) - guide.rowCenter(at: index - 1),
                mode.rowHeight + guide.rowSpacing
            )
        }
        XCTAssertEqual(
            guide.rowCenter(at: 1),
            mode.rowHeight + guide.rowSpacing + mode.rowHeight / 2,
            "The first leaf follows the workspace row and one stack gap"
        )
    }

    /// The tick is only doing its job if it touches the artwork the row draws.
    ///
    /// A workspace row draws three different glyphs in the same 18pt slot and
    /// they are not the same width, so the reach has to differ per kind. This
    /// measures the shipped symbols instead of trusting a number copied into
    /// the guide; a short tick leaves the rail visibly detached from the
    /// workspace it hangs from.
    @MainActor
    func testWorkspaceTickReachesTheGlyphTheRowDraws() throws {
        let mode = WarrenDesktopWorkspaceDisplayMode.rich
        let slot = WarrenLayoutMetrics.sidebarRowIconSlotSize

        func guide(
            _ glyph: WarrenDesktopWorkspaceGlyph
        ) -> WarrenDesktopSessionTreeGuide {
            WarrenDesktopSessionTreeGuide(
                rowHeight: mode.rowHeight,
                rowSpacing: WarrenSpacing.xxs,
                workspaceGlyph: glyph
            )
        }

        let checkoutInset = try Self.symbolLeadingInset(
            "laptopcomputer",
            slot: slot
        )
        let mergedInset = try Self.symbolLeadingInset(
            "arrow.triangle.merge",
            slot: slot
        )
        // The plain worktree marker is a 5pt stroked circle centered in the slot.
        let worktreeInset = (slot - 5) / 2

        // The widest glyph is the one the rail was tuned against, so it needs
        // the shortest tick and the other two have to reach further.
        XCTAssertGreaterThanOrEqual(
            guide(.checkout).workspaceConnectorLength,
            checkoutInset,
            "The checkout tick must reach the laptop glyph"
        )
        XCTAssertGreaterThan(
            guide(.mergedWorktree).workspaceConnectorLength,
            guide(.checkout).workspaceConnectorLength,
            "A merged worktree's merge glyph starts further into the slot"
        )
        XCTAssertGreaterThanOrEqual(
            guide(.mergedWorktree).workspaceConnectorLength,
            mergedInset,
            "The merged-worktree tick must reach the merge glyph"
        )
        XCTAssertGreaterThan(
            guide(.worktree).workspaceConnectorLength,
            guide(.mergedWorktree).workspaceConnectorLength,
            "A plain worktree's dot is the narrowest marker in the slot"
        )
        XCTAssertGreaterThanOrEqual(
            guide(.worktree).workspaceConnectorLength,
            worktreeInset,
            "The worktree tick must reach the dot"
        )
    }

    /// The leading inset of a symbol's ink inside the row's glyph slot.
    ///
    /// The row centers the symbol's layout box in the slot, so the ink's inset
    /// is half the slack plus whatever padding the artwork itself carries.
    private static func symbolLeadingInset(
        _ name: String,
        pointSize: CGFloat = 12,
        slot: CGFloat
    ) throws -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: .regular
        )
        let image = try XCTUnwrap(
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration),
            "\(name) must exist in the system symbol set"
        )
        let width = Int(ceil(image.size.width))
        let height = Int(ceil(image.size.height))
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var leftmost = width
        for x in 0..<width {
            for y in 0..<height {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    leftmost = min(leftmost, x)
                    break
                }
            }
        }
        return (slot - image.size.width) / 2 + CGFloat(leftmost)
    }

    /// The guide is painted, not merely computed.
    ///
    /// The value type cannot catch the failure that matters most here: a guide
    /// drawn over the row it drops from reads as damage, and only the rendered
    /// bitmap knows which of the two is on top. This hosts the real leaf group
    /// and reads the pixels back.
    @MainActor
    func testSessionTreeGuideIsDrawnBehindTheParentRowAndThroughEveryLeaf() throws {
        let mode = WarrenDesktopWorkspaceDisplayMode.rich
        let rowHeight = mode.rowHeight
        let spacing = WarrenSpacing.xxs
        let railX = WarrenDesktopSidebarIndent.sessionGuide
        let leafCount = 2

        let group = WarrenDesktopSessionLeafGroup(
            leafCount: leafCount,
            mode: mode,
            workspaceGlyph: .checkout
        ) {
            Color.clear.frame(height: rowHeight)
        } leaves: {
            ForEach(0..<leafCount, id: \.self) { _ in
                Color.clear.frame(height: rowHeight)
            }
        }
        .frame(width: 200, alignment: .leading)

        let host = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            Color.white
            group
            // The parent row's top-left corner, so the group's own origin is
            // measured rather than assumed.
            Color.red.frame(width: 4, height: 4)
            // An opaque stand-in for the row the rail drops from, sitting on
            // the rail so the z-order is what the pixels answer.
            Color.black
                .frame(width: 5, height: 5)
                .offset(x: railX - 2.5, y: rowHeight / 2 - 2.5)
        }
        .frame(width: 200, height: 200, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let column = Int((railX * scale).rounded())
        let branchLength = WarrenDesktopSidebarIndent.session + WarrenSpacing.compact
            - WarrenDesktopSidebarIndent.sessionGuide
        let branchReach = Int((branchLength * scale).rounded())

        func components(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat)? {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return nil
            }
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        /// The guide is a neutral grey drawn over white, so it is neither white
        /// nor one of the opaque patches. Matching a range instead of one value
        /// survives anti-aliasing at the line ends.
        func isGuide(_ x: Int, _ y: Int) -> Bool {
            guard let (red, green, blue) = components(x, y) else { return false }
            return red > 0.8 && red < 0.99
                && abs(red - green) < 0.05 && abs(green - blue) < 0.05
        }
        func isOpaquePatch(_ x: Int, _ y: Int) -> Bool {
            guard let (red, green, blue) = components(x, y) else { return false }
            return red < 0.1 && green < 0.1 && blue < 0.1
        }

        var originRow: Int?
        var guideRows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            if originRow == nil, let (red, green, blue) = components(Int(scale), y),
               red > 0.6, green < 0.3, blue < 0.3 {
                originRow = y
            }
            if isGuide(column, y) { guideRows.append(y) }
        }

        let groupTop = try XCTUnwrap(originRow, "The group must be laid out at the host's origin")
        let halfRow = Int((rowHeight / 2 * scale).rounded())
        let step = (rowHeight + spacing) * scale
        let parentCenter = groupTop + halfRow

        XCTAssertFalse(
            guideRows.contains { $0 < parentCenter },
            "The rail must not climb past the row it drops from"
        )
        XCTAssertTrue(
            guideRows.contains(parentCenter + halfRow),
            "The rail must carry on below the parent row"
        )
        XCTAssertTrue(
            isOpaquePatch(column, parentCenter),
            "The guide is drawn behind the row, not over it"
        )

        // The top tick leaves the rail toward the workspace icon and stops well
        // short of a leaf's branch.
        let connectorReach = Int(
            (WarrenDesktopSessionTreeGuide(
                rowHeight: rowHeight,
                rowSpacing: spacing,
                workspaceGlyph: .checkout
            ).workspaceConnectorLength * scale).rounded()
        )
        XCTAssertTrue(
            isGuide(column + connectorReach - 1, parentCenter),
            "The rail needs a tick into the workspace icon it hangs from"
        )
        XCTAssertFalse(
            isGuide(column + connectorReach + 2, parentCenter),
            "The workspace tick stops at the icon instead of crossing the row"
        )

        for index in 1...leafCount {
            let center = parentCenter + Int((CGFloat(index) * step).rounded())
            XCTAssertTrue(
                isGuide(column, center),
                "Leaf \(index) must be on the rail"
            )
            // The elbow is a real branch now, so it has to cover the whole
            // reach from the rail to the leaf icon's slot.
            for offset in 1..<branchReach {
                XCTAssertTrue(
                    isGuide(column + offset, center),
                    "Each leaf needs an elbow into it"
                )
            }
            XCTAssertFalse(
                isGuide(column + branchReach + 3, center),
                "An elbow stops at the leaf icon instead of crossing it"
            )
        }
    }
}
