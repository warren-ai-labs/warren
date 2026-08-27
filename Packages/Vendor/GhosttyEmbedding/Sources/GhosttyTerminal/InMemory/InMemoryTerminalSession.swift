//
//  InMemoryTerminalSession.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private let lock = NSLock()
    /// Serializes every C call that reads or mutates the terminal. State
    /// replacement and live output must have one unambiguous ordering.
    private let terminalCallLock = NSLock()
    private var surface: ghostty_surface_t?
    /// Set only after `setSurface` has finished flushing any pre-surface
    /// bytes. `receive` refuses to write while this is false so buffered
    /// output always precedes live output without holding `lock` across a
    /// Ghostty call.
    private var surfaceReady = false
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
        terminalCallLock.lock()
        defer { terminalCallLock.unlock() }
        var pending: Data?
        lock.lock()
        self.surface = surface
        surfaceReady = false
        if surface != nil, !pendingPreSurface.isEmpty {
            pending = pendingPreSurface
            pendingPreSurface.removeAll(keepingCapacity: false)
        }
        lock.unlock()

        // Flush anything the host sent before the surface existed — the
        // shell's first prompt at cold start. The background writer now waits
        // for `surfaceReady`, so this happens before any live byte is written
        // and Ghostty is never called while `lock` is held.
        if let surface, let pending, !pending.isEmpty {
            pending.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
            }
            TerminalDebugLog.log(
                .output,
                "terminal <- host flushed pre-surface \(pending.count) bytes"
            )
        }

        lock.lock()
        if surface != nil, self.surface == surface {
            surfaceReady = true
        }
        lock.unlock()

        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) {
        terminalCallLock.lock()
        defer { terminalCallLock.unlock() }
        lock.lock()
        defer { lock.unlock() }

        guard surface == expectedSurface else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surface == nil ? "nil" : "set")"
            )
            return
        }

        surface = nil
        surfaceReady = false
        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    public var currentSurface: ghostty_surface_t? {
        lock.lock()
        defer { lock.unlock() }
        return surface
    }

    public var isSurfaceReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return surface != nil && surfaceReady
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
    /// Thread-safe: acquires the same `NSLock` as `receive(_:)` and
    /// `setSurface(_:)`, preventing reads against a surface mid-replacement.
    public func readViewportText() -> String? {
        terminalCallLock.lock()
        defer { terminalCallLock.unlock() }
        lock.lock()
        guard let surface, surfaceReady else {
            lock.unlock()
            return nil
        }
        lock.unlock()

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
        terminalCallLock.lock()
        defer { terminalCallLock.unlock() }
        lock.lock()
        guard let surface, surfaceReady else {
            // No surface yet — buffer instead of dropping so the shell's first
            // prompt survives the spawn→attach race. Flushed in `setSurface`.
            pendingPreSurface.append(data)
            if pendingPreSurface.count > Self.pendingPreSurfaceCap {
                pendingPreSurface.removeFirst(pendingPreSurface.count - Self.pendingPreSurfaceCap)
            }
            TerminalDebugLog.log(
                .output,
                "terminal <- host buffered pre-surface \(TerminalDebugLog.describe(data))"
            )
            lock.unlock()
            return false
        }
        lock.unlock()

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

    /// Atomically replaces the current terminal emulator state with a native
    /// Ghostty snapshot. Invalid snapshots leave the existing terminal
    /// untouched. Callers are responsible for validating the advertised wire
    /// format before invoking this renderer-level API.
    @discardableResult
    public func restoreSnapshot(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        terminalCallLock.lock()
        defer { terminalCallLock.unlock() }
        lock.lock()
        guard let surface, surfaceReady else {
            lock.unlock()
            return false
        }
        lock.unlock()

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
        terminalCallLock.lock()
        defer { terminalCallLock.unlock() }
        lock.lock()
        guard let surface, surfaceReady else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            lock.unlock()
            return
        }
        lock.unlock()

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
}
