import XCTest
import WarrenDesignSystem
@testable import WarrenDesktop

/// The tab track's reveal contract: a selection inside the visible band must not
/// move the track, and one that crosses an edge moves it by the smallest
/// distance that brings it back. These are the cases that replaced the old
/// center-on-every-change math.
final class WarrenDesktopTabScrollPositionTests: XCTestCase {
    private let tabWidth: CGFloat = 150
    private let viewportWidth: CGFloat = 600
    private let trackWidth: CGFloat = 1500 // 10 tabs, 900pt of overflow.

    private func origin(
        selectedIndex: Int,
        currentOriginX: CGFloat,
        trackWidth: CGFloat? = nil,
        viewportWidth: CGFloat? = nil,
        revealInset: CGFloat? = nil,
        groupMarkSlotWidth: CGFloat = 0
    ) -> CGFloat {
        WarrenDesktopTabScrollPosition.revealOriginX(
            selectedMinX: CGFloat(selectedIndex) * tabWidth + groupMarkSlotWidth,
            tabWidth: tabWidth,
            trackWidth: (trackWidth ?? self.trackWidth) + groupMarkSlotWidth,
            viewportWidth: viewportWidth ?? self.viewportWidth,
            currentOriginX: currentOriginX,
            revealInset: revealInset
                ?? WarrenDesktopTabScrollPosition.defaultRevealInset
        )
    }

    func testVisibleSelectionLeavesTheTrackAlone() {
        // Origin 300 shows [336, 864]; tab 3 spans [450, 600].
        XCTAssertEqual(origin(selectedIndex: 3, currentOriginX: 300), 300)
    }

    func testSelectionPastTheTrailingEdgeMovesTheSmallestDistance() {
        // Origin 0 shows [36, 564]; tab 4 spans [600, 750].
        let moved = origin(selectedIndex: 4, currentOriginX: 0)
        XCTAssertEqual(moved, 186)
        XCTAssertEqual(moved + viewportWidth - 36, 750)
    }

    func testSelectionPastTheLeadingEdgeMovesTheSmallestDistance() {
        // Origin 600 shows [636, 1164]; tab 3 spans [450, 600].
        let moved = origin(selectedIndex: 3, currentOriginX: 600)
        XCTAssertEqual(moved, 414)
        XCTAssertEqual(moved + 36, 450)
    }

    func testSelectionInsideTheFringeIsPulledClearOfTheEdge() {
        // Already on screen but under the trailing fade and chevron.
        let moved = origin(selectedIndex: 3, currentOriginX: 0)
        XCTAssertEqual(moved, 36)
    }

    func testSelectionAtTheTrackStartClampsToZero() {
        XCTAssertEqual(origin(selectedIndex: 0, currentOriginX: 0), 0)
        XCTAssertEqual(origin(selectedIndex: 0, currentOriginX: 300), 0)
    }

    func testSelectionAtTheTrackEndClampsToTheMaximumOrigin() {
        // Origin 900 is the end of the 1500pt track.
        XCTAssertEqual(origin(selectedIndex: 9, currentOriginX: 900), 900)
    }

    func testTrackThatFitsNeverScrolls() {
        XCTAssertEqual(
            origin(selectedIndex: 1, currentOriginX: 0, trackWidth: 450),
            0
        )
    }

    func testOutOfRangeOriginIsNormalizedBeforeRevealing() {
        // A raw origin left of the track normalizes to 0 and stays there.
        XCTAssertEqual(origin(selectedIndex: 1, currentOriginX: -500), 0)
        // A raw origin past the end normalizes to the maximum origin.
        XCTAssertEqual(origin(selectedIndex: 8, currentOriginX: 9_999), 900)
    }

    /// A drawn group's chip is a slot rather than a Tab, so every Tab behind it
    /// starts one chip-width later and the reveal has to follow.
    func testGroupChipSlotShiftsTheRevealedOrigin() {
        XCTAssertEqual(origin(selectedIndex: 4, currentOriginX: 0), 186)
        XCTAssertEqual(
            origin(
                selectedIndex: 4,
                currentOriginX: 0,
                groupMarkSlotWidth: WarrenLayoutMetrics.tabGroupMarkSlotWidth
            ),
            186 + WarrenLayoutMetrics.tabGroupMarkSlotWidth
        )
    }

    func testNarrowViewportYieldsTheInsetBeforeTheBand() {
        // A 40pt viewport cannot hold two 36pt margins, so each yields to 20pt.
        XCTAssertEqual(
            origin(
                selectedIndex: 0,
                currentOriginX: 100,
                trackWidth: 300,
                viewportWidth: 40
            ),
            0
        )
        XCTAssertEqual(
            origin(
                selectedIndex: 1,
                currentOriginX: 100,
                trackWidth: 300,
                viewportWidth: 40
            ),
            260
        )
    }
}
