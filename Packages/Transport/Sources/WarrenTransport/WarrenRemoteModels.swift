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

    public init(
        name: String,
        url: String,
        token: String = "",
        ssh: String? = nil,
        sshRemote: String? = nil,
        type: String = "daemon",
        hostID: String? = nil,
        routeID: String? = nil
    ) {
        self.name = name
        self.url = url
        self.token = token
        self.ssh = ssh
        self.sshRemote = sshRemote
        self.type = type
        self.hostID = hostID
        self.routeID = routeID
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
            routeID: try values.decodeIfPresent(String.self, forKey: .routeID)
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
    public let expiresIn: Int?

    public init(hostID: String, accessToken: String, expiresIn: Int? = nil) {
        self.hostID = hostID
        self.accessToken = accessToken
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

public struct WarrenRelayPairing: Codable, Equatable, Hashable, Sendable {
    public let relayURL: String
    public let hostID: String
    public let pairingTicket: String

    public init(relayURL: String, hostID: String, pairingTicket: String) {
        self.relayURL = relayURL
        self.hostID = hostID
        self.pairingTicket = pairingTicket
    }

    /// Converts the pairing into an endpoint after a successful ticket
    /// exchange. The endpoint name is deliberately local-only metadata.
    public func endpoint(
        accessToken: String,
        name: String? = nil,
        routeID: String? = nil
    ) -> WarrenRemoteEndpointConfiguration {
        WarrenRemoteEndpointConfiguration(
            name: name ?? "Relay \(hostID.prefix(8))",
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

        // Relay links are host-scoped: /<optional-prefix>/h/<host-id>/.
        // Parse the suffix as exactly one path segment so a malformed link
        // such as /h/id/extra cannot silently connect to the wrong Host.
        let path = components.path
        guard let markerRange = path.range(of: "/h/") else {
            throw WarrenRelayPairingError.missingHostID
        }
        let suffix = path[markerRange.upperBound...]
        let suffixParts = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard suffixParts.count == 1 else { throw WarrenRelayPairingError.missingHostID }
        let hostID = String(suffixParts[0])
        guard !hostID.isEmpty,
              !hostID.contains("\\"),
              !hostID.contains("?")
        else { throw WarrenRelayPairingError.missingHostID }

        let ticket: String?
        if let fragment = components.fragment {
            let fragmentItems = URLComponents(string: "https://pairing.invalid/?\(fragment)")?.queryItems
            ticket = fragmentItems?.first(where: { $0.name == "t" || $0.name == "pairing_ticket" })?.value
                ?? (fragment.hasPrefix("t=") ? String(fragment.dropFirst(2)) : nil)
        } else {
            ticket = components.queryItems?.first(where: { $0.name == "t" || $0.name == "pairing_ticket" })?.value
        }
        guard let ticket, !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WarrenRelayPairingError.missingPairingTicket
        }

        var relay = components
        relay.scheme = scheme == "ws" ? "http" : (scheme == "wss" ? "https" : scheme)
        let prefix = String(path[..<markerRange.lowerBound])
        relay.path = prefix.isEmpty ? "" : prefix
        relay.query = nil
        relay.fragment = nil
        guard let relayURL = relay.url, relayURL.host != nil else {
            throw WarrenRelayPairingError.invalidURL
        }
        return WarrenRelayPairing(relayURL: relayURL.absoluteString, hostID: hostID, pairingTicket: ticket)
    }

    public static func exchange(
        _ pairing: WarrenRelayPairing,
        urlSession: URLSession = WarrenRemoteNetworking.session
    ) async throws -> WarrenRelaySessionExchange {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Relay",
            url: pairing.relayURL,
            type: "relay",
            hostID: pairing.hostID
        )
        guard let url = endpoint.relaySessionExchangeURL else {
            throw WarrenRelayPairingError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pairing_ticket": pairing.pairingTicket,
        ])
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
        guard value.hostID == pairing.hostID else {
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
            case "codex", "claude", "opencode":
                return true
            default:
                return false
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case workspaceID = "workspace"
            case terminalGroupID = "terminalGroup"
            case scope, title, customTitle, kind, command, process, directory, runtime, runtimeKind
            case lifecycle, epoch, sequence, pinned
            case agentSessionID = "agentSessionId"
            case transcriptPath, agentStatus, agentTurn, createdAt, endedAt
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
        timestamp: String? = nil
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
    }
}

public extension WarrenRemoteAgentEvent {
    var idForSwiftUI: String { identifiableID }
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
