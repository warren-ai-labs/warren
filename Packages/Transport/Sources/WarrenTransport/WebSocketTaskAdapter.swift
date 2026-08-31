/// The transport's small message vocabulary keeps URLSession details at the
/// edge. Control is always text; PTY output is always binary.
/// A platform-neutral WebSocket message used by the remote client.
///
/// The type is public so iOS and integration tests can inject an alternate
/// WebSocket implementation without coupling the client to URLSession.
public enum WarrenWebSocketMessage: Hashable, Sendable {
    case text(String)
    case binary([UInt8])
}

/// The minimum surface needed by the client transport. All calls are async so
/// scripted actors and URLSession actors have the same isolation boundary.
public protocol WarrenWebSocketTaskAdapter: Sendable {
    func resume() async
    func cancel() async
    func send(_ message: WarrenWebSocketMessage) async throws
    /// Sends a protocol-level WebSocket ping. Adapters that cannot expose a
    /// native ping may use the no-op default; URLSession-backed clients
    /// override it so liveness checks never compete with application traffic.
    func ping() async throws
    func receive() async throws -> WarrenWebSocketMessage
}

public extension WarrenWebSocketTaskAdapter {
    func ping() async throws {}
}
