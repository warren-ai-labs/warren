//
//  TerminalSurfaceCoordinator.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalSurfaceCoordinator` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization, and frame rendering via scheduled wakeups.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet {
            bridge.delegate = delegate
            bridge.openURLHandler = (delegate as? TerminalViewState)?.openURLHandler
        }
    }

    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            rebuildIfReady(removingBridgeFrom: oldValue)
        }
    }

    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            rebuildIfReady()
        }
    }

    var surface: TerminalSurface?
    private var bridge: TerminalCallbackBridge

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    var scaleFactor: () -> Double = { 2.0 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?

    /// Called during every teardown path (in-place rebuild, explicit free,
    /// deinit) while the detached surface's orphaned render layer is still
    /// attached to the platform view. In-memory surfaces may defer
    /// `ghostty_surface_free` until background calls drain, so this hook runs
    /// before that deferred free to prevent a CoreAnimation commit from
    /// reaching the stale layer delegate.
    ///
    /// On iOS ghostty's Metal renderer `addSublayer`s its own `IOSurfaceLayer`
    /// onto the view (the view's own backing layer is readonly, so it cannot
    /// render into it). `ghostty_surface_free` frees the Zig surface but leaves
    /// that sublayer in place with its delegate still pointing at the freed
    /// surface; the next CoreAnimation commit messages the dangling delegate and
    /// crashes. Platform views use this hook to nil the delegate and drop the
    /// layer before any commit can reach it. See
    /// `UITerminalView.detachOrphanedSurfaceLayers`.
    var onSurfaceLayersOrphaned: (() -> Void)?

    /// Called at the end of every coordinator `tick`, after the render
    /// *request* — the actual presentation happens asynchronously on
    /// ghostty's renderer thread.
    ///
    /// When `synchronizeMetrics` sends a new pixel size to ghostty via
    /// `setSize`, the underlying IOSurface is not rebuilt synchronously.
    /// Until the next full render pass ghostty still uses the **old**
    /// IOSurface, so it derives an incorrect `contentsScale` for the
    /// IOSurfaceLayer (e.g. old-pixel-height / new-point-height → 4.62
    /// instead of the expected 3.0). This causes a visible "jump" on
    /// every layout change (keyboard show/hide, rotation, color-scheme
    /// toggle, etc.).
    ///
    /// Platform views use this hook to silently enforce the correct
    /// `contentsScale` and `frame` on sublayers after each render,
    /// correcting any drift introduced by ghostty within a single frame.
    var onPostRender: (() -> Void)?

    private var lastMetrics: TerminalViewportMetrics?

    /// The last `(scale, pixel size)` sent to ghostty. Layout passes and
    /// settle resyncs re-run `synchronizeMetrics` far more often than the
    /// size changes, and ghostty ignores same-size resizes internally —
    /// skipping the send saves the Swift→C round-trips and keeps a `setSize`
    /// debug line meaning a real resize.
    private struct SentSurfaceSize: Equatable {
        var scale: Double
        var pixelWidth: UInt32
        var pixelHeight: UInt32
    }

    private var lastSentSize: SentSurfaceSize?
    private var isDisplayVisible = true
    private var isApplicationActive = true
    private var isSurfaceFocused = false
    /// Warren parks terminal views during an internal tab transition. Keep the
    /// Ghostty surface logically focused while it is parked so that its PTY
    /// does not receive a focus-loss report for a UI-only lifecycle change.
    private var suppressFocusLossReports = false
    private var pendingImmediateTick = true
    private var tickScheduled = false
    private var lastCreateFailureAt: TimeInterval?

    /// Cooldown before `fitToSize` may retry a surface create after
    /// `ghostty_surface_new` failed. A full create is expensive (font grid,
    /// Metal pipeline, compiled link regexes) and a failure can be *persistent*
    /// — with the display asleep every attempt fails identically
    /// (`error.OutOfMemory`), and each failed attempt strands a few KB inside
    /// ghostty's error path. Without this, the layout/settle-resync cadence
    /// retried at ~200/s and leaked ~1 GB/min for as long as the display
    /// stayed dark. Deliberate triggers (controller/configuration change,
    /// window attach) bypass the cooldown via `rebuildIfReady` directly.
    private static let createRetryCooldown: TimeInterval = 2.0

    init() {
        bridge = TerminalCallbackBridge()
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
        bridge.onRenderRequest = { [weak self] in
            self?.requestImmediateTick()
        }
    }

    func requestImmediateTick() {
        pendingImmediateTick = true
        scheduleTickIfNeeded()
    }

    /// Ghostty owns frame pacing with its renderer-thread CVDisplayLink. This
    /// compatibility hook only asks the app mailbox to make one progress turn;
    /// it must not create a second display loop in Swift.
    func startRenderScheduling() {
        requestImmediateTick()
    }

    /// Kept as a lifecycle hook for platform views. Focus and occlusion are
    /// propagated through the surface APIs; there is no Swift display loop to
    /// stop here.
    func stopRenderScheduling() {
        tickScheduled = false
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }
        guard hasValidViewSize else {
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface rebuild skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let scale = sanitizedScaleFactor()
        TerminalDebugLog.log(
            .lifecycle,
            "surface rebuild scale=\(String(format: "%.2f", scale)) \(configuration.debugSummary)"
        )
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration,
            platformSetup: { [self] config in
                platformSetup?(&config)
                config.scale_factor = scale
            }
        )
        guard let rawSurface else {
            lastCreateFailureAt = Self.monotonicTimestamp()
            TerminalDebugLog.log(.lifecycle, "surface rebuild failed")
            return
        }

        lastCreateFailureAt = nil
        bridge.rawSurface = rawSurface
        let newSurface = TerminalSurface(rawSurface)
        surface = newSurface
        newSurface.setOcclusion(effectiveSurfaceVisible)
        controller.shouldProcessWakeup = { [weak self] in
            self?.canRenderFrame == true
        }
        controller.onWakeup = { [weak self] in
            self?.requestImmediateTick()
        }
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        (delegate as? any TerminalSurfaceLifecycleDelegate)?
            .terminalDidAttachSurface(newSurface)
        synchronizeMetrics()
        requestImmediateTick()
    }

    // MARK: - Metrics

    func synchronizeMetrics() {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "synchronizeMetrics skipped: missing surface")
            return
        }

        let scale = sanitizedScaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let pixelWidth = UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid pixel size=\(pixelWidth)x\(pixelHeight)"
            )
            return
        }

        let sentSize = SentSurfaceSize(
            scale: scale,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        if sentSize != lastSentSize {
            TerminalDebugLog.log(
                .metrics,
                "sync view=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale)) pixels=\(pixelWidth)x\(pixelHeight)"
            )
            // Record before sending — setSize can re-enter synchronizeMetrics
            // via a synchronous cell-size callback.
            lastSentSize = sentSize
            surface.setContentScale(x: scale, y: scale)
            surface.setSize(width: pixelWidth, height: pixelHeight)
        }

        guard let surfaceSize = surface.size(),
              surfaceSize.columns > 0, surfaceSize.rows > 0
        else {
            TerminalDebugLog.log(.metrics, "sync missing grid metrics after resize")
            onMetricsUpdate?()
            return
        }

        let metrics = TerminalViewportMetrics(surfaceSize: surfaceSize, scale: scale)
        guard metrics != lastMetrics else {
            TerminalDebugLog.log(
                .metrics,
                "sync unchanged \(metrics.debugSummary)"
            )
            onMetricsUpdate?()
            return
        }

        lastMetrics = metrics
        TerminalDebugLog.log(.metrics, "sync updated \(metrics.debugSummary)")
        configuration.inMemorySession?.updateViewport(surfaceSize)
        if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
            delegate.terminalDidResize(surfaceSize)
        } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
            delegate.terminalDidResize(
                columns: Int(surfaceSize.columns),
                rows: Int(surfaceSize.rows)
            )
        }
        onMetricsUpdate?()
    }

    func fitToSize() {
        if surface == nil {
            guard canRetryCreate else { return }
            rebuildIfReady()
        } else {
            synchronizeMetrics()
        }
        if surface != nil {
            requestImmediateTick()
        }
    }

    private var canRetryCreate: Bool {
        guard let lastCreateFailureAt else { return true }
        return Self.monotonicTimestamp() - lastCreateFailureAt >= Self.createRetryCooldown
    }

    func setDisplayVisible(_ visible: Bool) {
        guard isDisplayVisible != visible else {
            surface?.setOcclusion(effectiveSurfaceVisible)
            return
        }

        isDisplayVisible = visible
        surface?.setOcclusion(effectiveSurfaceVisible)

        if canRenderFrame {
            requestImmediateTick()
        } else {
            stopRenderScheduling()
        }
    }

    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else {
            if active {
                renderImmediately()
            } else {
                stopRenderScheduling()
            }
            return
        }

        isApplicationActive = active
        surface?.setOcclusion(effectiveSurfaceVisible)

        if active {
            synchronizeMetrics()
            renderImmediately()
        } else {
            stopRenderScheduling()
        }
    }

    // MARK: - Frame Rendering

    func tick() {
        guard shouldRenderFrame else {
            return
        }
        pendingImmediateTick = false
        TerminalDebugLog.log(.render, "tick")
        controller?.tick()
        // Never pair this with `surface.draw()`: draw presents inline on the
        // main thread while renderer-thread frames present via blocks queued
        // to the main runloop, and ghostty discards only wrong-*sized* stale
        // frames — an already-queued older frame could land after the newer
        // inline one, briefly rolling part of the pane's content backwards
        // around output bursts. Resize repaints stay synchronous inside
        // ghostty via the layer's `needsDisplayOnBoundsChange` callback.
        surface?.refresh()
        onPostRender?()
    }

    // MARK: - Focus

    func setFocusLossReportingSuppressed(_ suppressed: Bool) {
        suppressFocusLossReports = suppressed
        TerminalDebugLog.log(
            .lifecycle,
            "focus loss reporting suppressed=\(suppressed)"
        )
    }

    func setFocus(_ focused: Bool) {
        if !focused, suppressFocusLossReports {
            TerminalDebugLog.log(.lifecycle, "focus=false suppressed")
            return
        }
        isSurfaceFocused = focused
        requestImmediateTick()
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        surface?.setFocus(focused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    deinit {
        // `@MainActor` classes have a nonisolated deinit by default, but
        // `tearDownSurface` calls methods on other main-actor types (surface,
        // bridge, controller). We rely on deinit running synchronously with
        // exclusive access; assume main-actor isolation so teardown can run
        // inline without crossing isolation.
        MainActor.assumeIsolated {
            tearDownSurface(removingBridgeFrom: controller)
        }
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        tickScheduled = false
        let detachingSurface = surface
        let detachingBridge = bridge
        let expectedSurface = detachingSurface?.rawValue
        let hadSurface = detachingSurface != nil
        let shouldClearFocus = !suppressFocusLossReports

        // Stop routing callbacks from the old surface before it is freed. A
        // rebuild gets a fresh bridge below, so an in-flight old callback can
        // never be delivered to the new surface's delegate.
        detachingBridge.rawSurface = nil
        detachingBridge.delegate = nil
        detachingBridge.onCellSizeChange = nil
        detachingBridge.onRenderRequest = nil

        // The native surface stores the host-managed callbacks as unretained
        // pointers. Keep the session alive until `ghostty_surface_free` has
        // joined its IO thread; otherwise an old view can be torn down while
        // that thread is still dispatching a final output callback.
        let release: @MainActor @Sendable () -> Void
        if let session = configuration.inMemorySession {
            release = {
                // Keep the unretained host callback target alive through the
                // synchronous native teardown. `withExtendedLifetime` is
                // intentional: a capture list alone is optimized away when
                // the captured value is not otherwise referenced.
                withExtendedLifetime(session) {
                    if shouldClearFocus {
                        detachingSurface?.setFocus(false)
                    }
                    detachingSurface?.free()
                    controller?.remove(detachingBridge)
                }
            }
        } else {
            release = {
                if shouldClearFocus {
                    detachingSurface?.setFocus(false)
                }
                detachingSurface?.free()
                controller?.remove(detachingBridge)
            }
        }

        if let session = configuration.inMemorySession {
            // `ghostty_surface_write_buffer` can wait for the main runloop.
            // Detach the session now, but delay native free until every call
            // that already borrowed the pointer has returned.
            let onDrained: @Sendable () -> Void = {
                Task { @MainActor in
                    release()
                }
            }
            let matched = session.clearSurface(
                ifMatches: expectedSurface,
                onDrained: onDrained
            )
            if !matched {
                Task { @MainActor in
                    release()
                }
            }
        } else {
            Task { @MainActor in
                release()
            }
        }
        controller?.onWakeup = nil
        controller?.shouldProcessWakeup = nil
        // SwiftUI can replace an AppTerminalView while the old view is still
        // being released. Each view owns its own coordinator/surface, but the
        // delegate's `surface` is shared state; an old view's teardown must not
        // clear a newer surface that has already been installed.
        let detachIsCurrent = (delegate as? TerminalViewState).map {
            $0.surface === detachingSurface
        } ?? true
        if suppressFocusLossReports {
            TerminalDebugLog.log(.lifecycle, "surface teardown focus=false suppressed")
        } else {
            TerminalDebugLog.log(.lifecycle, "surface teardown focus=false deferred")
        }
        surface = nil
        // The platform hook must run before the next CoreAnimation commit can
        // observe a layer belonging to the detached surface. It is safe to
        // clear the orphaned layer before the deferred native free; the
        // release callback above still performs the final free on the main
        // actor once all in-flight C calls have drained.
        if hadSurface { onSurfaceLayersOrphaned?() }
        lastMetrics = nil
        lastSentSize = nil
        pendingImmediateTick = true
        if hadSurface, detachIsCurrent {
            (delegate as? any TerminalSurfaceLifecycleDelegate)?
                .terminalDidDetachSurface()
        }

        if hadSurface {
            bridge = TerminalCallbackBridge()
            bridge.onCellSizeChange = { [weak self] width, height in
                self?.handleCellSizeChange(width: width, height: height)
            }
            bridge.onRenderRequest = { [weak self] in
                self?.requestImmediateTick()
            }
            bridge.delegate = delegate
            bridge.openURLHandler = (delegate as? TerminalViewState)?.openURLHandler
        }
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)"
        )
        synchronizeMetrics()
        requestImmediateTick()
        onCellSizeDidChange?()
    }

    private var shouldRenderFrame: Bool {
        canRenderFrame && pendingImmediateTick
    }

    private func scheduleTickIfNeeded() {
        guard canRenderFrame else {
            tickScheduled = false
            return
        }
        guard !tickScheduled else {
            return
        }
        tickScheduled = true
        TerminalDebugLog.log(.lifecycle, "tick scheduled")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            tickScheduled = false
            tick()
        }
    }

    private static func monotonicTimestamp() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// `scaleFactor()` guarded against degenerate values. While the display is
    /// asleep AppKit can report a zero backing scale; fed into
    /// `ghostty_surface_new` as `scale_factor` that becomes a 0 DPI → 0 cell
    /// size, and libghostty (built ReleaseFast, no checked arithmetic) turns
    /// the grid division into a garbage-huge allocation that fails with
    /// `error.OutOfMemory`. Clamp to the Retina default instead — a wrong-but-
    /// sane scale is corrected by the next `viewDidChangeBackingProperties`.
    func sanitizedScaleFactor() -> Double {
        let scale = scaleFactor()
        guard scale.isFinite, scale > 0 else { return 2.0 }
        return scale
    }

    private var effectiveSurfaceVisible: Bool {
        isDisplayVisible && isApplicationActive
    }

    private var canRenderFrame: Bool {
        effectiveSurfaceVisible && isAttached()
    }

    private var hasValidViewSize: Bool {
        let size = viewSize()
        return size.width > 0 && size.height > 0
    }

    private func renderImmediately() {
        guard canRenderFrame else {
            tickScheduled = false
            return
        }

        pendingImmediateTick = true
        tickScheduled = false
        tick()
    }
}
