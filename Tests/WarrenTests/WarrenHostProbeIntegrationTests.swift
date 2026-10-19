import AppKit
import SwiftUI
import XCTest
import WarrenObservation
@testable import WarrenDesktop
@testable import Warren

final class WarrenHostProbeIntegrationTests: XCTestCase {
    /// Opt-in acceptance against a running daemon, without changing its catalog
    /// or sessions.
    @MainActor
    func testLiveHostProbeReachesHeadless() async throws {
        guard let url = ProcessInfo.processInfo.environment["WARREN_HOST_PROBE_URL"] else {
            throw XCTSkip("Set WARREN_HOST_PROBE_URL to a running Headless HTTP root")
        }
        let endpoint = WarrenRemoteEndpointConfiguration(name: "Live Host", url: url)
        let model = WarrenRemoteApplicationModel()
        model.probeHosts([endpoint])
        let deadline = ContinuousClock.now + .seconds(8)
        while model.hostProbes[endpoint] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try XCTUnwrap(model.hostProbes[endpoint])
        XCTAssertFalse(result.isFailure, result.message)
        XCTAssertTrue(result.message.contains("Headless"))
    }
}
