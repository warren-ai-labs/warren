import Darwin
import Foundation
import XCTest
import WarrenDomain
@testable import WarrenTransport

final class WarrenRemoteNetworkingTests: XCTestCase {
    func testLoopbackEndpointsUseTheFastSessionAndDeadline() {
        let cases = [
            "http://127.0.0.1:8789",
            "http://127.0.0.1:0",
            "http://localhost:8789",
            "http://[::1]:8789",
        ]
        for url in cases {
            let endpoint = WarrenRemoteEndpointConfiguration(name: "Local", url: url)
            XCTAssertTrue(WarrenRemoteNetworking.isLoopback(endpoint), url)
            XCTAssertTrue(
                WarrenRemoteNetworking.session(for: endpoint) === WarrenRemoteNetworking.loopbackSession,
                url
            )
            XCTAssertEqual(
                WarrenRemoteNetworking.welcomeTimeout(for: endpoint),
                WarrenRemoteNetworking.loopbackWelcomeTimeout,
                url
            )
        }
    }

    func testRemoteAndRelayEndpointsKeepTheWaitingSession() {
        let remote = WarrenRemoteEndpointConfiguration(
            name: "Mac",
            url: "http://192.168.1.10:8789"
        )
        XCTAssertFalse(WarrenRemoteNetworking.isLoopback(remote))
        XCTAssertTrue(WarrenRemoteNetworking.session(for: remote) === WarrenRemoteNetworking.session)
        XCTAssertEqual(
            WarrenRemoteNetworking.welcomeTimeout(for: remote),
            WarrenRemoteNetworking.defaultWelcomeTimeout
        )

        // A Relay endpoint may advertise a loopback-looking direct URL, but the
        // active route is remote and must keep waiting for connectivity.
        let relay = WarrenRemoteEndpointConfiguration(
            name: "Relay",
            url: "wss://relay.example.test/h/host-1/v1/client/connect",
            type: "relay",
            hostID: "host-1",
            relayHostID: "host-1",
            directURL: "http://127.0.0.1:8789"
        )
        XCTAssertFalse(WarrenRemoteNetworking.isLoopback(relay))
        XCTAssertTrue(WarrenRemoteNetworking.session(for: relay) === WarrenRemoteNetworking.session)
    }

    /// Regression: a Desktop started while its local daemon is handing off used
    /// to sit on "Migrating runtime sessions…" for the full 30s welcome
    /// deadline because `waitsForConnectivity` suspended the attempt even after
    /// the daemon returned. A closed loopback port must now surface a
    /// disconnect immediately so the reconnect loop can retry.
    func testClosedLoopbackPortFailsFast() async throws {
        let port = try unusedLoopbackPort()
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Local",
            url: "http://127.0.0.1:\(port)",
            token: "token"
        )
        let client = WarrenRemoteClient(configuration: endpoint)
        await client.start()
        defer { Task { await client.stop() } }

        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if await client.state() == .reconnecting { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("closed loopback port did not fail fast; state was \(await client.state())")
    }

    private func unusedLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "WarrenRemoteNetworkingTests", code: 1)
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, size)
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: "WarrenRemoteNetworkingTests", code: 2)
        }

        var bound = sockaddr_in()
        var boundSize = size
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &boundSize)
            }
        }
        guard nameResult == 0 else {
            throw NSError(domain: "WarrenRemoteNetworkingTests", code: 3)
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }
}
