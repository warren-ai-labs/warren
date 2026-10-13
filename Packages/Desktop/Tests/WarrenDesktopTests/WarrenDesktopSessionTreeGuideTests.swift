import AppKit
import SwiftUI
import XCTest
import WarrenDesignSystem
@testable import WarrenDesktop

/// A worktree group is told apart by its rhythm and its shared status column,
/// so these tests pin the geometry the rows share.
final class WarrenDesktopSessionTreeGuideTests: XCTestCase {
    /// Every dot sits in one column, and that column fits inside the project
    /// avatar's slot, so the text after it starts on the project name's column
    /// whether or not a dot is drawn.
    func testStatusGutterFitsTheLeadingSlotAndTheGroupKeepsItsRhythm() {
        XCTAssertLessThanOrEqual(
            WarrenLayoutMetrics.sidebarStatusGutterWidth,
            WarrenDesktopSidebarRowLayout.leadingSlotWidth,
            "The status gutter has to fit the slot every worktree row reserves"
        )
        XCTAssertLessThanOrEqual(
            WarrenLayoutMetrics.sidebarStatusDotSize * 1.6,
            WarrenLayoutMetrics.sidebarStatusGutterWidth,
            "A mark's slot has to fit the gutter so a dot never shifts the text"
        )
        XCTAssertEqual(
            WarrenDesktopSidebarRowLayout.leadingSlotWidth,
            WarrenLayoutMetrics.sidebarRowIconSlotSize,
            "The leading slot is the project avatar's slot"
        )
        XCTAssertEqual(WarrenDesktopSidebarRowLayout.rowSpacing, 2)
        XCTAssertEqual(WarrenDesktopSidebarRowLayout.projectSectionSpacing, 16)
        XCTAssertEqual(WarrenDesktopSidebarRowLayout.cornerRadius, WarrenRadius.panelRow)
    }

    /// The gutter is the sidebar's only status channel, so every drawn mark
    /// lands there: the requests and failures, an unseen completion, and the
    /// working pulse.
    func testStatusGutterDrawsEveryDrawnMark() {
        let drawn = WarrenActivityMark.allCases.filter(WarrenDesktopSidebarStatusGutter.draws)
        for mark in [WarrenActivityMark.working, .ready, .inputNeeded, .approvalNeeded, .failed] {
            XCTAssertTrue(drawn.contains(mark), "\(mark) should draw in the gutter")
        }
        XCTAssertEqual(drawn, WarrenActivityMark.allCases.filter(\.isDrawn))
    }

    /// The group's pointer source is AppKit, not SwiftUI: its rows are Buttons,
    /// so a container `.onHover` never hears about them. Three things are pinned
    /// here — the sensor reports a move without taking the click, an enter that
    /// only says where the pointer is reports nothing, and a move does.
    @MainActor
    func testHoverSensorReportsThePointerAndLeavesClicksToTheRows() {
        var reports: [Bool] = []
        let sensor = WarrenDesktopHoverSensor.SensorView()
        sensor.onHover = { reports.append($0) }
        sensor.updateTrackingAreas()

        XCTAssertFalse(
            sensor.trackingAreas.isEmpty,
            "The sensor has to watch a tracking area to see the pointer"
        )
        XCTAssertTrue(
            sensor.trackingAreas.allSatisfy { $0.options.contains(.mouseMoved) },
            "Only a move inside the area proves the pointer went there"
        )
        XCTAssertNil(
            sensor.hitTest(NSPoint(x: 10, y: 10)),
            "The sensor watches the pointer; the row below still takes the click"
        )

        sensor.mouseEntered(with: Self.pointerEvent(.mouseEntered))
        XCTAssertEqual(
            reports, [],
            "An enter reports position, not movement, so it must not count as hover"
        )
        sensor.mouseMoved(with: Self.pointerMoveEvent())
        sensor.mouseExited(with: Self.pointerEvent(.mouseExited))
        XCTAssertEqual(reports, [true, false])
    }

    private static func pointerMoveEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        )!
    }

    private static func pointerEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        )!
    }
}
