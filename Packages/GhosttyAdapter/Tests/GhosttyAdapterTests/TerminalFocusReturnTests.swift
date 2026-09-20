import AppKit
import WarrenDomain
import XCTest
@testable import GhosttyAdapter
@testable import GhosttyTerminal

/// Covers focus coming back to the Terminal from a surface in the same window
/// that is not a Terminal — the embedded editor region.
///
/// The Session stays selected and attached for the whole trip, which is what
/// made this fail: `focus` reports only when the view was not already first
/// responder or when `focusReported` is clear, and after a trip through the
/// editor neither holds. The Session was left believing it had lost the keyboard
/// until an unrelated tab switch demoted the surface and reset that flag.
final class TerminalFocusReturnTests: XCTestCase {
    /// Focus reporting requires a key window. The test process has no activation
    /// policy that can grant one, and raising it to `.regular` would take the
    /// pointer and the foreground from whoever is running the suite — which the
    /// repository's verification rules rule out. Overriding the one property the
    /// focus path reads keeps these cases real without touching the foreground.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private struct Rig {
        let manager: TerminalSurfaceManager
        let surface: GhosttySurface
        let window: NSWindow
        let host: TerminalHostContainerView
    }

    @MainActor
    private func makeRig() -> Rig {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        manager.insert(surface)
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

    /// The click that brings the keyboard back to an already-selected Session has
    /// to reach the daemon. Nothing else in the pipeline reports it: no Session
    /// or pane changed, so no reconciliation runs.
    @MainActor
    func testFocusReturnFromNonTerminalSurfaceIsReported() async throws {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }

        var focusReports = 0
        rig.manager.submit(
            host: rig.host,
            intent: TerminalPresentationIntent(
                activeSessionID: rig.surface.id,
                viewportSize: rig.host.bounds.size,
                wantsTerminalFocus: true
            ),
            onFocused: { _, _ in focusReports += 1 },
            onBlurred: { _ in }
        )
        try await waitUntilFocusReturn {
            rig.surface.mountedTerminalView?.window === rig.window
        }
        try await waitUntilFocusReturn { focusReports > 0 }
        let reportsAfterPromotion = focusReports

        // The editor region takes the keyboard. Its view is not a terminal,
        // which is what makes this different from selecting a sibling pane.
        // A stand-in for the region: what matters to the focus path is that the
        // responder is a view which is not a terminal. Whether the chord monitor
        // recognizes it is a separate question, covered by the responder tests —
        // that check reads `NSApp.keyWindow`, which no amount of overriding can
        // supply in a process with no activation policy.
        let editorStandIn = NSTextView(frame: rig.host.bounds)
        rig.host.addSubview(editorStandIn)
        XCTAssertTrue(rig.window.makeFirstResponder(editorStandIn))
        // The host reports the surrender, which is what marks the daemon's view
        // of focus as stale.
        rig.manager.noteTerminalFocusSurrendered()

        // Clicking back into the Terminal.
        let terminalView = try XCTUnwrap(rig.surface.mountedTerminalView)
        XCTAssertTrue(rig.window.makeFirstResponder(terminalView))

        try await waitUntilFocusReturn { focusReports > reportsAfterPromotion }
    }

    /// An ordinary promotion must report exactly once.
    ///
    /// `focus` claims the responder itself, so `becomeFirstResponder` fires
    /// inside it and the focus-return path is entered on the same claim that is
    /// already about to report. Without a guard the daemon is told twice on every
    /// tab switch, which re-claims the control lease for no reason.
    @MainActor
    func testPromotionReportsFocusExactlyOnce() async throws {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }

        var focusReports = 0
        rig.manager.submit(
            host: rig.host,
            intent: TerminalPresentationIntent(
                activeSessionID: rig.surface.id,
                viewportSize: rig.host.bounds.size,
                wantsTerminalFocus: true
            ),
            onFocused: { _, _ in focusReports += 1 },
            onBlurred: { _ in }
        )
        try await waitUntilFocusReturn {
            rig.surface.mountedTerminalView?.window === rig.window
        }
        try await waitUntilFocusReturn { focusReports > 0 }

        // Let every deferred focus-return hop scheduled by the promotion run.
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(
            focusReports,
            1,
            "A promotion reported focus \(focusReports) times; the daemon must be told once."
        )
    }

    /// The keyboard returning to the pane that is already selected must not be
    /// mistaken for a pane selection.
    ///
    /// `onFocusRequested` moves the input router and the control lease to a
    /// different Session. Raising it here would re-select the Session that is
    /// already selected on every click into the Terminal.
    @MainActor
    func testFocusReturnDoesNotReselectTheSameSession() async throws {
        let rig = makeRig()
        var focusRequests: [TerminalSessionID] = []
        rig.manager.onFocusRequested = { focusRequests.append($0) }
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }

        rig.manager.submit(
            host: rig.host,
            intent: TerminalPresentationIntent(
                activeSessionID: rig.surface.id,
                viewportSize: rig.host.bounds.size,
                wantsTerminalFocus: true
            ),
            onFocused: { _, _ in },
            onBlurred: { _ in }
        )
        try await waitUntilFocusReturn {
            rig.surface.mountedTerminalView?.window === rig.window
        }

        let terminalView = try XCTUnwrap(rig.surface.mountedTerminalView)
        rig.manager.noteTerminalFocusSurrendered()
        _ = rig.window.makeFirstResponder(terminalView)
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(
            focusRequests.isEmpty,
            "The selected Session must not be re-selected when focus returns to it."
        )
    }

    /// A surrender note is only meaningful for the surface that owns the
    /// keyboard. A pane that never became active must not be able to report
    /// focus on the selected pane's behalf.
    @MainActor
    func testFocusReturnIgnoresSurfaceThatIsNotActive() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        manager.insert(surface)
        defer { manager.shutdown() }

        // Never submitted to a host, so it is not an active surface.
        XCTAssertFalse(manager.ownsTerminalFocus(surface.id))
    }
}

@MainActor
private func waitUntilFocusReturn(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard condition() else {
        struct ConditionTimeout: Error {}
        throw ConditionTimeout()
    }
}
