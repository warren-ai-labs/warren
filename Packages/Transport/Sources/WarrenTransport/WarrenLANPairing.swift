import Foundation

/// The one-time credential returned by a Host's explicitly armed LAN pairing
/// window. The token is deliberately not Codable on any persisted endpoint
/// catalog; callers should write it to a platform Keychain.
public struct WarrenLANPairingExchange: Codable, Equatable, Hashable, Sendable {
    public let hostID: String
    public let clientID: String
    public let token: String

    public init(hostID: String, clientID: String, token: String) {
        self.hostID = hostID
        self.clientID = clientID
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case clientID = "client_id"
        case token
    }
}

public enum WarrenLANPairingError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case invalidResponse
    case exchangeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The discovered Host endpoint is invalid."
        case .invalidResponse: return "The Host returned an invalid pairing response."
        case .exchangeFailed(let message): return "LAN pairing failed: \(message)"
        }
    }
}

/// Performs the unauthenticated half of the LAN pairing flow. The endpoint is
/// reachable only while the Host's temporary PIN window is open; it never
/// sends a stored Host token.
public enum WarrenLANPairingClient {
    public static func request(
        hostURL: String,
        hostID: String,
        clientID: String,
        clientName: String,
        pin: String,
        session: URLSession = WarrenRemoteNetworking.session
    ) async throws -> WarrenLANPairingExchange {
        guard var components = URLComponents(string: hostURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw WarrenLANPairingError.invalidURL
        }
        components.path = "/v1/pairing/request"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw WarrenLANPairingError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "host_id": hostID,
            "client_id": clientID,
            "client_name": clientName,
            "pin": pin,
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WarrenLANPairingError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw WarrenLANPairingError.exchangeFailed(
                    message?.isEmpty == false ? message! : "HTTP \(http.statusCode)"
                )
            }
            guard let exchange = try? JSONDecoder().decode(WarrenLANPairingExchange.self, from: data),
                  !exchange.hostID.isEmpty,
                  !exchange.clientID.isEmpty,
                  !exchange.token.isEmpty else {
                throw WarrenLANPairingError.invalidResponse
            }
            return exchange
        } catch let error as WarrenLANPairingError {
            throw error
        } catch {
            throw WarrenLANPairingError.exchangeFailed(error.localizedDescription)
        }
    }
}
