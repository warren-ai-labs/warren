import Foundation
import XCTest
@testable import WarrenTransport

final class WarrenHostProbeTests: XCTestCase {
    func testMatchingProtocolAllowsDifferentBuilds() throws {
        let result = try WarrenHostProbe.decode(Data(#"{"ok":true,"ready":true,"version":"4.0","build":"older-build"}"#.utf8))
        XCTAssertFalse(result.isFailure)
        XCTAssertTrue(result.message.contains("Host reachable"))
        XCTAssertTrue(result.message.contains("Headless older-build"))
    }

    func testMismatchIncludesBothProtocolsAndUpgradeAdvice() throws {
        let result = try WarrenHostProbe.decode(Data(#"{"ok":true,"version":"3.0","build":"old"}"#.utf8))
        XCTAssertTrue(result.isFailure)
        XCTAssertTrue(result.message.contains("Host 3.0, client 4.0"))
        XCTAssertTrue(result.message.contains("Update Warren on both machines"))
    }

    func testOlderHealthPayloadDoesNotInventAnIncompatibility() throws {
        let result = try WarrenHostProbe.decode(Data(#"{"ok":true}"#.utf8))
        XCTAssertFalse(result.isFailure)
        XCTAssertTrue(result.message.contains("protocol unknown"))
    }

    func testNotReadyIsDistinctFromUnreachable() throws {
        let result = try WarrenHostProbe.decode(Data(#"{"ok":true,"ready":false,"version":"4.0"}"#.utf8))
        XCTAssertTrue(result.isFailure)
        XCTAssertTrue(result.message.contains("responding, not ready"))
    }

    func testProbeUsesForwardedPortAndStripsCredentials() async {
        let result = await check("ws://user:password@probe.test:8790/prefix?token=secret#t=secret", token: "secret")
        XCTAssertFalse(result.isFailure)
        XCTAssertTrue(result.message.contains("Headless test-build"))
    }

    func testHTTPTimeoutUnreachableAndInvalidResponsesRemainDistinct() async {
        for (path, message) in [
            ("timeout", "Health probe timed out"),
            ("offline", "Host unreachable"),
            ("unauthorized", "HTTP 401"),
            ("missing", "HTTP 404"),
            ("invalid", "Invalid health response"),
        ] {
            let result = await check("http://probe.test/\(path)")
            XCTAssertTrue(result.isFailure)
            XCTAssertTrue(result.message.contains(message), result.message)
        }
    }

    func testRelayDoesNotProbeControlPlaneAsHost() async {
        let result = await WarrenHostProbe.check(.init(name: "Relay", url: "https://probe.test", type: "relay"))
        XCTAssertEqual(result.message, "Health probe unavailable for this route")
    }

    private func check(_ url: String, token: String = "") async -> WarrenHostProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await WarrenHostProbe.check(.init(name: "Host", url: url, token: token), session: session)
    }
}

private final class HostProbeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertFalse(request.httpShouldHandleCookies)
        let path = url.path
        if path == "/prefix/healthz" {
            XCTAssertEqual(url.scheme, "http")
            XCTAssertEqual(url.port, 8790)
        }
        if path == "/timeout/healthz" || path == "/offline/healthz" {
            client?.urlProtocol(self, didFailWithError: URLError(path.contains("timeout") ? .timedOut : .cannotConnectToHost))
            return
        }
        let status = path == "/unauthorized/healthz" ? 401 : path == "/missing/healthz" ? 404 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        let payload = path == "/invalid/healthz" ? "<html>Not Warren</html>" : #"{"ok":true,"ready":true,"version":"4.0","build":"test-build"}"#
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
