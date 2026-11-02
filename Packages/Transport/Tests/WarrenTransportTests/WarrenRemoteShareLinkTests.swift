import XCTest
@testable import WarrenTransport

/// A remote access link carries everything in its fragment, which no server
/// sees (`docs/remote.md`).
final class WarrenRemoteShareLinkTests: XCTestCase {
    private let code = String(repeating: "A", count: 43)

    func testParsesShareLinkFragment() throws {
        let link = try WarrenRemoteShareLink(
            "https://relay.example.com/#k=\(code)&host=host-1&invite=inv&name=My%20Mac"
        )
        XCTAssertEqual(link.relayURL, "https://relay.example.com")
        XCTAssertEqual(link.connectCode, code)
        XCTAssertEqual(link.hostID, "host-1")
        XCTAssertEqual(link.invite, "inv")
        XCTAssertEqual(link.hostName, "My Mac")
        XCTAssertEqual(link.connectionString, "https://relay.example.com/#k=\(code)")
    }

    func testRecognisesOnlyLinksWithAConnectCode() {
        XCTAssertTrue(WarrenRemoteShareLink.isCandidate("https://relay.example.com/#k=\(code)&host=h"))
        XCTAssertFalse(WarrenRemoteShareLink.isCandidate("https://relay.example.com/pair?ticket=abc"))
        XCTAssertFalse(WarrenRemoteShareLink.isCandidate("http://192.168.1.2:8789"))
    }

    func testRejectsLinkWithoutHost() {
        XCTAssertThrowsError(try WarrenRemoteShareLink("https://relay.example.com/#k=\(code)"))
    }

    func testRemoteEndpointUsesTheKeychainCodeAndNoLegacyRoutes() {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "https://relay.example.com",
            token: "device-token",
            type: "remote",
            refreshToken: code,
            directURL: "http://192.168.1.2:8789",
            routePreference: "relay"
        )
        XCTAssertTrue(endpoint.isRemote)
        XCTAssertEqual(endpoint.remoteConnectionString, "https://relay.example.com/#k=\(code)")
        XCTAssertNil(endpoint.effectiveDirectURL)
        XCTAssertNil(endpoint.effectiveRelayURL)
        XCTAssertEqual(endpoint.remoteMode, .relayOnly)
    }
}
