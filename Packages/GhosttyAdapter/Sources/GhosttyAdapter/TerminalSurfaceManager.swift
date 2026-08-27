import AppKit
import SwiftUI
import WarrenDomain

public enum TerminalSurfaceResidency: String, Equatable, Sendable {
    case active
    case warm
    case cold
}

public struct TerminalSurfaceRetentionPolicy: Equatable, Sendable {
    public static let defaultWarmLimit = 8
    public static let defaultWarmByteLimit = 1024 * 1024 * 1024

    public let warmLimit: Int
    public let warmByteLimit: Int
    public private(set) var activeSessionID: TerminalSessionID?
    public private(set) var warmSessionIDs: [TerminalSessionID] = []
    private var estimatedBytesBySessionID: [TerminalSessionID: Int] = [:]

    public init(
        warmLimit: Int = TerminalSurfaceRetentionPolicy.defaultWarmLimit,
        warmByteLimit: Int = TerminalSurfaceRetentionPolicy.defaultWarmByteLimit
    ) {
        self.warmLimit = max(0, warmLimit)
        self.warmByteLimit = max(0, warmByteLimit)
    }

    @discardableResult
    public mutating func activate(_ sessionID: TerminalSessionID) -> [TerminalSessionID] {
        if let previous = activeSessionID, previous != sessionID {
            warmSessionIDs.removeAll { $0 == previous }
            warmSessionIDs.insert(previous, at: 0)
        }
        warmSessionIDs.removeAll { $0 == sessionID }
        activeSessionID = sessionID
        return trimWarmSessions()
    }

    @discardableResult
    public mutating func deactivate() -> [TerminalSessionID] {
        if let activeSessionID {
            warmSessionIDs.removeAll { $0 == activeSessionID }
            warmSessionIDs.insert(activeSessionID, at: 0)
        }
        activeSessionID = nil
        return trimWarmSessions()
    }

    public mutating func remove(_ sessionID: TerminalSessionID) {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        warmSessionIDs.removeAll { $0 == sessionID }
        estimatedBytesBySessionID[sessionID] = nil
    }

    @discardableResult
    public mutating func updateEstimatedBytes(
        _ estimatedBytes: Int,
        for sessionID: TerminalSessionID
    ) -> [TerminalSessionID] {
        estimatedBytesBySessionID[sessionID] = max(0, estimatedBytes)
        return trimWarmSessions()
    }

    public func residency(of sessionID: TerminalSessionID) -> TerminalSurfaceResidency {
        if activeSessionID == sessionID { return .active }
        if warmSessionIDs.contains(sessionID) { return .warm }
        return .cold
    }

    public var estimatedWarmBytes: Int {
        warmSessionIDs.reduce(into: 0) { total, sessionID in
            total += estimatedBytesBySessionID[sessionID] ?? 0
        }
    }

    private mutating func trimWarmSessions() -> [TerminalSessionID] {
        var evicted: [TerminalSessionID] = []
        while warmSessionIDs.count > warmLimit || estimatedWarmBytes > warmByteLimit {
            guard let sessionID = warmSessionIDs.popLast() else { break }
            estimatedBytesBySessionID[sessionID] = nil
            evicted.append(sessionID)
        }
        return evicted
    }
}

public struct TerminalPresentationIntent: Equatable, Sendable {
    public let activeSessionID: TerminalSessionID?
    public let viewportSize: CGSize
    public let wantsTerminalFocus: Bool

    public init(
        activeSessionID: TerminalSessionID?,
        viewportSize: CGSize,
        wantsTerminalFocus: Bool
    ) {
        self.activeSessionID = activeSessionID
        self.viewportSize = viewportSize
        self.wantsTerminalFocus = wantsTerminalFocus
    }
}

public struct TerminalSurfaceManagerSnapshot: Equatable, Sendable {
    public let activeSessionID: TerminalSessionID?
    public let warmSessionIDs: [TerminalSessionID]
    public let retainedSurfaceCount: Int
    public let transitionGeneration: UInt64
    public let staleCommandCancellationCount: UInt64
    public let surfaceCreationCount: UInt64
    public let surfaceDisposalCount: UInt64
    public let hiddenRenderAttemptCount: UInt64
    public let estimatedWarmBytes: Int
}

/// The only owner of AppKit terminal views and Ghostty presentation work.
///
/// SwiftUI submits immutable intent. Reconciliation runs on a later main-loop
/// turn, outside `body`, `layout`, and `updateNSView` call stacks.
@MainActor
public final class TerminalSurfaceManager {
    private enum RecoveryPresentationPhase: String {
        /// Recovery bytes may be installed, but user-visible presentation
        /// remains disabled. The renderer may continue behind a transparent
        /// view so queued output can make progress without leaking a partial
        /// frame to the user.
        case recovering
        /// The atomic recovery boundary has arrived. Drawing and presenting
        /// are allowed through the single `schedulePresent` path.
        case ready
    }

    private final class Entry {
        let surface: GhosttySurface
        let view: AppTerminalView
        var transitionGeneration: UInt64 = 0
        var presentationGeneration: UInt64 = 0
        var presentationTask: Task<Void, Never>?
        var recoveryPhase: RecoveryPresentationPhase = .ready
        var displayVisible = false

        init(surface: GhosttySurface, view: AppTerminalView) {
            self.surface = surface
            self.view = view
        }
    }

    private var entries: [TerminalSessionID: Entry] = [:]
    private var policy: TerminalSurfaceRetentionPolicy
    private weak var host: TerminalHostContainerView?
    private var latestIntent = TerminalPresentationIntent(
        activeSessionID: nil,
        viewportSize: .zero,
        wantsTerminalFocus: false
    )
    private var reconcileScheduled = false
    private var transitionGeneration: UInt64 = 0
    private var staleCommandCancellationCount: UInt64 = 0
    private var surfaceCreationCount: UInt64 = 0
    private var surfaceDisposalCount: UInt64 = 0
    /// Surfaces whose background output drain is still in flight. Releasing
    /// them immediately would deallocate the terminal view on the main thread
    /// while the drain holds the in-memory session lock, recreating the
    /// teardown deadlock. They are released after the drain exits.
    private var pendingDisposals: [TerminalSessionID: Entry] = [:]
    private var hiddenRenderAttemptCount: UInt64 = 0
    private var windowObservers: [NSObjectProtocol] = []
    private var onFocused: (TerminalSessionID, TerminalSize?) -> Void = { _, _ in }
    private var onBlurred: (TerminalSessionID) -> Void = { _ in }
    /// Invoked when a retained surface is disposed (warm eviction, tab close,
    /// or shutdown). Owners use this to invalidate recovery anchors that are
    /// only valid while the exact surface instance is still alive.
    public var onSurfaceDisposed: ((TerminalSessionID) -> Void)?

    public init(
        warmLimit: Int = TerminalSurfaceRetentionPolicy.defaultWarmLimit,
        warmByteLimit: Int = TerminalSurfaceRetentionPolicy.defaultWarmByteLimit
    ) {
        policy = TerminalSurfaceRetentionPolicy(
            warmLimit: warmLimit,
            warmByteLimit: warmByteLimit
        )
    }

    public var retainedSurfaceCount: Int { entries.count }

    public var pendingDisposalCount: Int { pendingDisposals.count }

    public func surface(for sessionID: TerminalSessionID) -> GhosttySurface? {
        entries[sessionID]?.surface
    }

    /// Whether the retained surface is the one currently selected by the
    /// mounted terminal host. Cold recovery uses this as a layout barrier:
    /// subscribing before the host becomes active can capture an intermediate
    /// grid and force a second SIGWINCH immediately after the first frame.
    public func isActive(_ sessionID: TerminalSessionID) -> Bool {
        policy.activeSessionID == sessionID
    }

    public func isPresentable(_ sessionID: TerminalSessionID) -> Bool {
        guard isActive(sessionID), let entry = entries[sessionID] else { return false }
        return entry.surface.terminalViewIsPresentable
    }

    /// Whether a surface is safe to use as the destination of an atomic
    /// recovery.  `isPresentable` intentionally only describes AppKit
    /// visibility; a newly mounted view can be visible for one run-loop turn
    /// before Ghostty creates its native surface and publishes grid metrics.
    /// Recovery must wait for all of those pieces so a cold attach cannot
    /// consume a snapshot into a nil/zero-sized renderer.
    public func isReadyForRecovery(_ sessionID: TerminalSessionID) -> Bool {
        guard isActive(sessionID), let entry = entries[sessionID] else { return false }
        return entry.surface.terminalViewIsPresentable
            && entry.surface.terminalSurfaceIsReady
            && entry.surface.terminalViewportIsValid
    }

    /// Gives a mounted cold surface one synchronous opportunity to create its
    /// native Ghostty surface and synchronize metrics.  AppKit may have
    /// delivered `viewDidMoveToWindow` before Warren's reconciliation closure,
    /// or vice versa; retrying through the public manager boundary keeps that
    /// lifecycle race out of the remote model.  The coordinator itself
    /// applies its retry cooldown when surface creation is unavailable.
    @discardableResult
    public func prepareForRecovery(_ sessionID: TerminalSessionID) -> Bool {
        guard let entry = entries[sessionID], policy.activeSessionID == sessionID else {
            scheduleReconciliation()
            return false
        }
        if entry.view.window != nil {
            entry.view.fitToSize()
        } else {
            scheduleReconciliation()
        }
        return isReadyForRecovery(sessionID)
    }

    /// Returns true only when the active native view owns keyboard focus in a
    /// key window.  A cold subscriber uses this to decide whether it may claim
    /// the shared runtime's resize/control lease before its checkpoint.
    public func ownsTerminalFocus(_ sessionID: TerminalSessionID) -> Bool {
        guard isActive(sessionID),
              let entry = entries[sessionID],
              let window = entry.view.window,
              window.isKeyWindow,
              !entry.view.isHidden,
              entry.surface.terminalSurfaceIsReady else { return false }
        return window.firstResponder === entry.view
    }

    public func isDisplayVisible(_ sessionID: TerminalSessionID) -> Bool {
        entries[sessionID]?.displayVisible == true
    }

    public func insert(_ surface: GhosttySurface, recoveryGated: Bool = false) {
        guard entries[surface.id] == nil else { return }
        let view = AppTerminalView(frame: .zero)
        view.delegate = surface.state
        view.controller = surface.state.controller
        view.configuration = surface.state.configuration
        view.setFocusLossReportingSuppressed(true)
        view.isHidden = true
        surface.mountedTerminalView = view
        let entry = Entry(surface: surface, view: view)
        setDisplayVisible(false, for: entry)
        entry.recoveryPhase = recoveryGated ? .recovering : .ready
        entries[surface.id] = entry
        surfaceCreationCount &+= 1
        scheduleReconciliation()
    }

    public func remove(_ sessionID: TerminalSessionID) {
        policy.remove(sessionID)
        dispose(sessionID)
    }

    public func removeAll(except liveSessionIDs: Set<TerminalSessionID>) {
        for sessionID in Array(entries.keys) where !liveSessionIDs.contains(sessionID) {
            policy.remove(sessionID)
            dispose(sessionID)
        }
    }

    public func shutdown() {
        transitionGeneration &+= 1
        removeWindowObservers()
        for sessionID in Array(entries.keys) {
            policy.remove(sessionID)
            dispose(sessionID)
        }
        host = nil
        latestIntent = TerminalPresentationIntent(
            activeSessionID: nil,
            viewportSize: .zero,
            wantsTerminalFocus: false
        )
    }

    public func apply(font: TerminalFontPreference) {
        entries.values.forEach { $0.surface.apply(font: font) }
    }

    public func submit(
        host: TerminalHostContainerView,
        intent: TerminalPresentationIntent,
        onFocused: @escaping (TerminalSessionID, TerminalSize?) -> Void,
        onBlurred: @escaping (TerminalSessionID) -> Void
    ) {
        let needsReconciliation = self.host !== host || latestIntent != intent
        self.host = host
        host.manager = self
        latestIntent = intent
        self.onFocused = onFocused
        self.onBlurred = onBlurred
        if needsReconciliation {
            scheduleReconciliation()
        }
    }

    public func disconnect(host: TerminalHostContainerView) {
        guard self.host === host else { return }
        transitionGeneration &+= 1
        if let activeSessionID = policy.activeSessionID {
            demote(activeSessionID)
        }
        let evicted = policy.deactivate()
        evicted.forEach(dispose)
        removeWindowObservers()
        self.host = nil
    }

    public func hostDidLayout(_ host: TerminalHostContainerView, size: CGSize) {
        guard self.host === host else { return }
        guard latestIntent.viewportSize != size else {
            guard let sessionID = policy.activeSessionID,
                  let entry = entries[sessionID],
                  entry.presentationTask == nil else { return }
            guard !entry.surface.terminalViewIsPresentable
                || !entry.surface.terminalSurfaceIsReady else { return }
            schedulePresent(entry, generation: entry.transitionGeneration)
            return
        }
        latestIntent = TerminalPresentationIntent(
            activeSessionID: latestIntent.activeSessionID,
            viewportSize: size,
            wantsTerminalFocus: latestIntent.wantsTerminalFocus
        )
        scheduleReconciliation()
    }

    public func requestFocusForActiveSurface() {
        guard let sessionID = policy.activeSessionID else { return }
        focus(sessionID, generation: transitionGeneration)
    }

    public func requestPresent(_ sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else {
            hiddenRenderAttemptCount &+= 1
            TerminalDiagnostics.log("present_request_dropped", [
                "session": sessionID.description,
                "reason": "surface_absent",
            ])
            return
        }
        if entry.recoveryPhase == .recovering {
            TerminalDiagnostics.log("present_request_deferred", [
                "session": sessionID.description,
                "reason": "recovery_gate",
            ])
            return
        }
        guard policy.activeSessionID == sessionID else {
            // Keep the request until the lifecycle transition activates this
            // surface. A network recovery can complete before SwiftUI's
            // reconciliation turn; dropping the request here leaves the
            // newly attached pane permanently black until a second tab switch.
            TerminalDiagnostics.log("present_request_deferred", [
                "session": sessionID.description,
                "reason": "inactive_surface",
                "active": policy.activeSessionID?.description ?? "nil",
            ])
            scheduleReconciliation()
            return
        }
        schedulePresent(entry, generation: entry.transitionGeneration)
    }

    /// Prevents automatic presentation while a remote recovery is staged.
    /// The surface remains mounted but hidden until `endRecovery` confirms
    /// that the target sequence has rendered.
    public func beginRecovery(for sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else { return }
        entry.recoveryPhase = .recovering
        cancelPresentation(for: entry)
        setDisplayVisible(false, for: entry)
        // Keep the native renderer alive while the recovery stream is being
        // staged, but hide its pixels until the matching `synced` boundary.
        // `setDisplayVisible(false)` intentionally stops the coordinator's
        // wakeups; enabling it again here lets Ghostty consume queued output
        // without exposing a partially restored frame.
        prepareHiddenRendering(for: entry)
    }

    public func endRecovery(for sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else { return }
        entry.recoveryPhase = .ready
        if policy.activeSessionID == sessionID {
            // Keep the pixels hidden until schedulePresent has observed that
            // the restored state and the target live bytes have reached the
            // native surface. The renderer itself stays enabled so a hidden
            // promotion cannot wait on its own display wakeup.
            setDisplayVisible(false, for: entry)
            prepareHiddenRendering(for: entry)
            schedulePresent(entry, generation: entry.transitionGeneration)
        } else {
            // The remote marker can arrive before the AppKit reconciliation
            // that activates this surface. Reconcile the ready phase into the
            // mounted host rather than requiring a second tab switch.
            scheduleReconciliation()
        }
    }

    public func enqueueRawOutput(_ data: Data, for sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else { return }
        entry.surface.outputWriter.enqueueRaw(data)
    }

    public func resetOutput(
        for sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64
    ) {
        guard let entry = entries[sessionID] else { return }
        entry.surface.outputWriter.reset(epoch: epoch, sequence: sequence)
    }

    public func enqueueOutput(
        _ data: Data,
        for sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64
    ) {
        guard let entry = entries[sessionID] else { return }
        entry.surface.outputWriter.enqueue(epoch: epoch, sequence: sequence, payload: data)
    }

    @discardableResult
    public func restoreSnapshot(
        _ data: Data,
        for sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64
    ) -> Bool {
        guard let entry = entries[sessionID] else { return false }
        return entry.surface.restoreSnapshot(data, epoch: epoch, sequence: sequence)
    }

    public func endSearch(in sessionID: TerminalSessionID) {
        entries[sessionID]?.surface.endSearch()
    }

    public func endAllSearches() {
        entries.values.forEach { $0.surface.endSearch() }
    }

    public func snapshot() -> TerminalSurfaceManagerSnapshot {
        TerminalSurfaceManagerSnapshot(
            activeSessionID: policy.activeSessionID,
            warmSessionIDs: policy.warmSessionIDs,
            retainedSurfaceCount: entries.count,
            transitionGeneration: transitionGeneration,
            staleCommandCancellationCount: staleCommandCancellationCount,
            surfaceCreationCount: surfaceCreationCount,
            surfaceDisposalCount: surfaceDisposalCount,
            hiddenRenderAttemptCount: hiddenRenderAttemptCount,
            estimatedWarmBytes: policy.estimatedWarmBytes
        )
    }

    private func scheduleReconciliation() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reconcileScheduled = false
            reconcile()
        }
    }

    private func reconcile() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        let nextSessionID = latestIntent.activeSessionID
        let previousSessionID = policy.activeSessionID

        if previousSessionID != nextSessionID, let previousSessionID {
            demote(previousSessionID)
        }

        var evicted: [TerminalSessionID]
        if let nextSessionID, entries[nextSessionID] != nil {
            evicted = policy.activate(nextSessionID)
            evicted.append(contentsOf: policy.updateEstimatedBytes(
                estimatedSurfaceBytes(in: host),
                for: nextSessionID
            ))
        } else {
            evicted = policy.deactivate()
        }
        evicted.forEach(dispose)
        let retainedSessionIDs = Set(
            policy.warmSessionIDs + [policy.activeSessionID].compactMap { $0 }
        )
        for sessionID in Array(entries.keys) where !retainedSessionIDs.contains(sessionID) {
            dispose(sessionID)
        }

        guard let nextSessionID,
              let entry = entries[nextSessionID],
              let host else { return }
        entry.transitionGeneration = generation
        attach(entry, sessionID: nextSessionID, to: host, generation: generation)
    }

    private func attach(
        _ entry: Entry,
        sessionID: TerminalSessionID,
        to host: TerminalHostContainerView,
        generation: UInt64
    ) {
        // SwiftUI can submit the terminal host before its pane constraints have
        // propagated through AppKit. Flush that pending layout before deriving
        // the frame used to create Ghostty's first grid; otherwise the initial
        // attach can capture an intermediate viewport and only a later manual
        // resize will correct the PTY/cell geometry.
        host.window?.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        // The host's measured bounds are authoritative after the layout flush.
        // The intent can still contain the size from the preceding
        // NSViewRepresentable update while SwiftUI is committing a new pane
        // frame; using that stale request would recreate the same first-grid
        // mismatch even though AppKit already knows the final size.
        let viewport = sanitizedViewport(host.bounds.size, fallback: latestIntent.viewportSize)
        // Keep an already-visible active surface visible across an ordinary
        // geometry-only reconciliation (window resize, fullscreen settle,
        // etc.). Tab promotion and recovery enter this path with either a
        // parked view or a closed recovery gate, so they still remain
        // occluded until schedulePresent has caught the stream up.
        let preserveDisplay = entry.view.superview === host
            && !entry.view.isHidden
            && entry.displayVisible
            && entry.recoveryPhase == .ready
        cancelPresentation(for: entry)
        if !preserveDisplay {
            setDisplayVisible(false, for: entry)
            entry.view.alphaValue = 0
            entry.view.isHidden = true
        }
        if entry.view.superview !== host {
            entry.view.removeFromSuperview()
            entry.view.frame = CGRect(origin: .zero, size: viewport)
            host.addSubview(entry.view)
        } else if entry.view.frame.size != viewport {
            entry.view.setFrameSize(viewport)
        }

        installWindowObservers(for: host.window)
        DispatchQueue.main.async { [weak self, weak host, weak entry] in
            guard let self, let host, let entry else { return }
            guard isCurrent(
                sessionID,
                entry: entry,
                host: host,
                generation: generation,
                requiresVisibleView: false
            ) else {
                // During cold app launch SwiftUI may mount the host before its
                // window exists.  Treating that first turn as a stale attach
                // leaves the surface hidden forever until a second tab switch
                // schedules another reconciliation.  Retry once the host is
                // attached to a window; reconciliation will invalidate this
                // generation if the user selected another tab meanwhile.
                if self.host === host,
                   self.entries[sessionID] === entry,
                   self.latestIntent.activeSessionID == sessionID {
                    TerminalDiagnostics.log("attach_waiting_for_window", [
                        "session": sessionID.description,
                    ])
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self, weak host, weak entry] in
                        guard let self, let host, let entry,
                              self.host === host,
                              self.entries[sessionID] === entry,
                              self.latestIntent.activeSessionID == sessionID else { return }
                        self.scheduleReconciliation()
                    }
                } else {
                    self.staleCommandCancellationCount &+= 1
                }
                return
            }
            entry.view.isHidden = false
            entry.view.alphaValue = preserveDisplay ? 1 : 0
            if !preserveDisplay {
                // A warm surface can have accumulated more output than
                // Ghostty has rendered while it was parked. Keep its pixels
                // transparent until schedulePresent observes the writer
                // caught up; otherwise tab promotion visibly fast-forwards
                // through that backlog. The native renderer remains enabled
                // behind the transparent view so the queue can make progress.
                self.setDisplayVisible(false, for: entry)
                self.prepareHiddenRendering(for: entry)
            }
            entry.view.fitToSize()
            entry.surface.resyncIfNeeded()
            schedulePresent(entry, generation: generation)
            if latestIntent.wantsTerminalFocus {
                focus(sessionID, generation: generation)
            }
        }
    }

    private func demote(_ sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else { return }
        entry.transitionGeneration &+= 1
        cancelPresentation(for: entry)
        entry.surface.captureReattachAnchor()
        entry.view.setFocusLossReportingSuppressed(true)
        if entry.view.window?.firstResponder === entry.view {
            entry.view.window?.makeFirstResponder(nil)
        }
        setDisplayVisible(false, for: entry)
        entry.view.alphaValue = 0
        entry.view.isHidden = true
        entry.view.removeFromSuperview()
        onBlurred(sessionID)
    }

    private func dispose(_ sessionID: TerminalSessionID) {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        entry.transitionGeneration &+= 1
        cancelPresentation(for: entry)
        entry.view.setFocusLossReportingSuppressed(true)
        if entry.view.window?.firstResponder === entry.view {
            entry.view.window?.makeFirstResponder(nil)
        }
        setDisplayVisible(false, for: entry)
        entry.view.alphaValue = 0
        entry.view.isHidden = true
        entry.view.removeFromSuperview()
        entry.surface.mountedTerminalView = nil
        entry.surface.outputWriter.shutdown { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.releasePendingDisposal(entry)
        }
        pendingDisposals[sessionID] = entry
        surfaceDisposalCount &+= 1
        onSurfaceDisposed?(sessionID)
    }

    private func releasePendingDisposal(_ entry: Entry) {
        let sessionID = entry.surface.id
        guard pendingDisposals[sessionID] === entry else { return }
        pendingDisposals.removeValue(forKey: sessionID)
    }

    private func focus(_ sessionID: TerminalSessionID, generation: UInt64) {
        guard let host,
              let window = host.window,
              let entry = entries[sessionID],
              isCurrent(sessionID, entry: entry, host: host, generation: generation),
              window.isKeyWindow else { return }
        guard window.firstResponder === entry.view || window.makeFirstResponder(entry.view) else {
            return
        }
        entry.view.setFocusLossReportingSuppressed(false)
        onFocused(sessionID, entry.surface.terminalSize)
    }

    private func schedulePresent(_ entry: Entry, generation: UInt64) {
        guard entry.recoveryPhase == .ready else { return }
        let sessionID = entry.surface.id
        cancelPresentation(for: entry)
        let presentationGeneration = entry.presentationGeneration
        let targetEpoch = entry.surface.outputWriter.bufferEpoch
        let targetSequence = entry.surface.outputWriter.enqueuedSequence
        if !entry.displayVisible {
            // A mounted surface can be transparent during a cold recovery or
            // warm promotion. Keep its display wakeups running while the
            // target bytes drain; only the alpha transition below makes the
            // settled frame user-visible.
            prepareHiddenRendering(for: entry)
        }
        entry.presentationTask = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            let stallDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            var extendedWaitLogged = false
            var timeoutLogged = false
            defer {
                if entry.presentationGeneration == presentationGeneration {
                    entry.presentationTask = nil
                }
            }

            while true {
                guard !Task.isCancelled else { return }
                guard isCurrent(
                    sessionID,
                    entry: entry,
                    host: host,
                    generation: generation
                ) else {
                    staleCommandCancellationCount &+= 1
                    return
                }

                let outputReady = outputHasReached(
                    entry.surface,
                    targetEpoch: targetEpoch,
                    targetSequence: targetSequence
                )
                let viewReady = entry.surface.terminalViewIsPresentable
                let timedOut = ContinuousClock.now >= stallDeadline
                if (outputReady || timedOut), viewReady, entry.surface.terminalSurfaceIsReady {
                    if timedOut, !outputReady, !timeoutLogged {
                        timeoutLogged = true
                        TerminalDiagnostics.log("present_wait_timeout", [
                            "session": sessionID.description,
                            "targetEpoch": targetEpoch.map { String($0) } ?? "nil",
                            "targetSequence": String(targetSequence),
                            "renderedEpoch": String(entry.surface.renderedEpoch),
                            "renderedSequence": String(entry.surface.renderedSequence),
                            "enqueuedSequence": String(entry.surface.outputWriter.enqueuedSequence),
                        ])
                    }
                    entry.surface.requestDisplayRefresh()
                    if entry.surface.presentNow() {
                        // Draw once while transparent, then reveal the frame.
                        // A second tick covers renderers that defer their first
                        // draw until the view becomes composited.
                        entry.view.isHidden = false
                        entry.view.alphaValue = 1
                        setDisplayVisible(true, for: entry)
                        entry.surface.requestDisplayRefresh()
                        _ = entry.surface.presentNow()
                        TerminalDiagnostics.log("present_complete", [
                            "session": sessionID.description,
                            "targetEpoch": targetEpoch.map { String($0) } ?? "nil",
                            "targetSequence": String(targetSequence),
                            // The writer sequence at completion time. When
                            // this exceeds targetSequence the presentation
                            // fired while recovery bytes were still being
                            // enqueued: the pane became visible mid-replay.
                            "enqueuedNow": String(entry.surface.outputWriter.enqueuedSequence),
                            "renderedEpoch": String(entry.surface.renderedEpoch),
                            "renderedSequence": String(entry.surface.renderedSequence),
                            "recoveryPhase": entry.recoveryPhase.rawValue,
                        ])
                        return
                    }
                }

                if !extendedWaitLogged, ContinuousClock.now >= stallDeadline {
                    extendedWaitLogged = true
                    TerminalDiagnostics.log("present_wait_extended", [
                        "session": sessionID.description,
                        "targetEpoch": targetEpoch.map { String($0) } ?? "nil",
                        "targetSequence": String(targetSequence),
                        "renderedEpoch": String(entry.surface.renderedEpoch),
                        "renderedSequence": String(entry.surface.renderedSequence),
                        "surfaceReady": entry.surface.terminalSurfaceIsReady ? "true" : "false",
                        "viewPresentable": viewReady ? "true" : "false",
                    ])
                }

                do {
                    try await Task.sleep(
                        for: extendedWaitLogged ? .milliseconds(250) : .milliseconds(16)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func cancelPresentation(for entry: Entry) {
        entry.presentationGeneration &+= 1
        entry.presentationTask?.cancel()
        entry.presentationTask = nil
    }

    private func setDisplayVisible(_ visible: Bool, for entry: Entry) {
        entry.displayVisible = visible
        entry.view.setSurfaceVisible(visible)
    }

    /// Enables Ghostty's wakeups for a surface whose pixels are still hidden
    /// behind a transparent AppKit view. This is deliberately separate from
    /// `displayVisible`: a promotion must render its queued bytes before it is
    /// allowed to become visible, otherwise the user sees a fast-forward or a
    /// permanently black pane when Ghostty is occluded.
    private func prepareHiddenRendering(for entry: Entry) {
        guard entry.view.superview != nil, entry.view.window != nil else { return }
        entry.view.isHidden = false
        entry.view.alphaValue = 0
        entry.view.setSurfaceVisible(true)
    }

    private func outputHasReached(
        _ surface: GhosttySurface,
        targetEpoch: UInt64?,
        targetSequence: UInt64
    ) -> Bool {
        guard let targetEpoch else { return true }
        return surface.renderedEpoch > targetEpoch
            || (surface.renderedEpoch == targetEpoch
                && surface.renderedSequence >= targetSequence)
    }

    private func installWindowObservers(for window: NSWindow?) {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if latestIntent.wantsTerminalFocus {
                    requestFocusForActiveSurface()
                }
                requestPresentForActiveSurface()
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                requestPresentForActiveSurface()
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                requestPresentForActiveSurface()
            }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let sessionID = policy.activeSessionID else { return }
                onBlurred(sessionID)
            }
        })
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private func requestPresentForActiveSurface() {
        guard let sessionID = policy.activeSessionID else { return }
        requestPresent(sessionID)
    }

    private func isCurrent(
        _ sessionID: TerminalSessionID,
        entry: Entry,
        host: TerminalHostContainerView?,
        generation: UInt64,
        requiresVisibleView: Bool = true
    ) -> Bool {
        let transitionIsCurrent = policy.activeSessionID == sessionID
            && entries[sessionID] === entry
            && entry.transitionGeneration == generation
            && transitionGeneration == generation
            && self.host === host
            && entry.view.superview === host
            && entry.view.window != nil
        return transitionIsCurrent && (!requiresVisibleView || !entry.view.isHidden)
    }

    private func sanitizedViewport(_ requested: CGSize, fallback: CGSize) -> CGSize {
        let candidate = requested.width > 0 && requested.height > 0 ? requested : fallback
        return CGSize(width: max(candidate.width, 1), height: max(candidate.height, 1))
    }

    private func estimatedSurfaceBytes(in host: TerminalHostContainerView?) -> Int {
        guard let host else { return 0 }
        let viewport = sanitizedViewport(host.bounds.size, fallback: latestIntent.viewportSize)
        let scale = host.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = viewport.width * scale * viewport.height * scale
        guard pixels.isFinite, pixels > 0 else { return 0 }
        // Triple-buffered BGRA is the dominant predictable surface cost.
        let bytes = pixels * 4 * 3
        guard bytes < Double(Int.max) else { return Int.max }
        return Int(bytes.rounded(.up))
    }
}

@MainActor
public final class TerminalHostContainerView: NSView {
    weak var manager: TerminalSurfaceManager?

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        manager?.hostDidLayout(self, size: bounds.size)
    }
}

public struct TerminalHostRepresentable: NSViewRepresentable {
    public let manager: TerminalSurfaceManager
    public let activeSessionID: TerminalSessionID?
    public let wantsTerminalFocus: Bool
    public let onFocused: (TerminalSessionID, TerminalSize?) -> Void
    public let onBlurred: (TerminalSessionID) -> Void

    public init(
        manager: TerminalSurfaceManager,
        activeSessionID: TerminalSessionID?,
        wantsTerminalFocus: Bool = true,
        onFocused: @escaping (TerminalSessionID, TerminalSize?) -> Void = { _, _ in },
        onBlurred: @escaping (TerminalSessionID) -> Void = { _ in }
    ) {
        self.manager = manager
        self.activeSessionID = activeSessionID
        self.wantsTerminalFocus = wantsTerminalFocus
        self.onFocused = onFocused
        self.onBlurred = onBlurred
    }

    public func makeNSView(context: Context) -> TerminalHostContainerView {
        TerminalHostContainerView(frame: .zero)
    }

    public func updateNSView(_ nsView: TerminalHostContainerView, context: Context) {
        manager.submit(
            host: nsView,
            intent: TerminalPresentationIntent(
                activeSessionID: activeSessionID,
                viewportSize: nsView.bounds.size,
                wantsTerminalFocus: wantsTerminalFocus
            ),
            onFocused: onFocused,
            onBlurred: onBlurred
        )
    }

    public static func dismantleNSView(
        _ nsView: TerminalHostContainerView,
        coordinator: Void
    ) {
        nsView.manager?.disconnect(host: nsView)
    }
}
