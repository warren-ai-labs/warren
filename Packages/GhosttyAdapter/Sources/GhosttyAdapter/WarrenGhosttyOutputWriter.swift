import Foundation
import GhosttyTerminal

/// Outcome of a non-blocking native snapshot installation attempt.
public enum TerminalSnapshotRestoreResult: Equatable, Sendable {
    /// Ghostty accepted the snapshot and the writer advanced its anchor.
    case restored
    /// A live output drain owns the feed lock; retry without blocking the main actor.
    case feedBusy
    /// The surface or snapshot was rejected by the native restore path.
    case rejected
}

/// Feeds Host output into one Ghostty surface off the main thread.
///
/// Ghostty's own terminal reads PTY bytes on a background termio thread and
/// only hops to the main thread to present. Warren's renderer previously
/// forwarded every output chunk on the main actor, so a streaming agent
/// saturated the same thread that also handles trackpad scroll events —
/// scroll input had to wait behind ANSI parsing. This writer keeps an ordered
/// pending buffer and drains it on a utility-priority detached task, matching
/// Ghostty's real-world input-to-render pipeline.
public final class WarrenGhosttyOutputWriter: @unchecked Sendable {
    /// Called after bytes are accepted by the in-memory terminal. The surface
    /// uses this hook to request a display tick when output arrives while the
    /// view is being remounted.
    public var onOutputReceived: (@Sendable () -> Void)?

    private struct Chunk: Sendable {
        let epoch: UInt64
        let sequence: UInt64
        let payload: Data
    }

    private struct Slice: Sendable {
        let epoch: UInt64
        let sequence: UInt64
        let endSequence: UInt64
        let payload: Data
    }

    private struct Buffer {
        private(set) var epoch: UInt64?
        private(set) var enqueuedSequence: UInt64 = 0
        private var chunks: [Chunk] = []
        private var headIndex = 0
        private var headOffset = 0

        var isEmpty: Bool { headIndex >= chunks.count }

        mutating func reset(epoch: UInt64, sequence: UInt64) {
            self.epoch = epoch
            enqueuedSequence = sequence
            chunks.removeAll(keepingCapacity: true)
            headIndex = 0
            headOffset = 0
        }

        mutating func append(epoch: UInt64, sequence: UInt64, payload: Data) {
            guard !payload.isEmpty,
                  UInt64(payload.count) <= UInt64.max - sequence else { return }
            if self.epoch != epoch {
                reset(epoch: epoch, sequence: 0)
            }
            let end = sequence + UInt64(payload.count)
            guard end > enqueuedSequence else { return }
            let offset = sequence < enqueuedSequence
                ? Int(enqueuedSequence - sequence)
                : 0
            let retained = offset == 0 ? payload : Data(payload.dropFirst(offset))
            chunks.append(Chunk(
                epoch: epoch,
                sequence: sequence + UInt64(offset),
                payload: retained
            ))
            enqueuedSequence = end
        }

        mutating func take(maxBytes: Int) -> Slice? {
            precondition(maxBytes > 0)
            guard !isEmpty else { return nil }
            let chunk = chunks[headIndex]
            let count = min(maxBytes, chunk.payload.count - headOffset)
            let start = headOffset
            let end = start + count
            let payload = start == 0 && end == chunk.payload.count
                ? chunk.payload
                : Data(chunk.payload[start..<end])
            let slice = Slice(
                epoch: chunk.epoch,
                sequence: chunk.sequence + UInt64(start),
                endSequence: chunk.sequence + UInt64(end),
                payload: payload
            )
            headOffset = end
            if headOffset == chunk.payload.count {
                headIndex += 1
                headOffset = 0
                compactIfNeeded()
            }
            return slice
        }

        private mutating func compactIfNeeded() {
            guard headIndex >= 32, headIndex * 2 >= chunks.count else { return }
            chunks.removeFirst(headIndex)
            headIndex = 0
        }
    }

    private let lock = NSLock()
    /// Serializes native state installation with the final current-epoch
    /// check and Ghostty write. A stale drain can therefore only complete
    /// before the snapshot swap, never append covered bytes after it.
    private let terminalFeedLock = NSLock()
    private let inMemory: InMemoryTerminalSession
    private let ansiObserver: TerminalANSIObserver
    private let budgetBytes: Int
    private let yield: Duration
    private var buffer = Buffer()
    private var feedTask: Task<Void, Never>?
    /// Identifies the drain currently represented by `feedTask`. A task may
    /// finish after it has atomically handed the slot to a replacement drain,
    /// so cleanup must match this generation instead of clearing blindly.
    private var feedTaskGeneration: UInt64?
    private var nextFeedGeneration: UInt64 = 0
    /// A writer belongs to one surface lifetime. Once shutdown starts, no
    /// later transport callback may recreate a drain for the disposed surface.
    private var isShutdown = false
    private var latestRenderedEpoch: UInt64 = 0
    private var latestRenderedSequence: UInt64 = 0
    private var rawEpoch: UInt64 = 1
    private var rawSequence: UInt64 = 0
    private var shutdownCompletion: (@MainActor @Sendable () -> Void)?
    private var shutdownWaitingGeneration: UInt64?
    private var shutdownCompletionDelivered = false
    // Synchronized-output depth: >0 means Ghostty is inside ESC[?2026h ... ESC[?2026l.
    // Foreground should draw at frame boundary (depth==0), not at queue-empty.
    private var syncDepth: Int = 0
    private var syncEnteredAt: ContinuousClock.Instant?
    private var syncTail: [UInt8] = []

    init(
        inMemory: InMemoryTerminalSession,
        ansiObserver: TerminalANSIObserver,
        // Large live TUI bursts and legacy recovery frames must drain without
        // delaying input echoes. Native cold recovery bypasses this VT parser
        // entirely through restoreSnapshot(_:epoch:sequence:).
        // Keep one host-managed write close to Ghostty's 64 KiB reader batch.
        // A large call holds Ghostty's terminal-state mutex for the entire VT
        // parse and can delay the renderer behind a sustained output burst.
        budgetBytes: Int = 64 * 1024,
        yield: Duration = .microseconds(200)
    ) {
        precondition(budgetBytes > 0)
        self.inMemory = inMemory
        self.ansiObserver = ansiObserver
        self.budgetBytes = budgetBytes
        self.yield = yield
    }

    deinit {
        feedTask?.cancel()
    }

    /// Epoch of the output currently buffered, if any.
    public var bufferEpoch: UInt64? {
        lock.withLock { buffer.epoch }
    }

    /// Highest sequence already enqueued into the pending buffer.
    public var enqueuedSequence: UInt64 {
        lock.withLock { buffer.enqueuedSequence }
    }

    /// Last (epoch, sequence) actually written into Ghostty.
    public var renderedEpoch: UInt64 {
        lock.withLock { latestRenderedEpoch }
    }

    public var renderedSequence: UInt64 {
        lock.withLock { latestRenderedSequence }
    }

    /// Whether Ghostty is currently inside a synchronized-output block.
    /// Foreground draws should wait for depth==0, not for pending==0.
    public var isInSynchronizedOutput: Bool {
        lock.withLock { syncDepth > 0 }
    }

    /// Whether a synchronized block has been pending longer than the
    /// presentation timeout (50ms). Foreground should force a draw after
    /// this window to avoid a permanently black warm promotion when the
    /// closing `ESC[?2026l` is split across Data boundaries or never arrives.
    public var isSyncStalled: Bool {
        lock.withLock {
            guard syncDepth > 0, let entered = syncEnteredAt else { return false }
            return ContinuousClock.now - entered >= .milliseconds(50)
        }
    }

    /// Drops pending bytes and restarts the recovery anchor. Safe to call
    /// while a feed is in flight; the next enqueue starts a fresh drain.
    public func reset(epoch: UInt64, sequence: UInt64) {
        terminalFeedLock.withLock {
            lock.withLock {
                guard !isShutdown else { return }
                buffer.reset(epoch: epoch, sequence: sequence)
                syncDepth = 0
                syncEnteredAt = nil
                syncTail = []
            }
        }
    }

    /// Installs one native Ghostty state and advances the writer to its
    /// browser-facing recovery boundary. Queued historical bytes are dropped
    /// only after Ghostty accepts the snapshot.
    @discardableResult
    public func restoreSnapshot(
        _ data: Data,
        epoch: UInt64,
        sequence: UInt64
    ) -> Bool {
        restoreSnapshotResult(data, epoch: epoch, sequence: sequence) == .restored
    }

    @discardableResult
    func restoreSnapshotResult(
        _ data: Data,
        epoch: UInt64,
        sequence: UInt64
    ) -> TerminalSnapshotRestoreResult {
        // Recovery is retried by the caller when the feed is busy. Waiting on
        // this lock from the main actor can deadlock if the drain is blocked in
        // Ghostty while that same run loop is needed to unblock it.
        guard terminalFeedLock.try() else { return .feedBusy }
        defer { terminalFeedLock.unlock() }
        guard inMemory.restoreSnapshot(data) else { return .rejected }
        markSnapshotRestored(epoch: epoch, sequence: sequence)
        return .restored
    }

    /// Installs a native snapshot and reapplies embedder configuration while
    /// holding the same feed lock as live output. The callback runs on the
    /// main actor because terminal configuration is main-actor owned; keeping
    /// both operations in one critical section prevents live bytes from being
    /// written between the snapshot replacement and its color restoration.
    @MainActor
    @discardableResult
    func restoreSnapshotAndReapplyRuntimeConfig(
        _ data: Data,
        epoch: UInt64,
        sequence: UInt64,
        reapplyRuntimeConfig: () -> Bool
    ) -> TerminalSnapshotRestoreResult {
        // Do not make the main actor wait behind a potentially blocking native
        // write. The recovery coordinator retries the explicit `feedBusy`
        // result after the existing surface-ready delay.
        guard terminalFeedLock.try() else { return .feedBusy }
        defer { terminalFeedLock.unlock() }
        guard inMemory.restoreSnapshot(data) else { return .rejected }
        guard reapplyRuntimeConfig() else { return .rejected }
        markSnapshotRestored(epoch: epoch, sequence: sequence)
        return .restored
    }

    private func markSnapshotRestored(epoch: UInt64, sequence: UInt64) {
        lock.withLock {
            buffer.reset(epoch: epoch, sequence: sequence)
            latestRenderedEpoch = epoch
            latestRenderedSequence = sequence
            syncDepth = 0
            syncEnteredAt = nil
            syncTail = []
        }
    }

    /// Records that Ghostty has consumed bytes through `sequence` for `epoch`.
    public func markRendered(epoch: UInt64, sequence: UInt64) {
        lock.withLock {
            latestRenderedEpoch = epoch
            latestRenderedSequence = sequence
        }
    }

    /// Enqueues a framed output payload and drains it on the background task.
    public func enqueue(epoch: UInt64, sequence: UInt64, payload: Data) {
        let accepted = lock.withLock { () -> Bool in
            guard !isShutdown else { return false }
            buffer.append(epoch: epoch, sequence: sequence, payload: payload)
            return true
        }
        if accepted { startFeedIfNeeded() }
    }

    /// Enqueues raw Host bytes for transports without DENB frame metadata.
    /// All raw bytes share one synthetic epoch so ordering is preserved.
    public func enqueueRaw(_ payload: Data) {
        guard !payload.isEmpty else { return }
        let sequence = lock.withLock { () -> UInt64? in
            guard !isShutdown else { return nil }
            let sequence = max(rawSequence, buffer.enqueuedSequence)
            rawSequence = sequence &+ UInt64(payload.count)
            return Optional(sequence)
        }
        guard let sequence else { return }
        enqueue(epoch: rawEpoch, sequence: sequence, payload: payload)
    }

    /// Writes bytes into Ghostty synchronously (used by tests and initial
    /// snapshots where ordering with in-flight feed work is not a concern).
    public func receive(_ payload: Data) {
		terminalFeedLock.withLock {
			ansiObserver.receive(payload)
			updateSyncDepth(with: payload)
			if inMemory.receive(payload) {
				onOutputReceived?()
			}
		}
    }

    // MARK: - Synchronized output tracking

    private func updateSyncDepth(with payload: Data) {
        // Scan for ESC[?2026h / ESC[?2026l. Split sequences across Data
        // boundaries are rare (8-byte pattern) and ignored for simplicity.
        let bytes = [UInt8](payload)
        var delta = 0
        var i = 0
        while i + 7 < bytes.count {
            // ESC [ ? 2 0 2 6 h/l  -> 0x1B 0x5B 0x3F 0x32 0x30 0x32 0x36 0x68/0x6C
            if bytes[i] == 0x1B, bytes[i + 1] == 0x5B, bytes[i + 2] == 0x3F,
               bytes[i + 3] == 0x32, bytes[i + 4] == 0x30, bytes[i + 5] == 0x32, bytes[i + 6] == 0x36 {
                if bytes[i + 7] == 0x68 { // h
                    delta += 1
                    i += 8
                    continue
                } else if bytes[i + 7] == 0x6C { // l
                    delta -= 1
                    i += 8
                    continue
                }
            }
            i += 1
        }
        guard delta != 0 else { return }
        lock.withLock {
            syncDepth = max(0, syncDepth + delta)
        }
    }

    /// Cancels the background feed and drops pending bytes.
    ///
    /// The in-flight drain may still be inside Ghostty's host-managed write
    /// path; it exits once the main runloop pumps again. A synchronous wait
    /// here would hold the main thread and re-create the exact deadlock this
    /// writer avoids, so shutdown only cancels and clears. `completion` runs
    /// on the main actor after the drain has fully exited, which lets owners
    /// release the terminal view and surface without racing an in-flight
    /// Ghostty write.
    public func shutdown(
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let completionToNotify: (@MainActor @Sendable () -> Void)?
        lock.lock()
        if let completion,
           !shutdownCompletionDelivered,
           shutdownCompletion == nil
        {
            shutdownCompletion = completion
        }
        if !isShutdown {
            isShutdown = true
            shutdownWaitingGeneration = feedTaskGeneration
            feedTask?.cancel()
            buffer = Buffer()
        }
        let hasDrainToWaitFor = shutdownWaitingGeneration != nil
            && feedTaskGeneration == shutdownWaitingGeneration
        completionToNotify = hasDrainToWaitFor
            ? nil
            : takeShutdownCompletionLocked()
        lock.unlock()
        notifyShutdownCompletion(completionToNotify)
    }

    private func startFeedIfNeeded() {
        lock.lock()
        guard !isShutdown, feedTask == nil, !buffer.isEmpty else {
            lock.unlock()
            return
        }
        nextFeedGeneration &+= 1
        let generation = nextFeedGeneration
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.drain(generation: generation)
        }
        feedTask = task
        feedTaskGeneration = generation
        lock.unlock()
    }

    private func drain(generation: UInt64) async {
        defer { finishDrain(generation: generation) }
        var heldSlice: Slice?
        while !Task.isCancelled {
            if heldSlice == nil {
                heldSlice = lock.withLock {
                    buffer.take(maxBytes: budgetBytes)
                }
            }
            guard let slice = heldSlice else {
                if shouldExitDrain(generation: generation) { return }
                continue
            }

            // The surface may not be attached yet (or may be mid-attach while
            // pre-surface bytes flush). Keep the slice instead of consuming
            // more of the buffer, so the pre-surface prompt is never reordered
            // behind later live output.
            guard inMemory.isSurfaceReady else {
                try? await Task.sleep(for: yield)
                continue
            }

            // Ghostty's host-managed write path can block until the main
            // runloop services the surface. Never hold the writer lock across
            // this call: the main thread enqueues the next slice and would
            // deadlock against a drain blocked inside Ghostty. The in-memory
            // session also never holds its own lock across Ghostty, so a
            // teardown on the main thread cannot wait behind this call.
            let writeResult = terminalFeedLock.withLock { () -> (isCurrent: Bool, received: Bool) in
                guard lock.withLock({ buffer.epoch == slice.epoch }) else {
                    return (false, false)
                }
                ansiObserver.receive(slice.payload)
                updateSyncDepth(with: slice.payload)
				let received = inMemory.receive(slice.payload)
				if received {
					onOutputReceived?()
					lock.withLock {
                        latestRenderedEpoch = slice.epoch
                        latestRenderedSequence = slice.endSequence
                    }
                }
                return (true, received)
            }
            guard writeResult.isCurrent else {
                // A reanchor reset the stream while this slice was in flight;
                // it is stale and must not be rendered.
                heldSlice = nil
                continue
            }
            guard writeResult.received else {
                try? await Task.sleep(for: yield)
                continue
            }
            heldSlice = nil

            let hasMore = lock.withLock { !buffer.isEmpty }
            if !hasMore, shouldExitDrain(generation: generation) {
                return
            }
            // Yield only when there is more work; the 200µs quantum keeps a
            // 14MB hidden backlog drain within ~4ms instead of seconds, while
            // still yielding to the main thread for input and scroll.
            if hasMore {
                do {
                    try await Task.sleep(for: yield)
                } catch {
                    return
                }
            }
        }
    }

    /// Runs the shutdown completion once the drain task has fully returned.
    private func finishDrain(generation: UInt64) {
        let completion: (@MainActor @Sendable () -> Void)?
        lock.lock()
        if feedTaskGeneration == generation {
            feedTask = nil
            feedTaskGeneration = nil
        }
        if shutdownWaitingGeneration == generation {
            shutdownWaitingGeneration = nil
            completion = takeShutdownCompletionLocked()
        } else {
            completion = nil
        }
        lock.unlock()
        notifyShutdownCompletion(completion)
    }

    /// Runs the shutdown completion when there was no drain task to wait for.
    private func notifyShutdownCompletion(
        _ completion: (@MainActor @Sendable () -> Void)?
    ) {
        guard let completion else { return }
        Task { @MainActor in
            completion()
        }
    }

    private func takeShutdownCompletionLocked() -> (@MainActor @Sendable () -> Void)? {
        guard !shutdownCompletionDelivered, let completion = shutdownCompletion else {
            return nil
        }
        shutdownCompletion = nil
        shutdownCompletionDelivered = true
        return completion
    }

    /// Atomically decides whether this drain can exit. `feedTask` is cleared
    /// only while the matching generation owns it and the buffer is empty, so
    /// an enqueue that lands at the handoff always finds either the same live
    /// drain or an empty slot for a replacement drain.
    private func shouldExitDrain(generation: UInt64) -> Bool {
        lock.withLock {
            guard feedTaskGeneration == generation else { return true }
            guard buffer.isEmpty else { return false }
            feedTask = nil
            feedTaskGeneration = nil
            return true
        }
    }
}
