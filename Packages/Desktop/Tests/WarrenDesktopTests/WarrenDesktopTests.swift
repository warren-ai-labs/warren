import XCTest
import SwiftUI
import AppKit
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain
import WarrenClientCore

private struct TestTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        Text("surface:\(context.tab.id):\(context.workspace?.id.rawValue.uuidString ?? context.terminalGroup?.id.rawValue.uuidString ?? "none")")
    }
}

@MainActor
final class WarrenDesktopTests: XCTestCase {
    func testWorkspaceChromeIsDefaultAndDoesNotShowIndependentTopBar() {
        XCTAssertFalse(WarrenDesktopChromeMode.workspace.showsIndependentTopBar)
        XCTAssertTrue(WarrenDesktopChromeMode.dashboard.showsIndependentTopBar)

    }

    func testWorkspaceTabTrailingControlsHaveStableOrder() {
        XCTAssertEqual(
            WarrenDesktopWorkspaceTabTrailingControl.allCases,
            [.externalIDE, .endpoint, .web, .inspector, .settings]
        )
    }

    func testRootWorkspaceIsNotClassifiedAsWorktreeForDeletion() {
        let host = Host(name: "Local")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/Users/me/warren")
        let root = Workspace(projectID: project.id, name: "main", path: project.rootPath)
        let worktree = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/Users/me/warren-feature"
        )

        XCTAssertFalse(workspaceIsWorktree(root, project: project))
        XCTAssertTrue(workspaceIsWorktree(worktree, project: project))
    }

    func testExternalIDECatalogHasStableOrderAndBundleIdentifiers() {
        XCTAssertEqual(
            WarrenDesktopExternalIDE.supported.map(\.id),
            [
                .xcode,
                .visualStudioCode,
                .cursor,
                .windsurf,
                .zed,
                .intellijIDEA,
                .intellijIDEACommunity,
                .goLand,
                .pyCharm,
                .pyCharmCommunity,
                .webStorm,
                .phpStorm,
                .rubyMine,
                .clion,
                .rider,
                .dataGrip,
                .rustRover,
                .androidStudio,
                .sublimeText,
                .bbEdit,
                .textMate,
                .macVim,
                .nova,
            ]
        )
        XCTAssertEqual(
            WarrenDesktopExternalIDE.supported.map(\.bundleIdentifier),
            [
                "com.apple.dt.Xcode",
                "com.microsoft.VSCode",
                "com.todesktop.230313mzl4w4u92",
                "com.exafunction.windsurf",
                "dev.zed.Zed",
                "com.jetbrains.intellij",
                "com.jetbrains.intellij.ce",
                "com.jetbrains.goland",
                "com.jetbrains.pycharm",
                "com.jetbrains.pycharm.ce",
                "com.jetbrains.webstorm",
                "com.jetbrains.phpstorm",
                "com.jetbrains.rubymine",
                "com.jetbrains.clion",
                "com.jetbrains.rider",
                "com.jetbrains.datagrip",
                "com.jetbrains.rustrover",
                "com.google.android.studio",
                "com.sublimetext.4",
                "com.barebones.bbedit",
                "com.macromates.TextMate",
                "org.vim.MacVim",
                "com.panic.Nova",
            ]
        )
    }

    func testExternalIDEOptionsEnableOnlyInstalledApplicationsForLocalWorkspace() {
        let projectID = ProjectID()
        let workspace = Workspace(
            projectID: projectID,
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let codeURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.microsoft.VSCode" ? codeURL : nil
            },
            directoryExists: { $0.path == workspace.path },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(options.map(\.id), ["visualStudioCode"])
        XCTAssertEqual(options.map(\.isEnabled), [true])
        XCTAssertEqual(options.first?.workspaceURL?.path, workspace.path)
        XCTAssertEqual(options.first?.applicationURL, codeURL)
    }

    func testExternalIDEOptionsDisableEveryApplicationForRemoteWorkspace() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Remote",
            path: "/srv/warren"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in URL(fileURLWithPath: "/Applications/IDE.app") },
            directoryExists: { _ in true },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: false)

        XCTAssertEqual(options.count, WarrenDesktopExternalIDE.supported.count)
        XCTAssertTrue(options.allSatisfy { !$0.isEnabled })
    }

    func testExternalIDEOptionsDisableEveryApplicationWithoutExistingWorkspaceDirectory() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Missing",
            path: "/missing/worktree"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in URL(fileURLWithPath: "/Applications/IDE.app") },
            directoryExists: { _ in false },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        XCTAssertTrue(
            service.options(for: workspace, isLocalEndpoint: true)
                .allSatisfy { !$0.isEnabled }
        )
        XCTAssertTrue(
            service.options(for: nil, isLocalEndpoint: true)
                .allSatisfy { !$0.isEnabled }
        )
    }

    func testExternalIDEServiceLaunchesWorkspaceWithResolvedApplication() async throws {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var launchedWorkspaceURL: URL?
        var launchedApplicationURL: URL?
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in applicationURL },
            directoryExists: { _ in true },
            launch: { workspaceURL, resolvedApplicationURL in
                launchedWorkspaceURL = workspaceURL
                launchedApplicationURL = resolvedApplicationURL
            }
        )
        let option = try XCTUnwrap(
            service.options(for: workspace, isLocalEndpoint: true)
                .first { $0.id == "goLand" }
        )

        try await service.open(option)

        XCTAssertEqual(launchedWorkspaceURL?.path, workspace.path)
        XCTAssertEqual(launchedApplicationURL, applicationURL)
    }

    func testExternalIDECustomIDEsAppearInOptions() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let custom = WarrenDesktopCustomIDE(name: "Cursor", path: "/Applications/Cursor.app")
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in nil },
            directoryExists: { _ in true },
            loadCustomIDEs: { [custom] },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(options.map(\.id), ["custom:\(custom.id.uuidString)"])
        XCTAssertEqual(options.first?.name, "Cursor")
        XCTAssertEqual(options.first?.applicationURL?.path, "/Applications/Cursor.app")
        XCTAssertEqual(options.first?.isEnabled, true)
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

    func testExternalIDEIconNormalizesAppKitIntrinsicSize() {
        let source = NSImage(size: NSSize(width: 32, height: 32))
        let normalized = WarrenDesktopExternalIDEIcon.normalized(source)

        XCTAssertEqual(normalized.size.width, WarrenLayoutMetrics.externalIDEIconSize)
        XCTAssertEqual(normalized.size.height, WarrenLayoutMetrics.externalIDEIconSize)
        XCTAssertFalse(normalized === source)
    }

    func testExternalIDECustomStoreRoundTrips() {
        let defaults = UserDefaults.standard
        let key = "warren.customExternalIDEs"
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let custom = WarrenDesktopCustomIDE(name: "Cursor", path: "/Applications/Cursor.app")
        WarrenDesktopCustomIDEStore.save([custom])
        let loaded = WarrenDesktopCustomIDEStore.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Cursor")
        XCTAssertEqual(loaded.first?.path, "/Applications/Cursor.app")
    }

    func testExternalIDEIsApplicationBundleDetection() {
        XCTAssertTrue(
            WarrenDesktopExternalIDEService.isApplicationBundle(
                URL(fileURLWithPath: "/Applications/Xcode.app")
            )
        )
        XCTAssertFalse(
            WarrenDesktopExternalIDEService.isApplicationBundle(
                URL(fileURLWithPath: "/usr/local/bin/code")
            )
        )
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

    func testExternalIDEFailureUsesIDENameAndLaunchErrorDescription() {
        let error = NSError(
            domain: "WarrenDesktopTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Launch denied"]
        )

        let failure = WarrenDesktopExternalIDEFailure(ideName: "GoLand", error: error)

        XCTAssertEqual(failure.title, "Unable to Open GoLand")
        XCTAssertEqual(failure.message, "Launch denied")
    }

    func testRootLayoutMountsAtSupersetDesktopSizeWithoutPixelCapture() {
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(hostingView.bounds.width, 1280)
        XCTAssertEqual(hostingView.bounds.height, 800)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, hostingView.bounds.width)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, hostingView.bounds.height)
        XCTAssertGreaterThanOrEqual(
            hostingView.fittingSize.width,
            WarrenLayoutMetrics.sidebarExpandedWidth + WarrenLayoutMetrics.paneMinimumWidth
        )
        XCTAssertGreaterThanOrEqual(
            hostingView.fittingSize.height,
            WarrenLayoutMetrics.tabBarHeight
                + WarrenLayoutMetrics.presetBarHeight
                + WarrenLayoutMetrics.paneHeaderHeight
                + WarrenLayoutMetrics.paneMinimumHeight
        )
    }

    func testTabBarDragFillerSpansEmptyTrackWhenTabsFit() {
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let dragViews = descendantViews(
            of: hostingView,
            as: WarrenDesktopWindowDragView.self
        )
        guard let filler = dragViews.first(where: {
            $0.identifier?.rawValue == "warren.tab-bar-drag-region"
        }) else {
            XCTFail("Tab bar drag filler is missing")
            return
        }

        XCTAssertGreaterThanOrEqual(filler.frame.width, 100)
    }

    func testTabBarEngagesOverflowModeWhenTrailingChromeLeavesNarrowTrack() {
        let tabs = (0..<6).map { index in
            ClientTab(
                id: "tab-\(index)",
                title: "Session \(index)",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            )
        }
        let tabBar = tabBar(tabs: tabs)

        let hostingView = NSHostingView(rootView: tabBar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        let scrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        let tabTrack = WarrenDesktopTabBar.tabTrackWidth(tabCount: tabs.count)
        XCTAssertTrue(
            scrollViews.contains { $0.frame.width < tabTrack - 1 },
            "Scroll track must shrink below the tab track when overflow engages"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        let settledScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        XCTAssertEqual(
            settledScrollViews.map(\.frame.width),
            scrollViews.map(\.frame.width),
            "Overflow state must settle instead of toggling"
        )
    }

    func testTabBarStaysInFitModeWhenTabsFit() {
        let tabs = [
            ClientTab(
                id: "tab-a",
                title: "A",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            ),
            ClientTab(
                id: "tab-b",
                title: "B",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            ),
        ]
        let tabBar = tabBar(tabs: tabs)

        let hostingView = NSHostingView(rootView: tabBar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        let scrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        let tabTrack = WarrenDesktopTabBar.tabTrackWidth(tabCount: tabs.count)
        XCTAssertTrue(
            scrollViews.contains { abs($0.frame.width - tabTrack) < 1 },
            "Scroll track must exactly match the tab track when tabs fit"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        let settledScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        XCTAssertEqual(
            settledScrollViews.map(\.frame.width),
            scrollViews.map(\.frame.width),
            "Fit state must settle instead of toggling"
        )
    }

    func testOverflowFadeScrollViewSettlesWithHorizontalOverflow() {
        let scroll = WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: 36,
            surface: .black,
            showsEdgeChevrons: true
        ) {
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { _ in
                    Color.white.frame(width: 150, height: 36)
                }
            }
        }
        .frame(width: 500, height: 36)

        let hostingView = NSHostingView(rootView: scroll)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 36)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hostingView.layoutSubtreeIfNeeded()

        let initialFrames = descendantViews(of: hostingView, as: NSScrollView.self).map(\.frame)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            descendantViews(of: hostingView, as: NSScrollView.self).map(\.frame),
            initialFrames
        )
    }

    func testOverflowFadeScrollViewRefreshesEdgesAfterViewportResize() {
        let scroll = WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: 36,
            surface: .black,
            showsEdgeChevrons: true
        ) {
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { _ in
                    Color.white.frame(width: 150, height: 36)
                }
            }
        }

        let hostingView = NSHostingView(rootView: scroll)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 36)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        let narrowWidth = descendantViews(of: hostingView, as: NSScrollView.self).first?.frame.width

        hostingView.setFrameSize(NSSize(width: 2000, height: 36))
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        let wideWidth = descendantViews(of: hostingView, as: NSScrollView.self).first?.frame.width
        XCTAssertNotEqual(narrowWidth, wideWidth)

        hostingView.setFrameSize(NSSize(width: 500, height: 36))
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            descendantViews(of: hostingView, as: NSScrollView.self).first?.frame.width,
            narrowWidth
        )
    }

    private func descendantViews<T: NSView>(
        of view: NSView,
        as type: T.Type
    ) -> [T] {
        var matches: [T] = []
        for subview in view.subviews {
            if let typed = subview as? T {
                matches.append(typed)
            }
            matches.append(contentsOf: descendantViews(of: subview, as: type))
        }
        return matches
    }

    private func tabBar(tabs: [ClientTab]) -> some View {
        WarrenDesktopTabBar(
            tabs: tabs,
            tabTitles: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) }),
            tabActivities: [:],
            pinnedSessionIDs: [],
            selectedTabID: tabs.first?.id,
            chromeMode: .workspace,
            isSidebarCollapsed: false,
            connectionState: .attached,
            endpointOptions: [WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true)],
            selectedEndpointID: "local",
            webStatus: WarrenDesktopWebStatus(),
            externalIDEOptions: nil,
            hasInspector: false,
            isInspectorVisible: false,
            onToggleSidebar: {},
            onToggleInspector: {},
            onSettings: {},
            onWeb: {},
            onOpenInExternalIDE: { _ in },
            onSelectEndpoint: { _ in },
            onSelectTab: { _ in },
            onMoveTab: { _, _ in },
            sessionMoveTargets: [],
            sessionMoveDestinations: [:],
            onMoveSession: { _, _ in },
            canAddTab: true,
            isAddingTab: false,
            onAddTab: {},
            onCloseTab: { _ in },
            onCloseOtherTabs: { _ in },
            onCloseAllTabs: {},
            onRequestRename: { _ in },
            onToggleSessionPin: { _, _ in },
            onDismissActivity: { _, _ in }
        )
        .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
    }

    func testWindowDragRegionUsesDedicatedAppKitView() {
        let view = WarrenDesktopWindowDragView()

        XCTAssertFalse(view.acceptsFirstResponder)
    }

    func testSidebarDragRequiresFivePointMovementThreshold() {
        let origin = CGPoint(x: 20, y: 20)

        XCTAssertFalse(WarrenSidebarDragGesture.hasExceededThreshold(
            from: origin,
            to: CGPoint(x: 23, y: 23)
        ))
        XCTAssertTrue(WarrenSidebarDragGesture.hasExceededThreshold(
            from: origin,
            to: CGPoint(x: 23, y: 24)
        ))
    }

    func testSidebarDragOverlayAcceptsFirstModifiedClick() {
        let session = WarrenDesktopSidebarDragSession()
        let view = WarrenDesktopSidebarDragOverlayView(session: session)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testSidebarDragSessionPublishesMeasurementChangesOncePerState() {
        let session = WarrenDesktopSidebarDragSession()
        let clientID = UUID()
        var measurementStates: [Bool] = []

        session.addClient(id: clientID) { measurementStates.append($0) }
        session.setActive(true)
        session.setActive(true)
        session.setActive(false)
        session.removeClient(id: clientID)

        XCTAssertEqual(measurementStates, [true, false])
    }

    func testSidebarDragAutoCollapseKeepsOnlyValidDestinationsVisible() {
        let projectID = ProjectID()
        let otherProjectID = ProjectID()
        let workspaceID = WorkspaceID()
        let projectInfo = WarrenSidebarRowDragInfo(
            id: projectID.description,
            kind: .project(projectID),
            name: "Project",
            isLastOfList: false
        )
        let workspaceInfo = WarrenSidebarRowDragInfo(
            id: workspaceID.description,
            kind: .workspace(workspaceID, projectID: projectID),
            name: "Workspace",
            isLastOfList: false
        )

        XCTAssertEqual(
            WarrenSidebarDragPresentation.autoCollapse(for: projectInfo),
            .allProjects
        )
        XCTAssertEqual(
            WarrenSidebarDragPresentation.autoCollapse(for: workspaceInfo),
            .projectsExcept(projectID)
        )
        XCTAssertTrue(WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedExpansions: [projectID, otherProjectID],
            autoCollapse: .projectsExcept(projectID)
        ))
        XCTAssertFalse(WarrenSidebarDragPresentation.isExpanded(
            otherProjectID,
            persistedExpansions: [projectID, otherProjectID],
            autoCollapse: .projectsExcept(projectID)
        ))
        XCTAssertFalse(WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedExpansions: [projectID],
            autoCollapse: .allProjects
        ))
    }

    func testConnectionPresentationDistinguishesLoadingAndFailureStates() {
        let connecting = WarrenDesktopConnectionPresentation(.connecting)
        XCTAssertEqual(connecting.label, "Connecting…")
        XCTAssertEqual(connecting.tone, .info)
        XCTAssertTrue(connecting.isActive)

        let reconnecting = WarrenDesktopConnectionPresentation(.reconnecting)
        XCTAssertEqual(reconnecting.label, "Reconnecting…")
        XCTAssertEqual(reconnecting.tone, .warning)
        XCTAssertTrue(reconnecting.isActive)

        let failed = WarrenDesktopConnectionPresentation(.failed)
        XCTAssertEqual(failed.label, "Connection failed")
        XCTAssertEqual(failed.tone, .destructive)
        XCTAssertFalse(failed.isActive)
    }

    func testWindowDragRegionPerformsDragOnSingleClick() {
        let view = WarrenDesktopWindowDragView()
        let window = WarrenDragProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        view.mouseDown(with: Self.mouseDownEvent(clickCount: 1))

        XCTAssertTrue(window.didRequestDrag)
        XCTAssertFalse(window.didToggleFullScreen)
    }

    func testWindowDragRegionTogglesFullScreenOnDoubleClick() {
        let view = WarrenDesktopWindowDragView()
        let window = WarrenDragProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        view.mouseDown(with: Self.mouseDownEvent(clickCount: 2))

        XCTAssertTrue(window.didToggleFullScreen)
        XCTAssertFalse(window.didRequestDrag)
    }

    private static func mouseDownEvent(clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private static func mouseUpEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )!
    }

    private static func mouseEnteredEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 3,
            trackingNumber: 1,
            userData: nil
        )!
    }

    private static func mouseExitedEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 4,
            trackingNumber: 1,
            userData: nil
        )!
    }

    func testSidebarStateUsesSupersetSnapAndRestoreValues() {
        var state = WarrenDesktopSidebarState()
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)
        XCTAssertFalse(state.isCollapsed)

        state.setWidth(119)
        XCTAssertTrue(state.isCollapsed)
        XCTAssertEqual(state.renderedWidth, WarrenLayoutMetrics.sidebarCollapsedWidth)

        state.restoreExpanded()
        XCTAssertFalse(state.isCollapsed)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)

        state.setWidth(399)
        XCTAssertEqual(state.width, 399)
        state.setWidth(401)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarMaximumWidth)
    }

    func testPreviewFixtureKeepsStableRowsAndRelationships() {
        let fixture = WarrenDesktopFixture.preview
        XCTAssertEqual(fixture.groups.count, 2)
        XCTAssertEqual(fixture.groups.first?.workspaces.count, 2)
        XCTAssertEqual(
            fixture.groups.first?.workspaces.first?.projectID,
            fixture.groups.first?.project.id
        )
        XCTAssertEqual(fixture.tabs.map(\.id), ["tab-main", "tab-review"])
        XCTAssertNotNil(fixture.workspace(id: fixture.groups[0].workspaces[0].id))
    }

    func testProjectionKeepsEmptyStateWithoutInventingRows() {
        let fixture = WarrenDesktopFixture.preview
        let projection = WarrenDesktopProjection.empty(host: fixture.host)

        XCTAssertTrue(projection.groups.isEmpty)
        XCTAssertTrue(projection.tabs.isEmpty)
        XCTAssertNil(projection.inspector)
        XCTAssertTrue(projection.isConnected)
        XCTAssertNil(projection.workspace(id: fixture.groups[0].workspaces[0].id))
    }

    func testProjectionFindsFirstWorkspaceAfterAnEmptyProject() {
        let host = WarrenDomain.Host(name: "Indexed Host")
        let emptyProject = Project(hostID: host.id, name: "Empty", rootPath: "/tmp/empty")
        let populatedProject = Project(hostID: host.id, name: "Populated", rootPath: "/tmp/full")
        let workspace = Workspace(
            projectID: populatedProject.id,
            name: "main",
            path: "/tmp/full"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [emptyProject, populatedProject],
            workspaces: [workspace]
        )

        XCTAssertEqual(projection.firstWorkspace, workspace)
        XCTAssertEqual(projection.firstWorkspace(in: populatedProject.id), workspace)
    }

    func testProjectionCarriesWorkspaceMergeStateThroughGrouping() {
        let host = WarrenDomain.Host(name: "Merge Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "review",
            path: "/tmp/warren-review",
            branch: "review",
            mergeState: .merged
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace]
        )

        XCTAssertEqual(projection.workspace(id: workspace.id)?.mergeState, .merged)
        XCTAssertEqual(
            projection.groups.first?.workspaces.first?.mergeState,
            .merged
        )
    }

    func testTerminalGroupProjectionKeepsGroupTabsAndNavigationScoped() {
        let host = WarrenDomain.Host(name: "Terminal Host")
        let group = TerminalGroup(hostID: host.id, name: "Inbox", home: "/tmp")
        let sessionID = TerminalSessionID()
        let session = WarrenDesktopSession(
            id: sessionID,
            terminalGroupID: group.id,
            title: "Shell",
            state: .attached,
            activity: .working,
            workingDirectory: "/tmp"
        )
        let tab = ClientTab(
            id: "group-tab",
            title: "Shell",
            sessionID: sessionID
        )
        let projection = WarrenDesktopProjection(
            host: host,
            groups: [],
            sessions: [session],
            tabs: [tab],
            terminalGroups: [group]
        )

        XCTAssertEqual(projection.terminalGroup(id: group.id), group)
        XCTAssertEqual(projection.tabs(in: group.id), [tab])
        XCTAssertEqual(projection.sessions(in: group.id), [session])
        XCTAssertEqual(projection.runningSessionCount(in: group.id), 1)
        XCTAssertEqual(projection.activity(in: group.id), .working)

        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectTerminalGroup(group.id),
            in: projection
        )
        XCTAssertEqual(selected.selection, .terminalGroup(group.id))
        XCTAssertEqual(selected.selectedTabID, tab.id)

        let selectedByTab = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectTab(tab.id),
            in: projection
        )
        XCTAssertEqual(selectedByTab.selection, .terminalGroup(group.id))
    }

    func testNavigationDefaultsToFirstTerminalGroupWithoutWorkspaceTabs() {
        let host = WarrenDomain.Host(name: "Terminal Host")
        let group = TerminalGroup(hostID: host.id, name: "Inbox")
        let projection = WarrenDesktopProjection(
            host: host,
            groups: [],
            terminalGroups: [group]
        )

        XCTAssertEqual(
            WarrenDesktopNavigationReducer.initial(for: projection),
            WarrenDesktopNavigationState(
                selection: .terminalGroup(group.id),
                selectedTabID: nil
            )
        )
    }

    func testTerminalGroupContextKeepsScopeIdentitySeparateFromWorkspace() {
        let group = TerminalGroup(hostID: HostID(), name: "Inbox")
        let context = WarrenDesktopTerminalContext(
            terminalGroup: group,
            tab: ClientTab(id: "group-empty", title: "No open sessions", sessionID: nil)
        )

        XCTAssertNil(context.workspace)
        XCTAssertEqual(context.terminalGroup, group)
        XCTAssertEqual(context.scopeID, group.id.description)
    }

    func testNavigationPersistenceRoundTripsTerminalGroup() {
        let suiteName = "warren-terminal-group-navigation-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let groupID = TerminalGroupID()
        let state = WarrenDesktopNavigationState(
            selection: .terminalGroup(groupID),
            selectedTabID: "group-tab",
            memory: WarrenDesktopNavigationMemory(
                tabByTerminalGroupID: [groupID.description: "group-tab"]
            )
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(from: defaults),
            state
        )
    }

    func testActionsExposeProjectWorkspaceAndTabIntentWithoutSideEffects() {
        var received: [WarrenDesktopAction] = []
        let actions = WarrenDesktopActions(
            send: { received.append($0) }
        )

        let fixture = WarrenDesktopFixture.preview
        let projectID = fixture.groups[0].project.id
        let workspaceID = fixture.groups[0].workspaces[0].id
        let sessionID = fixture.sessions[0].id

        actions(.addProject)
        actions(.importSuperset)
        actions(.requestNewWorkspace(projectID))
        actions(.selectWorkspace(workspaceID))
        actions(.openSession(sessionID))
        actions(.deleteSession(sessionID))
        actions(.moveSession(sessionID, to: .workspace(workspaceID)))
        actions(.requestNewSession(workspaceID))
        actions(.launchSession(workspaceID, .claude))
        actions(.selectTab("tab-main"))
        actions(.restoreNavigation(WarrenDesktopNavigationState(
            selection: .workspace(workspaceID),
            selectedTabID: "tab-main"
        )))
        actions(.closeTab("tab-main"))
        actions(.toggleInspector)
        actions(.toggleSidebar)
        actions(.dismissActivity(sessionID, .working))

        XCTAssertEqual(
            received,
            [
                .addProject,
                .importSuperset,
                .requestNewWorkspace(projectID),
                .selectWorkspace(workspaceID),
                .openSession(sessionID),
                .deleteSession(sessionID),
                .moveSession(sessionID, to: .workspace(workspaceID)),
                .requestNewSession(workspaceID),
                .launchSession(workspaceID, .claude),
                .selectTab("tab-main"),
                .restoreNavigation(WarrenDesktopNavigationState(
                    selection: .workspace(workspaceID),
                    selectedTabID: "tab-main"
                )),
                .closeTab("tab-main"),
                .toggleInspector,
                .toggleSidebar,
                .dismissActivity(sessionID, .working),
            ]
        )
    }

    func testBuiltInPresetsMapToExplicitLaunchRequests() {
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.id), ["shell", "claude", "codex"])
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.map(\.presetBarTitle),
            ["Shell", "Claude", "Codex"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.compactMap(\.presetBarIconName),
            ["preset-shell", "preset-claude", "preset-codex"]
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.request), [.shell, .claude, .codex])
        XCTAssertNil(TerminalSessionLaunchRequest.shell.command)
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.command, "claude")
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.title, "Claude Code")
        XCTAssertEqual(
            TerminalSessionLaunchRequest.codex.command,
            "codex --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI?.id, "claude")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.firstAI?.resolvedRequest(
                shellCommand: "",
                claudeCommand: "claude --model sonnet",
                codexCommand: "codex"
            ).command,
            "claude --model sonnet"
        )
    }

    func testPresetOrderNormalizesPersistedIdentifiers() {
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder("codex,shell,codex,future"),
            ["codex", "shell", "claude"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder(""),
            ["shell", "claude", "codex"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrderRawValue("codex,shell,codex,future"),
            "codex,shell,claude"
        )
    }

    func testPresetOrderControlsPresentation() {
        let order = "shell,codex,claude"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedPinned(by: order).map(\.id),
            ["shell", "codex", "claude"]
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI(orderedBy: order)?.id, "codex")
    }

    func testAutomaticShellPolicyIsOptInForAnEmptyWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let emptyWorkspaceID = fixture.groups[0].workspaces[1].id
        let action = WarrenDesktopAction.openWorkspace(emptyWorkspaceID)

        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: action,
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: false
        ))
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: action,
                in: fixture.projection,
                creatingWorkspaceIDs: [],
                autoOpenShell: true
            ),
            emptyWorkspaceID
        )
    }

    func testAutomaticShellPolicyRejectsPopulatedPendingAndPassiveActions() {
        let fixture = WarrenDesktopFixture.preview
        let populatedWorkspaceID = fixture.groups[0].workspaces[0].id
        let emptyWorkspaceID = fixture.groups[0].workspaces[1].id

        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .openWorkspace(populatedWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: true
        ))
        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .openWorkspace(emptyWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [emptyWorkspaceID],
            autoOpenShell: true
        ))
        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .selectWorkspace(emptyWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: true
        ))
    }

    func testAutomaticAIPolicyIsOptInAndWinsOnDoubleClick() {
        let fixture = WarrenDesktopFixture.preview
        let project = fixture.groups[0].project.id
        let emptyWorkspaceID = fixture.groups[0].workspaces[1].id

        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .selectWorkspace(emptyWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: false,
            autoStartAI: false
        ))
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: .selectWorkspace(emptyWorkspaceID),
                in: fixture.projection,
                creatingWorkspaceIDs: [],
                autoOpenShell: false,
                autoStartAI: true
            ),
            emptyWorkspaceID
        )
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: .selectProject(project),
                in: WarrenDesktopProjection(
                    host: fixture.projection.host,
                    projects: [fixture.groups[0].project],
                    workspaces: [fixture.groups[0].workspaces[1]]
                ),
                creatingWorkspaceIDs: [],
                autoOpenShell: false,
                autoStartAI: true
            ),
            emptyWorkspaceID
        )
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: .openWorkspace(emptyWorkspaceID),
                in: fixture.projection,
                creatingWorkspaceIDs: [],
                autoOpenShell: true,
                autoStartAI: true
            ),
            emptyWorkspaceID
        )
    }

    func testPresetOrderMovesWithinBounds() {
        let order = "shell,claude,codex"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("codex", by: -1, in: order),
            "shell,codex,claude"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("shell", by: -1, in: order),
            order
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("codex", by: 1, in: order),
            order
        )
    }

    func testTabCyclerRequiresMultipleTabsAndWrapsInBothDirections() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertEqual(tabs.count, 2)

        XCTAssertNil(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: [tabs[0]],
            selectedTabID: tabs[0].id
        ))
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: nil
        ), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: tabs[0].id
        ), tabs[1].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: tabs[1].id
        ), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: false,
            in: tabs,
            selectedTabID: tabs[0].id
        ), tabs[1].id)
    }

    func testTabNumberSelectorIsOneBasedAndBoundsChecked() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertEqual(WarrenDesktopTabSelector.tabID(in: tabs, number: 1), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabSelector.tabID(in: tabs, number: 2), tabs[1].id)
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: 0))
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: 3))
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: [], number: 1))
    }

    func testTabTitleUsesDirectoryNameForInteractiveShell() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-1",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "warren",
            path: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: workspace
            ),
            "warren"
        )
    }

    func testTabTitleShowsRunningProcessAlongsideDirectory() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-2",
            title: "Codex",
            sessionID: sessionID,
            kind: .codex
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Codex",
            kind: .codex,
            runtimeProcess: "codex",
            workingDirectory: "/Users/me/Workspace/superset"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "codex — superset"
        )
    }

    func testTabTitleFallsBackWhenNoDirectoryIsKnown() {
        let tab = ClientTab(id: "tab-3", title: "Shell", kind: .shell)

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: nil,
                workspace: nil
            ),
            "Shell"
        )

        let codexTab = ClientTab(id: "tab-codex", title: "Codex", kind: .codex)
        let codexSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Codex",
            kind: .codex,
            runtimeProcess: "",
            workingDirectory: ""
        )
        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: codexTab,
                session: codexSession,
                workspace: nil
            ),
            "Codex"
        )
    }

    func testTabTitlePrefersCustomSessionTitle() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-4",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            customTitle: "My Agent",
            kind: .shell,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "warren",
            path: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: workspace
            ),
            "My Agent"
        )
    }

    func testSessionDisplayTitlePrefersCustomTitle() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            customTitle: "My Agent"
        )
        XCTAssertEqual(session.displayTitle, "My Agent")

        let defaultSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Codex"
        )
        XCTAssertEqual(defaultSession.displayTitle, "Codex")
    }

    func testProjectionKeepsPinnedProjectsWorkspacesAndSessionsFirst() {
        let host = WarrenDomain.Host(name: "Pinned Host")
        let pinnedProject = Project(
            hostID: host.id,
            name: "Pinned",
            rootPath: "/tmp/pinned",
            pinned: true
        )
        let regularProject = Project(hostID: host.id, name: "Regular", rootPath: "/tmp/regular")
        let pinnedWorkspace = Workspace(
            projectID: pinnedProject.id,
            name: "Pinned Worktree",
            path: "/tmp/pinned-worktree",
            pinned: true
        )
        let regularWorkspace = Workspace(
            projectID: pinnedProject.id,
            name: "Regular Worktree",
            path: "/tmp/regular-worktree"
        )
        let pinnedSessionID = TerminalSessionID()
        let regularSessionID = TerminalSessionID()
        let pinnedSession = WarrenDesktopSession(
            id: pinnedSessionID,
            workspaceID: pinnedWorkspace.id,
            title: "Pinned",
            pinned: true
        )
        let regularSession = WarrenDesktopSession(
            id: regularSessionID,
            workspaceID: pinnedWorkspace.id,
            title: "Regular"
        )
        let pinnedTab = ClientTab(
            id: "pinned-tab",
            title: "Pinned",
            sessionID: pinnedSessionID
        )
        let regularTab = ClientTab(
            id: "regular-tab",
            title: "Regular",
            sessionID: regularSessionID
        )

        let projection = WarrenDesktopProjection(
            host: host,
            projects: [regularProject, pinnedProject],
            workspaces: [regularWorkspace, pinnedWorkspace],
            sessions: [regularSession, pinnedSession],
            tabs: [regularTab, pinnedTab],
            sessionWorkspaceIDs: [
                pinnedSessionID: pinnedWorkspace.id,
                regularSessionID: pinnedWorkspace.id,
            ]
        )

        XCTAssertEqual(projection.groups.first?.project.id, pinnedProject.id)
        XCTAssertEqual(projection.groups.first?.workspaces.first?.id, pinnedWorkspace.id)
        XCTAssertEqual(projection.tabs.first?.id, pinnedTab.id)
    }

    func testPresetIconCacheLoadsHitsAndMissesOnlyOnce() {
        var loads: [String] = []
        let expected = NSImage(size: NSSize(width: 12, height: 12))
        let cache = WarrenPresetIconCache { name in
            loads.append(name)
            return name == "known" ? expected : nil
        }

        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertEqual(loads, ["known", "missing"])
    }

    func testSelectionReconcilesEmptyToLoadedProjection() {
        let fixture = WarrenDesktopFixture.preview
        let empty = WarrenDesktopProjection.empty(host: fixture.host)

        let emptyState = WarrenDesktopSelectionReconciler.reconcile(
            selection: nil,
            selectedTabID: nil,
            with: empty
        )
        XCTAssertNil(emptyState.selection)
        XCTAssertNil(emptyState.selectedTabID)

        let loadedState = WarrenDesktopSelectionReconciler.reconcile(
            selection: emptyState.selection,
            selectedTabID: emptyState.selectedTabID,
            with: fixture.projection
        )
        XCTAssertEqual(
            loadedState.selection,
            .workspace(fixture.groups[0].workspaces[0].id)
        )
        XCTAssertEqual(loadedState.selectedTabID, "tab-main")
    }

    func testSelectionReconcilesRemovedProjectWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let firstProjectID = fixture.groups[0].project.id
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let secondWorkspaceID = fixture.groups[1].workspaces[0].id

        let current = WarrenDesktopSelectionReconciler.reconcile(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main",
            with: fixture.projection
        )
        XCTAssertEqual(current.selection, .workspace(firstWorkspaceID))
        XCTAssertEqual(current.selectedTabID, "tab-main")

        let reducedGroups = fixture.projection.groups.filter { $0.project.id != firstProjectID }
        let reducedProjection = WarrenDesktopProjection(
            host: fixture.host,
            groups: reducedGroups,
            sessions: fixture.projection.sessions.filter { $0.tabID != "tab-main" },
            tabs: fixture.projection.tabs.filter { $0.id != "tab-main" },
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs
        )
        let reduced = WarrenDesktopSelectionReconciler.reconcile(
            selection: current.selection,
            selectedTabID: current.selectedTabID,
            with: reducedProjection
        )
        XCTAssertEqual(reduced.selection, .workspace(secondWorkspaceID))
        XCTAssertEqual(reduced.selectedTabID, "tab-review")

        let emptied = WarrenDesktopSelectionReconciler.reconcile(
            selection: reduced.selection,
            selectedTabID: reduced.selectedTabID,
            with: WarrenDesktopProjection.empty(host: fixture.host)
        )
        XCTAssertNil(emptied.selection)
        XCTAssertNil(emptied.selectedTabID)
    }

    func testSelectingWorkspaceNeverLeavesAnotherWorkspaceTabActive() {
        let fixture = WarrenDesktopFixture.preview
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let initial = WarrenDesktopNavigationState(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main"
        )

        let selected = WarrenDesktopNavigationReducer.reduce(
            initial,
            action: .selectWorkspace(workspaceWithoutTabID),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspaceWithoutTabID))
        XCTAssertNil(selected.selectedTabID)
        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reconcile(selected, with: fixture.projection),
            selected
        )
    }

    func testSelectingWorkspaceRestoresItsLastTab() {
        let fixture = WarrenDesktopFixture.preview
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let reviewWorkspaceID = fixture.groups[1].workspaces[0].id
        let alternateTab = ClientTab(
            id: "tab-alt",
            title: "Alternate",
            kind: .shell
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: fixture.tabs + [alternateTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [alternateTab.id: firstWorkspaceID]
        )

        let selectedAlternate = WarrenDesktopNavigationReducer.reduce(
            .init(),
            action: .selectTab(alternateTab.id),
            in: projection
        )
        let selectedReview = WarrenDesktopNavigationReducer.reduce(
            selectedAlternate,
            action: .selectWorkspace(reviewWorkspaceID),
            in: projection
        )
        let restored = WarrenDesktopNavigationReducer.reduce(
            selectedReview,
            action: .selectWorkspace(firstWorkspaceID),
            in: projection
        )

        XCTAssertEqual(selectedReview.selectedTabID, "tab-review")
        XCTAssertEqual(restored.selection, .workspace(firstWorkspaceID))
        XCTAssertEqual(restored.selectedTabID, alternateTab.id)
    }

    func testSelectingProjectRestoresItsLastWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let projectID = fixture.groups[0].project.id
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let secondWorkspaceID = fixture.groups[0].workspaces[1].id
        let featureTab = ClientTab(
            id: "tab-feature",
            title: "Feature",
            kind: .shell
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: fixture.tabs + [featureTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [featureTab.id: secondWorkspaceID]
        )

        let selectedFeature = WarrenDesktopNavigationReducer.reduce(
            .init(selection: .workspace(firstWorkspaceID), selectedTabID: "tab-main"),
            action: .selectTab(featureTab.id),
            in: projection
        )
        let restored = WarrenDesktopNavigationReducer.reduce(
            selectedFeature,
            action: .selectProject(projectID),
            in: projection
        )

        XCTAssertEqual(restored.selection, .workspace(secondWorkspaceID))
        XCTAssertEqual(restored.selectedTabID, featureTab.id)
    }

    func testRestoringSettingsPositionReturnsToThePreviousWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let previous = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[1].workspaces[0].id),
            selectedTabID: "tab-review"
        )
        let current = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[0].workspaces[0].id),
            selectedTabID: "tab-main"
        )

        let restored = WarrenDesktopNavigationReducer.reduce(
            current,
            action: .restoreNavigation(previous),
            in: fixture.projection
        )

        XCTAssertEqual(restored.selection, previous.selection)
        XCTAssertEqual(restored.selectedTabID, previous.selectedTabID)
    }

    func testRestoringSettingsPositionReconcilesADeletedTabWithoutLeavingItsWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let previous = WarrenDesktopNavigationState(
            selection: .workspace(workspaceID),
            selectedTabID: "deleted-tab"
        )

        let restored = WarrenDesktopNavigationReducer.reduce(
            WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            action: .restoreNavigation(previous),
            in: fixture.projection
        )

        XCTAssertEqual(restored.selection, .workspace(workspaceID))
        XCTAssertEqual(restored.selectedTabID, "tab-main")
    }

    func testPendingShellTabBelongsToWorkspaceBeforeSessionExists() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[1].id
        let pendingTab = ClientTab(
            id: "pending-shell-\(workspaceID.description)",
            title: "Starting Shell…",
            kind: .shell
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: fixture.tabs + [pendingTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [pendingTab.id: workspaceID]
        )

        XCTAssertEqual(projection.tabs(in: workspaceID), [pendingTab])
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectWorkspace(workspaceID),
            in: projection
        )
        XCTAssertEqual(selected.selectedTabID, pendingTab.id)
    }

    func testWorkspaceActivityUsesMostActionableSessionState() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let working = fixture.sessions[0]
        let failed = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "failed",
            title: "Failed",
            kind: .codex,
            state: .failed,
            activity: .failed
        )
        let waiting = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "waiting",
            title: "Waiting",
            kind: .claude,
            activity: .waitingForInput
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [working, waiting, failed]
        )

        XCTAssertEqual(projection.activity(in: workspaceID), .failed)
        XCTAssertEqual(projection.workspaceActivities[workspaceID], .failed)
        XCTAssertEqual(
            projection.workspaceActivitySummaries[workspaceID]?.activeTabCount,
            0
        )
        XCTAssertEqual(projection.session(id: failed.id), failed)
    }

    func testWorkspaceActivityCountsOnlyVisibleWorkingTabs() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let visibleWorkingIDs = [TerminalSessionID(), TerminalSessionID()]
        let hiddenWorkingID = TerminalSessionID()
        let waitingID = TerminalSessionID()
        let sessions = [
            WarrenDesktopSession(
                id: visibleWorkingIDs[0],
                workspaceID: workspaceID,
                title: "Working One",
                kind: .codex,
                activity: .working
            ),
            WarrenDesktopSession(
                id: visibleWorkingIDs[1],
                workspaceID: workspaceID,
                title: "Working Two",
                kind: .claude,
                activity: .working
            ),
            WarrenDesktopSession(
                id: hiddenWorkingID,
                workspaceID: workspaceID,
                title: "Hidden Working",
                kind: .codex,
                activity: .working
            ),
            WarrenDesktopSession(
                id: waitingID,
                workspaceID: workspaceID,
                title: "Waiting",
                kind: .claude,
                activity: .waitingForInput
            ),
        ]
        let tabs = [
            ClientTab(
                id: "working-one",
                title: "Working One",
                sessionID: visibleWorkingIDs[0],
                kind: .codex
            ),
            ClientTab(
                id: "working-two",
                title: "Working Two",
                sessionID: visibleWorkingIDs[1],
                kind: .claude
            ),
            ClientTab(
                id: "waiting",
                title: "Waiting",
                sessionID: waitingID,
                kind: .claude
            ),
        ]
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: sessions,
            tabs: tabs
        )

        let summary = projection.workspaceActivitySummaries[workspaceID]
        XCTAssertEqual(summary?.activity, .waitingForInput)
        XCTAssertEqual(summary?.activeTabCount, 2)
    }

    func testProjectionChangesOneSessionActivityWithoutChangingRelationships() {
        let projection = WarrenDesktopFixture.preview.projection
        let session = projection.sessions[0]
        let updated = projection.withSessionActivity(.working, for: session.id)

        XCTAssertEqual(updated.session(id: session.id)?.activity, .working)
        XCTAssertEqual(updated.groups, projection.groups)
        XCTAssertEqual(updated.tabs, projection.tabs)
        XCTAssertEqual(updated.sessionWorkspaceIDs, projection.sessionWorkspaceIDs)
        XCTAssertEqual(updated.tabWorkspaceIDs, projection.tabWorkspaceIDs)
        XCTAssertEqual(
            updated.tabs(in: session.workspaceID),
            projection.tabs(in: session.workspaceID)
        )
        XCTAssertEqual(updated.activity(in: session.workspaceID), .working)
    }

    func testSelectingTabSynchronizesSidebarWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let reviewWorkspaceID = fixture.groups[1].workspaces[0].id
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectTab("tab-review"),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(reviewWorkspaceID))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
    }

    func testClosingSelectedTabStaysInsideWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: .workspace(fixture.groups[0].workspaces[0].id), selectedTabID: "tab-main"),
            action: .closeTab("tab-main"),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(fixture.groups[0].workspaces[0].id))
        XCTAssertNil(selected.selectedTabID)
    }

    func testSelectingProjectResolvesItsDefaultWorkspaceAndLocalTab() {
        let fixture = WarrenDesktopFixture.preview
        let project = fixture.groups[1].project
        let workspace = fixture.groups[1].workspaces[0]

        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectProject(project.id),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspace.id))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
        XCTAssertEqual(fixture.projection.tabs(in: workspace.id).map(\.id), ["tab-review"])
    }

    func testBackgroundTabPublicationDoesNotStealExplicitEmptyWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let state = WarrenDesktopNavigationState(
            selection: .workspace(workspaceWithoutTabID),
            selectedTabID: nil
        )

        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reconcile(state, with: fixture.projection),
            state
        )
    }

    func testNavigationPersistenceRoundTripsWorkspaceAndTab() throws {
        let suiteName = "WarrenDesktopTests.navigation.workspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = WarrenDesktopFixture.preview
        let state = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[0].workspaces[0].id),
            selectedTabID: "tab-main",
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: [
                    fixture.groups[0].project.id.description:
                        fixture.groups[0].workspaces[0].id.description,
                ],
                tabByWorkspaceID: [
                    fixture.groups[0].workspaces[0].id.description: "tab-main",
                ]
            )
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)
        XCTAssertEqual(WarrenDesktopNavigationPersistence.restore(from: defaults), state)
    }

    func testNavigationPersistenceRoundTripsProject() throws {
        let suiteName = "WarrenDesktopTests.navigation.project.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = WarrenDesktopFixture.preview
        let state = WarrenDesktopNavigationState(
            selection: .project(fixture.groups[0].project.id),
            selectedTabID: nil
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)
        XCTAssertEqual(WarrenDesktopNavigationPersistence.restore(from: defaults), state)
    }

    func testNavigationPersistenceRoundTripsTerminalGroupTabOrders() throws {
        let suiteName = "WarrenDesktopTests.navigation.tabOrders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let orders = WarrenDesktopTabOrders(
            workspace: [WorkspaceID().description: ["workspace-tab-b", "workspace-tab-a"]],
            terminalGroup: [TerminalGroupID().description: ["group-tab-b", "group-tab-a"]]
        )

        WarrenDesktopNavigationPersistence.saveTabOrders(orders, to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restoreTabOrders(from: defaults),
            orders
        )
    }

    func testNavigationPersistenceClearsWhenEmpty() throws {
        let suiteName = "WarrenDesktopTests.navigation.empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WarrenDesktopNavigationPersistence.save(
            WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            to: defaults
        )

        XCTAssertNil(WarrenDesktopNavigationPersistence.restore(from: defaults))
    }

    func testNavigationPersistenceRetainsMemoryWithoutForegroundSelection() throws {
        let suiteName = "WarrenDesktopTests.navigation.memory-only.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = WarrenDesktopNavigationState(
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: ["project": "workspace"],
                tabByWorkspaceID: ["workspace": "tab"]
            )
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(from: defaults),
            state
        )
    }

    func testSidebarTreePersistenceIsPerScopeAndRoundTrips() throws {
        let suiteName = "WarrenDesktopTests.sidebarTree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = WarrenDesktopSidebarTreeState(
            expandedProjectIDs: [ProjectID(), ProjectID()],
            projectsCollapsed: true
        )

        WarrenDesktopSidebarTreePersistence.save(state, scope: "local", defaults: defaults)

        XCTAssertEqual(
            WarrenDesktopSidebarTreePersistence.restore(scope: "local", defaults: defaults),
            state
        )
        XCTAssertEqual(
            WarrenDesktopSidebarTreePersistence.restore(scope: "server", defaults: defaults),
            WarrenDesktopSidebarTreeState()
        )
    }

    func testNavigationReducerIgnoresSidebarMoves() {
        let projection = WarrenDesktopFixture.preview.projection
        let initial = WarrenDesktopNavigationReducer.initial(for: projection)
        let projectID = projection.groups[0].project.id

        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reduce(
                initial,
                action: .moveProject(projectID, before: nil),
                in: projection
            ),
            initial
        )
        if let workspace = projection.groups[0].workspaces.first {
            XCTAssertEqual(
                WarrenDesktopNavigationReducer.reduce(
                    initial,
                    action: .moveWorkspace(workspace.id, before: nil),
                    in: projection
                ),
                initial
            )
        }
        if let sessionID = projection.sessions.first?.id {
            XCTAssertEqual(
                WarrenDesktopNavigationReducer.reduce(
                    initial,
                    action: .dismissActivity(sessionID, .working),
                    in: projection
                ),
                initial
            )
            if let workspaceID = projection.groups.first?.workspaces.first?.id {
                XCTAssertEqual(
                    WarrenDesktopNavigationReducer.reduce(
                        initial,
                        action: .moveSession(sessionID, to: .workspace(workspaceID)),
                        in: projection
                    ),
                    initial
                )
            }
        }
    }
}

@MainActor
private final class WarrenDragProbeWindow: NSWindow {
    var didRequestDrag = false
    var didToggleFullScreen = false

    override func performDrag(with event: NSEvent) {
        didRequestDrag = true
    }

    override func toggleFullScreen(_ sender: Any?) {
        didToggleFullScreen = true
    }
}
