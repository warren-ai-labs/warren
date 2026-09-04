import Foundation
import WarrenDomain

/// One URLSession is shared by native Relay pairing and the WebSocket client.
/// Besides preserving the HttpOnly refresh cookie, waiting for connectivity
/// avoids turning a short Wi‑Fi handoff into a tight reconnect loop on iOS.
/// The session still uses Foundation's normal proxy and TLS policy; no
/// certificate or proxy bypass is installed here.
public enum WarrenRemoteNetworking {
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: configuration)
    }()
}

/// The endpoint description used by native clients.
///
/// `type` is kept as a string for compatibility with the desktop endpoint
/// catalog. A `daemon` endpoint talks to Headless directly; a `relay` endpoint
/// uses the host-scoped Relay WebSocket path and treats `hostID` as part of the
/// routing identity. Callers should load `token` from a Keychain-backed store
/// on mobile instead of persisting it in UserDefaults. The desktop client
/// keeps its historical file-backed token in its own adapter.
public struct WarrenRemoteEndpointConfiguration: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let url: String
    public let token: String
    public let ssh: String?
    public let sshRemote: String?
    public let type: String
    public let hostID: String?
    public let routeID: String?
    public let refreshToken: String?  // OAuth2 refresh token for Relay

    /// Returns a copy with a rotated Relay capability. Native clients use
    /// this when restoring a persisted endpoint after an app reinstall.
    public func withTokens(token: String, refreshToken: String?) -> Self {
        Self(name: name, url: url, token: token, ssh: ssh, sshRemote: sshRemote,
             type: type, hostID: hostID, routeID: routeID, refreshToken: refreshToken)
    }
    
    public init(
        name: String,
        url: String,
        token: String = "",
        ssh: String? = nil,
        sshRemote: String? = nil,
        type: String = "daemon",
        hostID: String? = nil,
        routeID: String? = nil,
        refreshToken: String? = nil
    ) {
        self.name = name
        self.url = url
        self.token = token
        self.ssh = ssh
        self.sshRemote = sshRemote
        self.type = type
        self.hostID = hostID
        self.routeID = routeID
        self.refreshToken = refreshToken
    }

    public var id: String { name }

    public var isRelay: Bool {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "relay"
    }

    /// Converts the configured endpoint to the WebSocket URL exposed by
    /// Headless, either directly or through the host-scoped Relay route.
    public var webSocketURL: URL? {
        guard var components = URLComponents(string: url) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        if isRelay {
            guard let hostID = normalizedHostID else { return nil }
            components.path = relayPath(components.path, hostID: hostID, endpoint: "v1/client/connect")
        } else {
            components.path = "/v1/ws"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The HTTPS endpoint used to exchange a shareable Relay pairing ticket.
    /// The host-scoped form preserves reverse-proxy prefixes and lets Relay
    /// bind the ticket to the Host identity in the URL.
    public var relaySessionExchangeURL: URL? {
        relaySessionURL(endpoint: "v1/session/exchange")
    }

    /// The HTTPS endpoint used to rotate a Relay refresh capability.
    public var relaySessionRefreshURL: URL? {
        relaySessionURL(endpoint: "v1/session/refresh")
    }

    /// The host-scoped endpoint used to register an ActivityKit push token.
    /// Registration is separate from the WebSocket so Relay can deliver a
    /// Live Activity update while this client and its app process are asleep.
    public var relayLiveActivityRegistrationURL: URL? {
        relaySessionURL(endpoint: "v1/live-activities")
    }

    private var normalizedHostID: String? {
        guard let hostID else { return nil }
        let value = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("/") || value.contains("\\") ? nil : value
    }

    private func relaySessionURL(endpoint: String) -> URL? {
        guard isRelay,
              let hostID = normalizedHostID,
              var components = URLComponents(string: url) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        case "http", "https": break
        default: return nil
        }
        components.path = relayPath(components.path, hostID: hostID, endpoint: endpoint)
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func relayPath(_ existingPath: String, hostID: String, endpoint: String) -> String {
        let prefix = existingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hostPath = "/h/\(hostID)/\(endpoint)"
        return prefix.isEmpty ? hostPath : "/\(prefix)\(hostPath)"
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, token, ssh, sshRemote, type
        case hostID = "host_id"
        case routeID = "route_id"
        case refreshToken = "refresh_token"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try values.decode(String.self, forKey: .name),
            url: try values.decode(String.self, forKey: .url),
            token: try values.decodeIfPresent(String.self, forKey: .token) ?? "",
            ssh: try values.decodeIfPresent(String.self, forKey: .ssh),
            sshRemote: try values.decodeIfPresent(String.self, forKey: .sshRemote),
            type: try values.decodeIfPresent(String.self, forKey: .type) ?? "daemon",
            hostID: try values.decodeIfPresent(String.self, forKey: .hostID),
            routeID: try values.decodeIfPresent(String.self, forKey: .routeID),
            refreshToken: try values.decodeIfPresent(String.self, forKey: .refreshToken)
        )
    }
}

/// The result of exchanging a shareable Relay pairing ticket. The access
/// capability is intentionally short-lived and belongs in memory/Keychain;
/// Relay remains the authority for refresh rotation. The ticket itself stays
/// valid for the Relay's configured sharing window so multiple devices can
/// exchange the same QR/link.
public struct WarrenRelaySessionExchange: Codable, Equatable, Hashable, Sendable {
    public let hostID: String
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?

    public init(hostID: String, accessToken: String, refreshToken: String? = nil, expiresIn: Int? = nil) {
        self.hostID = hostID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

public struct WarrenRelayPairing: Codable, Equatable, Hashable, Sendable {
    public let relayURL: String
    public let hostID: String
    public let pairingTicket: String
    /// Opaque client-facing invite ID. New links carry this value instead of
    /// exposing the Host ID; the Relay resolves it during exchange.
    public let inviteID: String?

    public init(relayURL: String, hostID: String, pairingTicket: String, inviteID: String? = nil) {
        self.relayURL = relayURL
        self.hostID = hostID
        self.pairingTicket = pairingTicket
        self.inviteID = inviteID
    }

    /// Converts the pairing into an endpoint after a successful ticket
    /// exchange. The endpoint name is deliberately local-only metadata.
    public func endpoint(
        accessToken: String,
        name: String? = nil,
        routeID: String? = nil
    ) -> WarrenRemoteEndpointConfiguration {
        WarrenRemoteEndpointConfiguration(
            name: name ?? (hostID.isEmpty ? "Relay Host" : "Relay \(hostID.prefix(8))"),
            url: relayURL,
            token: accessToken,
            type: "relay",
            hostID: hostID,
            routeID: routeID
        )
    }
}

public enum WarrenRelayPairingError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case missingHostID
    case missingPairingTicket
    case unsupportedScheme
    case exchangeFailed(String)
    case invalidExchangeResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The Relay pairing link is invalid."
        case .missingHostID: return "The Relay pairing link does not identify a Host."
        case .missingPairingTicket: return "The Relay pairing link has expired or has no pairing ticket."
        case .unsupportedScheme: return "Relay pairing requires an HTTP(S) link."
        case .exchangeFailed(let message): return "Relay pairing failed: \(message)"
        case .invalidExchangeResponse: return "Relay returned an invalid pairing response."
        }
    }
}

/// QR/paste pairing support lives in Transport so iOS and future native
/// clients share the same URL parsing and HTTPS exchange rules.
public enum WarrenRelayPairingClient {
    public static func parse(_ url: URL) throws -> WarrenRelayPairing {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            throw WarrenRelayPairingError.invalidURL
        }
        guard ["http", "https", "ws", "wss"].contains(scheme) else {
            throw WarrenRelayPairingError.unsupportedScheme
        }

        // New Relay links are opaque: /<optional-prefix>/invite/<invite-id>/.
        // Keep accepting the historical host-scoped /h/<host-id>/#t= form so
        // existing links continue to work while users move to opaque invites.
        let path = components.path
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let markerIndex = pathParts.lastIndex(where: { $0 == "invite" || $0 == "h" }),
              markerIndex + 1 < pathParts.count,
              markerIndex + 2 == pathParts.count else {
            throw WarrenRelayPairingError.missingHostID
        }
        let isInvite = pathParts[markerIndex] == "invite"
        let identity = String(pathParts[markerIndex + 1])
        guard !identity.isEmpty,
              !identity.contains("\\"),
              !identity.contains("?"),
              (!isInvite || Self.validInviteID(identity))
        else { throw WarrenRelayPairingError.missingHostID }

        let hostID = isInvite ? "" : identity
        let inviteID = isInvite ? identity : nil

        let ticket: String?
        if isInvite {
            ticket = nil
        } else if let fragment = components.fragment {
            let fragmentItems = URLComponents(string: "https://pairing.invalid/?\(fragment)")?.queryItems
            ticket = fragmentItems?.first(where: { $0.name == "t" || $0.name == "pairing_ticket" })?.value
                ?? (fragment.hasPrefix("t=") ? String(fragment.dropFirst(2)) : nil)
        } else {
            ticket = components.queryItems?.first(where: { $0.name == "t" || $0.name == "pairing_ticket" })?.value
        }
        if !isInvite && (ticket?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
            throw WarrenRelayPairingError.missingPairingTicket
        }

        var relay = components
        relay.scheme = scheme == "ws" ? "http" : (scheme == "wss" ? "https" : scheme)
        let prefixParts = pathParts[..<markerIndex]
        relay.path = prefixParts.isEmpty ? "" : "/" + prefixParts.joined(separator: "/")
        relay.query = nil
        relay.fragment = nil
        guard let relayURL = relay.url, relayURL.host != nil else {
            throw WarrenRelayPairingError.invalidURL
        }
        return WarrenRelayPairing(
            relayURL: relayURL.absoluteString,
            hostID: hostID,
            pairingTicket: ticket ?? "",
            inviteID: inviteID
        )
    }

    private static func validInviteID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
        }
    }

    public static func exchange(
        _ pairing: WarrenRelayPairing,
        urlSession: URLSession = WarrenRemoteNetworking.session,
        clientID: String? = nil
    ) async throws -> WarrenRelaySessionExchange {
        guard var components = URLComponents(string: pairing.relayURL),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            throw WarrenRelayPairingError.invalidURL
        }
        switch scheme {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        case "http", "https": break
        default: throw WarrenRelayPairingError.unsupportedScheme
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let inviteID = pairing.inviteID {
            guard Self.validInviteID(inviteID) else {
                throw WarrenRelayPairingError.invalidURL
            }
            let path = "/invite/\(inviteID)/v1/session/exchange"
            components.path = prefix.isEmpty ? path : "/\(prefix)\(path)"
        } else {
            guard !pairing.hostID.isEmpty, !pairing.pairingTicket.isEmpty else {
                throw WarrenRelayPairingError.missingPairingTicket
            }
            let path = "/h/\(pairing.hostID)/v1/session/exchange"
            components.path = prefix.isEmpty ? path : "/\(prefix)\(path)"
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw WarrenRelayPairingError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String]
        if let inviteID = pairing.inviteID {
            body = ["invite_id": inviteID]
        } else {
            body = ["pairing_ticket": pairing.pairingTicket]
        }
        if let clientID, !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["client_id"] = clientID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WarrenRelayPairingError.exchangeFailed("invalid server response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WarrenRelayPairingError.exchangeFailed(detail?.isEmpty == false ? detail! : "HTTP \(http.statusCode)")
        }
        guard let value = try? JSONDecoder().decode(WarrenRelaySessionExchange.self, from: data),
              !value.hostID.isEmpty,
              !value.accessToken.isEmpty else {
            throw WarrenRelayPairingError.invalidExchangeResponse
        }
        guard pairing.hostID.isEmpty || value.hostID == pairing.hostID else {
            throw WarrenRelayPairingError.invalidExchangeResponse
        }
        return value
    }
}

/// A Host resource snapshot. IDs intentionally remain strings: a remote Host
/// may use IDs from a future implementation that are not UUIDs.
public struct WarrenRemoteRoster: Codable, Equatable, Hashable, Sendable {
    public struct Host: Codable, Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let user: String?
        public let os: String?
        public let version: String?

        public init(id: String, name: String, user: String? = nil, os: String? = nil, version: String? = nil) {
            self.id = id
            self.name = name
            self.user = user
            self.os = os
            self.version = version
        }
    }

    public struct Project: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let path: String
        public let autoImportGitWorktrees: Bool
        public let pinned: Bool
        public let order: Int

        public init(
            id: String,
            name: String,
            path: String,
            autoImportGitWorktrees: Bool = false,
            pinned: Bool = false,
            order: Int = 0
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.autoImportGitWorktrees = autoImportGitWorktrees
            self.pinned = pinned
            self.order = order
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, path, autoImportGitWorktrees, pinned, order
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
            path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
            autoImportGitWorktrees = try values.decodeIfPresent(Bool.self, forKey: .autoImportGitWorktrees) ?? false
            pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            order = try values.decodeIfPresent(Int.self, forKey: .order) ?? 0
        }
    }

    public struct Workspace: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public let name: String
        public let path: String
        public let branch: String?
        public let kind: String?
        public let managedWorktree: Bool
        public let worktreeLocked: Bool
        public let pinned: Bool
        public let order: Int
        public let mergeState: String?

        public init(
            id: String,
            projectID: String,
            name: String,
            path: String,
            branch: String? = nil,
            kind: String? = nil,
            managedWorktree: Bool = false,
            worktreeLocked: Bool = false,
            pinned: Bool = false,
            order: Int = 0,
            mergeState: String? = nil
        ) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.path = path
            self.branch = branch
            self.kind = kind
            self.managedWorktree = managedWorktree
            self.worktreeLocked = worktreeLocked
            self.pinned = pinned
            self.order = order
            self.mergeState = mergeState
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case projectID = "project"
            case name, path, branch, kind, managedWorktree, worktreeLocked, pinned, order, mergeState
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            projectID = try values.decodeIfPresent(String.self, forKey: .projectID) ?? ""
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
            path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
            branch = try values.decodeIfPresent(String.self, forKey: .branch)
            kind = try values.decodeIfPresent(String.self, forKey: .kind)
            managedWorktree = try values.decodeIfPresent(Bool.self, forKey: .managedWorktree) ?? false
            worktreeLocked = try values.decodeIfPresent(Bool.self, forKey: .worktreeLocked) ?? false
            pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            order = try values.decodeIfPresent(Int.self, forKey: .order) ?? 0
            mergeState = try values.decodeIfPresent(String.self, forKey: .mergeState)
        }
    }

    public struct TerminalGroup: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let home: String?
        public let order: Int
        public let createdAt: String?

        public init(id: String, name: String, home: String? = nil, order: Int = 0, createdAt: String? = nil) {
            self.id = id
            self.name = name
            self.home = home
            self.order = order
            self.createdAt = createdAt
        }

        private enum CodingKeys: String, CodingKey { case id, name, home, order, createdAt }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
            home = try values.decodeIfPresent(String.self, forKey: .home)
            order = try values.decodeIfPresent(Int.self, forKey: .order) ?? 0
            createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        }
    }

    public enum SessionScope: String, Codable, Hashable, Sendable {
        case workspace
        case terminalGroup
        case unknown
    }

    /// A Host-owned terminal session. Workspace and terminal-group ownership
    /// stay separate so a standalone shell is never accidentally projected as
    /// a workspace session.
    public struct Session: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: String
        public let workspaceID: String?
        public let terminalGroupID: String?
        public let scope: SessionScope
        public let title: String
        public let customTitle: String?
        public let kind: String
        public let agentHandler: String?
        public let command: String?
        public let process: String?
        public let directory: String?
        public let runtime: String?
        public let runtimeKind: String?
        public let lifecycle: String
        public let epoch: UInt64?
        public let sequence: UInt64?
        public let pinned: Bool
        public let agentSessionID: String?
        public let transcriptPath: String?
        public let agentStatus: WarrenRemoteAgentStatus?
        public let agentTurn: WarrenRemoteAgentTurn?
        /// Effective optional capabilities for this Session. `nil` means an
        /// older Host omitted the field; an empty array is an explicit
        /// capability denial.
        public let agentCapabilities: [String]?
        public let createdAt: String?
        public let endedAt: String?

        public init(
            id: String,
            workspaceID: String? = nil,
            terminalGroupID: String? = nil,
            scope: SessionScope? = nil,
            title: String = "",
            customTitle: String? = nil,
            kind: String = "shell",
            agentHandler: String? = nil,
            command: String? = nil,
            process: String? = nil,
            directory: String? = nil,
            runtime: String? = nil,
            runtimeKind: String? = nil,
            lifecycle: String = "running",
            epoch: UInt64? = nil,
            sequence: UInt64? = nil,
            pinned: Bool = false,
            agentSessionID: String? = nil,
            transcriptPath: String? = nil,
            agentStatus: WarrenRemoteAgentStatus? = nil,
            agentTurn: WarrenRemoteAgentTurn? = nil,
            agentCapabilities: [String]? = nil,
            createdAt: String? = nil,
            endedAt: String? = nil
        ) {
            self.id = id
            self.workspaceID = workspaceID
            self.terminalGroupID = terminalGroupID
            self.scope = scope ?? {
                if terminalGroupID != nil { return .terminalGroup }
                if workspaceID != nil { return .workspace }
                return .unknown
            }()
            self.title = title
            self.customTitle = customTitle
            self.kind = kind
            self.agentHandler = agentHandler
            self.command = command
            self.process = process
            self.directory = directory
            self.runtime = runtime
            self.runtimeKind = runtimeKind
            self.lifecycle = lifecycle
            self.epoch = epoch
            self.sequence = sequence
            self.pinned = pinned
            self.agentSessionID = agentSessionID
            self.transcriptPath = transcriptPath
            self.agentStatus = agentStatus
            self.agentTurn = agentTurn
            self.agentCapabilities = agentCapabilities
            self.createdAt = createdAt
            self.endedAt = endedAt
        }

        public var displayTitle: String {
            let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return custom.isEmpty ? title : custom
        }

        public var isRunning: Bool { lifecycle == "running" }

        /// Agent activity belongs only to Sessions backed by a Warren Agent.
        /// Dedicated Agent Sessions identify their provider by kind, while a
        /// shell can become Agent-backed after Warren records its binding.
        public var isAgentBacked: Bool {
            if let agentSessionID,
               !agentSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "codex", "claude", "opencode", "pi", "qoder":
                return true
            default:
                return false
            }
        }

        public func supportsAgentCapability(_ capability: String) -> Bool {
            guard let agentCapabilities else {
                // Compatibility with Hosts predating Session-level fields is
                // handled by the connection-level capability handshake.
                return true
            }
            return agentCapabilities.contains(capability)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case workspaceID = "workspace"
            case terminalGroupID = "terminalGroup"
            case scope, title, customTitle, kind, agentHandler, command, process, directory, runtime, runtimeKind
            case lifecycle, epoch, sequence, pinned
            case agentSessionID = "agentSessionId"
            case transcriptPath, agentStatus, agentTurn, agentCapabilities, createdAt, endedAt
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID)
            terminalGroupID = try values.decodeIfPresent(String.self, forKey: .terminalGroupID)
            let rawScope = try values.decodeIfPresent(String.self, forKey: .scope)
            if let rawScope, let parsed = SessionScope(rawValue: rawScope) {
                scope = parsed
            } else if terminalGroupID != nil {
                scope = .terminalGroup
            } else if workspaceID != nil {
                scope = .workspace
            } else {
                scope = .unknown
            }
            title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
            customTitle = try values.decodeIfPresent(String.self, forKey: .customTitle)
            kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "shell"
            agentHandler = try values.decodeIfPresent(String.self, forKey: .agentHandler)
            command = try values.decodeIfPresent(String.self, forKey: .command)
            process = try values.decodeIfPresent(String.self, forKey: .process)
            directory = try values.decodeIfPresent(String.self, forKey: .directory)
            runtime = try values.decodeIfPresent(String.self, forKey: .runtime)
            runtimeKind = try values.decodeIfPresent(String.self, forKey: .runtimeKind)
            lifecycle = try values.decodeIfPresent(String.self, forKey: .lifecycle) ?? "running"
            epoch = try values.decodeIfPresent(UInt64.self, forKey: .epoch)
            sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence)
            pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            agentSessionID = try values.decodeIfPresent(String.self, forKey: .agentSessionID)
            transcriptPath = try values.decodeIfPresent(String.self, forKey: .transcriptPath)
            agentStatus = try values.decodeIfPresent(WarrenRemoteAgentStatus.self, forKey: .agentStatus)
            agentTurn = try values.decodeIfPresent(WarrenRemoteAgentTurn.self, forKey: .agentTurn)
            agentCapabilities = try values.decodeIfPresent([String].self, forKey: .agentCapabilities)
            createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
            endedAt = try values.decodeIfPresent(String.self, forKey: .endedAt)
        }
    }

    public struct WorktreeCandidate: Codable, Equatable, Hashable, Sendable {
        public let path: String
        public let name: String
        public let branch: String?
        public let locked: Bool
        public let imported: Bool
        public let workspaceID: String?

        public init(path: String, name: String, branch: String? = nil, locked: Bool = false, imported: Bool = false, workspaceID: String? = nil) {
            self.path = path
            self.name = name
            self.branch = branch
            self.locked = locked
            self.imported = imported
            self.workspaceID = workspaceID
        }

        private enum CodingKeys: String, CodingKey {
            case path, name, branch, locked, imported
            case workspaceID = "workspace"
        }
    }

    public struct EntityChanges<Value: Codable & Sendable>: Codable, Equatable, Hashable, Sendable where Value: Equatable & Hashable {
        public let upsert: [Value]
        public let remove: [String]
        public let order: [String]?

        public init(upsert: [Value] = [], remove: [String] = [], order: [String]? = nil) {
            self.upsert = upsert
            self.remove = remove
            self.order = order
        }

        private enum CodingKeys: String, CodingKey { case upsert, remove, order }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            upsert = try values.decodeIfPresent([Value].self, forKey: .upsert) ?? []
            remove = try values.decodeIfPresent([String].self, forKey: .remove) ?? []
            order = try values.decodeIfPresent([String].self, forKey: .order)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(upsert, forKey: .upsert)
            try values.encode(remove, forKey: .remove)
            try values.encodeIfPresent(order, forKey: .order)
        }
    }

    public struct Delta: Codable, Equatable, Hashable, Sendable {
        public let baseRevision: UInt64
        public let revision: UInt64
        public let host: Host?
        public let projects: EntityChanges<Project>?
        public let workspaces: EntityChanges<Workspace>?
        public let terminalGroups: EntityChanges<TerminalGroup>?
        public let sessions: EntityChanges<Session>?

        public init(
            baseRevision: UInt64,
            revision: UInt64,
            host: Host? = nil,
            projects: EntityChanges<Project>? = nil,
            workspaces: EntityChanges<Workspace>? = nil,
            terminalGroups: EntityChanges<TerminalGroup>? = nil,
            sessions: EntityChanges<Session>? = nil
        ) {
            self.baseRevision = baseRevision
            self.revision = revision
            self.host = host
            self.projects = projects
            self.workspaces = workspaces
            self.terminalGroups = terminalGroups
            self.sessions = sessions
        }

        private enum CodingKeys: String, CodingKey {
            case baseRevision, revision, host, projects, workspaces
            case terminalGroups
            case groups
            case sessions
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            baseRevision = try values.decode(UInt64.self, forKey: .baseRevision)
            revision = try values.decode(UInt64.self, forKey: .revision)
            host = try values.decodeIfPresent(Host.self, forKey: .host)
            projects = try values.decodeIfPresent(EntityChanges<Project>.self, forKey: .projects)
            workspaces = try values.decodeIfPresent(EntityChanges<Workspace>.self, forKey: .workspaces)
            terminalGroups = try values.decodeIfPresent(EntityChanges<TerminalGroup>.self, forKey: .terminalGroups)
                ?? values.decodeIfPresent(EntityChanges<TerminalGroup>.self, forKey: .groups)
            sessions = try values.decodeIfPresent(EntityChanges<Session>.self, forKey: .sessions)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(baseRevision, forKey: .baseRevision)
            try values.encode(revision, forKey: .revision)
            try values.encodeIfPresent(host, forKey: .host)
            try values.encodeIfPresent(projects, forKey: .projects)
            try values.encodeIfPresent(workspaces, forKey: .workspaces)
            try values.encodeIfPresent(terminalGroups, forKey: .terminalGroups)
            try values.encodeIfPresent(sessions, forKey: .sessions)
        }
    }

    public struct StreamMessage: Decodable, Sendable {
        public let type: String
        public let state: WarrenRemoteRoster?
        public let delta: Delta?

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            state = try values.decodeIfPresent(WarrenRemoteRoster.self, forKey: .state)
            delta = type == "roster.delta" ? try Delta(from: decoder) : nil
        }

        private enum CodingKeys: String, CodingKey {
            case type = "t"
            case state
        }
    }

    public let schema: Int?
    public let revision: UInt64?
    public let host: Host
    public let projects: [Project]
    public let workspaces: [Workspace]
    public let terminalGroups: [TerminalGroup]
    public let sessions: [Session]

    public init(
        schema: Int? = nil,
        revision: UInt64? = nil,
        host: Host,
        projects: [Project] = [],
        workspaces: [Workspace] = [],
        terminalGroups: [TerminalGroup] = [],
        sessions: [Session] = []
    ) {
        self.schema = schema
        self.revision = revision
        self.host = host
        self.projects = projects
        self.workspaces = workspaces
        self.terminalGroups = terminalGroups
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case schema, revision, host, projects, workspaces, terminalGroups, sessions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema)
        revision = try values.decodeIfPresent(UInt64.self, forKey: .revision)
        host = try values.decode(Host.self, forKey: .host)
        projects = try values.decodeIfPresent([Project].self, forKey: .projects) ?? []
        workspaces = try values.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        terminalGroups = try values.decodeIfPresent([TerminalGroup].self, forKey: .terminalGroups) ?? []
        sessions = try values.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    }

    public func applying(_ delta: Delta) -> WarrenRemoteRoster? {
        guard let revision, revision == delta.baseRevision, delta.revision > delta.baseRevision else {
            return nil
        }
        return WarrenRemoteRoster(
            schema: schema,
            revision: delta.revision,
            host: delta.host ?? host,
            projects: Self.applying(projects, changes: delta.projects, id: \.id),
            workspaces: Self.applying(workspaces, changes: delta.workspaces, id: \.id),
            terminalGroups: Self.applying(terminalGroups, changes: delta.terminalGroups, id: \.id),
            sessions: Self.applying(sessions, changes: delta.sessions, id: \.id)
        )
    }

    private static func applying<Value: Codable & Sendable & Equatable>(
        _ current: [Value],
        changes: EntityChanges<Value>?,
        id: (Value) -> String
    ) -> [Value] {
        guard let changes else { return current }
        var byID = Dictionary(uniqueKeysWithValues: current.map { (id($0), $0) })
        for value in changes.upsert { byID[id(value)] = value }
        for valueID in changes.remove { byID.removeValue(forKey: valueID) }

        var result: [Value] = []
        var emitted = Set<String>()
        if let order = changes.order {
            for valueID in order {
                guard let value = byID[valueID], emitted.insert(valueID).inserted else { continue }
                result.append(value)
            }
        }
        for value in current {
            let valueID = id(value)
            guard let latest = byID[valueID], emitted.insert(valueID).inserted else { continue }
            result.append(latest)
        }
        for value in changes.upsert {
            let valueID = id(value)
            guard let latest = byID[valueID], emitted.insert(valueID).inserted else { continue }
            result.append(latest)
        }
        return result
    }
}

// Top-level aliases keep call sites concise while retaining the roster's
// explicit hierarchy in its Codable representation.
public typealias WarrenRemoteHost = WarrenRemoteRoster.Host
public typealias WarrenRemoteProject = WarrenRemoteRoster.Project
public typealias WarrenRemoteWorkspace = WarrenRemoteRoster.Workspace
public typealias WarrenRemoteTerminalGroup = WarrenRemoteRoster.TerminalGroup
public typealias WarrenRemoteSession = WarrenRemoteRoster.Session

/// Result returned by `workspace.create`. The Host embeds the created
/// workspace fields at the top level together with the side-effect flags.
public struct WarrenRemoteWorkspaceCreateResult: Codable, Equatable, Hashable, Sendable {
    public let workspace: WarrenRemoteRoster.Workspace
    public let created: Bool
    public let gitWorktree: Bool

    public init(
        workspace: WarrenRemoteRoster.Workspace,
        created: Bool = false,
        gitWorktree: Bool = false
    ) {
        self.workspace = workspace
        self.created = created
        self.gitWorktree = gitWorktree
    }

    public init(from decoder: Decoder) throws {
        workspace = try WarrenRemoteRoster.Workspace(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        created = try values.decodeIfPresent(Bool.self, forKey: .created) ?? false
        gitWorktree = try values.decodeIfPresent(Bool.self, forKey: .gitWorktree) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        try workspace.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(created, forKey: .created)
        try values.encode(gitWorktree, forKey: .gitWorktree)
    }

    private enum CodingKeys: String, CodingKey {
        case created
        case gitWorktree = "gitWorktree"
    }
}

/// A JSON value used for provider-specific Agent tool input without leaking
/// `Any` through a Sendable API.
public enum WarrenRemoteJSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([WarrenRemoteJSONValue])
    case object([String: WarrenRemoteJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([WarrenRemoteJSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: WarrenRemoteJSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public func clipped(limit: Int = 4096) -> WarrenRemoteJSONValue {
        guard limit > 0 else { return self }
        switch self {
        case .string(let str):
            if str.count > limit {
                let index = str.index(str.startIndex, offsetBy: limit)
                return .string(String(str[..<index]) + "…")
            }
            return self
        case .array(let arr):
            return .array(arr.map { $0.clipped(limit: limit) })
        case .object(let obj):
            return .object(obj.mapValues { $0.clipped(limit: limit) })
        default:
            return self
        }
    }
}

public enum WarrenRemoteAgentActivity: String, Codable, CaseIterable, Sendable {
    case ready, working, blocked, stalled, failed, exited
    case unknown

    public init(rawValue: String) {
        switch rawValue {
        case "ready": self = .ready
        case "working": self = .working
        case "blocked": self = .blocked
        case "stalled": self = .stalled
        case "failed": self = .failed
        case "exited": self = .exited
        default: self = .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue == "unknown" ? "unknown" : rawValue)
    }
}

public enum WarrenRemoteAgentAttentionKind: String, Codable, CaseIterable, Sendable {
    case input, approval, warning
    case unknown

    public init(rawValue: String) {
        switch rawValue {
        case "input": self = .input
        case "approval": self = .approval
        case "warning": self = .warning
        default: self = .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue == "unknown" ? "unknown" : rawValue)
    }
}

public struct WarrenRemoteAgentAttention: Codable, Equatable, Hashable, Sendable {
    public let kind: WarrenRemoteAgentAttentionKind
    public let reason: String
    public let requestID: String?
    public let since: String?

    public init(kind: WarrenRemoteAgentAttentionKind, reason: String, requestID: String? = nil, since: String? = nil) {
        self.kind = kind
        self.reason = reason
        self.requestID = requestID
        self.since = since
    }

    private enum CodingKeys: String, CodingKey {
        case kind, reason
        case requestID = "requestId"
        case since
    }
}

public struct WarrenRemoteAgentStatus: Codable, Equatable, Hashable, Sendable {
    public let activity: WarrenRemoteAgentActivity
    public let attention: WarrenRemoteAgentAttention?

    public init(activity: WarrenRemoteAgentActivity, attention: WarrenRemoteAgentAttention? = nil) {
        self.activity = activity
        self.attention = attention
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activity = WarrenRemoteAgentActivity(
            rawValue: try values.decodeIfPresent(String.self, forKey: .activity) ?? "unknown"
        )
        attention = try values.decodeIfPresent(WarrenRemoteAgentAttention.self, forKey: .attention)
    }

    private enum CodingKeys: String, CodingKey { case activity, attention }
}

public enum WarrenRemoteAgentTurnStatus: String, Codable, Sendable {
    case idle, started, completed, failed, aborted
    case unknown

    public init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "started": self = .started
        case "completed": self = .completed
        case "failed": self = .failed
        case "aborted": self = .aborted
        default: self = .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue == "unknown" ? "unknown" : rawValue)
    }
}

/// Capabilities understood by the Agent View transport. These values mirror
/// Headless's wire constants and intentionally remain plain strings so a
/// newer Host can add capabilities without making decoding fail.
public enum WarrenRemoteAgentCapability {
    public static let timeline = "agent-timeline-v1"
    public static let interactions = "agent-interactions-v1"
    public static let interrupt = "agent-interrupt-v1"
    public static let attachments = "agent-attachments-v1"
}

public struct WarrenRemoteAgentAttachmentRef: Codable, Equatable, Hashable, Sendable {
    public let attachmentID: String
    public let name: String?
    public let mime: String?
    public let size: Int64?

    public init(attachmentID: String, name: String? = nil, mime: String? = nil, size: Int64? = nil) {
        self.attachmentID = attachmentID
        self.name = name
        self.mime = mime
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case name, mime, size
    }
}

public struct WarrenRemoteAgentMessageSendRequest: Codable, Equatable, Sendable {
    public let session: String
    public let clientMessageID: String
    public let text: String
    public let attachments: [WarrenRemoteAgentAttachmentRef]

    public init(session: String, clientMessageID: String, text: String, attachments: [WarrenRemoteAgentAttachmentRef] = []) {
        self.session = session
        self.clientMessageID = clientMessageID
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case clientMessageID = "clientMessageId"
        case text, attachments
    }
}

public struct WarrenRemoteAgentInteractionResponse: Codable, Equatable, Sendable {
    public let session: String
    public let requestID: String
    public let kind: String
    public let response: [String: WarrenRemoteJSONValue]

    public init(session: String, requestID: String, kind: String, response: [String: WarrenRemoteJSONValue] = [:]) {
        self.session = session
        self.requestID = requestID
        self.kind = kind
        self.response = response
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case requestID = "requestId"
        case kind, response
    }
}

public struct WarrenRemoteAgentTurnInterruptRequest: Codable, Equatable, Sendable {
    public let session: String
    public let turn: UInt64
    public let reason: String
    public let replacement: WarrenRemoteAgentMessageSendRequest?

    public init(session: String, turn: UInt64, reason: String, replacement: WarrenRemoteAgentMessageSendRequest? = nil) {
        self.session = session
        self.turn = turn
        self.reason = reason
        self.replacement = replacement
    }
}

public struct WarrenRemoteAgentTurnInterruptResult: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let session: String
    public let turn: UInt64
    public let clientMessageID: String?
    public let status: String?

    public init(
        accepted: Bool,
        session: String,
        turn: UInt64,
        clientMessageID: String? = nil,
        status: String? = nil
    ) {
        self.accepted = accepted
        self.session = session
        self.turn = turn
        self.clientMessageID = clientMessageID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case accepted, session, turn
        case clientMessageID = "clientMessageId"
        case status
    }
}

public struct WarrenRemoteAgentMessageSendResult: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let session: String
    public let clientMessageID: String

    public init(accepted: Bool, session: String, clientMessageID: String) {
        self.accepted = accepted
        self.session = session
        self.clientMessageID = clientMessageID
    }

    private enum CodingKeys: String, CodingKey {
        case accepted, session
        case clientMessageID = "clientMessageId"
    }
}

public struct WarrenRemoteAgentInteractionResult: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let session: String
    public let requestID: String
    public let kind: String

    public init(accepted: Bool, session: String, requestID: String, kind: String) {
        self.accepted = accepted
        self.session = session
        self.requestID = requestID
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case accepted, session
        case requestID = "requestId"
        case kind
    }
}

public struct WarrenRemoteAgentAttachmentPrepareRequest: Codable, Equatable, Sendable {
    public let session: String
    public let name: String
    public let mime: String
    public let size: Int64
    public let sha256: String?

    public init(session: String, name: String, mime: String, size: Int64, sha256: String? = nil) {
        self.session = session
        self.name = name
        self.mime = mime
        self.size = size
        self.sha256 = sha256
    }
}

public struct WarrenRemoteAgentAttachmentPrepareResult: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let uploadID: String
    public let chunkSize: Int
    public let expiresAt: String

    public init(
        attachmentID: String,
        uploadID: String,
        chunkSize: Int,
        expiresAt: String
    ) {
        self.attachmentID = attachmentID
        self.uploadID = uploadID
        self.chunkSize = chunkSize
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case uploadID = "uploadId"
        case chunkSize, expiresAt
    }
}

public struct WarrenRemoteAgentAttachmentChunkRequest: Codable, Equatable, Sendable {
    public let session: String
    public let uploadID: String
    public let sequence: UInt64
    public let length: Int
    public let sha256: String?
    public let data: String

    public init(session: String, uploadID: String, sequence: UInt64, length: Int, sha256: String? = nil, data: String) {
        self.session = session
        self.uploadID = uploadID
        self.sequence = sequence
        self.length = length
        self.sha256 = sha256
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case uploadID = "uploadId"
        case sequence, length, sha256, data
    }
}

public struct WarrenRemoteAgentAttachmentCompleteRequest: Codable, Equatable, Sendable {
    public let session: String
    public let uploadID: String
    public let length: Int64
    public let sha256: String?

    public init(session: String, uploadID: String, length: Int64, sha256: String? = nil) {
        self.session = session
        self.uploadID = uploadID
        self.length = length
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case uploadID = "uploadId"
        case length, sha256
    }
}

public struct WarrenRemoteAgentAttachmentAbortRequest: Codable, Equatable, Sendable {
    public let session: String
    public let uploadID: String

    public init(session: String, uploadID: String) {
        self.session = session
        self.uploadID = uploadID
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case uploadID = "uploadId"
    }
}

public struct WarrenRemoteAgentAttachmentResult: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let attachmentID: String?
    public let uploadID: String?
    public let state: String?
    public let received: Int64?
    public let error: String?

    public init(
        accepted: Bool,
        attachmentID: String? = nil,
        uploadID: String? = nil,
        state: String? = nil,
        received: Int64? = nil,
        error: String? = nil
    ) {
        self.accepted = accepted
        self.attachmentID = attachmentID
        self.uploadID = uploadID
        self.state = state
        self.received = received
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case accepted
        case attachmentID = "attachmentId"
        case uploadID = "uploadId"
        case state, received, error
    }
}

public struct WarrenRemoteAgentTurn: Codable, Equatable, Hashable, Sendable {
    public let id: UInt64
    public let status: WarrenRemoteAgentTurnStatus

    public init(id: UInt64, status: WarrenRemoteAgentTurnStatus) {
        self.id = id
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UInt64.self, forKey: .id)
        status = WarrenRemoteAgentTurnStatus(rawValue: try values.decode(String.self, forKey: .status))
    }

    private enum CodingKeys: String, CodingKey { case id, status }
}

public struct WarrenRemoteAgentUsage: Codable, Equatable, Hashable, Sendable {
    public let inputTokens: Int64?
    public let cacheCreationInputTokens: Int64?
    public let cacheReadInputTokens: Int64?
    public let outputTokens: Int64?
    public let reasoningOutputTokens: Int64?
    public let totalTokens: Int64?

    public init(
        inputTokens: Int64? = nil,
        cacheCreationInputTokens: Int64? = nil,
        cacheReadInputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        reasoningOutputTokens: Int64? = nil,
        totalTokens: Int64? = nil
    ) {
        self.inputTokens = inputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct WarrenRemoteAgentEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let sequence: UInt64
    public let turn: UInt64?
    public let id: String
    public let provider: String
    public let type: String
    public let role: String?
    public let content: String?
    public let contentDelta: Bool
    public let model: String?
    public let stopReason: String?
    public let toolName: String?
    public let toolInput: WarrenRemoteJSONValue?
    public let toolStatus: String?
    public let callID: String?
    public let output: String?
    public let files: [String]?
    public let error: String?
    public let usage: WarrenRemoteAgentUsage?
    public let durationMs: Int64?
    public let sidechain: Bool
    public let timestamp: String?
    /// Optional structured payload used by RFC 0010 timeline events. Keeping
    /// this as a JSON value lets older clients decode and advance sequence
    /// numbers without understanding newly introduced event types.
    public let payload: [String: WarrenRemoteJSONValue]?

    public init(
        sequence: UInt64,
        turn: UInt64? = nil,
        id: String = "",
        provider: String = "",
        type: String,
        role: String? = nil,
        content: String? = nil,
        contentDelta: Bool = false,
        model: String? = nil,
        stopReason: String? = nil,
        toolName: String? = nil,
        toolInput: WarrenRemoteJSONValue? = nil,
        toolStatus: String? = nil,
        callID: String? = nil,
        output: String? = nil,
        files: [String]? = nil,
        error: String? = nil,
        usage: WarrenRemoteAgentUsage? = nil,
        durationMs: Int64? = nil,
        sidechain: Bool = false,
        timestamp: String? = nil,
        payload: [String: WarrenRemoteJSONValue]? = nil
    ) {
        self.sequence = sequence
        self.turn = turn
        self.id = id
        self.provider = provider
        self.type = type
        self.role = role
        self.content = content
        self.contentDelta = contentDelta
        self.model = model
        self.stopReason = stopReason
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolStatus = toolStatus
        self.callID = callID
        self.output = output
        self.files = files
        self.error = error
        self.usage = usage
        self.durationMs = durationMs
        self.sidechain = sidechain
        self.timestamp = timestamp
        self.payload = payload
    }

    public var stableID: String {
        id.isEmpty ? "seq-\(sequence)" : id
    }

    public var identifiableID: String { "\(sequence)-\(stableID)" }
    public var rawID: String { id }

    private enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case turn, id, provider, type, role, content
        case contentDelta, model, stopReason, toolName, toolInput, toolStatus
        case callID = "callId"
        case output, files, error, usage, durationMs, sidechain, timestamp
        case payload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        turn = try values.decodeIfPresent(UInt64.self, forKey: .turn)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        role = try values.decodeIfPresent(String.self, forKey: .role)
        content = try values.decodeIfPresent(String.self, forKey: .content)
        contentDelta = try values.decodeIfPresent(Bool.self, forKey: .contentDelta) ?? false
        model = try values.decodeIfPresent(String.self, forKey: .model)
        stopReason = try values.decodeIfPresent(String.self, forKey: .stopReason)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
        toolInput = try values.decodeIfPresent(WarrenRemoteJSONValue.self, forKey: .toolInput)
        toolStatus = try values.decodeIfPresent(String.self, forKey: .toolStatus)
        callID = try values.decodeIfPresent(String.self, forKey: .callID)
        output = try values.decodeIfPresent(String.self, forKey: .output)
        files = try values.decodeIfPresent([String].self, forKey: .files)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        usage = try values.decodeIfPresent(WarrenRemoteAgentUsage.self, forKey: .usage)
        durationMs = try values.decodeIfPresent(Int64.self, forKey: .durationMs)
        sidechain = try values.decodeIfPresent(Bool.self, forKey: .sidechain) ?? false
        timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp)
        // Payload is optional extension data. A newer Host can accidentally
        // send a scalar or otherwise malformed object; retain the event so
        // sequence recovery continues and let the View ignore the payload.
        do {
            payload = try values.decodeIfPresent([String: WarrenRemoteJSONValue].self, forKey: .payload)
        } catch {
            payload = nil
        }
    }
}

public extension WarrenRemoteAgentEvent {
    var idForSwiftUI: String { identifiableID }

    func clipped(limit: Int = 4096) -> WarrenRemoteAgentEvent {
        guard limit > 0 else { return self }
        // Conversational messages (user, assistant, system) and their Content text are
        // intentionally NEVER clipped regardless of length.
        // Clipping is strictly confined to tool executions: tool_output (output) and tool_call (toolInput).
        let isToolOutput = (type == "tool_output" || type == "tool")
        let isToolCall = (type == "tool_call" || type == "tool_use")
        let needsOutputClip = isToolOutput && (output != nil && output!.count > limit)
        let needsInputClip = isToolCall && (toolInput != nil)
        if !needsOutputClip && !needsInputClip {
            return self
        }
        var nextOutput = output
        if needsOutputClip, let output {
            let index = output.index(output.startIndex, offsetBy: limit)
            nextOutput = String(output[..<index]) + "…"
        }
        var nextInput = toolInput
        if needsInputClip {
            nextInput = toolInput?.clipped(limit: limit)
        }
        return WarrenRemoteAgentEvent(
            sequence: sequence,
            turn: turn,
            id: id,
            provider: provider,
            type: type,
            role: role,
            content: content,
            contentDelta: contentDelta,
            model: model,
            stopReason: stopReason,
            toolName: toolName,
            toolInput: nextInput,
            toolStatus: toolStatus,
            callID: callID,
            output: nextOutput,
            files: files,
            error: error,
            usage: usage,
            durationMs: durationMs,
            sidechain: sidechain,
            timestamp: timestamp,
            payload: payload
        )
    }
}

public struct WarrenRemoteAgentHistoryPage: Codable, Equatable, Sendable {
    public let epoch: UInt64?
    public let events: [WarrenRemoteAgentEvent]
    public let cursor: UInt64?
    public let hasMore: Bool

    public init(epoch: UInt64? = nil, events: [WarrenRemoteAgentEvent] = [], cursor: UInt64? = nil, hasMore: Bool = false) {
        self.epoch = epoch
        self.events = events
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public struct WarrenRemoteAgentSnapshotResult: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let turn: WarrenRemoteAgentTurn
    public let sequence: UInt64

    public init(epoch: UInt64, turn: WarrenRemoteAgentTurn, sequence: UInt64) {
        self.epoch = epoch
        self.turn = turn
        self.sequence = sequence
    }
}

public struct WarrenRemoteAgentSubscriptionResult: Codable, Equatable, Sendable {
    public let session: WarrenRemoteSession
    public let snapshot: WarrenRemoteAgentSnapshotResult
    public let gapEvents: [WarrenRemoteAgentEvent]?

    public init(
        session: WarrenRemoteSession,
        snapshot: WarrenRemoteAgentSnapshotResult,
        gapEvents: [WarrenRemoteAgentEvent]? = nil
    ) {
        self.session = session
        self.snapshot = snapshot
        self.gapEvents = gapEvents
    }
}

public struct WarrenRemoteOutputFrame: Hashable, Sendable {
    public let sessionID: String
    public let epoch: UInt64
    public let sequence: UInt64
    public let payload: Data

    public init(sessionID: String, epoch: UInt64, sequence: UInt64, payload: Data) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.sequence = sequence
        self.payload = payload
    }
}

public struct WarrenRemoteAtomicState: Hashable, Sendable {
    public let sessionID: String
    public let epoch: UInt64
    public let sequence: UInt64
    public let format: String
    public let payload: Data

    public init(sessionID: String, epoch: UInt64, sequence: UInt64, format: String, payload: Data) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.sequence = sequence
        self.format = format
        self.payload = payload
    }
}

public struct WarrenRemoteOutputAnchor: Hashable, Sendable {
    public let sessionID: String
    public let epoch: UInt64
    public let sequence: UInt64
    public let reanchor: Bool
    public let synced: Bool

    public init(sessionID: String, epoch: UInt64, sequence: UInt64, reanchor: Bool, synced: Bool) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.sequence = sequence
        self.reanchor = reanchor
        self.synced = synced
    }
}

public struct WarrenRemoteFocusResult: Codable, Equatable, Sendable {
    public let focused: Bool
    public let resized: Bool

    public init(focused: Bool, resized: Bool = false) {
        self.focused = focused
        self.resized = resized
    }
}

public struct WarrenRemoteSubscriptionResult: Codable, Equatable, Sendable {
    public let subscribed: Bool

    public init(subscribed: Bool) {
        self.subscribed = subscribed
    }
}

/// Live protocol events emitted by `WarrenRemoteClient`.
public enum WarrenRemoteEvent: Sendable {
    case connection(WarrenRemoteConnectionState)
    case welcome(version: String)
    case roster(WarrenRemoteRoster)
    case rosterDelta(WarrenRemoteRoster.Delta)
    case output(WarrenRemoteOutputFrame)
    case atomicState(WarrenRemoteAtomicState)
    case anchor(WarrenRemoteOutputAnchor)
    case agent(sessionID: String, epoch: UInt64, events: [WarrenRemoteAgentEvent])
    case agentStatus(sessionID: String, epoch: UInt64, status: WarrenRemoteAgentStatus)
    case agentTurn(sessionID: String, epoch: UInt64, turn: WarrenRemoteAgentTurn)
    case maintenance(message: String?)
    case disconnected(reason: String)
}

public enum WarrenRemoteConnectionState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case stopped
}
