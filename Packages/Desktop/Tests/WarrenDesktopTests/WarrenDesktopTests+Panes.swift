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
    /// The plan takes the trailing column, the elapsed time it displaced
    /// becomes an append, and a full context window joins it.
    func testSessionSecondLineFoldsPlanContextAndCounts() {
        let workspaceID = WorkspaceID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            kind: .claude,
            activity: .working,
            currentStep: "Running swift build",
            plan: WarrenDesktopPlanProgress(done: 3, total: 5, currentStep: "Wire the sidebar"),
            context: WarrenDesktopContextUsage(used: 88, size: 100),
            turnCounts: ["Edited 2 files", "Ran 3 commands"],
            turnStartedAt: now.addingTimeInterval(-72)
        )
        let line = WarrenDesktopWorkspaceSessionRow.secondLine(for: session, now: now)
        XCTAssertEqual(line.meta, .plan(done: 3, total: 5), "A plan owns the trailing column")
        XCTAssertEqual(
            line.extras.map(\.text),
            ["88% ctx", "1m", "Edited 2 files"],
            "The context reminder, the elapsed a plan displaced, then the heaviest count"
        )
        XCTAssertTrue(line.extras.first?.isWarning == true)
    }
    /// A folded row keeps one dot per Session that has a state, capped so the
    /// dots still read as individual Sessions, and reserves exactly the room
    /// it draws in. An idle Session draws nothing and holds no room.
    func testLeafDisclosureShowsDotsOnlyWhileFolded() {
        let marks: [WarrenActivityMark?] = [
            .working, .exited, .ready, nil, .failed, .working, .ready, .inputNeeded, .working,
        ]
        let expanded = WarrenDesktopLeafDisclosure(isExpanded: true, marks: marks, toggle: {})
        XCTAssertEqual(expanded.visibleMarks, [])
        XCTAssertEqual(expanded.accessoryWidth, WarrenDesktopLeafDisclosure.chevronWidth)

        let folded = WarrenDesktopLeafDisclosure(isExpanded: false, marks: marks, toggle: {})
        XCTAssertEqual(
            folded.visibleMarks,
            [.working, .ready, .failed, .working, .ready, .inputNeeded],
            "Idle and exited Sessions draw no dot, and the count stops at the cap"
        )
        XCTAssertGreaterThan(folded.accessoryWidth, expanded.accessoryWidth)

        let quiet = WarrenDesktopLeafDisclosure(isExpanded: false, marks: [nil, .exited, nil], toggle: {})
        XCTAssertEqual(quiet.visibleMarks, [])
        XCTAssertGreaterThan(
            quiet.accessoryWidth,
            WarrenDesktopLeafDisclosure.chevronWidth,
            "A folded row of idle Sessions still counts its Sessions"
        )
        XCTAssertFalse(WarrenDesktopTreeFoldDots.drawsAny([nil, .exited]))
        XCTAssertTrue(WarrenDesktopTreeFoldDots.drawsAny([nil, .ready]))
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
    func testTabBarFollowsNewAndSelectedTabsInOverflowMode() {
        // Overflow now starts at the 96pt floor, not at a fixed width, so this
        // needs more Tabs than a 1000pt window can hold at the floor.
        let initialTabs = (0..<12).map { index in
            ClientTab(
                id: "tab-\(index)",
                title: "Session \(index)",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            )
        }
        let state = TabBarTestState(
            tabs: initialTabs,
            selectedTabID: initialTabs[0].id
        )
        let hostingView = NSHostingView(rootView: TabBarTestHarness(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        let initialScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)

        guard let scrollView = initialScrollViews.first else {
            XCTFail("Tab bar scroll view is missing")
            return
        }
        XCTAssertLessThanOrEqual(scrollView.contentView.bounds.minX, 1)

        let newTab = ClientTab(
            id: "tab-new",
            title: "New session",
            sessionID: TerminalSessionID(rawValue: UUID()),
            kind: .shell
        )
        state.tabs.append(newTab)
        state.selectedTabID = newTab.id
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        let updatedScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)

        guard let updatedScrollView = updatedScrollViews.first else {
            XCTFail("Updated tab bar scroll view is missing")
            return
        }
        XCTAssertGreaterThan(
            updatedScrollView.contentView.bounds.minX,
            1,
            "Selecting a new tab must reveal it in the overflow track"
        )

        state.selectedTabID = initialTabs[0].id
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()

        guard let restoredScrollView = descendantViews(of: hostingView, as: NSScrollView.self).first else {
            XCTFail("Restored tab bar scroll view is missing")
            return
        }

        XCTAssertLessThanOrEqual(
            restoredScrollView.contentView.bounds.minX,
            1,
            "Selecting the first tab must return the overflow track to the leading edge"
        )
    }
    func testTabBarEngagesOverflowModeWhenTrailingChromeLeavesNarrowTrack() {
        let tabs = (0..<12).map { index in
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
        XCTAssertTrue(
            WarrenDesktopTabTrack.overflows(
                count: tabs.count,
                tabWidth: WarrenDesktopTabTrack.minimumWidth,
                viewport: 1_000
            ),
            "Twelve Tabs cannot fit a 1000pt track at the floor width"
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
    /// Few Tabs take the ceiling, and the track still settles: the flexible
    /// track means the scroll view's own width no longer equals a fixed
    /// `count * 150`, so this pins the width a Tab gets instead.
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
        XCTAssertFalse(scrollViews.isEmpty, "The track is a scroll view even when it fits")
        XCTAssertEqual(
            WarrenDesktopTabTrack.tabWidth(count: tabs.count, viewport: 1_000),
            WarrenDesktopTabTrack.maximumWidth,
            "Two Tabs take the ceiling rather than stretching past it"
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
    func tabBar(tabs: [ClientTab]) -> some View {
        makeTabBar(tabs: tabs, selectedTabID: tabs.first?.id)
            .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
    }
    func testWindowDragRegionUsesDedicatedAppKitView() {
        let view = WarrenDesktopWindowDragView()

        XCTAssertFalse(view.acceptsFirstResponder)
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
    func testWindowDragRegionDoubleClickNeitherDragsNorEntersFullScreen() {
        let view = WarrenDesktopWindowDragView()
        let window = WarrenDragProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        view.mouseDown(with: Self.mouseDownEvent(clickCount: 2))

        // A double-click follows the system's title-bar preference, which
        // never means Spaces full screen.
        XCTAssertFalse(window.didToggleFullScreen)
        XCTAssertFalse(window.didRequestDrag)
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
    func testEditorSplitHonorsTheRegionFloorBeforeTheTerminal() {
        let wide: CGFloat = 1400
        let usable = wide - WarrenLayoutMetrics.editorSplitDividerWidth

        // A drag that would starve the editor region stops at its floor rather
        // than clipping code-server's Explorer.
        XCTAssertEqual(
            WarrenLayoutMetrics.editorSplitTerminalWidth(
                proposedTerminalWidth: usable,
                availableWidth: wide
            ),
            usable - WarrenLayoutMetrics.editorRegionMinimumWidth
        )
        // A drag toward zero stops at the Terminal's own pane minimum.
        XCTAssertEqual(
            WarrenLayoutMetrics.editorSplitTerminalWidth(
                proposedTerminalWidth: 0,
                availableWidth: wide
            ),
            WarrenLayoutMetrics.paneMinimumWidth
        )
        // Too narrow to seat both: the caller is told, rather than handed a
        // width that silently breaks one side.
        XCTAssertNil(
            WarrenLayoutMetrics.editorSplitTerminalWidth(
                proposedTerminalWidth: 400,
                availableWidth: WarrenLayoutMetrics.editorRegionMinimumWidth
            )
        )
    }
    /// Dragging a preset row onto another is one gesture, so it moves the row
    /// in front of its target rather than stepping through the ones between.
    func testPresetOrderMovesARowInFrontOfItsDropTarget() {
        let order = "shell,claude,codex,opencode,pi,qoder,antigravity,trae,browser"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("browser", before: "shell", in: order),
            "browser,shell,claude,codex,opencode,pi,qoder,antigravity,trae"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("shell", before: "codex", in: order),
            "claude,shell,codex,opencode,pi,qoder,antigravity,trae,browser"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("claude", before: "claude", in: order),
            order,
            "Dropping a row on itself changes nothing"
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
    /// ⌘N addresses Sessions only.
    ///
    /// The editor used to occupy the position after the last Session, which made
    /// the same keystroke mean different things depending on whether a Workspace
    /// had ever opened it. It is a region beside the track now, reached from the
    /// rail instead.
    func testTabNumberSelectorAddressesSessionsOnly() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: tabs.count + 1))
    }
    func testTabTitleSummarizesACustomCommandSession() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-cmdline",
            title: "Custom",
            sessionID: sessionID,
            kind: .custom
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Custom",
            kind: .custom,
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev -- --port 3000",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "npm run dev"
        )
    }
    func testTabTitleTreatsForegroundShellAsPrompt() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-shell-prompt",
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
            runtimeCommandLine: "-zsh",
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
            "zsh"
        )
        XCTAssertEqual(
            WarrenDesktopTabTitle.resolvedCommand(
                kind: .shell,
                process: "zsh",
                commandLine: "-zsh"
            ),
            ""
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
    /// Taking the last pane off screen leaves the workspace selected with no
    /// live pane, and keeps the visit memory so the next split or selection can
    /// still fall back to the tab the user was last in.
    func testClearingTheSelectedTabKeepsScopeAndVisitMemory() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let tab1 = ClientTab(id: "tab-1", title: "Tab 1", kind: .shell)
        let tab2 = ClientTab(id: "tab-2", title: "Tab 2", kind: .shell)
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: [tab1, tab2],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [tab1.id: workspaceID, tab2.id: workspaceID]
        )

        let visited1 = WarrenDesktopNavigationReducer.reduce(.init(), action: .selectTab(tab1.id), in: projection)
        let visited2 = WarrenDesktopNavigationReducer.reduce(visited1, action: .selectTab(tab2.id), in: projection)
        let cleared = WarrenDesktopNavigationReducer.reduce(visited2, action: .clearSelectedTab, in: projection)

        XCTAssertEqual(cleared.selection, .workspace(workspaceID))
        XCTAssertNil(cleared.selectedTabID)
        XCTAssertEqual(cleared.memory, visited2.memory)

        // The Session is untouched, so selecting the workspace again picks the
        // most recently visited tab back up.
        let reselected = WarrenDesktopNavigationReducer.reduce(
            cleared,
            action: .selectWorkspace(workspaceID),
            in: projection
        )
        XCTAssertEqual(reselected.selectedTabID, tab2.id)
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
    /// A single pane gives the bar nothing to switch between, and its chip
    /// repeats a title the pane header carries and the sidebar leaf highlights.
    /// Chips are earned by having a second pane to choose.
    func testPaneBarShowsItsTrackOnlyWhenThereIsAPaneToChoose() {
        XCTAssertFalse(
            WarrenDesktopPaneBar.showsTrack(entryCount: 1, mode: .rich)
        )
        XCTAssertTrue(
            WarrenDesktopPaneBar.showsTrack(entryCount: 2, mode: .rich)
        )
        // The editor no longer earns the track a stop. It is a region beside the
        // whole track, so a lone pane is still a lone pane while it is open.
        XCTAssertFalse(
            WarrenDesktopPaneBar.showsTrack(entryCount: 0, mode: .rich)
        )
        // Compact mode's tree does not list Sessions, so one entry is still the
        // only way back to it.
        XCTAssertTrue(
            WarrenDesktopPaneBar.showsTrack(entryCount: 1, mode: .compact)
        )
    }
    /// The identity slot and the pane track occupy the same row, so exactly one
    /// of them is drawn. Rich mode with one pane is the case that motivated it:
    /// the row is free, and the 28pt pane header below the presets was spending
    /// a third band to say the same thing.
    @MainActor
    func testTopChromeShowsPaneIdentityExactlyWhenThereIsNoTrack() throws {
        let identity = WarrenDesktopSoloPaneIdentity.Model(
            tabID: "tab-1",
            title: "Implement API",
            fullTitle: "Implement API · codex · feature",
            providerPresetID: "codex",
            mark: .working,
            canClose: true
        )
        let recorder = WarrenSemanticRecorder()
        let bar = makeTabBar(tabs: [ClientTab(
            id: "tab-1",
            title: "Implement API",
            sessionID: TerminalSessionID(),
            kind: .codex
        )], selectedTabID: "tab-1", soloPane: identity)
            .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: bar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let nodes = recorder.snapshot().nodes
        XCTAssertTrue(
            nodes.contains { $0.id == "pane.solo" && $0.label.contains("Implement API") }
        )
        XCTAssertFalse(
            nodes.contains { $0.id.hasPrefix("tab.tab-1") },
            "The identity replaces the chip rather than sitting beside it"
        )
        // Closing is still offered, since the bar's own x went away with the
        // chip and the pane header is gone in this state.
        XCTAssertTrue(nodes.contains { $0.id == "pane.solo.close" })
    }
    /// A pane bar entry only ever takes panes off screen. Offering to end a
    /// Session here would contradict "walk out and it keeps running", and would
    /// end it from the one control the user reaches for to tidy the layout.
    func testPaneBarEntryClosesPanesWithoutEndingTheSession() {
        var closedPanes = 0
        var endedSessions = 0
        let titles = WarrenDesktopTabItem.contextMenuActions(
            sessionID: TerminalSessionID(),
            isPinned: false,
            hasActivity: false,
            workspaceMoveTargets: [],
            onMoveSession: { _, _ in endedSessions += 1 },
            onTogglePin: {},
            onDismissActivity: {},
            onRename: {},
            onClose: { closedPanes += 1 },
            onCloseOthers: { closedPanes += 1 },
            onCloseAll: { closedPanes += 1 }
        ).compactMap { action -> String? in
            guard case .button(let title, _, _, let run) = action else { return nil }
            run()
            return title
        }

        XCTAssertEqual(
            titles,
            ["Pin Session", "Rename Session", "Close Pane", "Close Other Panes", "Close All Panes"]
        )
        XCTAssertEqual(closedPanes, 3)
        XCTAssertEqual(endedSessions, 0)
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("End Session") })
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("Close Tab") })
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
                activity: .blocked
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
        XCTAssertEqual(summary?.activity, .blocked)
        XCTAssertEqual(summary?.activeTabCount, 2)
    }
    func testClearingTheSelectedTabStaysInsideWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: .workspace(fixture.groups[0].workspaces[0].id), selectedTabID: "tab-main"),
            action: .clearSelectedTab,
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(fixture.groups[0].workspaces[0].id))
        XCTAssertNil(selected.selectedTabID)
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
}
