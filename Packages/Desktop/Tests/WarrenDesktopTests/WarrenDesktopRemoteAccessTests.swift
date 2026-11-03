import XCTest
@testable import WarrenDesktop

/// The words the Remote Access page prints for the two relay kinds.
final class WarrenDesktopRemoteAccessTests: XCTestCase {
    func testRelaySourceNamesTheOfficialRelay() {
        let projection = WarrenDesktopRemoteAccess(
            enabled: true,
            relayURL: "https://bolthole.warrenai.xyz",
            relaySource: "default",
            defaultRelayURL: "https://bolthole.warrenai.xyz"
        )
        XCTAssertEqual(projection.relaySourceText, "Official relay (https://bolthole.warrenai.xyz)")
        XCTAssertFalse(projection.isSelfHostedRelay)
        XCTAssertEqual(projection.effectiveRelayURL, "https://bolthole.warrenai.xyz")
    }

    func testRelaySourceNamesASelfHostedRelay() {
        let projection = WarrenDesktopRemoteAccess(
            enabled: true,
            relayURL: "https://relay.example.test",
            relaySource: "self-hosted",
            configuredRelayURL: "https://relay.example.test",
            defaultRelayURL: "https://bolthole.warrenai.xyz"
        )
        XCTAssertEqual(projection.relaySourceText, "Self-hosted relay")
        XCTAssertTrue(projection.isSelfHostedRelay)
    }

    func testStateReadsAsASentence() {
        XCTAssertTrue(WarrenDesktopRemoteAccess(state: "connected").stateText.hasPrefix("Connected"))
        XCTAssertTrue(WarrenDesktopRemoteAccess().stateText.hasPrefix("Off"))
        XCTAssertTrue(WarrenDesktopRemoteAccess(state: "error").stateText.hasPrefix("The relay refused"))
    }
}
