import SwiftUI
import XCTest
@testable import WarrenDesktop

/// The pane layers tab drop zones over an AppKit terminal view. Those zones
/// must stay invisible to mouse hit-testing: a hit-testable transparent layer
/// makes the SwiftUI host answer every click over the terminal, which breaks
/// click-to-position, selection drags, and terminal mouse reporting.
final class WarrenDesktopSplitDropOverlayHitTestTests: XCTestCase {
    private final class TerminalStandInView: NSView {}

    private struct TerminalStandIn: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @MainActor
    private func terminalReceivesCenterClick<Content: View>(
        @ViewBuilder content: (NSView) -> Content
    ) -> Bool {
        let terminal = TerminalStandInView(frame: .zero)
        let hosting = NSHostingView(rootView: content(terminal))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting.hitTest(NSPoint(x: 200, y: 150)) === terminal
    }

    @MainActor
    func testDropOverlayLeavesTerminalClicksToAppKit() {
        let overlaid = terminalReceivesCenterClick { terminal in
            ZStack {
                TerminalStandIn(view: terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                WarrenDesktopSplitDropOverlay(canSplit: true, onDrop: { _, _ in })
            }
        }
        XCTAssertTrue(
            overlaid,
            "drop zones must not take a hit-test shape over the terminal"
        )

        let maxedOut = terminalReceivesCenterClick { terminal in
            ZStack {
                TerminalStandIn(view: terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                WarrenDesktopSplitDropOverlay(canSplit: false, onDrop: { _, _ in })
            }
        }
        XCTAssertTrue(
            maxedOut,
            "the replace-only drop zone must not take a hit-test shape either"
        )
    }

    /// Pins the AppKit behaviour the overlay relies on, so a future change that
    /// reintroduces `contentShape` fails with a readable diagnosis.
    @MainActor
    func testHitTestableTransparentLayerWouldSwallowTerminalClicks() {
        let swallowed = terminalReceivesCenterClick { terminal in
            ZStack {
                TerminalStandIn(view: terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }
        }
        XCTAssertFalse(swallowed)
    }

    /// The pane selects itself on a click in its chrome. That gesture must stay
    /// simultaneous so the terminal keeps receiving the same click.
    @MainActor
    func testSimultaneousPaneFocusGestureKeepsTerminalClicks() {
        let reaches = terminalReceivesCenterClick { terminal in
            ZStack {
                TerminalStandIn(view: terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { })
        }
        XCTAssertTrue(reaches)
    }
}
