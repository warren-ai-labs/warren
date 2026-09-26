import XCTest
import WarrenClientCore
import WarrenDomain
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

    /// While the tree lists Sessions the bar answers "what is on screen", not
    /// "what Sessions exist". A workspace running four with one visible shows
    /// one entry.
    func testPaneBarListsOnlyVisiblePanesInPaneOrder() {
        let tabs = (1...4).map { ClientTab(id: "tab-\($0)", title: "Tab \($0)", kind: .shell) }
        let single = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-3"))

        XCTAssertEqual(
            WarrenDesktopPaneBar.tabs(
                visibleIn: single,
                from: tabs,
                selected: tabs[2],
                mode: .rich
            ).map(\.id),
            ["tab-3"]
        )

        let twoPanes = single.split(targetPaneID: "pane-1", newTabID: "tab-1", axis: .horizontal)
        XCTAssertEqual(
            WarrenDesktopPaneBar.tabs(
                visibleIn: twoPanes,
                from: tabs,
                selected: tabs[2],
                mode: .rich
            ).map(\.id),
            ["tab-3", "tab-1"]
        )
    }

    /// Compact mode hides Session leaves, so the bar takes the Session list back.
    /// Without this, toggling the tree's density silently strips access to every
    /// Session that is not currently in a pane.
    func testPaneBarListsEverySessionWhenTheTreeStopsListingThem() {
        let tabs = (1...4).map { ClientTab(id: "tab-\($0)", title: "Tab \($0)", kind: .shell) }
        let single = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-3"))

        XCTAssertEqual(
            WarrenDesktopPaneBar.tabs(
                visibleIn: single,
                from: tabs,
                selected: tabs[2],
                mode: .compact
            ).map(\.id),
            ["tab-1", "tab-2", "tab-3", "tab-4"],
            "The projection's order is the one the user reordered by dragging"
        )

        // The one entry is not redundant here: it may be the only way back to a
        // Session with no pane, so the track still has to appear.
        XCTAssertTrue(
            WarrenDesktopPaneBar.showsTrack(
                entryCount: 1,
                mode: .compact
            )
        )
        XCTAssertFalse(
            WarrenDesktopPaneBar.showsTrack(
                entryCount: 0,
                mode: .compact
            )
        )
    }

    /// Closing the last pane is a view operation: the Session keeps running, so
    /// the projection still carries its Tab and the bar falls back to it rather
    /// than blinking empty while the tree catches up.
    func testPaneBarFallsBackToTheSelectedTabWhenNoPaneIsLive() {
        let tabs = [ClientTab(id: "tab-1", title: "Tab 1", kind: .shell)]
        let stale = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-gone"))

        XCTAssertEqual(
            WarrenDesktopPaneBar.tabs(
                visibleIn: stale,
                from: tabs,
                selected: tabs[0],
                mode: .rich
            ).map(\.id),
            ["tab-1"]
        )
        XCTAssertTrue(
            WarrenDesktopPaneBar.tabs(
                visibleIn: stale,
                from: tabs,
                selected: nil,
                mode: .rich
            ).isEmpty
        )
        // The switcher falls back the same way, so an empty scope with a
        // selection pending still renders one reachable entry.
        XCTAssertEqual(
            WarrenDesktopPaneBar.tabs(
                visibleIn: stale,
                from: [],
                selected: tabs[0],
                mode: .compact
            ).map(\.id),
            ["tab-1"]
        )
    }

    /// A scope the user emptied keeps nothing on screen. The tree falls back to
    /// a leaf that names no Session, so the bar filters it out instead of
    /// redrawing an identity for a Session that is not being shown. Falling back
    /// to the workspace's first Tab instead made the last close look like a
    /// no-op.
    func testClearedScopeLeavesThePaneBarEmpty() {
        let tabs = [ClientTab(id: "tab-1", title: "Tab 1", kind: .shell)]
        let empty = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-empty", tabID: "empty"))

        XCTAssertTrue(
            WarrenDesktopPaneBar.tabs(
                visibleIn: empty,
                from: tabs,
                selected: nil,
                mode: .rich
            ).isEmpty
        )
        XCTAssertNil(
            empty.reconcile(validTabIDs: Set(tabs.map(\.id)), fallbackTabID: nil),
            "with no selected Tab there is nothing to fall back to"
        )
    }

    /// The mode owns exactly one decision — which surface lists Sessions — and
    /// the presentation is both of its consequences. Resolving them together is
    /// what keeps the track and the identity slot from both claiming the row or
    /// both giving it up. The solo identity is also built only when it will be
    /// shown, so a Session-switcher mode never pays for it.
    func testPaneBarPresentationIsTrackXorIdentity() {
        let tabs = (1...3).map { ClientTab(id: "tab-\($0)", title: "Tab \($0)", kind: .shell) }
        let onePane = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let twoPanes = onePane.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)
        var soloBuilds = 0
        let solo: ([ClientTab]) -> WarrenDesktopSoloPaneIdentity.Model? = { entries in
            soloBuilds += 1
            return entries.first.map {
                WarrenDesktopSoloPaneIdentity.Model(
                    tabID: $0.id,
                    title: $0.title,
                    fullTitle: $0.title,
                    providerPresetID: nil,
                    mark: nil,
                    canClose: true
                )
            }
        }

        let richSolo = WarrenDesktopPaneBar.presentation(
            visibleIn: onePane,
            from: tabs,
            selected: tabs[0],
            mode: .rich,
            solo: solo
        )
        XCTAssertFalse(richSolo.showsTrack)
        XCTAssertEqual(richSolo.solo?.tabID, "tab-1")
        XCTAssertEqual(richSolo.listings.map(\.id), ["tab-1"])

        let richSplit = WarrenDesktopPaneBar.presentation(
            visibleIn: twoPanes,
            from: tabs,
            selected: tabs[0],
            mode: .rich,
            solo: solo
        )
        XCTAssertTrue(richSplit.showsTrack)
        XCTAssertNil(richSplit.solo)
        XCTAssertEqual(richSplit.listings.map(\.id), ["tab-1", "tab-2"])

        // Compact hands the Session list to the bar, so even one entry is a
        // track and the identity slot stays empty.
        let compact = WarrenDesktopPaneBar.presentation(
            visibleIn: onePane,
            from: tabs,
            selected: tabs[0],
            mode: .compact,
            solo: solo
        )
        XCTAssertTrue(compact.showsTrack)
        XCTAssertNil(compact.solo)
        XCTAssertEqual(compact.listings.map(\.id), ["tab-1", "tab-2", "tab-3"])

        XCTAssertEqual(soloBuilds, 1, "the identity is built only when no track is drawn")
    }

    /// The split view recurses into subtrees, so at a leaf `tree.count` is 1 no
    /// matter how many panes the layout holds. Pane chrome derived from it was
    /// therefore off in every split, which is why the root count is carried down
    /// explicitly rather than recomputed.
    func testLeafSubtreeCountIsNotTheLayoutPaneCount() {
        let initial = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))
        let twoPanes = initial.split(targetPaneID: "pane-1", newTabID: "tab-2", axis: .horizontal)

        XCTAssertEqual(twoPanes.count, 2)
        guard case .split(_, _, let first, let second) = twoPanes else {
            return XCTFail("Expected a split")
        }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
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

    func testReconcileFallbackUsesStablePaneIdentity() {
        let tree = SplitLayoutTree.leaf(SplitPaneItem(id: "stale", tabID: "closed"))

        let first = tree.reconcile(validTabIDs: ["open"], fallbackTabID: "open")
        let second = tree.reconcile(validTabIDs: ["open"], fallbackTabID: "open")

        XCTAssertEqual(first?.allPaneIDs, [SplitPaneItem.fallbackID(forTabID: "open")])
        XCTAssertEqual(first, second)
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

    // MARK: - Flattened placement

    /// The placement is what the content renders: one frame per pane and one
    /// band per divider, in preorder. A pane's view is keyed by its own id, so
    /// these frames are the whole story of where a terminal ends up.
    func testHorizontalPlacementSplitsTheContainerAroundItsDivider() {
        let tree = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
            second: .leaf(SplitPaneItem(id: "pane-b", tabID: "b"))
        )
        let placement = tree.placement(in: CGSize(width: 1_000, height: 100))

        XCTAssertEqual(placement.panes.map(\.id), ["pane-a", "pane-b"])
        // 995 points of travel cannot split evenly, so the leading pane takes
        // the extra point and the divider sits on 498 rather than between
        // pixels.
        XCTAssertEqual(
            placement.panes[0].frame,
            CGRect(x: 0, y: 0, width: 498, height: 100)
        )
        XCTAssertEqual(
            placement.panes[1].frame,
            CGRect(x: 503, y: 0, width: 497, height: 100)
        )
        let divider = try? XCTUnwrap(placement.dividers.first)
        XCTAssertEqual(divider?.path, [])
        XCTAssertEqual(divider?.axis, .horizontal)
        XCTAssertEqual(divider?.frame, CGRect(x: 498, y: 0, width: 5, height: 100))
        XCTAssertEqual(divider?.totalLength, 995)
    }

    func testVerticalPlacementSplitsAlongTheOtherAxis() {
        let tree = SplitLayoutTree.split(
            axis: .vertical,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
            second: .leaf(SplitPaneItem(id: "pane-b", tabID: "b"))
        )
        let placement = tree.placement(in: CGSize(width: 1_000, height: 400))

        XCTAssertEqual(
            placement.panes[0].frame,
            CGRect(x: 0, y: 0, width: 1_000, height: 198)
        )
        XCTAssertEqual(
            placement.dividers.first?.frame,
            CGRect(x: 0, y: 198, width: 1_000, height: 5)
        )
        XCTAssertEqual(
            placement.panes[1].frame,
            CGRect(x: 0, y: 203, width: 1_000, height: 197)
        )
    }

    /// A nested split keeps its own divider, and that divider's path is the one
    /// `updateRatio(path:)` addresses — not its depth-first index.
    func testNestedPlacementKeepsEachDividersPath() {
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
        let placement = tree.placement(in: CGSize(width: 1_000, height: 400))

        XCTAssertEqual(placement.panes.map(\.id), ["pane-a", "pane-b", "pane-c"])
        XCTAssertEqual(placement.dividers.map(\.path), [[], [true]])
        XCTAssertEqual(placement.dividers.last?.axis, .vertical)
        XCTAssertEqual(
            placement.dividers.last?.frame,
            CGRect(x: 503, y: 198, width: 497, height: 5)
        )
    }

    /// Panes and dividers tile the container exactly: nothing overlaps and
    /// nothing is left over, which is what makes the flattened layout draw the
    /// same thing the recursive one did.
    func testPlacementTilesTheContainer() {
        let tree = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.35,
            first: .split(
                axis: .vertical,
                ratio: 0.6,
                first: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
                second: .leaf(SplitPaneItem(id: "pane-b", tabID: "b"))
            ),
            second: .leaf(SplitPaneItem(id: "pane-c", tabID: "c"))
        )
        let size = CGSize(width: 900, height: 500)
        let placement = tree.placement(in: size)

        XCTAssertEqual(placement.panes.count, 3)
        let area = placement.panes.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
            + placement.dividers.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
        XCTAssertEqual(area, size.width * size.height, accuracy: 0.01)
        for pane in placement.panes {
            XCTAssertTrue(
                CGRect(origin: .zero, size: size).contains(pane.frame),
                "\(pane.id) escapes the container"
            )
        }
    }

    /// The divider cannot travel past the minimum size of the subtree on either
    /// side of it, and a container too small for both minimums pins it in the
    /// middle rather than letting it cross.
    func testDividerBoundsFollowTheSubtreeMinimums() {
        let tree = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
            second: .leaf(SplitPaneItem(id: "pane-b", tabID: "b"))
        )
        let roomy = tree.placement(in: CGSize(width: 1_000, height: 100)).dividers[0]
        XCTAssertEqual(roomy.minimumRatio, 260 / 995, accuracy: 0.001)
        XCTAssertEqual(roomy.maximumRatio, 1 - 260 / 995, accuracy: 0.001)

        let cramped = tree.placement(in: CGSize(width: 400, height: 100)).dividers[0]
        XCTAssertEqual(cramped.minimumRatio, 0.5)
        XCTAssertEqual(cramped.maximumRatio, 0.5)
    }

    func testSinglePaneFillsTheContainerWithNoDivider() {
        let placement = SplitLayoutTree
            .leaf(SplitPaneItem(id: "pane-a", tabID: "a"))
            .placement(in: CGSize(width: 320, height: 200))
        XCTAssertTrue(placement.dividers.isEmpty)
        XCTAssertEqual(
            placement.panes.first?.frame,
            CGRect(x: 0, y: 0, width: 320, height: 200)
        )
    }

    /// A Session the panel was already drawing on its own keeps the pane
    /// identity it had, so adopting it into the layout does not re-create the
    /// terminal the user is looking at. The Session this request creates then
    /// splits the pane it adopted, which is what puts the new pane beside the
    /// Session that asked for it.
    func testSplitReusesTheIdentityOfThePaneItAdopts() {
        let layout = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-a", tabID: "a"))
        let adoptedPaneID = SplitPaneItem.fallbackID(forTabID: "b")

        let adopted = layout.split(
            targetPaneID: "pane-a",
            newTabID: "b",
            axis: .vertical,
            newPaneID: adoptedPaneID
        )
        XCTAssertEqual(adopted.allTabIDs, ["a", "b"])
        XCTAssertEqual(adopted.item(forTabID: "b")?.id, adoptedPaneID)

        let split = adopted.split(
            targetPaneID: adoptedPaneID,
            newTabID: "c",
            axis: .vertical
        )
        XCTAssertEqual(split.allTabIDs, ["a", "b", "c"])
        XCTAssertEqual(split.allPaneIDs.count, 3)
        XCTAssertEqual(
            split.allPaneIDs.filter { $0 == adoptedPaneID }.count,
            1,
            "The adopted pane keeps its one identity"
        )
        XCTAssertNotEqual(split.item(forTabID: "c")?.id, adoptedPaneID)
    }

    /// Every frame lands on a whole point, and the panes plus their dividers
    /// still cover the container exactly, whatever the container size and ratio
    /// are. A divider placed between pixels is what made the panes flip by a
    /// point between layout passes: each flip reads as a new viewport, so the
    /// PTY is resized for a divider that never moved.
    func testPlacementSnapsToPointsAndCoversFractionalContainers() {
        let tree = SplitLayoutTree.split(
            axis: .horizontal,
            ratio: 0.5927,
            first: .split(
                axis: .vertical,
                ratio: 0.413,
                first: .leaf(SplitPaneItem(id: "pane-a", tabID: "a")),
                second: .leaf(SplitPaneItem(id: "pane-b", tabID: "b"))
            ),
            second: .leaf(SplitPaneItem(id: "pane-c", tabID: "c"))
        )
        for size in [
            CGSize(width: 1_217.5, height: 815.25),
            CGSize(width: 809.5, height: 443.75),
            CGSize(width: 320, height: 200),
        ] {
            let placement = tree.placement(in: size)
            let container = CGRect(
                origin: .zero,
                size: CGSize(width: size.width.rounded(), height: size.height.rounded())
            )
            let frames = placement.panes.map(\.frame) + placement.dividers.map(\.frame)
            let area = frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
            XCTAssertEqual(
                area,
                container.width * container.height,
                accuracy: 0.01,
                "Panes and dividers must cover \(size) exactly"
            )
            for frame in frames {
                for value in [frame.minX, frame.minY, frame.width, frame.height] {
                    XCTAssertEqual(value, value.rounded(), "\(frame) is not on a point")
                }
            }
        }
    }
}

/// Pane groups are Host state, so the projection carries them and answers the
/// questions a renderer asks: which arrangements belong to this scope, which one
/// shows a Session, and in what order.
final class WarrenDesktopPaneGroupProjectionTests: XCTestCase {
    func testProjectionCarriesHostPaneGroupsInHostOrder() {
        let hostID = HostID()
        let workspaceID = WorkspaceID()
        let sessionA = TerminalSessionID()
        let sessionB = TerminalSessionID()
        let sessionC = TerminalSessionID()
        let later = PaneGroup(
            id: PaneGroupID(),
            hostID: hostID,
            workspaceID: workspaceID,
            name: "second",
            order: 1,
            tree: .leaf(sessionID: sessionB),
            revision: 3
        )
        let earlier = PaneGroup(
            id: PaneGroupID(),
            hostID: hostID,
            workspaceID: workspaceID,
            name: "first",
            order: 0,
            tree: .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(paneID: PaneID(), sessionID: sessionA),
                second: .leaf(sessionID: sessionC)
            ),
            revision: 7
        )
        let otherWorkspace = PaneGroup(
            id: PaneGroupID(),
            hostID: hostID,
            workspaceID: WorkspaceID(),
            tree: .leaf(sessionID: sessionB)
        )
        let projection = WarrenDesktopProjection(
            host: WarrenDomain.Host(id: hostID, name: "test"),
            projects: [],
            workspaces: [
                Workspace(
                    id: workspaceID,
                    projectID: ProjectID(),
                    name: "main",
                    path: "/tmp"
                )
            ],
            paneGroups: [later, otherWorkspace, earlier]
        )

        XCTAssertEqual(projection.paneGroups(in: workspaceID).map { $0.id }, [earlier.id, later.id])
        XCTAssertEqual(projection.paneGroups(in: workspaceID).first?.paneCount, 2)
        XCTAssertEqual(projection.paneGroup(containingSession: sessionC)?.id, earlier.id)
        XCTAssertEqual(projection.paneGroup(containingSession: sessionC)?.paneIndex(forSession: sessionC), 2)
        XCTAssertNil(projection.paneGroup(containingSession: TerminalSessionID()))
        XCTAssertEqual(projection.paneGroups(in: workspaceID).first?.tree.sessionIDs, [sessionA, sessionC])
    }
}

final class WarrenDesktopPaneGroupMappingTests: XCTestCase {
    func testHostTreeBecomesTheRenderersTreeAndBack() {
        let sessionA = TerminalSessionID()
        let sessionB = TerminalSessionID()
        let paneID = PaneID()
        let host = PaneNode.split(
            axis: .horizontal,
            ratio: 0.25,
            first: .leaf(paneID: paneID, sessionID: sessionA),
            second: .leaf(sessionID: sessionB)
        )
        let local = WarrenDesktopPaneGroupMapping.tree(from: host)
        XCTAssertEqual(local.count, 2)
        guard case .split(let axis, let ratio, _, _) = local else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(ratio, 0.25, accuracy: 0.001)
        XCTAssertEqual(local.leaves.map(\.id), [paneID.description, SplitPaneItem.fallbackID(forTabID: "remote-\(sessionB.description)")])
        XCTAssertEqual(local.allTabIDs, ["remote-\(sessionA.description)", "remote-\(sessionB.description)"])

        // A round trip preserves the Host's pane identity and hands the pane it
        // never assigned back as an empty identity for the Host to fill in.
        let rebuilt = WarrenDesktopPaneGroupMapping.paneNode(from: local) { tabID in
            WarrenDesktopPaneGroupMapping.sessionID(forTabID: tabID)
        }
        XCTAssertEqual(rebuilt, .split(
            axis: .horizontal,
            ratio: 0.25,
            first: .leaf(paneID: paneID, sessionID: sessionA),
            second: .leaf(paneID: nil, sessionID: sessionB)
        ))

        // A Tab that no longer maps to a Session is dropped with the split that
        // only held it: the renderer never sends a pane it cannot show.
        XCTAssertNil(WarrenDesktopPaneGroupMapping.paneNode(from: local) { _ in nil })
    }
}
