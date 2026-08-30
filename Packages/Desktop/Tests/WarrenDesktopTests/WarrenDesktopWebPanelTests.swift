import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenObservation

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

    func testAddressPresentationCanHideTheClientLocalURLForRemoteEndpoints() throws {
        let localURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8789/#t=local"))
        let lanURL = try XCTUnwrap(URL(string: "http://192.168.1.23:8789/#t=lan"))
        let publicURL = try XCTUnwrap(URL(string: "https://warren.example/#t=public"))

        let addresses = WarrenDesktopWebAddressPresentation.addresses(
            for: .init(
                isRunning: true,
                localURL: localURL,
                lanURL: lanURL,
                secureURL: publicURL
            ),
            includeLocalURL: false
        )

        XCTAssertEqual(addresses.map(\.kind), [.lan, .publicAccess])
        XCTAssertEqual(addresses.map(\.url), [lanURL, publicURL])
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
        XCTAssertEqual(WarrenPublicAccessCopy.resetLocalSetup, "Reset local setup")
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

    func testAITitleSettingsSectionIsRegisteredAndDeepLinkable() throws {
        XCTAssertTrue(WarrenDesktopSettingsSection.allCases.contains(.aiTitles))
        XCTAssertEqual(WarrenDesktopSettingsSection.aiTitles.deepLinkValue, "ai-titles")

        for value in ["ai-titles", "ai-title", "openai", "openai-titles"] {
            let url = try XCTUnwrap(URL(string: "warren://settings?section=\(value)"))
            XCTAssertEqual(
                WarrenDesktopSettingsDeepLink(url: url)?.section,
                .aiTitles,
                "section alias \(value) should select AI titles"
            )
        }
    }

    @MainActor
    func testAITitleSettingsTestConnectionButtonSendsCurrentDrafts() throws {
        let callback = expectation(description: "test connection callback")
        var received: (baseURL: String, model: String, key: String?)?
        let recorder = WarrenSemanticRecorder()
        let settings = WarrenDesktopSettingsView(
            onBack: {},
            hostName: "Test Host",
            webStatus: WarrenDesktopWebStatus(),
            onWebTest: nil,
            onWebStop: nil,
            onWebReset: nil,
            defaultRuntime: nil,
            onSetRuntime: { _ in },
            autoOpenShell: false,
            onSetAutoOpenShell: { _ in },
            autoStartAI: false,
            onSetAutoStartAI: { _ in },
            openAIBaseURL: "https://api.example.test/v1",
            openAIModel: "title-model",
            openAITitleEnabled: false,
            onSetOpenAISetting: { _, _ in },
            onTestOpenAI: { baseURL, model, key in
                received = (baseURL, model, key)
                callback.fulfill()
            },
            initialSettingsSection: .aiTitles
        )
        .environment(\.colorScheme, .dark)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: 1_000, height: 800)

        let hostingView = NSHostingView(rootView: settings)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let node = recorder.snapshot().node(id: "settings.ai-titles.test")
        XCTAssertEqual(node?.label, "Test AI title connection")
        XCTAssertTrue(node?.isEnabled == true)
        try recorder.perform(.press, on: "settings.ai-titles.test")
        wait(for: [callback], timeout: 1)

        XCTAssertEqual(received?.baseURL, "https://api.example.test/v1")
        XCTAssertEqual(received?.model, "title-model")
        XCTAssertNil(received?.key)
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

    func testRelaySetupLinkRoundTripsWithoutBecomingPublicAccess() throws {
        let prefill = WarrenDesktopRelayPrefill(
            relayURL: "http://192.0.2.10:8080/relay",
            hostID: "00000000-0000-4000-8000-000000000001",
            enrollmentTicket: "one-time ticket/+value",
            relayKeyID: "relay-key-1",
            relayPublicKey: "base64-public-key"
        )
        let link = WarrenDesktopSettingsDeepLink(section: .relay, relay: prefill)
        let url = try XCTUnwrap(link.url)
        XCTAssertNil(url.fragment)
        XCTAssertTrue(url.absoluteString.contains("enrollmentTicket="))
        XCTAssertEqual(WarrenDesktopSettingsDeepLink(url: url), link)
        XCTAssertNil(link.publicAccess)
        XCTAssertNotNil(link.relay)
    }

    func testRelaySetupLinkRequiresCanonicalParameters() throws {
        let url = try XCTUnwrap(URL(string: "warren://settings/relay?relayUrl=http%3A%2F%2F192.0.2.10%3A8080&hostId=00000000-0000-4000-8000-000000000001&enrollmentTicket=short-lived&relayKeyId=relay-key&relayPublicKey=key"))
        let link = try XCTUnwrap(WarrenDesktopSettingsDeepLink(url: url))
        XCTAssertEqual(link.section, .relay)
        XCTAssertEqual(link.relay?.relayURL, "http://192.0.2.10:8080")
        XCTAssertEqual(link.relay?.hostID, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(link.relay?.enrollmentTicket, "short-lived")
        XCTAssertNil(link.publicAccess)
    }

    func testRelaySetupLinkRejectsLegacyAliases() throws {
        let aliasParameters = try XCTUnwrap(URL(string: "warren://settings/relay?url=http%3A%2F%2F192.0.2.10%3A8080&host=00000000-0000-4000-8000-000000000001&ticket=short-lived&keyId=relay-key&publicKey=key"))
        let aliasSection = try XCTUnwrap(URL(string: "warren://settings/owned-relay?relayUrl=http%3A%2F%2F192.0.2.10%3A8080&hostId=00000000-0000-4000-8000-000000000001&enrollmentTicket=short-lived&relayKeyId=relay-key&relayPublicKey=key"))

        XCTAssertEqual(WarrenDesktopSettingsDeepLink(url: aliasParameters)?.section, .relay)
        XCTAssertNil(WarrenDesktopSettingsDeepLink(url: aliasParameters)?.relay)
        XCTAssertNil(WarrenDesktopSettingsDeepLink(url: aliasSection))
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
