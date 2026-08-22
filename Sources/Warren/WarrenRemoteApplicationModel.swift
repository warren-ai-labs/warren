import Foundation
import AppKit
import GhosttyAdapter
import Observation
import WarrenClientCore
import WarrenDesktop
import WarrenDomain
import WarrenStateStore
import WarrenTransport

extension WarrenRemoteEndpointConfiguration {
    static func localDaemon() -> Self {
        let environment = ProcessInfo.processInfo.environment
        let tokenURL: URL
        if let configured = environment["WARREN_TOKEN_FILE"], !configured.isEmpty {
            tokenURL = URL(fileURLWithPath: configured)
        } else {
            tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".warren/token")
        }
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(name: "Local", url: "http://127.0.0.1:8789", token: token, ssh: nil)
    }
}

struct WarrenRemoteEndpointConfiguration: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let url: String
    let token: String
    let ssh: String?

    var id: String { name }
}

private struct WarrenEndpointConfigurationFile: Decodable {
    let current: String?
    let endpoints: [String: WarrenRemoteEndpointConfiguration]
}

enum WarrenEndpointCatalog {
    static func configurationURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["WARREN_CONFIG"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warren/config.json")
    }

    static func load() -> (current: String?, endpoints: [WarrenRemoteEndpointConfiguration]) {
        load(from: configurationURL())
    }

    static func load(
        from configURL: URL
    ) -> (current: String?, endpoints: [WarrenRemoteEndpointConfiguration]) {
        guard let data = try? Data(contentsOf: configURL),
              let file = try? JSONDecoder().decode(WarrenEndpointConfigurationFile.self, from: data) else {
            return (nil, [])
        }
        return (file.current, file.endpoints.values.sorted { $0.name < $1.name })
    }
}

struct RemoteRoster: Decodable, Sendable, Equatable {
    struct Host: Decodable, Sendable, Equatable { let id: String; let name: String }
    struct Project: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let path: String
        let autoImportGitWorktrees: Bool?
        let pinned: Bool?
    }
    struct WorktreeCandidate: Decodable, Sendable {
        let path: String
        let name: String
        let branch: String?
        let locked: Bool?
        let imported: Bool
        let workspace: String?
    }
    struct Workspace: Decodable, Sendable, Equatable {
        let id: String
        let project: String
        let name: String
        let path: String
        let branch: String?
        let managedWorktree: Bool?
        let worktreeLocked: Bool?
        let pinned: Bool?
        // Keep the wire value raw so a future Host state cannot invalidate
        // the entire roster; the projection maps known values below.
        let mergeState: String?
    }
    struct TerminalGroup: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let home: String?
        let order: Int?
        let createdAt: String?
    }
    struct Session: Decodable, Sendable, Equatable {
        let id: String
        let workspace: String?
        let terminalGroup: String?
        let scope: String?
        let title: String
        let customTitle: String?
        let kind: String
        let command: String?
        let process: String?
        let directory: String?
        let lifecycle: String
        let pinned: Bool?
        let agentStatus: AgentStatus?
    }
    struct AgentStatus: Decodable, Sendable, Equatable {
        let activity: String
        let attention: Attention?

        struct Attention: Decodable, Sendable, Equatable {
            let kind: String
            let reason: String
            let requestID: String?
            let since: String?

            private enum CodingKeys: String, CodingKey {
                case kind
                case reason
                case requestID = "requestId"
                case since
            }
        }
    }

    let host: Host
    let projects: [Project]
    let workspaces: [Workspace]
    let terminalGroups: [TerminalGroup]
    let sessions: [Session]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(Host.self, forKey: .host)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        terminalGroups = try container.decodeIfPresent([TerminalGroup].self, forKey: .terminalGroups) ?? []
        sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case projects
        case workspaces
        case terminalGroups
        case sessions
    }
}

/// Keeps the newest value while exposing at most one pending wake-up.
struct WarrenLatestValueSignal<Value: Sendable>: Sendable {
    private var latestValue: Value?
    private var signalPending = false

    mutating func offer(_ value: Value) -> Bool {
        latestValue = value
        guard !signalPending else { return false }
        signalPending = true
        return true
    }

    mutating func take() -> Value? {
        let value = latestValue
        latestValue = nil
        signalPending = false
        return value
    }

    mutating func reset() {
        latestValue = nil
        signalPending = false
    }
}

/// Keeps at most one unsent terminal viewport. A window drag can produce more
/// resize callbacks than the daemon can process; intermediate dimensions have
/// no value once a newer one exists.
struct WarrenResizeRequestBuffer: Sendable {
    private(set) var pending: TerminalSize?
    private(set) var lastSent: TerminalSize?

    /// Returns true when the caller needs to start a drain task.
    mutating func offer(_ size: TerminalSize) -> Bool {
        guard size != lastSent || pending != nil else { return false }
        let shouldStart = pending == nil
        pending = size
        return shouldStart
    }

    mutating func take() -> TerminalSize? {
        guard let pending else { return nil }
        self.pending = nil
        guard pending != lastSent else { return nil }
        return pending
    }

    mutating func markSent(_ size: TerminalSize) {
        lastSent = size
    }

    mutating func reset() {
        pending = nil
        lastSent = nil
    }
}

private enum RemoteWireEvent: Sendable {
    case roster
    case agent(sessionID: TerminalSessionID, status: AgentStatus)
    case output(Data)
    case framedOutput(sessionID: TerminalSessionID, epoch: UInt64, sequence: UInt64, payload: Data)
    case anchor(sessionID: TerminalSessionID, epoch: UInt64, sequence: UInt64, reanchor: Bool)
    case maintenance(message: String?)
    case disconnected(String)
}

private struct WarrenRemoteRequestContext {
    let method: String
    let params: [String: String]
    let startedAt: Date
}

private enum WarrenRemoteErrorInfoKey {
    static let method = "WarrenRemoteMethod"
    static let params = "WarrenRemoteParams"
    static let endpoint = "WarrenRemoteEndpoint"
    static let startedAt = "WarrenRemoteRequestStartedAt"
    static let daemonProtocol = "WarrenRemoteDaemonProtocol"
}

struct TerminalOutputAnchor: Equatable, Sendable {
    let epoch: UInt64
    let sequence: UInt64
}

enum WarrenRemoteTabOrdering {
    static func moving(
        _ tabID: String,
        before destinationTabID: String?,
        in tabIDs: [String]
    ) -> [String] {
        guard let sourceIndex = tabIDs.firstIndex(of: tabID) else { return tabIDs }
        if let destinationTabID {
            guard destinationTabID != tabID, tabIDs.contains(destinationTabID) else {
                return tabIDs
            }
        }
        var result = tabIDs
        let moved = result.remove(at: sourceIndex)
        if let destinationTabID,
           let destinationIndex = result.firstIndex(of: destinationTabID) {
            result.insert(moved, at: destinationIndex)
        } else {
            result.append(moved)
        }
        return result
    }

    static func reconciling(
        preferredOrder: [String],
        availableTabIDs: [String]
    ) -> [String] {
        let available = Set(availableTabIDs)
        var seen: Set<String> = []
        let retained = preferredOrder.filter {
            available.contains($0) && seen.insert($0).inserted
        }
        return retained + availableTabIDs.filter { seen.insert($0).inserted }
    }
}

/// Parameters shared by the desktop attach path and its protocol tests. The
/// viewport is optional for compatibility with older clients, but a valid
/// viewport is always sent when Ghostty has produced one.
enum WarrenRemoteTerminalProtocol {
    static func attachParameters(
        sessionID: TerminalSessionID,
        size: TerminalSize?,
        anchor: TerminalOutputAnchor? = nil
    ) -> [String: String] {
        // Attach subscribes to output only and must not claim focus. The
        // viewport is still sent so a daemon with no focus owner can resize
        // the shared runtime before its reanchor snapshot: without this, the
        // snapshot is captured at the session's last width and soft-wrapped
        // history replays into Ghostty at the wrong wrap points.
        var params = ["id": sessionID.description, "focused": "false"]
        if let size {
            params["cols"] = String(size.columns)
            params["rows"] = String(size.rows)
        }
        if let anchor {
            params["epoch"] = String(anchor.epoch)
            params["sequence"] = String(anchor.sequence)
        }
        return params
    }

    static func shouldAttach(
        previousTabID: String?,
        nextTabID: String?,
        mountedSurfaceCount: Int
    ) -> Bool {
        guard nextTabID != nil else { return false }
        return previousTabID != nextTabID || mountedSurfaceCount == 0
    }
}

private actor WarrenRemoteWire {
    private static let outputChunkBytes = 128 * 1024
    /// URLSession's default maximumMessageSize (1 MiB) rejects the daemon's
    /// largest legal frames (terminal output up to 8 MiB plus agent batches);
    /// raising it is required for those messages to survive the transport.
    private static let maximumWebSocketMessageBytes = 64 * 1024 * 1024
    private static let connectTimeout: Duration = .seconds(10)
    private static let requestTimeout: Duration = .seconds(15)
    private let configuration: WarrenRemoteEndpointConfiguration
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var requestContexts: [String: WarrenRemoteRequestContext] = [:]
    private var daemonProtocolVersion: String?
    private var pendingInput = Data()
    private var inputTask: Task<Void, Never>?
    // Rosters are snapshots, so intermediate states have no value once a
    // newer snapshot has arrived. Keep one wake-up in the lossless event
    // stream and let the consumer take the newest snapshot.
    private var latestRosterSignal = WarrenLatestValueSignal<RemoteRoster>()
    private let eventBuffer = WarrenLosslessAsyncBuffer<RemoteWireEvent>(capacity: 64)

    init(configuration: WarrenRemoteEndpointConfiguration) { self.configuration = configuration }

    nonisolated func events() -> AsyncStream<RemoteWireEvent> { eventBuffer.stream }

    func connect() async throws {
        guard task == nil else { return }
        guard var components = URLComponents(string: configuration.url) else {
            throw URLError(.badURL)
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/ws"
        guard let url = components.url else { throw URLError(.badURL) }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = Self.maximumWebSocketMessageBytes
        let token = configuration.token
        task = socket
        socket.resume()
        // A daemon that accepts TCP but never completes the WebSocket
        // handshake or answers auth would otherwise hang the desktop on a
        // "Connecting…" spinner forever. Bound the handshake so the
        // connection loop can tear this wire down and retry or fail visibly.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await socket.send(.string(Self.json([
                    "t": "auth",
                    "token": token,
                    "version": "1.0",
                ])))
            }
            group.addTask {
                try await Task.sleep(for: Self.connectTimeout)
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        inputTask?.cancel()
        inputTask = nil
        pendingInput.removeAll(keepingCapacity: true)
        latestRosterSignal.reset()
        eventBuffer.finish()
        for continuation in continuations.values {
            continuation.resume(throwing: URLError(.cancelled))
        }
        continuations.removeAll()
        requestContexts.removeAll()
        daemonProtocolVersion = nil
    }

    func request(_ method: String, params: [String: String] = [:]) async throws -> Data {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let id = UUID().uuidString.lowercased()
        let text = Self.json(["t": "request", "id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                requestContexts[id] = WarrenRemoteRequestContext(
                    method: method,
                    params: params,
                    startedAt: Date()
                )
                Task {
                    do { try await task.send(.string(text)) }
                    catch { self.failRequest(id, error: error) }
                }
                // A daemon can accept the WebSocket and then stall on a request
                // (for example a wedged attach). Fail the request instead of
                // leaving the terminal pane on its "Connecting…" spinner forever.
                Task {
                    try? await Task.sleep(for: Self.requestTimeout)
                    self.failRequest(id, error: URLError(.timedOut))
                }
                if Task.isCancelled {
                    self.failRequest(id, error: URLError(.cancelled))
                }
            }
        }, onCancel: {
            Task { await self.cancelRequest(id) }
        })
    }

    func sendInput(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingInput.append(data)
        guard inputTask == nil else { return }
        inputTask = Task { [weak self] in await self?.drainInput() }
    }

    func takeLatestRoster() -> RemoteRoster? {
        latestRosterSignal.take()
    }

    private func drainInput() async {
        defer { inputTask = nil }
        while !Task.isCancelled, !pendingInput.isEmpty {
            let data = pendingInput
            pendingInput.removeAll(keepingCapacity: true)
            guard let task else { return }
            do {
                try await task.send(.data(data))
            } catch {
                _ = await eventBuffer.send(.disconnected(String(describing: error)))
                return
            }
        }
    }

    private func failRequest(_ id: String, error: Error) {
        let context = requestContexts.removeValue(forKey: id)
        continuations.removeValue(forKey: id)?.resume(
            throwing: makeRequestError(error: error, context: context)
        )
    }

    private func cancelRequest(_ id: String) {
        failRequest(id, error: URLError(.cancelled))
    }

    private func makeRequestError(
        message: String,
        context: WarrenRemoteRequestContext?
    ) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        userInfo[WarrenRemoteErrorInfoKey.endpoint] = configuration.url
        userInfo[WarrenRemoteErrorInfoKey.daemonProtocol] = daemonProtocolVersion ?? "unknown"
        if let context {
            userInfo[WarrenRemoteErrorInfoKey.method] = context.method
            userInfo[WarrenRemoteErrorInfoKey.params] = context.params
            userInfo[WarrenRemoteErrorInfoKey.startedAt] = context.startedAt
        }
        return NSError(domain: "WarrenRemote", code: 1, userInfo: userInfo)
    }

    private func makeRequestError(
        error: Error,
        context: WarrenRemoteRequestContext?
    ) -> NSError {
        let wrapped = makeRequestError(message: error.localizedDescription, context: context)
        var userInfo = wrapped.userInfo
        userInfo[NSUnderlyingErrorKey] = error
        return NSError(domain: wrapped.domain, code: wrapped.code, userInfo: userInfo)
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        // Every exit path ends the event stream so the connection loop's
        // `for await` can never stay suspended after a switch or a dropped
        // socket. `finish` is idempotent; the normal disconnect path calls it
        // again through `close()`.
        defer { eventBuffer.finish() }
        do {
            while !Task.isCancelled {
                switch try await socket.receive() {
                case .data(let data):
                    guard await emitOutput(data) else { return }
                case .string(let text):
                    guard await handleText(Data(text.utf8)) else { return }
                @unknown default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            _ = await eventBuffer.send(.disconnected(String(describing: error)))
        }
    }

    private func emitOutput(_ data: Data) async -> Bool {
        let bytes = [UInt8](data)
        if let frame = try? WarrenWireCodec().decodeOutputFrame(bytes) {
            return await emitChunks(frame)
        }
        switch WarrenOutputDecoder.decode(data) {
        case .payload(let payload):
            return await emitChunks(payload)
        case .legacyRaw:
            return await emitChunks(data)
        case .undecodableEnvelope:
            // The daemon speaks the DENB envelope but this frame cannot be
            // decoded. Rendering it would print binary garbage into Ghostty;
            // drop the connection so the remote model reconnects cleanly.
            return await eventBuffer.send(.disconnected(
                "The daemon sent an undecodable terminal frame; reconnecting."
            ))
        }
    }

    private func emitChunks(_ frame: WarrenDecodedOutputFrame) async -> Bool {
        let payload = frame.payload
        var offset = 0
        while offset < payload.count {
            let end = min(offset + Self.outputChunkBytes, payload.count)
            let chunk = offset == 0 && end == payload.count
                ? payload
                : Data(payload[offset..<end])
            guard await eventBuffer.send(.framedOutput(
                sessionID: frame.header.sessionID,
                epoch: frame.header.epoch,
                sequence: frame.header.sequence + UInt64(offset),
                payload: chunk
            )) else { return false }
            offset = end
        }
        return true
    }

    private func emitChunks(_ data: Data) async -> Bool {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.outputChunkBytes, data.count)
            let chunk = offset == 0 && end == data.count
                ? data
                : Data(data[offset..<end])
            guard await eventBuffer.send(.output(chunk)) else { return false }
            offset = end
        }
        return true
    }

    private func handleText(_ data: Data) async -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else { return true }
        if type == "response" {
            if let id = object["id"] as? String,
               let continuation = continuations.removeValue(forKey: id) {
                let context = requestContexts.removeValue(forKey: id)
                if object["ok"] as? Bool == true {
                    let result = object["result"] ?? NSNull()
                    let encoded = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("null".utf8)
                    continuation.resume(returning: encoded)
                } else {
                    continuation.resume(throwing: makeRequestError(
                        message: object["error"] as? String ?? "Remote request failed",
                        context: context
                    ))
                }
            } else if object["ok"] as? Bool == false {
                // Responses without a matching request id (for example the
                // daemon rejecting a binary input frame sent before attach)
                // must not tear down a healthy connection. Ignore them the
                // same way the Web client does.
            }
        } else if type == "welcome" {
            let version = object["version"] as? String ?? "unknown"
            daemonProtocolVersion = version
            guard Self.compatibleProtocolVersion(version, with: "1.0") else {
                return await eventBuffer.send(.disconnected(
                    "Warren Desktop is incompatible with the daemon protocol "
                        + "(desktop=1.0, daemon=\(version)); update both together."
                ))
            }
        } else if type == "roster", let state = object["state"],
                  let encoded = try? JSONSerialization.data(withJSONObject: state),
                  let roster = try? JSONDecoder().decode(RemoteRoster.self, from: encoded) {
            guard latestRosterSignal.offer(roster) else { return true }
            return await eventBuffer.send(.roster)
        } else if type == "agent.status",
                  let sessionString = object["session"] as? String,
                  let sessionID = TerminalSessionID(uuidString: sessionString),
                  let rawStatus = object["status"],
                  let encodedStatus = try? JSONSerialization.data(withJSONObject: rawStatus),
                  let remoteStatus = try? JSONDecoder().decode(RemoteRoster.AgentStatus.self, from: encodedStatus),
                  let status = Self.agentStatus(from: remoteStatus) {
            return await eventBuffer.send(.agent(sessionID: sessionID, status: status))
        } else if type == "maintenance" {
            return await eventBuffer.send(.maintenance(message: object["message"] as? String))
        } else if type == "attached" || type == "synced" {
            guard let sessionIDString = object["session"] as? String,
                  let sessionID = TerminalSessionID(uuidString: sessionIDString),
                  let epoch = (object["epoch"] as? NSNumber)?.uint64Value,
                  let sequence = (object["sequence"] as? NSNumber)?.uint64Value else {
                return true
            }
            return await eventBuffer.send(.anchor(
                sessionID: sessionID,
                epoch: epoch,
                sequence: sequence,
                reanchor: type == "attached"
            ))
        } else if type == "error" {
            return await eventBuffer.send(.disconnected(
                object["error"] as? String ?? "Remote authentication failed"
            ))
        }
        return true
    }

    private nonisolated static func compatibleProtocolVersion(_ lhs: String, with rhs: String) -> Bool {
        lhs.split(separator: ".", maxSplits: 1).first == rhs.split(separator: ".", maxSplits: 1).first
    }

    private nonisolated static func json(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func agentStatus(from value: RemoteRoster.AgentStatus) -> AgentStatus? {
        guard let activity = AgentActivityState(rawValue: value.activity) else { return nil }
        let attention = value.attention.flatMap { raw -> AgentAttention? in
            guard let kind = AgentAttentionKind(rawValue: raw.kind) else { return nil }
            return AgentAttention(
                kind: kind,
                reason: raw.reason,
                requestID: raw.requestID,
                since: raw.since
            )
        }
        return AgentStatus(activity: activity, attention: attention)
    }
}

private enum WarrenRemoteDiagnostics {
    private static let sensitiveParameterNames = [
        "authorization", "cookie", "password", "secret", "token",
    ]

    static func text(
        error: Error,
        endpoint: String?,
        selectedSessionID: TerminalSessionID?,
        attachedSessionID: TerminalSessionID?,
        focusedSessionID: TerminalSessionID?,
        now: Date = Date()
    ) -> String {
        let nsError = error as NSError
        let info = nsError.userInfo
        let requestEndpoint = info[WarrenRemoteErrorInfoKey.endpoint] as? String
        let method = info[WarrenRemoteErrorInfoKey.method] as? String ?? "unknown"
        let params = info[WarrenRemoteErrorInfoKey.params] as? [String: String] ?? [:]
        let daemonProtocol = info[WarrenRemoteErrorInfoKey.daemonProtocol] as? String ?? "unknown"
        let startedAt = info[WarrenRemoteErrorInfoKey.startedAt] as? Date
        let effectiveEndpoint = requestEndpoint ?? endpoint ?? "unknown"
        let elapsed = startedAt.map { max(0, now.timeIntervalSince($0)) }

        var lines = [
            "Warren daemon diagnostic",
            "timestamp: \(iso8601(now))",
            "endpoint: \(redactedEndpoint(effectiveEndpoint))",
            "operation: \(method)",
            "parameters: \(formattedParameters(params))",
            "selectedSession: \(selectedSessionID?.description ?? "none")",
            "attachedSession: \(attachedSessionID?.description ?? "none")",
            "focusedSession: \(focusedSessionID?.description ?? "none")",
            "clientProtocol: 1.0",
            "daemonProtocol: \(daemonProtocol)",
            "appVersion: \(appVersion())",
            "os: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "errorType: \(String(reflecting: type(of: error)))",
            "errorDomain: \(nsError.domain)",
            "errorCode: \(nsError.code)",
            "message: \(nsError.localizedDescription)",
        ]
        if let startedAt {
            lines.insert("requestStarted: \(iso8601(startedAt))", at: 2)
        }
        if let elapsed {
            lines.insert(String(format: "requestElapsedMs: %.0f", elapsed * 1_000), at: 3)
        }
        if let underlying = info[NSUnderlyingErrorKey] as? NSError {
            lines.append(
                "underlying: \(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func formattedParameters(_ params: [String: String]) -> String {
        guard !params.isEmpty else { return "none" }
        return params.keys.sorted().map { key in
            let value = params[key] ?? ""
            let lowercased = key.lowercased()
            let redacted = sensitiveParameterNames.contains { lowercased.contains($0) }
                ? "<redacted>"
                : value
            return "\(key)=\(redacted)"
        }.joined(separator: ", ")
    }

    private static func redactedEndpoint(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? raw
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }
}

@MainActor
@Observable
final class WarrenRemoteApplicationModel {
    private static let deletionReconciliationTimeout: Duration = .seconds(30)
    /// A daemon restart briefly drops the WebSocket before its listener is
    /// ready again. Keep that expected gap out of the notice center;
    /// persistent failures still become visible after the grace period.
    private static let transientConnectionIssueDelay: Duration = .seconds(5)

    private(set) var projection = WarrenDesktopProjection
        .empty(host: WarrenDomain.Host(name: "Server"))
        .withConnectionState(.connecting)
    private(set) var navigation: WarrenDesktopNavigationState {
        didSet { WarrenDesktopNavigationPersistence.save(navigation) }
    }
    /// Client-local diagnostics and system messages shown by the desktop
    /// notice center. Keep this bounded so repeated failures cannot grow the
    /// model without limit.
    private(set) var notices: [WarrenDesktopNotice] = []
    private(set) var webStatus = WarrenDesktopWebStatus()
    /// Default engine for new sessions, owned by the headless daemon.
    private(set) var defaultRuntime: String?
    /// Whether opening an empty workspace creates a default Shell session.
    private(set) var autoOpenShell = false
    /// Whether entering an empty workspace starts the first AI preset.
    private(set) var autoStartAI = false
    @ObservationIgnored private var settingsLoaded = false
    /// Set while the daemon has announced an operator-initiated maintenance
    /// window (for example an app install that restarts the daemon). Clients
    /// show an update state instead of treating the disconnect as a failure.
    private(set) var maintenanceMessage: String?
    private(set) var creatingSessionWorkspaceIDs: Set<WorkspaceID> = []
    private(set) var creatingSessionTerminalGroupIDs: Set<TerminalGroupID> = []
    private(set) var deletingProjectIDs: Set<ProjectID> = []
    private(set) var deletingWorkspaceIDs: Set<WorkspaceID> = []
    private(set) var attachingSessionID: TerminalSessionID?

    @ObservationIgnored private var wire: WarrenRemoteWire?
    @ObservationIgnored private var endpointConfiguration: WarrenRemoteEndpointConfiguration?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var selectedSessionID: TerminalSessionID?
    @ObservationIgnored private var attachedSessionID: TerminalSessionID?
    @ObservationIgnored private var focusedSessionID: TerminalSessionID?
    @ObservationIgnored private var pendingFocusSessionID: TerminalSessionID?
    @ObservationIgnored private var pendingFocusSize: TerminalSize?
    @ObservationIgnored private var pendingFocusResizeSize: TerminalSize?
    @ObservationIgnored private var focusClaimInFlight = false
    @ObservationIgnored private var focusClaimGeneration = 0
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var initialRefreshPending = false
    @ObservationIgnored private var currentRoster: RemoteRoster?
    @ObservationIgnored private var rosterApplicationGeneration: UInt64 = 0
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeBuffer = WarrenResizeRequestBuffer()
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var deletionReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var deletionReconciliationWire: WarrenRemoteWire?
    @ObservationIgnored private var attachGeneration: UInt64 = 0
    @ObservationIgnored private var terminalFont = TerminalFontPreference()
    @ObservationIgnored private var pendingTerminalOpenRequest: WarrenTerminalOpenRequest?
    @ObservationIgnored private var maintenanceResetTask: Task<Void, Never>?
    @ObservationIgnored private var connectionIssueTask: Task<Void, Never>?
    @ObservationIgnored private var outputAnchors: [TerminalSessionID: TerminalOutputAnchor] = [:]
    @ObservationIgnored private var agentStatusBySessionID: [TerminalSessionID: AgentStatus] = [:]
    @ObservationIgnored private var dismissedActivityBySessionID: [TerminalSessionID: AgentActivityState] = [:]
    @ObservationIgnored private var suppressFramedAnchorUpdates: Set<TerminalSessionID> = []
    @ObservationIgnored private var tabOrderByWorkspaceID: [WorkspaceID: [String]] = [:]
    @ObservationIgnored private var tabOrderByTerminalGroupID: [TerminalGroupID: [String]] = [:]
    @ObservationIgnored private var appliedLiveTabSessionIDs: Set<TerminalSessionID> = []
    @ObservationIgnored let surfaceManager: TerminalSurfaceManager
    @ObservationIgnored private(set) var projectionPublicationCount: UInt64 = 0

    init(surfaceManager: TerminalSurfaceManager = TerminalSurfaceManager()) {
        self.surfaceManager = surfaceManager
        self.navigation = WarrenDesktopNavigationPersistence.restore()
            ?? WarrenDesktopNavigationState(selection: nil, selectedTabID: nil)
        let tabOrders = WarrenDesktopNavigationPersistence.restoreTabOrders()
        self.tabOrderByWorkspaceID = tabOrders.workspace.reduce(into: [:]) { result, entry in
            guard let id = WorkspaceID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
        self.tabOrderByTerminalGroupID = tabOrders.terminalGroup.reduce(into: [:]) { result, entry in
            guard let id = TerminalGroupID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    func connect(_ configuration: WarrenRemoteEndpointConfiguration) {
        surfaceManager.onSurfaceDisposed = { [weak self] sessionID in
            guard let self else { return }
            self.outputAnchors.removeValue(forKey: sessionID)
            self.suppressFramedAnchorUpdates.remove(sessionID)
        }
        guard endpointConfiguration != configuration || eventTask == nil else {
            // The root view's `.task` can restart on window transitions such
            // as entering full screen. Tearing down and recreating an already
            // healthy connection is both wasteful and the trigger for the
            // terminal teardown deadlock, so keep the live connection instead.
            return
        }
        disconnect()
        cancelTransientConnectionIssue()
        restorePersistedTabOrders()
        endpointConfiguration = configuration
        settingsLoaded = false
        defaultRuntime = nil
        autoOpenShell = false
        autoStartAI = false
        if configuration.url.hasPrefix("http://127.0.0.1:8789"),
           !configuration.token.isEmpty,
           let localBaseURL = URL(string: "http://127.0.0.1:8789/") {
            let url = Self.authenticatedWebURL(localBaseURL, daemonToken: configuration.token)
            let lanURL: URL? = WarrenLANAddress.primaryIPv4().flatMap { ip in
                guard let baseURL = URL(string: "http://\(ip):8789/") else { return nil }
                return Self.authenticatedWebURL(baseURL, daemonToken: configuration.token)
            }
            webStatus = WarrenDesktopWebStatus(
                isRunning: true,
                localURL: url,
                lanURL: lanURL,
                canControl: true
            )
        }
        publishProjectionIfChanged(
            WarrenDesktopProjection
                .empty(host: WarrenDomain.Host(name: configuration.name))
                .withConnectionState(.connecting)
        )
        eventTask = Task { @MainActor [weak self] in
            await self?.runConnectionLoop(configuration)
        }
    }

    func disconnect() {
        guard eventTask != nil || endpointConfiguration != nil || wire != nil
            || surfaceManager.retainedSurfaceCount > 0 else {
            return
        }
        eventTask?.cancel()
        eventTask = nil
        endpointConfiguration = nil
        cancelTransientConnectionIssue()
        clearMaintenance()
        if let wire { Task { await wire.close() } }
        wire = nil
        currentRoster = nil
        appliedLiveTabSessionIDs.removeAll()
        agentStatusBySessionID.removeAll()
        tabOrderByWorkspaceID.removeAll()
        tabOrderByTerminalGroupID.removeAll()
        dismissedActivityBySessionID.removeAll()
        creatingSessionWorkspaceIDs.removeAll()
        creatingSessionTerminalGroupIDs.removeAll()
        clearDeletionState()
        resetAttachmentState()
        webStatus = WarrenDesktopWebStatus()
        publishProjectionIfChanged(projection.withConnectionState(.disconnected))
    }

    func isConnected(to configuration: WarrenRemoteEndpointConfiguration) -> Bool {
        endpointConfiguration == configuration && eventTask != nil
    }

    /// Keeps the endpoint alive across daemon restarts and transient network
    /// failures. A fresh wire is created per attempt; the old wire's event
    /// stream is finished by `close()` so it can never be reused.
    private func runConnectionLoop(_ configuration: WarrenRemoteEndpointConfiguration) async {
        var attempt = 0
        while !Task.isCancelled {
            let wire = WarrenRemoteWire(configuration: configuration)
            self.wire = wire
            let events = wire.events()
            do {
                try await wire.connect()
                // A daemon restart clears its tunnel state, so refresh the
                // projection on every (re)connect to keep the top-bar tunnel
                // indicator truthful. Do not hold the initial roster behind
                // this optional five-second request.
                let tunnelStatusTask = Task { @MainActor [weak self] in
                    await self?.refreshTunnelStatus()
                }
                defer { tunnelStatusTask.cancel() }
                for await event in events {
                    guard !Task.isCancelled else { return }
                    if case .roster = event {
                        attempt = 0
                    }
                    if case .disconnected = event {
                        break
                    }
                    await consume(event)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if attempt == 0, maintenanceMessage == nil {
                    present(error)
                }
            }
            // Invalidate request tasks before closing the old wire. Otherwise
            // a late cancellation can report an error against a new
            // connection, and a deletion that cannot be observed anymore can
            // leave its local spinner pending forever.
            let wasCurrentWire = self.wire === wire
            if wasCurrentWire {
                self.wire = nil
                stopDeletionReconciliation()
            }
            await wire.close()
            guard !Task.isCancelled else { return }
            resetAttachmentState()
            publishProjectionIfChanged(projection.withConnectionState(.reconnecting))
            let delay = Self.reconnectDelay(attempt: attempt)
            attempt += 1
            try? await Task.sleep(for: .milliseconds(delay))
        }
    }

    /// Drops client-side attachment state so the next roster re-attaches the
    /// selected tab on a fresh transport. The projection and navigation are
    /// intentionally kept: the old tab remains visible while reconnecting.
    private func resetAttachmentState() {
        attachingSessionID = nil
        selectedSessionID = nil
        attachedSessionID = nil
        focusedSessionID = nil
        pendingFocusSessionID = nil
        pendingFocusSize = nil
        pendingFocusResizeSize = nil
        focusClaimInFlight = false
        focusClaimGeneration += 1
        pendingInput.removeAll(keepingCapacity: true)
        initialRefreshPending = false
        attachGeneration &+= 1
        outputAnchors.removeAll()
        suppressFramedAnchorUpdates.removeAll()
        cancelResizeRequests()
        focusTask?.cancel()
        focusTask = nil
        shutdownAllMountedSurfaces()
    }

    private func shutdownAllMountedSurfaces() {
        surfaceManager.shutdown()
        appliedLiveTabSessionIDs.removeAll()
        outputAnchors.removeAll()
        suppressFramedAnchorUpdates.removeAll()
    }

    private func removeMountedSurface(sessionID: TerminalSessionID) {
        surfaceManager.remove(sessionID)
        outputAnchors.removeValue(forKey: sessionID)
        suppressFramedAnchorUpdates.remove(sessionID)
    }

    private func clearMaintenance() {
        maintenanceResetTask?.cancel()
        maintenanceResetTask = nil
        maintenanceMessage = nil
    }

    /// Exponential backoff matching the Web client: 500ms doubling to 30s.
    nonisolated static func reconnectDelay(attempt: Int) -> Int {
        let bounded = min(max(attempt, 0), 6)
        return min(30_000, 500 * (1 << bounded))
    }

    func createWorkspace(projectID: ProjectID, request creation: WorkspaceCreationRequest) {
        request("workspace.create", params: [
            "project": projectID.description,
            "branch": creation.branch,
            "name": creation.displayName,
            "path": creation.path,
        ])
    }

    /// Loads the headless daemon's settings. Runtime selection is a
    /// headless-side decision; the Desktop only reflects and changes it.
    func loadSettings() {
        guard !settingsLoaded, let wire else { return }
        settingsLoaded = true
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request("settings.get")
                guard let self,
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let kind = result["defaultRuntime"] as? String {
                    self.defaultRuntime = kind
                }
                if let enabled = result["autoOpenShell"] as? Bool {
                    self.autoOpenShell = enabled
                }
                if let enabled = result["autoStartAI"] as? Bool {
                    self.autoStartAI = enabled
                }
            } catch {
                // Settings are not critical; the picker keeps its default.
            }
        }
    }

    func setDefaultRuntime(_ kind: String) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("settings.put", params: ["defaultRuntime": kind])
                self?.defaultRuntime = kind
            } catch {
                self?.present(error)
            }
        }
    }

    func setAutoOpenShell(_ enabled: Bool) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("settings.put", params: ["autoOpenShell": enabled ? "true" : "false"])
                self?.autoOpenShell = enabled
            } catch {
                self?.present(error)
            }
        }
    }

    func setAutoStartAI(_ enabled: Bool) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("settings.put", params: ["autoStartAI": enabled ? "true" : "false"])
                self?.autoStartAI = enabled
            } catch {
                self?.present(error)
            }
        }
    }

    func setProjectAutoImportGitWorktrees(_ projectID: ProjectID, enabled: Bool) {
        request("project.autoImportGitWorktrees", params: [
            "project": projectID.description,
            "enabled": enabled ? "true" : "false",
        ])
    }

    func listProjectWorktrees(_ projectID: ProjectID) async throws -> [WarrenDesktopWorktreeCandidate] {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        let data = try await wire.request("project.worktrees", params: ["project": projectID.description])
        let values = try JSONDecoder().decode([RemoteRoster.WorktreeCandidate].self, from: data)
        return values.compactMap { value in
            guard let workspaceID = value.workspace.flatMap(WorkspaceID.init(uuidString:)) else {
                return WarrenDesktopWorktreeCandidate(
                    path: value.path,
                    name: value.name,
                    branch: value.branch,
                    locked: value.locked ?? false,
                    imported: value.imported,
                    workspaceID: nil
                )
            }
            return WarrenDesktopWorktreeCandidate(
                path: value.path,
                name: value.name,
                branch: value.branch,
                locked: value.locked ?? false,
                imported: value.imported,
                workspaceID: workspaceID
            )
        }
    }

    func importProjectWorktrees(_ projectID: ProjectID, paths: [String]) async throws {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: paths, options: [])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "WarrenRemote", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Unable to encode worktree selection.",
            ])
        }
        _ = try await wire.request("project.worktrees.import", params: [
            "project": projectID.description,
            "paths": encoded,
        ])
        try await refreshRoster(using: wire)
    }

    func createSession(workspaceID: WorkspaceID, request launch: TerminalSessionLaunchRequest) {
        guard let wire,
              let workspace = projection.workspace(id: workspaceID),
              !creatingSessionWorkspaceIDs.contains(workspaceID),
              !deletingWorkspaceIDs.contains(workspaceID),
              !deletingProjectIDs.contains(workspace.projectID) else { return }
        creatingSessionWorkspaceIDs.insert(workspaceID)
        Task { @MainActor [weak self] in
            defer { self?.finishCreatingSession(in: workspaceID) }
            do {
                let data = try await wire.request("session.create", params: [
                    "workspace": workspaceID.description,
                    "command": launch.command ?? "",
                    "kind": launch.kind.rawValue,
                    "title": launch.title ?? "",
                ])
                let created = try JSONDecoder().decode(RemoteRoster.Session.self, from: data)
                guard let sessionID = TerminalSessionID(uuidString: created.id) else {
                    throw NSError(domain: "WarrenRemote", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: "The daemon returned an invalid Session ID.",
                    ])
                }

                // The create response is authoritative, but the projection is
                // roster-backed. Refresh it before selecting the new tab so the
                // terminal surface can be mounted against a real tab instead of
                // waiting for an arbitrary roster tick.
                try await self?.refreshRoster(using: wire)
                guard let self,
                      self.selectedWorkspaceID == workspaceID else { return }
                // Creating and attaching are separate waits. End the create
                // indication before the terminal attach indication begins so
                // one user action never displays two spinners at once.
                self.finishCreatingSession(in: workspaceID)
                self.publishNavigationIfChanged(
                    WarrenDesktopNavigationReducer.reduce(
                        self.navigation,
                        action: .selectTab(Self.tabID(sessionID)),
                        in: self.projection
                    )
                )
                await self.attachSelectedSession()
            } catch {
                self?.present(error)
            }
        }
    }

    func createSession(terminalGroupID: TerminalGroupID, request launch: TerminalSessionLaunchRequest) {
        guard let wire, !creatingSessionTerminalGroupIDs.contains(terminalGroupID) else { return }
        creatingSessionTerminalGroupIDs.insert(terminalGroupID)
        Task { @MainActor [weak self] in
            defer { self?.finishCreatingSession(in: terminalGroupID) }
            do {
                let data = try await wire.request("session.create", params: [
                    "group": terminalGroupID.description,
                    "command": launch.command ?? "",
                    "kind": launch.kind.rawValue,
                    "title": launch.title ?? "",
                ])
                let created = try JSONDecoder().decode(RemoteRoster.Session.self, from: data)
                guard let sessionID = TerminalSessionID(uuidString: created.id) else {
                    throw NSError(domain: "WarrenRemote", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: "The daemon returned an invalid Session ID.",
                    ])
                }
                try await self?.refreshRoster(using: wire)
                guard let self,
                      self.selectedTerminalGroupID == terminalGroupID else { return }
                self.finishCreatingSession(in: terminalGroupID)
                self.publishNavigationIfChanged(
                    WarrenDesktopNavigationReducer.reduce(
                        self.navigation,
                        action: .selectTab(Self.tabID(sessionID)),
                        in: self.projection
                    )
                )
                await self.attachSelectedSession()
            } catch {
                self?.present(error)
            }
        }
    }

    /// Resolves a launcher link and opens its requested resource. The request
    /// is retained until the local/remote roster is ready so a Raycast
    /// invocation can arrive during Warren's first connection attempt.
    func openTerminal(_ request: WarrenTerminalOpenRequest) {
        pendingTerminalOpenRequest = request
        fulfillPendingTerminalOpenRequest()
    }

    private func fulfillPendingTerminalOpenRequest() {
        guard let request = pendingTerminalOpenRequest,
              wire != nil else { return }

        if request.hasResourceTarget {
            fulfillResourceOpenRequest(request)
            return
        }

        let group: WarrenDomain.TerminalGroup?
        if let requestedGroup = request.group {
            group = resolveSelector(
                requestedGroup,
                in: projection.terminalGroups,
                name: { $0.name },
                id: { $0.id.description }
            )
        } else {
            group = projection.terminalGroups.first
        }
        guard let group else {
            pendingTerminalOpenRequest = nil
            present(NSError(domain: "WarrenRemote", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "The requested Warren terminal group does not exist.",
            ]))
            return
        }

        pendingTerminalOpenRequest = nil
        publishNavigationIfChanged(
            WarrenDesktopNavigationReducer.reduce(
                navigation,
                action: .selectTerminalGroup(group.id),
                in: projection
            )
        )
        createSession(terminalGroupID: group.id, request: .shell)
    }

    private func fulfillResourceOpenRequest(_ request: WarrenTerminalOpenRequest) {
        let project: Project?
        if let selector = request.project {
            guard let resolved = resolveSelector(
                selector,
                in: projection.groups.map(\.project),
                name: { $0.name },
                id: { $0.id.description }
            ) else {
                failResourceOpenRequest(resource: "project", selector: selector)
                return
            }
            project = resolved
        } else {
            project = nil
        }

        let explicitlySelectedWorkspace: Workspace?
        if let selector = request.workspace {
            let candidates = projection.groups
                .filter { project == nil || $0.project.id == project?.id }
                .flatMap(\.workspaces)
            guard let resolved = resolveSelector(
                selector,
                in: candidates,
                name: { $0.name },
                id: { $0.id.description }
            ) else {
                failResourceOpenRequest(resource: "workspace", selector: selector)
                return
            }
            explicitlySelectedWorkspace = resolved
        } else {
            explicitlySelectedWorkspace = nil
        }

        if let project, let workspace = explicitlySelectedWorkspace, workspace.projectID != project.id {
            failResourceOpenRequest(resource: "workspace", selector: request.workspace ?? workspace.name)
            return
        }

        if let selector = request.session {
            let candidates = projection.sessions.filter { session in
                if let workspace = explicitlySelectedWorkspace {
                    return session.workspaceID == workspace.id && session.tabID != nil
                }
                if let project {
                    return session.workspaceID.flatMap(projection.workspace(id:))?.projectID == project.id
                        && session.tabID != nil
                }
                return session.tabID != nil
            }
            guard let session = resolveSelector(
                selector,
                in: candidates,
                name: { $0.displayTitle },
                id: { $0.id.description }
            ) else {
                failResourceOpenRequest(resource: "session", selector: selector)
                return
            }
            pendingTerminalOpenRequest = nil
            publishNavigationIfChanged(
                WarrenDesktopNavigationReducer.reduce(
                    navigation,
                    action: .openSession(session.id),
                    in: projection
                )
            )
            Task { await attachSelectedSession() }
            return
        }

        let workspace = explicitlySelectedWorkspace
            ?? project.flatMap { projection.firstWorkspace(in: $0.id) }
        guard let workspace else {
            // A project can exist without a workspace. Selecting it is still
            // useful, but there is no terminal to create until one is added.
            if let project {
                pendingTerminalOpenRequest = nil
                publishNavigationIfChanged(
                    WarrenDesktopNavigationReducer.reduce(
                        navigation,
                        action: .selectProject(project.id),
                        in: projection
                    )
                )
                return
            }
            failResourceOpenRequest(resource: "workspace", selector: request.workspace ?? "")
            return
        }

        pendingTerminalOpenRequest = nil
        publishNavigationIfChanged(
            WarrenDesktopNavigationReducer.reduce(
                navigation,
                action: .selectWorkspace(workspace.id),
                in: projection
            )
        )
        if projection.tabs(in: workspace.id).isEmpty {
            createSession(workspaceID: workspace.id, request: .shell)
        } else {
            Task { await attachSelectedSession() }
        }
    }

    private func failResourceOpenRequest(resource: String, selector: String) {
        pendingTerminalOpenRequest = nil
        let target = selector.isEmpty ? resource : "\(resource) ‘\(selector)’"
        present(NSError(domain: "WarrenRemote", code: 31, userInfo: [
            NSLocalizedDescriptionKey: "The Warren link target \(target) does not exist or is ambiguous.",
        ]))
    }

    private func resolveSelector<Value>(
        _ selector: String,
        in values: [Value],
        name: (Value) -> String,
        id: (Value) -> String
    ) -> Value? {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = values.filter { value in
            id(value).caseInsensitiveCompare(normalized) == .orderedSame
                || name(value).caseInsensitiveCompare(normalized) == .orderedSame
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func finishCreatingSession(in workspaceID: WorkspaceID) {
        guard creatingSessionWorkspaceIDs.contains(workspaceID) else { return }
        creatingSessionWorkspaceIDs.remove(workspaceID)
    }

    private func finishCreatingSession(in terminalGroupID: TerminalGroupID) {
        guard creatingSessionTerminalGroupIDs.contains(terminalGroupID) else { return }
        creatingSessionTerminalGroupIDs.remove(terminalGroupID)
    }

    func addProject(_ folder: URL) async {
        guard let wire else { return }
        do {
            _ = try await wire.request("project.add", params: [
                "path": folder.path,
                "name": folder.lastPathComponent,
            ])
            try await refreshRoster(using: wire)
        } catch {
            present(error)
        }
    }

    func updateTerminalFont(_ preference: TerminalFontPreference) {
        guard preference != terminalFont else { return }
        terminalFont = preference
        surfaceManager.apply(font: preference)
    }
    func startWebFromUI() {
        controlPublicAccess(.enable)
    }
    func stopWeb() {
        controlPublicAccess(.disable)
    }

    func enablePublicAccess(
        edgeURL: String,
        accountName: String,
        inviteKey: String,
        approvalKey: String
    ) {
        webStatus.publicAccessBusy = true
        webStatus.publicAccessError = nil
        Task {
            defer { webStatus.publicAccessBusy = false }
            do {
                try await publicAccessRequest(
                    .enable,
                    edgeURL: edgeURL,
                    accountName: accountName,
                    inviteKey: inviteKey,
                    approvalKey: approvalKey
                )
            } catch {
                webStatus.publicAccessError = error.localizedDescription
                if inviteKey.isEmpty, approvalKey.isEmpty, isMissingPublicAccessEndpoint(error) {
                    do {
                        try await tunnelRequest(.start, kind: "gnar")
                        webStatus.publicAccessError = nil
                        return
                    } catch {
                        webStatus.publicAccessError = error.localizedDescription
                        present(error)
                        return
                    }
                }
                present(error)
            }
        }
    }

    /// Persists the non-secret Public Access configuration and verifies the
    /// gnar Edge. Bootstrap keys are forwarded only through the headless API;
    /// Settings clears them after a successful response and keeps only a mask.
    func testPublicAccess(
        edgeURL: String,
        accountName: String,
        inviteKey: String,
        approvalKey: String
    ) {
        webStatus.publicAccessBusy = true
        webStatus.publicAccessError = nil
        webStatus.publicAccessAuthenticated = false
        Task {
            defer { webStatus.publicAccessBusy = false }
            do {
                try await publicAccessRequest(
                    .test,
                    edgeURL: edgeURL,
                    accountName: accountName,
                    inviteKey: inviteKey,
                    approvalKey: approvalKey
                )
            } catch {
                // Older headless builds do not know the first-class test
                // route. A token-only check can still use the compatibility
                // tunnel lifecycle; bootstrap keys cannot be forwarded to an
                // old daemon because it has no enrollment contract.
                if isMissingPublicAccessEndpoint(error) {
                    if !inviteKey.isEmpty || !approvalKey.isEmpty {
                        let unsupported = NSError(domain: "WarrenRemote", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "This Warren daemon does not support Public Access enrollment. Upgrade the daemon or sign in to gnar first, then retry without a key.",
                        ])
                        webStatus.publicAccessError = unsupported.localizedDescription
                        present(unsupported)
                        return
                    }
                    do {
                        try await tunnelRequest(.start, kind: "gnar")
                        try await tunnelRequest(.stop, kind: "gnar")
                        webStatus.publicAccessAuthenticated = true
                        webStatus.publicAccessError = nil
                        return
                    } catch {
                        webStatus.publicAccessError = error.localizedDescription
                        present(error)
                        return
                    }
                }
                webStatus.publicAccessError = error.localizedDescription
                present(error)
            }
        }
    }

    private enum PublicAccessAction: String {
        case enable
        case test
        case disable
        case restart
    }

    private func controlPublicAccess(_ action: PublicAccessAction) {
        webStatus.publicAccessBusy = true
        webStatus.publicAccessError = nil
        Task {
            defer { webStatus.publicAccessBusy = false }
            do {
                try await publicAccessRequest(action)
            } catch {
                webStatus.publicAccessError = error.localizedDescription
                if isMissingPublicAccessEndpoint(error) {
                    do {
                        try await tunnelRequest(action == .disable ? .stop : .start, kind: "gnar")
                        webStatus.publicAccessError = nil
                        return
                    } catch {
                        webStatus.publicAccessError = error.localizedDescription
                        present(error)
                        return
                    }
                }
                present(error)
            }
        }
    }
    func openWebURL(_ url: URL) {
        let browserURL = Self.publicAccessBrowserURL(
            url,
            currentEndpoint: webStatus.secureURL,
            daemonToken: endpointConfiguration?.token ?? ""
        )
        NSWorkspace.shared.open(browserURL)
    }
    func copyWebURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.canonicalWebURL(url).absoluteString, forType: .string)
    }
    func copyLocalWebURL() {
        if let url = webStatus.localURL { copyWebURL(url) }
    }
    func startCloudflareWebAccess() {
        controlTunnel(.start, kind: "cloudflared")
    }
    func stopCloudflareWebAccess() {
        controlTunnel(.stop, kind: "cloudflared")
    }
    func startTailscaleWebAccess() {
        controlTunnel(.start, kind: "tailscale")
    }
    func stopTailscaleWebAccess() {
        controlTunnel(.stop, kind: "tailscale")
    }
    func copySecureWebURL() {
        Task {
            await refreshTunnelStatus()
            guard let url = webStatus.secureURL else {
                present(NSError(domain: "WarrenRemote", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Public Access is not ready. Configure the Edge URL and one Invite Key or Approval Key in Settings → Public Access, then use Save & Test.",
                ]))
                return
            }
            NSPasteboard.general.clearContents()
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            NSPasteboard.general.setString(
                (components?.url ?? url).absoluteString,
                forType: .string
            )
        }
    }

    /// Returns the URL used only for an explicit browser-open action. Public
    /// Access responses and clipboard paths stay canonical and credential-free;
    /// the existing Warren fragment is added at the last possible moment so
    /// the protected WebSocket can authenticate. This compatibility mechanism
    /// remains a residual risk for browser history and is never persisted or
    /// sent through analytics.
    static func publicAccessBrowserURL(
        _ url: URL,
        currentEndpoint: URL?,
        daemonToken: String
    ) -> URL {
        guard !daemonToken.isEmpty,
              let currentEndpoint,
              canonicalWebURL(url) == canonicalWebURL(currentEndpoint) else {
            return url
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return authenticatedWebURL(components.url ?? url, daemonToken: daemonToken)
    }

    /// Adds the legacy Warren Web authentication fragment only to a URL being
    /// opened in a browser. The value is encoded as an RFC3986 fragment field
    /// so base64 tokens containing `+`, `/`, or `=` survive URLSearchParams.
    static func authenticatedWebURL(_ url: URL, daemonToken: String) -> URL {
        guard !daemonToken.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.percentEncodedFragment = "t=\(percentEncodeFragmentValue(daemonToken))"
        return components.url ?? url
    }

    private static func percentEncodeFragmentValue(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func normalizeAuthenticatedWebURL(_ url: URL) -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              fragment.hasPrefix("t=") else {
            return url
        }
        let token = String(fragment.dropFirst(2))
        var canonical = components
        canonical.fragment = nil
        return authenticatedWebURL(canonical.url ?? url, daemonToken: token)
    }

    private static func canonicalWebURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    private enum TunnelAction: String {
        case start
        case stop
    }

    private func controlTunnel(_ action: TunnelAction, kind: String) {
        Task {
            do {
                try await tunnelRequest(action, kind: kind)
            } catch {
                present(error)
            }
        }
    }

    private func tunnelRequest(_ action: TunnelAction, kind: String) async throws {
        guard let configuration = endpointConfiguration else {
            throw NSError(domain: "WarrenRemote", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "No daemon endpoint is selected.",
            ])
        }
        let base = configuration.url.hasSuffix("/")
            ? String(configuration.url.dropLast())
            : configuration.url
        guard let url = URL(string: base + "/v1/tunnels/" + action.rawValue) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["kind": kind])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Tunnel request failed."
            throw NSError(domain: "WarrenRemote", code: 13, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        applyTunnelStatus(from: data)
    }

    private func refreshTunnelStatus() async {
        guard let configuration = endpointConfiguration else { return }
        let publicAccessAvailable = await refreshPublicAccessStatus(configuration: configuration)
        if publicAccessAvailable && webStatus.tunnelRunning {
            return
        }
        await refreshLegacyTunnelStatus(configuration: configuration)
    }

    private func refreshLegacyTunnelStatus(configuration: WarrenRemoteEndpointConfiguration) async {
        let base = configuration.url.hasSuffix("/")
            ? String(configuration.url.dropLast())
            : configuration.url
        guard let url = URL(string: base + "/v1/tunnels") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            applyTunnelStatus(from: data)
        } catch {
            return
        }
    }

    private func publicAccessRequest(
        _ action: PublicAccessAction,
        edgeURL: String = "",
        accountName: String = "",
        inviteKey: String = "",
        approvalKey: String = ""
    ) async throws {
        guard let configuration = endpointConfiguration else {
            throw NSError(domain: "WarrenRemote", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "No daemon endpoint is selected.",
            ])
        }
        let base = configuration.url.hasSuffix("/")
            ? String(configuration.url.dropLast())
            : configuration.url
        guard let url = URL(string: base + "/v1/public-access/" + action.rawValue) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if action == .enable {
            request.httpBody = try JSONEncoder().encode(PublicAccessEnableRequest(
                edgeURL: edgeURL.isEmpty ? nil : edgeURL,
                accountName: accountName.isEmpty ? nil : accountName,
                inviteKey: inviteKey,
                approvalKey: approvalKey,
                enrollmentKey: approvalKey
            ))
        } else if action == .test {
            request.httpBody = try JSONEncoder().encode(PublicAccessTestRequest(
                edgeURL: edgeURL,
                accountName: accountName,
                inviteKey: inviteKey,
                approvalKey: approvalKey
            ))
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(PublicAccessStatus.self, from: data).error)
                .flatMap { $0 }
                ?? String(data: data, encoding: .utf8)
                ?? "Public Access request failed."
            throw NSError(domain: "WarrenRemote", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        applyPublicAccessStatus(from: data)
    }

    private func isMissingPublicAccessEndpoint(_ error: Error) -> Bool {
        (error as NSError).code == 404
    }

    private func refreshPublicAccessStatus(configuration: WarrenRemoteEndpointConfiguration) async -> Bool {
        let base = configuration.url.hasSuffix("/")
            ? String(configuration.url.dropLast())
            : configuration.url
        guard let url = URL(string: base + "/v1/public-access") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            applyPublicAccessStatus(from: data)
            return true
        } catch {
            return false
        }
    }

    private struct PublicAccessEnableRequest: Encodable {
        /// The top chrome sends nil so an enable action keeps the configured
        /// Edge/account. Settings uses the test route when it needs to save
        /// an explicit empty value and return to the release default.
        let edgeURL: String?
        let accountName: String?
        let inviteKey: String
        let approvalKey: String
        /// Legacy Warren daemons called the approval key an enrollment key.
        /// Sending the alias only on the compatibility enable request keeps
        /// older headless clients usable without changing the v1.7 gnar call.
        let enrollmentKey: String

        enum CodingKeys: String, CodingKey {
            case edgeURL = "edgeUrl"
            case accountName
            case inviteKey
            case approvalKey
            case enrollmentKey
        }
    }

    private struct PublicAccessTestRequest: Encodable {
        let edgeURL: String?
        let accountName: String
        let inviteKey: String
        let approvalKey: String

        enum CodingKeys: String, CodingKey {
            case edgeURL = "edgeUrl"
            case accountName
            case inviteKey
            case approvalKey
        }
    }

    private struct PublicAccessStatus: Decodable {
        let edgeURL: String?
        let configuredEdgeURL: String?
        let defaultEdgeURL: String?
        let usingDefaultEdge: Bool?
        let accountName: String?
        let configuredAccountName: String?
        let usingDefaultAccount: Bool?
        let enabled: Bool
        let authenticated: Bool?
        let running: Bool
        let publicEndpoint: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case edgeURL = "edgeUrl"
            case configuredEdgeURL = "configuredEdgeUrl"
            case defaultEdgeURL = "defaultEdgeUrl"
            case usingDefaultEdge = "usingDefaultEdge"
            case accountName
            case configuredAccountName = "configuredAccountName"
            case usingDefaultAccount = "usingDefaultAccount"
            case enabled
            case authenticated
            case running
            case publicEndpoint
            case error
        }
    }

    private func applyPublicAccessStatus(from data: Data) {
        guard let response = try? JSONDecoder().decode(PublicAccessStatus.self, from: data) else {
            webStatus.secureURL = nil
            webStatus.tunnelRunning = false
            webStatus.configuredEdgeURL = nil
            webStatus.defaultEdgeURL = nil
            webStatus.usingDefaultEdge = false
            webStatus.configuredAccountName = nil
            webStatus.effectiveAccountName = nil
            webStatus.usingDefaultAccount = false
            webStatus.publicAccessEnabled = false
            webStatus.publicAccessAuthenticated = false
            return
        }
        webStatus.configuredEdgeURL = response.configuredEdgeURL.flatMap(URL.init(string:))
        webStatus.defaultEdgeURL = response.defaultEdgeURL.flatMap(URL.init(string:))
        webStatus.usingDefaultEdge = response.usingDefaultEdge ?? (response.configuredEdgeURL == nil)
        webStatus.configuredAccountName = response.configuredAccountName
        webStatus.effectiveAccountName = response.accountName
        webStatus.usingDefaultAccount = response.usingDefaultAccount ?? (response.configuredAccountName == nil)
        webStatus.publicAccessEnabled = response.enabled
        webStatus.publicAccessAuthenticated = response.authenticated ?? false
        webStatus.publicAccessError = response.error.flatMap { error in
            error.isEmpty ? nil : error
        }
        guard response.running,
              let endpoint = response.publicEndpoint,
              let url = URL(string: endpoint) else {
            webStatus.secureURL = nil
            webStatus.tunnelRunning = false
            return
        }
        webStatus.secureURL = url
        webStatus.tunnelRunning = true
        webStatus.publicAccessAuthenticated = true
    }

    private func applyTunnelStatus(from data: Data) {
        struct Response: Decodable {
            let tunnels: [String: Tunnel]
        }
        struct Tunnel: Decodable {
            let running: Bool
            let webURL: String?

            enum CodingKeys: String, CodingKey {
                case running
                case webURL = "web_url"
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            webStatus.secureURL = nil
            webStatus.tunnelRunning = false
            return
        }
        let active = response.tunnels.first(where: { kind, tunnel in
            kind == "gnar" && tunnel.running && tunnel.webURL != nil
        }) ?? response.tunnels.first(where: { $0.value.running && $0.value.webURL != nil })
        guard let active,
              let rawURL = active.value.webURL,
              let url = URL(string: rawURL) else {
            webStatus.secureURL = nil
            webStatus.tunnelRunning = false
            return
        }
        webStatus.secureURL = Self.normalizeAuthenticatedWebURL(url)
        webStatus.tunnelRunning = true
        if active.key == "gnar" {
            webStatus.publicAccessAuthenticated = true
            webStatus.publicAccessError = nil
        }
    }

    func previewSupersetImport() async throws -> SupersetImportPreview {
        try await SupersetCLIImportSource().preview()
    }

    func commitSupersetImport(_ preview: SupersetImportPreview) async {
        guard let wire else { return }
        do {
            for project in preview.projects where project.status == .ready {
                let id: String
                do {
                    let data = try await wire.request("project.add", params: [
                        "path": project.repositoryPath,
                        "name": project.name,
                    ])
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let createdID = object["id"] as? String else { continue }
                    id = createdID
                } catch {
                    // The user may have added this project just before importing.
                    // The local projection can still be one roster tick behind,
                    // so ask the daemon for an authoritative snapshot instead of
                    // treating its duplicate-path response as a fatal import error.
                    try await refreshRoster(using: wire)
                    guard let existing = findProject(path: project.repositoryPath) else {
                        throw error
                    }
                    id = existing.id
                }
                // project.add may have imported every Git worktree when the
                // host setting is enabled. Refresh before issuing explicit
                // workspace.create requests so this manual import remains
                // idempotent across both settings modes.
                try await refreshRoster(using: wire)
                for workspace in project.workspaces where workspace.status == .ready {
                    if normalizedPath(workspace.path) == normalizedPath(project.repositoryPath) {
                        continue
                    }
                    if hasWorkspace(path: workspace.path, projectID: id) {
                        continue
                    }
                    _ = try await wire.request("workspace.create", params: [
                        "project": id,
                        "branch": workspace.branch ?? "main",
                        "name": workspace.name,
                        "path": workspace.path,
                    ])
                }
            }
            try await refreshRoster(using: wire)
        } catch {
            present(error)
        }
    }

    private func refreshRoster(using wire: WarrenRemoteWire) async throws {
        let generation = rosterApplicationGeneration
        let data = try await wire.request("roster")
        let roster = try JSONDecoder().decode(RemoteRoster.self, from: data)
        // A refresh may race with a stream roster or another refresh. Only
        // apply a response if this wire is still active and no newer roster
        // has already been applied while the request was in flight.
        guard self.wire === wire,
              Self.shouldApplyRoster(
                  startedAt: generation,
                  currentGeneration: rosterApplicationGeneration
              ) else { return }
        guard Self.shouldApplyRoster(roster, after: currentRoster) else {
            clearMaintenance()
            cancelTransientConnectionIssue()
            return
        }
        currentRoster = roster
        apply(roster)
    }

    private func findProject(path: String) -> (id: String, path: String)? {
        guard let project = currentRoster?.projects.first(where: {
            normalizedPath($0.path) == normalizedPath(path)
        }) else { return nil }
        return (project.id, project.path)
    }

    private func hasWorkspace(path: String, projectID: String) -> Bool {
        currentRoster?.workspaces.contains(where: {
            $0.project == projectID && normalizedPath($0.path) == normalizedPath(path)
        }) == true
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    func perform(_ action: WarrenDesktopAction) {
        TerminalDiagnostics.log("action", [
            "action": String(String(describing: action).prefix(160)),
        ])
        publishNavigationIfChanged(
            WarrenDesktopNavigationReducer.reduce(navigation, action: action, in: projection)
        )
        switch action {
        case .selectProject, .selectWorkspace, .openWorkspace, .selectTerminalGroup, .selectTab, .restoreNavigation:
            Task { await attachSelectedSession() }
        case .openSession(let id):
            selectSession(id)
        case .deleteSession(let id):
            closeSession(id)
        case .closeTab(let tabID):
            if let id = projection.tabs.first(where: { $0.id == tabID })?.sessionID {
                closeSession(id)
            }
            // Close selects the replacement tab before the daemon confirms the
            // delete. Attach it immediately so the pane does not fall back to
            // the "Connecting…" placeholder while the roster catches up.
            Task { await attachSelectedSession() }
        case .closeOtherTabs(let tabID):
            let tabs: [ClientTab]
            if let workspaceID = projection.workspaceID(forTabID: tabID) {
                tabs = projection.tabs(in: workspaceID)
            } else if let groupID = projection.terminalGroupID(forTabID: tabID) {
                tabs = projection.tabs(in: groupID)
            } else {
                return
            }
            for tab in tabs where tab.id != tabID {
                if let id = tab.sessionID { closeSession(id) }
            }
            Task { await attachSelectedSession() }
        case .closeAllTabs:
            for tab in selectedContextTabs {
                if let id = tab.sessionID { closeSession(id) }
            }
        case .launchSession(let workspaceID, let launch):
            createSession(workspaceID: workspaceID, request: launch)
        case .requestNewTerminalGroupSession(let groupID):
            createSession(terminalGroupID: groupID, request: .shell)
        case .launchTerminalGroupSession(let groupID, let launch):
            createSession(terminalGroupID: groupID, request: launch)
        case .addProject:
            present(NSError(domain: "WarrenRemote", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Remote projects must use remote paths. "
                    + "Run `warren --endpoint <server> project add /path`.",
            ]))
        case .renameProject(let id, let name):
            request("project.rename", params: ["id": id.description, "name": name])
        case .renameWorkspace(let id, let name):
            request("workspace.rename", params: ["id": id.description, "name": name])
        case .deleteProject(let id):
            deleteProject(id)
        case .deleteWorkspace(let id, let removeLocalWorktree):
            deleteWorkspace(id, removeLocalWorktree: removeLocalWorktree)
        case .renameSession(let id, let title):
            request("session.rename", params: ["id": id.description, "title": title])
        case .setProjectPinned(let id, let pinned):
            request("project.pin", params: ["id": id.description, "pinned": String(pinned)])
        case .setWorkspacePinned(let id, let pinned):
            request("workspace.pin", params: ["id": id.description, "pinned": String(pinned)])
        case .createTerminalGroup(let name, let home):
            var params = ["name": name]
            if let home { params["home"] = home }
            request("terminal-group.create", params: params)
        case .renameTerminalGroup(let id, let name):
            request("terminal-group.rename", params: ["id": id.description, "name": name])
        case .setTerminalGroupHome(let id, let home):
            request("terminal-group.home", params: [
                "id": id.description,
                "path": home ?? "",
            ])
        case .deleteTerminalGroup(let id):
            request("terminal-group.remove", params: [
                "id": id.description,
                "force": "true",
            ])
        case .setSessionPinned(let id, let pinned):
            request("session.pin", params: ["id": id.description, "pinned": String(pinned)])
        case .dismissActivity(let id, let expectedActivity):
            let candidate = projection.session(id: id)?.activity
            guard WarrenActivityDismissal.canDismiss(
                candidate: candidate,
                expected: expectedActivity
            ) else { return }
            dismissedActivityBySessionID[id] = expectedActivity
            publishProjectionIfChanged(projection.withSessionActivity(nil, for: id))
        case .moveProject(let projectID, let before):
            guard !deletingProjectIDs.contains(projectID),
                  let group = projection.groups.first(where: { $0.project.id == projectID }),
                  !group.workspaces.contains(where: { deletingWorkspaceIDs.contains($0.id) })
            else { return }
            var params = ["id": projectID.description]
            if let before { params["before"] = before.description }
            request("project.move", params: params)
        case .moveWorkspace(let workspaceID, let before):
            guard let workspace = projection.workspace(id: workspaceID),
                  let group = projection.groups.first(where: { $0.project.id == workspace.projectID }),
                  !deletingProjectIDs.contains(workspace.projectID),
                  !deletingWorkspaceIDs.contains(workspaceID),
                  !group.workspaces.contains(where: { deletingWorkspaceIDs.contains($0.id) })
            else { return }
            var params = ["id": workspaceID.description]
            if let before { params["before"] = before.description }
            request("workspace.move", params: params)
        case .moveTerminalGroup(let groupID, let before):
            var params = ["id": groupID.description]
            if let before { params["before"] = before.description }
            request("terminal-group.move", params: params)
        case .moveTab(let tabID, let before):
            moveTab(tabID, before: before)
        case .moveSession(let id, let destination):
            moveSession(id, to: destination)
        case .importSuperset, .requestNewWorkspace, .requestProjectWorktreeImport,
             .setProjectAutoImportGitWorktrees, .requestNewSession,
             .toggleSidebar:
            break
        }
    }

    func sendInput(_ data: Data) async {
        guard !data.isEmpty else { return }
        // The Ghostty surface is mounted before `session.attach` completes.
        // Keystrokes in that window must be buffered and replayed after the
        // daemon grants control; sending them early makes the daemon reject
        // the frame and the old disconnect path would reconnect in a loop.
        guard attachedSessionID == selectedSessionID, let wire else {
            pendingInput.append(data)
            return
        }
        await wire.sendInput(data)
    }

    func resize(columns: Int, rows: Int) {
        guard let sessionID = selectedSessionID,
              attachedSessionID == sessionID else { return }
        guard let size = TerminalSize(columns: columns, rows: rows) else { return }
        guard focusedSessionID == sessionID else {
            // The very first Ghostty metric can arrive while the focus claim
            // is still in flight. Remember the latest size and apply it as
            // soon as the daemon confirms ownership instead of dropping it.
            if focusClaimInFlight || pendingFocusSessionID == sessionID {
                pendingFocusResizeSize = size
            }
            return
        }
        pendingFocusResizeSize = nil
        guard resizeBuffer.offer(size) else { return }
        guard resizeTask == nil else { return }
        resizeTask = Task { @MainActor [weak self] in
            await self?.drainResizeRequests()
        }
    }

    private func drainResizeRequests() async {
        defer { resizeTask = nil }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(24))
            } catch {
                return
            }

            guard let size = resizeBuffer.take(),
                  let wire,
                  let sessionID = selectedSessionID,
                  attachedSessionID == sessionID,
                  focusedSessionID == sessionID else {
                return
            }
            resizeBuffer.markSent(size)
            TerminalDiagnostics.log("resize_request", [
                "session": sessionID.description,
                "cols": String(size.columns),
                "rows": String(size.rows),
            ])
            do {
                _ = try await wire.request("session.resize", params: [
                    "cols": String(size.columns),
                    "rows": String(size.rows),
                ])
            } catch {
                guard !Task.isCancelled,
                      selectedSessionID == sessionID,
                      attachedSessionID == sessionID,
                      focusedSessionID == sessionID else { return }
                present(error)
                return
            }
        }
    }

    private func cancelResizeRequests() {
        resizeTask?.cancel()
        resizeTask = nil
        resizeBuffer.reset()
    }

    func focus(sessionID: TerminalSessionID, size: TerminalSize?) {
        guard selectedSessionID == sessionID else { return }
        let measuredSize = size ?? surfaceManager
            .surface(for: sessionID)?
            .state.surfaceSize
            .flatMap { TerminalSize(columns: Int($0.columns), rows: Int($0.rows)) }
        guard attachedSessionID == sessionID else {
            pendingFocusSessionID = sessionID
            pendingFocusSize = measuredSize
            return
        }
        sendFocus(sessionID: sessionID, focused: true, size: measuredSize)
    }

    func blur(sessionID: TerminalSessionID) {
        if pendingFocusSessionID == sessionID {
            pendingFocusSessionID = nil
            pendingFocusSize = nil
        }
        pendingFocusResizeSize = nil
        cancelResizeRequests()
        focusClaimInFlight = false
        focusClaimGeneration += 1
        guard selectedSessionID == sessionID else { return }
        focusTask?.cancel()
        focusedSessionID = nil
        guard attachedSessionID == sessionID else { return }
        sendFocus(sessionID: sessionID, focused: false, size: nil)
    }

    private func sendFocus(sessionID: TerminalSessionID, focused: Bool, size: TerminalSize?) {
        guard let wire,
              selectedSessionID == sessionID,
              attachedSessionID == sessionID else { return }
        focusTask?.cancel()
        focusClaimGeneration += 1
        let generation = focusClaimGeneration
        focusClaimInFlight = focused
        focusTask = Task { @MainActor [weak self, generation] in
            guard let self else { return }
            do {
                var params = ["focused": focused ? "true" : "false"]
                if focused, let size {
                    params["cols"] = String(size.columns)
                    params["rows"] = String(size.rows)
                }
                let data = try await wire.request("session.focus", params: params)
                let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard self.focusClaimGeneration == generation,
                      self.selectedSessionID == sessionID,
                      self.attachedSessionID == sessionID else { return }
                self.focusClaimInFlight = false
                if focused {
                    self.focusedSessionID = (result?["focused"] as? Bool == true) ? sessionID : nil
                    if let pending = self.pendingFocusResizeSize {
                        self.pendingFocusResizeSize = nil
                        self.resize(columns: pending.columns, rows: pending.rows)
                    }
                } else if self.focusedSessionID == sessionID {
                    self.focusedSessionID = nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.focusClaimGeneration == generation,
                      self.selectedSessionID == sessionID,
                      self.attachedSessionID == sessionID else { return }
                self.focusClaimInFlight = false
                self.present(error)
            }
        }
    }

    func report(_ error: Error) { present(error) }

    func addNotice(
        title: String,
        message: String,
        detail: String? = nil,
        kind: WarrenDesktopNotice.Kind = .info
    ) {
        notices.insert(
            WarrenDesktopNotice(
                kind: kind,
                title: title,
                message: message,
                detail: detail
            ),
            at: 0
        )
        if notices.count > 50 {
            notices.removeLast(notices.count - 50)
        }
    }

    func markNoticeRead(_ id: WarrenDesktopNotice.ID) {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return }
        guard notices[index].isUnread else { return }
        notices[index].isUnread = false
    }

    func dismissNotice(_ id: WarrenDesktopNotice.ID) {
        notices.removeAll { $0.id == id }
    }

    nonisolated static func diagnosticText(
        error: Error,
        endpoint: String? = nil,
        selectedSessionID: TerminalSessionID? = nil,
        attachedSessionID: TerminalSessionID? = nil,
        focusedSessionID: TerminalSessionID? = nil,
        now: Date = Date()
    ) -> String {
        WarrenRemoteDiagnostics.text(
            error: error,
            endpoint: endpoint,
            selectedSessionID: selectedSessionID,
            attachedSessionID: attachedSessionID,
            focusedSessionID: focusedSessionID,
            now: now
        )
    }

    private func request(
        _ method: String,
        params: [String: String] = [:],
        onError: (@MainActor (Error) -> Void)? = nil
    ) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do { _ = try await wire.request(method, params: params) }
            catch {
                if let onError {
                    onError(error)
                } else {
                    self?.present(error)
                }
            }
        }
    }

    private func deleteProject(_ id: ProjectID) {
        guard let wire,
              let group = projection.groups.first(where: { $0.project.id == id }),
              !group.workspaces.contains(where: { deletingWorkspaceIDs.contains($0.id) }),
              deletingProjectIDs.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("project.remove", params: [
                    "id": id.description,
                    "force": "true",
                ])
            } catch {
                guard let self else { return }
                if Self.isRemoteRequestOutcomeUnknown(error) {
                    if self.wire === wire {
                        self.ensureDeletionReconciliation(using: wire)
                    }
                } else {
                    self.deletingProjectIDs.remove(id)
                    if self.wire === wire {
                        self.present(error)
                    }
                }
                return
            }
            // Keep the row busy until an authoritative roster confirms that
            // the project is gone. The helper also retries when the refresh
            // itself times out.
            guard let self, self.wire === wire else { return }
            self.ensureDeletionReconciliation(using: wire)
        }
    }

    private func deleteWorkspace(_ id: WorkspaceID, removeLocalWorktree: Bool) {
        guard let wire,
              let workspace = projection.workspace(id: id),
              !deletingProjectIDs.contains(workspace.projectID),
              deletingWorkspaceIDs.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("workspace.remove", params: [
                    "id": id.description,
                    "force": "true",
                    "remove_worktree": String(removeLocalWorktree),
                ])
            } catch {
                guard let self else { return }
                if Self.isRemoteRequestOutcomeUnknown(error) {
                    if self.wire === wire {
                        self.ensureDeletionReconciliation(using: wire)
                    }
                } else {
                    self.deletingWorkspaceIDs.remove(id)
                    if self.wire === wire {
                        self.present(error)
                    }
                }
                return
            }
            // Keep the row busy until an authoritative roster confirms that
            // the workspace is gone. The helper also retries when the refresh
            // itself times out.
            guard let self, self.wire === wire else { return }
            self.ensureDeletionReconciliation(using: wire)
        }
    }

    private func closeSession(_ id: TerminalSessionID) {
        detachSessionBeingClosed(id)
        request("session.delete", params: ["id": id.description]) { [weak self] error in
            guard let self else { return }
            if Self.isSessionAlreadyClosed(error, sessionID: id) {
                // The tab may already have been closed by a previous action or
                // another client before its roster update arrived. A stale
                // close is a successful no-op, matching the local model's
                // closeTabIfPresent behavior; it must not create a notice.
                Task { await self.refreshRosterIfConnected() }
            } else {
                self.present(error)
            }
        }
    }

    private func moveSession(
        _ id: TerminalSessionID,
        to destination: WarrenDesktopSessionMoveDestination
    ) {
        guard let wire else { return }
        let wasSelected = navigation.selectedTabID == Self.tabID(id)
        var params = ["id": id.description]
        switch destination {
        case .workspace(let workspaceID):
            params["workspace"] = workspaceID.description
        case .terminalGroup(let groupID):
            params["group"] = groupID.description
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("session.move", params: params)
                guard let self else { return }
                try await self.refreshRoster(using: wire)
                guard wasSelected else { return }
                // The roster has already moved the tab into the destination
                // context; selecting the same tab now transfers navigation
                // (sidebar selection and active tab) with the UI.
                self.publishNavigationIfChanged(
                    WarrenDesktopNavigationReducer.reduce(
                        self.navigation,
                        action: .selectTab(Self.tabID(id)),
                        in: self.projection
                    )
                )
                await self.attachSelectedSession()
            } catch {
                self?.present(error)
            }
        }
    }

    /// Releases the local attachment as soon as a session is being closed.
    ///
    /// SwiftUI can demote the terminal view while the delete request is still
    /// in flight, which makes the host call `blur` for the same session. If the
    /// daemon has already removed the session by then, that stale focus request
    /// fails with "no attached session" and would create a notice during
    /// normal tab churn. Clearing attachment state first
    /// keeps the blur, attach, resize, and focus paths inert for the closed
    /// session; the roster still owns the durable cleanup.
    private func detachSessionBeingClosed(_ id: TerminalSessionID) {
        guard selectedSessionID == id else { return }
        attachingSessionID = nil
        selectedSessionID = nil
        attachedSessionID = nil
        focusedSessionID = nil
        pendingFocusSessionID = nil
        pendingFocusSize = nil
        pendingFocusResizeSize = nil
        focusClaimInFlight = false
        focusClaimGeneration += 1
        attachGeneration &+= 1
        pendingInput.removeAll(keepingCapacity: true)
        cancelResizeRequests()
        focusTask?.cancel()
        focusTask = nil
    }

    private func refreshRosterIfConnected() async {
        guard let wire else { return }
        try? await refreshRoster(using: wire)
    }

    private func clearDeletionState() {
        stopDeletionReconciliation()
        deletingProjectIDs.removeAll()
        deletingWorkspaceIDs.removeAll()
    }

    private func stopDeletionReconciliation() {
        deletionReconciliationTask?.cancel()
        deletionReconciliationTask = nil
        deletionReconciliationWire = nil
    }

    private var hasPendingDeletion: Bool {
        !deletingProjectIDs.isEmpty || !deletingWorkspaceIDs.isEmpty
    }

    private func ensureDeletionReconciliation(using wire: WarrenRemoteWire) {
        guard self.wire === wire, hasPendingDeletion else { return }
        if deletionReconciliationWire === wire, deletionReconciliationTask != nil {
            return
        }
        deletionReconciliationTask?.cancel()
        deletionReconciliationWire = wire
        deletionReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcilePendingDeletions(using: wire)
            guard self.deletionReconciliationWire === wire else { return }
            self.deletionReconciliationTask = nil
            self.deletionReconciliationWire = nil
        }
    }

    private func reconcilePendingDeletions(using wire: WarrenRemoteWire) async {
        let deadline = ContinuousClock.now.advanced(by: Self.deletionReconciliationTimeout)
        var delayMilliseconds = 500
        while !Task.isCancelled,
              self.wire === wire,
              hasPendingDeletion {
            guard ContinuousClock.now < deadline else {
                deletingProjectIDs.removeAll()
                deletingWorkspaceIDs.removeAll()
                present(NSError(domain: "WarrenRemote", code: 14, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Deletion did not finish within 30 seconds. Refresh the roster and try again.",
                ]))
                return
            }
            do {
                try await refreshRoster(using: wire)
            } catch is CancellationError {
                return
            } catch {
                // A timeout here does not prove that the deletion failed. Keep
                // the row unavailable and retry the read-only reconciliation.
            }
            guard !Task.isCancelled,
                  self.wire === wire,
                  hasPendingDeletion else { return }
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            delayMilliseconds = min(delayMilliseconds * 2, 15_000)
        }
    }

    nonisolated static func isSessionAlreadyClosed(
        _ error: Error,
        sessionID: TerminalSessionID
    ) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "WarrenRemote"
            && nsError.code == 1
            && nsError.localizedDescription == "session not found: \(sessionID)"
    }

    nonisolated static func reconcileDeletionIDs<T: Hashable>(
        _ pending: Set<T>,
        against live: Set<T>
    ) -> Set<T> {
        pending.intersection(live)
    }

    nonisolated static func shouldApplyRoster(
        startedAt generation: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        generation == currentGeneration
    }

    nonisolated static func isRemoteRequestOutcomeUnknown(_ error: Error) -> Bool {
        isTransportFailure(error as NSError)
    }

    private nonisolated static func isTransportFailure(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            // URLSession occasionally surfaces a dropped WebSocket as a raw
            // POSIX error instead of an NSURLError. These are all expected
            // while the daemon is restarting or the client is reconnecting.
            switch error.code {
            case 32, 50, 51, 54, 57, 60, 61, 65:
                return true
            default:
                break
            }
        }
        switch URLError.Code(rawValue: error.code) {
        case .cancelled,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .resourceUnavailable,
             .secureConnectionFailed,
             .timedOut:
            return true
        default:
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            return isTransportFailure(underlying)
        }
    }

    private func consume(_ event: RemoteWireEvent) async {
        switch event {
        case .roster:
            guard let wire, let roster = await wire.takeLatestRoster() else { return }
            cancelTransientConnectionIssue()
            clearMaintenance()
            guard Self.shouldApplyRoster(roster, after: currentRoster) else {
                ensureDeletionReconciliation(using: wire)
                return
            }
            currentRoster = roster
            apply(roster)
            ensureDeletionReconciliation(using: wire)
        case .agent(let sessionID, let status):
            agentStatusBySessionID[sessionID] = status
            let activity = status.activity
            let presentation = WarrenActivityDismissal.presentedActivity(
                candidate: activity,
                dismissed: dismissedActivityBySessionID[sessionID]
            )
            if presentation.clearsDismissal {
                dismissedActivityBySessionID.removeValue(forKey: sessionID)
            }
            // Activity events are live updates and should not wait for the
            // next roster tick. The roster remains authoritative when it is
            // applied, so a stale event cache cannot overwrite a newer
            // server snapshot later.
            let presentedStatus = presentation.activity == nil ? nil : status
            publishProjectionIfChanged(
                projection.withSessionAgentStatus(presentedStatus, for: sessionID)
            )
        case .maintenance(let message):
            maintenanceMessage = message?.isEmpty == false ? message : "Warren is updating"
            maintenanceResetTask?.cancel()
            // Safety net for an announcement without a restart: the banner
            // clears on the next roster once the daemon is back, and after a
            // bounded timeout so an aborted update cannot linger forever.
            maintenanceResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.clearMaintenance()
            }
        case .output(let data):
            await feedOutput(data)
        case .framedOutput(let sessionID, let epoch, let sequence, let payload):
            if !suppressFramedAnchorUpdates.contains(sessionID) {
                let endSequence = sequence + UInt64(payload.count)
                if let current = outputAnchors[sessionID] {
                    if epoch > current.epoch
                        || (epoch == current.epoch && endSequence > current.sequence) {
                        outputAnchors[sessionID] = TerminalOutputAnchor(
                            epoch: epoch,
                            sequence: endSequence
                        )
                    }
                } else {
                    outputAnchors[sessionID] = TerminalOutputAnchor(
                        epoch: epoch,
                        sequence: endSequence
                    )
                }
            }
            await feedOutput(payload, sessionID: sessionID)
        case .anchor(let sessionID, let epoch, let sequence, let reanchor):
            if reanchor {
                suppressFramedAnchorUpdates.insert(sessionID)
            } else {
                suppressFramedAnchorUpdates.remove(sessionID)
            }
            if let current = outputAnchors[sessionID] {
                if epoch > current.epoch
                    || (epoch == current.epoch && sequence > current.sequence) {
                    outputAnchors[sessionID] = TerminalOutputAnchor(
                        epoch: epoch,
                        sequence: sequence
                    )
                }
            } else {
                outputAnchors[sessionID] = TerminalOutputAnchor(
                    epoch: epoch,
                    sequence: sequence
                )
            }
        case .disconnected:
            // The connection loop observes this event before consume and
            // drives the reconnect; it is unreachable here.
            break
        }
    }

    private func feedOutput(_ data: Data, sessionID: TerminalSessionID? = nil) async {
        guard !data.isEmpty,
              let targetSessionID = sessionID ?? selectedSessionID,
              targetSessionID == selectedSessionID,
              surfaceManager.surface(for: targetSessionID) != nil else { return }
        let nudge = initialRefreshPending
        if nudge {
            TerminalDiagnostics.log("feed_output", [
                "session": targetSessionID.description,
                "bytes": String(data.count),
                "nudge": "true",
            ])
        } else {
            TerminalDiagnostics.logVerbose("feed_output", [
                "session": targetSessionID.description,
                "bytes": String(data.count),
                "nudge": "false",
            ])
        }
        surfaceManager.enqueueRawOutput(data, for: targetSessionID)
        if nudge {
            initialRefreshPending = false
            surfaceManager.requestPresent(targetSessionID)
        }
    }

    private func apply(
        _ roster: RemoteRoster,
        advancesGeneration: Bool = true
    ) {
        if advancesGeneration {
            rosterApplicationGeneration &+= 1
        }
        loadSettings()
        clearMaintenance()
        guard let hostID = HostID(uuidString: roster.host.id) else { return }
        let host = WarrenDomain.Host(id: hostID, name: roster.host.name)
        let projects = roster.projects.compactMap { value -> Project? in
            guard let id = ProjectID(uuidString: value.id) else { return nil }
            return Project(
                id: id,
                hostID: hostID,
                name: value.name,
                rootPath: value.path,
                autoImportGitWorktrees: value.autoImportGitWorktrees ?? false,
                pinned: value.pinned ?? false
            )
        }
        let workspaces = roster.workspaces.compactMap { value -> Workspace? in
            guard let id = WorkspaceID(uuidString: value.id),
                  let projectID = ProjectID(uuidString: value.project) else { return nil }
            return Workspace(
                id: id,
                projectID: projectID,
                name: value.name,
                path: value.path,
                branch: value.branch,
                pinned: value.pinned ?? false,
                mergeState: value.mergeState.flatMap(WorkspaceMergeState.init(rawValue:)),
                managedWorktree: value.managedWorktree ?? false,
                worktreeLocked: value.worktreeLocked ?? false
            )
        }
        let liveProjectIDs = Set(projects.map(\.id))
        let liveWorkspaceIDs = Set(workspaces.map(\.id))
        deletingProjectIDs = Self.reconcileDeletionIDs(
            deletingProjectIDs,
            against: liveProjectIDs
        )
        deletingWorkspaceIDs = Self.reconcileDeletionIDs(
            deletingWorkspaceIDs,
            against: liveWorkspaceIDs
        )
        let terminalGroups = roster.terminalGroups.enumerated().compactMap { index, value -> WarrenDomain.TerminalGroup? in
            guard let id = TerminalGroupID(uuidString: value.id) else { return nil }
            return WarrenDomain.TerminalGroup(
                id: id,
                hostID: hostID,
                name: value.name,
                home: value.home,
                order: value.order ?? index,
                createdAt: Self.terminalGroupDate(value.createdAt)
            )
        }
        let workspacePaths = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.path) })
        let groupHomes = Dictionary(uniqueKeysWithValues: terminalGroups.map { ($0.id, $0.home ?? "") })
        let remoteSessions = roster.sessions.compactMap {
            value -> (RemoteRoster.Session, TerminalSessionID, WorkspaceID?, TerminalGroupID?)? in
            guard let id = TerminalSessionID(uuidString: value.id) else { return nil }
            let workspaceID = value.workspace.flatMap(WorkspaceID.init(uuidString:))
            let terminalGroupID = value.terminalGroup.flatMap(TerminalGroupID.init(uuidString:))
            guard (workspaceID == nil) != (terminalGroupID == nil) else { return nil }
            return (value, id, workspaceID, terminalGroupID)
        }
        let sessions = remoteSessions.map { value, id, workspaceID, terminalGroupID in
            let candidateStatus = Self.resolvedAgentStatus(
                rosterStatus: value.agentStatus,
                liveStatus: agentStatusBySessionID[id]
            )
            let candidateActivity = candidateStatus?.activity
            let presentation = WarrenActivityDismissal.presentedActivity(
                candidate: candidateActivity,
                dismissed: dismissedActivityBySessionID[id]
            )
            if presentation.clearsDismissal {
                dismissedActivityBySessionID.removeValue(forKey: id)
            }
            return WarrenDesktopSession(
                id: id,
                workspaceID: workspaceID,
                terminalGroupID: terminalGroupID,
                tabID: Self.tabID(id),
                title: value.title,
                customTitle: value.customTitle,
                pinned: value.pinned ?? false,
                kind: TerminalSessionKind(rawValue: value.kind) ?? .custom,
                state: value.lifecycle == "running" ? .attached : .exited,
                agentStatus: presentation.activity == nil ? nil : candidateStatus,
                runtimeProcess: value.process ?? value.command ?? "",
                workingDirectory: value.directory
                    ?? workspaceID.flatMap { workspacePaths[$0] }
                    ?? terminalGroupID.flatMap { groupHomes[$0] }
                    ?? ""
            )
        }
        let liveSessionIDs = Set(remoteSessions.map(\.1))
        dismissedActivityBySessionID = dismissedActivityBySessionID.filter {
            liveSessionIDs.contains($0.key)
        }
        let activeStatusSessionIDs = Set(
            remoteSessions.compactMap { value, id, _, _ in
                value.agentStatus == nil ? nil : id
            }
        )
        agentStatusBySessionID = agentStatusBySessionID.filter {
            liveSessionIDs.contains($0.key) && activeStatusSessionIDs.contains($0.key)
        }
        // Ended sessions stay in the projection for history, but they are
        // not openable tabs: attaching to them would fail and leave the user
        // staring at a terminal that cannot accept input.
        let unorderedTabs = remoteSessions.compactMap { value, id, _, _ -> ClientTab? in
            guard value.lifecycle == "running" else { return nil }
            return ClientTab(
                id: Self.tabID(id),
                title: value.title,
                sessionID: id,
                kind: TerminalSessionKind(rawValue: value.kind) ?? .custom
            )
        }
        let sessionWorkspaces = Dictionary(uniqueKeysWithValues: remoteSessions.compactMap { value in
            value.2.map { (value.1, $0) }
        })
        let sessionTerminalGroups = Dictionary(uniqueKeysWithValues: remoteSessions.compactMap { value in
            value.3.map { (value.1, $0) }
        })
        let tabs = applyingLocalTabOrder(
            unorderedTabs,
            sessionWorkspaces: sessionWorkspaces,
            sessionTerminalGroups: sessionTerminalGroups
        )
        let nextProjection = WarrenDesktopProjection(
            host: host,
            projects: projects,
            workspaces: workspaces,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaces,
            connectionState: .attached,
            terminalGroups: terminalGroups,
            sessionTerminalGroupIDs: sessionTerminalGroups
        )
        publishProjectionIfChanged(nextProjection)
        TerminalDiagnostics.log("roster_apply", [
            "tabs": String(tabs.count),
            "selectedTab": navigation.selectedTabID ?? "nil",
            "mounted": String(surfaceManager.retainedSurfaceCount),
        ])
        let liveTabSessionIDs = Set(tabs.compactMap(\.sessionID))
        for sessionID in Array(outputAnchors.keys) where !liveTabSessionIDs.contains(sessionID) {
            outputAnchors.removeValue(forKey: sessionID)
            suppressFramedAnchorUpdates.remove(sessionID)
        }
        // Surface cleanup is only needed when the set of live tabs changes;
        // repeatedly scanning every mounted terminal makes roster bursts
        // compete with input and rendering on the main actor.
        if appliedLiveTabSessionIDs != liveTabSessionIDs {
            surfaceManager.removeAll(except: liveTabSessionIDs)
            appliedLiveTabSessionIDs = liveTabSessionIDs
        }
        cancelTransientConnectionIssue()
        let previousTabID = navigation.selectedTabID
        let nextNavigation = WarrenDesktopNavigationReducer.reconcile(navigation, with: projection)
        if nextNavigation != navigation {
            navigation = nextNavigation
        }
        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
            attachedSessionID = nil
            focusedSessionID = nil
            pendingFocusSessionID = nil
            pendingFocusSize = nil
            pendingFocusResizeSize = nil
            focusClaimInFlight = false
            focusClaimGeneration += 1
            pendingInput.removeAll(keepingCapacity: true)
            cancelResizeRequests()
        }
        if navigation.selectedTabID == nil {
            selectedSessionID = nil
            attachedSessionID = nil
            focusedSessionID = nil
            pendingFocusSessionID = nil
            pendingFocusSize = nil
            pendingFocusResizeSize = nil
            focusClaimInFlight = false
            focusClaimGeneration += 1
            pendingInput.removeAll(keepingCapacity: true)
            cancelResizeRequests()
        } else if WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: previousTabID,
            nextTabID: navigation.selectedTabID,
            mountedSurfaceCount: surfaceManager.retainedSurfaceCount
        ) {
            // The first roster is also the desktop's restore point. Without
            // this explicit attach, the tab bar appears populated while the
            // pane remains empty until the user clicks the tab.
            Task { @MainActor [weak self] in
                await self?.attachSelectedSession()
            }
        }
        fulfillPendingTerminalOpenRequest()
    }

    private func attachSelectedSession() async {
        guard let tabID = navigation.selectedTabID,
              let sessionID = projection.tabs.first(where: { $0.id == tabID })?.sessionID,
              let session = projection.sessions.first(where: { $0.id == sessionID }),
              let wire else { return }

        // Mount before awaiting the attach response. The daemon may legally
        // produce the first tmux snapshot immediately after it accepts the
        // attach request; feeding that snapshot into an already-created surface
        // prevents the initial prompt from disappearing in the network race.
        let existingSurface = surfaceManager.surface(for: sessionID)
        guard existingSurface == nil || selectedSessionID != sessionID || attachedSessionID != sessionID else {
            return
        }
        TerminalDiagnostics.log("attach_start", [
            "session": sessionID.description,
            "existing": existingSurface != nil ? "true" : "false",
        ])
        if let previousSessionID = selectedSessionID, previousSessionID != sessionID {
            pendingInput.removeAll(keepingCapacity: true)
            pendingFocusSessionID = nil
            pendingFocusSize = nil
            pendingFocusResizeSize = nil
            cancelResizeRequests()
        }
        attachGeneration &+= 1
        let generation = attachGeneration
        attachingSessionID = sessionID
        defer {
            if generation == attachGeneration, attachingSessionID == sessionID {
                attachingSessionID = nil
            }
        }
        attachedSessionID = nil
        focusedSessionID = nil
        focusClaimInFlight = false
        focusClaimGeneration += 1
        let surface: GhosttySurface
        if let existingSurface {
            surface = existingSurface
        } else {
            // Defensive fallback: the authoritative cleanup runs in
            // TerminalSurfaceManager.dispose, but never attach a brand-new
            // surface with an anchor from an older surface instance.
            outputAnchors.removeValue(forKey: sessionID)
            suppressFramedAnchorUpdates.remove(sessionID)
            let inputBridge = WarrenOrderedInputBridge { [weak self] data in
                await self?.sendInput(data)
            }
            surface = GhosttySurface(
                id: sessionID,
                attachmentID: TerminalAttachmentID(),
                workingDirectory: session.workingDirectory,
                font: terminalFont,
                onInput: { data in inputBridge.send(data) },
                onResize: { [weak self] columns, rows in Task { @MainActor in self?.resize(columns: columns, rows: rows) } }
            )
            surfaceManager.insert(surface)
        }
        selectedSessionID = sessionID

        // SwiftUI/AppKit reports the actual Ghostty grid only after the
        // surface has entered a measured pane. Waiting here makes the very
        // first tmux snapshot use the same rows/columns as the pixels on
        // screen, instead of briefly capturing the tmux default 120x36 grid.
        // Keep a bounded fallback so a renderer that cannot obtain metrics
        // still attaches and can converge through its later resize callback.
        let size = await waitForSurfaceSize(surface, generation: generation)
        TerminalDiagnostics.log("attach_size", [
            "session": sessionID.description,
            "size": size.map { "\($0.columns)x\($0.rows)" } ?? "nil",
        ])
        guard generation == attachGeneration,
              selectedSessionID == sessionID,
              surfaceManager.surface(for: sessionID) === surface else { return }
        do {
            initialRefreshPending = true
            _ = try await wire.request(
                "session.attach",
                params: WarrenRemoteTerminalProtocol.attachParameters(
                    sessionID: sessionID,
                    size: size,
                    anchor: outputAnchors[sessionID]
                )
            )
            guard generation == attachGeneration,
                  selectedSessionID == sessionID else { return }
            attachedSessionID = sessionID
            TerminalDiagnostics.log("attach_complete", [
                "session": sessionID.description,
            ])
            surfaceManager.requestPresent(sessionID)
            if !pendingInput.isEmpty {
                let buffered = pendingInput
                pendingInput.removeAll(keepingCapacity: true)
                await wire.sendInput(buffered)
            }
            if pendingFocusSessionID == sessionID {
                let pendingSize = pendingFocusSize ?? size
                pendingFocusSessionID = nil
                pendingFocusSize = nil
                sendFocus(sessionID: sessionID, focused: true, size: pendingSize)
            }
        } catch {
            if generation == attachGeneration, selectedSessionID == sessionID {
                selectedSessionID = nil
                attachedSessionID = nil
                focusedSessionID = nil
                removeMountedSurface(sessionID: sessionID)
                // Only a failure for the currently selected session belongs in
                // the notice center. A stale attach can be cancelled by a
                // rapid close of the very tab it was connecting; reporting
                // that would create noise during normal tab churn.
                present(error)
            }
        }
    }

    private func waitForSurfaceSize(
        _ surface: GhosttySurface,
        generation: UInt64
    ) async -> TerminalSize? {
        for _ in 0..<60 {
            guard generation == attachGeneration else { return nil }
            if let metrics = surface.state.surfaceSize,
               let size = TerminalSize(
                   columns: Int(metrics.columns),
                   rows: Int(metrics.rows)
               ) {
                return size
            }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func selectSession(_ id: TerminalSessionID) {
        guard let session = projection.sessions.first(where: { $0.id == id }) else { return }
        guard session.workspaceID != nil || session.terminalGroupID != nil else { return }
        TerminalDiagnostics.log("select_session", [
            "session": id.description,
            "workspace": session.workspaceID?.description ?? "nil",
            "terminalGroup": session.terminalGroupID?.description ?? "nil",
        ])
        publishNavigationIfChanged(
            WarrenDesktopNavigationReducer.reduce(
                navigation,
                action: .openSession(id),
                in: projection
            )
        )
        Task { await attachSelectedSession() }
    }

    private func moveTab(_ tabID: String, before destinationTabID: String?) {
        let currentOrder: [String]
        let reorder: ([String]) -> Void
        if let workspaceID = projection.workspaceID(forTabID: tabID) {
            guard destinationTabID == nil
                || projection.workspaceID(forTabID: destinationTabID!) == workspaceID else { return }
            currentOrder = projection.tabs(in: workspaceID).map(\.id)
            reorder = { [weak self] order in
                guard let self else { return }
                self.tabOrderByWorkspaceID[workspaceID] = order
            }
        } else if let groupID = projection.terminalGroupID(forTabID: tabID) {
            guard destinationTabID == nil
                || projection.terminalGroupID(forTabID: destinationTabID!) == groupID else { return }
            currentOrder = projection.tabs(in: groupID).map(\.id)
            reorder = { [weak self] order in
                guard let self else { return }
                self.tabOrderByTerminalGroupID[groupID] = order
            }
        } else {
            return
        }
        let nextOrder = WarrenRemoteTabOrdering.moving(
            tabID,
            before: destinationTabID,
            in: currentOrder
        )
        guard nextOrder != currentOrder else { return }
        reorder(nextOrder)
        persistTabOrders()
        publishProjectionIfChanged(
            projection.reorderingTabs(
                tabID: tabID,
                accordingTo: nextOrder
            )
        )
    }

    private func applyingLocalTabOrder(
        _ tabs: [ClientTab],
        sessionWorkspaces: [TerminalSessionID: WorkspaceID],
        sessionTerminalGroups: [TerminalSessionID: TerminalGroupID]
    ) -> [ClientTab] {
        let tabWorkspaceIDs = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            tab.sessionID.flatMap { sessionWorkspaces[$0] }.map { (tab.id, $0) }
        })
        let liveWorkspaceIDs = Set(tabWorkspaceIDs.values)
        tabOrderByWorkspaceID = tabOrderByWorkspaceID.filter {
            liveWorkspaceIDs.contains($0.key)
        }
        let tabTerminalGroupIDs = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            tab.sessionID.flatMap { sessionTerminalGroups[$0] }.map { (tab.id, $0) }
        })
        let liveTerminalGroupIDs = Set(tabTerminalGroupIDs.values)
        tabOrderByTerminalGroupID = tabOrderByTerminalGroupID.filter {
            liveTerminalGroupIDs.contains($0.key)
        }

        var result = tabs
        for workspaceID in liveWorkspaceIDs {
            let availableIDs = tabs.compactMap { tab in
                tabWorkspaceIDs[tab.id] == workspaceID ? tab.id : nil
            }
            let preferredOrder = tabOrderByWorkspaceID[workspaceID] ?? availableIDs
            let reconciledOrder = WarrenRemoteTabOrdering.reconciling(
                preferredOrder: preferredOrder,
                availableTabIDs: availableIDs
            )
            tabOrderByWorkspaceID[workspaceID] = reconciledOrder
            let tabsByID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            var orderedTabs = reconciledOrder.compactMap { tabsByID[$0] }.makeIterator()
            result = result.map { tab in
                tabWorkspaceIDs[tab.id] == workspaceID ? (orderedTabs.next() ?? tab) : tab
            }
        }
        for groupID in liveTerminalGroupIDs {
            let availableIDs = tabs.compactMap { tab in
                tabTerminalGroupIDs[tab.id] == groupID ? tab.id : nil
            }
            let preferredOrder = tabOrderByTerminalGroupID[groupID] ?? availableIDs
            let reconciledOrder = WarrenRemoteTabOrdering.reconciling(
                preferredOrder: preferredOrder,
                availableTabIDs: availableIDs
            )
            tabOrderByTerminalGroupID[groupID] = reconciledOrder
            let tabsByID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            var orderedTabs = reconciledOrder.compactMap { tabsByID[$0] }.makeIterator()
            result = result.map { tab in
                tabTerminalGroupIDs[tab.id] == groupID ? (orderedTabs.next() ?? tab) : tab
            }
        }
        return result
    }

    private var selectedWorkspaceID: WorkspaceID? {
        switch navigation.selection {
        case .workspace(let id): id
        case .project(let id): projection.firstWorkspace(in: id)?.id
        case .terminalGroup: nil
        case nil: nil
        }
    }

    private var selectedTerminalGroupID: TerminalGroupID? {
        switch navigation.selection {
        case .terminalGroup(let id): id
        default: nil
        }
    }

    private var selectedContextTabs: [ClientTab] {
        switch navigation.selection {
        case .workspace(let id):
            return projection.tabs(in: id)
        case .terminalGroup(let id):
            return projection.tabs(in: id)
        case .project(let id):
            guard let workspaceID = projection.firstWorkspace(in: id)?.id else { return [] }
            return projection.tabs(in: workspaceID)
        case nil:
            return []
        }
    }

    private func present(_ error: Error) {
        if Self.isRemoteRequestOutcomeUnknown(error), endpointConfiguration != nil {
            scheduleTransientConnectionIssue(error)
            return
        }
        presentDiagnostic(error)
    }

    private func presentDiagnostic(_ error: Error) {
        let detail = Self.diagnosticText(
            error: error,
            endpoint: endpointConfiguration?.url,
            selectedSessionID: selectedSessionID,
            attachedSessionID: attachedSessionID,
            focusedSessionID: focusedSessionID
        )
        addNotice(
            title: "Warren error",
            message: error.localizedDescription,
            detail: detail,
            kind: .error
        )
    }

    private func scheduleTransientConnectionIssue(_ error: Error) {
        guard let expectedConfiguration = endpointConfiguration,
              connectionIssueTask == nil else { return }
        connectionIssueTask = Task { @MainActor [weak self] in
            defer { self?.connectionIssueTask = nil }
            do {
                try await Task.sleep(for: Self.transientConnectionIssueDelay)
            } catch {
                return
            }
            guard let self,
                  self.endpointConfiguration == expectedConfiguration,
                  self.maintenanceMessage == nil else { return }
            self.presentDiagnostic(error)
        }
    }

    private func cancelTransientConnectionIssue() {
        connectionIssueTask?.cancel()
        connectionIssueTask = nil
    }

    @discardableResult
    func publishProjectionIfChanged(_ nextProjection: WarrenDesktopProjection) -> Bool {
        guard projection != nextProjection else { return false }
        projection = nextProjection
        projectionPublicationCount &+= 1
        return true
    }

    nonisolated static func shouldApplyRoster(_ roster: RemoteRoster, after previous: RemoteRoster?) -> Bool {
        previous != roster
    }

    /// The daemon roster is the durable snapshot. A live event is only a
    /// fallback for sessions whose snapshot has not exposed activity yet.
    nonisolated static func resolvedAgentStatus(
        rosterStatus: RemoteRoster.AgentStatus?,
        liveStatus: AgentStatus?
    ) -> AgentStatus? {
        if let rosterStatus,
           let activity = AgentActivityState(rawValue: rosterStatus.activity) {
            let attention = rosterStatus.attention.flatMap { value -> AgentAttention? in
                guard let kind = AgentAttentionKind(rawValue: value.kind) else { return nil }
                return AgentAttention(
                    kind: kind,
                    reason: value.reason,
                    requestID: value.requestID,
                    since: value.since
                )
            }
            return AgentStatus(activity: activity, attention: attention)
        }
        return liveStatus
    }

    private func publishNavigationIfChanged(_ nextNavigation: WarrenDesktopNavigationState) {
        guard navigation != nextNavigation else { return }
        navigation = nextNavigation
    }

    private func restorePersistedTabOrders() {
        let orders = WarrenDesktopNavigationPersistence.restoreTabOrders()
        tabOrderByWorkspaceID = orders.workspace.reduce(into: [:]) { result, entry in
            guard let id = WorkspaceID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
        tabOrderByTerminalGroupID = orders.terminalGroup.reduce(into: [:]) { result, entry in
            guard let id = TerminalGroupID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    private func persistTabOrders() {
        WarrenDesktopNavigationPersistence.saveTabOrders(WarrenDesktopTabOrders(
            workspace: Dictionary(uniqueKeysWithValues: tabOrderByWorkspaceID.map {
                ($0.key.description, $0.value)
            }),
            terminalGroup: Dictionary(uniqueKeysWithValues: tabOrderByTerminalGroupID.map {
                ($0.key.description, $0.value)
            })
        ))
    }
    private static func terminalGroupDate(_ rawValue: String?) -> Date {
        guard let rawValue, let date = ISO8601DateFormatter().date(from: rawValue) else {
            return .distantPast
        }
        return date
    }

    private static func tabID(_ id: TerminalSessionID) -> String { "remote-\(id.description)" }
}

private extension WarrenDesktopProjection {
    func reorderingTabs(tabID: String, accordingTo orderedIDs: [String]) -> Self {
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var orderedTabs = orderedIDs.compactMap { tabsByID[$0] }.makeIterator()
        let reorderedTabs = tabs.map { tab in
            let sameScope = tabWorkspaceIDs[tab.id] != nil
                ? tabWorkspaceIDs[tab.id] == tabWorkspaceIDs[tabID]
                : tabTerminalGroupIDs[tab.id] == tabTerminalGroupIDs[tabID]
            return sameScope ? (orderedTabs.next() ?? tab) : tab
        }
        return Self(
            host: host,
            groups: groups,
            sessions: sessions,
            tabs: reorderedTabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: connectionState,
            terminalGroups: terminalGroups,
            sessionTerminalGroupIDs: sessionTerminalGroupIDs,
            tabTerminalGroupIDs: tabTerminalGroupIDs
        )
    }

    func withConnectionState(_ state: WarrenDesktopConnectionState) -> Self {
        Self(
            host: host,
            groups: groups,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: state,
            terminalGroups: terminalGroups,
            sessionTerminalGroupIDs: sessionTerminalGroupIDs,
            tabTerminalGroupIDs: tabTerminalGroupIDs
        )
    }

}
