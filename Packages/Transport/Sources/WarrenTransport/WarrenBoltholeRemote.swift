import Bolthole
import Foundation

/// Serverless remote access (`docs/remote.md`).
///
/// A Host shares a Bolthole connection string whose fragment also carries
/// the Host ID, a pairing invite and the Host name:
///
///     https://relay.example.com/#k=<code>&host=<host id>&invite=<invite>&name=<name>
///
/// The fragment never reaches a server. The connect code opens an
/// end-to-end encrypted session to the Host, over the relay or directly on
/// the LAN; the invite is exchanged once, inside that session, for this
/// device's own paired-client token. `/v1/ws` then authenticates with that
/// token exactly as a LAN socket does.
public struct WarrenRemoteShareLink: Equatable, Sendable {
    /// The relay base URL without fragment or trailing slash.
    public let relayURL: String
    /// The base64url connect code. It is a secret.
    public let connectCode: String
    public let hostID: String
    /// The pairing invite. Absent on a link that only reconnects.
    public let invite: String?
    public let hostName: String?

    /// Whether `value` looks like a remote access link rather than a Relay
    /// invite or a LAN address, so the scanner can route it without trying
    /// every parser.
    public static func isCandidate(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let fragment = components.fragment else { return false }
        return fragment.split(separator: "&").contains { $0.hasPrefix("k=") }
    }

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              let fragment = components.fragment else {
            throw WarrenRemoteShareError.invalidLink
        }
        var parameters: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let decoded = parts[1].replacingOccurrences(of: "+", with: " ")
            parameters[parts[0]] = decoded.removingPercentEncoding ?? decoded
        }
        guard let code = parameters["k"], !code.isEmpty,
              let hostID = parameters["host"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostID.isEmpty else {
            throw WarrenRemoteShareError.invalidLink
        }
        // Validates the code's encoding and length before anything is saved.
        _ = try ConnectCode(code)
        components.fragment = nil
        components.query = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let relay = components.url?.absoluteString else { throw WarrenRemoteShareError.invalidLink }
        self.relayURL = relay
        self.connectCode = code
        self.hostID = hostID
        let invite = parameters["invite"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.invite = (invite?.isEmpty ?? true) ? nil : invite
        let name = parameters["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostName = (name?.isEmpty ?? true) ? nil : name
    }

    /// The Bolthole connection string (relay + code only).
    public var connectionString: String {
        Self.connectionString(relayURL: relayURL, connectCode: connectCode)
    }

    public static func connectionString(relayURL: String, connectCode: String) -> String {
        var base = relayURL
        if let hash = base.firstIndex(of: "#") { base = String(base[..<hash]) }
        if !base.hasSuffix("/") { base += "/" }
        return base + "#k=" + connectCode
    }
}

public enum WarrenRemoteShareError: LocalizedError, Equatable, Sendable {
    case invalidLink
    case missingInvite
    case expired
    case rejected(status: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "This is not a Warren remote access link."
        case .missingInvite:
            return "This link cannot pair a new device. Create a new one with Share on the Host."
        case .expired:
            return "The link has expired or was replaced. Create a new one on the Host."
        case .rejected(let status):
            return "The Host refused the pairing (HTTP \(status))."
        case .invalidResponse:
            return "The Host returned an invalid pairing response."
        }
    }
}

public enum WarrenRemotePairing {
    /// Exchanges the link's invite for this device's own token, inside an
    /// end-to-end encrypted session. The returned token authenticates `/v1/ws`
    /// on every path (relay or LAN).
    public static func pair(
        link: WarrenRemoteShareLink,
        clientID: String,
        clientName: String?
    ) async throws -> String {
        guard let invite = link.invite else { throw WarrenRemoteShareError.missingInvite }
        let client = try BoltholeClient(link.connectionString)
        defer { Task { await client.close() } }
        var body: [String: String] = [
            "host_id": link.hostID,
            "client_id": clientID,
            "invite": invite,
        ]
        if let clientName, !clientName.isEmpty { body["client_name"] = clientName }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let response = try await client.request(
            "POST",
            "/v1/pairing/request",
            headers: ["content-type": "application/json"],
            body: payload
        )
        let data = try await response.data()
        switch response.status {
        case 200:
            break
        case 409:
            throw WarrenRemoteShareError.expired
        default:
            throw WarrenRemoteShareError.rejected(status: response.status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String,
              !token.isEmpty else {
            throw WarrenRemoteShareError.invalidResponse
        }
        return token
    }
}

public enum WarrenBoltholeAdapterError: Error, Equatable, Sendable {
    case closed
}

/// A `WarrenWebSocketTaskAdapter` over a Bolthole `ws` stream, so the
/// existing remote client speaks the Warren protocol through the encrypted
/// session unchanged. The Bolthole client underneath picks the path (LAN
/// direct or relay) and moves between them on its own.
public actor WarrenBoltholeWebSocketAdapter: WarrenWebSocketTaskAdapter {
    private let client: BoltholeClient
    private let path: String
    private var opening: Task<WebSocketStream, Error>?
    private var cancelled = false

    public init(client: BoltholeClient, path: String = "/v1/ws") {
        self.client = client
        self.path = path
    }

    /// Starts opening the stream without waiting for it, so the caller's
    /// welcome deadline also bounds the encrypted handshake.
    public func resume() async {
        _ = startOpening()
    }

    private func startOpening() -> Task<WebSocketStream, Error> {
        if let opening { return opening }
        let client = self.client
        let path = self.path
        let task = Task { try await client.webSocket(path) }
        opening = task
        return task
    }

    private func stream() async throws -> WebSocketStream {
        if cancelled { throw WarrenBoltholeAdapterError.closed }
        return try await startOpening().value
    }

    public func cancel() async {
        cancelled = true
        guard let opening else { return }
        opening.cancel()
        // Close in the background: a handshake that never completes must not
        // hold up the caller's teardown.
        Task { if let socket = try? await opening.value { await socket.close() } }
    }

    public func send(_ message: WarrenWebSocketMessage) async throws {
        let socket = try await stream()
        switch message {
        case .text(let value):
            try await socket.send(.text(value))
        case .binary(let value):
            try await socket.send(.data(Data(value)))
        }
    }

    public func receive() async throws -> WarrenWebSocketMessage {
        let socket = try await stream()
        guard let message = try await socket.receive() else {
            throw WarrenBoltholeAdapterError.closed
        }
        switch message {
        case .text(let value):
            return .text(value)
        case .data(let value):
            return .binary(Array(value))
        }
    }
}

public extension WarrenRemoteEndpointConfiguration {
    /// Remote access endpoints (Bolthole). `url` is the relay base URL and
    /// `token` the paired-client token; the connect code is a secret kept in
    /// the Keychain and carried in `refreshToken`, which no other code path
    /// uses for this endpoint type.
    var isRemote: Bool {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "remote"
    }

    /// The Bolthole connection string, when this is a remote endpoint with
    /// its connect code available.
    var remoteConnectionString: String? {
        guard isRemote, let code = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return nil
        }
        return WarrenRemoteShareLink.connectionString(relayURL: url, connectCode: code)
    }

    /// Maps the route preference onto Bolthole path selection: Bolthole races
    /// LAN candidates against the relay itself, so "auto" needs nothing else.
    var remoteMode: BoltholeClient.Mode {
        switch (routePreference ?? "auto").lowercased() {
        case "direct": return .directOnly
        case "relay": return .relayOnly
        default: return .auto
        }
    }
}
