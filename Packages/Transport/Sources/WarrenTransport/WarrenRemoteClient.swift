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
    case requestFailedWithCode(code: String, message: String, details: [String: WarrenRemoteJSONValue]?)
    case incompatibleProtocol(expected: String, received: String)
    case upgradeRequired(String)
    case unsupportedTerminalStateFormat(String)
    case messageTooLarge(kind: String, actual: Int, limit: Int)
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
        case .requestFailedWithCode(let code, let message, _):
            return "Warren Host request failed [\(code)]: \(message)"
        case .incompatibleProtocol(let expected, let received):
            return "Warren Host protocol mismatch (expected \(expected), received \(received))."
        case .upgradeRequired(let message):
            return "Warren Host upgrade required: \(message)"
        case .unsupportedTerminalStateFormat(let format):
            return "Warren Host sent an unsupported terminal state format: \(format)."
        case .messageTooLarge(let kind, let actual, let limit):
            return "Warren Host sent an oversized \(kind) message (\(actual) bytes; limit \(limit))."
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
    case welcome(version: String, capabilities: [String])
    case roster(WarrenRemoteRoster)
    case rosterDelta(WarrenRemoteRoster.Delta)
    case output(WarrenRemoteOutputFrame)
    case atomicState(WarrenRemoteAtomicState)
    case anchor(WarrenRemoteOutputAnchor)
    case agentEvents(streamID: String, executionID: String, events: [WarrenRemoteAgentEvent])
    case maintenance(message: String?)
    case disconnected(reason: String)
}

/// Owns one authenticated URLSession WebSocket and all request continuations
/// for that connection. A new instance is created for every reconnect; this
/// prevents a response from an old socket from completing a request on a new
/// socket.
private actor WarrenRemoteSocket {
    // Mobile networks may spend several seconds on DNS, TLS, and proxy
    // negotiation before the authenticated welcome arrives.
    private static let connectTimeout: Duration = .seconds(30)
    private static let requestTimeout: Duration = .seconds(15)
    private static let heartbeatInterval: Duration = .seconds(20)
    private let terminalStateFormats: Set<String>

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
    private var welcomeHostID: String?
    private var welcomeAccessScopeID: String?

    init(
        adapter: any WarrenWebSocketTaskAdapter,
        codec: WarrenWireCodec = WarrenWireCodec(),
        terminalStateFormats: Set<String>
    ) {
        self.adapter = adapter
        self.codec = codec
        self.terminalStateFormats = terminalStateFormats
        // A peer can stream terminal bytes and Agent deltas faster than a
        // suspended iOS consumer can drain them. Bound the socket queue so a
        // stalled scene cannot retain an unbounded transcript; the model's
        // sequence/anchor recovery repairs any dropped tail after resume.
        let pair = AsyncThrowingStream<WarrenRemoteSocketEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2048)
        )
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    static func adapter(
        url: URL,
        session: URLSession,
        maximumMessageSize: Int
    ) -> any WarrenWebSocketTaskAdapter {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        return URLSessionWebSocketTaskAdapter(task: task)
    }

    func connect(
        token: String,
        isRelay: Bool = false,
        clientID: String? = nil,
        capabilities: [String] = [
            "roster-delta",
            WarrenRemoteAgentCapability.timeline,
            WarrenRemoteAgentCapability.interactions,
            WarrenRemoteAgentCapability.interrupt,
            WarrenRemoteAgentCapability.attachments,
            WarrenRemoteAgentCapability.goals,
        ]
    ) async throws -> String {
        guard !isClosed else { throw WarrenRemoteClientError.closed }
        await adapter.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        var auth: [String: Any] = [
            "t": "auth",
            "version": WarrenRemoteClient.protocolVersion,
            "capabilities": capabilities,
            "terminalStateFormats": terminalStateFormats.sorted(),
        ]
        if isRelay {
            auth["access_token"] = token
            if let clientID, !clientID.isEmpty { auth["client_id"] = clientID }
        } else {
            auth["token"] = token
        }
        let authPayload = Self.json(auth)
        let authByteCount = authPayload.utf8.count
        guard authByteCount <= WarrenRemoteClient.maximumJSONMessageBytes else {
            throw WarrenRemoteClientError.messageTooLarge(
                kind: "JSON auth",
                actual: authByteCount,
                limit: WarrenRemoteClient.maximumJSONMessageBytes
            )
        }
        // URLSession's async send can remain suspended while a daemon is
        // replacing its listener during a Ghostline handoff. Run it as an
        // unstructured task so the welcome timeout below remains a hard
        // deadline even when the adapter does not promptly observe task
        // cancellation. `fail` closes the adapter on either send failure or
        // timeout, allowing the outer connection loop to create a fresh
        // socket and retry.
        let authSendTask = Task { [weak self] in
            do {
                try await self?.adapter.send(.text(authPayload))
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail(error)
            }
        }
        defer { authSendTask.cancel() }

        do {
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
        } catch {
            fail(error)
            throw error
        }
    }

    func replicaIdentity() -> (hostID: String, accessScopeID: String)? {
        guard let welcomeHostID, let welcomeAccessScopeID,
              !welcomeHostID.isEmpty, !welcomeAccessScopeID.isEmpty else { return nil }
        return (welcomeHostID, welcomeAccessScopeID)
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
		var jsonParams: [String: String] = [:]
		for (key, value) in params { jsonParams[key] = value }
		let data = (try? JSONSerialization.data(withJSONObject: jsonParams)) ?? Data("{}".utf8)
		return try await request(method, paramsData: data)
	}

	func request(_ method: String, paramsData: Data) async throws -> Data {
        guard !isClosed else { throw WarrenRemoteClientError.closed }
        guard paramsData.count <= WarrenRemoteClient.maximumJSONMessageBytes else {
            throw WarrenRemoteClientError.messageTooLarge(
                kind: "JSON request parameters",
                actual: paramsData.count,
                limit: WarrenRemoteClient.maximumJSONMessageBytes
            )
        }
        let id = UUID().uuidString.lowercased()
        let text = Self.json([
            "t": "request",
            "id": id,
            "method": method,
            "params": (try? JSONSerialization.jsonObject(with: paramsData)) ?? [:],
        ])
        let textByteCount = text.utf8.count
        guard textByteCount <= WarrenRemoteClient.maximumJSONMessageBytes else {
            throw WarrenRemoteClientError.messageTooLarge(
                kind: "JSON request",
                actual: textByteCount,
                limit: WarrenRemoteClient.maximumJSONMessageBytes
            )
        }
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
        guard bytes.count <= codec.maximumEnvelopeBytes else {
            throw WarrenRemoteClientError.messageTooLarge(
                kind: "DENB",
                actual: bytes.count,
                limit: codec.maximumEnvelopeBytes
            )
        }
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
                    guard bytes.count <= codec.maximumEnvelopeBytes else {
                        throw WarrenRemoteClientError.messageTooLarge(
                            kind: "DENB",
                            actual: bytes.count,
                            limit: codec.maximumEnvelopeBytes
                        )
                    }
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
                        guard terminalStateFormats.contains(frame.header.format) else {
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
                    let byteCount = text.utf8.count
                    guard byteCount <= WarrenRemoteClient.maximumJSONMessageBytes else {
                        throw WarrenRemoteClientError.messageTooLarge(
                            kind: "JSON",
                            actual: byteCount,
                            limit: WarrenRemoteClient.maximumJSONMessageBytes
                        )
                    }
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
        guard data.count <= WarrenRemoteClient.maximumJSONMessageBytes else {
            throw WarrenRemoteClientError.messageTooLarge(
                kind: "JSON",
                actual: data.count,
                limit: WarrenRemoteClient.maximumJSONMessageBytes
            )
        }
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
            guard WarrenRemoteClient.compatibleProtocolVersion(version, with: WarrenRemoteClient.protocolVersion) else {
                let error = WarrenRemoteClientError.incompatibleProtocol(expected: WarrenRemoteClient.protocolVersion, received: version)
                if let welcomeContinuation {
                    self.welcomeContinuation = nil
                    welcomeContinuation.resume(throwing: error)
                } else {
                    welcomeResult = .failure(error)
                }
                throw error
            }
            guard let host = object["host"] as? [String: Any],
                  let hostID = host["id"] as? String, !hostID.isEmpty,
                  let accessScopeID = object["accessScopeId"] as? String,
                  !accessScopeID.isEmpty else {
                let error = WarrenRemoteClientError.invalidResponse
                if let welcomeContinuation {
                    self.welcomeContinuation = nil
                    welcomeContinuation.resume(throwing: error)
                } else {
                    welcomeResult = .failure(error)
                }
                throw error
            }
            welcomeHostID = hostID
            welcomeAccessScopeID = accessScopeID
            if let welcomeContinuation {
                self.welcomeContinuation = nil
                welcomeContinuation.resume(returning: version)
            } else {
                welcomeResult = .success(version)
            }
            let capabilities = (object["capabilities"] as? [String]) ?? []
            _ = continuation?.yield(.welcome(version: version, capabilities: capabilities))
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
                let code = object["code"] as? String
                let details: [String: WarrenRemoteJSONValue]? = {
                    guard let raw = object["details"],
                          JSONSerialization.isValidJSONObject(raw),
                          let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                    return try? JSONDecoder().decode([String: WarrenRemoteJSONValue].self, from: data)
                }()
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
                if let code, !code.isEmpty {
                    requests.removeValue(forKey: id)?.resume(throwing: WarrenRemoteClientError.requestFailedWithCode(code: code, message: message, details: details))
                } else {
                    requests.removeValue(forKey: id)?.resume(throwing: WarrenRemoteClientError.requestFailed(message))
                }
            }
        case "error":
            // Headless uses `error`; Relay's upgrade boundary uses `message`.
            // Preserve the server's reason so a rejected ticket, offline Host,
            // or expired capability is actionable in the mobile connection
            // banner instead of collapsing everything into one generic error.
            let message = object["error"] as? String
                ?? object["message"] as? String
                ?? "Remote authentication failed"
            let error: WarrenRemoteClientError
            if message.hasPrefix("incompatible protocol version:") || message.hasPrefix("upgrade required:") {
                error = .upgradeRequired(message)
            } else {
                error = .authenticationFailed(message)
            }
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
        case "agent.events":
            guard let streamID = object["streamId"] as? String,
                  let executionID = object["executionId"] as? String,
                  let rawEvents = object["events"] as? [Any],
                  !streamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !executionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WarrenRemoteClientError.invalidResponse
            }
            guard data.count <= WarrenRemoteClient.maximumAgentEventBatchBytes else {
                throw WarrenRemoteClientError.messageTooLarge(
                    kind: "Agent event batch",
                    actual: data.count,
                    limit: WarrenRemoteClient.maximumAgentEventBatchBytes
                )
            }
            guard rawEvents.count <= WarrenRemoteClient.maximumAgentEventCount else {
                throw WarrenRemoteClientError.messageTooLarge(
                    kind: "Agent event batch",
                    actual: rawEvents.count,
                    limit: WarrenRemoteClient.maximumAgentEventCount
                )
            }
            // Canonical event decoding is strict: a malformed row invalidates
            // the batch because sequence continuity is part of the contract.
            let events: [WarrenRemoteAgentEvent]
            do {
                events = try rawEvents.map { value in
                    guard JSONSerialization.isValidJSONObject(value) else {
                        throw WarrenRemoteClientError.invalidResponse
                    }
                    let encoded = try JSONSerialization.data(withJSONObject: value)
                    guard encoded.count <= WarrenRemoteClient.maximumAgentEventBytes else {
                        throw WarrenRemoteClientError.messageTooLarge(
                            kind: "Agent event",
                            actual: encoded.count,
                            limit: WarrenRemoteClient.maximumAgentEventBytes
                        )
                    }
                    return try JSONDecoder().decode(WarrenRemoteAgentEvent.self, from: encoded)
                }
            } catch let error as WarrenRemoteClientError {
                if case .messageTooLarge = error { throw error }
                throw WarrenRemoteClientError.invalidResponse
            } catch {
                // A malformed batch cannot be sequence-repaired safely. Fail
                // the socket so the connection loop closes this replica and
                // reconnects through the normal bounded history handshake.
                throw WarrenRemoteClientError.invalidResponse
            }
            _ = continuation?.yield(.agentEvents(
                streamID: streamID,
                executionID: executionID,
                events: events
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
    public static let replayTerminalStateFormat = "ghostline-vt-replay-v1"
    public static let snapshotTerminalStateFormat = "ghostty-vt-snapshot-v1"
    public static let protocolVersion = "4.0"
    /// Control JSON is deliberately smaller than the largest binary DENB
    /// snapshot. These limits are enforced before JSON decoding and again at
    /// the Agent event boundary so a malformed peer cannot grow one batch or
    /// one event without bound.
    public static let maximumJSONMessageBytes = 8 * 1024 * 1024
    public static let maximumAgentEventBatchBytes = 8 * 1024 * 1024
    public static let maximumAgentEventCount = 512
    public static let maximumAgentEventBytes = 1 * 1024 * 1024

    private struct Subscription: Sendable {
        let size: TerminalSize?
        let claimControl: Bool
        let attachmentID: String?
        let generation: UInt64
    }

    private let configuration: WarrenRemoteEndpointConfiguration
    private let urlSession: URLSession
    private var accessToken: String
    private let advertisedCapabilities: [String]
    private var refreshToken: String?  // OAuth2-style refresh token for Relay
    private let refreshTokenHandler: (@Sendable (String) -> Void)?
    private let tokenUpdateHandler: (@Sendable (String, String?) -> Void)?
    /// Native pairing supplies a stable device identity so Relay capabilities
    /// remain bound to the same client across reconnects. Keeping this
    /// optional preserves compatibility with older capabilities that have no
    /// client_id claim.
    private let clientID: String?
    /// Scripted adapters consumed in order, one per connection attempt. A queue
    /// rather than a single value so a test can drive a reconnect, which is the
    /// only point where retained subscription intent is replayed.
    private var injectedTasks: [any WarrenWebSocketTaskAdapter] = []
    private let codec: WarrenWireCodec
    private let terminalStateFormats: Set<String>
    private let eventStream: AsyncStream<WarrenRemoteEvent>
    private var eventContinuation: AsyncStream<WarrenRemoteEvent>.Continuation?
    private var connectionTask: Task<Void, Never>?
    private var socket: WarrenRemoteSocket?
    private var running = false
    private var connectionState: WarrenRemoteConnectionState = .stopped
    private var rosterStorage: WarrenRemoteRoster?
    private var hostIdentity: (hostID: String, accessScopeID: String)?
    private var negotiatedCapabilities: Set<String> = []
    private var anchors: [String: WarrenRemoteRecoveryAnchor] = [:]
    /// Subscriptions survive a socket replacement. They are deliberately
    /// separate from recovery anchors: the latter advance with every frame,
    /// while this table records the user's current visibility intent.
    private var subscriptions: [String: Subscription] = [:]
    private var subscriptionGeneration: UInt64 = 0
    /// The single Session whose control lease this client currently holds.
    ///
    /// `Subscription.claimControl` records what one `session.subscribe` asked
    /// for and never expires, so every Session that was ever selected keeps a
    /// historical claim. Replaying those on reconnect made the Host apply a
    /// focus handoff and a PTY resize per retained surface, which is both a
    /// visible reflow and a burst of contention on the Host. Focus is the
    /// authoritative lease transition, so track it separately and restore only
    /// the claim that is still live.
    private var controlSessionID: String?

    public init(
        configuration: WarrenRemoteEndpointConfiguration,
        urlSession: URLSession = WarrenRemoteNetworking.session,
        codec: WarrenWireCodec = WarrenWireCodec(),
        terminalStateFormats: [String] = [WarrenRemoteClient.replayTerminalStateFormat],
        clientID: String? = nil,
        refreshTokenHandler: (@Sendable (String) -> Void)? = nil,
        tokenUpdateHandler: (@Sendable (String, String?) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.accessToken = configuration.token
        // Extract refresh_token from endpoint metadata if available
        self.refreshToken = configuration.refreshToken
        self.refreshTokenHandler = refreshTokenHandler
        self.tokenUpdateHandler = tokenUpdateHandler
        self.advertisedCapabilities = [
            "roster-delta",
            WarrenRemoteAgentCapability.timeline,
            WarrenRemoteAgentCapability.interactions,
            WarrenRemoteAgentCapability.interrupt,
            WarrenRemoteAgentCapability.attachments,
            WarrenRemoteAgentCapability.goals,
        ]
        self.clientID = clientID ?? configuration.clientID
        self.codec = codec
        self.terminalStateFormats = Set(terminalStateFormats.filter { !$0.isEmpty })
        let pair = AsyncStream<WarrenRemoteEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4096)
        )
        self.eventStream = pair.stream
        self.eventContinuation = pair.continuation
    }

    /// Injection initializer for scripted WebSocket and protocol tests.
    public init(
        configuration: WarrenRemoteEndpointConfiguration,
        task: any WarrenWebSocketTaskAdapter,
        codec: WarrenWireCodec = WarrenWireCodec(),
        capabilities: [String] = ["roster-delta"],
        terminalStateFormats: [String] = [WarrenRemoteClient.replayTerminalStateFormat],
        urlSession: URLSession = WarrenRemoteNetworking.session,
        clientID: String? = nil,
        refreshTokenHandler: (@Sendable (String) -> Void)? = nil,
        tokenUpdateHandler: (@Sendable (String, String?) -> Void)? = nil
    ) {
        self.init(
            configuration: configuration,
            tasks: [task],
            codec: codec,
            capabilities: capabilities,
            terminalStateFormats: terminalStateFormats,
            urlSession: urlSession,
            clientID: clientID,
            refreshTokenHandler: refreshTokenHandler,
            tokenUpdateHandler: tokenUpdateHandler
        )
    }

    /// Injection initializer that scripts several connection attempts. Each
    /// adapter serves one attempt, so a test can observe what the client replays
    /// onto the replacement socket.
    public init(
        configuration: WarrenRemoteEndpointConfiguration,
        tasks: [any WarrenWebSocketTaskAdapter],
        codec: WarrenWireCodec = WarrenWireCodec(),
        capabilities: [String] = ["roster-delta"],
        terminalStateFormats: [String] = [WarrenRemoteClient.replayTerminalStateFormat],
        urlSession: URLSession = WarrenRemoteNetworking.session,
        clientID: String? = nil,
        refreshTokenHandler: (@Sendable (String) -> Void)? = nil,
        tokenUpdateHandler: (@Sendable (String, String?) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.accessToken = configuration.token
        self.refreshToken = configuration.refreshToken
        self.refreshTokenHandler = refreshTokenHandler
        self.tokenUpdateHandler = tokenUpdateHandler
        self.advertisedCapabilities = capabilities
        self.clientID = clientID ?? configuration.clientID
        self.injectedTasks = tasks
        self.codec = codec
        self.terminalStateFormats = Set(terminalStateFormats.filter { !$0.isEmpty })
        let pair = AsyncStream<WarrenRemoteEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4096)
        )
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
    public func replicaNamespace() -> (hostID: String, accessScopeID: String)? { hostIdentity }
    public func recoveryAnchor(for sessionID: String) -> WarrenRemoteRecoveryAnchor? { anchors[sessionID] }

    /// Capabilities returned by the latest authenticated Host welcome. A
    /// reconnect replaces this set; callers should hide controls while the
    /// connection is negotiating rather than assuming a previous Host's
    /// capabilities still apply.
    public func capabilities() -> Set<String> { negotiatedCapabilities }

    public func supportsCapability(_ capability: String) -> Bool {
        negotiatedCapabilities.contains(capability)
    }

    public func request(_ method: String, params: [String: String] = [:]) async throws -> Data {
        guard let socket else { throw WarrenRemoteClientError.notConnected }
        return try await request(on: socket, method: method, params: params)
    }

    /// JSON-shaped request parameters for structured Agent View operations.
    /// The string overload above remains source-compatible with existing
    /// terminal calls.
    public func request(_ method: String, jsonParams: [String: Any] = [:]) async throws -> Data {
        guard let socket else { throw WarrenRemoteClientError.notConnected }
        let data = (try? JSONSerialization.data(withJSONObject: jsonParams)) ?? Data("{}".utf8)
        return try await request(on: socket, method: method, paramsData: data)
    }

    public func request<Value: Decodable>(
        _ method: String,
        params: [String: String] = [:],
        decoding type: Value.Type = Value.self
    ) async throws -> Value {
        let data = try await request(method, params: params)
        return try decode(data, as: type)
    }

    public func request<Value: Decodable>(
        _ method: String,
        jsonParams: [String: Any] = [:],
        decoding type: Value.Type = Value.self
    ) async throws -> Value {
        let data = try await request(method, jsonParams: jsonParams)
        return try decode(data, as: type)
    }

    /// Registers an ActivityKit push token with the Relay. This HTTP call is
    /// intentionally independent from the WebSocket connection: iOS may
    /// suspend the app immediately after the Activity is created.
    @discardableResult
    public func registerLiveActivityPushToken(sessionID: String, token: String) async throws -> Bool {
        guard configuration.isRelay else { throw WarrenRemoteClientError.invalidEndpoint }
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionID,
            "push_token": token,
        ])
        let response = try await relayLiveActivityRequest(
            method: "POST",
            body: data,
            retryAfterRefresh: true
        )
        guard let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              value["registered"] as? Bool == true else {
            throw WarrenRemoteClientError.invalidResponse
        }
        return true
    }

    /// Removes a previously registered ActivityKit token. A best-effort
    /// caller may ignore failures when the Relay is already offline.
    @discardableResult
    public func unregisterLiveActivityPushToken(sessionID: String, token: String) async throws -> Bool {
        guard configuration.isRelay else { throw WarrenRemoteClientError.invalidEndpoint }
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionID,
            "push_token": token,
        ])
        let response = try await relayLiveActivityRequest(
            method: "DELETE",
            body: data,
            retryAfterRefresh: true
        )
        guard let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw WarrenRemoteClientError.invalidResponse
        }
        return value["unregistered"] as? Bool == true
    }

    private func relayLiveActivityRequest(
        method: String,
        body: Data,
        retryAfterRefresh: Bool
    ) async throws -> Data {
        guard let url = configuration.relayLiveActivityRegistrationURL else {
            throw WarrenRemoteClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WarrenRemoteClientError.invalidResponse
        }
        if http.statusCode == 401, retryAfterRefresh,
           await refreshRelayAccessToken() {
            return try await relayLiveActivityRequest(
                method: method,
                body: body,
                retryAfterRefresh: false
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail?.isEmpty == false ? detail! : "HTTP \(http.statusCode)"
            throw WarrenRemoteClientError.requestFailed("Relay live activity request failed: \(message)")
        }
        return data
    }

    /// Creates a Host-owned session in a workspace, terminal group, or the
    /// Host's default terminal group when neither scope is supplied.
    @discardableResult
    public func createSession(
        workspaceID: String? = nil,
        terminalGroupID: String? = nil,
        command: String? = nil,
        kind: String? = nil,
        agentHandler: String? = nil,
        title: String? = nil,
        runtimeKind: String? = nil
    ) async throws -> WarrenRemoteSession {
        var params: [String: String] = [:]
        if let workspaceID, !workspaceID.isEmpty { params["workspace"] = workspaceID }
        if let terminalGroupID, !terminalGroupID.isEmpty { params["group"] = terminalGroupID }
        if let command { params["command"] = command }
        if let kind { params["kind"] = kind }
        if let agentHandler { params["agentHandler"] = agentHandler }
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

    private func request(
        on socket: WarrenRemoteSocket,
        method: String,
        paramsData: Data
    ) async throws -> Data {
        try await socket.request(method, paramsData: paramsData)
    }

    private func request<Value: Decodable>(
        _ method: String,
        jsonData: Data,
        decoding type: Value.Type
    ) async throws -> Value {
        guard let socket else { throw WarrenRemoteClientError.notConnected }
        let data = try await request(on: socket, method: method, paramsData: jsonData)
        return try decode(data, as: type)
    }

    private func decode<Value: Decodable>(_ data: Data, as type: Value.Type) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw WarrenRemoteClientError.invalidResponse
        }
    }

    private func jsonObject<Value: Encodable>(_ value: Value) -> Data {
        guard let data = try? JSONEncoder().encode(value),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return Data("{}".utf8)
        }
        return data
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
            subscriptionGeneration &+= 1
            subscriptions[sessionID] = Subscription(
                size: size,
                claimControl: claimControl,
                attachmentID: nil,
                generation: subscriptionGeneration
            )
            if claimControl {
                controlSessionID = sessionID
            } else if controlSessionID == sessionID {
                controlSessionID = nil
            }
        }
        let intentGeneration = subscriptions[sessionID]?.generation
        let data: Data
        if let socket { data = try await request(on: socket, method: "session.subscribe", params: params) }
        else { data = try await request("session.subscribe", params: params) }
        let result = try decode(data, as: WarrenRemoteSubscriptionResult.self)
        // A restore request may complete after the UI unsubscribed the
        // Session. Do not resurrect that intent (or its attachment) on a
        // late response; only update an intent that still has the same token.
        if let intentGeneration,
           subscriptions[sessionID]?.generation == intentGeneration {
            subscriptions[sessionID] = Subscription(
                size: size,
                claimControl: claimControl,
                attachmentID: result.attachmentID,
                generation: intentGeneration
            )
        }
        return result
    }

    @discardableResult
    public func unsubscribe(sessionID: String) async throws -> Bool {
        // Remove the local visibility intent before waiting for the Host. If
        // the socket is already down there is no request to send, but a later
        // reconnect must still not resurrect a Session the user left.
        subscriptionGeneration &+= 1
        subscriptions.removeValue(forKey: sessionID)
        if controlSessionID == sessionID {
            controlSessionID = nil
        }
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
        size: TerminalSize? = nil,
        agentOnly: Bool = false
    ) async throws -> WarrenRemoteFocusResult {
        var params = ["id": sessionID, "focused": focused ? "true" : "false"]
        if agentOnly { params["agent"] = "true" }
        if focused, let size {
            params["cols"] = String(size.columns)
            params["rows"] = String(size.rows)
        }
        // An Agent-only focus is acknowledged without taking the terminal PTY
        // lease, so it must not change which subscription a reconnect reclaims.
        // A release is recorded before the request: if it fails in transit the
        // Host drops the lease when the socket does, and reclaiming it on the
        // next socket would resize a runtime this client no longer drives.
        if !agentOnly, !focused, controlSessionID == sessionID {
            controlSessionID = nil
        }
        let result = try await request(
            "session.focus",
            params: params,
            decoding: WarrenRemoteFocusResult.self
        )
        if !agentOnly, focused, result.focused {
            controlSessionID = sessionID
            if let size { recordSubscribedSize(size, for: sessionID) }
        }
        return result
    }

    /// Keeps the recorded viewport aligned with the last size this client asked
    /// the Host to apply. A reconnect replays it with the control claim, so a
    /// stale value would revert the runtime to an earlier geometry.
    private func recordSubscribedSize(_ size: TerminalSize, for sessionID: String) {
        guard let current = subscriptions[sessionID], current.size != size else { return }
        subscriptions[sessionID] = Subscription(
            size: size,
            claimControl: current.claimControl,
            attachmentID: current.attachmentID,
            generation: current.generation
        )
    }

    /// Promotes the existing terminal subscription to the focused control
    /// lease. Agent-only surfaces use this just-in-time before an interrupt;
    /// the protocol has no control-only attach alias.
    @discardableResult
    public func claimControl(sessionID: String) async throws -> Bool {
        let result = try await focus(sessionID: sessionID, focused: true, agentOnly: true)
        return result.focused
    }

    @discardableResult
    public func resize(sessionID: String, size: TerminalSize) async throws -> Bool {
        let result = try await request(
            "session.resize",
            params: [
                "id": sessionID,
                "cols": String(size.columns),
                "rows": String(size.rows),
            ],
            decoding: [String: Bool].self
        )
        let resized = result["resized"] ?? false
        if resized { recordSubscribedSize(size, for: sessionID) }
        return resized
    }

    /// Sends one DENB input frame. The Host accepts it only while this client
    /// owns the focused control lease for the subscribed session.
    public func sendInput(sessionID: String, payload: Data) async throws {
        guard let socket else { throw WarrenRemoteClientError.notConnected }
        guard let subscription = subscriptions[sessionID],
              let attachmentID = subscription.attachmentID,
              let sessionUUID = UUID(uuidString: sessionID),
              let attachmentUUID = UUID(uuidString: attachmentID) else {
            throw WarrenRemoteClientError.requestFailed("terminal subscription is required before input")
        }
        guard let metadata = InputMetadata(
            sessionID: TerminalSessionID(rawValue: sessionUUID),
            attachmentID: TerminalAttachmentID(rawValue: attachmentUUID),
            payloadLength: payload.count
        ) else {
            throw WarrenRemoteClientError.invalidResponse
        }
        let bytes = try codec.encodeInput(metadata: metadata, payload: payload)
        try await socket.sendBinary(bytes)
    }

    @discardableResult
    public func prepareAgentAttachment(
        executionID: String,
        commandID: String,
        name: String,
        mime: String,
        size: Int64,
        sha256: String? = nil,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentAttachmentPrepareResult {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["name"] = name
        params["mime"] = mime
        params["size"] = size
        if let sha256 { params["sha256"] = sha256 }
        return try await request(
            "agent.attachment.prepare",
            jsonParams: params,
            decoding: WarrenRemoteAgentAttachmentPrepareResult.self
        )
    }

    @discardableResult
    public func uploadAgentAttachmentChunk(
        executionID: String,
        commandID: String,
        uploadID: String,
        chunk: UInt64,
        length: Int,
        sha256: String? = nil,
        data: String,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentAttachmentResult {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["uploadId"] = uploadID
        params["chunk"] = chunk
        params["length"] = length
        if let sha256 { params["sha256"] = sha256 }
        params["data"] = data
        return try await request(
            "agent.attachment.chunk",
            jsonParams: params,
            decoding: WarrenRemoteAgentAttachmentResult.self
        )
    }

    @discardableResult
    public func completeAgentAttachment(
        executionID: String,
        commandID: String,
        uploadID: String,
        length: Int64,
        sha256: String? = nil,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentAttachmentResult {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["uploadId"] = uploadID
        params["length"] = length
        if let sha256 { params["sha256"] = sha256 }
        return try await request(
            "agent.attachment.complete",
            jsonParams: params,
            decoding: WarrenRemoteAgentAttachmentResult.self
        )
    }

    @discardableResult
    public func abortAgentAttachment(
        executionID: String,
        commandID: String,
        uploadID: String,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentAttachmentResult {
        let params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        ).merging(["uploadId": uploadID]) { _, new in new }
        return try await request(
            "agent.attachment.abort",
            jsonParams: params,
            decoding: WarrenRemoteAgentAttachmentResult.self
        )
    }

    // MARK: - Canonical Agent API

    private static func validateAgentEventBatch(
        _ events: [WarrenRemoteAgentEvent]
    ) throws {
        guard events.count <= maximumAgentEventCount else {
            throw WarrenRemoteClientError.messageTooLarge(
                kind: "Agent event batch",
                actual: events.count,
                limit: maximumAgentEventCount
            )
        }
        for event in events {
            guard let encoded = try? JSONEncoder().encode(event) else {
                throw WarrenRemoteClientError.invalidResponse
            }
            guard encoded.count <= maximumAgentEventBytes else {
                throw WarrenRemoteClientError.messageTooLarge(
                    kind: "Agent event",
                    actual: encoded.count,
                    limit: maximumAgentEventBytes
                )
            }
        }
    }

    public func agentExecution(
        executionID: String
    ) async throws -> WarrenRemoteAgentExecution {
        try await request(
            "agent.execution.get",
            jsonParams: ["executionId": executionID],
            decoding: WarrenRemoteAgentExecution.self
        )
    }

    public func agentEventsHistory(
        streamID: String,
        afterSequence: UInt64? = nil,
        beforeSequence: UInt64? = nil,
        limit: Int = 200
    ) async throws -> WarrenRemoteAgentEventsHistoryResult {
        var params: [String: Any] = ["streamId": streamID, "limit": limit]
        if let afterSequence { params["afterSequence"] = afterSequence }
        if let beforeSequence { params["beforeSequence"] = beforeSequence }
        let result: WarrenRemoteAgentEventsHistoryResult = try await request(
            "agent.events.history",
            jsonParams: params,
            decoding: WarrenRemoteAgentEventsHistoryResult.self
        )
        try Self.validateAgentEventBatch(result.events)
        return result
    }

    public func subscribeAgentEvents(
        streamID: String,
        afterSequence: UInt64 = 0,
        limit: Int = 200
    ) async throws -> WarrenRemoteAgentEventsSubscriptionResult {
        let result: WarrenRemoteAgentEventsSubscriptionResult = try await request(
            "agent.events.subscribe",
            jsonParams: [
                "streamId": streamID,
                "afterSequence": afterSequence,
                "limit": limit,
            ],
            decoding: WarrenRemoteAgentEventsSubscriptionResult.self
        )
        try Self.validateAgentEventBatch(result.events)
        return result
    }

    public func resumeAgentExecution(
        executionID: String,
        commandID: String,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentCommandReceipt {
        try await request(
            "agent.execution.resume",
            jsonParams: canonicalCommandParams(
                commandID: commandID,
                executionID: executionID,
                expectedVersion: expectedVersion,
                leaseID: leaseID
            ),
            decoding: WarrenRemoteAgentCommandReceipt.self
        )
    }

    public func startAgentTurn(
        executionID: String,
        commandID: String,
        text: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = [],
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentCommandReceipt {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["text"] = text
        if !attachments.isEmpty { params["attachments"] = jsonCompatible(attachments) }
        return try await request("agent.turn.start", jsonParams: params, decoding: WarrenRemoteAgentCommandReceipt.self)
    }

    public func steerAgentTurn(
        executionID: String,
        commandID: String,
        turnID: String,
        text: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = [],
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentCommandReceipt {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["turnId"] = turnID
        params["text"] = text
        if !attachments.isEmpty { params["attachments"] = jsonCompatible(attachments) }
        return try await request("agent.turn.steer", jsonParams: params, decoding: WarrenRemoteAgentCommandReceipt.self)
    }

    public func cancelAgentTurn(
        executionID: String,
        commandID: String,
        turnID: String,
        reason: String? = nil,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentCommandReceipt {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["turnId"] = turnID
        if let reason, !reason.isEmpty { params["reason"] = reason }
        return try await request("agent.turn.cancel", jsonParams: params, decoding: WarrenRemoteAgentCommandReceipt.self)
    }

    public func resolveAgentInteraction(
        executionID: String,
        commandID: String,
        interactionID: String,
        version: UInt64,
        resolution: [String: WarrenRemoteJSONValue],
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentCommandReceipt {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["interactionId"] = interactionID
        params["version"] = version
        params["resolution"] = jsonCompatible(resolution)
        return try await request("agent.interaction.resolve", jsonParams: params, decoding: WarrenRemoteAgentCommandReceipt.self)
    }

    public func setAgentGoal(
        executionID: String,
        commandID: String,
        objective: String,
        status: String? = nil,
        tokenBudget: Int64? = nil,
        replaceExisting: Bool = false,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentCommandReceipt {
        var params = canonicalCommandParams(
            commandID: commandID,
            executionID: executionID,
            expectedVersion: expectedVersion,
            leaseID: leaseID
        )
        params["objective"] = objective
        if let status, !status.isEmpty { params["status"] = status }
        if let tokenBudget { params["tokenBudget"] = tokenBudget }
        if replaceExisting { params["replaceExisting"] = true }
        return try await request("agent.goal.set", jsonParams: params, decoding: WarrenRemoteAgentCommandReceipt.self)
    }

    public func clearAgentGoal(
        executionID: String,
        commandID: String,
        expectedVersion: UInt64? = nil,
        leaseID: String? = nil
    ) async throws -> WarrenRemoteAgentCommandReceipt {
        return try await request(
            "agent.goal.clear",
            jsonParams: canonicalCommandParams(
                commandID: commandID,
                executionID: executionID,
                expectedVersion: expectedVersion,
                leaseID: leaseID
            ),
            decoding: WarrenRemoteAgentCommandReceipt.self
        )
    }

    private func canonicalCommandParams(
        commandID: String,
        executionID: String,
        expectedVersion: UInt64?,
        leaseID: String?
    ) -> [String: Any] {
        var params: [String: Any] = [
            "commandId": commandID,
            "executionId": executionID,
        ]
        if let expectedVersion { params["expectedVersion"] = expectedVersion }
        if let leaseID, !leaseID.isEmpty { params["leaseId"] = leaseID }
        return params
    }

    private func jsonCompatible<Value: Encodable>(_ value: Value) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }

    /// A deterministic exponential backoff shared by mobile and desktop
    /// clients. The first retry waits 500 ms and the delay caps at 30 s.
    public static func reconnectDelayMilliseconds(attempt: Int) -> Int {
        let bounded = min(max(attempt, 0), 6)
        return min(30_000, 500 * (1 << bounded))
    }

    public static func compatibleProtocolVersion(_ lhs: String, with rhs: String) -> Bool {
        lhs == rhs
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
            if !injectedTasks.isEmpty {
                adapter = injectedTasks.removeFirst()
            } else {
                adapter = WarrenRemoteSocket.adapter(
                    url: url,
                    session: urlSession,
                    maximumMessageSize: max(codec.maximumEnvelopeBytes, Self.maximumJSONMessageBytes)
                )
            }
            let socket = WarrenRemoteSocket(
                adapter: adapter,
                codec: codec,
                terminalStateFormats: terminalStateFormats
            )
            self.socket = socket
            negotiatedCapabilities = []
            let connectionStartedAt = ContinuousClock.now
            var refreshedAfterAuthenticationFailure = false
            do {
                let version = try await socket.connect(
                    token: accessToken,
                    isRelay: configuration.isRelay,
                    clientID: clientID,
                    capabilities: advertisedCapabilities
                )
                hostIdentity = await socket.replicaIdentity()
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
                if let error = error as? WarrenRemoteClientError,
                   error.requiresClientUpgrade {
                    if self.socket === socket { self.socket = nil }
                    await socket.close()
                    running = false
                    setConnectionState(.disconnected)
                    emit(.disconnected(reason: error.localizedDescription))
                    return
                }
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
        
        // Try OAuth2-style refresh_token first (preferred)
        if let refreshToken = refreshToken, !refreshToken.isEmpty {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                let body: [String: String] = ["refresh_token": refreshToken]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return false }
                
                let value = try JSONDecoder().decode(WarrenRelaySessionExchange.self, from: data)
                guard value.hostID == configuration.hostID,
                      !value.accessToken.isEmpty else { return false }
                
                accessToken = value.accessToken
                if let next = value.refreshToken, !next.isEmpty {
                    self.refreshToken = next
                    refreshTokenHandler?(next)
                    tokenUpdateHandler?(value.accessToken, next)
                } else {
                    tokenUpdateHandler?(value.accessToken, nil)
                }
                return true
            } catch {
                // OAuth2 refresh failed, fall back to cookie-based approach
            }
        }
        
        // Fallback: Cookie-based refresh (legacy)
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
            if let next = value.refreshToken, !next.isEmpty {
                refreshToken = next
                refreshTokenHandler?(next)
                tokenUpdateHandler?(value.accessToken, next)
            } else {
                tokenUpdateHandler?(value.accessToken, nil)
            }
            return true
        } catch {
            return false
        }
    }

    private func consume(_ event: WarrenRemoteSocketEvent, from socket: WarrenRemoteSocket) async {
        switch event {
        case .welcome(let version, let capabilities):
            negotiatedCapabilities = Set(capabilities)
            emit(.welcome(version: version))
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
        case .agentEvents(let streamID, let executionID, let events):
            emit(.agentEvents(streamID: streamID, executionID: executionID, events: events))
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
                  current.claimControl == subscription.claimControl,
                  current.generation == subscription.generation else { continue }
            // Restore visibility for every retained Session, but reclaim the
            // control lease only for the one that still holds it. A passive
            // restore also drops the viewport: the Host applies a size only
            // together with a claim, and sending one per Session would hand the
            // shared runtime a queue of conflicting SIGWINCHes.
            let claimsControl = sessionID == controlSessionID
            let size = claimsControl ? subscription.size : nil
            let anchor = anchors[sessionID]
            do {
                _ = try await subscribe(
                    sessionID: sessionID,
                    size: size,
                    anchor: anchor,
                    claimControl: claimsControl,
                    record: false,
                    socket: socket
                )
            } catch {
                // A Host may evict an old ring or cursor after a restart. In
                // that case the anchor is only a hint; retry without it so
				// protocol 4 can deliver a fresh atomic checkpoint. Other
                // failures (for example an ended Session) retain the intent
                // for a later roster/reconnect without issuing a second
                // request immediately.
                if anchor != nil,
                   Self.isRecoveryAnchorFailure(error),
                   running,
                   self.socket === socket,
                   subscriptions[sessionID]?.generation == subscription.generation {
                    _ = try? await subscribe(
                        sessionID: sessionID,
                        size: size,
                        anchor: nil,
                        claimControl: claimsControl,
                        record: false,
                        socket: socket
                    )
                }
            }
        }
    }

    private static func isRecoveryAnchorFailure(_ error: Error) -> Bool {
        guard case let WarrenRemoteClientError.requestFailed(message) = error else {
            if case let WarrenRemoteClientError.requestFailedWithCode(_, message, _) = error {
                let value = message.lowercased()
                return value.contains("anchor")
                    || value.contains("cursor")
                    || value.contains("epoch")
                    || value.contains("sequence")
                    || value.contains("recovery")
            }
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
