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
            contentKey: WarrenDesktopSettingsInputs(),
            content: { AnyView(Text("Settings")) }
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
            contentKey: WarrenDesktopSettingsInputs(),
            content: { AnyView(Text("Settings")) }
        )
        XCTAssertFalse(window.isVisible, "Closing settings hides its window")
    }

    func testAskingForSettingsAgainReusesTheSameWindow() {
        let coordinator = WarrenDesktopSettingsWindowPresenter.Coordinator()
        coordinator.update(
            isPresented: true,
            activation: 1,
            contentKey: WarrenDesktopSettingsInputs(),
            content: { AnyView(Text("A")) }
        )
        let first = coordinator.presentedWindow
        coordinator.update(
            isPresented: true,
            activation: 2,
            contentKey: WarrenDesktopSettingsInputs(),
            content: { AnyView(Text("B")) }
        )
        XCTAssertTrue(coordinator.presentedWindow === first, "One settings window, not one per request")
    }

    /// The root view re-renders on every Host and terminal event; the open
    /// page is rebuilt only when a value it shows changed.
    func testTheOpenPageIsRebuiltOnlyWhenItsInputsChange() {
        let coordinator = WarrenDesktopSettingsWindowPresenter.Coordinator()
        var builds = 0
        let content: () -> AnyView = {
            builds += 1
            return AnyView(Text("Settings"))
        }
        coordinator.update(
            isPresented: true,
            activation: 1,
            contentKey: WarrenDesktopSettingsInputs(),
            content: content
        )
        XCTAssertEqual(builds, 1)

        coordinator.update(
            isPresented: true,
            activation: 1,
            contentKey: WarrenDesktopSettingsInputs(),
            content: content
        )
        XCTAssertEqual(builds, 1, "An unrelated re-render leaves the page alone")

        coordinator.update(
            isPresented: true,
            activation: 1,
            contentKey: WarrenDesktopSettingsInputs(hostName: "Studio"),
            content: content
        )
        XCTAssertEqual(builds, 2, "A changed value reaches the page")

        coordinator.update(
            isPresented: false,
            activation: 1,
            contentKey: WarrenDesktopSettingsInputs(hostName: "Mini"),
            content: content
        )
        XCTAssertEqual(builds, 2, "A closed page is not built")
    }
}
