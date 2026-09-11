import XCTest
@testable import WarrenDesktop

final class WarrenDesktopSplitLayoutTests: XCTestCase {
    func testInitialSinglePaneLeaf() {
        let tree = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.allPaneIDs, ["pane-1"])
        XCTAssertEqual(tree.allTabIDs, ["tab-1"])
    }

    func testSplitHorizontalAndVerticalUpToFourPanes() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))

        // Split 1 -> 2 (horizontal)
        let twoPanes = initial.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)
        XCTAssertEqual(twoPanes.count, 2)
        XCTAssertEqual(twoPanes.allTabIDs, ["tab-1", "tab-2"])

        // Split 2 -> 3 (vertical on pane-1)
        let threePanes = twoPanes.split(targetPaneID: "pane-1", newTabID: "tab-3", axis: .vertical)
        XCTAssertEqual(threePanes.count, 3)
        XCTAssertTrue(threePanes.contains(tabID: "tab-3"))

        // Split 3 -> 4 (vertical on pane-2)
        let pane2ID = twoPanes.item(forTabID: "tab-2")!.id
        let fourPanes = threePanes.split(targetPaneID: pane2ID, newTabID: "tab-4", axis: .vertical)
        XCTAssertEqual(fourPanes.count, 4)
        XCTAssertEqual(fourPanes.count, SplitLayoutTree.maxPanes)

        // Attempt 5th pane split -> MUST be rejected because max is 4
        let rejectedFivePanes = fourPanes.split(targetPaneID: "pane-1", newTabID: "tab-5", axis: .horizontal)
        XCTAssertEqual(rejectedFivePanes.count, 4)
        XCTAssertFalse(rejectedFivePanes.contains(tabID: "tab-5"))
    }

    func testSplitRejectsDuplicateTabAndEmptyTabIDs() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        XCTAssertEqual(
            initial.split(targetPaneID: "pane-1", newTabID: "tab-1", axis: .horizontal),
            initial
        )
        XCTAssertEqual(
            initial.split(targetPaneID: "pane-1", newTabID: " ", axis: .horizontal),
            initial
        )
    }

    func testSplitOnlyTargetsTheFirstDuplicatePaneAndRejectsInvalidReplacement() {
        let duplicate = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "same-pane", tabID: "tab-1")),
            second: .leaf(SplitPaneItem(id: "same-pane", tabID: "tab-2"))
        )
        let split = duplicate.split(
            targetPaneID: "same-pane",
            newTabID: "tab-3",
            axis: .vertical
        )
        XCTAssertEqual(split.count, 3)
        XCTAssertEqual(split.allTabIDs, ["tab-1", "tab-3", "tab-2"])

        XCTAssertEqual(split.replace(paneID: "same-pane", withTabID: " "), split)
        XCTAssertEqual(split.replace(paneID: "same-pane", withTabID: "tab-2"), split)
    }

    func testReplacementOnlyChangesTheFirstMalformedDuplicatePane() {
        let duplicate = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "same-pane", tabID: "tab-1")),
            second: .leaf(SplitPaneItem(id: "same-pane", tabID: "tab-2"))
        )

        let replaced = duplicate.replace(paneID: "same-pane", withTabID: "tab-3")
        XCTAssertEqual(replaced.allTabIDs, ["tab-3", "tab-2"])
    }

    func testRemovePaneCollapsesTree() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let twoPanes = initial.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)
        let pane2ID = twoPanes.item(forTabID: "tab-2")!.id

        let collapsed = twoPanes.remove(paneID: pane2ID)
        XCTAssertNotNil(collapsed)
        XCTAssertEqual(collapsed?.count, 1)
        XCTAssertEqual(collapsed?.allPaneIDs, ["pane-1"])
    }

    func testMaximizePane() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let twoPanes = initial.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)
        let pane2ID = twoPanes.item(forTabID: "tab-2")!.id

        let maximized = twoPanes.maximize(paneID: pane2ID)
        XCTAssertEqual(maximized.count, 1)
        XCTAssertEqual(maximized.allPaneIDs, [pane2ID])
        XCTAssertEqual(maximized.allTabIDs, ["tab-2"])
    }

    func testCycleNextPaneID() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let twoPanes = initial.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)
        let pane2ID = twoPanes.item(forTabID: "tab-2")!.id

        XCTAssertEqual(twoPanes.nextPaneID(after: "pane-1", forward: true), pane2ID)
        XCTAssertEqual(twoPanes.nextPaneID(after: pane2ID, forward: true), "pane-1")
    }

    func testReconciliationPrunesClosedTabs() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let twoPanes = initial.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)

        // tab-2 is closed
        let reconciled = twoPanes.reconcile(validTabIDs: ["tab-1"], fallbackTabID: "tab-1")
        XCTAssertNotNil(reconciled)
        XCTAssertEqual(reconciled?.count, 1)
        XCTAssertEqual(reconciled?.allTabIDs, ["tab-1"])
    }

    func testReconciliationPrunesWhitespaceTabIDs() {
        let tree = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1")),
            second: .leaf(SplitPaneItem(id: "pane-2", tabID: "   "))
        )

        let reconciled = tree.reconcile(
            validTabIDs: ["tab-1", "   "],
            fallbackTabID: "tab-1"
        )
        XCTAssertEqual(reconciled?.count, 1)
        XCTAssertEqual(reconciled?.allTabIDs, ["tab-1"])
    }

    func testNestedDividerUsesStablePathInsteadOfPreorderGuess() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let two = initial.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)
        let three = two.split(targetPaneID: "pane-1", newTabID: "tab-3", axis: .vertical)
        XCTAssertEqual(three.splitPaths, [[], [false]])

        let adjusted = three.updateRatio(path: [false], ratio: 0.72)
        guard case .split(_, let rootRatio, let first, _) = adjusted else {
            return XCTFail("expected nested split")
        }
        XCTAssertEqual(rootRatio, 0.5, accuracy: 0.001)
        guard case .split(_, let nestedRatio, _, _) = first else {
            return XCTFail("expected nested first split")
        }
        XCTAssertEqual(nestedRatio, 0.72, accuracy: 0.001)

        let normalized = three.updateRatio(path: [], ratio: .nan)
        guard case .split(_, let normalizedRatio, _, _) = normalized else {
            return XCTFail("expected normalized split")
        }
        XCTAssertEqual(normalizedRatio, 0.5, accuracy: 0.001)
    }

    func testDecodeNormalizesMalformedRatioAndPrunesDuplicateLeaves() throws {
        let malformed = """
        {"split":{"axis":"horizontal","ratio":null,"first":{"leaf":{"id":"p1","tabID":"t1"}},"second":{"leaf":{"id":"p2","tabID":"t1"}}}}
        """.data(using: .utf8)!
        let tree = try JSONDecoder().decode(SplitLayoutTree.self, from: malformed)
        XCTAssertEqual(tree.reconcile(validTabIDs: ["t1"], fallbackTabID: "t1")?.count, 1)

        let invalidRatio = """
        {"split":{"axis":"vertical","ratio":999,"first":{"leaf":{"id":"p1","tabID":"t1"}},"second":{"leaf":{"id":"p2","tabID":"t2"}}}}
        """.data(using: .utf8)!
        let normalized = try JSONDecoder().decode(SplitLayoutTree.self, from: invalidRatio)
        guard case .split(_, let ratio, _, _) = normalized else {
            return XCTFail("expected split")
        }
        XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
    }

    func testStructuralIdentityIgnoresRatiosButTracksShapeAndLeaves() {
        let first = SplitLayoutTree.leaf(SplitPaneItem(id: "p1", tabID: "t1"))
        let second = first.split(targetPaneID: "p1", newTabID: "t2", axis: .horizontal)
        let resized = second.updateRatio(path: [], ratio: 0.72)

        XCTAssertEqual(second.structuralIdentity, resized.structuralIdentity)

        let changedAxis = first.split(targetPaneID: "p1", newTabID: "t2", axis: .vertical)
        XCTAssertNotEqual(second.structuralIdentity, changedAxis.structuralIdentity)

        let changedLeaf = SplitLayoutTree.leaf(SplitPaneItem(id: "p1", tabID: "other"))
        XCTAssertNotEqual(first.structuralIdentity, changedLeaf.structuralIdentity)
    }

    func testReconcileFallbackUsesStablePaneIdentity() {
        let tree = SplitLayoutTree.leaf(SplitPaneItem(id: "stale", tabID: "closed"))

        let first = tree.reconcile(validTabIDs: ["open"], fallbackTabID: "open")
        let second = tree.reconcile(validTabIDs: ["open"], fallbackTabID: "open")

        XCTAssertEqual(first?.allPaneIDs, [SplitPaneItem.fallbackID(forTabID: "open")])
        XCTAssertEqual(first, second)
    }

    func testPersistenceDropsUnscopedLegacyLayouts() {
        let suiteName = "WarrenDesktopSplitLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tree = SplitLayoutTree.leaf(SplitPaneItem(id: "pane", tabID: "tab"))
        WarrenDesktopSplitLayoutPersistence.save(
            [
                "legacy-workspace": tree,
                "endpoint-local-workspace-current": tree,
            ],
            to: defaults
        )

        let restored = WarrenDesktopSplitLayoutPersistence.restore(from: defaults)
        XCTAssertNil(restored["legacy-workspace"])
        XCTAssertEqual(restored["endpoint-local-workspace-current"], tree)
    }

    func testPruningDropsDeletedScopesOfCurrentEndpointOnly() {
        let tree = SplitLayoutTree.leaf(SplitPaneItem(id: "pane", tabID: "tab"))
        let layouts = [
            "endpoint-local-workspace-live": tree,
            "endpoint-local-workspace-deleted": tree,
            "endpoint-remote-workspace-absent": tree,
        ]

        let pruned = WarrenDesktopSplitLayoutPersistence.pruned(
            layouts,
            endpointID: "local",
            liveScopeKeys: ["endpoint-local-workspace-live"]
        )

        XCTAssertNotNil(pruned["endpoint-local-workspace-live"])
        XCTAssertNil(pruned["endpoint-local-workspace-deleted"])
        XCTAssertNotNil(
            pruned["endpoint-remote-workspace-absent"],
            "another endpoint's scopes are not represented in this projection"
        )
    }

    @MainActor
    func testScheduledSaveCoalescesAndFlushesTheLatestLayout() {
        let suiteName = "WarrenDesktopSplitLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let second = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-2", tabID: "tab-2"))
        WarrenDesktopSplitLayoutPersistence.scheduleSave(
            ["endpoint-local-workspace-a": first],
            to: defaults,
            after: 60
        )
        XCTAssertTrue(
            WarrenDesktopSplitLayoutPersistence.restore(from: defaults).isEmpty,
            "a scheduled save must not write before its quiet period"
        )

        WarrenDesktopSplitLayoutPersistence.scheduleSave(
            ["endpoint-local-workspace-a": second],
            to: defaults,
            after: 60
        )
        WarrenDesktopSplitLayoutPersistence.flushPendingSave()

        XCTAssertEqual(
            WarrenDesktopSplitLayoutPersistence.restore(from: defaults),
            ["endpoint-local-workspace-a": second]
        )

        // A flush with nothing pending is a no-op rather than a rewrite.
        WarrenDesktopSplitLayoutPersistence.flushPendingSave()
        XCTAssertEqual(
            WarrenDesktopSplitLayoutPersistence.restore(from: defaults),
            ["endpoint-local-workspace-a": second]
        )
    }

    func testWindowMinimumStopsGrowingBeyondTwoPanes() {
        let one = SplitLayoutTree.leaf(SplitPaneItem(id: "p1", tabID: "t1"))
        let two = one.split(targetPaneID: "p1", newTabID: "t2", axis: .vertical)
        let three = two.split(targetPaneID: "p1", newTabID: "t3", axis: .vertical)
        let four = three.split(targetPaneID: "p1", newTabID: "t4", axis: .vertical)

        XCTAssertEqual(one.windowMinimumPaneHeight, one.minimumPaneHeight)
        XCTAssertEqual(two.windowMinimumPaneHeight, two.minimumPaneHeight)
        XCTAssertLessThan(three.windowMinimumPaneHeight, three.minimumPaneHeight)
        XCTAssertEqual(four.windowMinimumPaneHeight, two.minimumPaneHeight)

        let wide = one.split(targetPaneID: "p1", newTabID: "t2", axis: .horizontal)
        let wider = wide.split(targetPaneID: "p1", newTabID: "t3", axis: .horizontal)
        XCTAssertEqual(wide.windowMinimumPaneWidth, wide.minimumPaneWidth)
        XCTAssertEqual(wider.windowMinimumPaneWidth, wide.minimumPaneWidth)
    }

    func testSnapTargetPullsAnEvenSplitWithinAPointRadius() {
        let total: CGFloat = 1200
        let radius = Double(SplitLayoutTree.snapDistance / total)

        // Inside the radius the drag latches; just outside it tracks the pointer.
        XCTAssertEqual(
            SplitLayoutTree.snapTarget(for: 0.5 + radius / 2, totalLength: total, minimum: 0.15, maximum: 0.85),
            0.5
        )
        XCTAssertEqual(
            SplitLayoutTree.snapTarget(for: 0.5 - radius / 2, totalLength: total, minimum: 0.15, maximum: 0.85),
            0.5
        )
        XCTAssertNil(
            SplitLayoutTree.snapTarget(for: 0.5 + radius * 2, totalLength: total, minimum: 0.15, maximum: 0.85)
        )

        // The radius is measured in points, so a narrow container pulls across a
        // larger slice of its own width than a wide one.
        let narrow = SplitLayoutTree.snapTarget(for: 0.52, totalLength: 200, minimum: 0.15, maximum: 0.85)
        let wide = SplitLayoutTree.snapTarget(for: 0.52, totalLength: 200 * 6, minimum: 0.15, maximum: 0.85)
        XCTAssertEqual(narrow, 0.5)
        XCTAssertNil(wide)
    }

    func testSnapTargetIgnoresUnreachableTargetsAndUnlaidOutContainers() {
        // A clamp range that excludes the even split must not latch: the divider
        // could never come to rest there.
        XCTAssertNil(
            SplitLayoutTree.snapTarget(for: 0.5, totalLength: 1200, minimum: 0.6, maximum: 0.85)
        )
        XCTAssertNil(
            SplitLayoutTree.snapTarget(for: 0.5, totalLength: 1200, minimum: 0.15, maximum: 0.4)
        )
        XCTAssertNil(
            SplitLayoutTree.snapTarget(for: 0.5, totalLength: 0, minimum: 0.15, maximum: 0.85)
        )
        XCTAssertNil(
            SplitLayoutTree.snapTarget(for: .nan, totalLength: 1200, minimum: 0.15, maximum: 0.85)
        )
        XCTAssertNil(
            SplitLayoutTree.snapTarget(for: 0.5, totalLength: 1200, minimum: 0.85, maximum: 0.15)
        )
    }

    func testSpatialFocusChoosesNearestPaneAndWraps() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "p1", tabID: "t1"))
        let tree = initial.split(targetPaneID: "p1", newTabID: "t2", axis: .horizontal)
        let right = tree.item(forTabID: "t2")!.id
        XCTAssertEqual(tree.nearestPaneID(from: "p1", direction: .right, wrapping: false), right)
        XCTAssertEqual(tree.nearestPaneID(from: right, direction: .right), "p1")
        XCTAssertNil(tree.nearestPaneID(from: "missing", direction: .right))
    }
}
