import Foundation
import GhosttyTerminal
import WarrenDomain

/// Outcome of a non-blocking native snapshot installation attempt.
public enum TerminalSnapshotRestoreResult: Equatable, Sendable {
    /// Ghostty accepted the snapshot and the writer advanced its anchor.
    case restored
    /// A live output drain owns the feed lock; retry without blocking the main actor.
    case feedBusy
    /// Ghostty rejected the snapshot itself.
    case rejected
    /// Ghostty accepted the snapshot, but the runtime configuration could not
    /// be reapplied. The grid is valid, so the caller can retry config only.
    case configRejected
}

/// A point in the ordered output stream used to synchronize presentation with
/// the bytes that have already entered the writer.
public struct WarrenGhosttyOutputBoundary: Equatable, Sendable {
    public let epoch: UInt64?
    public let sequence: UInt64

    public init(epoch: UInt64?, sequence: UInt64) {
        self.epoch = epoch
        self.sequence = sequence
    }
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
        let generation: UInt64
        let epoch: UInt64
        let sequence: UInt64
        let endSequence: UInt64
        let payload: Data
    }

    /// A Host-reported grid change: output from `sequence` on was produced
    /// for `grid`.
    private struct GridMark: Sendable {
        let epoch: UInt64
        let sequence: UInt64
        let grid: TerminalSize
    }

    private struct Buffer {
        private(set) var generation: UInt64 = 0
        private(set) var epoch: UInt64?
        private(set) var enqueuedSequence: UInt64 = 0
        private var chunks: [Chunk] = []
        private var headIndex = 0
        private var headOffset = 0
        /// Grid changes in sequence order. A mark can arrive before the bytes
        /// that precede it, because the Host sends it ahead of queued output;
        /// it waits here until the drain reaches its sequence.
        private var marks: [GridMark] = []

        var isEmpty: Bool { headIndex >= chunks.count }

        /// Whether the drain has bytes to write or a grid change to apply.
        var hasWork: Bool { !isEmpty || dueMark != nil }

        /// The sequence of the next byte the drain will take.
        private var nextSequence: UInt64 {
            guard !isEmpty else { return enqueuedSequence }
            return chunks[headIndex].sequence + UInt64(headOffset)
        }

        /// The first grid change whose sequence the drain has reached.
        private var dueMark: GridMark? {
            guard epoch != nil, let mark = marks.first, mark.epoch == epoch,
                  mark.sequence <= nextSequence else {
                return nil
            }
            return mark
        }

        mutating func takeDueMark() -> GridMark? {
            guard let mark = dueMark else { return nil }
            marks.removeFirst()
            return mark
        }

        mutating func appendMark(_ mark: GridMark) {
            // A mark can belong to an epoch this buffer has not reset to yet:
            // a deferred snapshot install leaves the old epoch in place while
            // the new stream's marks arrive. Keep it; `reset` drops it if the
            // anchor it waits for never comes.
            marks.removeAll { $0.epoch != mark.epoch || $0.sequence >= mark.sequence }
            marks.append(mark)
        }

        mutating func reset(epoch: UInt64, sequence: UInt64) {
            generation &+= 1
            self.epoch = epoch
            enqueuedSequence = sequence
            chunks.removeAll(keepingCapacity: true)
            headIndex = 0
            headOffset = 0
            // The new anchor's own size is set by the caller. A mark the Host
            // sent ahead of this anchor's bytes stays.
            marks.removeAll { $0.epoch != epoch || $0.sequence < sequence }
        }

        /// Invalidates slices already handed to a drain without establishing a
        /// new output anchor. This is used during shutdown so a cancelled
        /// drain cannot publish a sequence after its buffer was cleared.
        mutating func invalidate() {
            generation &+= 1
            epoch = nil
            enqueuedSequence = 0
            chunks.removeAll(keepingCapacity: true)
            headIndex = 0
            headOffset = 0
            marks.removeAll()
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
            guard !isEmpty, dueMark == nil else { return nil }
            let chunk = chunks[headIndex]
            var count = min(maxBytes, chunk.payload.count - headOffset)
            // Never write bytes produced for the next grid before that grid
            // is applied.
            if let mark = marks.first, mark.epoch == epoch {
                let start = chunk.sequence + UInt64(headOffset)
                if mark.sequence > start, mark.sequence - start < UInt64(count) {
                    count = Int(mark.sequence - start)
                }
            }
            let start = headOffset
            let end = start + count
            let payload = start == 0 && end == chunk.payload.count
                ? chunk.payload
                : Data(chunk.payload[start..<end])
            let slice = Slice(
                generation: generation,
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
    private let ansiObserver: TerminalANSIObserver?
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
    /// Internal suspension point used by deterministic writer race tests. The
    /// hook is read under `lock`, then awaited outside it so production feeds
    /// retain the same lock ordering as the normal path.
    private var beforeWriteHook: (@Sendable () async -> Void)?
    private var shutdownCompletion: (@MainActor @Sendable () -> Void)?
    private var shutdownWaitingGeneration: UInt64?
    private var shutdownCompletionDelivered = false
    // Synchronized-output state: true while Ghostty is inside
    // ESC[?2026h ... ESC[?2026l. Foreground should draw at frame boundary
    // (false), not at queue-empty. `syncScanTail` carries up to 7 trailing
    // bytes across slice boundaries under `terminalFeedLock` so split escape
    // sequences are never missed.
    private var inSynchronizedOutput = false
    private var syncScanTail: [UInt8] = []
    private var syncEnteredAt: ContinuousClock.Instant?
    /// Last time a byte of the open synchronized-output block arrived.
    private var syncLastByteAt: ContinuousClock.Instant?
    /// The grid the Host produced the output now being written for, when the
    /// Host reports one. While it is set, Ghostty's grid follows the Host's
    /// marks instead of the view.
    private var hostGrid: TerminalSize?
    /// When the current anchor grid was set. A snapshot waits for Ghostty to
    /// reach that grid for at most `gridSettleTimeout`, so a grid Ghostty
    /// cannot lay out never leaves the pane without its state.
    private var anchorGridSetAt: ContinuousClock.Instant?
    /// Asks the owner to lay Ghostty out at a grid on the main actor. Returns
    /// whether the terminal will reach it; a surface that cannot be sized
    /// right now (no native surface yet) is not waited for.
    private var gridApplier: (@Sendable (TerminalSize) async -> Bool)?
    /// Bounds the wait for Ghostty's IO thread to resize the terminal. It
    /// normally takes well under a frame; the bound only keeps a surface that
    /// stopped servicing its mailbox from stalling output forever.
    var gridSettleTimeout: Duration = .seconds(1)

    init(
        inMemory: InMemoryTerminalSession,
        ansiObserver: TerminalANSIObserver? = nil,
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

    /// The enqueued epoch and sequence captured under one lock. Presentation
    /// must use this snapshot rather than reading the two properties separately
    /// across a concurrent recovery reset.
    public var enqueuedBoundary: WarrenGhosttyOutputBoundary {
        lock.withLock {
            WarrenGhosttyOutputBoundary(
                epoch: buffer.epoch,
                sequence: buffer.enqueuedSequence
            )
        }
    }

    /// Last (epoch, sequence) actually written into Ghostty.
    public var renderedEpoch: UInt64 {
        lock.withLock { latestRenderedEpoch }
    }

    public var renderedSequence: UInt64 {
        lock.withLock { latestRenderedSequence }
    }

    public var renderedBoundary: WarrenGhosttyOutputBoundary {
        lock.withLock {
            WarrenGhosttyOutputBoundary(
                epoch: latestRenderedEpoch,
                sequence: latestRenderedSequence
            )
        }
    }

    /// Installs a deterministic suspension point immediately before a slice
    /// enters Ghostty. This is intentionally internal; callers use it only to
    /// reproduce reset-versus-drain races in the adapter test suite.
    func setBeforeWriteHook(_ hook: (@Sendable () async -> Void)?) {
        lock.withLock {
            beforeWriteHook = hook
        }
    }

    /// Whether Ghostty is currently inside a synchronized-output block.
    /// Foreground draws should wait for the block to close, not for pending==0.
    public var isInSynchronizedOutput: Bool {
        lock.withLock { inSynchronizedOutput }
    }

    /// Whether a synchronized-output block has stopped making progress.
    ///
    /// A block that is still receiving bytes is a frame in flight, and drawing
    /// it means presenting half of a repaint: rows already rewritten next to
    /// rows that were just erased. Whole-block repaints are routinely 10-20 KB
    /// and take ~70ms to drain, so any window measured from the block's start
    /// fires on ordinary frames. Only silence counts as a stall, with a hard
    /// ceiling for a block that keeps dribbling bytes without ever closing.
    public var isSyncStalled: Bool {
        isSyncStalled(window: .milliseconds(250), ceiling: .seconds(2))
    }

    public func isSyncStalled(
        window: Duration,
        ceiling: Duration
    ) -> Bool {
        lock.withLock {
            guard inSynchronizedOutput, let entered = syncEnteredAt else { return false }
            let now = ContinuousClock.now
            if now - entered >= ceiling { return true }
            guard let last = syncLastByteAt else { return false }
            return now - last >= window
        }
    }

    /// The grid the Host reported for the output being written, or nil when
    /// the Host does not report sizes and the view decides the grid.
    public var reportedGrid: TerminalSize? {
        lock.withLock { hostGrid }
    }

    public func setGridApplier(_ applier: (@Sendable (TerminalSize) async -> Bool)?) {
        lock.withLock { gridApplier = applier }
    }

    /// Records the grid at a new output anchor, before its snapshot installs.
    /// Passing nil returns the grid to the view.
    public func setAnchorGrid(_ grid: TerminalSize?) {
        lock.withLock {
            hostGrid = grid
            anchorGridSetAt = grid == nil ? nil : ContinuousClock.now
        }
    }

    /// Records that output from `sequence` on was produced for `grid`. The
    /// drain applies the change exactly between the bytes before and after
    /// it, however early the mark arrives.
    public func enqueueGridChange(epoch: UInt64, sequence: UInt64, grid: TerminalSize) {
        let accepted = lock.withLock { () -> Bool in
            guard !isShutdown, hostGrid != nil else { return false }
            buffer.appendMark(GridMark(epoch: epoch, sequence: sequence, grid: grid))
            return true
        }
        if accepted { startFeedIfNeeded() }
    }

    /// Whether Ghostty's terminal is not yet at the grid the Host reported.
    /// A snapshot installed now would be reflowed to the wrong grid.
    private var terminalLagsHostGrid: Bool {
        let (grid, setAt, timeout) = lock.withLock { (hostGrid, anchorGridSetAt, gridSettleTimeout) }
        guard let grid, let current = inMemory.terminalGrid() else { return false }
        guard Int(current.columns) != grid.columns || Int(current.rows) != grid.rows else {
            return false
        }
        if let setAt, ContinuousClock.now - setAt >= timeout {
            TerminalDiagnostics.log("terminal_grid_settle_timeout", [
                "want": "\(grid.columns)x\(grid.rows)",
                "have": "\(current.columns)x\(current.rows)",
                "phase": "snapshot",
            ])
            return false
        }
        return true
    }

    /// Drops pending bytes and restarts the recovery anchor. Safe to call
    /// while a feed is in flight; the next enqueue starts a fresh drain.
    public func reset(epoch: UInt64, sequence: UInt64) {
        terminalFeedLock.withLock {
            lock.withLock {
                guard !isShutdown else { return }
                buffer.reset(epoch: epoch, sequence: sequence)
                inSynchronizedOutput = false
                syncScanTail.removeAll(keepingCapacity: true)
                syncEnteredAt = nil
                syncLastByteAt = nil
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
        guard !terminalLagsHostGrid else { return .feedBusy }
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
        // The snapshot was captured at the Host's grid; wait for Ghostty to
        // reach it rather than reflow it through the old one. The caller
        // retries `feedBusy`.
        guard !terminalLagsHostGrid else { return .feedBusy }
        guard inMemory.restoreSnapshot(data) else { return .rejected }
        guard reapplyRuntimeConfig() else { return .configRejected }
        markSnapshotRestored(epoch: epoch, sequence: sequence)
        return .restored
    }

    private func markSnapshotRestored(epoch: UInt64, sequence: UInt64) {
        lock.withLock {
            buffer.reset(epoch: epoch, sequence: sequence)
            latestRenderedEpoch = epoch
            latestRenderedSequence = sequence
            inSynchronizedOutput = false
            syncScanTail.removeAll(keepingCapacity: true)
            syncEnteredAt = nil
            syncLastByteAt = nil
        }
    }

    /// Records that Ghostty has consumed bytes through `sequence` for `epoch`.
    public func markRendered(epoch: UInt64, sequence: UInt64) {
        lock.withLock {
            guard epoch > latestRenderedEpoch
                || (epoch == latestRenderedEpoch && sequence >= latestRenderedSequence)
            else { return }
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
			ansiObserver?.receive(payload)
			updateSyncState(with: payload)
			if inMemory.receive(payload) {
				onOutputReceived?()
			}
		}
    }

    // MARK: - Synchronized output tracking

    /// Tracks DEC mode 2026 (`ESC[?2026h` / `ESC[?2026l`) as a boolean state
    /// across arbitrary slice boundaries without copying the payload.
    /// Must be called while holding `terminalFeedLock`.
    private func updateSyncState(with payload: Data) {
        guard !payload.isEmpty else { return }
        let initialInSync = lock.withLock { inSynchronizedOutput }
        var inSync = initialInSync
        var openedNewBlock = false

        func applyMatch(_ finalByte: UInt8) {
            if finalByte == 0x68 { // h
                if !inSync {
                    openedNewBlock = true
                }
                inSync = true
            } else if finalByte == 0x6C { // l
                inSync = false
            }
        }

        func matchSyncSequence(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> UInt8? {
            // ESC [ ? 2 0 2 6 h/l -> 0x1B 0x5B 0x3F 0x32 0x30 0x32 0x36 0x68/0x6C
            guard bytes[index] == 0x1B,
                  bytes[index + 1] == 0x5B,
                  bytes[index + 2] == 0x3F,
                  bytes[index + 3] == 0x32,
                  bytes[index + 4] == 0x30,
                  bytes[index + 5] == 0x32,
                  bytes[index + 6] == 0x36
            else { return nil }
            let finalByte = bytes[index + 7]
            return (finalByte == 0x68 || finalByte == 0x6C) ? finalByte : nil
        }

        payload.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let count = bytes.count
            var payloadStart = 0

            if !syncScanTail.isEmpty {
                let tailCount = syncScanTail.count
                let headCount = min(7, count)
                var boundary = syncScanTail
                boundary.append(contentsOf: bytes[0..<headCount])
                let boundaryCount = boundary.count
                var lastConsumedInBoundary = 0

                boundary.withUnsafeBufferPointer { buf in
                    var i = 0
                    while i < tailCount, i + 8 <= boundaryCount {
                        if let finalByte = matchSyncSequence(buf, at: i) {
                            applyMatch(finalByte)
                            i += 8
                            lastConsumedInBoundary = i
                            continue
                        }
                        i += 1
                    }
                }

                if count < 7 {
                    let keepStart = max(boundaryCount - 7, lastConsumedInBoundary)
                    if keepStart < boundaryCount {
                        syncScanTail = Array(boundary[keepStart..<boundaryCount])
                    } else {
                        syncScanTail.removeAll(keepingCapacity: true)
                    }
                    return
                }
                payloadStart = max(0, lastConsumedInBoundary - tailCount)
            }

            var i = payloadStart
            var lastConsumed = payloadStart
            if count >= 8 {
                let limit = count - 7
                while i < limit {
                    if let finalByte = matchSyncSequence(bytes, at: i) {
                        applyMatch(finalByte)
                        i += 8
                        lastConsumed = i
                        continue
                    }
                    i += 1
                }
            }

            let tailStart = max(count - 7, lastConsumed)
            if tailStart < count {
                syncScanTail = Array(bytes[tailStart..<count])
            } else {
                syncScanTail.removeAll(keepingCapacity: true)
            }
        }

        let now = ContinuousClock.now
        lock.withLock {
            inSynchronizedOutput = inSync
            if inSync {
                if !initialInSync || openedNewBlock || syncEnteredAt == nil {
                    syncEnteredAt = now
                }
                syncLastByteAt = now
            } else {
                syncEnteredAt = nil
                syncLastByteAt = nil
            }
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
            buffer.invalidate()
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
        guard !isShutdown, feedTask == nil, buffer.hasWork else {
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
                let mark = lock.withLock { () -> (GridMark, UInt64)? in
                    buffer.takeDueMark().map { ($0, buffer.generation) }
                }
                if let (mark, markGeneration) = mark {
                    await applyGrid(mark.grid, generation: markGeneration)
                    continue
                }
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

            let beforeWrite = lock.withLock { beforeWriteHook }
            if let beforeWrite {
                await beforeWrite()
            }

            // Ghostty's host-managed write path can block until the main
            // runloop services the surface. Never hold the writer lock across
            // this call: the main thread enqueues the next slice and would
            // deadlock against a drain blocked inside Ghostty. The in-memory
            // session also never holds its own lock across Ghostty, so a
            // teardown on the main thread cannot wait behind this call.
            let writeResult = terminalFeedLock.withLock { () -> (isCurrent: Bool, received: Bool) in
                guard lock.withLock({
                    buffer.generation == slice.generation && buffer.epoch == slice.epoch
                }) else {
                    return (false, false)
                }
                ansiObserver?.receive(slice.payload)
                updateSyncState(with: slice.payload)
				let received = inMemory.receive(slice.payload)
				if received {
					onOutputReceived?()
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

            let committed = lock.withLock { () -> Bool in
                // A reset that does not need Ghostty's feed lock (shutdown or
                // an epoch-changing enqueue) may land after the native write.
                // Do not let that completed stale slice move the published
                // boundary backwards.
                guard buffer.generation == slice.generation,
                      buffer.epoch == slice.epoch else {
                    return false
                }
                if slice.epoch > latestRenderedEpoch
                    || (slice.epoch == latestRenderedEpoch
                        && slice.endSequence > latestRenderedSequence)
                {
                    latestRenderedEpoch = slice.epoch
                    latestRenderedSequence = slice.endSequence
                }
                return true
            }
            guard committed else { continue }

            let hasMore = lock.withLock { buffer.hasWork }
            if !hasMore, shouldExitDrain(generation: generation) {
                return
            }
            // Yield only when there is more work; the 200µs quantum keeps a
            // 14MB hidden backlog drain within ~4ms instead of seconds, while
            // still yielding to the main thread for input and scroll.
            // Inside a synchronized-output block the rest of the frame is
            // already on its way, and a present cannot happen until the block
            // closes, so draining it back-to-back both shortens the block and
            // keeps the block from ever looking stalled.
            if hasMore, !lock.withLock({ inSynchronizedOutput }) {
                do {
                    try await Task.sleep(for: yield)
                } catch {
                    return
                }
            }
        }
    }

    /// Lays Ghostty out at `grid` and waits until its terminal has the grid,
    /// so the next byte is parsed for the size it was produced for.
    ///
    /// The applier runs on the main actor while no feed lock is held: the
    /// main actor takes the feed lock for a reset, and Ghostty's write path
    /// may need the main run loop.
    private func applyGrid(_ grid: TerminalSize, generation: UInt64) async {
        let applier = lock.withLock { () -> (@Sendable (TerminalSize) async -> Bool)? in
            hostGrid = grid
            return gridApplier
        }
        guard let applier, await applier(grid) else { return }
        let deadline = ContinuousClock.now.advanced(by: gridSettleTimeout)
        while !Task.isCancelled {
            guard lock.withLock({ buffer.generation == generation }) else { return }
            guard let current = inMemory.terminalGrid() else { return }
            if Int(current.columns) == grid.columns, Int(current.rows) == grid.rows { return }
            if ContinuousClock.now >= deadline {
                TerminalDiagnostics.log("terminal_grid_settle_timeout", [
                    "want": "\(grid.columns)x\(grid.rows)",
                    "have": "\(current.columns)x\(current.rows)",
                ])
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
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
            guard !buffer.hasWork else { return false }
            feedTask = nil
            feedTaskGeneration = nil
            return true
        }
    }
}
