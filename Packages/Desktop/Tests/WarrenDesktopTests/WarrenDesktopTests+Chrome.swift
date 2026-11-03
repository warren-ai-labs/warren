import XCTest
import SwiftUI
import AppKit
import Combine
@testable import WarrenDesktop
import WarrenDesktopFixtures
import WarrenDesignSystem
import WarrenDomain
import WarrenClientCore
import WarrenObservation

extension WarrenDesktopTests {
    func testNoticePreservesDetailAndUnreadState() {
        let notice = WarrenDesktopNotice(
            kind: .error,
            title: "Unable to open IDE",
            message: "Launch denied",
            detail: "NSError(domain: WarrenDesktopTests, code: 1)"
        )

        XCTAssertEqual(notice.kind, .error)
        XCTAssertEqual(notice.detail, "NSError(domain: WarrenDesktopTests, code: 1)")
        XCTAssertTrue(notice.isUnread)

        var readNotice = notice
        readNotice.isUnread = false
        XCTAssertFalse(readNotice.isUnread)
    }
    func testNoticeDefaultsDetailToMessage() {
        let notice = WarrenDesktopNotice(title: "Connected", message: "Daemon is ready")

        XCTAssertEqual(notice.detail, notice.message)
        XCTAssertEqual(notice.kind, .info)
    }
    func testExternalIDEOptionsRequestApplicationIcon() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var requestedPaths: [String] = []
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.jetbrains.goland" ? applicationURL : nil
            },
            directoryExists: { _ in true },
            applicationIcon: { url in
                requestedPaths.append(url.path)
                return nil
            },
            launch: { _, _ in }
        )

        _ = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(requestedPaths, ["/Applications/GoLand.app"])
    }
    func testExternalIDEOptionsCacheApplicationResolutionAndIcons() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var resolvedBundleIdentifiers: [String] = []
        var requestedIconPaths: [String] = []
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                resolvedBundleIdentifiers.append(bundleIdentifier)
                return bundleIdentifier == "com.jetbrains.goland" ? applicationURL : nil
            },
            directoryExists: { _ in true },
            applicationIcon: { url in
                requestedIconPaths.append(url.path)
                return nil
            },
            launch: { _, _ in }
        )

        let firstOptions = service.options(for: workspace, isLocalEndpoint: true)
        let secondOptions = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(firstOptions.map(\.id), secondOptions.map(\.id))
        XCTAssertEqual(
            resolvedBundleIdentifiers.count,
            WarrenDesktopExternalIDE.supported.count
        )
        XCTAssertEqual(requestedIconPaths, [applicationURL.path])
    }
    func testExternalIDEIconNormalizesAppKitIntrinsicSize() {
        let source = NSImage(size: NSSize(width: 32, height: 32))
        let normalized = WarrenDesktopExternalIDEIcon.normalized(source)

        XCTAssertEqual(WarrenDesktopExternalIDEIcon.opticalScale(for: "cursor"), 1.2)
        XCTAssertEqual(WarrenDesktopExternalIDEIcon.opticalScale(for: "xcode"), 1)
        XCTAssertEqual(
            WarrenLayoutMetrics.externalIDEIconSize,
            WarrenLayoutMetrics.chromeIconSize * WarrenLayoutMetrics.externalIDEIconScale
        )
        XCTAssertEqual(normalized.size.width, WarrenLayoutMetrics.externalIDEIconSize)
        XCTAssertEqual(normalized.size.height, WarrenLayoutMetrics.externalIDEIconSize)
        XCTAssertFalse(normalized === source)
    }
    func testExternalIDEMenuPresentationShowsOnlyInstalledApplications() {
        let options = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.microsoft.VSCode"
                    ? URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
                    : nil
            },
            directoryExists: { _ in true },
            launch: { _, _ in }
        ).options(
            for: Workspace(
                projectID: ProjectID(),
                name: "Feature",
                path: "/Users/me/Workspace/warren-feature"
            ),
            isLocalEndpoint: true
        )

        let items = WarrenDesktopExternalIDEMenuPresentation.items(from: options)

        XCTAssertEqual(items.map(\.title), ["Visual Studio Code"])
        XCTAssertEqual(items.map(\.isEnabled), [true])
    }
    /// RFC 0021: the editor is a page of the right sidebar beside the Terminal,
    /// and the Terminal never leaves the screen.
    func testEmbeddedEditorOpensBesideTheTerminalAndClosesFromTheSameControl() throws {
        let defaults = UserDefaults.standard
        let previousDefault = defaults.object(
            forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE
        )
        // The sidebar's open switch is one global preference, so a value left
        // over from another run would open the sidebar — and, with no Inspector
        // surface on this root, its only page — before the first press.
        let previousInspectorOpen = defaults.object(forKey: "warren.desktop.inspectorOpen")
        defaults.set(false, forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE)
        defaults.set(false, forKey: "warren.desktop.inspectorOpen")
        defer {
            if let previousDefault {
                defaults.set(
                    previousDefault,
                    forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE
                )
            } else {
                defaults.removeObject(
                    forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE
                )
            }
            if let previousInspectorOpen {
                defaults.set(previousInspectorOpen, forKey: "warren.desktop.inspectorOpen")
            } else {
                defaults.removeObject(forKey: "warren.desktop.inspectorOpen")
            }
        }
        let recorder = WarrenSemanticRecorder()
        var received: [WarrenDesktopAction] = []
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions { received.append($0) },
            embeddedEditorAvailable: true,
            editorSurface: { workspace in
                AnyView(
                    Text("editor:\(workspace.name)")
                        .warrenSemanticElement(
                            id: "embedded-editor.surface",
                            role: .group,
                            label: "Embedded editor"
                        )
                )
            },
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        // Wide enough to seat the Terminal and the editor region's floor at once.
        hostingView.frame = NSRect(x: 0, y: 0, width: 1600, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // The editor is never a Tab of the track, and nothing is mounted yet.
        XCTAssertNil(
            recorder.snapshot().nodes.first { $0.id == "tab.workspace-editor" }
        )
        XCTAssertNil(
            recorder.snapshot().nodes.first { $0.id == "embedded-editor.surface" }
        )

        try recorder.perform(.press, on: "right-sidebar.toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        try recorder.perform(.press, on: "right-sidebar.tab.editor")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let split = recorder.snapshot()
        XCTAssertNotNil(split.nodes.first { $0.id == "embedded-editor.surface" })
        // The Terminal is still mounted: the editor took width, not its place.
        XCTAssertNotNil(split.nodes.first { $0.id == "test-terminal.tab-main" })
        // The "+" that holds the presets stays in the top bar.
        XCTAssertNotNil(split.nodes.first { $0.id == "tab.new" })
        XCTAssertNotNil(split.nodes.first { $0.id == "central-split.resize" })
        // Nothing about the editor is Host state.
        XCTAssertTrue(received.isEmpty)

        // The Workspace's own row says the activity is a local editor, which is
        // what keeps it visible under `Active only` without implying a Session.
        XCTAssertTrue(
            recorder.snapshot().nodes.contains { node in
                node.id.hasPrefix("workspace.")
                    && (node.value?.contains("Editor open on this Mac") ?? false)
            }
        )
        // The row's marker is also the entry back to the editor, so a Workspace
        // whose editor is open is reachable from the rail rather than only from
        // the chrome control that opened it.
        let editorEntry = try XCTUnwrap(
            recorder.snapshot().nodes.first {
                $0.id.hasPrefix("workspace-editor-entry.")
            }
        )
        XCTAssertEqual(editorEntry.value, "Show the editor")
        try recorder.perform(.press, on: editorEntry.id)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // Navigating from the rail keeps the region and asks only for selection:
        // the entry moves the user to the Workspace, it does not mutate a Host.
        XCTAssertNotNil(
            recorder.snapshot().nodes.first { $0.id == "embedded-editor.surface" }
        )
        XCTAssertTrue(
            received.allSatisfy {
                if case .selectWorkspace = $0 { true } else { false }
            },
            "unexpected actions: \(received)"
        )
        XCTAssertFalse(received.isEmpty)
        received.removeAll()

        // The Editor tab's close box turns the region off without hiding the
        // sidebar.
        try recorder.perform(.press, on: "right-sidebar.editor.close")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let closed = recorder.snapshot()
        XCTAssertNil(closed.nodes.first { $0.id == "embedded-editor.surface" })
        // Closing does not end the Terminal's Session or reach the Host.
        XCTAssertNotNil(closed.nodes.first { $0.id == "test-terminal.tab-main" })
        XCTAssertTrue(received.isEmpty)
        // One close, not two: closing clears the marker, so the Workspace no
        // longer reads as editor-marked and a relaunch will not reopen it.
        XCTAssertFalse(
            closed.nodes.contains { node in
                node.id.hasPrefix("workspace.")
                    && (node.value?.contains("Editor open on this Mac") ?? false)
            }
        )
        // The rail's entry goes with the marker: nothing points at a region that
        // is no longer there.
        XCTAssertNil(
            closed.nodes.first { $0.id.hasPrefix("workspace-editor-entry.") }
        )
    }
    func testTitleBarDoubleClickFollowsTheSystemPreference() {
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "Minimize"), .minimize)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "None"), .ignore)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "Maximize"), .zoom)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "Fill"), .zoom)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: nil), .zoom, "Unset is the system default")
    }
}
