import Foundation
import WarrenDomain

/// Preserves callback order before terminal input crosses into Swift concurrency.
///
/// Ghostty emits bracketed paste as separate start, payload, and end writes.
/// Creating one unstructured task per write can reorder those fenceposts, so
/// callbacks append synchronously here and a single task drains them in FIFO
/// order off the main actor.
final class WarrenOrderedInputBridge: @unchecked Sendable {
    typealias Sink = @Sendable (Data) async -> Void

    private let lock = NSLock()
    private let sink: Sink
    private var pending = Data()
    private var isDrainScheduled = false

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        pending.append(data)
        let shouldSchedule = !isDrainScheduled
        if shouldSchedule {
            isDrainScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let data = takePending() {
            await sink(data)
        }
    }

    private func takePending() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard !pending.isEmpty else {
            isDrainScheduled = false
            return nil
        }
        let data = pending
        pending.removeAll(keepingCapacity: true)
        return data
    }
}

/// Routes terminal input without making a keystroke wait behind a MainActor
/// roster application. A surface can begin producing input before the daemon
/// grants the attachment control lease, so the router holds that short prefix
/// and drains it in FIFO order only after `activate`.
final class WarrenTerminalInputRouter: @unchecked Sendable {
    typealias Sender = @Sendable (Data) async -> Void

    private let lock = NSLock()
    private var sessionID: TerminalSessionID?
    private var sender: Sender?
    private var pending = Data()
    private var drainScheduled = false

    func prepare(for sessionID: TerminalSessionID) {
        lock.lock()
        self.sessionID = sessionID
        sender = nil
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func activate(for sessionID: TerminalSessionID, sender: @escaping Sender) {
        lock.lock()
        guard self.sessionID == sessionID else {
            lock.unlock()
            return
        }
        self.sender = sender
        let shouldSchedule = scheduleDrainLocked()
        lock.unlock()
        if shouldSchedule { startDrain() }
    }

    func enqueue(_ data: Data, for sessionID: TerminalSessionID) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard self.sessionID == sessionID else {
            lock.unlock()
            return
        }
        pending.append(data)
        let shouldSchedule = scheduleDrainLocked()
        lock.unlock()
        if shouldSchedule { startDrain() }
    }

    func discard(for sessionID: TerminalSessionID) {
        lock.lock()
        guard self.sessionID == sessionID else {
            lock.unlock()
            return
        }
        self.sessionID = nil
        sender = nil
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func scheduleDrainLocked() -> Bool {
        guard !drainScheduled, sender != nil, !pending.isEmpty else { return false }
        drainScheduled = true
        return true
    }

    private func startDrain() {
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let (data, sender) = takePending() {
            await sender(data)
        }
    }

    private func takePending() -> (Data, Sender)? {
        lock.lock()
        defer { lock.unlock() }
        guard let sender, !pending.isEmpty else {
            drainScheduled = false
            return nil
        }
        let data = pending
        pending.removeAll(keepingCapacity: true)
        return (data, sender)
    }
}
