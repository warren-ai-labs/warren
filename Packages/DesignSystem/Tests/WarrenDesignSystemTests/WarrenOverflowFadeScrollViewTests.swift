#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import WarrenDesignSystem

/// Scrolling must not rebuild what the scroll view holds.
///
/// The edge fades follow whether the content can scroll further, and that
/// state used to live in the scroll view's own body, so leaving or reaching
/// either end re-ran `content` and rebuilt every row of the sidebar in the
/// frame the scroll was drawing.
@MainActor
final class WarrenOverflowFadeScrollViewTests: XCTestCase {
    private final class Counter {
        var builds = 0
    }

    private final class Model {}

    /// The list as the sidebar builds it: one view holding every row.
    private struct Rows: View {
        let counter: Counter
        /// Made fresh by every run of the content, as the sidebar's rows get
        /// fresh closures, so a rebuilt parent always re-runs this body.
        let model: Model

        var body: some View {
            let _ = counter.builds += 1
            VStack(spacing: 0) {
                ForEach(0..<30, id: \.self) { Text("Row \($0)").frame(height: 40) }
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    private func settle(_ hosting: NSView) {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testCrossingAnEdgeDoesNotRebuildTheContent() throws {
        let counter = Counter()
        let view = WarrenOverflowFadeScrollView(.vertical, surface: .black) {
            Rows(counter: counter, model: Model())
        }
        let hosting = NSHostingView(rootView: view.frame(width: 200, height: 200))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        settle(hosting)

        let scrollView = try XCTUnwrap(scrollViews(in: hosting).first)
        let span = try XCTUnwrap(scrollView.documentView).frame.height - scrollView.contentView.bounds.height
        XCTAssertGreaterThan(span, 0)
        XCTAssertGreaterThan(counter.builds, 0, "The probe counts nothing")
        counter.builds = 0

        // Off the top, to the bottom, and back: every edge state changes.
        for y in [span / 2, span, span / 2, 0] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            settle(hosting)
        }

        XCTAssertEqual(counter.builds, 0, "An edge crossing rebuilt the rows")
    }
}
#endif
