import XCTest
@testable import WarrenTransport

/// The Warren Browser viewer page reads the Host token out of its own URL
/// fragment, which no server ever sees (RFC 0022 §8.5). The Session id has to be
/// readable by the page, so it rides in the query; the token may not.
final class WarrenRemoteBrowserViewerURLTests: XCTestCase {
    private let sessionID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

    func testDirectEndpointPutsTheSessionInTheQueryAndTheTokenInTheFragment() throws {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "http://192.168.1.50:8789",
            token: "access-token-123"
        )

        let url = try XCTUnwrap(endpoint.browserViewerURL(sessionID: sessionID))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "192.168.1.50")
        XCTAssertEqual(url.port, 8789)
        XCTAssertEqual(url.path, "/v1/browser/view")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "session", value: sessionID)]
        )
        XCTAssertEqual(components.fragment, "t=access-token-123")
    }

    func testWebSocketEndpointIsServedOverPlainHTTP() throws {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "ws://localhost:8789",
            token: "loopback-token"
        )

        let url = try XCTUnwrap(endpoint.browserViewerURL(sessionID: sessionID))

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.path, "/v1/browser/view")
        XCTAssertEqual(url.absoluteString, "http://localhost:8789/v1/browser/view?session=\(sessionID)#t=loopback-token")
    }

    func testRelayEndpointScopesTheViewerPathToItsHostRecordID() throws {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "wss://relay.example.test/relay",
            token: "relay-token-9",
            type: "relay",
            relayHostID: "relay-host-9"
        )

        let url = try XCTUnwrap(endpoint.browserViewerURL(sessionID: sessionID))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.path, "/relay/h/relay-host-9/v1/browser/view")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "session", value: sessionID)]
        )
        XCTAssertEqual(components.fragment, "t=relay-token-9")
    }

    func testUnsupportedSchemesHaveNoViewerURL() {
        for address in ["ssh://host.example.test", "warren://host.example.test", "file:///tmp/host"] {
            let endpoint = WarrenRemoteEndpointConfiguration(
                name: "Host",
                url: address,
                token: "access-token-123"
            )
            XCTAssertNil(endpoint.browserViewerURL(sessionID: sessionID))
        }
    }

    /// A fragment is never sent to a server, so the token must stay behind the
    /// `#` on every route: not in the path, not in the query, not percent-encoded
    /// into either.
    func testTheTokenNeverLeavesTheFragment() throws {
        let direct = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "http://192.168.1.50:8789",
            token: "access-token-123"
        )
        let relay = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "wss://relay.example.test/relay",
            token: "relay-token-9",
            type: "relay",
            relayHostID: "relay-host-9"
        )

        for endpoint in [direct, relay] {
            let url = try XCTUnwrap(endpoint.browserViewerURL(sessionID: sessionID))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = components.query ?? ""

            XCTAssertEqual(components.queryItems?.count, 1)
            XCTAssertFalse(query.contains(endpoint.token))
            XCTAssertFalse(query.contains("t="))
            XCTAssertFalse(url.path.contains(endpoint.token))
            XCTAssertFalse(url.path.contains(sessionID))
            XCTAssertEqual(components.fragment, "t=\(endpoint.token)")
            XCTAssertTrue(url.absoluteString.hasSuffix("#t=\(endpoint.token)"))
        }
    }
}
