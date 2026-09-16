import XCTest
import WarrenClientCore
import WarrenDesignSystem
@testable import WarrenDesktop

/// The pane bar's group contract: what the track draws for a scope whose layout
/// is split, and where the group's chip puts every Tab behind it.
///
/// The chip is a slot rather than a Tab, so the two facts these tests hold down
/// are the ones the scroll follower depends on: how much wider the track gets,
/// and which Tab index the shift starts at.
final class WarrenDesktopTabGroupTests: XCTestCase {
    private func listings(_ ids: String...) -> [ClientTab] {
        ids.map { ClientTab(id: $0, title: $0) }
    }

    private func tree(tabIDs: [String]) -> SplitLayoutTree {
        var tree: SplitLayoutTree?
        for tabID in tabIDs {
            guard let existing = tree else {
                tree = .leaf(SplitPaneItem(id: "pane-\(tabID)", tabID: tabID))
                continue
            }
            // Splitting the last pane appends the new one, which is how the app's
            // repeated split accumulates leaves: left to right, in creation order.
            tree = existing.split(
                targetPaneID: existing.allPaneIDs[existing.allPaneIDs.count - 1],
                newTabID: tabID,
                axis: .horizontal
            )
        }
        return tree ?? .leaf(SplitPaneItem(id: "pane-empty", tabID: "empty"))
    }

    private func group(tabIDs: [String], scopeKey: String = "workspace-a") -> WarrenDesktopSplitGroup {
        WarrenDesktopSplitGroup(scopeKey: scopeKey, tree: tree(tabIDs: tabIDs))
    }

    private func runTabs(_ element: WarrenDesktopTabRowElement) -> [String]? {
        guard case .groupRun(_, let tabs, _) = element else { return nil }
        return tabs.map(\.id)
    }

    /// The Tab the group's drop target names, wrapped so a missing run is
    /// distinguishable from a run that targets the end of the strip.
    private func groupDropTarget(_ element: WarrenDesktopTabRowElement) -> String?? {
        guard case .groupRun(_, _, let dropBeforeTabID) = element else { return nil }
        return .some(dropBeforeTabID)
    }

    func testASinglePaneDrawsNoGroup() {
        let elements = WarrenDesktopPaneBar.rowElements(
            listings: listings("a", "b"),
            group: group(tabIDs: ["a"])
        )
        XCTAssertEqual(elements.count, 2)
        for element in elements {
            guard case .tab = element else {
                return XCTFail("A one-pane scope must not draw a group")
            }
        }
        XCTAssertEqual(elements.groupMarkSlotWidth, 0)
        XCTAssertNil(elements.groupMarkAnchorIndex)
    }

    func testAnUnsplittableScopeDrawsPlainTabs() {
        let elements = WarrenDesktopPaneBar.rowElements(listings: listings("a", "b"), group: nil)
        XCTAssertEqual(elements.map(\.id), ["a", "b"])
        XCTAssertEqual(elements.groupMarkSlotWidth, 0)
        XCTAssertNil(elements.groupMarkAnchorIndex)
    }

    /// Rich mode already lists the tree's own panes, so the group covers the
    /// whole track.
    func testContiguousMembersBecomeOneRunWithTheChip() {
        let elements = WarrenDesktopPaneBar.rowElements(
            listings: listings("a", "b", "c"),
            group: group(tabIDs: ["a", "b", "c"])
        )
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(runTabs(elements[0]), ["a", "b", "c"])
        XCTAssertTrue(elements[0].drawsGroupMark)
        XCTAssertEqual(elements.groupMarkSlotWidth, WarrenLayoutMetrics.tabGroupMarkSlotWidth)
        XCTAssertEqual(elements.groupMarkAnchorIndex, 0)
    }

    /// Compact mode lists every Session in the order the user dragged them, so
    /// the members can start out scattered. The track leads with them anyway,
    /// because a mark and a rule only say "these belong together" while nothing
    /// sits between them.
    func testScatteredMembersLeadTheTrack() {
        let elements = WarrenDesktopPaneBar.rowElements(
            listings: listings("a", "x", "b", "y", "c"),
            group: group(tabIDs: ["a", "b", "c"])
        )
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(runTabs(elements[0]), ["a", "b", "c"])
        XCTAssertEqual(elements.map(\.id), ["tabgroup.workspace-a", "x", "y"])
        XCTAssertEqual(elements.groupMarkAnchorIndex, 0)
    }

    /// Gathering preserves the pane order the glyph draws, not the order the
    /// scattered listing happened to hold.
    func testGatheredMembersKeepPaneOrder() {
        let elements = WarrenDesktopPaneBar.rowElements(
            listings: listings("b", "a", "x"),
            group: group(tabIDs: ["a", "b"])
        )
        XCTAssertEqual(elements.map(\.id), ["tabgroup.workspace-a", "x"])
        XCTAssertEqual(runTabs(elements[0]), ["a", "b"])
    }

    /// A member the user had dragged to the very end still leads the track once
    /// it is in the layout, and the Tabs outside the group keep their own order
    /// behind it.
    func testTheGroupLeadsWhateverTheStoredOrderWas() {
        let elements = WarrenDesktopPaneBar.rowElements(
            listings: listings("p", "q", "b", "x", "a"),
            group: group(tabIDs: ["a", "b"])
        )
        XCTAssertEqual(elements.map(\.id), ["tabgroup.workspace-a", "p", "q", "x"])
        XCTAssertEqual(runTabs(elements[0]), ["a", "b"])
        XCTAssertEqual(elements.groupMarkAnchorIndex, 0)
        XCTAssertEqual(
            elements.drawnTabIDs,
            ["a", "b", "p", "q", "x"],
            "The track's order is not the listing's; the follower reads this one"
        )
    }

    /// A drop on any member lands after the group, since the group leads the
    /// strip and nothing can sit inside it.
    func testAGroupRunTargetsTheTabThatFollowsIt() {
        let withRest = WarrenDesktopPaneBar.rowElements(
            listings: listings("b", "a", "x"),
            group: group(tabIDs: ["a", "b"])
        )
        guard let target = withRest.first(where: { $0.drawsGroupMark }) else {
            return XCTFail("Expected a group run")
        }
        XCTAssertEqual(groupDropTarget(target), .some("x"))

        let alone = WarrenDesktopPaneBar.rowElements(
            listings: listings("b", "a"),
            group: group(tabIDs: ["a", "b"])
        )
        guard let target = alone.first(where: { $0.drawsGroupMark }) else {
            return XCTFail("Expected a group run")
        }
        XCTAssertEqual(
            groupDropTarget(target),
            .some(.none),
            "With nothing after it, a drop belongs at the end"
        )
    }

    /// Only the last member keeps the hairline that separates it from whatever
    /// follows; between members the group's rule is the only line.
    func testOnlyTheLastMemberKeepsATrailingSeparator() {
        XCTAssertFalse(WarrenDesktopTabRowElement.memberShowsTrailingSeparator(index: 0, count: 3))
        XCTAssertFalse(WarrenDesktopTabRowElement.memberShowsTrailingSeparator(index: 1, count: 3))
        XCTAssertTrue(WarrenDesktopTabRowElement.memberShowsTrailingSeparator(index: 2, count: 3))
    }

    /// The mark is drawn in front of the group's first member, and the group
    /// leads the track, so every Tab starting at index zero is shifted by the
    /// mark's slot.
    func testEveryTabOriginFollowsTheMarkSlot() {
        let elements = WarrenDesktopPaneBar.rowElements(
            listings: listings("a", "b", "c", "d"),
            group: group(tabIDs: ["c", "d"])
        )
        XCTAssertEqual(elements.groupMarkSlotWidth, WarrenLayoutMetrics.tabGroupMarkSlotWidth)
        XCTAssertEqual(elements.groupMarkAnchorIndex, 0)
    }

    /// Rich mode's tree already lists the Sessions, so the bar is a pure pane
    /// control and draws the tree on screen. A Session visited from outside the
    /// layout is therefore that tree alone, with no group for panes the user
    /// cannot see; the sidebar leaf that selected it is the way back.
    func testAVisitedSessionIsDrawnWithoutTheGroupInRichMode() {
        let tabs = listings("a", "b", "c")
        let rendered = WarrenDesktopSplitProjection.rendered(
            tree(tabIDs: ["a", "b"]),
            selectedTabID: "c",
            validTabIDs: Set(tabs.map(\.id)),
            isHoldingForCreation: false
        )
        XCTAssertEqual(rendered.allTabIDs, ["c"])

        let listed = WarrenDesktopPaneBar.tabs(
            visibleIn: rendered,
            from: tabs,
            selected: tabs[2],
            mode: .rich
        )
        XCTAssertEqual(listed.map(\.id), ["c"])

        let elements = WarrenDesktopPaneBar.rowElements(listings: listed, group: nil)
        XCTAssertEqual(elements.map(\.id), ["c"])
        XCTAssertFalse(elements.contains(where: \.drawsGroupMark))
        XCTAssertEqual(elements.groupMarkSlotWidth, 0)
    }

    /// The visiting Session is added to the panes, not drawn in place of one.
    func testAPaneIsNotListedTwiceWhenItIsSelected() {
        let tabs = listings("a", "b", "c")
        let listed = WarrenDesktopPaneBar.tabs(
            visibleIn: tree(tabIDs: ["a", "b"]),
            from: tabs,
            selected: tabs[0],
            mode: .rich
        )
        XCTAssertEqual(listed.map(\.id), ["a", "b"])
    }

    /// Compact mode already enumerates every Session, so a visit is not a
    /// special case there: the group is gathered inside the user's own order.
    func testCompactModeListsEverySessionAndGathersTheGroup() {
        let tabs = listings("a", "x", "b", "c")
        let listed = WarrenDesktopPaneBar.tabs(
            visibleIn: tree(tabIDs: ["a", "b"]),
            from: tabs,
            selected: tabs[3],
            mode: .compact
        )
        let elements = WarrenDesktopPaneBar.rowElements(
            listings: listed,
            group: group(tabIDs: ["a", "b"])
        )
        XCTAssertEqual(elements.map(\.id), ["tabgroup.workspace-a", "x", "c"])
    }

    /// A group has to keep its color across launches, which `hashValue` cannot
    /// promise: it is seeded per process.
    func testGroupColorIsStableForOneScopeAndSharedByEqualKeys() {
        let tokens = WarrenColorTokens.dark
        let tints = tokens.tabGroupTints
        XCTAssertFalse(tints.isEmpty)

        let first = WarrenDesktopSplitGroupPalette.colorIndex(
            for: "endpoint-local-workspace-1",
            tintCount: tints.count
        )
        let second = WarrenDesktopSplitGroupPalette.colorIndex(
            for: "endpoint-local-workspace-1",
            tintCount: tints.count
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue((0..<tints.count).contains(first))
    }

    func testPaletteSpreadsDistinctScopesAcrossItsTints() {
        let tints = WarrenColorTokens.dark.tabGroupTints
        let indices = Set(
            (0..<24).map { offset in
                WarrenDesktopSplitGroupPalette.colorIndex(
                    for: "endpoint-local-workspace-\(offset)",
                    tintCount: tints.count
                )
            }
        )
        // Not a guarantee of any single pair, but a palette that mapped every
        // scope onto one hue would defeat the point of having one.
        XCTAssertGreaterThan(indices.count, 1)
    }

    // MARK: - Glyph geometry

    /// The glyph mirrors the tree it labels, so the divider count and the
    /// arrangement both come from the layout rather than from a fixed icon.
    func testGlyphDividersMirrorTheLayout() {
        let frame = WarrenDesktopSplitGroupGlyph.designFrameRect
        // A left/right split draws one vertical divider, inset from both the
        // frame's top and bottom edges.
        assertSegments(
            WarrenDesktopSplitGroupGlyph.segments(for: twoPane(axis: .horizontal), in: frame),
            [Segment(start: CGPoint(x: 6, y: 4.1), end: CGPoint(x: 6, y: 7.9))]
        )
        // A top/bottom split draws one horizontal divider instead.
        assertSegments(
            WarrenDesktopSplitGroupGlyph.segments(for: twoPane(axis: .vertical), in: frame),
            [Segment(start: CGPoint(x: 2.8, y: 6), end: CGPoint(x: 9.2, y: 6))]
        )
    }

    /// A nested divider starts against its parent divider and only pulls back
    /// from the edge it actually reaches, which is what keeps the two lines
    /// meeting exactly instead of leaving a gap.
    func testNestedDividerMeetsItsParentAndInsetOnce() {
        let frame = WarrenDesktopSplitGroupGlyph.designFrameRect
        let tree = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
            second: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(SplitPaneItem(id: "pane-b", tabID: "b")),
                second: .leaf(SplitPaneItem(id: "pane-c", tabID: "c"))
            )
        )
        assertSegments(
            WarrenDesktopSplitGroupGlyph.segments(for: tree, in: frame),
            [
                Segment(start: CGPoint(x: 6, y: 4.1), end: CGPoint(x: 6, y: 7.9)),
                Segment(start: CGPoint(x: 6, y: 6), end: CGPoint(x: 9.2, y: 6)),
            ]
        )
    }

    func testSinglePaneDrawsNoDivider() {
        let frame = WarrenDesktopSplitGroupGlyph.designFrameRect
        XCTAssertTrue(
            WarrenDesktopSplitGroupGlyph.segments(
                for: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
                in: frame
            ).isEmpty
        )
    }

    private func twoPane(axis: SplitAxis) -> SplitLayoutTree {
        .split(
            axis: axis,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
            second: .leaf(SplitPaneItem(id: "pane-b", tabID: "b"))
        )
    }

    private typealias Segment = WarrenDesktopSplitGroupGlyph.Segment

    /// Divider coordinates are products of the frame's fractions, so comparing
    /// them exactly would fail on the last bit rather than on the geometry.
    private func assertSegments(
        _ actual: [Segment],
        _ expected: [Segment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.start.x, expected.start.x, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actual.start.y, expected.start.y, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actual.end.x, expected.end.x, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actual.end.y, expected.end.y, accuracy: 0.001, file: file, line: line)
        }
    }
}
