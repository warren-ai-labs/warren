import AppKit
import WarrenDomain
import XCTest
@testable import GhosttyAdapter
@testable import GhosttyTerminal

/// Covers entering a Session: the keyboard has to end up in its terminal even
/// when the control that activated the Session still owns the responder.
///
/// Reconciliation is deliberately not allowed to take the keyboard from a
/// SwiftUI control, because it runs on layout and roster turns. Activation is
/// the user's own instruction, so it carries the extra permission with it and
/// still respects every other check (active surface, key window, attach).
final class TerminalInputFocusTests: XCTestCase {
    /// Focus reporting requires a key window. This process has no activation
    /// policy that can grant one without taking the foreground from whoever is
    /// running the suite, so the one property the path reads is overridden,
    /// exactly as `TerminalFocusReturnTests` does.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private struct Rig {
        let manager: TerminalSurfaceManager
        let surface: GhosttySurface
        let window: NSWindow
        let host: TerminalHostContainerView
        let activationControl: NSView
    }

    @MainActor
    private func makeRig(keyWindow: Bool = true) -> Rig {
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
        let window: NSWindow
        if keyWindow {
            window = KeyWindow(
                contentRect: host.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
        } else {
            window = NSWindow(
                contentRect: host.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
        }
        window.contentView = host
        // A stand-in for the SwiftUI control that activated the Session: the
        // command palette's field, the clicked Tab, the "+" that launched it.
        // What matters to the focus path is that the responder is a view that
        // is not a terminal and lives in this window.
        let activationControl = NSView(frame: host.bounds)
        host.addSubview(activationControl)
        XCTAssertTrue(window.makeFirstResponder(activationControl))
        return Rig(
            manager: manager,
            surface: surface,
            window: window,
            host: host,
            activationControl: activationControl
        )
    }

    @MainActor
    private func submit(
        _ rig: Rig,
        focused: @escaping (TerminalSessionID, TerminalSize?) -> Void = { _, _ in }
    ) {
        rig.manager.submit(
            host: rig.host,
            intent: TerminalPresentationIntent(
                activeSessionID: rig.surface.id,
                viewportSize: rig.host.bounds.size,
                wantsTerminalFocus: true
            ),
            onFocused: focused,
            onBlurred: { _ in }
        )
    }

    /// A layout turn must keep its hands off SwiftUI chrome. This is the
    /// behaviour the activation path is allowed to override, so it has to stay
    /// true for everything else.
    @MainActor
    func testReconciliationDoesNotTakeFocusFromAControl() async throws {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }

        submit(rig)
        try await waitUntilInputFocus {
            rig.surface.mountedTerminalView?.window === rig.window
                && rig.surface.mountedTerminalView?.isHidden == false
        }
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(
            rig.window.firstResponder === rig.activationControl,
            "Reconciliation took the keyboard from the control that owned it."
        )
        XCTAssertFalse(rig.manager.ownsTerminalFocus(rig.surface.id))
    }

    /// Entering the Session is what allows the claim, and it has to land even
    /// though the selector control was first responder when the request was
    /// made.
    @MainActor
    func testUserActivationTakesFocusFromAControlInTheSameWindow() async throws {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }

        var focusReports = 0
        submit(rig) { _, _ in focusReports += 1 }
        try await waitUntilInputFocus {
            rig.surface.mountedTerminalView?.window === rig.window
                && rig.surface.mountedTerminalView?.isHidden == false
        }
        try await Task.sleep(for: .milliseconds(80))
        let reportsBeforeActivation = focusReports

        rig.manager.requestInputFocus(for: rig.surface.id)
        try await waitUntilInputFocus {
            rig.manager.ownsTerminalFocus(rig.surface.id)
        }
        try await waitUntilInputFocus { focusReports > reportsBeforeActivation }

        XCTAssertTrue(rig.window.firstResponder === rig.surface.mountedTerminalView)
    }

    /// The activation permission is about *where* the keyboard goes, not about
    /// whether the pane can hold it. A non-key window still owns nothing.
    @MainActor
    func testUserActivationDoesNotClaimInANonKeyWindow() async throws {
        let rig = makeRig(keyWindow: false)
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }

        submit(rig)
        try await waitUntilInputFocus {
            rig.surface.mountedTerminalView?.window === rig.window
        }
        rig.manager.requestInputFocus(for: rig.surface.id)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(
            rig.window.firstResponder === rig.activationControl,
            "A non-key window must not take the keyboard for a Session."
        )
        XCTAssertFalse(rig.manager.ownsTerminalFocus(rig.surface.id))
    }

    /// The origin rule itself: activation is the only origin allowed to move
    /// the keyboard off a control, and only inside the window that owns it.
    @MainActor
    func testOnlyUserActivationTakesTheKeyboardFromAControl() {
        let rig = makeRig()
        defer {
            rig.manager.shutdown()
            rig.window.orderOut(nil as Any?)
        }
        let control = rig.activationControl
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let otherControl = NSView(frame: otherWindow.contentLayoutRect)
        otherWindow.contentView = otherControl

        XCTAssertTrue(TerminalSurfaceManager.allowsFocusTransfer(
            from: control,
            in: rig.window,
            origin: .userActivation
        ))
        XCTAssertFalse(TerminalSurfaceManager.allowsFocusTransfer(
            from: control,
            in: rig.window,
            origin: .reconciliation
        ), "A layout turn took the keyboard from a control.")
        XCTAssertFalse(
            TerminalSurfaceManager.allowsFocusTransfer(
                from: otherControl,
                in: rig.window,
                origin: .userActivation
            ),
            "Activation reached a control in another window."
        )
        otherWindow.orderOut(nil as Any?)
    }
}

@MainActor
private func waitUntilInputFocus(
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
