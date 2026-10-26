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
    /// A platform view under the pointer, which reports the clicks it gets.
    /// SwiftUI's hit testing decides whether AppKit reaches it at all.
    private final class ProbeView: NSView {
        var clicks = 0
        override func mouseDown(with event: NSEvent) { clicks += 1 }
        // The test window is never key; the probe takes the activating click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private struct Probe: NSViewRepresentable {
        let view: ProbeView
        func makeNSView(context: Context) -> ProbeView { view }
        func updateNSView(_ nsView: ProbeView, context: Context) {}
    }

    private struct Mounted {
        let window: NSWindow
        let hosting: NSView
        let scrollView: NSScrollView
        let probe: ProbeView
    }

    private func mountProbe(counter: Counter) throws -> Mounted {
        let probe = ProbeView()
        let view = WarrenOverflowFadeScrollView(
            .vertical,
            surface: .black,
            suspendsHitTestingWhileScrolling: true
        ) {
            VStack(spacing: 0) {
                Probe(view: probe).frame(height: 1200)
                Rows(counter: counter, model: Model())
            }
        }
        let hosting = NSHostingView(rootView: view.frame(width: 200, height: 200))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        settle(hosting)
        let scrollView = try XCTUnwrap(scrollViews(in: hosting).first)
        return Mounted(window: window, hosting: hosting, scrollView: scrollView, probe: probe)
    }

    /// Whether a point in the window reaches the probe.
    private func reachesProbe(_ mounted: Mounted) -> Bool {
        let point = NSPoint(x: 100, y: 100)
        var view = mounted.hosting.hitTest(point)
        while let current = view {
            if current === mounted.probe { return true }
            view = current.superview
        }
        return false
    }

    private func scroll(_ mounted: Mounted, to y: CGFloat) {
        mounted.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        mounted.scrollView.reflectScrolledClipView(mounted.scrollView.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        mounted.hosting.layoutSubtreeIfNeeded()
    }

    /// While the content moves it takes no hits, so a still pointer costs no
    /// per-frame responder walk; once it has settled it takes them again.
    func testContentIgnoresThePointerOnlyWhileItScrolls() throws {
        let counter = Counter()
        let mounted = try mountProbe(counter: counter)
        defer { mounted.window.orderOut(nil) }
        XCTAssertTrue(reachesProbe(mounted), "A resting list takes hits")

        counter.builds = 0
        scroll(mounted, to: 120)
        XCTAssertFalse(reachesProbe(mounted), "A moving list takes no hits")

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        settle(mounted.hosting)
        XCTAssertTrue(reachesProbe(mounted), "A settled list takes hits again")
        XCTAssertEqual(counter.builds, 0, "Suspending and restoring hits rebuilt the rows")
    }

    /// A click that arrives mid-scroll reaches the content under it rather
    /// than being lost to the suspended hit testing.
    func testAClickDuringAScrollLands() throws {
        let mounted = try mountProbe(counter: Counter())
        defer { mounted.window.orderOut(nil) }
        scroll(mounted, to: 120)
        XCTAssertFalse(reachesProbe(mounted))

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mounted.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        // Through the application, as a real click arrives, so the local
        // monitor sees it before the window dispatches it.
        NSApplication.shared.sendEvent(event)
        XCTAssertEqual(mounted.probe.clicks, 1)
    }
}
#endif
