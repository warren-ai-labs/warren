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

    func testPublicAccessCopyUsesRelayRouteTerminology() {
        XCTAssertEqual(WarrenPublicAccessCopy.relayURL, "Relay URL")
        XCTAssertEqual(WarrenPublicAccessCopy.publicHostname, "Public hostname")
        XCTAssertEqual(WarrenPublicAccessCopy.pathPrefix, "Path prefix")
        XCTAssertEqual(WarrenPublicAccessCopy.resetLocalSetup, "Reset local route")
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
            onRelayEnroll: nil,
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

    @MainActor
    func testRelaySettingsShowSingleConnectionFormAndLifecycleActions() throws {
        let reset = expectation(description: "relay settings reset")
        let recorder = WarrenSemanticRecorder()
        let settings = WarrenDesktopSettingsView(
            onBack: {},
            hostName: "Test Host",
            webStatus: WarrenDesktopWebStatus(),
            onWebTest: nil,
            onWebStop: nil,
            onWebReset: nil,
            onRelayEnroll: { _, _, completion in completion(.success(())) },
            relaySettings: WarrenDesktopRelaySettings(
                enabled: true,
                relayURL: "https://relay.example.test",
                hostID: "00000000-0000-4000-8000-000000000001",
                routeID: "route-1",
                relayKeyID: "key-1",
                relayPublicKey: "pinned-public-key"
            ),
            onResetRelay: { completion in
                completion(.success(()))
                reset.fulfill()
            },
            defaultRuntime: nil,
            onSetRuntime: { _ in },
            autoOpenShell: false,
            onSetAutoOpenShell: { _ in },
            autoStartAI: false,
            onSetAutoStartAI: { _ in },
            openAIBaseURL: "",
            openAIModel: "",
            openAITitleEnabled: false,
            onSetOpenAISetting: { _, _ in },
            onTestOpenAI: { _, _, _ in },
            initialSettingsSection: .relay
        )
        .environment(\.colorScheme, .dark)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: 1_000, height: 800)

        let hostingView = NSHostingView(rootView: settings)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        XCTAssertNotNil(snapshot.node(id: "settings.relay.share"))
        XCTAssertNotNil(snapshot.node(id: "settings.relay.connection"))
        XCTAssertNotNil(snapshot.node(id: "settings.relay.join-url"))
        XCTAssertNotNil(snapshot.node(id: "settings.relay.enrollment-key"))
        XCTAssertEqual(snapshot.node(id: "settings.relay.connect")?.label, "Connect Relay")
        XCTAssertNotNil(snapshot.node(id: "settings.relay.reset"))
        XCTAssertNil(snapshot.node(id: "settings.relay.details"))
        XCTAssertNil(snapshot.node(id: "settings.relay.save"))
        XCTAssertNil(snapshot.node(id: "settings.relay.reregister"))
        XCTAssertNil(snapshot.node(id: "settings.relay.registration"))

        try recorder.perform(.press, on: "settings.relay.reset")
        wait(for: [reset], timeout: 1)
    }

    @MainActor
    func testRelaySettingsLinkPrefillsWithoutConsumingEnrollmentKey() throws {
        let enrolled = expectation(description: "relay enrollment")
        var received: (String, String, String)?
        let prefill = WarrenDesktopRelayPrefill(
            relayURL: "https://relay.example.test",
            enrollmentKey: "AAAA-BBBB-CCCC-DDDD"
        )
        let recorder = WarrenSemanticRecorder()
        let settings = WarrenDesktopSettingsView(
            onBack: {},
            hostName: "Test Host",
            webStatus: WarrenDesktopWebStatus(),
            onWebTest: nil,
            onWebStop: nil,
            onWebReset: nil,
            onRelayEnroll: { relayURL, key, completion in
                received = (relayURL, key, "")
                completion(.success(()))
                enrolled.fulfill()
            },
            relaySettings: WarrenDesktopRelaySettings(),
            defaultRuntime: nil,
            onSetRuntime: { _ in },
            autoOpenShell: false,
            onSetAutoOpenShell: { _ in },
            autoStartAI: false,
            onSetAutoStartAI: { _ in },
            openAIBaseURL: "",
            openAIModel: "",
            openAITitleEnabled: false,
            onSetOpenAISetting: { _, _ in },
            onTestOpenAI: { _, _, _ in },
            initialSettingsSection: .relay,
            relayPrefill: prefill
        )
        .environment(\.colorScheme, .dark)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: settings)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(received)

        XCTAssertNotNil(recorder.snapshot().node(id: "settings.relay.enrollment-key"))
        XCTAssertEqual(recorder.snapshot().node(id: "settings.relay.connect")?.label, "Connect Relay")
        try recorder.perform(.press, on: "settings.relay.connect")
        wait(for: [enrolled], timeout: 1)

        XCTAssertEqual(received?.0, "https://relay.example.test")
        XCTAssertEqual(received?.1, "AAAA-BBBB-CCCC-DDDD")
    }

    @MainActor
    func testRelaySettingsAlwaysShowSingleConnectionForm() throws {
        let recorder = WarrenSemanticRecorder()
        let settings = WarrenDesktopSettingsView(
            onBack: {},
            hostName: "Test Host",
            webStatus: WarrenDesktopWebStatus(),
            onWebTest: nil,
            onWebStop: nil,
            onWebReset: nil,
            onRelayEnroll: { _, _, completion in completion(.success(())) },
            relaySettings: WarrenDesktopRelaySettings(),
            defaultRuntime: nil,
            onSetRuntime: { _ in },
            autoOpenShell: false,
            onSetAutoOpenShell: { _ in },
            autoStartAI: false,
            onSetAutoStartAI: { _ in },
            openAIBaseURL: "",
            openAIModel: "",
            openAITitleEnabled: false,
            onSetOpenAISetting: { _, _ in },
            onTestOpenAI: { _, _, _ in },
            initialSettingsSection: .relay
        )
        .environment(\.colorScheme, .dark)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: 1_000, height: 800)

        let hostingView = NSHostingView(rootView: settings)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        XCTAssertNotNil(snapshot.node(id: "settings.relay.connection"))
        XCTAssertNotNil(snapshot.node(id: "settings.relay.join-url"))
        XCTAssertNotNil(snapshot.node(id: "settings.relay.enrollment-key"))
        XCTAssertEqual(snapshot.node(id: "settings.relay.connect")?.label, "Connect Relay")
        XCTAssertNil(snapshot.node(id: "settings.relay.details"))
        XCTAssertNil(snapshot.node(id: "settings.relay.registration"))
    }

    func testPublicAccessSetupLinkRoundTripsEncodedConfiguration() throws {
        let prefill = WarrenDesktopPublicAccessPrefill(
            publicHostname: "public.example.com",
            pathPrefix: "/private path?mode=secure&scope=owner"
        )
        let link = WarrenDesktopSettingsDeepLink(
            section: .publicAccess,
            publicAccess: prefill
        )
        let url = try XCTUnwrap(link.url)
        let absolute = url.absoluteString
        XCTAssertNil(url.fragment)
        XCTAssertTrue(absolute.contains("publicHostname="))
        XCTAssertTrue(absolute.contains("%20"))
        XCTAssertEqual(WarrenDesktopSettingsDeepLink(url: url), link)
    }

    func testPublicAccessRouteFieldsRoundTripFromPathForm() throws {
        let url = try XCTUnwrap(URL(string: "warren://settings/public-access?publicHostname=public.example.com&pathPrefix=%2Fhost"))

        let link = try XCTUnwrap(WarrenDesktopSettingsDeepLink(url: url))
        XCTAssertEqual(link.section, .publicAccess)
        XCTAssertEqual(link.publicAccess?.publicHostname, "public.example.com")
        XCTAssertEqual(link.publicAccess?.pathPrefix, "/host")
    }

    func testRelaySettingsLinkRoundTripsWithoutBecomingPublicAccess() throws {
        let prefill = WarrenDesktopRelayPrefill(
            relayURL: "http://192.0.2.10:8080/relay",
            enrollmentKey: "AAAA-BBBB-CCCC-DDDD"
        )
        let link = WarrenDesktopSettingsDeepLink(section: .relay, relay: prefill)
        let url = try XCTUnwrap(link.url)
        XCTAssertNil(url.fragment)
        XCTAssertTrue(url.absoluteString.contains("enrollmentKey="))
        XCTAssertEqual(WarrenDesktopSettingsDeepLink(url: url), link)
        XCTAssertNil(link.publicAccess)
        XCTAssertNotNil(link.relay)
    }

    func testRelaySettingsLinkReadsOnlyURLAndEnrollmentKey() throws {
        let url = try XCTUnwrap(URL(string: "warren://settings/relay?relayUrl=http%3A%2F%2F192.0.2.10%3A8080&enrollmentKey=AAAA-BBBB-CCCC-DDDD&hostId=ignored"))
        let link = try XCTUnwrap(WarrenDesktopSettingsDeepLink(url: url))
        XCTAssertEqual(link.section, .relay)
        XCTAssertEqual(link.relay?.relayURL, "http://192.0.2.10:8080")
        XCTAssertEqual(link.relay?.enrollmentKey, "AAAA-BBBB-CCCC-DDDD")
        XCTAssertNil(link.publicAccess)
    }

    func testRelaySettingsLinkRejectsLegacyAliases() throws {
        let aliasParameters = try XCTUnwrap(URL(string: "warren://settings/relay?url=http%3A%2F%2F192.0.2.10%3A8080&host=ignored&ticket=short-lived"))
        let aliasSection = try XCTUnwrap(URL(string: "warren://settings/owned-relay?relayUrl=http%3A%2F%2F192.0.2.10%3A8080&enrollmentKey=AAAA-BBBB-CCCC-DDDD"))

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
        let url = try XCTUnwrap(URL(string: "warren://settings?section=public-access&publicHostname=first.example&publicHostname=second.example"))

        let link = try XCTUnwrap(WarrenDesktopSettingsDeepLink(url: url))
        XCTAssertEqual(link.publicAccess?.publicHostname, "first.example")
    }
}
