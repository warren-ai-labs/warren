import AppKit
import SwiftUI
import XCTest

@testable import WarrenDesktop

/// A panel's content is republished by its presenter while it is the open
/// request, so the menu layer never draws the state frozen at open time.
@MainActor
final class WarrenDesktopMenuPanelTests: XCTestCase {
    func testPresentingAPanelReturnsTheRequestItOpened() {
        let center = WarrenDesktopMenuCenter()
        let id = center.presentPanel(AnyView(Text("Panel")), at: .zero, width: 248)
        XCTAssertEqual(center.request?.id, id)
    }

    func testThePresenterPublishesItsPanelOnlyWhileItsRequestIsOpen() {
        let center = WarrenDesktopMenuCenter()
        var builds = 0
        let panel = { () -> Text in
            builds += 1
            return Text("Panel")
        }

        XCTAssertTrue(WarrenDesktopMenuPanelContentKey.live(nil, in: center, panel: panel).isEmpty)

        let id = center.presentPanel(AnyView(Text("Panel")), at: .zero, width: 248)
        let live = WarrenDesktopMenuPanelContentKey.live(id, in: center, panel: panel)
        XCTAssertEqual(Array(live.keys), [id])
        XCTAssertEqual(builds, 1)

        center.present([.button(title: "Other", action: {})], at: .zero)
        XCTAssertTrue(
            WarrenDesktopMenuPanelContentKey.live(id, in: center, panel: panel).isEmpty,
            "A replaced panel stops being rebuilt"
        )

        center.dismiss()
        XCTAssertTrue(WarrenDesktopMenuPanelContentKey.live(id, in: center, panel: panel).isEmpty)
        XCTAssertEqual(builds, 1)
    }

    private final class Driver: ObservableObject {
        @Published var offset: CGFloat = 10
        @Published var isPresented = false
    }

    private struct Anchored: View {
        @ObservedObject var driver: Driver

        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: driver.offset)
                Text("Anchor")
                    .warrenMenuPanel(isPresented: $driver.isPresented, width: 200) {
                        Text("Panel")
                    }
                Spacer(minLength: 0)
            }
        }
    }

    /// The anchor is read when the panel opens rather than tracked, so it has
    /// to be where the view is then, not where it was first laid out.
    func testABoundPanelOpensWhereItsViewIsNow() throws {
        let center = WarrenDesktopMenuCenter()
        let driver = Driver()
        let hosting = NSHostingView(
            rootView: Anchored(driver: driver).environment(\.warrenMenuCenter, center)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        func settle() {
            for _ in 0..<3 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        settle()

        driver.isPresented = true
        settle()
        let first = try XCTUnwrap(center.request?.anchor)
        driver.isPresented = false
        settle()
        XCTAssertNil(center.request)

        driver.offset = 120
        settle()
        driver.isPresented = true
        settle()
        let moved = try XCTUnwrap(center.request?.anchor)
        XCTAssertEqual(moved.y - first.y, 110, accuracy: 0.5)
        XCTAssertEqual(moved.x, first.x, accuracy: 0.5)
    }
}
