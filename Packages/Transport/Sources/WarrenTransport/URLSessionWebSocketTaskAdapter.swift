import Foundation

public enum WarrenWebSocketTaskAdapterError: Error, Equatable, Sendable {
    case invalidIncomingMessage
}

/// Actor-isolated wrapper around URLSession's task. The task never crosses the
/// adapter's isolation boundary, and the core codec only sees `[UInt8]`.
public actor URLSessionWebSocketTaskAdapter: WarrenWebSocketTaskAdapter {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func resume() async {
        task.resume()
    }

    public func cancel() async {
        task.cancel(with: .normalClosure, reason: nil)
    }

    public func send(_ message: WarrenWebSocketMessage) async throws {
        switch message {
        case .text(let value):
            try await task.send(.string(value))
        case .binary(let value):
            try await task.send(.data(Data(value)))
        }
    }

    public func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    public func receive() async throws -> WarrenWebSocketMessage {
        switch try await task.receive() {
        case .string(let value):
            return .text(value)
        case .data(let value):
            return .binary(Array(value))
        @unknown default:
            throw WarrenWebSocketTaskAdapterError.invalidIncomingMessage
        }
    }
}
