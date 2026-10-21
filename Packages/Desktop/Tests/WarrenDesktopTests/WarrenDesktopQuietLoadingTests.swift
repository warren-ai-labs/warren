import AppKit
import SwiftUI
import XCTest

import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation
@testable import WarrenDesktop

/// The launch and the in-app update are the two waits Warren cannot avoid, and
/// both are usually shorter than it takes to read anything. These tests pin the
/// promise that the window holds still and says nothing until a wait is worth
/// mentioning, then says it with one quiet line.
final class WarrenDesktopQuietLoadingTests: XCTestCase {
    private struct RenderTerminalSurface: View {
        let context: WarrenDesktopTerminalContext

        var body: some View {
            Text("surface:\(context.tab.id)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Long enough to be past the reveal without depending on frame timing.
    private static let afterReveal: TimeInterval = 0.8
    /// Short enough to still be inside the hold.
    private static let insideHold: TimeInterval = 0.15

    /// Hosting views need a window: a transition's fade only advances while
    /// the view is in one. The window is never ordered front, so the harness
    /// stays off screen.
    private var windows: [NSWindow] = []

    @MainActor
    private func mount<T: View>(_ view: T, recorder: WarrenSemanticRecorder) -> NSHostingView<T> {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 1_180, height: 760)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return hosting
    }

    @MainActor
    private func makeConnectingStage(
        recorder: WarrenSemanticRecorder,
        colorScheme: ColorScheme = .dark
    ) -> some View {
        WarrenDesktopConnectingStage(title: "Connecting to Local")
            .environment(\.colorScheme, colorScheme)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)
            .frame(width: 1_180, height: 760)
    }

    private static func makeProjection(
        connectionState: WarrenDesktopConnectionState = .attached,
        hasProjects: Bool = true
    ) -> WarrenDesktopProjection {
        let host = Host(name: "studio")
        let project = Project(hostID: host.id, name: "warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/warren",
            branch: "main"
        )
        return WarrenDesktopProjection(
            host: host,
            projects: hasProjects ? [project] : [],
            workspaces: hasProjects ? [workspace] : [],
            sessions: [],
            connectionState: connectionState
        )
    }

    @MainActor
    private func makeRoot(
        recorder: WarrenSemanticRecorder,
        connectionState: WarrenDesktopConnectionState = .attached,
        updateStatus: WarrenDesktopUpdateStatus = .none,
        hasProjects: Bool = true,
        colorScheme: ColorScheme = .dark
    ) -> some View {
        let projection = Self.makeProjection(
            connectionState: connectionState,
            hasProjects: hasProjects
        )
        return WarrenDesktopRoot(
            projection: projection,
            updateStatus: updateStatus,
            persistenceEnabled: false
        ) { context in
            RenderTerminalSurface(context: context)
        }
        .environment(\.colorScheme, colorScheme)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: 1_180, height: 760)
    }

    @MainActor
    func testLaunchHoldsTheFrameBeforeItSaysConnecting() {
        let recorder = WarrenSemanticRecorder()
        let hosting = mount(makeConnectingStage(recorder: recorder), recorder: recorder)

        RunLoop.main.run(until: Date().addingTimeInterval(Self.insideHold))
        XCTAssertNil(
            recorder.snapshot().node(id: WarrenDesktopConnectingStage.elementID),
            "A connect that beats the delay must not draw a loading state"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
        let node = recorder.snapshot().node(id: WarrenDesktopConnectingStage.elementID)
        XCTAssertEqual(node?.label, "Connecting to Local")
        hosting.removeFromSuperview()
    }

    @MainActor
    func testUpdateKeepsTheWindowAndRevealsOneCapsule() {
        let recorder = WarrenSemanticRecorder()
        let hosting = mount(
            makeRoot(recorder: recorder, updateStatus: .updating),
            recorder: recorder
        )

        RunLoop.main.run(until: Date().addingTimeInterval(Self.insideHold))
        let heldSnapshot = recorder.snapshot()
        XCTAssertNil(heldSnapshot.node(id: WarrenDesktopUpdateHUD.elementID))
        // The window is not replaced: the sidebar's own update button, which
        // sits on the content behind the HUD, is still there to be read.
        XCTAssertNotNil(heldSnapshot.node(id: "sidebar.update"))

        RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
        let revealedSnapshot = recorder.snapshot()
        XCTAssertEqual(
            revealedSnapshot.node(id: WarrenDesktopUpdateHUD.elementID)?.label,
            WarrenDesktopUpdateHUD.title
        )
        XCTAssertNotNil(revealedSnapshot.node(id: "sidebar.update"))
        hosting.removeFromSuperview()
    }

    /// A failed install puts the window back: the capsule and its dim go, and
    /// the shell the user was working in is the shell they get.
    @MainActor
    func testAFailedInstallTakesTheCapsuleAway() {
        let recorder = WarrenSemanticRecorder()
        let probe = UpdateStatusProbe(
            recorder: recorder,
            projection: Self.makeProjection()
        )
        let hosting = mount(probe, recorder: recorder)
        RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
        XCTAssertNotNil(recorder.snapshot().node(id: WarrenDesktopUpdateHUD.elementID))

        NotificationCenter.default.post(name: Self.endUpdate, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
        XCTAssertNil(recorder.snapshot().node(id: WarrenDesktopUpdateHUD.elementID))
        XCTAssertNotNil(recorder.snapshot().node(id: "sidebar.update"))
        hosting.removeFromSuperview()
    }

    private static let endUpdate = Notification.Name("WarrenDesktopQuietLoadingTests.endUpdate")

    /// A root whose update status can be finished from outside, the way the
    /// composition root does when the download fails.
    private struct UpdateStatusProbe: View {
        let recorder: WarrenSemanticRecorder
        let projection: WarrenDesktopProjection
        @State private var status = WarrenDesktopUpdateStatus.updating

        var body: some View {
            WarrenDesktopRoot(
                projection: projection,
                updateStatus: status,
                persistenceEnabled: false
            ) { context in
                RenderTerminalSurface(context: context)
            }
            .environment(\.colorScheme, .dark)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)
            .frame(width: 1_180, height: 760)
            .onReceive(NotificationCenter.default.publisher(for: endUpdate)) { _ in
                status = .failed
            }
        }
    }

    /// A Host update shows the window's one card, not one per terminal.
    @MainActor
    func testHostMaintenanceShowsTheWindowCard() {
        let recorder = WarrenSemanticRecorder()
        let root = WarrenDesktopRoot(
            projection: Self.makeProjection(),
            hostMaintenanceMessage: "Warren is updating",
            persistenceEnabled: false
        ) { context in
            RenderTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: 1_180, height: 760)
        let hosting = mount(root, recorder: recorder)

        RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
        let nodes = recorder.snapshot().nodes.filter { $0.id == WarrenDesktopUpdateHUD.elementID }
        XCTAssertEqual(nodes.count, 1)
        hosting.removeFromSuperview()
    }

    @MainActor
    func testAnIdleShellDrawsNoUpdateState() {
        let recorder = WarrenSemanticRecorder()
        let hosting = mount(makeRoot(recorder: recorder), recorder: recorder)

        RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
        XCTAssertNil(recorder.snapshot().node(id: WarrenDesktopUpdateHUD.elementID))
        hosting.removeFromSuperview()
    }

    func testConnectingLineNamesWhatTheWaitIsFor() {
        XCTAssertEqual(
            WarrenDesktopWorkspaceContent<EmptyView>.connectingTitle(
                hostName: "studio",
                isReconnecting: false,
                migratingRuntimeSessions: false
            ),
            "Connecting to studio"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceContent<EmptyView>.connectingTitle(
                hostName: "studio",
                isReconnecting: true,
                migratingRuntimeSessions: false
            ),
            "Reconnecting to studio"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceContent<EmptyView>.connectingTitle(
                hostName: "studio",
                isReconnecting: false,
                migratingRuntimeSessions: true
            ),
            "Migrating runtime sessions…"
        )
    }

    /// Writes the held frame and the revealed line when asked, so the launch
    /// state can be looked at rather than only measured.
    @MainActor
    func testWritesTheLoadingStatesWhenAnArtifactDirectoryIsGiven() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_LOADING_IMAGES"] else {
            throw XCTSkip("Set WARREN_LOADING_IMAGES to write loading-state PNGs")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let recorder = WarrenSemanticRecorder()

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"

            // The launch, in the shell it actually happens in: the chrome holds
            // its ground, then one line appears in the content card.
            let held = mount(
                makeRoot(
                    recorder: recorder,
                    connectionState: .connecting,
                    hasProjects: false,
                    colorScheme: scheme
                ),
                recorder: recorder
            )
            try write(held, to: directory, name: "launch-held-\(suffix)")
            RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
            held.layoutSubtreeIfNeeded()
            try write(held, to: directory, name: "launch-connecting-\(suffix)")
            held.removeFromSuperview()

            // What the crossfade lands on once the Host has answered.
            let answered = mount(
                makeRoot(recorder: recorder, hasProjects: false, colorScheme: scheme),
                recorder: recorder
            )
            RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
            answered.layoutSubtreeIfNeeded()
            try write(answered, to: directory, name: "launch-answered-\(suffix)")
            answered.removeFromSuperview()

            let updating = mount(
                makeRoot(recorder: recorder, updateStatus: .updating, colorScheme: scheme),
                recorder: recorder
            )
            RunLoop.main.run(until: Date().addingTimeInterval(Self.afterReveal))
            updating.layoutSubtreeIfNeeded()
            try write(updating, to: directory, name: "update-restarting-\(suffix)")
            updating.removeFromSuperview()
        }
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
}
