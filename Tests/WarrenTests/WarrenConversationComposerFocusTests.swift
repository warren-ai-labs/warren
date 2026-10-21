import AppKit
import SwiftUI
import XCTest
import WarrenDomain
@testable import Warren

/// The Conversation composer takes the keyboard when the Session is activated,
/// not whenever the pane happens to be mounted.
///
/// The composer used to focus itself from `makeNSView`, which was both too
/// eager (a remount stole focus from the editor) and too late to help: an
/// activation issued before the pane existed never landed. These cases pin the
/// token contract that replaced it.
final class WarrenConversationComposerFocusTests: XCTestCase {
    /// A key window without taking the foreground from whoever runs the suite.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private struct Mount {
        let window: NSWindow
        let hosting: NSHostingView<WarrenConversationView>
        let feed: WarrenConversationFeed
    }

    /// The production wiring in miniature: a parent that observes the model and
    /// hands its activation token to the surface. SwiftUI only re-runs the
    /// surface when the model publishes, so this is the half of the contract a
    /// composer-only test cannot see.
    private struct ModelDrivenSurface: View {
        @ObservedObject var model: WarrenRemoteApplicationModel
        let sessionID: TerminalSessionID

        var body: some View {
            return WarrenConversationSurface(
                sessionID: sessionID,
                model: model,
                wantsInputFocus: true
            )
        }
    }

    @MainActor
    private func mount(
        focusRequest: UInt,
        wantsInputFocus: Bool,
        providerName: String = "Claude"
    ) -> Mount {
        _ = NSApplication.shared
        let feed = WarrenConversationFeed(sessionID: TerminalSessionID())
        feed.markLoaded()
        let view = WarrenConversationView(
            feed: feed,
            providerName: providerName,
            root: "/tmp",
            actions: WarrenConversationActions(),
            focusRequest: focusRequest,
            wantsInputFocus: wantsInputFocus
        )
        let hosting = NSHostingView(rootView: view)
        let window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFrontRegardless()
        settle()
        return Mount(window: window, hosting: hosting, feed: feed)
    }

    @MainActor
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    @MainActor
    private func composerTextView(in window: NSWindow) -> NSTextView? {
        window.firstResponder as? NSTextView
    }

    @MainActor
    func testActivationFocusesTheComposer() {
        let mount = mount(focusRequest: 1, wantsInputFocus: true)
        defer { mount.window.orderOut(nil as Any?) }

        XCTAssertNotNil(
            composerTextView(in: mount.window),
            "An activated Conversation Session left its composer without the keyboard."
        )
    }

    /// The activation token is only consumed while the pane owns the keyboard
    /// intent, so an overlay or a passive split pane must not take focus.
    @MainActor
    func testActivationDoesNotStealWhileThePaneIsNotFocused() {
        let mount = mount(focusRequest: 1, wantsInputFocus: false)
        defer { mount.window.orderOut(nil as Any?) }

        XCTAssertNil(
            composerTextView(in: mount.window),
            "A composer with no keyboard intent took the keyboard anyway."
        )
    }

    /// A layout pass that reaches the view again must not refocus: the token,
    /// not the update, is the activation.
    @MainActor
    func testRepeatedUpdateWithTheSameTokenDoesNotRefocus() {
        let mount = mount(focusRequest: 1, wantsInputFocus: true)
        defer { mount.window.orderOut(nil as Any?) }
        XCTAssertNotNil(composerTextView(in: mount.window))

        let standIn = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        mount.hosting.addSubview(standIn)
        XCTAssertTrue(mount.window.makeFirstResponder(standIn))

        // A new root with the same token is exactly what a parent re-render
        // produces when nothing was activated.
        mount.hosting.rootView = WarrenConversationView(
            feed: mount.feed,
            providerName: "Claude (renamed)",
            root: "/tmp",
            actions: WarrenConversationActions(),
            focusRequest: 1,
            wantsInputFocus: true
        )
        settle()

        XCTAssertTrue(
            mount.window.firstResponder === standIn,
            "A plain update re-took the keyboard from the control that had it."
        )
    }

    /// The model's activation request has to reach the pane through SwiftUI,
    /// not just move a number nobody reads.
    @MainActor
    func testModelActivationReachesTheMountedSurface() {
        _ = NSApplication.shared
        let model = WarrenRemoteApplicationModel()
        let sessionID = TerminalSessionID()
        let hosting = NSHostingView(
            rootView: ModelDrivenSurface(model: model, sessionID: sessionID)
        )
        let window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil as Any?) }
        settle()

        XCTAssertNil(
            composerTextView(in: window),
            "A mounted but unactivated Conversation pane took the keyboard."
        )

        model.requestConversationFocus(sessionID)
        settle()

        XCTAssertNotNil(
            composerTextView(in: window),
            "The model's activation request never reached the composer."
        )
    }

    /// The next activation moves the token and focuses the composer again,
    /// even though the view already exists.
    @MainActor
    func testANewTokenRefocusesAnExistingComposer() {
        let mount = mount(focusRequest: 1, wantsInputFocus: true)
        defer { mount.window.orderOut(nil as Any?) }
        XCTAssertNotNil(composerTextView(in: mount.window))

        let standIn = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        mount.hosting.addSubview(standIn)
        XCTAssertTrue(mount.window.makeFirstResponder(standIn))

        mount.hosting.rootView = WarrenConversationView(
            feed: mount.feed,
            providerName: "Claude",
            root: "/tmp",
            actions: WarrenConversationActions(),
            focusRequest: 2,
            wantsInputFocus: true
        )
        settle()

        XCTAssertNotNil(
            composerTextView(in: mount.window),
            "A second activation did not bring the keyboard back to the composer."
        )
    }
}
