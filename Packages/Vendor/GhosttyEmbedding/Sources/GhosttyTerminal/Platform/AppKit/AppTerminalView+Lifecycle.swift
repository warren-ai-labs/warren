//
//  AppTerminalView+Lifecycle.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView {
        func setupTrackingArea() {
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ]
            let area = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override open func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            setupTrackingArea()
        }

        override open var acceptsFirstResponder: Bool {
            true
        }

        override open func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                // A view parked by Warren starts with silent lifecycle focus
                // handling. Becoming a real responder is an explicit return to
                // user-visible focus, so future losses must be reported again.
                core.setFocusLossReportingSuppressed(false)
                focusDidBecomeFirstResponder()
                // First-responder ownership and key-window status are separate.
                // Preserve the binding intent in a non-key window, but keep the
                // Ghostty cursor visually inactive until didBecomeKey.
                core.setFocus(window?.isKeyWindow == true)
                onFocusChange?(true)
            }
            return result
        }

        override open func resignFirstResponder() -> Bool {
            let focusWindow = window
            let wasIntended = focusBinding?.isFocused == true
            let result = super.resignFirstResponder()
            if result {
                inputHandler?.resetModifierState()
                core.setFocus(false)
                focusDidResignFirstResponder(
                    from: focusWindow,
                    wasIntended: wasIntended
                )
            }
            return result
        }

        override open func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            guard let window else {
                // Also invoked from _setWindow: while AppKit holds the
                // view-tree lock; keep Ghostty calls off this path.
                DispatchQueue.main.async { [weak self] in
                    // A tab can be parked and reattached before this deferred
                    // cleanup runs. Do not deliver a stale focus loss to a
                    // view that is already back in a window.
                    guard let self, self.window == nil else { return }
                    self.inputHandler?.resetModifierState()
                    self.core.stopRenderScheduling()
                    self.core.setFocus(false)
                }
                return
            }

            // Observer registration and focus intent stay synchronous. Only
            // the Ghostty surface lifecycle moves off this call:
            // viewDidMoveToWindow runs inside _setWindow: (addSubview) while
            // AppKit holds the view-tree lock. Creating a surface, flushing
            // buffered bytes, or syncing metrics synchronously can block on
            // Ghostty's surface lock while the io thread holds it for a resize
            // callback, inverting lock order and deadlocking the main thread.
            if focusBinding?.isFocused == true {
                requestFocusMove()
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            // Cross-display rescue: AppKit posts didChangeScreen when the
            // window's screen reference changes, even when the new screen
            // has the same backingScaleFactor (in which case
            // viewDidChangeBackingProperties does not fire). Listening
            // here lets us re-run metric sync on every screen transition
            // — required for the case where two displays share scale but
            // differ in geometry / color profile, and harmless when
            // viewDidChangeBackingProperties also fires for the
            // different-scale case.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                // SwiftUI/AppKit can temporarily detach and reattach the
                // terminal view while diffing the view hierarchy. Rebuilding
                // on every reattach discards Ghostty's scrollback/state, so
                // only create a new surface when one does not already exist.
                if self.surface == nil {
                    self.core.rebuildIfReady()
                } else {
                    self.scheduleMetricsSync()
                }
                self.updateMetalLayerMetrics()
                self.updateColorScheme()
                self.core.startRenderScheduling()
            }
        }

        @objc func windowDidBecomeKey(_: Notification) {
            let focused = window?.isKeyWindow == true
                && window?.firstResponder === self
            core.setFocus(focused)
            if !focused,
               focusBinding?.isFocused == true,
               let window,
               window.firstResponder == nil || window.firstResponder === window {
                requestFocusMove()
            }
        }

        @objc func windowDidResignKey(_: Notification) {
            // Key-window status and first-responder ownership are different axes.
            // Dim the cursor to its unfocused (hollow) state via the core — but do
            // NOT write "unfocused" back through the SwiftUI focus binding. The view
            // is still first responder; only the window went non-key. Reporting a
            // focus loss here clears the host's `@FocusState`, and if any host
            // re-render then runs `synchronizeFocus` while the window is non-key, it
            // strips first-responder status for real (`makeFirstResponder(nil)`) — so
            // on reactivation the cursor stays hollow until the user clicks. Ghostty's
            // own macOS app keeps window-key status as separate state for exactly this
            // reason; we mirror that by leaving the binding untouched on key loss.
            inputHandler?.resetModifierState()
            core.setFocus(false)
        }

        @objc func windowDidChangeScreen(_: Notification) {
            // Defer one runloop tick so AppKit's layout pass and the
            // window's new backingScaleFactor have both settled before we
            // re-derive metrics. Calling synchronously can race with the
            // layout pass and re-introduce the drift we're trying to fix.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updateMetalLayerMetrics()
                scheduleMetricsSync()
            }
        }

        private func removeWindowObservers() {
            // Remove any existing key-window observers before registering for the
            // current window. AppKit can move the view directly between windows
            // without an intermediate nil attachment.
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: nil
            )
        }

        override open func setFrameSize(_ newSize: NSSize) {
            let sizeChanged = bounds.size != newSize
            super.setFrameSize(newSize)
            if sizeChanged {
                scheduleMetricsSync()
            }
        }

        override open func layout() {
            super.layout()
            let sizeChanged = bounds.size != lastObservedBoundsSize
            lastObservedBoundsSize = bounds.size
            if sizeChanged {
                scheduleMetricsSync()
            }
            // A SwiftUI/AppKit host can leave this view at an intermediate frame
            // after an *animated or programmatic* grow (window zoom, sidebar
            // toggle): the last `layout()` we get carries mid-animation bounds and
            // no further pass arrives, so the surface stays sized to the stale,
            // smaller width and the content is boxed into a corner of the window.
            // Re-derive metrics one runloop later — by then the host's frame has
            // settled — so the final size is always captured. Coalesced so a burst
            // of layout passes schedules a single catch-up.
            if sizeChanged {
                scheduleSettleResync()
            }
        }

        override open func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            // AppKit guarantees the frame is final here, so an interactive
            // window/split drag that ended between layout passes still lands at
            // the true size (the drag-out-to-grow case).
            scheduleMetricsSync()
        }

        /// Re-fit after the host layout settles. The immediate leg is handled by
        /// `scheduleMetricsSync`; the late leg covers an animated settle whose
        /// final frame lands after the next runloop turn. Both legs run outside
        /// AppKit's layout call stack.
        private func scheduleSettleResync() {
            settleResyncScheduled = true
            settleResyncLateWorkItem?.cancel()
            let late = DispatchWorkItem { [weak self] in self?.resyncAfterLayoutSettle() }
            settleResyncLateWorkItem = late
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: late)
        }

        /// Re-derive metrics using the latest bounds. Do not force a nested AppKit
        /// layout here: resize callbacks can arrive while the display cycle is
        /// already laying out the view tree, and nested layout recreates the
        /// feedback loop this catch-up is meant to avoid.
        private func resyncAfterLayoutSettle() {
            settleResyncScheduled = false
            settleResyncLateWorkItem = nil
            scheduleMetricsSync()
        }

        override open func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateMetalLayerMetrics()
            scheduleMetricsSync()
        }

        /// Defer Ghostty metric work until AppKit has released its view-tree
        /// lock. Multiple frame/layout callbacks in one display interval share
        /// one synchronization, and `core.viewSize` reads the final bounds when
        /// it executes rather than an intermediate frame.
        private func scheduleMetricsSync() {
            guard !metricsSyncScheduled else { return }
            metricsSyncScheduled = true
            metricsSyncGeneration &+= 1
            let generation = metricsSyncGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                guard let self, self.metricsSyncGeneration == generation else { return }
                self.metricsSyncScheduled = false
                guard self.window != nil else { return }
                self.core.fitToSize()
                self.core.requestImmediateTick()
            }
        }

        public func fitToSize() {
            core.fitToSize()
        }

        func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.sanitizedScaleFactor()
            // Write to the actually-attached backing layer (not just the
            // cached `metalLayer` ivar). The render pipeline can swap
            // `self.layer` to an IOSurfaceLayer for IOSurface-backed
            // compositing; once that happens the cached CAMetalLayer
            // reference is detached from the view tree and writes to its
            // contentsScale are no-ops as far as what's visible. The
            // observable symptom is text rendered at half size after the
            // window crosses to a display with a different
            // backingScaleFactor.
            layer?.contentsScale = scale
            if let metal = layer as? CAMetalLayer {
                metal.drawableSize = CGSize(
                    width: bounds.width * scale,
                    height: bounds.height * scale
                )
            }
            // Mirror to the cached ivar in case anything else still
            // reads through it during a transitional layout pass.
            metalLayer?.contentsScale = scale
            metalLayer?.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        func enforceMetalLayerScale() {
            let scale = core.sanitizedScaleFactor()
            if let layer, layer.contentsScale != scale {
                layer.contentsScale = scale
            }
            if let metalLayer, metalLayer.contentsScale != scale {
                metalLayer.contentsScale = scale
            }
        }

        /// macOS counterpart of `UITerminalView.detachOrphanedSurfaceLayers`,
        /// run on every surface teardown via `onSurfaceLayersOrphaned`. On
        /// macOS ghostty installs its renderer by *replacing* the backing
        /// layer with an IOSurfaceLayer (sublayers are the iOS shape), and
        /// `ghostty_surface_free` leaves that layer attached, frozen on its
        /// last frame. Restoring the view's own CAMetalLayer detaches the
        /// orphan; sublayers are left alone — any here belong to consumers.
        func detachOrphanedSurfaceLayers() {
            if let metalLayer, let layer, layer !== metalLayer {
                layer.delegate = nil
                self.layer = metalLayer
                updateMetalLayerMetrics()
            }
        }

        override open func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColorScheme()
        }

        func updateColorScheme() {
            let scheme: TerminalColorScheme = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: .dark
            default: .light
            }
            surface?.setColorScheme(scheme.ghosttyValue)
            if let controller,
               let viewState = delegate as? TerminalViewState,
               viewState.controller === controller
            {
                // viewDidMoveToWindow / viewDidChangeEffectiveAppearance can
                // run inside a SwiftUI update. adopt() publishes objectWillChange
                // synchronously, so defer it one main-actor hop like the other
                // TerminalViewState delegate writes.
                Task { @MainActor [weak viewState] in
                    viewState?.adopt(terminalColorScheme: scheme)
                }
            } else {
                controller?.setColorScheme(scheme)
            }
        }
    }
#endif
