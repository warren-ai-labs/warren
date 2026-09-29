@testable import WarrenTransport

enum ScriptedWebSocketTaskError: Error, Equatable, Sendable {
    case notResumed
    case cancelled
    case receiveAlreadyPending
    case scriptedFailure
}

/// Test-only fake. Keeping it in the test target prevents production API from
/// acquiring scripted-state and failure concepts.
actor ScriptedWebSocketTask: WarrenWebSocketTaskAdapter {
    private var incoming: [WarrenWebSocketMessage] = []
    private var waiter: CheckedContinuation<WarrenWebSocketMessage, Error>?
    private var receiveError: ScriptedWebSocketTaskError?
    private var resumed = false
    private var cancelled = false
    private var sent: [WarrenWebSocketMessage] = []
    private var resumeCount = 0
    private var cancelCount = 0
    private var receiveCount = 0
    private var activeReceiveCount = 0
    private var maximumConcurrentReceives = 0
    private var receiveStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var pingsHang = false
    private var pingWaiters: [CheckedContinuation<Void, Error>] = []

    func resume() async {
        guard !cancelled else { return }
        resumed = true
        resumeCount += 1
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        cancelCount += 1
        resumeWaiter(throwing: ScriptedWebSocketTaskError.cancelled)
        let pings = pingWaiters
        pingWaiters.removeAll()
        pings.forEach { $0.resume(throwing: ScriptedWebSocketTaskError.cancelled) }
    }

    /// Models a half-open socket: the pong never arrives, and the ping only
    /// completes once the task is torn down.
    func ping() async throws {
        guard pingsHang else { return }
        guard !cancelled else { throw ScriptedWebSocketTaskError.cancelled }
        try await withCheckedThrowingContinuation { pingWaiters.append($0) }
    }

    func hangPings() {
        pingsHang = true
    }

    func send(_ message: WarrenWebSocketMessage) async throws {
        guard resumed else { throw ScriptedWebSocketTaskError.notResumed }
        guard !cancelled else { throw ScriptedWebSocketTaskError.cancelled }
        sent.append(message)
    }

    func receive() async throws -> WarrenWebSocketMessage {
        receiveCount += 1
        activeReceiveCount += 1
        maximumConcurrentReceives = max(maximumConcurrentReceives, activeReceiveCount)
        resumeReceiveStartedWaiters()
        do {
            if !incoming.isEmpty {
                let message = incoming.removeFirst()
                activeReceiveCount -= 1
                return message
            }
            if let receiveError { throw receiveError }
            if cancelled { throw ScriptedWebSocketTaskError.cancelled }
            guard waiter == nil else { throw ScriptedWebSocketTaskError.receiveAlreadyPending }

            let message = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    if !incoming.isEmpty {
                        continuation.resume(returning: incoming.removeFirst())
                    } else if let receiveError {
                        continuation.resume(throwing: receiveError)
                    } else if cancelled {
                        continuation.resume(throwing: ScriptedWebSocketTaskError.cancelled)
                    } else {
                        waiter = continuation
                    }
                }
            }, onCancel: {
                Task { await self.cancel() }
            })
            activeReceiveCount -= 1
            return message
        } catch {
            activeReceiveCount -= 1
            throw error
        }
    }

    func enqueue(_ message: WarrenWebSocketMessage) {
        guard !cancelled, receiveError == nil else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            incoming.append(message)
        }
    }

    func failReceive() {
        failReceive(with: .scriptedFailure)
    }

    func failReceive(with error: ScriptedWebSocketTaskError) {
        guard !cancelled else { return }
        receiveError = error
        resumeWaiter(throwing: error)
    }

    func waitUntilReceiveCalled() async {
        guard receiveCount == 0 else { return }
        await withCheckedContinuation { continuation in
            receiveStartedWaiters.append(continuation)
        }
    }

    var sentMessages: [WarrenWebSocketMessage] { sent }
    var resumeCallCount: Int { resumeCount }
    var cancelCallCount: Int { cancelCount }
    var receiveCallCount: Int { receiveCount }
    var maximumConcurrentReceiveCount: Int { maximumConcurrentReceives }

    private func resumeWaiter(throwing error: ScriptedWebSocketTaskError) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: error)
    }

    private func resumeReceiveStartedWaiters() {
        let waiters = receiveStartedWaiters
        receiveStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
