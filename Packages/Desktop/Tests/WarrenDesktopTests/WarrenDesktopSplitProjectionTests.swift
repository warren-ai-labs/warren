import XCTest
@testable import WarrenDesktop

/// The layout store's contract, and the bug it was written to close: a scope
/// keeps one split, and looking at another Session must not be able to retire
/// it. The projection is the only thing a selection is allowed to narrow.
final class WarrenDesktopSplitProjectionTests: XCTestCase {
    private func panes(_ tabIDs: String...) -> SplitLayoutTree {
        var tree = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-\(tabIDs[0])", tabID: tabIDs[0]))
        for tabID in tabIDs.dropFirst() {
            tree = tree.split(
                targetPaneID: tree.allPaneIDs[0],
                newTabID: tabID,
                axis: .horizontal
            )
        }
        return tree
    }

    // MARK: - What the store keeps

    func testStoredKeepsTheSplitWhileAnotherSessionIsSelected() {
        let tree = panes("a", "b")
        let stored = WarrenDesktopSplitProjection.stored(
            tree,
            validTabIDs: ["a", "b", "c"],
            fallbackTabID: "c"
        )
        XCTAssertEqual(stored?.count, 2)
        XCTAssertEqual(stored?.allTabIDs, ["a", "b"])
    }

    func testStoredDropsPanesWhoseSessionEnded() {
        let tree = panes("a", "b")
        let stored = WarrenDesktopSplitProjection.stored(
            tree,
            validTabIDs: ["a"],
            fallbackTabID: "a"
        )
        XCTAssertEqual(stored?.count, 1)
        XCTAssertEqual(stored?.allTabIDs, ["a"])
    }

    // MARK: - What the panel draws

    func testRenderedNarrowsToASelectionOutsideTheLayout() {
        let rendered = WarrenDesktopSplitProjection.rendered(
            panes("a", "b"),
            selectedTabID: "c",
            validTabIDs: ["a", "b", "c"],
            isHoldingForCreation: false
        )
        XCTAssertEqual(rendered.count, 1)
        XCTAssertEqual(rendered.allTabIDs, ["c"])
    }

    func testRenderedKeepsTheLayoutForASelectedMember() {
        let rendered = WarrenDesktopSplitProjection.rendered(
            panes("a", "b"),
            selectedTabID: "b",
            validTabIDs: ["a", "b", "c"],
            isHoldingForCreation: false
        )
        XCTAssertEqual(rendered.count, 2)
    }

    /// Creation selects its new Session before the roster can place it in the
    /// layout, so the layout has to hold for that window or the split would
    /// target a pane the tree no longer has.
    func testRenderedHoldsTheLayoutWhileASplitIsInFlight() {
        let rendered = WarrenDesktopSplitProjection.rendered(
            panes("a", "b"),
            selectedTabID: "new",
            validTabIDs: ["a", "b", "new"],
            isHoldingForCreation: true
        )
        XCTAssertEqual(rendered.count, 2)
    }

    /// The same window for a scope that has no tree yet. Creation selects the
    /// new Session before the split can consume it, so the lone-pane fallback
    /// has to name the pane the request recorded rather than the selection.
    func testBaseTabIDHoldsThePendingTargetOverTheSelection() {
        XCTAssertEqual(
            WarrenDesktopSplitProjection.baseTabID(
                selectedTabID: "new",
                pendingTargetTabID: "a",
                emptyTabID: "empty"
            ),
            "a"
        )
    }

    /// Without a split in flight the selection is the base, and a scope with
    /// nothing selected at all still renders an identity-free pane.
    func testBaseTabIDFallsBackToTheSelectionThenEmpty() {
        XCTAssertEqual(
            WarrenDesktopSplitProjection.baseTabID(
                selectedTabID: "a",
                pendingTargetTabID: nil,
                emptyTabID: "empty"
            ),
            "a"
        )
        XCTAssertEqual(
            WarrenDesktopSplitProjection.baseTabID(
                selectedTabID: nil,
                pendingTargetTabID: nil,
                emptyTabID: "empty"
            ),
            "empty"
        )
    }

    /// The guarantee the user asked for: visit another Session, come back, and
    /// the split is still there.
    func testVisitingAnotherSessionAndReturningKeepsTheSplit() {
        let tree = panes("a", "b")
        let valid: Set<String> = ["a", "b", "c"]

        let visited = WarrenDesktopSplitProjection.rendered(
            WarrenDesktopSplitProjection.stored(tree, validTabIDs: valid, fallbackTabID: "a")
                ?? tree,
            selectedTabID: "c",
            validTabIDs: valid,
            isHoldingForCreation: false
        )
        XCTAssertEqual(visited.count, 1, "The visit itself may narrow what is drawn")

        let returned = WarrenDesktopSplitProjection.rendered(
            WarrenDesktopSplitProjection.stored(tree, validTabIDs: valid, fallbackTabID: "a")
                ?? tree,
            selectedTabID: "a",
            validTabIDs: valid,
            isHoldingForCreation: false
        )
        XCTAssertEqual(returned.count, 2)
        XCTAssertEqual(returned.allTabIDs, ["a", "b"])
    }

    // MARK: - What a split applies to

    /// A split extends the layout, so its target is always a pane of it — even
    /// while the panel is showing a Session that is only being visited.
    func testSplitTargetIsTheSelectedPaneWhenItIsOne() {
        let layout = panes("a", "b")
        XCTAssertEqual(
            WarrenDesktopSplitProjection.splitTargetPaneID(
                in: layout,
                selectedTabID: "b",
                rememberedPaneID: layout.allPaneIDs.first
            ),
            layout.item(forTabID: "b")?.id
        )
    }

    func testSplitTargetFallsBackToTheRememberedPaneForAVisit() {
        let layout = panes("a", "b")
        let remembered = layout.item(forTabID: "b")?.id
        XCTAssertEqual(
            WarrenDesktopSplitProjection.splitTargetPaneID(
                in: layout,
                selectedTabID: "c",
                rememberedPaneID: remembered
            ),
            remembered
        )
    }

    /// A remembered pane the user has since closed is gone; the layout's first
    /// pane is the only answer left.
    func testSplitTargetFallsBackToTheFirstPane() {
        let layout = panes("a", "b")
        XCTAssertEqual(
            WarrenDesktopSplitProjection.splitTargetPaneID(
                in: layout,
                selectedTabID: "c",
                rememberedPaneID: "pane-gone"
            ),
            layout.allPaneIDs.first
        )
    }

    func testLonePaneKeepsAnExistingPaneIdentity() {
        let pane = WarrenDesktopSplitProjection.lonePane(tabID: "a").leaves[0]
        XCTAssertEqual(pane.id, SplitPaneItem.fallbackID(forTabID: "a"))
        XCTAssertEqual(pane.tabID, "a")

        let named = WarrenDesktopSplitProjection.lonePane(tabID: "a", paneID: "pane-a").leaves[0]
        XCTAssertEqual(named.id, "pane-a")
    }

    // MARK: - Adopting the Host's arrangement

    /// The bug this guard closes: a split's roster echo is slow, and a roster
    /// that still carries the pre-edit arrangement arrives first. Adopting that
    /// stale tree made the split flash and collapse until the real answer came.
    func testAStaleRosterCannotCollapseAnEditInFlight() {
        let beforeEdit = panes("a", "b")
        let edit = panes("a", "b", "c")

        XCTAssertFalse(
            WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: edit,
                adopted: beforeEdit,
                host: beforeEdit
            ),
            "the pre-edit arrangement is not an answer to the edit"
        )
        XCTAssertFalse(
            WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: edit,
                adopted: beforeEdit,
                host: panes("a", "b", "d")
            ),
            "while the edit is unconfirmed, nothing but its own panes may replace it"
        )
        XCTAssertTrue(
            WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: edit,
                adopted: beforeEdit,
                host: panes("a", "b", "c")
            ),
            "the Host's echo of the edit confirms it"
        )
    }

    /// The Host assigns pane identity, so the tree it echoes back is not `==`
    /// to the local edit even when it shows the same panes. Confirmation has to
    /// compare the tabs, or every split would wait forever for an equality that
    /// never comes.
    func testConfirmationComparesTabsNotPaneIdentity() {
        let beforeEdit = SplitLayoutTree.leaf(
            SplitPaneItem(id: "host-pane-a", tabID: "a")
        )
        let edit = beforeEdit.split(
            targetPaneID: "host-pane-a",
            newTabID: "b",
            axis: .horizontal
        )
        let echo = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "pane-1", tabID: "a")),
            second: .leaf(SplitPaneItem(id: "pane-2", tabID: "b"))
        )

        XCTAssertNotEqual(echo, edit, "same panes, different identities")
        XCTAssertTrue(
            WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: edit,
                adopted: beforeEdit,
                host: echo
            )
        )
    }

    func testAdoptionWithoutAnEditInFlightAlwaysTakesTheHost() {
        let beforeEdit = panes("a", "b")
        XCTAssertTrue(
            WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: beforeEdit,
                adopted: beforeEdit,
                host: panes("a", "b", "c")
            )
        )
        XCTAssertTrue(
            WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: nil,
                adopted: nil,
                host: beforeEdit
            )
        )
    }
}
