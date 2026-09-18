import XCTest
@testable import WarrenTransport

/// A Host has two identities: its own (`/healthz` `host_id`, used to verify a
/// direct candidate) and the Relay's host record id (the `/h/{id}/...` scope of
/// a Relay route). Sharing one field let either route overwrite the other, which
/// made the Relay reject the socket as `unauthorized`.
final class WarrenRemoteEndpointRouteIdentityTests: XCTestCase {
    func testRelayRouteUsesTheRelayHostRecordID() {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "https://relay.example.test/relay",
            token: "access",
            type: "relay",
            hostID: "lan-host-1",
            relayHostID: "relay-host-9"
        )
        XCTAssertEqual(endpoint.effectiveRelayHostID, "relay-host-9")
        XCTAssertEqual(
            endpoint.webSocketURL?.absoluteString,
            "wss://relay.example.test/relay/h/relay-host-9/v1/client/connect"
        )
        XCTAssertEqual(
            endpoint.relaySessionRefreshURL?.absoluteString,
            "https://relay.example.test/relay/h/relay-host-9/v1/session/refresh"
        )
        XCTAssertEqual(
            endpoint.relayLiveActivityRegistrationURL?.absoluteString,
            "https://relay.example.test/relay/h/relay-host-9/v1/live-activities"
        )
    }

    /// Without a Relay host record id a Relay route cannot be built at all.
    /// Catalogs from before the split are not migrated, so the client has to
    /// fail loudly and let the Host be paired again instead of guessing which
    /// id the route should carry.
    func testRelayRouteWithoutHostRecordIDHasNoRoute() {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "https://relay.example.test",
            token: "access",
            type: "relay",
            hostID: "lan-host-1"
        )
        XCTAssertNil(endpoint.effectiveRelayHostID)
        XCTAssertNil(endpoint.webSocketURL)
        XCTAssertNil(endpoint.relaySessionRefreshURL)
        XCTAssertNil(endpoint.relayLiveActivityRegistrationURL)
    }

    func testDirectRouteKeepsTheHostIdentityOutOfRelayPaths() {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "http://192.168.1.50:8789",
            token: "access",
            hostID: "lan-host-1",
            directURL: "http://192.168.1.50:8789",
            relayURL: "https://relay.example.test"
        )
        XCTAssertEqual(endpoint.webSocketURL?.absoluteString, "ws://192.168.1.50:8789/v1/ws")
        XCTAssertNil(endpoint.relaySessionRefreshURL)
        XCTAssertNil(endpoint.relayLiveActivityRegistrationURL)
        XCTAssertEqual(endpoint.hostID, "lan-host-1")
    }

    func testRouteDetailsRewriteOnlyTheIdentityTheyOwn() {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "https://relay.example.test",
            token: "access",
            type: "relay",
            hostID: "lan-host-1",
            relayHostID: "relay-host-9",
            directURL: "http://192.168.1.50:8789",
            relayURL: "https://relay.example.test"
        )
        let directUpdate = endpoint.withRouteDetails(
            directURL: "http://192.168.1.51:8789",
            hostID: "lan-host-2"
        )
        XCTAssertEqual(directUpdate.hostID, "lan-host-2")
        XCTAssertEqual(directUpdate.relayHostID, "relay-host-9")

        let relayUpdate = endpoint.withRouteDetails(relayHostID: "relay-host-10")
        XCTAssertEqual(relayUpdate.hostID, "lan-host-1")
        XCTAssertEqual(relayUpdate.relayHostID, "relay-host-10")
    }

    func testRelayHostIDRoundTripsThroughCodable() throws {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Host",
            url: "https://relay.example.test",
            token: "access",
            type: "relay",
            hostID: "lan-host-1",
            relayHostID: "relay-host-9",
            directURL: "http://192.168.1.50:8789",
            relayURL: "https://relay.example.test"
        )
        let data = try JSONEncoder().encode(endpoint)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["relay_host_id"] as? String, "relay-host-9")
        XCTAssertEqual(object["host_id"] as? String, "lan-host-1")

        let decoded = try JSONDecoder().decode(
            WarrenRemoteEndpointConfiguration.self,
            from: data
        )
        XCTAssertEqual(decoded, endpoint)
    }
}
