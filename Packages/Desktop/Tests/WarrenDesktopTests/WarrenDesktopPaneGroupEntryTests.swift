import XCTest
@testable import WarrenDesktop

/// Entering a pane arrangement has to choose a Session to activate.
///
/// A group step carries no Tab of its own, so the choice follows the same
/// precedence the panel uses for a visited Tab: the current selection when the
/// arrangement holds it, then the pane the user last worked in, then the
/// arrangement's first pane. Without it the keyboard stayed in the arrangement
/// that had just been parked.
final class WarrenDesktopPaneGroupEntryTests: XCTestCase {
    private let first = SplitPaneItem(id: "pane-first", tabID: "tab-first")
    private let second = SplitPaneItem(id: "pane-second", tabID: "tab-second")

    private var split: SplitLayoutTree {
        .split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))
    }

    func testSelectionInsideTheArrangementWins() {
        XCTAssertEqual(
            WarrenDesktopPaneGroupEntry.tabID(
                in: split,
                selectedTabID: "tab-second",
                rememberedPaneID: "pane-first"
            ),
            "tab-second"
        )
    }

    /// A selection in another arrangement must not drag its Tab into this one.
    /// The pane the user last worked in here is the next best answer.
    func testSelectionOutsideTheArrangementFallsBackToTheRememberedPane() {
        XCTAssertEqual(
            WarrenDesktopPaneGroupEntry.tabID(
                in: split,
                selectedTabID: "tab-elsewhere",
                rememberedPaneID: "pane-second"
            ),
            "tab-second"
        )
    }

    /// A remembered pane that this arrangement no longer holds lands on its
    /// first pane instead of leaving the keyboard with no target at all.
    func testUnknownRememberedPaneFallsBackToTheFirstLeaf() {
        XCTAssertEqual(
            WarrenDesktopPaneGroupEntry.tabID(
                in: split,
                selectedTabID: "tab-elsewhere",
                rememberedPaneID: "pane-gone"
            ),
            "tab-first"
        )
    }

    func testLonePaneIsItsOwnTarget() {
        XCTAssertEqual(
            WarrenDesktopPaneGroupEntry.tabID(
                in: .leaf(first),
                selectedTabID: nil,
                rememberedPaneID: nil
            ),
            "tab-first"
        )
    }
}
