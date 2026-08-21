import Foundation
import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem

final class WarrenDesktopWebPanelTests: XCTestCase {
    func testAddressPresentationKeepsLinksUniqueAndActionable() throws {
        let localURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8789/#t=local"))
        let lanURL = try XCTUnwrap(URL(string: "http://192.168.1.23:8789/#t=lan"))
        let publicURL = try XCTUnwrap(URL(string: "https://warren.example/#t=public"))

        let addresses = WarrenDesktopWebAddressPresentation.addresses(for: .init(
            isRunning: true,
            localURL: localURL,
            lanURL: lanURL,
            secureURL: publicURL
        ))

        XCTAssertEqual(addresses.map(\.kind), [.local, .lan, .publicAccess])
        XCTAssertEqual(addresses.map(\.url), [localURL, lanURL, publicURL])
        XCTAssertEqual(addresses.map { $0.kind.canOpenInBrowser }, [true, false, false])
    }

    func testAddressPresentationDoesNotRepeatTheLocalURLAsLAN() throws {
        let localURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8789/#t=local"))
        let publicURL = try XCTUnwrap(URL(string: "https://warren.example/#t=public"))

        let addresses = WarrenDesktopWebAddressPresentation.addresses(for: .init(
            isRunning: true,
            localURL: localURL,
            lanURL: localURL,
            secureURL: publicURL
        ))

        XCTAssertEqual(addresses.map(\.kind), [.local, .publicAccess])
        XCTAssertEqual(addresses.map(\.url), [localURL, publicURL])
    }

    func testAddressPresentationKeepsPublicLinkAvailableWithoutLocalLink() throws {
        let publicURL = try XCTUnwrap(URL(string: "https://warren.example/#t=public"))

        let addresses = WarrenDesktopWebAddressPresentation.addresses(for: .init(
            secureURL: publicURL,
            tunnelRunning: true
        ))

        XCTAssertEqual(addresses.map(\.kind), [.publicAccess])
        XCTAssertEqual(addresses.map(\.url), [publicURL])
    }

    func testWebPopoverUsesCompactDocumentedWidth() {
        XCTAssertEqual(WarrenLayoutMetrics.webPopoverWidth, 288)
        XCTAssertLessThan(WarrenLayoutMetrics.webPopoverWidth, 340)
    }

    func testPublicAccessIntentIsSeparateFromDesktopControlPermission() {
        let status = WarrenDesktopWebStatus(
            canControl: false,
            publicAccessEnabled: true
        )

        XCTAssertTrue(status.publicAccessEnabled)
        XCTAssertFalse(status.canControl)
        XCTAssertFalse(status.tunnelRunning)
    }

    func testPublicAccessAuthenticationIsSeparateFromLiveEndpoint() {
        let status = WarrenDesktopWebStatus(publicAccessAuthenticated: true)

        XCTAssertTrue(status.publicAccessAuthenticated)
        XCTAssertFalse(status.tunnelRunning)
        XCTAssertNil(status.secureURL)
    }

    func testGnarProjectLinkUsesTheSelfHostedWorkerRepository() {
        XCTAssertEqual(WarrenPublicAccessCopy.gnarProjectURL, "https://github.com/abcdlsj/gnar")
    }
}
