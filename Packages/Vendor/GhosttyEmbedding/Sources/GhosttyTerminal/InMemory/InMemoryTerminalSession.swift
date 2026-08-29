//
//  InMemoryTerminalSession.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    /// Tracks one native surface independently from the currently attached
    /// surface. A write may outlive `clearSurface`; keeping the operation
    /// count on this object lets teardown detach immediately while retaining
    /// the native pointer until every in-flight C call has returned.
    private final class SurfaceState: @unchecked Sendable {
        let surface: ghostty_surface_t
        let callLock = NSLock()
        var activeCalls = 0
        var ready = false
        var detached = false
        /// Bytes received after this surface was installed but before its
        /// pre-surface queue has finished flushing. Keeping this queue on the
        /// state itself closes the gap between moving the old queue and
        /// publishing `ready = true`.
        var pending = Data()
        var drainedCallbacks: [@Sendable () -> Void] = []

        init(surface: ghostty_surface_t) {
            self.surface = surface
        }
    }

    /// A lease keeps a native surface alive for the duration of one C call.
    /// The call lock is per surface, so detaching one surface never blocks a
    /// lifecycle operation for another surface.
    private final class SurfaceLease: @unchecked Sendable {
        let owner: InMemoryTerminalSession
        let state: SurfaceState
        private let releaseLock = NSLock()
        private var hasReleased = false

        init(owner: InMemoryTerminalSession, state: SurfaceState) {
            self.owner = owner
            self.state = state
            state.callLock.lock()
        }

        func release() {
            releaseLock.lock()
            guard !hasReleased else {
                releaseLock.unlock()
                return
            }
            hasReleased = true
            releaseLock.unlock()
            owner.release(self)
        }
    }

    private let lock = NSLock()
    private var surfaceState: SurfaceState?
    /// Host output received before a surface has attached. The read pump is
    /// armed the instant the child is spawned, but the ghostty surface is not
    /// built until the view mounts a turn later — so the shell's first prompt
    /// can arrive before `setSurface`. Buffer it here instead of dropping it,
    /// and flush it the moment a surface attaches (see `setSurface`).
    private var pendingPreSurface = Data()
    /// Safety cap on the pre-surface buffer so a surface that never attaches
    /// cannot grow it without bound. A cold-start prompt is a few hundred
    /// bytes; this only bites pathological cases. Oldest bytes drop first.
    private static let pendingPreSurfaceCap = 1 << 20 // 1 MB
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    public func setSurface(_ surface: ghostty_surface_t?) {
        guard let surface else {
            clearSurface(ifMatches: currentSurface)
            return
        }

        let state: SurfaceState
        lock.lock()
        if let current = surfaceState,
           current.surface == surface,
           !current.detached
        {
            lock.unlock()
            return
        }
        state = SurfaceState(surface: surface)
        surfaceState = state
        if !pendingPreSurface.isEmpty {
            state.pending = pendingPreSurface
            pendingPreSurface.removeAll(keepingCapacity: false)
        }
        lock.unlock()

        // Flush anything the host sent before the surface existed — the
        // shell's first prompt at cold start. The background writer now waits
        // for the not-ready surface state, so this happens before any live
        // byte is written and Ghostty is never called while `lock` is held.
        let flushedBytes = flushPending(for: state)
        if flushedBytes > 0 {
            TerminalDebugLog.log(
                .output,
                "terminal <- host flushed pre-surface \(flushedBytes) bytes"
            )
        }

        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=set"
        )
    }

    @discardableResult
    func clearSurface(
        ifMatches expectedSurface: ghostty_surface_t?,
        onDrained: (@Sendable () -> Void)? = nil
    ) -> Bool {
        var callbacks: [@Sendable () -> Void] = []
        lock.lock()
        guard surfaceState?.surface == expectedSurface
            || (surfaceState == nil && expectedSurface == nil)
        else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surfaceState == nil ? "nil" : "set")"
            )
            lock.unlock()
            return false
        }

        guard let state = surfaceState else {
            lock.unlock()
            if let onDrained { onDrained() }
            return true
        }

        surfaceState = nil
        state.ready = false
        state.detached = true
        // Preserve bytes queued while the surface was attaching. They belong
        // before any output received after this detach and must not disappear
        // if teardown wins the race with the attach flush.
        appendPending(state.pending, to: &pendingPreSurface)
        state.pending.removeAll(keepingCapacity: false)
        if let onDrained {
            if state.activeCalls == 0 {
                callbacks.append(onDrained)
            } else {
                state.drainedCallbacks.append(onDrained)
            }
        }
        lock.unlock()

        callbacks.forEach { $0() }
        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
        return true
    }

    public var currentSurface: ghostty_surface_t? {
        lock.lock()
        defer { lock.unlock() }
        return surfaceState?.surface
    }

    public var isSurfaceReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceState?.ready == true && surfaceState?.detached == false
    }

    // MARK: - Viewport Read

    /// Returns the active viewport as a UTF-8 string, or `nil` if no surface
    /// is attached. Lines are separated by `\n`. The `ghostty_text_s`
    /// lifecycle (allocate via `ghostty_surface_read_text`, free via
    /// `ghostty_surface_free_text`) is fully encapsulated — callers never
    /// touch the C buffer.
    ///
    /// Selection grammar: `(VIEWPORT, TOP_LEFT)` to `(VIEWPORT, BOTTOM_RIGHT)`
    /// with `rectangle: false` (linear flow). This reads exactly the visible
    /// rows and ignores scrollback. Empty viewports return an empty string.
    ///
    /// Thread-safe: acquires a lease for the same native surface used by
    /// `receive(_:)`, preventing reads against a surface while it is being
    /// detached or replaced.
    public func readViewportText() -> String? {
        guard let lease = beginLease() else { return nil }
        defer { lease.release() }
        let surface = lease.state.surface

        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            return ""
        }
        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    @discardableResult
    public func receive(_ data: Data) -> Bool {
        while true {
            if let lease = beginLease() {
                defer { lease.release() }
                let surface = lease.state.surface

                TerminalDebugLog.log(
                    .output,
                    "terminal <- host \(TerminalDebugLog.describe(data))"
                )

                data.withUnsafeBytes { buffer in
                    guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
                }
                return true
            }

            // Re-check the state while holding the same lock used by
            // `flushPending` to publish `ready`. If an attach completed after
            // the failed lease attempt, retry instead of appending to a queue
            // that the attach path has already drained.
            lock.lock()
            if let state = surfaceState, !state.detached {
                if state.ready {
                    lock.unlock()
                    continue
                }
                appendPending(data, to: &state.pending)
            } else {
                // No surface yet — buffer instead of dropping so the shell's
                // first prompt survives the spawn→attach race. Flushed in
                // `setSurface`.
                appendPending(data, to: &pendingPreSurface)
            }
            TerminalDebugLog.log(
                .output,
                "terminal <- host buffered pre-surface \(TerminalDebugLog.describe(data))"
            )
            lock.unlock()
            return false
        }
    }

    /// Atomically replaces the current terminal emulator state with a native
    /// Ghostty snapshot. Invalid snapshots leave the existing terminal
    /// untouched. Callers are responsible for validating the advertised wire
    /// format before invoking this renderer-level API.
    @discardableResult
    public func restoreSnapshot(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard let lease = beginLease() else { return false }
        defer { lease.release() }
        let surface = lease.state.surface

        let restored = data.withUnsafeBytes { buffer -> Bool in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return ghostty_surface_restore_snapshot(surface, pointer, UInt(buffer.count))
        }
        TerminalDebugLog.log(
            .output,
            "terminal native state restore bytes=\(data.count) result=\(restored)"
        )
        return restored
    }

    /// Re-applies the embedder's runtime configuration to the current native
    /// surface. Native snapshot restore replaces the terminal state wholesale;
    /// Ghostty's configured default colors therefore need to be installed again
    /// before the restored session answers OSC 10/11 queries.
    @discardableResult
    func reapplyRuntimeConfig(_ config: ghostty_config_t) -> Bool {
        guard let lease = beginLease() else { return false }
        defer { lease.release() }

        ghostty_surface_update_config(lease.state.surface, config)
        TerminalDebugLog.log(.lifecycle, "in-memory session runtime config reapplied")
        return true
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        guard let lease = beginLease() else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }
        defer { lease.release() }
        let surface = lease.state.surface

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        lock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            lock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        lastResize = mergedResize
        lock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }

    // MARK: - Native surface leases

    /// Appends bytes to a queue while enforcing the bounded pre-surface
    /// retention policy. The caller must hold `lock`.
    private func appendPending(_ data: Data, to queue: inout Data) {
        queue.append(data)
        if queue.count > Self.pendingPreSurfaceCap {
            queue.removeFirst(queue.count - Self.pendingPreSurfaceCap)
        }
    }

    /// Requeues a batch that was removed for an attach flush. It must precede
    /// bytes received after teardown, so prepend rather than append while the
    /// caller holds `lock`.
    private func prependPending(_ data: Data, to queue: inout Data) {
        guard !data.isEmpty else { return }
        var combined = data
        combined.append(queue)
        if combined.count > Self.pendingPreSurfaceCap {
            combined.removeFirst(combined.count - Self.pendingPreSurfaceCap)
        }
        queue = combined
    }

    /// Flushes all bytes accumulated before a surface becomes ready. New
    /// receives during a flush land in `SurfaceState.pending`; the final
    /// empty check and `ready` publication happen under `lock`, so no receive
    /// can append to an abandoned queue after the attach completes.
    private func flushPending(for state: SurfaceState) -> Int {
        var flushedBytes = 0
        while true {
            let pending: Data
            lock.lock()
            guard surfaceState === state, !state.detached else {
                lock.unlock()
                return flushedBytes
            }
            guard !state.pending.isEmpty else {
                state.ready = true
                lock.unlock()
                return flushedBytes
            }
            pending = state.pending
            state.pending.removeAll(keepingCapacity: false)
            lock.unlock()

            guard let lease = beginLease(for: state, requireReady: false) else {
                // Teardown may have detached the state after the queue was
                // moved out. Keep those bytes for the next surface instead of
                // silently dropping them.
                lock.lock()
                prependPending(pending, to: &pendingPreSurface)
                lock.unlock()
                return flushedBytes
            }
            pending.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                ghostty_surface_write_buffer(state.surface, ptr, UInt(buffer.count))
            }
            lease.release()
            flushedBytes += pending.count
        }
    }

    /// Acquires a lease for the currently attached, ready surface. The state
    /// is retained by the lease after detachment, so the native pointer cannot
    /// be freed while a C call is still using it.
    private func beginLease(
        for requestedState: SurfaceState? = nil,
        requireReady: Bool = true
    ) -> SurfaceLease? {
        lock.lock()
        let state = requestedState ?? surfaceState
        guard let state,
              !state.detached,
              (!requireReady || state.ready),
              surfaceState === state
        else {
            lock.unlock()
            return nil
        }
        state.activeCalls += 1
        lock.unlock()
        return SurfaceLease(owner: self, state: state)
    }

    private func release(_ lease: SurfaceLease) {
        lease.state.callLock.unlock()
        var callbacks: [@Sendable () -> Void] = []
        lock.lock()
        lease.state.activeCalls -= 1
        if lease.state.detached, lease.state.activeCalls == 0 {
            callbacks = lease.state.drainedCallbacks
            lease.state.drainedCallbacks.removeAll()
        }
        lock.unlock()
        callbacks.forEach { $0() }
    }
}
