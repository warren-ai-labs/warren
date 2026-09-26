import AppKit
import SwiftUI
import XCTest

import WarrenClientCore
import WarrenDomain
@testable import WarrenDesktop

/// Reports the frame the view it decorates is laid out with, in window
/// coordinates. The chrome rows are AppKit-hosted SwiftUI, so the only honest
/// measurement of "is this on screen" is where AppKit put it.
private struct FrameProbe: NSViewRepresentable {
    let name: String
    let onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard nsView.window != nil else { return }
            onFrame(nsView.convert(nsView.bounds, to: nil))
        }
    }
}

/// The top chrome row must fit the window it is given.
///
/// A Session named after a long shell command made the row demand hundreds of
/// points more width than the window had. SwiftUI centres that overflow on the
/// window, so the two columns either side of it move: the sidebar's leading
/// edge went off screen — the rail lost its left boundary — while the trailing
/// controls went off the right. Both are the same defect, so both are pinned
/// here: the row's identity has to give width up to the window rather than
/// taking it from the columns.
@MainActor
final class WarrenDesktopTopChromeWidthTests: XCTestCase {
    /// Mounts the same two-column arrangement the root view uses — a
    /// fixed-width rail and a flexible workspace column — and hands back the
    /// frames the rail and the chrome row ended up with.
    private func mount(
        title: String,
        windowWidth: CGFloat = 1000,
        sidebarWidth: CGFloat = 260
    ) -> (sidebar: CGRect, row: CGRect) {
        var frames: [String: CGRect] = [:]
        let identity = WarrenDesktopSoloPaneIdentity.Model(
            tabID: "tab-1",
            title: title,
            fullTitle: title,
            providerPresetID: nil,
            mark: nil,
            canClose: true
        )
        let bar = makeTabBar(
            tabs: [ClientTab(id: "tab-1", title: title, kind: .shell)],
            selectedTabID: "tab-1",
            soloPane: identity
        )
        let root = ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.accentColor
                    .frame(width: sidebarWidth)
                    .background(FrameProbe(name: "sidebar") { frames["sidebar"] = $0 })

                VStack(spacing: 0) {
                    bar.background(FrameProbe(name: "row") { frames["row"] = $0 })
                    Color.accentColor
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        let hosting = NSHostingView(rootView: root)
        // The app's window owns the hosting view's size, so the row has to fit
        // the window it is given. Left at its default, the hosting view grows to
        // the content instead — which would let an over-wide row widen the window
        // rather than overflow it, and hide exactly the failure measured here.
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: windowWidth, height: 200)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // The probes report from an async pass, so the frames are not there the
        // instant the subtree is laid out. Wait for both rather than guess a
        // duration: a short wait reads a missing probe as a zero frame.
        let deadline = Date().addingTimeInterval(1)
        while frames.count < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return (frames["sidebar"] ?? .zero, frames["row"] ?? .zero)
    }

    func testALongPaneTitleLeavesTheRailOnTheLeadingEdge() {
        let title = String(repeating: "run the full integration suite with coverage ", count: 4)
        let (sidebar, _) = mount(title: title)

        XCTAssertEqual(
            sidebar.origin.x, 0,
            "The rail's leading edge must stay at the window's leading edge"
        )
        XCTAssertEqual(
            sidebar.width, 260,
            "The rail must keep the width it was given"
        )
    }

    /// The row's trailing controls are the window's own actions. Overflowing
    /// content pushes them out of the window along with the rail, which is the
    /// other half of the same layout failure.
    func testALongPaneTitleKeepsTheRowInsideTheWindow() {
        let title = String(repeating: "run the full integration suite with coverage ", count: 4)
        let (_, row) = mount(title: title, windowWidth: 1000)

        XCTAssertGreaterThanOrEqual(
            row.origin.x, 0,
            "The chrome row must start at the window's leading edge"
        )
        XCTAssertLessThanOrEqual(
            row.maxX, 1000,
            "The workspace actions must stay reachable at the window's trailing edge"
        )
    }

    /// A narrow window is the same squeeze with less slack, and the row must
    /// still hand width back rather than take it.
    func testALongPaneTitleFitsANarrowWindow() {
        let title = String(repeating: "run the full integration suite with coverage ", count: 4)
        let (sidebar, _) = mount(title: title, windowWidth: 560)

        XCTAssertEqual(sidebar.origin.x, 0)
        XCTAssertEqual(sidebar.width, 260)
    }

    /// The fix must not cost the ordinary case anything: a title that already
    /// fits leaves the rail exactly where it was, because the identity is only
    /// flexible when the row has width to give.
    func testAShortPaneTitleLeavesTheRailWhereItWas() {
        let (sidebar, row) = mount(title: "zsh")

        XCTAssertEqual(sidebar.origin.x, 0)
        XCTAssertEqual(sidebar.width, 260)
        XCTAssertEqual(row.origin.x, 260)
    }
}
