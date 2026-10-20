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
}
