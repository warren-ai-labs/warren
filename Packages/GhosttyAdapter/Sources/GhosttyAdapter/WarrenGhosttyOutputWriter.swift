import Foundation
import GhosttyTerminal

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
    private var latestRenderedEpoch: UInt64 = 0
    private var latestRenderedSequence: UInt64 = 0
    private var rawEpoch: UInt64 = 1
    private var rawSequence: UInt64 = 0
    private var shutdownCompletion: (@MainActor @Sendable () -> Void)?
    // Synchronized-output depth: >0 means Ghostty is inside ESC[?2026h ... ESC[?2026l.
    // Foreground should draw at frame boundary (depth==0), not at queue-empty.
    private var syncDepth: Int = 0

    init(
        inMemory: InMemoryTerminalSession,
        ansiObserver: TerminalANSIObserver,
        // Large live TUI bursts and legacy recovery frames must drain without
        // delaying input echoes. Native cold recovery bypasses this VT parser
        // entirely through restoreSnapshot(_:epoch:sequence:).
        // Warm promotion must drain a hidden backlog within 50ms, so keep the
        // budget large and the yield minimal; visible fast-forward is avoided
        // by the presentation gate, not by throttling the writer.
        budgetBytes: Int = 8 * 1024 * 1024,
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

    /// Drops pending bytes and restarts the recovery anchor. Safe to call
    /// while a feed is in flight; the next enqueue starts a fresh drain.
    public func reset(epoch: UInt64, sequence: UInt64) {
        terminalFeedLock.withLock {
            lock.withLock {
                buffer.reset(epoch: epoch, sequence: sequence)
                syncDepth = 0
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
        terminalFeedLock.lock()
        defer { terminalFeedLock.unlock() }
        guard inMemory.restoreSnapshot(data) else { return false }
        lock.withLock {
            buffer.reset(epoch: epoch, sequence: sequence)
            latestRenderedEpoch = epoch
            latestRenderedSequence = sequence
            syncDepth = 0
        }
        return true
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
        lock.withLock {
            buffer.append(epoch: epoch, sequence: sequence, payload: payload)
        }
        startFeedIfNeeded()
    }

    /// Enqueues raw Host bytes for transports without DENB frame metadata.
    /// All raw bytes share one synthetic epoch so ordering is preserved.
    public func enqueueRaw(_ payload: Data) {
        guard !payload.isEmpty else { return }
        let sequence = lock.withLock { () -> UInt64 in
            let sequence = max(rawSequence, buffer.enqueuedSequence)
            rawSequence = sequence &+ UInt64(payload.count)
            return sequence
        }
        enqueue(epoch: rawEpoch, sequence: sequence, payload: payload)
    }

    /// Writes bytes into Ghostty synchronously (used by tests and initial
    /// snapshots where ordering with in-flight feed work is not a concern).
    public func receive(_ payload: Data) {
        terminalFeedLock.withLock {
            ansiObserver.receive(payload)
            updateSyncDepth(with: payload)
            inMemory.receive(payload)
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
        let hadTask: Bool
        lock.lock()
        hadTask = feedTask != nil
        feedTask?.cancel()
        feedTask = nil
        buffer = Buffer()
        if let completion {
            shutdownCompletion = completion
        }
        lock.unlock()
        if !hadTask {
            notifyShutdownCompletion()
        }
    }

    private func startFeedIfNeeded() {
        lock.lock()
        guard feedTask == nil, !buffer.isEmpty else {
            lock.unlock()
            return
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.drain()
        }
        feedTask = task
        lock.unlock()
    }

    private func drain() async {
        defer { finishDrain() }
        var heldSlice: Slice?
        while !Task.isCancelled {
            if heldSlice == nil {
                heldSlice = lock.withLock {
                    buffer.take(maxBytes: budgetBytes)
                }
            }
            guard let slice = heldSlice else {
                if exitIfDrained() { return }
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
                return (true, inMemory.receive(slice.payload))
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

            lock.withLock {
                latestRenderedEpoch = slice.epoch
                latestRenderedSequence = slice.endSequence
            }

            let hasMore = lock.withLock { !buffer.isEmpty }
            if !hasMore, exitIfDrained() {
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
    private func finishDrain() {
        let completion: (@MainActor @Sendable () -> Void)?
        lock.lock()
        feedTask = nil
        completion = shutdownCompletion
        shutdownCompletion = nil
        lock.unlock()
        guard let completion else { return }
        Task { @MainActor in
            completion()
        }
    }

    /// Runs the shutdown completion when there was no drain task to wait for.
    private func notifyShutdownCompletion() {
        let completion: (@MainActor @Sendable () -> Void)?
        lock.lock()
        completion = shutdownCompletion
        shutdownCompletion = nil
        lock.unlock()
        guard let completion else { return }
        Task { @MainActor in
            completion()
        }
    }

    /// Atomically decides whether this drain can exit. `feedTask` is cleared
    /// only while the buffer is empty, so an enqueue that lands at the same
    /// moment always finds either a live drain or `feedTask == nil` to
    /// restart one — no enqueued bytes are left behind.
    private func exitIfDrained() -> Bool {
        lock.withLock {
            guard buffer.isEmpty else { return false }
            feedTask = nil
            return true
        }
    }
}
