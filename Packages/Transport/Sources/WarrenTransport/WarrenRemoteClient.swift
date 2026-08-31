import Foundation
import WarrenDomain
import WarrenProtocol

public enum WarrenRemoteClientError: Error, Equatable, Sendable, LocalizedError {
    case invalidEndpoint
    case alreadyStarted
    case notConnected
    case closed
    case authenticationFailed(String)
    case requestFailed(String)
    case incompatibleProtocol(expected: String, received: String)
    case unsupportedTerminalStateFormat(String)
    case invalidResponse
    case requestTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Warren Host endpoint is invalid."
        case .alreadyStarted:
            return "The Warren remote client is already started."
        case .notConnected:
            return "The Warren remote client is not connected."
        case .closed:
            return "The Warren remote connection is closed."
        case .authenticationFailed(let message):
            return "Warren Host authentication failed: \(message)"
        case .requestFailed(let message):
            return "Warren Host request failed: \(message)"
        case .incompatibleProtocol(let expected, let received):
            return "Warren Host protocol mismatch (expected \(expected), received \(received))."
        case .unsupportedTerminalStateFormat(let format):
            return "Warren Host sent an unsupported terminal state format: \(format)."
        case .invalidResponse:
            return "Warren Host returned an invalid response."
        case .requestTimedOut(let method):
            return "Warren Host request timed out: \(method)."
        }
    }
}

/// One recovery position retained by a native client. `sequence` is the next
/// PTY byte the renderer needs, not the last byte it rendered.
public struct WarrenRemoteRecoveryAnchor: Hashable, Sendable {
    public let epoch: UInt64
    public let sequence: UInt64

    public init(epoch: UInt64, sequence: UInt64) {
        self.epoch = epoch
        self.sequence = sequence
    }
}

private enum WarrenRemoteSocketEvent: Sendable {
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

/// Owns one authenticated URLSession WebSocket and all request continuations
/// for that connection. A new instance is created for every reconnect; this
/// prevents a response from an old socket from completing a request on a new
/// socket.
private actor WarrenRemoteSocket {
    private static let connectTimeout: Duration = .seconds(10)
    private static let requestTimeout: Duration = .seconds(15)
    private static let heartbeatInterval: Duration = .seconds(20)
    private static let maximumWebSocketMessageBytes = 128 * 1024 * 1024
    private static let terminalStateFormat = "ghostline-vt-replay-v1"

    let events: AsyncThrowingStream<WarrenRemoteSocketEvent, Error>

    private let adapter: any WarrenWebSocketTaskAdapter
    private let codec: WarrenWireCodec
    private var continuation: AsyncThrowingStream<WarrenRemoteSocketEvent, Error>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var welcomeContinuation: CheckedContinuation<String, Error>?
    private var welcomeResult: Result<String, WarrenRemoteClientError>?
    private var requests: [String: CheckedContinuation<Data, Error>] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var heartbeatTask: Task<Void, Never>?
    private var isClosed = false

    init(adapter: any WarrenWebSocketTaskAdapter, codec: WarrenWireCodec = WarrenWireCodec()) {
        self.adapter = adapter
        self.codec = codec
        let pair = AsyncThrowingStream<WarrenRemoteSocketEvent, Error>.makeStream()
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    static func adapter(
        url: URL,
        session: URLSession
    ) -> any WarrenWebSocketTaskAdapter {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumWebSocketMessageBytes
        return URLSessionWebSocketTaskAdapter(task: task)
    }

    func connect(token: String, isRelay: Bool = false, clientID: String? = nil) async throws -> String {
        guard !isClosed else { throw WarrenRemoteClientError.closed }
        await adapter.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        var auth: [String: Any] = [
            "t": "auth",
            "version": "2.0",
            "capabilities": ["roster-delta"],
            "terminalStateFormats": [Self.terminalStateFormat],
        ]
        if isRelay {
            auth["access_token"] = token
            if let clientID, !clientID.isEmpty { auth["client_id"] = clientID }
        } else {
            auth["token"] = token
        }
        let authPayload = Self.json(auth)
        do {
            try await adapter.send(.text(authPayload))
        } catch {
            fail(error)
            throw error
        }

        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.waitForWelcome() }
                group.addTask {
                    try await Task.sleep(for: Self.connectTimeout)
                    throw WarrenRemoteClientError.requestTimedOut("welcome")
                }
                let value = try await group.next()!
                group.cancelAll()
                return value
            }
        }, onCancel: {
            Task { await self.close() }
        })
    }

    /// Keeps otherwise quiet LAN/relay connections alive. A protocol-level
    /// ping does not enqueue a roster response behind terminal or Agent
    /// traffic, so a busy Host cannot make an otherwise healthy socket look
    /// disconnected just because a heartbeat request timed out.
    func startHeartbeat() {
        guard heartbeatTask == nil, !isClosed else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.heartbeatInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                do {
                    try await self?.adapter.ping()
                } catch {
                    await self?.fail(error)
                    return
                }
            }
        }
    }

    private func waitForWelcome() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if let welcomeResult {
                    self.welcomeResult = nil
                    continuation.resume(with: welcomeResult)
                    return
                }
                welcomeContinuation = continuation
                if isClosed {
                    welcomeContinuation = nil
                    continuation.resume(throwing: WarrenRemoteClientError.closed)
                }
            }
        }, onCancel: {
            Task { await self.cancelWelcomeWait() }
        })
    }

    private func cancelWelcomeWait() {
        guard let welcomeContinuation else { return }
        self.welcomeContinuation = nil
        welcomeContinuation.resume(throwing: CancellationError())
    }

    func request(_ method: String, params: [String: String]) async throws -> Data {
        guard !isClosed else { throw WarrenRemoteClientError.closed }
        let id = UUID().uuidString.lowercased()
        let text = Self.json([
            "t": "request",
            "id": id,
            "method": method,
            "params": params,
        ])
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                requests[id] = continuation
                requestTimeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(for: Self.requestTimeout)
                    guard !Task.isCancelled else { return }
                    await self?.failRequest(id, error: WarrenRemoteClientError.requestTimedOut(method))
                }
                Task { [weak self] in
                    do {
                        try await self?.adapter.send(.text(text))
                    } catch {
                        await self?.fail(error)
                    }
                }
                if Task.isCancelled {
                    failRequest(id, error: WarrenRemoteClientError.closed)
                }
            }
        }, onCancel: {
            Task { await self.failRequest(id, error: WarrenRemoteClientError.closed) }
        })
    }

    func sendBinary(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw WarrenRemoteClientError.closed }
        do {
            try await adapter.send(.binary(bytes))
        } catch {
            fail(error)
            throw error
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        requestTimeoutTasks.values.forEach { $0.cancel() }
        requestTimeoutTasks.removeAll()
        welcomeContinuation?.resume(throwing: WarrenRemoteClientError.closed)
        welcomeContinuation = nil
        welcomeResult = nil
        requests.values.forEach { $0.resume(throwing: WarrenRemoteClientError.closed) }
        requests.removeAll()
        continuation?.finish()
        continuation = nil
        Task { await adapter.cancel() }
    }

    private func fail(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        requestTimeoutTasks.values.forEach { $0.cancel() }
        requestTimeoutTasks.removeAll()
        welcomeContinuation?.resume(throwing: error)
        welcomeContinuation = nil
        requests.values.forEach { $0.resume(throwing: error) }
        requests.removeAll()
        continuation?.finish(throwing: error)
        continuation = nil
        Task { await adapter.cancel() }
    }

    private func failRequest(_ id: String, error: Error) {
        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        requests.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled, !isClosed {
                let message = try await adapter.receive()
                switch message {
                case .binary(let bytes):
                    let decoded = try codec.decodeFrame(bytes)
                    switch decoded {
                    case .output(let frame):
                        guard let sessionID = UUID(uuidString: frame.header.sessionID.description) else {
                            throw WarrenRemoteClientError.invalidResponse
                        }
                        _ = continuation?.yield(.output(WarrenRemoteOutputFrame(
                            sessionID: sessionID.uuidString.lowercased(),
                            epoch: frame.header.epoch,
                            sequence: frame.header.sequence,
                            payload: frame.payload
                        )))
                    case .atomicState(let frame):
                        guard let sessionID = UUID(uuidString: frame.header.sessionID.description) else {
                            throw WarrenRemoteClientError.invalidResponse
                        }
                        guard frame.header.format == Self.terminalStateFormat else {
                            throw WarrenRemoteClientError.unsupportedTerminalStateFormat(frame.header.format)
                        }
                        _ = continuation?.yield(.atomicState(WarrenRemoteAtomicState(
                            sessionID: sessionID.uuidString.lowercased(),
                            epoch: frame.header.epoch,
                            sequence: frame.header.sequence,
                            format: frame.header.format,
                            payload: frame.payload
                        )))
                    case .input:
                        throw WarrenRemoteClientError.invalidResponse
                    }
        case .text(let text):
                    try await handleText(Data(text.utf8))
                }
            }
        } catch {
            guard !Task.isCancelled, !isClosed else { return }
            _ = continuation?.yield(.disconnected(reason: error.localizedDescription))
            fail(error)
        }
    }

    private func handleText(_ data: Data) async throws {
        if let message = try? JSONDecoder().decode(WarrenRemoteRoster.StreamMessage.self, from: data) {
            if message.type == "roster", let state = message.state {
                _ = continuation?.yield(.roster(state))
                return
            }
            if message.type == "roster.delta", let delta = message.delta {
                _ = continuation?.yield(.rosterDelta(delta))
                return
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else {
            return
        }
        switch type {
        case "welcome":
            let version = object["version"] as? String ?? "unknown"
            guard WarrenRemoteClient.compatibleProtocolVersion(version, with: "2.0") else {
                let error = WarrenRemoteClientError.incompatibleProtocol(expected: "2.0", received: version)
                if let welcomeContinuation {
                    self.welcomeContinuation = nil
                    welcomeContinuation.resume(throwing: error)
                } else {
                    welcomeResult = .failure(error)
                }
                throw error
            }
            if let welcomeContinuation {
                self.welcomeContinuation = nil
                welcomeContinuation.resume(returning: version)
            } else {
                welcomeResult = .success(version)
            }
            _ = continuation?.yield(.welcome(version: version))
        case "response":
            guard let id = object["id"] as? String else { return }
            if object["ok"] as? Bool == true {
                let value = object["result"] ?? NSNull()
                let encoded = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                    ?? Data("null".utf8)
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
                requests.removeValue(forKey: id)?.resume(returning: encoded)
            } else {
                let message = object["error"] as? String ?? "Remote request failed"
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
                requests.removeValue(forKey: id)?.resume(throwing: WarrenRemoteClientError.requestFailed(message))
            }
        case "error":
            // Headless uses `error`; Relay's upgrade boundary uses `message`.
            // Preserve the server's reason so a rejected ticket, offline Host,
            // or expired capability is actionable in the mobile connection
            // banner instead of collapsing everything into one generic error.
            let message = object["error"] as? String
                ?? object["message"] as? String
                ?? "Remote authentication failed"
            let error = WarrenRemoteClientError.authenticationFailed(message)
            if let welcomeContinuation {
                self.welcomeContinuation = nil
                welcomeContinuation.resume(throwing: error)
            } else {
                welcomeResult = .failure(error)
            }
            throw error
        case "attached", "synced":
            guard let sessionID = object["session"] as? String,
                  let epoch = Self.uint64(object["epoch"]),
                  let sequence = Self.uint64(object["sequence"]) else { return }
            let reanchor = object["reanchor"] as? Bool ?? (type == "attached")
            _ = continuation?.yield(.anchor(WarrenRemoteOutputAnchor(
                sessionID: sessionID,
                epoch: epoch,
                sequence: sequence,
                reanchor: type == "synced" ? false : reanchor,
                synced: type == "synced"
            )))
        case "agent":
            guard let sessionID = object["session"] as? String,
                  let rawEvents = object["events"] else { return }
            let encoded = try JSONSerialization.data(withJSONObject: rawEvents)
            let events = try JSONDecoder().decode([WarrenRemoteAgentEvent].self, from: encoded)
            _ = continuation?.yield(.agent(
                sessionID: sessionID,
                epoch: Self.uint64(object["epoch"]) ?? 0,
                events: events
            ))
        case "agent.status":
            guard let sessionID = object["session"] as? String,
                  let rawStatus = object["status"] else { return }
            let encoded = try JSONSerialization.data(withJSONObject: rawStatus)
            let status = try JSONDecoder().decode(WarrenRemoteAgentStatus.self, from: encoded)
            _ = continuation?.yield(.agentStatus(
                sessionID: sessionID,
                epoch: Self.uint64(object["epoch"]) ?? 0,
                status: status
            ))
        case "agent.turn":
            guard let sessionID = object["session"] as? String,
                  let turn = Self.uint64(object["turn"]),
                  let status = object["status"] as? String else { return }
            _ = continuation?.yield(.agentTurn(
                sessionID: sessionID,
                epoch: Self.uint64(object["epoch"]) ?? 0,
                turn: WarrenRemoteAgentTurn(id: turn, status: .init(rawValue: status))
            ))
        case "maintenance":
            _ = continuation?.yield(.maintenance(message: object["message"] as? String))
        default:
            break
        }
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as NSNumber: return value.uint64Value
        case let value as String: return UInt64(value)
        default: return nil
        }
    }

    private static func json(_ value: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Cross-platform client for the `warren-headless` Host WebSocket API.
///
/// The client owns connection/reconnect state and emits typed events. SwiftUI
/// or AppKit consumers should observe `events()` and keep their own rendering
/// state; no WebSocket or renderer object needs to cross into a View.
public actor WarrenRemoteClient {
    private struct Subscription: Sendable {
        let size: TerminalSize?
        let claimControl: Bool
    }

    private let configuration: WarrenRemoteEndpointConfiguration
    private let urlSession: URLSession
    private var accessToken: String
    /// A native pairing intentionally leaves the Relay capability's client_id
    /// empty. Keeping this optional also lets a future enrollment flow pin a
    /// stable client identity without changing the WebSocket protocol.
    private let clientID: String?
    private var injectedTask: (any WarrenWebSocketTaskAdapter)?
    private let codec: WarrenWireCodec
    private let eventStream: AsyncStream<WarrenRemoteEvent>
    private var eventContinuation: AsyncStream<WarrenRemoteEvent>.Continuation?
    private var connectionTask: Task<Void, Never>?
    private var socket: WarrenRemoteSocket?
    private var running = false
    private var connectionState: WarrenRemoteConnectionState = .stopped
    private var rosterStorage: WarrenRemoteRoster?
    private var anchors: [String: WarrenRemoteRecoveryAnchor] = [:]
    /// Subscriptions survive a socket replacement. They are deliberately
    /// separate from recovery anchors: the latter advance with every frame,
    /// while this table records the user's current visibility intent.
    private var subscriptions: [String: Subscription] = [:]

    public init(
        configuration: WarrenRemoteEndpointConfiguration,
        urlSession: URLSession = WarrenRemoteNetworking.session,
        codec: WarrenWireCodec = WarrenWireCodec()
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.accessToken = configuration.token
        self.clientID = nil
        self.codec = codec
        let pair = AsyncStream<WarrenRemoteEvent>.makeStream()
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    /// Injection initializer for scripted WebSocket and protocol tests.
    public init(
        configuration: WarrenRemoteEndpointConfiguration,
        task: any WarrenWebSocketTaskAdapter,
        codec: WarrenWireCodec = WarrenWireCodec()
    ) {
        self.configuration = configuration
        self.urlSession = .shared
        self.accessToken = configuration.token
        self.clientID = nil
        self.injectedTask = task
        self.codec = codec
        let pair = AsyncStream<WarrenRemoteEvent>.makeStream()
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    public nonisolated func events() -> AsyncStream<WarrenRemoteEvent> { eventStream }

    public func start() {
        guard !running else { return }
        running = true
        setConnectionState(.connecting)
        connectionTask = Task { [weak self] in await self?.runConnectionLoop() }
    }

    public func stop() {
        running = false
        connectionTask?.cancel()
        connectionTask = nil
        let socket = socket
        self.socket = nil
        Task { await socket?.close() }
        setConnectionState(.stopped)
    }

    public func reconnectNow() {
        guard running else { return }
        let socket = socket
        self.socket = nil
        Task { await socket?.close() }
        setConnectionState(.reconnecting)
    }

    public func state() -> WarrenRemoteConnectionState { connectionState }
    public func roster() -> WarrenRemoteRoster? { rosterStorage }
    public func recoveryAnchor(for sessionID: String) -> WarrenRemoteRecoveryAnchor? { anchors[sessionID] }

    public func request(_ method: String, params: [String: String] = [:]) async throws -> Data {
        guard let socket else { throw WarrenRemoteClientError.notConnected }
        return try await request(on: socket, method: method, params: params)
    }

    public func request<Value: Decodable>(
        _ method: String,
        params: [String: String] = [:],
        decoding type: Value.Type = Value.self
    ) async throws -> Value {
        let data = try await request(method, params: params)
        return try decode(data, as: type)
    }

    /// Creates a Host-owned session in a workspace, terminal group, or the
    /// Host's default terminal group when neither scope is supplied.
    @discardableResult
    public func createSession(
        workspaceID: String? = nil,
        terminalGroupID: String? = nil,
        command: String? = nil,
        kind: String? = nil,
        title: String? = nil,
        runtimeKind: String? = nil
    ) async throws -> WarrenRemoteSession {
        var params: [String: String] = [:]
        if let workspaceID, !workspaceID.isEmpty { params["workspace"] = workspaceID }
        if let terminalGroupID, !terminalGroupID.isEmpty { params["group"] = terminalGroupID }
        if let command { params["command"] = command }
        if let kind { params["kind"] = kind }
        if let title { params["title"] = title }
        if let runtimeKind { params["runtimeKind"] = runtimeKind }
        return try await request("session.create", params: params, decoding: WarrenRemoteSession.self)
    }

    @discardableResult
    public func deleteSession(sessionID: String) async throws -> Bool {
        let result = try await request(
            "session.delete",
            params: ["id": sessionID],
            decoding: [String: Bool].self
        )
        return result["deleted"] ?? false
    }

    @discardableResult
    public func createWorkspace(
        projectID: String,
        branch: String,
        name: String? = nil,
        path: String? = nil
    ) async throws -> WarrenRemoteWorkspaceCreateResult {
        var params = ["project": projectID, "branch": branch]
        if let name { params["name"] = name }
        if let path { params["path"] = path }
        return try await request("workspace.create", params: params, decoding: WarrenRemoteWorkspaceCreateResult.self)
    }

    @discardableResult
    public func renameWorkspace(workspaceID: String, name: String) async throws -> Bool {
        let result = try await request(
            "workspace.rename",
            params: ["id": workspaceID, "name": name],
            decoding: [String: Bool].self
        )
        return result["renamed"] ?? false
    }

    @discardableResult
    public func deleteWorkspace(
        workspaceID: String,
        force: Bool = false,
        removeWorktree: Bool = false
    ) async throws -> Bool {
        let result = try await request(
            "workspace.remove",
            params: [
                "id": workspaceID,
                "force": force ? "true" : "false",
                "remove_worktree": removeWorktree ? "true" : "false",
            ],
            decoding: [String: Bool].self
        )
        return result["removed"] ?? false
    }

    private func request(
        on socket: WarrenRemoteSocket,
        method: String,
        params: [String: String]
    ) async throws -> Data {
        try await socket.request(method, params: params)
    }

    private func decode<Value: Decodable>(_ data: Data, as type: Value.Type) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw WarrenRemoteClientError.invalidResponse
        }
    }

    @discardableResult
    public func subscribe(
        sessionID: String,
        size: TerminalSize? = nil,
        anchor: WarrenRemoteRecoveryAnchor? = nil,
        claimControl: Bool = false
    ) async throws -> WarrenRemoteSubscriptionResult {
        let result = try await subscribe(
            sessionID: sessionID,
            size: size,
            anchor: anchor,
            claimControl: claimControl,
            record: true
        )
        return result
    }

    private func subscribe(
        sessionID: String,
        size: TerminalSize?,
        anchor: WarrenRemoteRecoveryAnchor?,
        claimControl: Bool,
        record: Bool,
        socket: WarrenRemoteSocket? = nil
    ) async throws -> WarrenRemoteSubscriptionResult {
        var params = ["id": sessionID, "claim": claimControl ? "true" : "false"]
        if let size {
            params["cols"] = String(size.columns)
            params["rows"] = String(size.rows)
        }
        if let anchor {
            params["epoch"] = String(anchor.epoch)
            params["sequence"] = String(anchor.sequence)
        }
        if record {
            // Record intent before the request starts. A Session can be
            // selected while the socket is reconnecting; retaining that
            // intent lets the next socket restore it automatically.
            subscriptions[sessionID] = Subscription(size: size, claimControl: claimControl)
        }
        let data: Data
        if let socket {
            data = try await request(on: socket, method: "session.subscribe", params: params)
        } else {
            data = try await request("session.subscribe", params: params)
        }
        let result = try decode(data, as: WarrenRemoteSubscriptionResult.self)
        return result
    }

    @discardableResult
    public func unsubscribe(sessionID: String) async throws -> Bool {
        // Remove the local visibility intent before waiting for the Host. If
        // the socket is already down there is no request to send, but a later
        // reconnect must still not resurrect a Session the user left.
        subscriptions.removeValue(forKey: sessionID)
        let result = try await request(
            "session.unsubscribe",
            params: ["id": sessionID],
            decoding: [String: Bool].self
        )
        return result["unsubscribed"] ?? false
    }

    @discardableResult
    public func focus(
        sessionID: String,
        focused: Bool = true,
        size: TerminalSize? = nil
    ) async throws -> WarrenRemoteFocusResult {
        var params = ["id": sessionID, "focused": focused ? "true" : "false"]
        if focused, let size {
            params["cols"] = String(size.columns)
            params["rows"] = String(size.rows)
        }
        return try await request("session.focus", params: params, decoding: WarrenRemoteFocusResult.self)
    }

    @discardableResult
    public func resize(_ size: TerminalSize) async throws -> Bool {
        let result = try await request(
            "session.resize",
            params: ["cols": String(size.columns), "rows": String(size.rows)],
            decoding: [String: Bool].self
        )
        return result["resized"] ?? false
    }

    /// Sends raw PTY bytes. The Host accepts these bytes only while this
    /// client owns the session's control lease.
    public func sendInput(_ payload: Data) async throws {
        guard let socket else { throw WarrenRemoteClientError.notConnected }
        try await socket.sendBinary(Array(payload))
    }

    /// Sends an Agent composer value through the same PTY protocol as the Web
    /// client: CR-delimited text followed by kitty Enter after a short fence.
    public func sendAgentInput(_ text: String, sessionID: String? = nil) async throws {
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        guard !normalized.isEmpty else { return }
        try await sendInput(Data(normalized.utf8))
        _ = sessionID
        try await Task.sleep(for: .milliseconds(80))
        try await sendInput(Data([0x1B, 0x5B, 0x31, 0x33, 0x75]))
    }

    public func agentHistory(
        sessionID: String,
        before: UInt64? = nil,
        limit: Int = 100,
        conversationOnly: Bool = false
    ) async throws -> WarrenRemoteAgentHistoryPage {
        var params = ["session": sessionID, "limit": String(limit)]
        if let before { params["before"] = String(before) }
        if conversationOnly { params["priority"] = "conversation" }
        return try await request("agent.history", params: params, decoding: WarrenRemoteAgentHistoryPage.self)
    }

    /// A deterministic exponential backoff shared by mobile and desktop
    /// clients. The first retry waits 500 ms and the delay caps at 30 s.
    public static func reconnectDelayMilliseconds(attempt: Int) -> Int {
        let bounded = min(max(attempt, 0), 6)
        return min(30_000, 500 * (1 << bounded))
    }

    public static func compatibleProtocolVersion(_ lhs: String, with rhs: String) -> Bool {
        lhs.split(separator: ".", maxSplits: 1).first == rhs.split(separator: ".", maxSplits: 1).first
    }

    private func runConnectionLoop() async {
        var attempt = 0
        while running, !Task.isCancelled {
            guard let url = configuration.webSocketURL else {
                setConnectionState(.disconnected)
                emit(.disconnected(reason: WarrenRemoteClientError.invalidEndpoint.localizedDescription))
                return
            }
            if configuration.isRelay, accessToken.isEmpty {
                _ = await refreshRelayAccessToken()
            }
            setConnectionState(attempt == 0 ? .connecting : .reconnecting)
            let adapter: any WarrenWebSocketTaskAdapter
            if let injectedTask {
                adapter = injectedTask
                self.injectedTask = nil
            } else {
                adapter = WarrenRemoteSocket.adapter(url: url, session: urlSession)
            }
            let socket = WarrenRemoteSocket(adapter: adapter, codec: codec)
            self.socket = socket
            let connectionStartedAt = ContinuousClock.now
            var refreshedAfterAuthenticationFailure = false
            do {
                let version = try await socket.connect(
                    token: accessToken,
                    isRelay: configuration.isRelay,
                    clientID: clientID
                )
                setConnectionState(.connected)
                await socket.startHeartbeat()
                _ = version
                await restoreSubscriptions(on: socket)
                for try await event in socket.events {
                    guard running, !Task.isCancelled else { return }
                    if case .disconnected(let reason) = event {
                        emit(.disconnected(reason: reason))
                        break
                    }
                    await consume(event, from: socket)
                }
            } catch {
                guard running, !Task.isCancelled else { return }
                // Relay access capabilities are intentionally short-lived. A
                // failed auth after a foreground resume is recoverable when
                // the shared URLSession still owns the HttpOnly refresh cookie;
                // rotate once before surfacing a reconnect error.
                if configuration.isRelay,
                   Self.isAuthenticationFailure(error) {
                    refreshedAfterAuthenticationFailure = await refreshRelayAccessToken()
                }
                if !refreshedAfterAuthenticationFailure {
                    emit(.disconnected(reason: error.localizedDescription))
                }
            }
            if self.socket === socket { self.socket = nil }
            await socket.close()
            guard running, !Task.isCancelled else { return }
            if refreshedAfterAuthenticationFailure {
                attempt = 0
                setConnectionState(.reconnecting)
                continue
            }
            // A socket that remained connected through a short stability
            // window is considered healthy. Reset the backoff only after that
            // point; otherwise a handshake that succeeds and immediately dies
            // would loop at 500 ms forever and present as constant reconnecting.
            if ContinuousClock.now - connectionStartedAt >= .seconds(10) {
                attempt = 0
            }
            setConnectionState(.reconnecting)
            let delay = Self.reconnectDelayMilliseconds(attempt: attempt)
            attempt += 1
            try? await Task.sleep(for: .milliseconds(delay))
        }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let remoteError = error as? WarrenRemoteClientError else { return false }
        if case .authenticationFailed = remoteError { return true }
        return false
    }

    private func refreshRelayAccessToken() async -> Bool {
        guard configuration.isRelay,
              let url = configuration.relaySessionRefreshURL else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return false }
            let value = try JSONDecoder().decode(WarrenRelaySessionExchange.self, from: data)
            guard value.hostID == configuration.hostID,
                  !value.accessToken.isEmpty else { return false }
            accessToken = value.accessToken
            return true
        } catch {
            return false
        }
    }

    private func consume(_ event: WarrenRemoteSocketEvent, from socket: WarrenRemoteSocket) async {
        switch event {
        case .welcome(let version): emit(.welcome(version: version))
        case .roster(let roster):
            if let currentRevision = rosterStorage?.revision,
               let nextRevision = roster.revision,
               nextRevision < currentRevision {
                return
            }
            rosterStorage = roster
            emit(.roster(roster))
        case .rosterDelta(let delta):
            if let current = rosterStorage, let next = current.applying(delta) {
                rosterStorage = next
                emit(.rosterDelta(delta))
                emit(.roster(next))
            } else {
                do {
                    let data = try await socket.request("roster", params: [:])
                    let next = try JSONDecoder().decode(WarrenRemoteRoster.self, from: data)
                    rosterStorage = next
                    emit(.roster(next))
                } catch {
                    emit(.disconnected(reason: error.localizedDescription))
                }
            }
        case .output(let frame):
            let sequenceResult = frame.sequence.addingReportingOverflow(UInt64(frame.payload.count))
            guard !sequenceResult.overflow else {
                emit(.disconnected(reason: WarrenRemoteClientError.invalidResponse.localizedDescription))
                await socket.close()
                return
            }
            updateOutputAnchor(
                sessionID: frame.sessionID,
                epoch: frame.epoch,
                sequence: frame.sequence,
                endSequence: sequenceResult.partialValue
            )
            emit(.output(frame))
        case .atomicState(let state):
            updateAnchor(sessionID: state.sessionID, epoch: state.epoch, sequence: state.sequence)
            emit(.atomicState(state))
        case .anchor(let anchor):
            updateAnchor(sessionID: anchor.sessionID, epoch: anchor.epoch, sequence: anchor.sequence)
            emit(.anchor(anchor))
        case .agent(let sessionID, let epoch, let events):
            emit(.agent(sessionID: sessionID, epoch: epoch, events: events))
        case .agentStatus(let sessionID, let epoch, let status):
            emit(.agentStatus(sessionID: sessionID, epoch: epoch, status: status))
        case .agentTurn(let sessionID, let epoch, let turn):
            emit(.agentTurn(sessionID: sessionID, epoch: epoch, turn: turn))
        case .maintenance(let message): emit(.maintenance(message: message))
        case .disconnected(let reason): emit(.disconnected(reason: reason))
        }
    }

    private func updateAnchor(sessionID: String, epoch: UInt64, sequence: UInt64) {
        guard let current = anchors[sessionID] else {
            anchors[sessionID] = WarrenRemoteRecoveryAnchor(epoch: epoch, sequence: sequence)
            return
        }
        guard epoch > current.epoch || (epoch == current.epoch && sequence > current.sequence) else {
            return
        }
        anchors[sessionID] = WarrenRemoteRecoveryAnchor(epoch: epoch, sequence: sequence)
    }

    private func updateOutputAnchor(
        sessionID: String,
        epoch: UInt64,
        sequence: UInt64,
        endSequence: UInt64
    ) {
        guard let current = anchors[sessionID] else {
            anchors[sessionID] = WarrenRemoteRecoveryAnchor(epoch: epoch, sequence: endSequence)
            return
        }
        guard epoch >= current.epoch else { return }
        // A frame that starts after the last contiguous byte indicates a
        // recovery gap. Keep the older anchor so the next subscription asks
        // the Host for an atomic checkpoint instead of skipping the gap.
        if epoch == current.epoch, sequence > current.sequence { return }
        guard endSequence > current.sequence || epoch > current.epoch else { return }
        anchors[sessionID] = WarrenRemoteRecoveryAnchor(epoch: epoch, sequence: endSequence)
    }

    private func restoreSubscriptions(on socket: WarrenRemoteSocket) async {
        // Snapshot the dictionary so an unsubscribe/selection change made by
        // the UI while recovery requests are in flight does not mutate the
        // collection being iterated. The final request still uses the socket
        // captured for this connection and cannot affect a newer socket.
        let pending = subscriptions
        for (sessionID, subscription) in pending.sorted(by: { $0.key < $1.key }) {
            guard running, self.socket === socket else { return }
            guard let current = subscriptions[sessionID],
                  current.size == subscription.size,
                  current.claimControl == subscription.claimControl else { continue }
            let anchor = anchors[sessionID]
            do {
                _ = try await subscribe(
                    sessionID: sessionID,
                    size: subscription.size,
                    anchor: anchor,
                    claimControl: subscription.claimControl,
                    record: false,
                    socket: socket
                )
            } catch {
                // A Host may evict an old ring or cursor after a restart. In
                // that case the anchor is only a hint; retry without it so
                // protocol 2 can deliver a fresh atomic checkpoint. Other
                // failures (for example an ended Session) retain the intent
                // for a later roster/reconnect without issuing a second
                // request immediately.
                if anchor != nil,
                   Self.isRecoveryAnchorFailure(error),
                   running,
                   self.socket === socket {
                    _ = try? await subscribe(
                        sessionID: sessionID,
                        size: subscription.size,
                        anchor: nil,
                        claimControl: subscription.claimControl,
                        record: false,
                        socket: socket
                    )
                }
            }
        }
    }

    private static func isRecoveryAnchorFailure(_ error: Error) -> Bool {
        guard case let WarrenRemoteClientError.requestFailed(message) = error else {
            return false
        }
        let value = message.lowercased()
        return value.contains("anchor")
            || value.contains("cursor")
            || value.contains("epoch")
            || value.contains("sequence")
            || value.contains("recovery")
    }

    private func setConnectionState(_ state: WarrenRemoteConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        emit(.connection(state))
    }

    private func emit(_ event: WarrenRemoteEvent) {
        _ = eventContinuation?.yield(event)
    }
}
