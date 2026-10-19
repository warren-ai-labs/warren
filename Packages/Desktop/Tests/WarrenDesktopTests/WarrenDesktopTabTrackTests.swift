import XCTest

@testable import WarrenDesktop

/// How the tab track sizes its Tabs and when the selection plate travels.
final class WarrenDesktopTabTrackTests: XCTestCase {
    func testFewTabsTakeTheCeiling() {
        XCTAssertEqual(
            WarrenDesktopTabTrack.tabWidth(count: 2, viewport: 1_000),
            WarrenDesktopTabTrack.maximumWidth
        )
    }

    func testTabsNarrowEvenlyAsMoreArrive() {
        let width = WarrenDesktopTabTrack.tabWidth(count: 6, viewport: 1_000)
        XCTAssertEqual(width, 166, "Six Tabs split the track rather than stretching past the ceiling")
        XCTAssertLessThanOrEqual(width, WarrenDesktopTabTrack.maximumWidth)
    }

    func testTabsStopAtTheFloorAndTheTrackScrolls() {
        let width = WarrenDesktopTabTrack.tabWidth(count: 14, viewport: 1_000)
        XCTAssertEqual(width, WarrenDesktopTabTrack.minimumWidth)
        XCTAssertTrue(
            WarrenDesktopTabTrack.overflows(count: 14, tabWidth: width, viewport: 1_000)
        )
        XCTAssertFalse(
            WarrenDesktopTabTrack.overflows(count: 6, tabWidth: 166, viewport: 1_000)
        )
    }

    func testGroupMarksComeOutOfTheTabSpace() {
        XCTAssertEqual(
            WarrenDesktopTabTrack.tabWidth(count: 4, viewport: 1_000, groupMarkTotalWidth: 100),
            WarrenDesktopTabTrack.maximumWidth,
            "Four Tabs still have room for the ceiling once a group's mark is reserved"
        )
        XCTAssertEqual(
            WarrenDesktopTabTrack.tabWidth(count: 8, viewport: 1_000, groupMarkTotalWidth: 100),
            112
        )
    }

    func testThePlateTravelsBetweenNeighboursAndNotAcrossScreens() {
        XCTAssertTrue(
            WarrenDesktopTabTrack.plateTravels(from: 1, to: 2, tabWidth: 150, viewport: 600)
        )
        XCTAssertFalse(
            WarrenDesktopTabTrack.plateTravels(from: 0, to: 12, tabWidth: 150, viewport: 600),
            "Twelve Tabs away is more than a viewport: the plate appears there instead"
        )
        XCTAssertTrue(
            WarrenDesktopTabTrack.plateTravels(from: nil, to: 5, tabWidth: 150, viewport: 600),
            "The first selection has nowhere to travel from"
        )
    }
}
