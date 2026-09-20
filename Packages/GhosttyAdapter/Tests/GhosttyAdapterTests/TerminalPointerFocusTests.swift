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

    // MARK: - Window-activating click

    /// The click that activates the window has to reach the view, or it cannot
    /// move focus to the pane it landed in.
    @MainActor
    func testSurfaceAcceptsFirstMouse() {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    /// Accepting it must not also forward it to the program. A press delivered
    /// to a mouse-mode program moves the cursor in an editor or presses a button
    /// in a TUI, which is not what a click to focus a window asked for.
    @MainActor
    func testWindowActivatingClickIsNotForwardedToTheProgram() throws {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let click = try makeClick(eventNumber: 4321)

        // AppKit asks this for the activating click, and the answer records
        // which `mouseDown` to withhold.
        _ = view.acceptsFirstMouse(for: click)
        view.mouseDown(with: click)

        XCTAssertTrue(
            view.suppressesNextLeftMouseUp,
            "A withheld press must withhold its release, or the program sees a release alone."
        )
        XCTAssertNil(
            view.pointerSelectionStartPoint,
            "The activating click must not begin a selection."
        )
    }

    /// The release is withheld exactly once. A later real click has to work
    /// normally.
    @MainActor
    func testReleaseSuppressionAppliesOnlyToTheActivatingClick() throws {
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let activating = try makeClick(eventNumber: 4321)
        _ = view.acceptsFirstMouse(for: activating)
        view.mouseDown(with: activating)
        view.mouseUp(with: try makeClick(eventNumber: 4321, type: .leftMouseUp))
        XCTAssertFalse(view.suppressesNextLeftMouseUp)

        // A subsequent click is an ordinary one: it starts a selection.
        view.mouseDown(with: try makeClick(eventNumber: 4322))

        XCTAssertNotNil(view.pointerSelectionStartPoint)
        XCTAssertFalse(view.suppressesNextLeftMouseUp)
    }

    private func makeClick(
        eventNumber: Int,
        type: NSEvent.EventType = .leftMouseDown
    ) throws -> NSEvent {
        let event = NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: 1
        )
        return try XCTUnwrap(event)
    }
}
