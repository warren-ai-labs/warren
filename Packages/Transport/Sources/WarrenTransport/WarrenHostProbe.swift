import Foundation

/// Health is advisory: only the authenticated WebSocket can establish access.
public struct WarrenHostProbe: Equatable, Sendable {
    public let message: String
    public let isFailure: Bool
    public let hostID: String?

    public init(message: String, isFailure: Bool = false, hostID: String? = nil) {
        self.message = message
        self.isFailure = isFailure
        self.hostID = hostID
    }

    public static func check(
        _ endpoint: WarrenRemoteEndpointConfiguration,
        session: URLSession = .shared,
        expectedHostID: String? = nil,
        timeout: TimeInterval = 5,
        clientID: String? = nil
    ) async -> Self {
        guard !endpoint.isRelay, endpoint.ssh == nil,
              var url = URLComponents(string: endpoint.url) else {
            return Self(message: "Health probe unavailable for this route")
        }
        switch url.scheme?.lowercased() {
        case "ws": url.scheme = "http"
        case "wss": url.scheme = "https"
        default: break
        }
        guard ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            return Self(message: "Invalid Host URL", isFailure: true)
        }
        // /healthz is public. Do not send catalog credentials or URL tokens.
        url.user = nil
        url.password = nil
        url.query = nil
        url.fragment = nil
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = "/" + (url.path.isEmpty ? "" : url.path + "/") + "healthz"
        guard let healthURL = url.url else {
            return Self(message: "Invalid Host URL", isFailure: true)
        }
        var request = URLRequest(url: healthURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        if let clientID {
            let value = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                request.setValue(value, forHTTPHeaderField: "X-Warren-Client-ID")
            }
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return Self(message: "Invalid health response", isFailure: true)
            }
            guard response.statusCode == 200 else {
                return Self(message: "Health probe: HTTP \(response.statusCode)", isFailure: true)
            }
            return try decode(data, expectedHostID: expectedHostID)
        } catch let error as URLError where error.code == .timedOut {
            return Self(message: "Health probe timed out", isFailure: true)
        } catch is DecodingError {
            return Self(message: "Invalid health response", isFailure: true)
        } catch {
            // URL errors can include credentials from the original endpoint.
            return Self(message: "Host unreachable — check the address or tunnel", isFailure: true)
        }
    }

    static func decode(_ data: Data, expectedHostID: String? = nil) throws -> Self {
        struct Health: Decodable {
            let ok: Bool
            let ready: Bool?
            let version: String?
            let build: String?
            let hostID: String?

            enum CodingKeys: String, CodingKey {
                case ok, ready, version, build
                case hostID = "host_id"
            }
        }
        let health = try JSONDecoder().decode(Health.self, from: data)
        let client = WarrenRemoteClient.protocolVersion
        let version = health.version ?? "unknown"
        let build = health.build ?? "unknown"
        let expected = expectedHostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = health.hostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expected, !expected.isEmpty, hostID?.caseInsensitiveCompare(expected) != .orderedSame {
            return Self(message: "Host identity mismatch", isFailure: true, hostID: hostID)
        }
        let mismatch = health.version.map { !WarrenRemoteClient.compatibleProtocolVersion($0, with: client) } ?? false
        let status: String
        if mismatch {
            status = "Protocol mismatch: Host \(version), client \(client). Update Warren on both machines."
        } else if !health.ok || health.ready == false {
            status = "Host responding, not ready"
        } else {
            status = "Host reachable · protocol \(version)"
        }
        return Self(
            message: "\(status)\nHeadless \(build)",
            isFailure: mismatch || !health.ok || health.ready == false,
            hostID: hostID
        )
    }
}
