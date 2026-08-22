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
        XCTAssertEqual(addresses.map { $0.kind.canOpenInBrowser }, [true, false, true])
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

    func testSettingsDeepLinksRoundTripEverySection() throws {
        for section in WarrenDesktopSettingsSection.allCases {
            let link = WarrenDesktopSettingsDeepLink(section: section)
            let url = try XCTUnwrap(link.url)
            XCTAssertEqual(url.scheme, WarrenDesktopSettingsDeepLink.scheme)
            XCTAssertEqual(url.host, WarrenDesktopSettingsDeepLink.host)
            XCTAssertNil(url.fragment)
            XCTAssertEqual(WarrenDesktopSettingsDeepLink(url: url), link)
        }
    }

    func testPublicAccessSetupLinkRoundTripsEncodedConfiguration() throws {
        let prefill = WarrenDesktopPublicAccessPrefill(
            edgeURL: "https://tunnel.example.com:8443/path?mode=secure",
            accountName: "MacBook Pro / Li",
            keyKind: .invite,
            inviteKey: "invite + secret/with&reserved#characters",
            approvalKey: nil
        )
        let link = WarrenDesktopSettingsDeepLink(
            section: .publicAccess,
            publicAccess: prefill
        )
        let url = try XCTUnwrap(link.url)
        let absolute = url.absoluteString
        XCTAssertNil(url.fragment)
        XCTAssertTrue(absolute.contains("inviteKey="))
        XCTAssertTrue(absolute.contains("%23"))
        XCTAssertEqual(WarrenDesktopSettingsDeepLink(url: url), link)
    }

    func testPublicAccessPathFormAndKeyKindInferenceAreSupported() throws {
        let url = try XCTUnwrap(URL(string: "warren://settings/public-access?edgeUrl=https%3A%2F%2Ftunnel.example.com&accountName=host&approvalKey=approval-secret"))

        let link = try XCTUnwrap(WarrenDesktopSettingsDeepLink(url: url))
        XCTAssertEqual(link.section, .publicAccess)
        XCTAssertEqual(link.publicAccess?.edgeURL, "https://tunnel.example.com")
        XCTAssertEqual(link.publicAccess?.accountName, "host")
        XCTAssertEqual(link.publicAccess?.keyKind, .approval)
        XCTAssertEqual(link.publicAccess?.approvalKey, "approval-secret")
    }

    func testSettingsDeepLinkRejectsForeignOrUnknownLinks() throws {
        let foreignScheme = try XCTUnwrap(URL(string: "https://settings?section=public-access"))
        let foreignHost = try XCTUnwrap(URL(string: "warren://other?section=public-access"))
        let unknownSection = try XCTUnwrap(URL(string: "warren://settings?section=unknown"))

        XCTAssertNil(WarrenDesktopSettingsDeepLink(url: foreignScheme))
        XCTAssertNil(WarrenDesktopSettingsDeepLink(url: foreignHost))
        XCTAssertNil(WarrenDesktopSettingsDeepLink(url: unknownSection))
    }

    func testSettingsDeepLinkUsesTheFirstDuplicateQueryValue() throws {
        let url = try XCTUnwrap(URL(string: "warren://settings?section=public-access&edgeUrl=https%3A%2F%2Ffirst.example&edgeUrl=https%3A%2F%2Fsecond.example"))

        let link = try XCTUnwrap(WarrenDesktopSettingsDeepLink(url: url))
        XCTAssertEqual(link.publicAccess?.edgeURL, "https://first.example")
    }
}
