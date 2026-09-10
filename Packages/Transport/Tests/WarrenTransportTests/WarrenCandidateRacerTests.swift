import Foundation
import XCTest
@testable import WarrenTransport

final class WarrenCandidateRacerTests: XCTestCase {
    func testFirstHealthyCandidateWinsAfterPriorityStagger() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let winner = await WarrenCandidateRacer.race(
            candidates: [
                .init(url: "http://probe.test/slow", priority: 100),
                .init(url: "http://probe.test/fast", priority: 80),
            ],
            expectedHostID: "host-1",
            session: session,
            timeout: 0.5
        )

        XCTAssertEqual(winner?.url, "http://probe.test/fast")
    }

    func testIdentityMismatchCannotWinTheRace() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let winner = await WarrenCandidateRacer.race(
            candidates: [
                .init(url: "http://probe.test/wrong", priority: 100),
                .init(url: "http://probe.test/right", priority: 80),
            ],
            expectedHostID: "host-1",
            session: session,
            timeout: 0.5
        )

        XCTAssertEqual(winner?.url, "http://probe.test/right")
    }

    func testDetailedRaceChoosesLowestLatencyAcrossInterfaces() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let result = await WarrenCandidateRacer.raceDetailed(
            candidates: [
                .init(url: "http://probe.test/slow", priority: 100),
                .init(url: "http://probe.test/fast", priority: 80),
            ],
            expectedHostID: "host-1",
            session: session,
            timeout: 0.5
        )

        XCTAssertEqual(result.winner?.url, "http://probe.test/fast")
        XCTAssertEqual(result.probes.count, 2)
        XCTAssertTrue(result.probes.allSatisfy(\.reachable))
        let slow = result.probes.first { $0.candidate.url.hasSuffix("/slow") }
        let fast = result.probes.first { $0.candidate.url.hasSuffix("/fast") }
        XCTAssertNotNil(slow?.latencyMilliseconds)
        XCTAssertNotNil(fast?.latencyMilliseconds)
        XCTAssertLessThan(fast?.latencyMilliseconds ?? .max, slow?.latencyMilliseconds ?? .min)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RacerURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RacerURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let delay: TimeInterval = url.path.hasPrefix("/slow") ? 0.2 : 0.01
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let hostID = url.path.hasPrefix("/wrong") ? "host-2" : "host-1"
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"ready":true,"version":"4.0","host_id":"\#(hostID)"}"#.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
