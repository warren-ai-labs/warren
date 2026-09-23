import XCTest
import AppKit
import WebKit
@testable import Warren

/// The browser viewer's keyboard signal (RFC 0022 §8.4).
///
/// The viewer is a `WKWebView`. A click on its content hands AppKit's first
/// responder to the web process without asking the subclass to become first
/// responder, so the Terminal cannot observe the keyboard leaving. Warren
/// therefore routes the region's focus from the pointer boundary, and these
/// tests pin the boundary's policy.
final class WarrenBrowserViewerFocusTests: XCTestCase {
    func testPressInsideTheViewerTakesTheKeyboard() {
        XCTAssertEqual(
            WarrenBrowserViewerFocusBoundary.keyboardFocusChange(
                for: .leftMouseDown,
                hitViewer: true
            ),
            true
        )
        XCTAssertEqual(
            WarrenBrowserViewerFocusBoundary.keyboardFocusChange(
                for: .leftMouseDown,
                hitViewer: false
            ),
            false
        )
    }

    /// Only the press decides. A release outside the region routinely ends a
    /// drag that began inside it, and acting on it would read as the keyboard
    /// leaving while the user is still working in the page.
    func testReleaseAndMovementDoNotChangeViewerKeyboardFocus() {
        XCTAssertNil(
            WarrenBrowserViewerFocusBoundary.keyboardFocusChange(
                for: .leftMouseUp,
                hitViewer: false
            )
        )
        XCTAssertNil(
            WarrenBrowserViewerFocusBoundary.keyboardFocusChange(
                for: .leftMouseUp,
                hitViewer: true
            )
        )
        XCTAssertNil(
            WarrenBrowserViewerFocusBoundary.keyboardFocusChange(
                for: .mouseMoved,
                hitViewer: true
            )
        )
    }

    /// A region that closes while focused has to release the keyboard, or the
    /// Terminal's `wantsTerminalFocus` stays false and the pane refuses input
    /// until the next click.
    @MainActor
    func testAViewerThatGoesAwayReleasesTheKeyboard() {
        let model = WarrenBrowserViewerFocusModel()
        XCTAssertFalse(model.hasKeyboardFocus)
        model.register(sessionID: "viewer", webView: WKWebView())
        model.setKeyboardFocusForTesting(true)
        XCTAssertTrue(model.hasKeyboardFocus)
        model.unregister(sessionID: "viewer")
        XCTAssertFalse(model.hasKeyboardFocus)
    }
}
