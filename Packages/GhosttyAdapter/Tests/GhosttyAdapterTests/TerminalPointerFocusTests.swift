import AppKit
import XCTest
@testable import GhosttyAdapter
@testable import GhosttyTerminal

/// Covers the "is the user typing into a terminal at all" question an app-level
/// key monitor asks before claiming a keystroke, and the pointer behaviour the
/// terminal surface publishes.
final class TerminalPointerFocusTests: XCTestCase {
    @MainActor
    func testTerminalViewIsRecognizedAsTerminalResponder() {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertTrue(TerminalSurfaceManager.isTerminalResponder(view))
    }

    /// A surface's real first responder can be a descendant of the terminal
    /// view, so the answer has to hold for the whole subtree.
    @MainActor
    func testDescendantOfTerminalViewIsRecognized() {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let child = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.addSubview(child)

        XCTAssertTrue(TerminalSurfaceManager.isTerminalResponder(child))
    }

    /// The embedded editor is a WKWebView, and a text field is the sidebar's
    /// rename box. Neither may be treated as the terminal: that is what made
    /// `C-x` disappear from the editor instead of cutting a selection.
    @MainActor
    func testUnrelatedViewIsNotTerminalResponder() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))

        XCTAssertFalse(TerminalSurfaceManager.isTerminalResponder(field))
    }

    @MainActor
    func testMissingResponderIsNotTerminalResponder() {
        XCTAssertFalse(TerminalSurfaceManager.isTerminalResponder(nil))
    }

    /// A window is the responder whenever nothing in it has claimed focus.
    @MainActor
    func testWindowResponderIsNotTerminalResponder() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        XCTAssertFalse(TerminalSurfaceManager.isTerminalResponder(window))
    }

    // MARK: - Pointer shape

    @MainActor
    func testOrdinaryCellsUseAnIBeam() {
        XCTAssertEqual(AppTerminalView.cursor(for: .text), NSCursor.iBeam)
    }

    @MainActor
    func testHoveredLinkUsesAPointingHand() {
        XCTAssertEqual(AppTerminalView.cursor(for: .pointer), NSCursor.pointingHand)
    }

    /// Shapes with no AppKit equivalent fall back to the arrow rather than
    /// borrowing an unrelated cursor.
    @MainActor
    func testUnmappableShapesFallBackToTheArrow() {
        XCTAssertEqual(AppTerminalView.cursor(for: .wait), NSCursor.arrow)
        XCTAssertEqual(AppTerminalView.cursor(for: .nwseResize), NSCursor.arrow)
    }

    @MainActor
    func testResizeShapesFollowTheirAxis() {
        XCTAssertEqual(AppTerminalView.cursor(for: .colResize), NSCursor.resizeLeftRight)
        XCTAssertEqual(AppTerminalView.cursor(for: .rowResize), NSCursor.resizeUpDown)
    }

    /// A terminal that never raises a shape action still reads as text, so the
    /// pointer is right from the first frame.
    @MainActor
    func testSurfaceStartsWithATextPointer() {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertEqual(view.terminalMouseShape, .text)
    }

    // MARK: - Selection autoscroll

    @MainActor
    func testDragInsideTheViewDoesNotAutoscroll() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 100)

        XCTAssertEqual(
            AppTerminalView.autoscrollOvershoot(for: CGPoint(x: 10, y: 50), in: bounds),
            0
        )
    }

    /// Ghostty's y axis grows downward, so a drag above the view is negative and
    /// has to scroll toward earlier output.
    @MainActor
    func testDragAboveTheViewScrollsTowardEarlierOutput() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 100)

        XCTAssertGreaterThan(
            AppTerminalView.autoscrollOvershoot(for: CGPoint(x: 10, y: -20), in: bounds),
            0
        )
    }

    @MainActor
    func testDragBelowTheViewScrollsTowardLaterOutput() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 100)

        XCTAssertLessThan(
            AppTerminalView.autoscrollOvershoot(for: CGPoint(x: 10, y: 140), in: bounds),
            0
        )
    }

    /// A drag flung far past the edge stays controllable instead of running
    /// through the whole scrollback in a few ticks.
    @MainActor
    func testAutoscrollRateIsCapped() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 100)
        let nearby = AppTerminalView.autoscrollOvershoot(
            for: CGPoint(x: 10, y: -20),
            in: bounds
        )
        let faraway = AppTerminalView.autoscrollOvershoot(
            for: CGPoint(x: 10, y: -5000),
            in: bounds
        )

        XCTAssertGreaterThan(faraway, nearby)
        XCTAssertLessThanOrEqual(faraway, 5)
    }
}
