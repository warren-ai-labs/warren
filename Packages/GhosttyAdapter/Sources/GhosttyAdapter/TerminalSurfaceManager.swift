import AppKit
import SwiftUI
import WarrenDomain

public enum TerminalSurfaceResidency: String, Equatable, Sendable {
    case active
    case warm
    case cold
}

public struct TerminalSurfaceRetentionPolicy: Equatable, Sendable {
    /// How many parked surfaces stay resident behind the active ones.
    ///
    /// A warm surface is what makes an ordinary tab switch a reparent instead of
    /// a cold attach, and a cold attach installs a complete atomic state, which
    /// a TUI repaints end to end. The budget therefore has to cover the Sessions
    /// a user actually cycles through; at 8 a second lap through ten open
    /// Sessions evicted surfaces and turned every revisit into that reflow.
    public static let defaultWarmLimit = 32
    /// Ceiling for the estimated warm-surface memory, which is what actually
    /// evicts on a large viewport: every warm surface keeps its IOSurface
    /// (~86 MB measured at 1512x982), so a count cap alone cannot bind. Sized so
    /// the 32-surface limit is the binding constraint on ordinary displays.
    public static let defaultWarmByteLimit = 3 * 1024 * 1024 * 1024

    public let warmLimit: Int
    public let warmByteLimit: Int
    public private(set) var activeSessionID: TerminalSessionID?
    public private(set) var activeSessionIDs: Set<TerminalSessionID> = []
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
        activeSessionIDs = [sessionID]
        return trimWarmSessions()
    }

    @discardableResult
    public mutating func activateMultiple(_ sessionIDs: Set<TerminalSessionID>, primary: TerminalSessionID?) -> [TerminalSessionID] {
        let removedFromActive = activeSessionIDs.subtracting(sessionIDs)
        for old in removedFromActive.sorted(by: { $0.description < $1.description }) {
            warmSessionIDs.removeAll { $0 == old }
            warmSessionIDs.insert(old, at: 0)
        }
        for newID in sessionIDs.sorted(by: { $0.description < $1.description }) {
            warmSessionIDs.removeAll { $0 == newID }
        }
        activeSessionIDs = sessionIDs
        // A caller can reconcile a new visible set while the previous
        // primary is being dismantled. Never retain a primary that is no
        // longer active; doing so makes residency and focus callbacks point
        // at a stale surface.
        let validPrimary = primary.flatMap { sessionIDs.contains($0) ? $0 : nil }
        activeSessionID = validPrimary
            ?? activeSessionIDs.sorted(by: { $0.description < $1.description }).first
        return trimWarmSessions()
    }

    @discardableResult
    public mutating func deactivate() -> [TerminalSessionID] {
        if let activeSessionID {
            warmSessionIDs.removeAll { $0 == activeSessionID }
            warmSessionIDs.insert(activeSessionID, at: 0)
        }
        for id in activeSessionIDs where id != activeSessionID {
            warmSessionIDs.removeAll { $0 == id }
            warmSessionIDs.insert(id, at: 0)
        }
        activeSessionIDs.removeAll()
        activeSessionID = nil
        return trimWarmSessions()
    }

    public mutating func remove(_ sessionID: TerminalSessionID) {
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        activeSessionIDs.remove(sessionID)
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
        if activeSessionIDs.contains(sessionID) || activeSessionID == sessionID { return .active }
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
    public let activeSessionIDs: Set<TerminalSessionID>
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
        var postRevealRedrawGeneration: UInt64 = 0
        var postRevealRedrawTask: Task<Void, Never>?
        /// Bounded retry that guarantees a promotion eventually draws. A
        /// retained surface whose view was parked needs a reconciliation to
        /// re-mount it, and nothing in SwiftUI re-mounts it when the promotion
        /// does not change the active set; without this the presentation task
        /// can exit before drawing and the pane stays black forever.
        var presentWatchdogTask: Task<Void, Never>?
        var presentWatchdogGeneration: UInt64 = 0
        /// Consecutive promotion retries that failed to draw. Bounds the
        /// watchdog so a surface that can never present cannot reconcile on a
        /// loop; a successful present resets it.
        var presentWatchdogStreak = 0
        var recoveryPhase: RecoveryPresentationPhase = .ready
        var displayVisible = false
        /// Set when a displayed surface is parked and needs the bounded
        /// post-reveal draw after its next warm promotion.
        var warmPromotionPending = false
        /// Reconnect recovery can deliberately keep the old frame visible.
        /// That path must not be treated as an ordinary warm promotion.
        var skipNextWarmPromotionRedraw = false
        /// A transient transport reconnect may keep the last presented frame
        /// visible while the replacement snapshot is installed. The normal
        /// cold-attach path still hides the view behind its recovery gate.
        var preserveDisplayDuringRecovery = false
        /// A preserved frame must wait for the replacement snapshot and its
        /// live tail to render before the next present. Without this bit,
        /// `displayVisible == true` would make `schedulePresent` skip the
        /// output-boundary wait and draw the old grid once more.
        var waitsForRecoveryBoundary = false
        /// Whether the manager has already reported AppKit focus for this
        /// mounted surface. Geometry-only reconciliations must not re-claim
        /// the daemon control lease on every SwiftUI update.
        var focusReported = false
        /// A host can disappear through both SwiftUI dismantling and the
        /// manager's next reconciliation pass. Keep demotion idempotent so a
        /// single pane does not emit duplicate blur callbacks in that race.
        var isDemoted = false
        /// The presentation token that last completed successfully. Native
        /// surface identity matters because a coordinator can rebuild the
        /// underlying Ghostty surface without replacing this entry.
        var lastPresentedSurface: ObjectIdentifier?
        var lastPresentedEpoch: UInt64?
        var lastPresentedSequence: UInt64 = 0
        /// Which path asked for the draw that is in flight, reported by
        /// `present_complete`. A repaint the user did not ask for — during heavy
        /// output, with no resize and no selection — is otherwise
        /// indistinguishable from a promotion that was supposed to happen.
        var pendingPresentReason: String?

        init(surface: GhosttySurface, view: AppTerminalView) {
            self.surface = surface
            self.view = view
        }
    }

    /// Weak box for the per-Session host map. SwiftUI can dismantle a pane
    /// without a final `disconnect`, so a strong map would keep both the
    /// AppKit host and its Ghostty surface alive for the rest of the session.
    private final class WeakHostBox {
        weak var value: TerminalHostContainerView?

        init(_ value: TerminalHostContainerView) {
            self.value = value
        }
    }

    private var entries: [TerminalSessionID: Entry] = [:]
    private var policy: TerminalSurfaceRetentionPolicy
    private weak var host: TerminalHostContainerView?
    private var activeHostBoxes: [TerminalSessionID: WeakHostBox] = [:]
    /// The Desktop root may keep terminal hosts mounted underneath its
    /// embedded editor. This explicit visibility set distinguishes mounted
    /// hosts from Sessions that should currently be active/presented; `nil`
    /// preserves the single-host API's legacy intent until the owner submits
    /// its first set.
    private var requestedActiveSessionIDs: Set<TerminalSessionID>?
    private var latestIntents: [TerminalSessionID: TerminalPresentationIntent] = [:]
    private var focusCallbacks: [TerminalSessionID: (TerminalSessionID, TerminalSize?) -> Void] = [:]
    private var blurCallbacks: [TerminalSessionID: (TerminalSessionID) -> Void] = [:]
    private var latestIntent = TerminalPresentationIntent(
        activeSessionID: nil,
        viewportSize: .zero,
        wantsTerminalFocus: false
    )
    /// Why a reconciliation turn was requested. Recorded with every AppKit
    /// first-responder change so a focus loss can be attributed to the event
    /// that caused it instead of being inferred from the code paths.
    private enum ReconcileReason: String {
        /// A new intent from SwiftUI: tab/session selection or focus intent.
        case intent
        /// Viewport size changed (window resize, sidebar toggle, pane chrome).
        case geometry
        case surfaceInserted
        case recoveryReady
        case presentDeferred
        case recoveryPrepare
        case attachRetry
        /// The owner published a new set of simultaneously visible Sessions
        /// (a split was added, closed, or maximized).
        case visibleSet
        /// A terminal pane was unmounted; the remaining panes reconcile so the
        /// primary slot moves to a host that still exists.
        case hostDisconnected
        case unknown
    }

    private var reconcileScheduled = false
    private var pendingReconcileReason: ReconcileReason?
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
    /// Observer registration is tied to the window. Reinstalling the same
    /// observers for every layout reconciliation creates notification churn and
    /// can race a pending blur; a split window changes its primary Session
    /// without changing the window, so the handlers read the live intent.
    private weak var observedWindow: NSWindow?
    /// Invalidates callbacks queued by an observer that was removed while the
    /// host moved between windows or while SwiftUI replaced the terminal pane.
    private var windowObserverGeneration: UInt64 = 0
    private var windowBlurGeneration: UInt64 = 0
    private var pendingWindowBlurTask: Task<Void, Never>?
    private var onFocused: (TerminalSessionID, TerminalSize?) -> Void = { _, _ in }
    private var onBlurred: (TerminalSessionID) -> Void = { _ in }
    private var resizeDebounceTask: Task<Void, Never>?
    private var resizingUntil: ContinuousClock.Instant?
    /// Test-only observation point for the one-shot redraw. The production
    /// path leaves this nil and performs the native draw directly.
    var postRevealRedrawObserver: ((TerminalSessionID) -> Void)?
    /// Test-only hook fired after the one-shot task is installed. It lets
    /// lifecycle tests invalidate the task before its display interval elapses.
    var postRevealRedrawScheduledObserver: ((TerminalSessionID) -> Void)?
    /// Keep the production retry tied to the next display interval. Tests can
    /// extend it to make cancellation races deterministic.
    var postRevealRedrawDelay: Duration = .milliseconds(16)
    /// A key-window transition can be paired with a become-key notification
    /// during one AppKit/SwiftUI transaction. Give that pair one display turn
    /// to settle before releasing the remote control lease.
    var windowBlurDelay: Duration = .milliseconds(16)
    /// Invoked when a retained surface is disposed (warm eviction, tab close,
    /// or shutdown). Owners use this to invalidate recovery anchors that are
    /// only valid while the exact surface instance is still alive.
    public var onSurfaceDisposed: ((TerminalSessionID) -> Void)?
    /// Invoked when AppKit gives keyboard focus to a mounted surface that is
    /// not the current primary — a click into a passive split pane. The owner
    /// answers by selecting that Session, which routes input and the control
    /// lease to the pane the user actually clicked.
    public var onFocusRequested: ((TerminalSessionID) -> Void)?

    /// Reports an active Session whose promotion could not draw within its
    /// bound. The pane is black with nothing in flight: the presentation task
    /// either exited on a host/generation check or waits on a native surface or
    /// AppKit view that will not become ready on its own. Only the client can
    /// recover it, by re-subscribing and installing a fresh snapshot.
    public var onPresentStalled: ((TerminalSessionID) -> Void)?

    /// Accessors keep the weak-box bookkeeping in one place: a dead box is
    /// indistinguishable from a missing mapping for every caller.
    private func activeHost(_ sessionID: TerminalSessionID) -> TerminalHostContainerView? {
        guard let box = activeHostBoxes[sessionID] else { return nil }
        guard let value = box.value else {
            activeHostBoxes.removeValue(forKey: sessionID)
            return nil
        }
        return value
    }

    private func setActiveHost(_ host: TerminalHostContainerView, for sessionID: TerminalSessionID) {
        activeHostBoxes[sessionID] = WeakHostBox(host)
    }

    private func removeActiveHost(for sessionID: TerminalSessionID) {
        activeHostBoxes.removeValue(forKey: sessionID)
    }

    /// Sessions with a live mounted host, in a deterministic order.
    private var activeHostSessionIDs: [TerminalSessionID] {
        // Snapshot the keys first: the lookup prunes dead boxes and must not
        // mutate the dictionary while its key view is being iterated.
        Array(activeHostBoxes.keys)
            .filter { activeHost($0) != nil }
            .sorted { $0.description < $1.description }
    }

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
        guard requestedActiveSessionIDs?.contains(sessionID) != false else {
            return false
        }
        return policy.residency(of: sessionID) == .active
    }

    /// Publishes the next visible set before SwiftUI commits its layout.
    ///
    /// The Desktop changes the Editor/Terminal mode in the same transaction
    /// that changes the content area's height. Marking the set first lets
    /// `hostDidLayout` ignore the transient hidden-terminal geometry and lets
    /// the caller finish the residency transition after the final layout.
    public func prepareForVisibilityChange(sessionIDs: Set<TerminalSessionID>) {
        let previousActiveIDs = policy.activeSessionIDs.isEmpty
            ? Set([policy.activeSessionID].compactMap { $0 })
            : policy.activeSessionIDs
        requestedActiveSessionIDs = sessionIDs
        for sessionID in previousActiveIDs.subtracting(sessionIDs).sorted(by: { $0.description < $1.description }) {
            demote(sessionID)
        }
        // A pending geometry debounce belongs to the previous presentation.
        // Let the next visible-set reconciliation derive its viewport from the
        // final host bounds instead of replaying that stale resize.
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
        resizingUntil = nil
    }

    public func activateMultiple(sessionIDs: Set<TerminalSessionID>) {
        prepareForVisibilityChange(sessionIDs: sessionIDs)
        let primary = policy.activeSessionID.flatMap {
            sessionIDs.contains($0) ? $0 : nil
        }
        _ = policy.activateMultiple(sessionIDs, primary: primary)
        scheduleReconciliation(.visibleSet)
    }

    public func isPresentable(_ sessionID: TerminalSessionID) -> Bool {
        guard isActive(sessionID), let entry = entries[sessionID] else { return false }
        return entry.surface.terminalViewIsPresentable
    }

    /// Whether a reported grid describes the pane the surface is laid out
    /// into right now.
    ///
    /// A surface reports a grid whenever Ghostty recomputes metrics, including
    /// the default 640x480 surface every surface is created with before the
    /// view has driven a real size. That report reaches the client
    /// asynchronously, so by the time it arrives the view already matches its
    /// host and a geometry-only check cannot tell it apart from a real resize.
    /// Compare against the grid the current view geometry implies instead: the
    /// cell size is fixed per font, so a mismatch means the report was produced
    /// for a different viewport. Forwarding that would reflow the running
    /// program at the wrong width, which reads as a history replay.
    public func acceptsReportedGrid(
        _ sessionID: TerminalSessionID,
        columns: Int,
        rows: Int
    ) -> Bool {
        guard isActive(sessionID),
              let entry = entries[sessionID],
              let host = activeHost(sessionID),
              entry.view.superview === host,
              entry.view.window != nil,
              !entry.view.isHidden else { return false }
        let viewSize = entry.view.bounds.size
        let hostSize = host.bounds.size
        guard viewSize.width > 0, viewSize.height > 0,
              hostSize.width > 0, hostSize.height > 0,
              abs(viewSize.width - hostSize.width) < 1,
              abs(viewSize.height - hostSize.height) < 1,
              let metrics = entry.surface.state.surface?.size(),
              metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0
        else { return false }
        let scale = Double(entry.view.window?.backingScaleFactor ?? 2)
        let expectedColumns = Int((Double(viewSize.width) * scale / Double(metrics.cellWidthPixels)).rounded(.down))
        let expectedRows = Int((Double(viewSize.height) * scale / Double(metrics.cellHeightPixels)).rounded(.down))
        guard expectedColumns > 0, expectedRows > 0 else { return false }
        // Ghostty floors the grid, and the view's pixel size is floored before
        // it is sent, so an exact match is expected; one cell of slack absorbs
        // a rounding difference between the two paths.
        return abs(columns - expectedColumns) <= 1 && abs(rows - expectedRows) <= 1
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

    /// Whether a retained surface is safe to install a native recovery
    /// snapshot even though it is not the currently active tab.
    ///
    /// `isReadyForRecovery` intentionally requires the surface to be the
    /// active tab and its AppKit view to be presentable, because the cold
    /// attach flow also has to fit the view to its window. A warm surface
    /// that was demoted (user switched tabs) keeps its native Ghostty
    /// surface alive and ready off-screen, and its daemon output subscription
    /// stays live; a snapshot that arrives during that window must be
    /// installable immediately instead of waiting for the user to switch
    /// back. Presenting the pixels is still gated by `schedulePresent` on the
    /// next activation, so installing early never leaks a partial frame.
    public func isReadyToInstallRecovery(_ sessionID: TerminalSessionID) -> Bool {
        guard let entry = entries[sessionID] else { return false }
        return entry.surface.terminalSurfaceIsReady
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
        guard let entry = entries[sessionID],
              isActive(sessionID) else {
            scheduleReconciliation(.recoveryPrepare)
            return false
        }
        if entry.view.window != nil {
            entry.view.fitToSize()
        } else {
            scheduleReconciliation(.recoveryPrepare)
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

    /// True when a terminal surface — any of them — owns the key window's
    /// keyboard focus.
    ///
    /// The session-scoped check above answers "may this Session claim the
    /// control lease". This one answers "is the user typing into a terminal at
    /// all", which is what an app-level key monitor needs before it treats a
    /// keystroke as a terminal command. It walks the responder's ancestors
    /// because a surface's real first responder may be a descendant, and it asks
    /// about the view class rather than the entry map so that a surface mid-
    /// transition still counts.
    public var terminalOwnsKeyboardFocus: Bool {
        Self.isTerminalResponder(NSApp.keyWindow?.firstResponder)
    }

    /// Whether `responder` is a terminal surface or lives inside one.
    static func isTerminalResponder(_ responder: NSResponder?) -> Bool {
        guard let responder = responder as? NSView else { return false }
        var candidate: NSView? = responder
        while let current = candidate {
            if current is AppTerminalView { return true }
            candidate = current.superview
        }
        return false
    }

    public func isDisplayVisible(_ sessionID: TerminalSessionID) -> Bool {
        entries[sessionID]?.displayVisible == true
    }

    public func insert(_ surface: GhosttySurface, recoveryGated: Bool = false) {
        guard entries[surface.id] == nil else { return }
        let sessionID = surface.id
        let view = WarrenTerminalSurfaceView(frame: .zero)
        // A split window has several live surfaces, but only the selected one
        // owns the input router and the control lease. AppKit decides which
        // view a click focuses, so the owner must learn about that decision;
        // otherwise typing into a freshly clicked pane is silently dropped.
        view.onDidBecomeFirstResponder = { [weak self] in
            guard let self else { return }
            guard self.isActive(sessionID) else { return }
            guard self.latestIntent.activeSessionID != sessionID else {
                // The keyboard came back to the pane that was already selected,
                // which is what a click into the Terminal after a trip through
                // the editor region looks like. There is no Session to select,
                // but the daemon still has to be told: nothing else reports
                // this, because no Session or pane changed and so no
                // reconciliation runs.
                self.reportFocusReturn(sessionID)
                return
            }
            self.onFocusRequested?(sessionID)
        }
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
        scheduleReconciliation(.surfaceInserted)
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
        let start = Date()
        let count = entries.count
        TerminalDiagnostics.log("surface_shutdown_begin", ["surfaces": String(count), "pending": String(pendingDisposals.count)])
        transitionGeneration &+= 1
        removeWindowObservers()
        for sessionID in Array(entries.keys) {
            policy.remove(sessionID)
            dispose(sessionID)
        }
        host = nil
        activeHostBoxes.removeAll()
        requestedActiveSessionIDs = nil
        latestIntents.removeAll()
        focusCallbacks.removeAll()
        blurCallbacks.removeAll()
        latestIntent = TerminalPresentationIntent(
            activeSessionID: nil,
            viewportSize: .zero,
            wantsTerminalFocus: false
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        TerminalDiagnostics.log("surface_shutdown_end", ["duration_ms": String(ms), "pending": String(pendingDisposals.count)])
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
        // `hostDidLayout` is the authoritative source for viewport changes.
        // Treating the size carried by every NSViewRepresentable update as
        // intent would reconcile once per SwiftUI layout frame while a sidebar
        // or pane animates, which also re-enters focus handling. The comparison
        // is per-pane: in a split, a passive sibling's intent never matches the
        // primary one, so comparing against `latestIntent` would reconcile on
        // every sibling update.
        let previousPrimaryIntent = latestIntent
        let previousPaneIntent = intent.activeSessionID.flatMap { latestIntents[$0] }
        let paneIntentChanged = previousPaneIntent == nil
            || previousPaneIntent?.wantsTerminalFocus != intent.wantsTerminalFocus
        host.manager = self
        let previous = host.targetSessionID
        if let previous, previous != intent.activeSessionID {
            if activeHost(previous) === host {
                removeActiveHost(for: previous)
            }
            latestIntents.removeValue(forKey: previous)
            focusCallbacks.removeValue(forKey: previous)
        }
        // A Session may only occupy one host in this window. If SwiftUI
        // briefly submits the same leaf to a replacement host, invalidate the
        // old host before replacing the map entry so stale callbacks cannot
        // reattach the surface a second time.
        if let sessionID = intent.activeSessionID {
            if let previousHost = activeHost(sessionID), previousHost !== host {
                previousHost.targetSessionID = nil
                previousHost.manager = nil
            }
            host.targetSessionID = sessionID
            setActiveHost(host, for: sessionID)
            latestIntents[sessionID] = intent
            focusCallbacks[sessionID] = onFocused
            blurCallbacks[sessionID] = onBlurred
        } else {
            host.targetSessionID = nil
        }
        if let sessionID = intent.activeSessionID {
            // SwiftUI does not guarantee sibling update order. Only an intent
            // that explicitly wants keyboard focus may replace the selected
            // primary surface; passive sibling submissions must not make the
            // last-rendered pane the focus/control target. A same-session
            // update still refreshes the primary intent (for example when an
            // overlay temporarily suppresses focus).
            let primaryIsMissing = latestIntent.activeSessionID.map {
                activeHost($0) == nil
            } ?? true
            if intent.wantsTerminalFocus
                || latestIntent.activeSessionID == nil
                || primaryIsMissing
                || latestIntent.activeSessionID == sessionID
            {
                latestIntent = intent
                self.host = host
            }
        } else if latestIntent.activeSessionID == previous {
            updatePrimaryIntent()
        }
        self.onFocused = onFocused
        self.onBlurred = onBlurred
        // The promotion rules above decide whether this submit becomes the
        // primary; derive the primary change from their outcome instead of
        // duplicating them.
        let primaryChanged = previousPrimaryIntent.activeSessionID != latestIntent.activeSessionID
            || previousPrimaryIntent.wantsTerminalFocus != latestIntent.wantsTerminalFocus
        let isDetached = intent.activeSessionID.map {
            entries[$0]?.view.superview !== host
        } ?? false
        let needsReconciliation = primaryChanged
            || paneIntentChanged
            || previous != intent.activeSessionID
            || isDetached
        if needsReconciliation {
            scheduleReconciliation(.intent)
        }
    }

    public func disconnect(host: TerminalHostContainerView) {
        if let sessionID = host.targetSessionID {
            let blurCallback = blurCallbacks[sessionID]
            if activeHost(sessionID) === host {
                removeActiveHost(for: sessionID)
            }
            latestIntents.removeValue(forKey: sessionID)
            focusCallbacks.removeValue(forKey: sessionID)
            host.targetSessionID = nil
            demote(sessionID, blurCallback: blurCallback)
        }
        let remainingSessionIDs = activeHostSessionIDs
        if self.host === host {
            self.host = remainingSessionIDs.first.flatMap { activeHost($0) }
        }
        if remainingSessionIDs.isEmpty && self.host == nil {
            transitionGeneration &+= 1
            let evicted = policy.deactivate()
            evicted.forEach(dispose)
            removeWindowObservers()
            self.host = nil
        } else {
            updatePrimaryIntent()
            scheduleReconciliation(.hostDisconnected)
        }
    }

    public func hostDidLayout(_ host: TerminalHostContainerView, size: CGSize) {
        let sessionID = host.targetSessionID
        guard let sessionID, let entry = entries[sessionID] else { return }
        // A hidden terminal host still participates in SwiftUI/AppKit layout
        // while the embedded Editor is visible. Its content size is not a
        // canonical PTY viewport until the terminal is shown again.
        if let requestedActiveSessionIDs,
           !requestedActiveSessionIDs.contains(sessionID) {
            return
        }
        if entry.view.superview === host && entry.view.frame.size != size {
            entry.view.setFrameSize(size)
            entry.view.fitToSize()
            entry.surface.resyncIfNeeded()
        }
        let intent = latestIntents[sessionID] ?? latestIntent
        guard intent.viewportSize != size || intent.activeSessionID != sessionID else {
            guard entry.presentationTask == nil else { return }
            guard !entry.surface.terminalViewIsPresentable
                || !entry.surface.terminalSurfaceIsReady else { return }
            schedulePresent(
                entry,
                host: host,
                generation: entry.transitionGeneration,
                reason: "viewReady"
            )
            return
        }
        TerminalDiagnostics.logAsync("terminal_geometry_change", [
            "from": GhosttyDiagnosticsFormat.finiteSize(intent.viewportSize),
            "to": GhosttyDiagnosticsFormat.finiteSize(size),
            "session": sessionID.description,
        ])
        latestIntents[sessionID] = TerminalPresentationIntent(
            activeSessionID: sessionID,
            viewportSize: size,
            wantsTerminalFocus: intent.wantsTerminalFocus
        )
        if host === self.host {
            latestIntent = latestIntents[sessionID] ?? latestIntent
        }
        // Coalesce rapid resize events (drag) and give the daemon a short
        // window to reflow at the new size before revealing. Without this
        // a shell that is actively producing output would promote with the
        // old-width backlog and show 1-2s of missing color blocks until
        // the new-width frames arrive.
        resizingUntil = ContinuousClock.now.advanced(by: .milliseconds(250))
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.resizeDebounceTask = nil
            self.scheduleReconciliation(.geometry)
        }
    }

    /// Re-reports focus for a surface that AppKit just handed the keyboard back
    /// to without any Session or pane having changed.
    ///
    /// Only reports when this really is the selected surface in a key window, so
    /// a background pane that becomes first responder during a transition cannot
    /// claim the lease.
    /// Records that the keyboard went to a surface in this window that is not a
    /// Terminal, so the daemon's view of focus is now stale.
    ///
    /// `focusReported` is the existing "the daemon needs telling again" signal,
    /// reset by recovery, demote, and window blur. A trip into the editor region
    /// is a fourth way for the report to go stale while the pane itself stays
    /// selected and attached, and it is the only one Warren cannot observe from
    /// AppKit alone: the region is not a pane and owns no Session, so the host
    /// has to say so.
    public func noteTerminalFocusSurrendered() {
        guard let sessionID = latestIntent.activeSessionID,
              let entry = entries[sessionID] else { return }
        entry.focusReported = false
    }

    /// Deferred by one hop because AppKit has not yet installed this view as the
    /// window's first responder while `becomeFirstResponder` is still running,
    /// so the ownership check would read the outgoing responder.
    ///
    /// Reports only when the daemon's view of focus is stale. `focus` claims the
    /// responder itself, so an ordinary promotion enters this path on the very
    /// claim it is already about to report; by the time this hop runs that claim
    /// has set `focusReported`, which is what keeps a tab switch to one report
    /// instead of two.
    ///
    /// Deliberately does not consult `wantsTerminalFocus`. AppKit handing over
    /// the keyboard is a fact, where the intent is Warren's description of what
    /// it wants, and the failure being fixed here comes from letting the
    /// description outrank the fact. `ownsTerminalFocus` carries the checks that
    /// matter: active surface, key window, real first responder.
    private func reportFocusReturn(_ sessionID: TerminalSessionID) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let entry = self.entries[sessionID],
                  !entry.focusReported,
                  self.ownsTerminalFocus(sessionID) else { return }
            self.focus(
                sessionID,
                generation: self.transitionGeneration,
                forceReport: true,
                trigger: "focusReturn"
            )
        }
    }

    public func requestFocusForActiveSurface(trigger: String = "explicit_request") {
        // The selected pane can change while the active-set remains the same;
        // prefer the latest intent so a key-window transition cannot restore
        // focus to the previous sibling.
        guard let sessionID = latestIntent.activeSessionID ?? policy.activeSessionID else { return }
        // A key-window transition can leave the same AppKit first responder in
        // place while the daemon control lease was released during the blur.
        // Explicit focus requests therefore force one lease re-claim.
        focus(
            sessionID,
            generation: transitionGeneration,
            forceReport: true,
            trigger: trigger
        )
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
        guard isActive(sessionID) else {
            // Keep the request until the lifecycle transition activates this
            // surface. A network recovery can complete before SwiftUI's
            // reconciliation turn; dropping the request here leaves the
            // newly attached pane permanently black until a second tab switch.
            TerminalDiagnostics.log("present_request_deferred", [
                "session": sessionID.description,
                "reason": "inactive_surface",
                "active": policy.activeSessionID?.description ?? "nil",
            ])
            scheduleReconciliation(.presentDeferred)
            return
        }
        guard let host = activeHost(sessionID) else {
            scheduleReconciliation(.presentDeferred)
            return
        }
        // A parked surface has its view removed from the host, and nothing in
        // SwiftUI re-mounts it when the promotion does not change the active
        // set. `schedulePresent` requires the view to be attached to its host
        // and the generations to agree, so presenting now would silently do
        // nothing and leave the pane black until an unrelated reconciliation.
        // Route through reconciliation, which re-attaches the view through the
        // same path as a cold attach.
        guard entry.view.superview === host,
              entry.transitionGeneration == transitionGeneration else {
            TerminalDiagnostics.log("present_request_reattach", [
                "session": sessionID.description,
                "attached": entry.view.superview === host ? "true" : "false",
                "entryGeneration": String(entry.transitionGeneration),
                "transitionGeneration": String(transitionGeneration),
            ])
            scheduleReconciliation(.presentDeferred)
            return
        }
        schedulePresent(
            entry,
            host: host,
            generation: entry.transitionGeneration,
            reason: "promote"
        )
    }

    /// Bounded retry that keeps a promotion from ending in a permanently black
    /// pane.
    ///
    /// Presentation depends on state no caller can verify synchronously: the
    /// view must still be attached to the host when the task runs, and the
    /// generations captured at scheduling time must still be current. A single
    /// interrupted turn would otherwise leave the pane black until the user
    /// navigates away and back. Reconcile if a promotion has not drawn after a
    /// delay longer than the presentation task's own stall deadline;
    /// reconciliation re-runs `attach`, which re-mounts the view and resets the
    /// generations. Bounded so an unrecoverable surface cannot spin.
    private func armPresentWatchdog(
        for entry: Entry,
        sessionID: TerminalSessionID
    ) {
        guard entry.presentWatchdogTask == nil else { return }
        entry.presentWatchdogGeneration &+= 1
        let generation = entry.presentWatchdogGeneration
        entry.presentWatchdogTask = Task { @MainActor [weak self, weak entry] in
            defer {
                if entry?.presentWatchdogGeneration == generation {
                    entry?.presentWatchdogTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    // Longer than `schedulePresent`'s own 2s output-stall
                    // deadline: a legitimately slow drain must be allowed to
                    // present before the watchdog assumes the work is dead.
                    try await Task.sleep(for: .milliseconds(2500))
                } catch {
                    return
                }
                guard let self, let entry else { return }
                guard entry.presentWatchdogGeneration == generation else { return }
                guard self.entries[sessionID] === entry, self.isActive(sessionID) else { return }
                // A drawn frame, a newer promotion, or an in-flight recovery
                // owns the next step; the watchdog only covers a silently dead
                // one.
                guard !entry.displayVisible || entry.view.isHidden else { return }
                guard entry.recoveryPhase == .ready else { return }
                entry.presentWatchdogStreak += 1
                // Keep retrying for as long as the pane is unpresentable: a
                // bounded retry count used to give up here and leave the pane
                // black until something unrelated re-anchored it. Only the log
                // is capped so a permanently broken surface cannot flood it.
                if entry.presentWatchdogStreak <= 5 || entry.presentWatchdogStreak % 8 == 0 {
                    TerminalDiagnostics.log("present_watchdog_retry", [
                        "session": sessionID.description,
                        "streak": String(entry.presentWatchdogStreak),
                        "attached": entry.view.superview === self.activeHost(sessionID)
                            && self.activeHost(sessionID) != nil ? "true" : "false",
                        "entryGeneration": String(entry.transitionGeneration),
                        "transitionGeneration": String(self.transitionGeneration),
                    ])
                }
                self.scheduleReconciliation(.presentDeferred)
            }
        }
    }

    /// Records why a promotion could not draw.
    ///
    /// Every gate between `schedulePresent` and `presentNow()` is silent, so a
    /// stalled promotion used to leave no trace at all. The fields distinguish
    /// the two families: the AppKit view is not presentable (`viewAttached`,
    /// `viewHidden`, `viewVisible`, `viewFrame`), or the native renderer is not
    /// ready (`surfaceReady`).
    private func logPresentStall(
        _ event: String,
        sessionID: TerminalSessionID,
        entry: Entry,
        host: TerminalHostContainerView?,
        outputReady: Bool,
        targetEpoch: UInt64?,
        targetSequence: UInt64
    ) {
        let view = entry.view
        TerminalDiagnostics.log(event, [
            "session": sessionID.description,
            "viewAttached": view.window != nil ? "true" : "false",
            "viewHidden": view.isHidden ? "true" : "false",
            "viewVisible": view.visibleRect.isEmpty ? "false" : "true",
            "viewFrame": GhosttyDiagnosticsFormat.finiteSize(view.frame.size),
            "hostMounted": host != nil ? "true" : "false",
            "hostBounds": host.map { GhosttyDiagnosticsFormat.finiteSize($0.bounds.size) } ?? "nil",
            "surfaceReady": entry.surface.terminalSurfaceIsReady ? "true" : "false",
            "viewportValid": entry.surface.terminalViewportIsValid ? "true" : "false",
            "outputReady": outputReady ? "true" : "false",
            "displayVisible": entry.displayVisible ? "true" : "false",
            "recoveryPhase": entry.recoveryPhase.rawValue,
            // Inside a synchronized-output block `presentNow()` defers the draw
            // until the block closes or its stall escape fires. That is the
            // only failure inside `presentNow()` that is not reported as
            // `present_now`, so name it here.
            "syncPending": entry.surface.outputWriter.isInSynchronizedOutput
                && !entry.surface.outputWriter.isSyncStalled ? "true" : "false",
            "syncStalled": entry.surface.outputWriter.isSyncStalled ? "true" : "false",
            "targetEpoch": targetEpoch.map(String.init) ?? "nil",
            "targetSequence": String(targetSequence),
        ])
    }

    private func disarmPresentWatchdog(for entry: Entry) {
        entry.presentWatchdogGeneration &+= 1
        entry.presentWatchdogTask?.cancel()
        entry.presentWatchdogTask = nil
    }

    /// Prevents automatic presentation while a remote recovery is staged.
    /// The surface remains mounted but hidden until `endRecovery` confirms
    /// that the target sequence has rendered.
    public func beginRecovery(
        for sessionID: TerminalSessionID,
        preservingDisplay: Bool = false
    ) {
        guard let entry = entries[sessionID] else { return }
        entry.recoveryPhase = .recovering
        entry.waitsForRecoveryBoundary = false
        entry.warmPromotionPending = false
        entry.skipNextWarmPromotionRedraw = preservingDisplay
        entry.preserveDisplayDuringRecovery = preservingDisplay
            && entry.displayVisible
            && !entry.view.isHidden
            && entry.view.alphaValue > 0
        entry.focusReported = false
        cancelPresentation(for: entry)
        if entry.preserveDisplayDuringRecovery {
            // Keep the last completed frame on screen. The native renderer is
            // already alive, and the recovery snapshot replaces its grid
            // atomically; presentation remains gated until `synced`.
            entry.view.isHidden = false
            entry.view.alphaValue = 1
            setDisplayVisible(true, for: entry)
        } else {
            setDisplayVisible(false, for: entry)
            // Keep the native renderer alive while the recovery stream is
            // being staged, but hide its pixels until the matching `synced`
            // boundary. `setDisplayVisible(false)` intentionally stops the
            // coordinator's wakeups; enabling it again here lets Ghostty
            // consume queued output without exposing a partially restored
            // frame.
            prepareHiddenRendering(for: entry)
        }
    }

    public func endRecovery(for sessionID: TerminalSessionID) {
        guard let entry = entries[sessionID] else { return }
        let preservingDisplay = entry.preserveDisplayDuringRecovery
        entry.preserveDisplayDuringRecovery = false
        entry.skipNextWarmPromotionRedraw = false
        entry.recoveryPhase = .ready
        if isActive(sessionID),
           let host = activeHost(sessionID) {
            if preservingDisplay {
                // Do not blank the frame that was kept visible during the
                // transport gap. Schedule a boundary-aware present so the
                // replacement snapshot becomes visible as soon as its live
                // tail has rendered.
                entry.waitsForRecoveryBoundary = true
                entry.view.isHidden = false
                entry.view.alphaValue = 1
                setDisplayVisible(true, for: entry)
            } else {
                // Keep the pixels hidden until schedulePresent has observed
                // that the restored state and the target live bytes have
                // reached the native surface. The renderer itself stays
                // enabled so a hidden promotion cannot wait on its own
                // display wakeup.
                setDisplayVisible(false, for: entry)
                prepareHiddenRendering(for: entry)
            }
            schedulePresent(
                entry,
                host: host,
                generation: entry.transitionGeneration,
                reason: "recoveryReady"
            )
        } else {
            // The remote marker can arrive before the AppKit reconciliation
            // that activates this surface. Reconcile the ready phase into the
            // mounted host rather than requiring a second tab switch.
            scheduleReconciliation(.recoveryReady)
        }
    }

    /// Aborts a staged recovery without disposing the native surface. This is
    /// used when the transport drops again before a replacement snapshot can
    /// arrive; a retained frame must remain usable for the next reconnect.
    public func cancelRecovery(
        for sessionID: TerminalSessionID,
        preservingDisplay: Bool = false
    ) {
        guard let entry = entries[sessionID] else { return }
        let keepVisible = preservingDisplay
            && entry.displayVisible
            && !entry.view.isHidden
        entry.recoveryPhase = .ready
        entry.preserveDisplayDuringRecovery = false
        entry.skipNextWarmPromotionRedraw = preservingDisplay && keepVisible
        if !entry.skipNextWarmPromotionRedraw {
            entry.warmPromotionPending = false
        }
        entry.waitsForRecoveryBoundary = false
        cancelPresentation(for: entry)
        if keepVisible {
            entry.view.isHidden = false
            entry.view.alphaValue = 1
            setDisplayVisible(true, for: entry)
        } else {
            setDisplayVisible(false, for: entry)
            prepareHiddenRendering(for: entry)
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
        restoreSnapshotResult(
            data,
            for: sessionID,
            epoch: epoch,
            sequence: sequence
        ) == .restored
    }

    @discardableResult
    public func restoreSnapshotResult(
        _ data: Data,
        for sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64
    ) -> TerminalSnapshotRestoreResult {
        guard let entry = entries[sessionID] else { return .rejected }
        let result = entry.surface.restoreSnapshotResult(data, epoch: epoch, sequence: sequence)
        if result == .configRejected {
            TerminalDiagnostics.log("atomic_recovery_config_rejected", [
                "session": sessionID.description,
                "epoch": String(epoch),
                "sequence": String(sequence),
            ])
        }
        return result
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
            activeSessionIDs: policy.activeSessionIDs,
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

    private func scheduleReconciliation(_ reason: ReconcileReason) {
        // The first reason wins: a coalesced turn is attributed to whatever
        // triggered it, and the later callers only joined that same turn.
        if pendingReconcileReason == nil {
            pendingReconcileReason = reason
        }
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reconcileScheduled = false
            let reason = pendingReconcileReason ?? .unknown
            pendingReconcileReason = nil
            reconcile(reason: reason)
        }
    }

    private func reconcile(reason: ReconcileReason) {
        transitionGeneration &+= 1
        let generation = transitionGeneration

        // Drop mappings whose host was dismantled without a final SwiftUI
        // update. This is common during split-tree replacement and prevents a
        // stale Session from keeping an active residency indefinitely. A
        // deallocated host is already gone from the weak map, so this only has
        // to catch hosts SwiftUI retargeted without telling us.
        for sessionID in Array(activeHostBoxes.keys) {
            guard activeHost(sessionID)?.targetSessionID != sessionID else { continue }
            removeActiveHost(for: sessionID)
            latestIntents.removeValue(forKey: sessionID)
            focusCallbacks.removeValue(forKey: sessionID)
            blurCallbacks.removeValue(forKey: sessionID)
        }
        updatePrimaryIntent()

        var targetHosts: [TerminalSessionID: TerminalHostContainerView] = [:]
        for sessionID in activeHostSessionIDs {
            if let requestedActiveSessionIDs, !requestedActiveSessionIDs.contains(sessionID) {
                continue
            }
            guard let hostView = activeHost(sessionID) else { continue }
            targetHosts[sessionID] = hostView
        }
        let targetSessions: [TerminalSessionID: TerminalHostContainerView]
        if !targetHosts.isEmpty {
            targetSessions = targetHosts
        } else if requestedActiveSessionIDs == nil,
                  let activeSessionID = latestIntent.activeSessionID,
                  let host = self.host {
            targetSessions = [activeSessionID: host]
        } else {
            targetSessions = [:]
        }

        let previousActiveIDs = policy.activeSessionIDs.isEmpty
            ? Set([policy.activeSessionID].compactMap { $0 })
            : policy.activeSessionIDs

        let currentActiveSet = Set(targetSessions.keys)
        let newlyInactive = previousActiveIDs.subtracting(currentActiveSet)
        for inactiveID in newlyInactive {
            demote(inactiveID)
        }

        var evicted: [TerminalSessionID]
        if !currentActiveSet.isEmpty {
            let primary = latestIntent.activeSessionID.flatMap { currentActiveSet.contains($0) ? $0 : nil }
            evicted = policy.activateMultiple(currentActiveSet, primary: primary)
            for (sessID, hostView) in targetSessions {
                evicted.append(contentsOf: policy.updateEstimatedBytes(
                    estimatedSurfaceBytes(in: hostView),
                    for: sessID
                ))
            }
        } else {
            evicted = policy.deactivate()
            removeWindowObservers()
        }
        evicted.forEach(dispose)

        let retainedSessionIDs = Set(
            policy.warmSessionIDs + Array(policy.activeSessionIDs) + [policy.activeSessionID].compactMap { $0 }
        )
        for sessionID in Array(entries.keys) where !retainedSessionIDs.contains(sessionID) {
            dispose(sessionID)
        }

        for (sessionID, hostView) in targetSessions {
            guard let entry = entries[sessionID] else { continue }
            entry.transitionGeneration = generation
            attach(
                entry,
                sessionID: sessionID,
                to: hostView,
                generation: generation,
                reason: reason
            )
        }
    }

    private func attach(
        _ entry: Entry,
        sessionID: TerminalSessionID,
        to host: TerminalHostContainerView,
        generation: UInt64,
        reason: ReconcileReason
    ) {
        // SwiftUI can submit a newly mounted terminal host before its pane
        // constraints have propagated through AppKit. Flush that pending
        // layout before deriving the frame used to create Ghostty's first
        // grid; otherwise the initial attach can capture an intermediate
        // viewport and only a later manual resize will correct the PTY/cell
        // geometry. A geometry-only reconciliation already arrives after
        // `hostDidLayout`; flushing the entire window tree in that hot path
        // needlessly re-enters SwiftUI layout and can steal first responder.
        let needsInitialLayout = entry.view.superview !== host
            || !entry.surface.terminalSurfaceIsReady
            || host.bounds.width <= 0
            || host.bounds.height <= 0
        if needsInitialLayout {
            host.window?.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
        }
        // The host's measured bounds are authoritative after the layout flush.
        // The intent can still contain the size from the preceding
        // NSViewRepresentable update while SwiftUI is committing a new pane
        // frame; using that stale request would recreate the same first-grid
        // mismatch even though AppKit already knows the final size.
        let viewport = sanitizedViewport(
            host.bounds.size,
            fallback: latestIntents[sessionID]?.viewportSize ?? latestIntent.viewportSize
        )
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
        entry.isDemoted = false

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
                if self.activeHost(sessionID) === host,
                   self.entries[sessionID] === entry,
                   self.latestIntents[sessionID]?.activeSessionID == sessionID {
                    TerminalDiagnostics.log("attach_waiting_for_window", [
                        "session": sessionID.description,
                    ])
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self, weak host, weak entry] in
                        guard let self, let host, let entry,
                              self.activeHost(sessionID) === host,
                              self.entries[sessionID] === entry,
                              self.latestIntents[sessionID]?.activeSessionID == sessionID else { return }
                        self.scheduleReconciliation(.attachRetry)
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
            schedulePresent(
                entry,
                host: host,
                generation: generation,
                reason: "reconcile"
            )
            if latestIntents[sessionID]?.wantsTerminalFocus == true {
                focus(sessionID, generation: generation, trigger: reason.rawValue)
            }
        }
    }

    private func demote(
        _ sessionID: TerminalSessionID,
        blurCallback: ((TerminalSessionID) -> Void)? = nil
    ) {
        guard let entry = entries[sessionID] else { return }
        guard !entry.isDemoted else { return }
        entry.isDemoted = true
        entry.transitionGeneration &+= 1
        cancelPresentation(for: entry)
        entry.waitsForRecoveryBoundary = false
        let wasDisplayedWarmSurface = entry.displayVisible
            && !entry.view.isHidden
            && entry.view.alphaValue > 0
        let skipPostRevealRedraw = entry.skipNextWarmPromotionRedraw
        entry.skipNextWarmPromotionRedraw = false
        entry.warmPromotionPending = wasDisplayedWarmSurface && !skipPostRevealRedraw
        entry.focusReported = false
        // Do not capture viewport text synchronously on MainActor: `captureReattachAnchor`
        // previously called `ghostty_surface_read_text` under `terminalCallLock`,
        // which blocks if the background drain is inside `ghostty_surface_write_buffer`.
        // Closing a tab always disposes its surface, so the anchor is unused there;
        // for warm demotion the next `resyncIfNeeded` now uses a cheap always-resync
        // path that does not read the grid.
        entry.surface.clearReattachAnchor()
        entry.view.setFocusLossReportingSuppressed(true)
        if entry.view.window?.firstResponder === entry.view {
            TerminalDiagnostics.logAsync("terminal_focus_release", [
                "session": sessionID.description,
                "cause": "demote",
            ])
            entry.view.window?.makeFirstResponder(nil)
        }
        setDisplayVisible(false, for: entry)
        entry.view.alphaValue = 0
        entry.view.isHidden = true
        // Keep warm grid alive: capture the native surface before AppKit teardown
        // clears it, then restore it so InMemory stays surfaceReady and writer
        // drain continues offscreen. View itself is still removed (host keeps 1
        // subview as tests expect, window becomes nil) but grid stays current.
        let retained = entry.surface.inMemory.currentSurface
        entry.view.removeFromSuperview()
        if let retained {
            entry.surface.inMemory.setSurface(retained)
        }
        (blurCallback ?? blurCallbacks[sessionID] ?? onBlurred)(sessionID)
        blurCallbacks.removeValue(forKey: sessionID)
    }

    private func dispose(_ sessionID: TerminalSessionID) {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        removeActiveHost(for: sessionID)
        latestIntents.removeValue(forKey: sessionID)
        focusCallbacks.removeValue(forKey: sessionID)
        blurCallbacks.removeValue(forKey: sessionID)
        entry.transitionGeneration &+= 1
        cancelPresentation(for: entry)
        entry.view.setFocusLossReportingSuppressed(true)
        if entry.view.window?.firstResponder === entry.view {
            TerminalDiagnostics.logAsync("terminal_focus_release", [
                "session": sessionID.description,
                "cause": "dispose",
            ])
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

    private func focus(
        _ sessionID: TerminalSessionID,
        generation: UInt64,
        forceReport: Bool = false,
        trigger: String
    ) {
        guard let host = activeHost(sessionID),
              let window = host.window,
              let entry = entries[sessionID],
              isCurrent(sessionID, entry: entry, host: host, generation: generation),
              window.isKeyWindow else { return }
        let currentResponder = window.firstResponder
        let wasFirstResponder = currentResponder === entry.view
        guard wasFirstResponder
            || Self.canClaimFocus(
                from: currentResponder,
                in: window,
                for: entry.view
            ) else {
            TerminalDiagnostics.logAsync("terminal_focus_claim_skipped", [
                "session": sessionID.description,
                "trigger": trigger,
                "previous": Self.responderDescription(currentResponder),
                "wantsTerminalFocus": latestIntent.wantsTerminalFocus ? "true" : "false",
            ])
            return
        }
        // Record what the terminal is about to take focus away from. A steal
        // from a SwiftUI control (the sidebar's rows/buttons are hosted in an
        // NSView whose class name carries "Hosting") is the signal that a
        // reconciliation reached past the terminal and disturbed the user's
        // keyboard context.
        if !wasFirstResponder {
            TerminalDiagnostics.logAsync("terminal_focus_claim", [
                "session": sessionID.description,
                "trigger": trigger,
                "previous": Self.responderDescription(currentResponder),
                "wantsTerminalFocus": latestIntent.wantsTerminalFocus ? "true" : "false",
            ])
        }
        guard wasFirstResponder || window.makeFirstResponder(entry.view) else {
            TerminalDiagnostics.logAsync("terminal_focus_claim_rejected", [
                "session": sessionID.description,
                "trigger": trigger,
                "previous": Self.responderDescription(currentResponder),
            ])
            return
        }
        entry.view.setFocusLossReportingSuppressed(false)
        if forceReport || !wasFirstResponder || !entry.focusReported {
            entry.focusReported = true
            (focusCallbacks[sessionID] ?? onFocused)(sessionID, entry.surface.terminalSize)
        }
    }

    /// Identifies a first responder without retaining it or reading AppKit
    /// state that is only valid on the main actor later.
    private static func responderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        if responder is NSWindow { return "window" }
        return String(describing: type(of: responder))
    }

    /// Focus reconciliation may run while SwiftUI has a real control focused.
    /// A sibling terminal surface is an intentional internal transfer when a
    /// split pane is selected; SwiftUI/AppKit controls remain protected.
    private static func canClaimFocus(
        from responder: NSResponder?,
        in window: NSWindow,
        for terminalView: AppTerminalView
    ) -> Bool {
        guard let responder else { return true }
        if responder === window || responder === terminalView {
            return true
        }
        guard let responderView = responder as? NSView else { return false }
        if responderView.isDescendant(of: terminalView) {
            return true
        }
        // All terminal views are hosted in the same window and use the
        // AppKit terminal view class; permitting that peer transfer preserves
        // split-pane focus cycling without stealing focus from SwiftUI chrome.
        return responderView is AppTerminalView && responderView.window === window
    }

    private func schedulePresent(
        _ entry: Entry,
        host: TerminalHostContainerView,
        generation: UInt64,
        reason: String
    ) {
        guard entry.recoveryPhase == .ready else { return }
        let sessionID = entry.surface.id
        // A pending presentation already observes the same lifecycle state;
        // restarting it for every window notification only multiplies sync
        // draws. Reconciliation cancels the task explicitly when its
        // generation changes.
        guard entry.presentationTask == nil else { return }

        let currentSurface = entry.surface.state.surface
        let currentSurfaceID = currentSurface.map(ObjectIdentifier.init)
        let currentBoundary = entry.surface.outputWriter.enqueuedBoundary
        let currentEpoch = currentBoundary.epoch
        let currentSequence = currentBoundary.sequence
        if entry.displayVisible,
           entry.surface.terminalViewIsPresentable,
           entry.surface.terminalSurfaceIsReady,
           entry.lastPresentedSurface == currentSurfaceID,
           entry.lastPresentedEpoch == currentEpoch,
           entry.lastPresentedSequence >= currentSequence
        {
            // The same surface and output boundary are already on screen.
            TerminalDiagnostics.logVerbose("present_skip_duplicate", [
                "session": sessionID.description,
                "sequence": String(currentSequence),
            ])
            return
        }

        let presentationGeneration = entry.presentationGeneration
        // Capture a fixed output boundary. The writer may still be draining a
        // burst when a surface is promoted; revealing before this boundary is
        // consumed exposes a partially applied TUI frame. Bytes enqueued
        // after this point remain live output and do not extend the promotion
        // wait (the Zeno case).
        entry.pendingPresentReason = reason
        let targetEpoch = currentEpoch
        let targetSequence = currentSequence
        let waitsForOutput = !entry.displayVisible || entry.waitsForRecoveryBoundary
        let schedulePostRevealRedraw = entry.warmPromotionPending
            && !entry.waitsForRecoveryBoundary
        // A second line of defence behind the stall report below: reconciliation
        // re-attaches the view and resets the generations, which is the only
        // thing that can revive a promotion that died before it started.
        armPresentWatchdog(for: entry, sessionID: sessionID)
        let stallDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        // A promotion that is only missing a draw must not wait the whole
        // output-stall window: the pane is black for that entire time. Give the
        // draw itself a much shorter bound and escalate from there.
        let drawStallDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        if !entry.displayVisible {
            prepareHiddenRendering(for: entry)
        }
        // Every gate between `schedulePresent` and `presentNow()` is silent — a
        // stopped view or a cleared native surface leaves nothing in the log —
        // so report the state once if the promotion has not drawn by its own
        // stall deadline, and hand the Session back to the client to recover.
        var stallReported = false
        entry.presentationTask = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
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
                    TerminalDiagnostics.logVerbose("present_task_abandoned", [
                        "session": sessionID.description,
                        "attached": entry.view.superview === host ? "true" : "false",
                        "window": entry.view.window != nil ? "true" : "false",
                        "entryGeneration": String(entry.transitionGeneration),
                        "transitionGeneration": String(transitionGeneration),
                        "generation": String(generation),
                    ])
                    return
                }

                // A resize window is refreshed by every geometry change, so a
                // sustained stream of them would otherwise starve the draw path
                // below and keep the pane black indefinitely.
                if let until = resizingUntil,
                   ContinuousClock.now < until,
                   ContinuousClock.now < stallDeadline {
                    do {
                        try await Task.sleep(until: until, tolerance: .milliseconds(10))
                    } catch { return }
                    continue
                }

                let outputReady = !waitsForOutput || outputHasReached(
                    entry.surface,
                    targetEpoch: targetEpoch,
                    targetSequence: targetSequence
                )
                let timedOut = waitsForOutput && ContinuousClock.now >= stallDeadline
                let viewReady = entry.surface.terminalViewIsPresentable
                let surfaceReady = entry.surface.terminalSurfaceIsReady
                if (outputReady || timedOut), viewReady, surfaceReady {
                    if timedOut, !outputReady {
                        TerminalDiagnostics.log("present_wait_timeout", [
                            "session": sessionID.description,
                            "targetEpoch": targetEpoch.map(String.init) ?? "nil",
                            "targetSequence": String(targetSequence),
                            "renderedEpoch": String(entry.surface.renderedEpoch),
                            "renderedSequence": String(entry.surface.renderedSequence),
                            "enqueuedSequence": String(entry.surface.outputWriter.enqueuedSequence),
                        ])
                    }
                    if entry.surface.presentNow() {
                        finishPresentation(
                            entry: entry,
                            sessionID: sessionID,
                            generation: generation,
                            targetEpoch: targetEpoch,
                            targetSequence: targetSequence,
                            schedulePostRevealRedraw: schedulePostRevealRedraw
                        )
                        return
                    }
                }

                // Pending output is a legitimate reason to wait; a stopped view,
                // a cleared native surface, or an open synchronized-output block
                // is not. Force the draw for the latter and hand the Session to
                // the client only if even that fails.
                let outputPending = waitsForOutput && !outputReady
                if !outputPending, ContinuousClock.now >= drawStallDeadline {
                    if viewReady, surfaceReady, entry.surface.presentNow(forceDraw: true) {
                        finishPresentation(
                            entry: entry,
                            sessionID: sessionID,
                            generation: generation,
                            targetEpoch: targetEpoch,
                            targetSequence: targetSequence,
                            schedulePostRevealRedraw: schedulePostRevealRedraw,
                            forceDraw: true
                        )
                        return
                    }
                    logPresentStall(
                        "present_wait_state",
                        sessionID: sessionID,
                        entry: entry,
                        host: host,
                        outputReady: outputReady,
                        targetEpoch: targetEpoch,
                        targetSequence: targetSequence
                    )
                    onPresentStalled?(sessionID)
                    return
                }

                // The stall check runs after the draw attempts above: a
                // promotion that is merely slow still presents once its output
                // boundary passes its deadline. Only one that cannot draw at all
                // reaches the report.
                if !stallReported, ContinuousClock.now >= stallDeadline {
                    stallReported = true
                    logPresentStall(
                        "present_wait_state",
                        sessionID: sessionID,
                        entry: entry,
                        host: host,
                        outputReady: outputReady,
                        targetEpoch: targetEpoch,
                        targetSequence: targetSequence
                    )
                    onPresentStalled?(sessionID)
                    return
                }

                do {
                    try await Task.sleep(
                        for: timedOut ? .milliseconds(250) : .milliseconds(16)
                    )
                } catch {
                    return
                }
            }
        }
    }

    /// Marks one successful draw as the pane's current presentation.
    ///
    /// Shared by the normal path and the forced draw that rescues a promotion
    /// whose view and grid are ready while its draw keeps being deferred.
    private func finishPresentation(
        entry: Entry,
        sessionID: TerminalSessionID,
        generation: UInt64,
        targetEpoch: UInt64?,
        targetSequence: UInt64,
        schedulePostRevealRedraw scheduleRedraw: Bool,
        forceDraw: Bool = false
    ) {
        entry.view.isHidden = false
        entry.view.alphaValue = 1
        setDisplayVisible(true, for: entry)
        let presentedSurface = entry.surface.state.surface
        entry.lastPresentedSurface = presentedSurface.map(ObjectIdentifier.init)
        let presentedBoundary = entry.surface.outputWriter.enqueuedBoundary
        entry.lastPresentedEpoch = presentedBoundary.epoch
        entry.lastPresentedSequence = presentedBoundary.sequence
        entry.waitsForRecoveryBoundary = false
        entry.warmPromotionPending = false
        entry.presentWatchdogStreak = 0
        disarmPresentWatchdog(for: entry)
        if scheduleRedraw, let presentedSurface {
            schedulePostRevealRedraw(
                entry,
                host: host,
                generation: generation,
                nativeSurfaceID: ObjectIdentifier(presentedSurface)
            )
        }
        let view = entry.view.bounds.size
        TerminalDiagnostics.log("present_complete", [
            "session": sessionID.description,
            "reason": entry.pendingPresentReason ?? "unknown",
            "view": "\(Int(view.width))x\(Int(view.height))",
            "forceDraw": forceDraw ? "true" : "false",
            "targetEpoch": targetEpoch.map(String.init) ?? "nil",
            "targetSequence": String(targetSequence),
            "enqueuedNow": String(presentedBoundary.sequence),
            "renderedEpoch": String(entry.surface.renderedEpoch),
            "renderedSequence": String(entry.surface.renderedSequence),
            "recoveryPhase": entry.recoveryPhase.rawValue,
        ])
    }

    /// Gives a successfully promoted warm surface one additional native draw
    /// after the first visible frame has crossed a display interval. The first
    /// frame remains immediate; this bounded retry only repairs a compositor
    /// backing store that was purged between the draw and its first composite.
    private func schedulePostRevealRedraw(
        _ entry: Entry,
        host: TerminalHostContainerView?,
        generation: UInt64,
        nativeSurfaceID: ObjectIdentifier
    ) {
        guard entry.postRevealRedrawTask == nil,
              let host,
              entry.recoveryPhase == .ready else { return }
        let sessionID = entry.surface.id
        entry.postRevealRedrawGeneration &+= 1
        let redrawGeneration = entry.postRevealRedrawGeneration
        entry.postRevealRedrawTask = Task { @MainActor [weak self, weak entry, weak host] in
            guard let self, let entry else { return }
            defer {
                if entry.postRevealRedrawGeneration == redrawGeneration {
                    entry.postRevealRedrawTask = nil
                }
            }

            do {
                try await Task.sleep(for: self.postRevealRedrawDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isCurrent(
                      sessionID,
                      entry: entry,
                      host: host,
                      generation: generation
                  ),
                  policy.activeSessionID == sessionID,
                  entry.recoveryPhase == .ready,
                  entry.displayVisible,
                  !entry.view.isHidden,
                  entry.view.alphaValue > 0,
                  entry.surface.terminalViewIsPresentable,
                  entry.surface.terminalSurfaceIsReady,
                  let currentSurface = entry.surface.state.surface,
                  ObjectIdentifier(currentSurface) == nativeSurfaceID
            else { return }

            let redrawn = entry.surface.presentNow()
            TerminalDiagnostics.log("post_reveal_redraw", [
                "session": sessionID.description,
                "result": redrawn ? "true" : "false",
            ])
            postRevealRedrawObserver?(sessionID)
        }
        postRevealRedrawScheduledObserver?(sessionID)
    }

    private func cancelPresentation(for entry: Entry) {
        entry.presentationGeneration &+= 1
        entry.presentationTask?.cancel()
        entry.presentationTask = nil
        entry.postRevealRedrawGeneration &+= 1
        entry.postRevealRedrawTask?.cancel()
        entry.postRevealRedrawTask = nil
        disarmPresentWatchdog(for: entry)
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
        let rendered = surface.outputWriter.renderedBoundary
        guard let renderedEpoch = rendered.epoch else { return false }
        return renderedEpoch > targetEpoch
            || (renderedEpoch == targetEpoch
                && rendered.sequence >= targetSequence)
    }

    private func installWindowObservers(for window: NSWindow?) {
        guard let window else { return }
        // Reinstalling for every layout reconciliation creates notification
        // churn and can race a pending blur. The observers are keyed on the
        // window alone: in a split window the primary Session changes without
        // the window changing, and the handlers read the live intent.
        guard !(observedWindow === window && !windowObservers.isEmpty) else { return }
        removeWindowObservers()
        observedWindow = window
        windowObserverGeneration &+= 1
        let observerGeneration = windowObserverGeneration
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window,
                      self.windowObserverGeneration == observerGeneration,
                      self.host?.window === window else { return }
                self.cancelPendingWindowBlur()
                if latestIntent.wantsTerminalFocus {
                    requestFocusForActiveSurface(trigger: "window_did_become_key")
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
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, let sessionID = self.latestIntent.activeSessionID,
                      self.windowObserverGeneration == observerGeneration,
                      self.host?.window === window else { return }
                self.scheduleWindowBlur(
                    for: sessionID,
                    window: window,
                    observerGeneration: observerGeneration
                )
            }
        })
    }

    private func removeWindowObservers() {
        windowObserverGeneration &+= 1
        cancelPendingWindowBlur()
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
        observedWindow = nil
    }

    /// Keeps the global fallback intent aligned with the focused host while
    /// preserving a deterministic fallback when no pane requested focus.
    /// `activeHostBoxes` is the source of truth for visible placements; the
    /// global `host`/`latestIntent` pair exists only for legacy single-host
    /// lifecycle notifications and primary focus requests.
    private func updatePrimaryIntent(preferredSessionID: TerminalSessionID? = nil) {
        if let preferredSessionID,
           let preferredHost = activeHost(preferredSessionID),
           let preferredIntent = latestIntents[preferredSessionID] {
            latestIntent = preferredIntent
            host = preferredHost
            return
        }
        if let currentSessionID = latestIntent.activeSessionID,
           let currentHost = activeHost(currentSessionID),
           let currentIntent = latestIntents[currentSessionID] {
            latestIntent = currentIntent
            host = currentHost
            return
        }
        if let fallbackSessionID = activeHostSessionIDs.first,
           let fallbackHost = activeHost(fallbackSessionID),
           let fallbackIntent = latestIntents[fallbackSessionID] {
            latestIntent = fallbackIntent
            host = fallbackHost
            return
        }
        latestIntent = TerminalPresentationIntent(
            activeSessionID: nil,
            viewportSize: .zero,
            wantsTerminalFocus: false
        )
        host = nil
    }

    private func scheduleWindowBlur(
        for sessionID: TerminalSessionID,
        window: NSWindow,
        observerGeneration: UInt64
    ) {
        pendingWindowBlurTask?.cancel()
        windowBlurGeneration &+= 1
        let blurGeneration = windowBlurGeneration
        pendingWindowBlurTask = Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            defer {
                if self.windowBlurGeneration == blurGeneration {
                    self.pendingWindowBlurTask = nil
                }
            }

            do {
                try await Task.sleep(for: self.windowBlurDelay)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  self.windowBlurGeneration == blurGeneration,
                  self.windowObserverGeneration == observerGeneration,
                  let window,
                  self.host?.window === window,
                  self.latestIntent.activeSessionID == sessionID,
                  self.policy.activeSessionID == sessionID,
                  !window.isKeyWindow else { return }

            TerminalDiagnostics.logVerbose("window_blur_commit", [
                "session": sessionID.description,
            ])
            self.entries[sessionID]?.focusReported = false
            self.onBlurred(sessionID)
        }
    }

    private func cancelPendingWindowBlur() {
        windowBlurGeneration &+= 1
        pendingWindowBlurTask?.cancel()
        pendingWindowBlurTask = nil
    }

    private func requestPresentForActiveSurface() {
        let mountedSessionIDs = activeHostSessionIDs
        if !mountedSessionIDs.isEmpty {
            for sessionID in mountedSessionIDs {
                requestPresent(sessionID)
            }
        } else if let sessionID = policy.activeSessionID {
            requestPresent(sessionID)
        }
    }

    private func isCurrent(
        _ sessionID: TerminalSessionID,
        entry: Entry,
        host: TerminalHostContainerView?,
        generation: UInt64,
        requiresVisibleView: Bool = true
    ) -> Bool {
        let isHostMatching = (self.host === host && policy.activeSessionID == sessionID) || (activeHost(sessionID) === host)
        let transitionIsCurrent = isActive(sessionID)
            && entries[sessionID] === entry
            && entry.transitionGeneration == generation
            && transitionGeneration == generation
            && isHostMatching
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
        let fallback = host.targetSessionID.flatMap { latestIntents[$0]?.viewportSize }
            ?? latestIntent.viewportSize
        let viewport = sanitizedViewport(host.bounds.size, fallback: fallback)
        let scale = host.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = viewport.width * scale * viewport.height * scale
        guard pixels.isFinite, pixels > 0 else { return 0 }
        // Triple-buffered BGRA is the dominant predictable surface cost.
        let bytes = pixels * 4 * 3
        guard bytes < Double(Int.max) else { return Int.max }
        return Int(bytes.rounded(.up))
    }
}

/// Terminal view that reports the moment AppKit hands it keyboard focus.
/// In a split window the user picks the control target by clicking a pane, and
/// that decision is made by AppKit responder routing rather than by SwiftUI.
@MainActor
final class WarrenTerminalSurfaceView: AppTerminalView {
    var onDidBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onDidBecomeFirstResponder?()
        }
        return result
    }
}

@MainActor
public final class TerminalHostContainerView: NSView {
    weak var manager: TerminalSurfaceManager?
    public var targetSessionID: TerminalSessionID?

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
