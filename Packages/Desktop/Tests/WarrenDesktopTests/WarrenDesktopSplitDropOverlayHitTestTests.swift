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
                WarrenDesktopSplitDropOverlay(paneID: "pane-1", canSplit: true)
                    .environmentObject(WarrenDesktopTabDrag())
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
                WarrenDesktopSplitDropOverlay(paneID: "pane-1", canSplit: false)
                    .environmentObject(WarrenDesktopTabDrag())
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

    // MARK: - Drop regions

    /// Every point of a splittable pane belongs to exactly one target. The
    /// earlier layout gave all five destinations the full pane, so the center
    /// silently shadowed the four directional zones.
    func testZoneGeometryTilesThePane() {
        let size = CGSize(width: 800, height: 500)
        let rects = WarrenDesktopSplitDropZones.rects(in: size)
        let zones = [rects.top, rects.bottom, rects.left, rects.right, rects.center]

        for (index, lhs) in zones.enumerated() {
            for rhs in zones[(index + 1)...] {
                XCTAssertFalse(
                    lhs.intersects(rhs),
                    "drop zones must not overlap: \(lhs) and \(rhs)"
                )
            }
        }

        let area = zones.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, size.width * size.height, accuracy: 0.001)
        XCTAssertEqual(rects.top, CGRect(x: 0, y: 0, width: 800, height: 125))
        XCTAssertEqual(rects.bottom, CGRect(x: 0, y: 375, width: 800, height: 125))
        XCTAssertEqual(rects.left, CGRect(x: 0, y: 125, width: 200, height: 250))
        XCTAssertEqual(rects.right, CGRect(x: 600, y: 125, width: 200, height: 250))
        XCTAssertEqual(rects.center, CGRect(x: 200, y: 125, width: 400, height: 250))
    }

    @MainActor
    func testResolverMapsEachZone() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(
            WarrenDesktopPaneDropResolver.target(in: size, at: CGPoint(x: 200, y: 10), canSplit: true),
            .top
        )
        XCTAssertEqual(
            WarrenDesktopPaneDropResolver.target(in: size, at: CGPoint(x: 200, y: 290), canSplit: true),
            .bottom
        )
        XCTAssertEqual(
            WarrenDesktopPaneDropResolver.target(in: size, at: CGPoint(x: 10, y: 150), canSplit: true),
            .left
        )
        XCTAssertEqual(
            WarrenDesktopPaneDropResolver.target(in: size, at: CGPoint(x: 390, y: 150), canSplit: true),
            .right
        )
        XCTAssertEqual(
            WarrenDesktopPaneDropResolver.target(in: size, at: CGPoint(x: 200, y: 150), canSplit: true),
            .center
        )
    }

    /// A pane at the four-pane cap still accepts the centre target, which is
    /// how replace-in-place stays reachable.
    @MainActor
    func testResolverHonoursThePaneLimit() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(
            WarrenDesktopPaneDropResolver.target(in: size, at: CGPoint(x: 10, y: 150), canSplit: false),
            .center
        )
    }

    /// The native drag session can only name the pane under the pointer if the
    /// marker has a frame there. This exercises the full screen-to-zone path,
    /// including the marker's flipped/unflipped Y origin.
    @MainActor
    func testDragHandleResolvesThePaneUnderThePointer() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let marker = WarrenDesktopPaneDropMarkerView()
        marker.paneID = "pane-1"
        marker.canSplit = true
        marker.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(marker)

        let handle = WarrenDesktopTabDragHandleView()
        handle.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        window.contentView?.addSubview(handle)

        func resolve(_ point: NSPoint) -> WarrenDesktopSplitTarget? {
            handle.resolve(window.convertPoint(toScreen: point))
        }

        XCTAssertEqual(resolve(NSPoint(x: 200, y: 275))?.target, .top)
        XCTAssertEqual(resolve(NSPoint(x: 200, y: 25))?.target, .bottom)
        XCTAssertEqual(resolve(NSPoint(x: 20, y: 150))?.target, .left)
        XCTAssertEqual(resolve(NSPoint(x: 380, y: 150))?.target, .right)
        XCTAssertEqual(resolve(NSPoint(x: 200, y: 150))?.target, .center)
        XCTAssertEqual(resolve(NSPoint(x: 200, y: 150))?.paneID, "pane-1")
        XCTAssertNil(resolve(NSPoint(x: 500, y: 150)))
    }

    /// The marker is how the drag source finds a pane; it must never become a
    /// mouse target for the terminal below it.
    @MainActor
    func testPaneDropMarkerTakesNoHit() {
        let marker = WarrenDesktopPaneDropMarkerView()
        marker.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(marker.hitTest(NSPoint(x: 50, y: 50)))
    }

    /// A resolved drop reports the pane, the dragged tab, and the zone to the
    /// split callback. A drop outside every pane reports nothing.
    @MainActor
    func testDragHandleReportsTheResolvedSplitOnDrop() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let marker = WarrenDesktopPaneDropMarkerView()
        marker.paneID = "pane-7"
        marker.canSplit = true
        marker.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(marker)

        var drops: [(String, String, SplitDropTarget)] = []
        let handle = WarrenDesktopTabDragHandleView()
        handle.tabID = "tab-b"
        handle.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        handle.onSplitDrop = { paneID, tabID, target in
            drops.append((paneID, tabID, target))
        }
        window.contentView?.addSubview(handle)

        handle.performDrop(at: window.convertPoint(toScreen: NSPoint(x: 20, y: 150)))
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?.0, "pane-7")
        XCTAssertEqual(drops.first?.1, "tab-b")
        XCTAssertEqual(drops.first?.2, .left)

        handle.performDrop(at: window.convertPoint(toScreen: NSPoint(x: 500, y: 150)))
        XCTAssertEqual(drops.count, 1)
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
