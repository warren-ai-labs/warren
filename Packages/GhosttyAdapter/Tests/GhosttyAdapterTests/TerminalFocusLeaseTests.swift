import AppKit
import WarrenDomain
import XCTest
@testable import GhosttyAdapter
@testable import GhosttyTerminal

/// Covers the focus-report latch and the recovery-gate deferral.
///
/// AppKit handing a pane the keyboard says where a keystroke goes; it does not
/// say the Host will accept it. The latch therefore closes only when the Host
/// confirms the claim, and reopens when the claim is skipped, fails, or is taken
/// away. The recovery gate used to drop a present request for good, which is the
/// same permanently black pane from the other direction.
final class TerminalFocusLeaseTests: XCTestCase {
    /// The focus path requires a key window. Raising the test process to
    /// `.regular` would take the foreground from whoever runs the suite, so
    /// override the one property the path reads instead.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private struct Rig {
        let manager: TerminalSurfaceManager
        let surface: GhosttySurface
        let window: NSWindow
        let host: TerminalHostContainerView
        var focusReports: Int = 0
    }

    @MainActor
    private func makeRig(gated: Bool = false) -> Rig {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, inoutSize in _ = inoutSize }
        )
        manager.insert(surface, recoveryGated: gated)
        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = KeyWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return Rig(manager: manager, surface: surface, window: window, host: host)
    }

    /// Submits the intent that makes the pane the terminal target and reports
    /// every focus claim the manager makes.
    @MainActor
    private func submit(_ rig: Rig, onReport: @escaping () -> Void) {
        rig.manager.submit(
            host: rig.host,
            intent: TerminalPresentationIntent(
                activeSessionID: rig.surface.id,
                viewportSize: rig.host.bounds.size,
                wantsTerminalFocus: true
            ),
            onFocused: { _, _ in onReport() },
            onBlurred: { _ in }
        )
    }

    /// A report is not a confirmation. Until the Host answers, further focus
    /// turns must not claim again; a rejection must let the next turn report.
    @MainActor
    func testFocusReportStaysPendingUntilTheHostConfirms() async throws {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }
        var reports = 0
        submit(rig) { reports += 1 }
        try await waitUntil { reports == 1 }

        // The claim is outstanding: an activation turn must not send a second.
        rig.manager.requestInputFocus(for: rig.surface.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, 1, "a report in flight must not be repeated")

        rig.manager.noteFocusReportOutcome(rig.surface.id, accepted: true)
        rig.manager.requestInputFocus(for: rig.surface.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, 1, "a confirmed lease must not be re-claimed")

        // A rejection reopens the latch; the next focus turn reports again.
        rig.manager.noteFocusReportOutcome(rig.surface.id, accepted: false)
        rig.manager.requestInputFocus(for: rig.surface.id)
        try await waitUntil { reports == 2 }
    }

    /// A lease taken away from a pane that still owns the keyboard is claimed
    /// back once. A background pane stays quiet: it has no keystrokes to lose.
    @MainActor
    func testLeaseTakenReclaimsOnlyWhileThePaneOwnsTheKeyboard() async throws {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }
        var reports = 0
        submit(rig) { reports += 1 }
        try await waitUntil { reports == 1 }
        rig.manager.noteFocusReportOutcome(rig.surface.id, accepted: true)

        rig.manager.noteFocusLeaseTaken(rig.surface.id)
        try await waitUntil { reports == 2 }

        // The keyboard moved elsewhere in the window without a surrender report.
        let standIn = NSTextView(frame: rig.host.bounds)
        rig.host.addSubview(standIn)
        XCTAssertTrue(rig.window.makeFirstResponder(standIn))
        rig.manager.noteFocusReportOutcome(rig.surface.id, accepted: true)
        rig.manager.noteFocusLeaseTaken(rig.surface.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, 2, "a pane without the keyboard must not re-claim")
    }

    /// A lease handed back by the Host closes the latch without another claim:
    /// the Host already agreed, so a report would only churn the lease.
    @MainActor
    func testLeaseGrantedClosesTheLatchWithoutAResend() async throws {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }
        var reports = 0
        submit(rig) { reports += 1 }
        try await waitUntil { reports == 1 }
        rig.manager.noteFocusReportOutcome(rig.surface.id, accepted: true)

        rig.manager.noteFocusLeaseTaken(rig.surface.id)
        try await waitUntil { reports == 2 }
        rig.manager.noteFocusLeaseGranted(rig.surface.id)
        rig.manager.requestInputFocus(for: rig.surface.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, 2, "a handed-back lease must not be re-claimed")
    }

    /// A present request that arrives behind the recovery gate is replayed when
    /// the gate is cancelled, not dropped. Before this the pane stayed hidden
    /// until an unrelated reconciliation.
    @MainActor
    func testPresentDeferredByRecoveryIsReplayedWhenRecoveryIsCancelled() async throws {
        let rig = makeRig(gated: true)
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }
        submit(rig) {}
        try await waitUntil { rig.surface.mountedTerminalView?.window === rig.window }

        rig.manager.beginRecovery(for: rig.surface.id)
        rig.manager.requestPresent(rig.surface.id)
        XCTAssertFalse(rig.manager.isDisplayVisible(rig.surface.id))

        rig.manager.cancelRecovery(for: rig.surface.id)
        try await waitUntil { rig.manager.isDisplayVisible(rig.surface.id) }
        try await waitUntil { !(rig.surface.mountedTerminalView?.isHidden ?? true) }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            struct Timeout: Error {}
            throw Timeout()
        }
    }
}
