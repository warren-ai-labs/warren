import AppKit
import SwiftUI
import XCTest

import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
@testable import WarrenDesktop

/// A borderless window that can still become key, the way the app's own
/// window does. The render harness never orders it front; the environment
/// override supplies the key-window state, so the tests leave no window on
/// screen.
private final class KeyableRenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// A terminal slot that draws nothing but its context, so a rendered window is
/// not waiting on a Host.
private struct RenderTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        Text("surface:\(context.tab.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Renders the real window at its expanded, collapsed, and peeking states.
///
/// The point is to look at the three states rather than only measure them: a
/// collapsed sidebar must leave no rail, and the peek must lie over the content
/// instead of taking width from it. The root view is mounted as-is; only the
/// terminal surface is a stub, because a Host is not available in a test.
final class WarrenDesktopSidebarChromeRenderTests: XCTestCase {
    private struct Fixture {
        let projection: WarrenDesktopProjection
    }

    private func makeFixture(
        needsInput: Bool = false,
        failed: Bool = false
    ) -> Fixture {
        let host = Host(name: "studio")
        let warren = Project(hostID: host.id, name: "warren", rootPath: "/tmp/warren")
        let ghostline = Project(hostID: host.id, name: "ghostline", rootPath: "/tmp/ghostline")
        let main = Workspace(
            projectID: warren.id,
            name: "main",
            path: "/tmp/warren",
            branch: "main"
        )
        let sidebar = Workspace(
            projectID: warren.id,
            name: "feat/sidebar",
            path: "/tmp/warren-sidebar",
            branch: "feat/sidebar"
        )
        let cargo = Workspace(
            projectID: ghostline.id,
            name: "main",
            path: "/tmp/ghostline",
            branch: "main"
        )
        let sessions = [
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: sidebar.id,
                tabID: "tab-sidebar",
                title: "Sidebar rows",
                kind: .claude,
                activity: .working,
                currentStep: "Editing WarrenDesktopSidebarView.swift"
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: cargo.id,
                tabID: "tab-cargo",
                title: "cargo build",
                kind: .shell,
                agentStatus: failed
                    ? AgentStatus(activity: .failed)
                    : (needsInput
                        ? AgentStatus(
                            activity: .blocked,
                            attention: AgentAttention(
                                kind: .input,
                                reason: "Wants approval to run git push"
                            )
                        )
                        : nil),
                lastActivity: failed
                    ? "Ran cargo test · exit 1"
                    : (needsInput ? "Wants approval to run git push" : nil)
            ),
        ]
        return Fixture(
            projection: WarrenDesktopProjection(
                host: host,
                projects: [warren, ghostline],
                workspaces: [main, sidebar, cargo],
                sessions: sessions
            )
        )
    }

    @MainActor
    private func makeRoot(_ fixture: Fixture) -> some View {
        WarrenDesktopRoot(
            projection: fixture.projection,
            persistenceEnabled: false
        ) { context in
            RenderTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        // A test process cannot become the key window, so the harness declares
        // what a real focused window reports. The gate itself is exercised by
        // the peek controller's unit tests.
        .environment(\.controlActiveState, .key)
    }

    @MainActor
    private func mount(_ root: AnyView, size: CGSize) -> (NSHostingView<AnyView>, NSWindow) {
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = KeyableRenderWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    @MainActor
    private func write(_ view: NSView, to directory: String, name: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("No bitmap for \(name)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Copies the top-left corner of a rendered window so a 7pt dot is legible.
    @MainActor
    private func writeCrop(
        _ view: NSView,
        to directory: String,
        name: String,
        rect: CGRect,
        scale: CGFloat = 3
    ) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("No bitmap for \(name)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let full = bitmap.cgImage,
              let cropped = full.cropping(to: rect) else {
            return XCTFail("No crop for \(name)")
        }
        let width = Int(CGFloat(cropped.width) * scale)
        let height = Int(CGFloat(cropped.height) * scale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return XCTFail("No context for \(name)")
        }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            return XCTFail("No scaled image for \(name)")
        }
        let rep = NSBitmapImageRep(cgImage: scaled)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    func testWritesTheExpandedCollapsedAndPeekStatesWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_SIDEBAR_IMAGES"] else {
            throw XCTSkip("Set WARREN_SIDEBAR_IMAGES to write sidebar PNGs")
        }
        let size = CGSize(width: 1_180, height: 760)
        let fixture = makeFixture(needsInput: true)

        // Expanded.
        let (expanded, expandedWindow) = mount(AnyView(makeRoot(fixture)), size: size)
        try write(expanded, to: directory, name: "sidebar-peek-expanded")
        expandedWindow.orderOut(nil)

        // Collapsed: the rail is gone and the content card takes the inset.
        let (collapsed, collapsedWindow) = mount(AnyView(makeRoot(fixture)), size: size)
        NotificationCenter.default.post(name: WarrenDesktopCommand.toggleSidebar, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        collapsed.layoutSubtreeIfNeeded()
        try write(collapsed, to: directory, name: "sidebar-peek-collapsed")
        collapsedWindow.orderOut(nil)

        // Peek: the full sidebar over the content card, at the same width.
        let (peek, peekWindow) = mount(AnyView(makeRoot(fixture)), size: size)
        NotificationCenter.default.post(name: WarrenDesktopCommand.toggleSidebar, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        NotificationCenter.default.post(name: WarrenDesktopCommand.peekSidebar, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        peek.layoutSubtreeIfNeeded()
        try write(peek, to: directory, name: "sidebar-peek-shown")
        peekWindow.orderOut(nil)
    }

    @MainActor
    func testWritesTheCollapsedButtonDotWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_SIDEBAR_IMAGES"] else {
            throw XCTSkip("Set WARREN_SIDEBAR_IMAGES to write sidebar PNGs")
        }
        let size = CGSize(width: 1_180, height: 760)
        let crop = CGRect(x: 140, y: 0, width: 200, height: 56)

        let (orange, orangeWindow) = mount(
            AnyView(makeRoot(makeFixture(needsInput: true))),
            size: size
        )
        NotificationCenter.default.post(name: WarrenDesktopCommand.toggleSidebar, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        orange.layoutSubtreeIfNeeded()
        try writeCrop(orange, to: directory, name: "sidebar-peek-dot-orange", rect: crop)
        orangeWindow.orderOut(nil)

        let (red, redWindow) = mount(
            AnyView(makeRoot(makeFixture(failed: true))),
            size: size
        )
        NotificationCenter.default.post(name: WarrenDesktopCommand.toggleSidebar, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        red.layoutSubtreeIfNeeded()
        try writeCrop(red, to: directory, name: "sidebar-peek-dot-red", rect: crop)
        redWindow.orderOut(nil)

        let (idle, idleWindow) = mount(
            AnyView(makeRoot(makeFixture())),
            size: size
        )
        NotificationCenter.default.post(name: WarrenDesktopCommand.toggleSidebar, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        idle.layoutSubtreeIfNeeded()
        try writeCrop(idle, to: directory, name: "sidebar-peek-dot-none", rect: crop)
        idleWindow.orderOut(nil)
    }
}
