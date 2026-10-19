import AppKit
import SwiftUI
import XCTest

@testable import WarrenDesktop

/// The settings page is its own window so it can sit beside the terminal it
/// changes; these tests pin the window's size, title, and dismissal.
@MainActor
final class WarrenDesktopSettingsWindowTests: XCTestCase {
    func testTheSettingsWindowOpensAtItsOwnSizeAndHidesOnClose() {
        let coordinator = WarrenDesktopSettingsWindowPresenter.Coordinator()
        coordinator.update(
            isPresented: true,
            activation: 1,
            content: AnyView(Text("Settings"))
        )
        guard let window = coordinator.presentedWindow else {
            return XCTFail("The presenter did not create a window")
        }
        XCTAssertEqual(window.title, "Settings")
        XCTAssertEqual(window.minSize, NSSize(width: 820, height: 540))
        XCTAssertTrue(window.styleMask.contains(.closable))

        coordinator.update(
            isPresented: false,
            activation: 1,
            content: AnyView(Text("Settings"))
        )
        XCTAssertFalse(window.isVisible, "Closing settings hides its window")
    }

    func testAskingForSettingsAgainReusesTheSameWindow() {
        let coordinator = WarrenDesktopSettingsWindowPresenter.Coordinator()
        coordinator.update(isPresented: true, activation: 1, content: AnyView(Text("A")))
        let first = coordinator.presentedWindow
        coordinator.update(isPresented: true, activation: 2, content: AnyView(Text("B")))
        XCTAssertTrue(coordinator.presentedWindow === first, "One settings window, not one per request")
    }
}
