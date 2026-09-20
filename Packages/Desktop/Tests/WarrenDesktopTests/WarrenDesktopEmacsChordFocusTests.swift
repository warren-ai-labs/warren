import AppKit
import XCTest
@testable import WarrenDesktop

/// `C-x` is a terminal command, and the monitor that implements it sees every
/// key in the app. These cover the gate that keeps it off keys belonging to
/// anything that is not a terminal.
final class WarrenDesktopEmacsChordFocusTests: XCTestCase {
    @MainActor
    func testChordIsClaimedWhileTheTerminalHasFocus() throws {
        let monitor = EmacsSplitChordMonitor()
        monitor.isTerminalFocused = { true }
        let event = try controlX()

        XCTAssertNil(monitor.handle(event: event))
        XCTAssertTrue(monitor.inChord)
    }

    /// The embedded editor is a WKWebView, which the previous denylist of text
    /// views and text fields did not cover: `C-x` was swallowed here and
    /// code-server's Cut never ran.
    @MainActor
    func testChordIsNotClaimedWhileAnotherSurfaceHasFocus() throws {
        let monitor = EmacsSplitChordMonitor()
        monitor.isTerminalFocused = { false }
        let event = try controlX()

        XCTAssertNotNil(monitor.handle(event: event))
        XCTAssertFalse(monitor.inChord)
    }

    /// Focus can leave the terminal while a chord is half-typed. The pending
    /// chord must not then consume the next key in whatever took focus.
    @MainActor
    func testFocusLeavingTheTerminalCancelsAPendingChord() throws {
        let monitor = EmacsSplitChordMonitor()
        var terminalHasFocus = true
        monitor.isTerminalFocused = { terminalHasFocus }
        _ = monitor.handle(event: try controlX())
        XCTAssertTrue(monitor.inChord)

        terminalHasFocus = false
        let next = try key("2")

        XCTAssertNotNil(monitor.handle(event: next))
        XCTAssertFalse(monitor.inChord)
    }

    /// A split action is only emitted for the second key of the chord, and only
    /// while the terminal still owns the keyboard.
    @MainActor
    func testSecondChordKeyEmitsItsAction() throws {
        let monitor = EmacsSplitChordMonitor()
        monitor.isTerminalFocused = { true }
        var actions: [EmacsSplitAction] = []
        monitor.onAction = { action in
            actions.append(action)
            return true
        }
        _ = monitor.handle(event: try controlX())

        XCTAssertNil(monitor.handle(event: try key("3")))
        XCTAssertEqual(actions, [.splitRight])
        XCTAssertFalse(monitor.inChord)
    }

    private func controlX() throws -> NSEvent {
        try key("x", modifiers: .control)
    }

    private func key(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )
        return try XCTUnwrap(event)
    }
}
