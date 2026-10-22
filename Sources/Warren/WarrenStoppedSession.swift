import Foundation

/// What the Host kept of one stopped Session's last output.
///
/// A stopped Session has no runtime to subscribe to, so its pane has exactly
/// three states: the output is loading, the Host answered with the bytes it
/// kept, or the read failed and can be retried.
struct WarrenStoppedSessionHistory: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed(String)
    }

    let phase: Phase
    /// The terminal output the Host kept, from the runtime's first byte. Empty
    /// when the runtime kept none, which is a stopped Tab with nothing to show
    /// rather than an error.
    let payload: Data

    static let loading = WarrenStoppedSessionHistory(phase: .loading, payload: Data())

    static func ready(_ payload: Data) -> WarrenStoppedSessionHistory {
        WarrenStoppedSessionHistory(phase: .ready, payload: payload)
    }

    static func failed(_ message: String) -> WarrenStoppedSessionHistory {
        WarrenStoppedSessionHistory(phase: .failed(message), payload: Data())
    }

    var isLoading: Bool { phase == .loading }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// The line a stopped pane shows in place of output.
    var emptyLabel: String? {
        guard phase == .ready, payload.isEmpty else { return nil }
        return "No output was kept for this Session."
    }
}

/// The Host's answer to `session.history`.
struct WarrenStoppedSessionHistoryPayload: Decodable {
    let payload: String?
    let truncated: Bool?
}
