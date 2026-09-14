import XCTest
import SwiftUI
import AppKit
import Combine
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain
import WarrenClientCore
import WarrenObservation

private struct TestTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        Text("surface:\(context.tab.id):\(context.workspace?.id.rawValue.uuidString ?? context.terminalGroup?.id.rawValue.uuidString ?? "none")")
    }
}

@MainActor
private final class TabBarTestState: ObservableObject {
    @Published var tabs: [ClientTab]
    @Published var selectedTabID: String?

    init(tabs: [ClientTab], selectedTabID: String?) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }
}

private struct TabBarTestHarness: View {
    @ObservedObject var state: TabBarTestState

    var body: some View {
        makeTabBar(tabs: state.tabs, selectedTabID: state.selectedTabID)
            .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
    }
}

@MainActor
private final class SidebarHostRowsTestState: ObservableObject {
    @Published var hosts: [WarrenDesktopSidebarHostProjection]
    let selection: WarrenDesktopSidebarResourceSelection?
    @Published private(set) var selectedResources: [WarrenDesktopSidebarResourceSelection] = []

    init(
        hosts: [WarrenDesktopSidebarHostProjection],
        selection: WarrenDesktopSidebarResourceSelection?
    ) {
        self.hosts = hosts
        self.selection = selection
    }

    func recordSelection(_ selection: WarrenDesktopSidebarResourceSelection) {
        selectedResources.append(selection)
    }
}

private struct SidebarHostRowsTestHarness: View {
    @ObservedObject var state: SidebarHostRowsTestState
    let activeEndpointID: String
    var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact
    var selectedTabID: String? = nil

    var body: some View {
        WarrenDesktopSidebarHostRows(
            hosts: state.hosts,
            showsActiveOnly: false,
            workspaceDisplayMode: workspaceDisplayMode,
            isCollapsed: false,
            selection: state.selection,
            activeEndpointID: activeEndpointID,
            selectedTabID: selectedTabID,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in },
            onSelect: { state.recordSelection($0) },
            onOpenWorkspace: { _ in },
            onFocusTask: { _ in },
            onToggleActiveOnly: {},
            onRetry: { _ in }
        )
    }
}

@MainActor
private func makeTabBar(
    tabs: [ClientTab],
    selectedTabID: String?,
    soloPane: WarrenDesktopSoloPaneIdentity.Model? = nil
) -> WarrenDesktopTabBar {
    WarrenDesktopTabBar(
        presentation: WarrenDesktopPaneBarPresentation(
            listings: tabs,
            showsTrack: soloPane == nil,
            solo: soloPane
        ),
        tabTitles: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) }),
        tabActivities: [:],
        pinnedSessionIDs: [],
        selectedTabID: selectedTabID,
        chromeMode: .workspace,
        isSidebarCollapsed: false,
        connectionState: .attached,
        endpointOptions: [WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true)],
        selectedEndpointID: "local",
        webStatus: WarrenDesktopWebStatus(),
        externalIDEOptions: nil,
        embeddedEditorAvailable: false,
        embeddedEditorTabVisible: false,
        embeddedEditorSelected: false,
        embeddedEditorDefault: false,
        onToggleSidebar: {},
        onSettings: {},
        onChromePopover: { _ in },
        onOpenInExternalIDE: { _ in },
        onOpenEmbeddedEditor: {},
        onCloseEmbeddedEditor: {},
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
}

@MainActor
final class WarrenDesktopTests: XCTestCase {
    func testPublicAccessUsesOwnerReachabilityTerminology() {
        XCTAssertEqual(WarrenPublicAccessCopy.title, "Public Access")
        XCTAssertEqual(WarrenPublicAccessCopy.relayURL, "Relay URL")
        XCTAssertEqual(WarrenPublicAccessCopy.publicHostname, "Public hostname")
        XCTAssertEqual(WarrenPublicAccessCopy.pathPrefix, "Path prefix")
        XCTAssertEqual(WarrenPublicAccessCopy.publicEndpoint, "Public Endpoint")
        XCTAssertEqual(WarrenPublicAccessCopy.resetLocalSetup, "Reset local route")
        XCTAssertFalse(WarrenPublicAccessCopy.title.localizedCaseInsensitiveContains("sharing"))
    }

    func testWorkspaceChromeIsDefaultAndDoesNotShowIndependentTopBar() {
        XCTAssertFalse(WarrenDesktopChromeMode.workspace.showsIndependentTopBar)
        XCTAssertTrue(WarrenDesktopChromeMode.dashboard.showsIndependentTopBar)

    }

    /// The toggle names its effect on the tree. A speech bubble claimed every
    /// leaf is a conversation, which a plain shell is not.
    func testWorkspaceDisplayModeDescribesItsEffectOnTheTree() {
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode(rawValue: "rich"),
            .rich
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode.compact.toggleLabel,
            "Show Sessions in the navigation tree"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode.rich.toggleHint,
            "List each workspace without its running Sessions"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode.rich.systemImage,
            "list.bullet.indent"
        )
        XCTAssertNotEqual(
            WarrenDesktopWorkspaceDisplayMode.rich.systemImage,
            WarrenDesktopWorkspaceDisplayMode.compact.systemImage
        )
    }

    /// Rich mode is denser, so it needs more separation between project
    /// subtrees, not less.
    func testRichModeSeparatesProjectSubtreesMoreThanCompact() {
        XCTAssertGreaterThan(
            WarrenDesktopWorkspaceDisplayMode.rich.projectGroupSpacing,
            WarrenDesktopWorkspaceDisplayMode.compact.projectGroupSpacing
        )
        XCTAssertGreaterThan(
            WarrenDesktopWorkspaceDisplayMode.compact.projectGroupSpacing,
            WarrenSpacing.xxs
        )
    }

    /// Indent is width taken from row titles, so a tier only spends a step when
    /// nothing cheaper separates it. Only the Session leaf does: everything
    /// above it is told apart by weight, brightness, or glyph.
    func testOnlyTheSessionLeafSpendsAnIndentStep() {
        let step = WarrenLayoutMetrics.sidebarIndentStep
        let rowInset = WarrenSpacing.compact

        XCTAssertEqual(WarrenDesktopSidebarIndent.host, WarrenDesktopSidebarIndent.section)
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.project + rowInset,
            WarrenDesktopSidebarIndent.section
        )
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.workspace,
            WarrenDesktopSidebarIndent.project,
            "A workspace says it is inside a project by weight, not position"
        )
        XCTAssertEqual(WarrenDesktopSidebarIndent.task, WarrenDesktopSidebarIndent.project)
        XCTAssertEqual(WarrenDesktopSidebarIndent.terminalGroup, WarrenDesktopSidebarIndent.project)
        // The leaf spends one step so it reads as nested, plus the small gap
        // that keeps its icon clear of the rail drawn from the parent glyph.
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.session - WarrenDesktopSidebarIndent.workspace,
            step + WarrenDesktopSidebarIndent.sessionGuideGap
        )
        // That gap moves the icon, not the title: the glyph-to-title spacing
        // gives back exactly what the indent adds, so the readable column keeps
        // the width it had before the rail was separated from the leaf.
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.session
                + WarrenLayoutMetrics.sidebarLeafIconSlotSize
                + (WarrenSpacing.compact - WarrenDesktopSidebarIndent.sessionGuideGap),
            WarrenLayoutMetrics.sidebarLeadingInset(depth: 1)
                + WarrenLayoutMetrics.sidebarLeafIconSlotSize
        )

        // The whole tree now fits in the width one workspace row used to need,
        // which is what the collapse was for.
        XCTAssertLessThanOrEqual(
            WarrenDesktopSidebarIndent.session,
            WarrenLayoutMetrics.sidebarLeadingInset(depth: 1)
        )

        // The rail descends through the gutter every row starts from, so its
        // center is the depth-0 content leading edge: the same edge section
        // labels, Host titles, and the project and workspace glyph slots use.
        // Anchoring it on the parent glyph's center instead left only three
        // points of branch, which read as a stub against the leaf icon.
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.sessionGuide,
            WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)
        )
        // The gutter is what makes the elbow a real branch: the rail sits a
        // full indent step left of the leaf content it connects to.
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.session + WarrenSpacing.compact
                - WarrenDesktopSidebarIndent.sessionGuide,
            WarrenLayoutMetrics.sidebarIndentStep + WarrenSpacing.xxs
        )
    }

    /// The weight is what replaced the indent, so a container row and the rows
    /// inside it must not resolve to the same font.
    func testContainerRowsCarryHeavierWeightThanWhatTheyContain() {
        XCTAssertEqual(WarrenTypography.sidebarContainerRow, WarrenTypography.navigationGroup)
        XCTAssertNotEqual(WarrenTypography.sidebarContainerRow, WarrenTypography.workspaceRow)
        XCTAssertEqual(WarrenTypography.workspaceRow, WarrenTypography.navigationItem)
    }

    func testWorkspaceTabTrailingControlsHaveStableOrder() {
        XCTAssertEqual(
            WarrenDesktopWorkspaceTabTrailingControl.allCases,
            [.externalIDE, .endpoint, .web, .settings]
        )
    }

    func testWorkspaceTabTrailingLayoutKeepsSignalChromeAndOverflow() {
        let layout = WarrenDesktopWorkspaceTabTrailingControl.layout(
            externallyVisibleControls: WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
            availableControls: WarrenDesktopWorkspaceTabTrailingControl.allCases
        )

        XCTAssertEqual(layout.direct, [.externalIDE, .web, .settings])
        XCTAssertEqual(layout.overflow, [.endpoint])
    }

    func testWorkspaceTabTrailingExposesEndpointForMultipleServers() {
        let controls = WarrenDesktopWorkspaceTabTrailingControl.controlsForEndpointCount(
            WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
            endpointCount: 2
        )
        let layout = WarrenDesktopWorkspaceTabTrailingControl.layout(
            externallyVisibleControls: controls,
            availableControls: WarrenDesktopWorkspaceTabTrailingControl.allCases
        )

        XCTAssertEqual(controls, [.externalIDE, .endpoint, .web, .settings])
        XCTAssertEqual(layout.direct, controls)
        XCTAssertEqual(layout.overflow, [])
    }

    func testWorkspaceTabTrailingKeepsEndpointInOverflowForSingleServer() {
        XCTAssertEqual(
            WarrenDesktopWorkspaceTabTrailingControl.controlsForEndpointCount(
                WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
                endpointCount: 1
            ),
            WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls
        )
    }

    func testEndpointAppearanceAssignsDifferentPaletteEntries() {
        let endpoints = [
            WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true),
            WarrenDesktopEndpointOption(id: "vps", label: "VPS"),
        ]

        let localColor = WarrenDesktopEndpointAppearance.color(
            for: "local",
            in: endpoints,
            tokens: WarrenColorTokens.dark
        )
        let remoteColor = WarrenDesktopEndpointAppearance.color(
            for: "vps",
            in: endpoints,
            tokens: WarrenColorTokens.dark
        )

        XCTAssertNotEqual(localColor, remoteColor)
    }

    func testHostResourceReferencesKeepEndpointScopeInIdentityAndNavigation() {
        let projectID = ProjectID()
        let local = WarrenDesktopHostResourceRef(endpointID: "local", id: projectID)
        let remote = WarrenDesktopHostResourceRef(endpointID: "prod", id: projectID)

        XCTAssertNotEqual(local, remote)
        XCTAssertNotEqual(local.navigationKey, remote.navigationKey)
        XCTAssertEqual(local.navigationKey, "local:\(projectID.description)")
        XCTAssertEqual(remote.navigationKey, "prod:\(projectID.description)")
    }

    @MainActor
    func testMultiHostSidebarScopesSelectionAndExpansionWhenIDsCollide() throws {
        let sharedProjectID = ProjectID()
        let sharedWorkspaceID = WorkspaceID()
        let localHost = Host(name: "Local Mac")
        let remoteHost = Host(name: "Build VPS")
        let localProject = Project(
            id: sharedProjectID,
            hostID: localHost.id,
            name: "Local Project",
            rootPath: "/tmp/local"
        )
        let remoteProject = Project(
            id: sharedProjectID,
            hostID: remoteHost.id,
            name: "Remote Project",
            rootPath: "/tmp/remote"
        )
        let localWorkspace = Workspace(
            id: sharedWorkspaceID,
            projectID: sharedProjectID,
            name: "Local Workspace",
            path: "/tmp/local"
        )
        let remoteWorkspace = Workspace(
            id: sharedWorkspaceID,
            projectID: sharedProjectID,
            name: "Remote Workspace",
            path: "/tmp/remote"
        )
        let localGroup = WarrenDesktopProjectGroup(
            project: localProject,
            workspaces: [localWorkspace]
        )
        let remoteGroup = WarrenDesktopProjectGroup(
            project: remoteProject,
            workspaces: [remoteWorkspace]
        )
        let scopedSelection = WarrenDesktopSidebarResourceSelection.project(
            WarrenDesktopHostResourceRef(endpointID: "local", id: sharedProjectID)
        )
        let recorder = WarrenSemanticRecorder()
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopProjection(
                host: remoteHost,
                groups: [remoteGroup],
                connectionState: .attached
            ),
            navigation: WarrenDesktopNavigationState(selection: .project(sharedProjectID)),
            endpointOptions: [
                .init(id: "local", label: "Local", isLocal: true),
                .init(id: "remote", label: "Remote"),
            ],
            selectedEndpointID: "remote",
            sidebarHostProjections: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: localHost,
                    connectionState: .attached,
                    projectGroups: [localGroup]
                ),
                WarrenDesktopSidebarHostProjection(
                    endpointID: "remote",
                    endpointLabel: "Remote",
                    host: remoteHost,
                    connectionState: .attached,
                    projectGroups: [remoteGroup]
                ),
            ],
            usesSidebarHostSections: true,
            sidebarResourceSelection: scopedSelection,
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let localID = "project.host.local.\(sharedProjectID.description)"
        let remoteID = "project.host.remote.\(sharedProjectID.description)"
        let localWorkspaceID = "workspace.host.local.\(sharedWorkspaceID.description)"
        let remoteWorkspaceID = "workspace.host.remote.\(sharedWorkspaceID.description)"
        let initialSnapshot = recorder.snapshot()
        XCTAssertEqual(initialSnapshot.node(id: "sidebar.projects.hosts")?.value, "2 hosts")
        guard let projectsHeader = initialSnapshot.node(id: "sidebar.projects.hosts"),
              let localHostHeader = initialSnapshot.node(id: "host.local.toggle") else {
            XCTFail("Multi-host sidebar must expose its Projects and Host headers")
            return
        }
        XCTAssertEqual(
            localHostHeader.frame.height,
            Double(WarrenLayoutMetrics.sidebarHostHeaderHeight),
            accuracy: 0.01
        )
        XCTAssertEqual(
            localHostHeader.frame.y,
            projectsHeader.frame.y + projectsHeader.frame.height + Double(WarrenSpacing.xxs),
            accuracy: 0.01
        )
        XCTAssertTrue(initialSnapshot.node(id: localID)?.value?.contains("Expanded") == true)
        XCTAssertTrue(initialSnapshot.node(id: remoteID)?.value?.contains("Collapsed") == true)
        XCTAssertNotNil(initialSnapshot.node(id: localWorkspaceID))
        XCTAssertNil(initialSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "\(remoteID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        let expandedSnapshot = recorder.snapshot()
        XCTAssertNotNil(expandedSnapshot.node(id: localWorkspaceID))
        XCTAssertNotNil(expandedSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "\(localID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        let collapsedSnapshot = recorder.snapshot()
        XCTAssertNil(collapsedSnapshot.node(id: localWorkspaceID))
        XCTAssertNotNil(collapsedSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "host.local.toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(recorder.snapshot().node(id: "host.local.toggle")?.value, "Collapsed")
    }

    @MainActor
    func testMultiHostProjectPrimaryActionOnlyTogglesDisclosure() throws {
        let localHost = Host(name: "Local Mac")
        let remoteHost = Host(name: "Build VPS")
        let project = Project(
            hostID: localHost.id,
            name: "Project",
            rootPath: "/tmp/project"
        )
        let workspace = Workspace(
            projectID: project.id,
            name: "Workspace",
            path: "/tmp/project"
        )
        let group = WarrenDesktopProjectGroup(project: project, workspaces: [workspace])
        let state = SidebarHostRowsTestState(
            hosts: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: localHost,
                    connectionState: .attached,
                    projectGroups: [group]
                ),
                WarrenDesktopSidebarHostProjection(
                    endpointID: "remote",
                    endpointLabel: "Remote",
                    host: remoteHost,
                    connectionState: .attached
                ),
            ],
            selection: nil
        )
        let recorder = WarrenSemanticRecorder()
        let root = SidebarHostRowsTestHarness(
            state: state,
            activeEndpointID: "local"
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let projectID = "project.host.local.\(project.id.description)"
        let workspaceID = "workspace.host.local.\(workspace.id.description)"
        XCTAssertNil(recorder.snapshot().node(id: workspaceID))

        try recorder.perform(.press, on: projectID)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertTrue(state.selectedResources.isEmpty)
        XCTAssertTrue(snapshot.node(id: projectID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(snapshot.node(id: workspaceID))
    }

    @MainActor
    func testMultiHostSidebarRevealsTheScopedSelectionWhenItsRosterArrives() {
        let sharedProjectID = ProjectID()
        let sharedWorkspaceID = WorkspaceID()
        let localHost = Host(name: "Local Mac")
        let remoteHost = Host(name: "Build VPS")
        let localProject = Project(
            id: sharedProjectID,
            hostID: localHost.id,
            name: "Local Project",
            rootPath: "/tmp/local"
        )
        let remoteProject = Project(
            id: sharedProjectID,
            hostID: remoteHost.id,
            name: "Remote Project",
            rootPath: "/tmp/remote"
        )
        let localGroup = WarrenDesktopProjectGroup(
            project: localProject,
            workspaces: [
                Workspace(
                    id: sharedWorkspaceID,
                    projectID: sharedProjectID,
                    name: "Local Workspace",
                    path: "/tmp/local"
                ),
            ]
        )
        let remoteGroup = WarrenDesktopProjectGroup(
            project: remoteProject,
            workspaces: [
                Workspace(
                    id: sharedWorkspaceID,
                    projectID: sharedProjectID,
                    name: "Remote Workspace",
                    path: "/tmp/remote"
                ),
            ]
        )
        let localEmpty = WarrenDesktopSidebarHostProjection(
            endpointID: "local",
            endpointLabel: "Local",
            host: localHost,
            connectionState: .attached
        )
        let remoteProjection = WarrenDesktopSidebarHostProjection(
            endpointID: "remote",
            endpointLabel: "Remote",
            host: remoteHost,
            connectionState: .attached,
            projectGroups: [remoteGroup]
        )
        let state = SidebarHostRowsTestState(
            hosts: [localEmpty, remoteProjection],
            selection: .project(
                WarrenDesktopHostResourceRef(
                    endpointID: "local",
                    id: sharedProjectID
                )
            )
        )
        let recorder = WarrenSemanticRecorder()
        let root = SidebarHostRowsTestHarness(
            state: state,
            activeEndpointID: "local"
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let localWorkspaceID = "workspace.host.local.\(sharedWorkspaceID.description)"
        let remoteWorkspaceID = "workspace.host.remote.\(sharedWorkspaceID.description)"
        let localProjectID = "project.host.local.\(sharedProjectID.description)"
        let initialSnapshot = recorder.snapshot()
        guard let localEmptyAction = initialSnapshot.node(
            id: "sidebar.empty.host.local.add-project"
        ), let localHostHeader = initialSnapshot.node(id: "host.local.toggle") else {
            XCTFail("Multi-host empty Host must expose its header and add-project action")
            return
        }
        XCTAssertEqual(
            localEmptyAction.frame.x - localHostHeader.frame.x,
            Double(WarrenDesktopSidebarIndent.hostEmptyState - WarrenDesktopSidebarIndent.host),
            accuracy: 0.01
        )
        XCTAssertNil(initialSnapshot.node(id: localWorkspaceID))
        XCTAssertNil(recorder.snapshot().node(id: remoteWorkspaceID))

        state.hosts = [
            WarrenDesktopSidebarHostProjection(
                endpointID: "local",
                endpointLabel: "Local",
                host: localHost,
                connectionState: .attached,
                projectGroups: [localGroup]
            ),
            remoteProjection,
        ]
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.node(id: localProjectID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(snapshot.node(id: localWorkspaceID))
        XCTAssertNil(snapshot.node(id: remoteWorkspaceID))
    }

    @MainActor
    func testSingleSidebarHostUsesLegacyProjectPresentation() throws {
        let host = Host(name: "Local Mac")
        let project = Project(
            hostID: host.id,
            name: "Project",
            rootPath: "/tmp/project"
        )
        let workspace = Workspace(
            projectID: project.id,
            name: "Workspace",
            path: "/tmp/project"
        )
        let group = WarrenDesktopProjectGroup(
            project: project,
            workspaces: [workspace]
        )
        let recorder = WarrenSemanticRecorder()
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopProjection(
                host: host,
                groups: [group],
                connectionState: .attached
            ),
            navigation: WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            endpointOptions: [
                .init(id: "local", label: "Local", isLocal: true),
            ],
            selectedEndpointID: "local",
            sidebarHostProjections: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: host,
                    connectionState: .attached,
                    projectGroups: [group]
                ),
            ],
            usesSidebarHostSections: true,
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let projectID = "project.host.local.\(project.id.description)"
        let workspaceID = "workspace.host.local.\(workspace.id.description)"
        let initialSnapshot = recorder.snapshot()
        XCTAssertNil(initialSnapshot.node(id: "sidebar.projects.hosts"))
        XCTAssertNil(initialSnapshot.node(id: "host.local.toggle"))
        XCTAssertTrue(initialSnapshot.node(id: projectID)?.value?.contains("Collapsed") == true)
        XCTAssertNil(initialSnapshot.node(id: workspaceID))

        try recorder.perform(.press, on: "\(projectID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertNotNil(recorder.snapshot().node(id: workspaceID))
    }

    func testMultiHostProjectsHeaderShowsTheCountOnHover() {
        XCTAssertEqual(
            WarrenDesktopSidebarHostsSectionPresentation.title(
                hostCount: 2,
                isHovered: false
            ),
            "PROJECTS · HOSTS"
        )
        XCTAssertEqual(
            WarrenDesktopSidebarHostsSectionPresentation.title(
                hostCount: 2,
                isHovered: true
            ),
            "PROJECTS · 2"
        )
    }

    func testHostTintAssignmentIsStableAcrossOrderAndResolvesCollisions() {
        let aliases = (0..<64).map { "host-\($0)" }
        let paletteCount = WarrenColorTokens.dark.hostSectionTints.count
        let first = WarrenDesktopHostTint.indices(for: aliases, count: paletteCount)
        let reordered = WarrenDesktopHostTint.indices(
            for: aliases.reversed(),
            count: paletteCount
        )

        XCTAssertEqual(first, reordered)
        var pair: (String, String)?
        for left in aliases {
            for right in aliases where left < right {
                guard WarrenDesktopHostTint.index(for: left, count: paletteCount)
                        == WarrenDesktopHostTint.index(for: right, count: paletteCount) else {
                    continue
                }
                pair = (left, right)
                break
            }
            if pair != nil { break }
        }
        guard let pair else {
            XCTFail("test aliases did not produce a palette collision")
            return
        }
        let collisionAssignments = WarrenDesktopHostTint.indices(
            for: [pair.0, pair.1],
            count: paletteCount
        )
        XCTAssertNotEqual(collisionAssignments[pair.0], collisionAssignments[pair.1])
    }

    func testEndpointOptionsDefaultCapabilitiesFollowEndpointOwnership() {
        let local = WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true)
        let remote = WarrenDesktopEndpointOption(id: "vps", label: "VPS")

        XCTAssertEqual(local.capabilities, .local)
        XCTAssertEqual(remote.capabilities, .remote)
    }

    func testEndpointCapabilitiesCanBeCustomizedForHostProvidedIntegrations() {
        let hostEditor = WarrenDesktopEndpointCapabilities(
            canAddProject: false,
            canImportSuperset: false,
            canUseEmbeddedEditor: true,
            canOpenExternalIDE: true,
            canCopyLocalWebURL: false
        )
        let endpoint = WarrenDesktopEndpointOption(
            id: "vps",
            label: "VPS",
            capabilities: hostEditor
        )

        XCTAssertEqual(endpoint.capabilities, hostEditor)
        XCTAssertTrue(endpoint.capabilities.canUseEmbeddedEditor)
        XCTAssertTrue(endpoint.capabilities.canOpenExternalIDE)
        XCTAssertFalse(endpoint.capabilities.canAddProject)
    }

    func testEmbeddedEditorKeepsIDEControlAvailableWithoutExternalApplications() {
        XCTAssertTrue(
            WarrenDesktopWorkspaceTabTrailingControl.available(
                externalIDEOptions: nil,
                embeddedEditorAvailable: true
            ).contains(.externalIDE)
        )
    }

    func testWorkspaceTabTrailingExternalControlsAreDeduplicatedAndCapped() {
        let requested = Array(repeating: WarrenDesktopWorkspaceTabTrailingControl.settings, count: 8)
            + WarrenDesktopWorkspaceTabTrailingControl.allCases

        let normalized = WarrenDesktopWorkspaceTabTrailingControl.normalizedExternalControls(requested)

        XCTAssertEqual(normalized, [.settings, .externalIDE, .endpoint, .web])
        XCTAssertLessThanOrEqual(
            normalized.count,
            WarrenDesktopWorkspaceTabTrailingControl.maximumExternalButtonCount
        )
    }

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

    func testExternalIDEOptionsCacheInvalidatesWhenWorkspaceDirectoryChanges() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var directoryExists = true
        var resolveCount = 0
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in
                resolveCount += 1
                return applicationURL
            },
            directoryExists: { _ in directoryExists },
            launch: { _, _ in }
        )

        let availableOptions = service.options(for: workspace, isLocalEndpoint: true)
        directoryExists = false
        let unavailableOptions = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertTrue(availableOptions.allSatisfy(\.isEnabled))
        XCTAssertTrue(unavailableOptions.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(resolveCount, WarrenDesktopExternalIDE.supported.count * 2)
    }

    func testExternalIDEOptionsCacheInvalidatesWhenCustomIDEsChange() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        var customIDEs: [WarrenDesktopCustomIDE] = []
        let custom = WarrenDesktopCustomIDE(
            name: "Custom IDE",
            path: "/Applications/Custom IDE.app"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in nil },
            directoryExists: { _ in true },
            loadCustomIDEs: { customIDEs },
            launch: { _, _ in }
        )

        XCTAssertTrue(service.options(for: workspace, isLocalEndpoint: true).isEmpty)
        customIDEs = [custom]
        let options = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(options.map(\.id), ["custom:\(custom.id.uuidString)"])
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

    func testRemoteEndpointHidesLocalOnboardingAndEditorControls() {
        let projection = WarrenDesktopProjection(
            host: Host(name: "Remote"),
            groups: [],
            connectionState: .attached
        )
        let recorder = WarrenSemanticRecorder()
        let root = WarrenDesktopRoot(
            projection: projection,
            endpointOptions: [
                WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true),
                WarrenDesktopEndpointOption(id: "remote", label: "Remote"),
            ],
            selectedEndpointID: "remote",
            embeddedEditorAvailable: true,
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let nodeIDs = Set(recorder.snapshot().nodes.map(\.id))
        XCTAssertFalse(nodeIDs.contains("onboarding.add-project"))
        XCTAssertFalse(nodeIDs.contains("onboarding.import-superset"))
        XCTAssertFalse(nodeIDs.contains("workspace-ide.open"))
    }

    func testEmbeddedEditorUsesAClosableLocalTabAndStaysMountedBehindSessions() throws {
        let defaults = UserDefaults.standard
        let previousDefault = defaults.object(
            forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE
        )
        defaults.set(false, forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE)
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(
            recorder.snapshot().nodes.first { $0.id == "tab.workspace-editor" }
        )
        try recorder.perform(.press, on: "workspace-ide.open")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(
            recorder.snapshot().nodes.first {
                $0.id == "workspace-editor.install"
            }
        )
        try recorder.perform(.press, on: "workspace-editor.open")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertEqual(
            snapshot.nodes.first { $0.id == "tab.workspace-editor" }?.value,
            "Selected"
        )
        XCTAssertEqual(
            snapshot.nodes.first { $0.id == "tab.tab-main" }?.value,
            "Not selected"
        )
        XCTAssertNotNil(snapshot.nodes.first { $0.id == "embedded-editor.surface" })
        XCTAssertTrue(received.isEmpty)

        try recorder.perform(.press, on: "tab.tab-main")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let restoredSnapshot = recorder.snapshot()
        XCTAssertEqual(
            restoredSnapshot.nodes.first { $0.id == "tab.tab-main" }?.value,
            "Selected"
        )
        XCTAssertEqual(received, [.selectTab("tab-main")])
        XCTAssertNotNil(
            restoredSnapshot.nodes.first { $0.id == "embedded-editor.surface" }
        )

        NotificationCenter.default.post(
            name: WarrenDesktopCommand.selectTab,
            object: nil,
            userInfo: [WarrenDesktopCommand.selectTabIndexKey: 2]
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            recorder.snapshot().nodes.first { $0.id == "tab.workspace-editor" }?.value,
            "Selected"
        )
        XCTAssertEqual(received, [.selectTab("tab-main")])

        NotificationCenter.default.post(
            name: WarrenDesktopCommand.nextTab,
            object: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(
            recorder.snapshot().nodes.first { $0.id == "embedded-editor.surface" }
        )
        XCTAssertEqual(received, [.selectTab("tab-main"), .selectTab("tab-main")])

        try recorder.perform(.press, on: "tab.workspace-editor")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try recorder.perform(.press, on: "tab.workspace-editor.close")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let closedSnapshot = recorder.snapshot()
        XCTAssertNil(closedSnapshot.nodes.first { $0.id == "tab.workspace-editor" })
        XCTAssertNil(closedSnapshot.nodes.first { $0.id == "embedded-editor.surface" })
        XCTAssertEqual(received, [.selectTab("tab-main"), .selectTab("tab-main")])
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
        let initialTabs = (0..<6).map { index in
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
        makeTabBar(tabs: tabs, selectedTabID: tabs.first?.id)
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

    func testConnectionPresentationNamesRuntimeMigration() {
        let migrating = WarrenDesktopConnectionPresentation(
            .connecting,
            migratingRuntimeSessions: true
        )

        XCTAssertEqual(migrating.label, "Migrating runtime sessions…")
        XCTAssertEqual(migrating.tone, .info)
        XCTAssertTrue(migrating.isActive)
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

    /// The width policy and `setWidth` both existed from the start, but nothing
    /// ever called them: the rail was pinned at 280pt with the collapse button
    /// as the only escape. The handle is what connects them, so it has to be in
    /// the tree and it has to drive a real resize.
    @MainActor
    func testSidebarResizeHandleDrivesTheWidthPolicy() throws {
        var state = WarrenDesktopSidebarState()
        var resets = 0
        let recorder = WarrenSemanticRecorder()
        let handle = WarrenDesktopSidebarResizeHandle(
            width: state.renderedWidth,
            onResize: { state.setWidth($0) },
            onReset: { resets += 1 }
        )
        .frame(height: 400)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: handle)
        hostingView.frame = NSRect(x: 0, y: 0, width: 20, height: 400)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let node = recorder.snapshot().nodes.first { $0.id == "sidebar.resize" }
        XCTAssertNotNil(node, "The rail's only resize affordance must be reachable")
        XCTAssertEqual(node?.value, "280 points")

        // The handle only ever forwards a proposal; the policy owns clamping and
        // the collapse snap, so a drag past either end cannot strand the rail.
        state.setWidth(state.renderedWidth + 200)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarMaximumWidth)
        state.setWidth(WarrenLayoutMetrics.sidebarSnapThreshold - 1)
        XCTAssertTrue(state.isCollapsed)

        try recorder.perform(.press, on: "sidebar.resize")
        XCTAssertEqual(resets, 1, "Double-click is the way out of a drag gone wrong")

        // The strip has to be wide enough to catch a pointer without eating the
        // click target of the rows beside it.
        XCTAssertGreaterThan(WarrenDesktopSidebarResizeHandle.hitWidth, WarrenSpacing.hairline)
        XCTAssertLessThanOrEqual(WarrenDesktopSidebarResizeHandle.hitWidth, WarrenSpacing.compact)
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

    func testProjectionAggregatesTaskWorkspacesAcrossProjects() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let firstProject = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let secondProject = Project(hostID: host.id, name: "Web", rootPath: "/tmp/web")
        let firstWorkspace = Workspace(
            projectID: firstProject.id,
            taskID: task.id,
            name: "delivery-api",
            path: "/tmp/api-delivery"
        )
        let secondWorkspace = Workspace(
            projectID: secondProject.id,
            taskID: task.id,
            name: "delivery-web",
            path: "/tmp/web-delivery"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: firstWorkspace.id,
            title: "API"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [firstProject, secondProject],
            workspaces: [firstWorkspace, secondWorkspace],
            sessions: [session]
        )

        XCTAssertEqual(projection.taskGroups.map(\.task), [task])
        XCTAssertEqual(
            projection.taskGroups.first?.workspaces.map(\.id),
            [firstWorkspace.id, secondWorkspace.id]
        )
        XCTAssertEqual(projection.groups.map(\.project.id), [firstProject.id, secondProject.id])
        XCTAssertEqual(
            projection.withSessionActivity(.working, for: session.id).taskGroups,
            projection.taskGroups
        )
    }

    func testTaskDeletionIntentCarriesTaskIdentity() {
        let taskID = TaskID()

        guard case .deleteTask(let receivedID) = WarrenDesktopAction.deleteTask(taskID) else {
            return XCTFail("Expected a task deletion action")
        }

        XCTAssertEqual(receivedID, taskID)
    }

    func testTaskDeletionRequestCarriesTaskMetadata() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")

        guard case .task(let receivedTask) = WarrenDesktopDeletionRequest.task(task) else {
            return XCTFail("Expected a task deletion request")
        }

        XCTAssertEqual(receivedTask, task)
    }

    func testTaskRenameRequestCarriesTaskMetadata() {
        let taskID = TaskID()
        let request = WarrenDesktopRenameRequest.task(taskID, name: "Delivery")

        XCTAssertEqual(request.initialValue, "Delivery")
        XCTAssertEqual(request.title, "Rename Task")
        XCTAssertEqual(request.fieldLabel, "Task name")
        XCTAssertTrue(request.message.contains("linked workspaces"))
    }

    @MainActor
    func testProjectWorkspaceRowsIdentifyTheirTaskWithoutDuplicatingTaskRows() throws {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let assigned = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let available = Workspace(
            projectID: project.id,
            name: "available",
            path: "/tmp/api-available"
        )
        let groups = [WarrenDesktopProjectGroup(project: project, workspaces: [assigned, available])]
        let recorder = WarrenSemanticRecorder()
        var selectedTaskID: TaskID?
        var selectedWorkspaceID: WorkspaceID?
        var taskTree = WarrenDesktopSidebarTreeState(
            expandedProjectIDs: [project.id],
            tasksCollapsed: true
        )
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [WarrenDesktopTaskGroup(task: task, workspaces: [assigned])],
            groups: groups,
            terminalGroups: [],
            workspaceActivitySummaries: [:],
            tree: .constant(WarrenDesktopSidebarTreeState(
                expandedTaskIDs: [task.id],
                expandedProjectIDs: [project.id]
            )),
            isCollapsed: false,
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { taskID in
                selectedTaskID = taskID
                WarrenDesktopSidebar.revealTask(taskID, in: &taskTree)
            },
            onRequestTerminalGroupCreate: {},
            onRequestTerminalGroupEdit: { _ in },
            onAction: { action in
                if case .selectWorkspace(let workspaceID) = action {
                    selectedWorkspaceID = workspaceID
                }
            },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        let assignedProjectNode = snapshot.node(
            id: "workspace.project-list.\(assigned.id.description)"
        )
        XCTAssertEqual(
            assignedProjectNode?.label,
            "Workspace assigned"
        )
        XCTAssertTrue(assignedProjectNode?.value?.contains("Belongs to task Delivery") == true)
        XCTAssertFalse(assignedProjectNode?.isEnabled ?? true)
        XCTAssertFalse(assignedProjectNode?.isSelected ?? true)

        let taskLinkNode = snapshot.node(
            id: "workspace-task.project-list.\(assigned.id.description)"
        )
        XCTAssertEqual(taskLinkNode?.label, "Task Delivery")
        XCTAssertEqual(taskLinkNode?.value, "Open task")
        XCTAssertTrue(taskLinkNode?.isEnabled ?? false)
        try recorder.perform(.press, on: "workspace-task.project-list.\(assigned.id.description)")
        XCTAssertEqual(selectedTaskID, task.id)
        XCTAssertFalse(taskTree.tasksCollapsed)
        XCTAssertTrue(taskTree.expandedTaskIDs.contains(task.id))

        try recorder.perform(.press, on: "workspace.project-list.\(assigned.id.description)")
        XCTAssertNil(selectedWorkspaceID)

        let availableProjectNode = snapshot.node(
            id: "workspace.project-list.\(available.id.description)"
        )
        XCTAssertEqual(availableProjectNode?.label, "Workspace available")
        XCTAssertFalse(availableProjectNode?.value?.contains("Belongs to task") == true)
        XCTAssertNil(snapshot.node(id: "workspace-task.project-list.\(available.id.description)"))

        let assignedTaskNode = snapshot.node(
            id: "workspace.task-list.\(assigned.id.description)"
        )
        XCTAssertEqual(assignedTaskNode?.label, "Workspace API · assigned")
        XCTAssertFalse(assignedTaskNode?.label.contains("Delivery") == true)
        XCTAssertFalse(assignedTaskNode?.value?.contains("Belongs to task") == true)
        XCTAssertNil(snapshot.node(id: "workspace-task.task-list.\(assigned.id.description)"))
    }

    func testSidebarWorkspaceScrollTargetPrefersTaskListForAttachedWorkspace() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let assigned = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let available = Workspace(
            projectID: project.id,
            name: "available",
            path: "/tmp/api-available"
        )

        XCTAssertEqual(
            WarrenDesktopSidebar.workspaceScrollTarget(for: assigned),
            "workspace.task-list.\(assigned.id.description)"
        )
        XCTAssertEqual(
            WarrenDesktopSidebar.workspaceScrollTarget(for: available),
            "workspace.project-list.\(available.id.description)"
        )
    }

    func testHostScopedTaskWorkspaceScrollsToItsTaskRowRatherThanTheProjectTree() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let assigned = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let available = Workspace(
            projectID: project.id,
            name: "available",
            path: "/tmp/api-available"
        )

        // The Host tree renders a task-linked row unselectable, so navigation
        // has to land on the Task row instead of the Projects subtree.
        XCTAssertEqual(
            WarrenDesktopSidebar.hostWorkspaceScrollTarget(
                endpointID: "local",
                workspaceID: assigned.id,
                owningTaskID: task.id
            ),
            "workspace.task-list.\(assigned.id.description)"
        )
        XCTAssertEqual(
            WarrenDesktopSidebar.hostWorkspaceScrollTarget(
                endpointID: "local",
                workspaceID: available.id,
                owningTaskID: nil
            ),
            "host.local.workspace.\(available.id.description)"
        )
        // Tasks are current-Host-only, so a background Host keeps its own row
        // as the activation path even for a task-linked workspace.
        XCTAssertEqual(
            WarrenDesktopSidebar.hostWorkspaceScrollTarget(
                endpointID: "vps",
                workspaceID: assigned.id,
                owningTaskID: nil
            ),
            "host.vps.workspace.\(assigned.id.description)"
        )
    }

    func testTaskWorkspaceOptionsKeepOnlyUnassignedWorkspacesGroupedByProject() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let firstProject = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let secondProject = Project(hostID: host.id, name: "Web", rootPath: "/tmp/web")
        let availableWorkspace = Workspace(
            projectID: firstProject.id,
            name: "available",
            path: "/tmp/api-available"
        )
        let assignedWorkspace = Workspace(
            projectID: firstProject.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let groups = [
            WarrenDesktopProjectGroup(
                project: firstProject,
                workspaces: [availableWorkspace, assignedWorkspace]
            ),
            WarrenDesktopProjectGroup(project: secondProject),
        ]

        let availableGroups = WarrenDesktopTaskWorkspaceOptions.availableGroups(from: groups)

        XCTAssertEqual(availableGroups.map(\.project.id), [firstProject.id])
        XCTAssertEqual(availableGroups.flatMap(\.workspaces).map(\.id), [availableWorkspace.id])
    }

    @MainActor
    func testTaskCreationSubmitRejectsUnpairedReferenceAndInvalidURL() async {
        var createCallCount = 0
        var createdRequest: WarrenDesktopTaskCreationRequest?
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            name: "Delivery",
            source: "tapd",
            externalID: "",
            url: "not a URL",
            onCreate: { request in
                createCallCount += 1
                createdRequest = request
                return TaskID()
            },
            onCreated: { _ in }
        )

        XCTAssertEqual(
            coordinator.validationMessage,
            "Source and external ID must be provided together."
        )
        await coordinator.submit()
        XCTAssertEqual(createCallCount, 0)

        coordinator.externalID = "123"
        XCTAssertEqual(
            coordinator.validationMessage,
            "URL must be an absolute HTTP(S) URL."
        )
        await coordinator.submit()
        XCTAssertEqual(createCallCount, 0)

        coordinator.url = "HTTPS://tracker.example/tasks/123"
        XCTAssertNil(coordinator.validationMessage)
        await coordinator.submit()
        XCTAssertEqual(createCallCount, 1)
        XCTAssertEqual(createdRequest?.url, "https://tracker.example/tasks/123")
    }

    @MainActor
    func testTaskCreationSubmitPreventsDuplicatesAndExpandsReturnedID() async {
        let requestID = UUID()
        let started = expectation(description: "Task creation started")
        let fake = PausingTaskCreationFake(callExpectations: [started])
        let host = WarrenDomain.Host(name: "Task Host")
        let first = WarrenTask(hostID: host.id, name: "Delivery")
        let returned = WarrenTask(hostID: host.id, name: "Delivery")
        var tree = WarrenDesktopSidebarTreeState()
        var isPresented = true
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            requestID: requestID,
            name: "Delivery",
            source: "tapd",
            externalID: "123",
            url: "https://tracker.example/tasks/123",
            onCreate: fake.create,
            onCreated: { taskID in
                WarrenDesktopTaskCreationPresentation.complete(
                    taskID: taskID,
                    tree: &tree,
                    onDismiss: { isPresented = false }
                )
            }
        )

        let submission = Task { await coordinator.submit() }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(fake.requests, [WarrenDesktopTaskCreationRequest(
            requestID: requestID,
            name: "Delivery",
            source: "tapd",
            externalID: "123",
            url: "https://tracker.example/tasks/123"
        )])
        XCTAssertTrue(coordinator.isSubmitting)
        XCTAssertTrue(isPresented)

        await coordinator.submit()
        XCTAssertEqual(fake.callCount, 1)

        fake.succeed(returned.id)
        await submission.value

        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertFalse(isPresented)
        XCTAssertNotEqual(first.id, returned.id)
        XCTAssertEqual(tree.expandedTaskIDs, [returned.id])
        XCTAssertFalse(tree.expandedTaskIDs.contains(first.id))
        XCTAssertFalse(tree.tasksCollapsed)
    }

    @MainActor
    func testTaskCreationSubmitFailureKeepsInputsAndAllowsRetry() async {
        let firstStarted = expectation(description: "First task creation started")
        let retryStarted = expectation(description: "Task creation retry started")
        let fake = PausingTaskCreationFake(
            callExpectations: [firstStarted, retryStarted]
        )
        var isPresented = true
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            name: "Delivery",
            source: "tapd",
            externalID: "123",
            url: "https://tracker.example/tasks/123",
            onCreate: fake.create,
            onCreated: { _ in isPresented = false }
        )

        let firstSubmission = Task { await coordinator.submit() }
        await fulfillment(of: [firstStarted], timeout: 1)

        let failure = NSError(
            domain: "TaskCreationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Task creation failed"]
        )
        fake.fail(failure)
        await firstSubmission.value

        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertTrue(isPresented)
        XCTAssertEqual(coordinator.errorMessage, "Task creation failed")
        XCTAssertEqual(coordinator.name, "Delivery")
        XCTAssertEqual(coordinator.source, "tapd")
        XCTAssertEqual(coordinator.externalID, "123")
        XCTAssertEqual(coordinator.url, "https://tracker.example/tasks/123")

        coordinator.binding(\.url).wrappedValue = "HTTPS://tracker.example/tasks/123"
        XCTAssertNil(coordinator.errorMessage)
        coordinator.binding(\.url).wrappedValue = "https://tracker.example/tasks/123"

        let retry = Task { await coordinator.submit() }
        await fulfillment(of: [retryStarted], timeout: 1)
        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(fake.requests.map(\.requestID), [coordinator.requestID, coordinator.requestID])
        XCTAssertTrue(coordinator.isSubmitting)
        XCTAssertNil(coordinator.errorMessage)
        fake.succeed(TaskID())
        await retry.value
        XCTAssertFalse(isPresented)
    }

    @MainActor
    func testTaskCreationChangesRequestIDOnlyWhenSubmittedDraftChanges() async {
        let requestID = UUID()
        var requests: [WarrenDesktopTaskCreationRequest] = []
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            requestID: requestID,
            name: "Delivery",
            onCreate: { request in
                requests.append(request)
                throw NSError(
                    domain: "TaskCreationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Task creation failed"]
                )
            },
            onCreated: { _ in XCTFail("Failed submissions must not complete creation") }
        )

        await coordinator.submit()
        await coordinator.submit()
        XCTAssertEqual(requests.map(\.requestID), [requestID, requestID])

        coordinator.binding(\.name).wrappedValue = "Updated delivery"
        XCTAssertNil(coordinator.errorMessage)
        await coordinator.submit()

        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(requests[2].requestID, requestID)
        XCTAssertEqual(requests[2].requestID, coordinator.requestID)
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

    func testWorkspaceContentModePersistenceIsScopedAndDropsStaleWorkspaces() {
        let suiteName = "warren-workspace-content-mode-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaces = WarrenDesktopFixture.preview.projection.groups.flatMap(\.workspaces)
        let editorWorkspace = workspaces[0]
        let terminalWorkspace = workspaces[1]

        WarrenDesktopWorkspaceContentModePersistence.save(
            [
                editorWorkspace.id: .editor,
                terminalWorkspace.id: .terminal,
                WorkspaceID(): .editor,
            ],
            scope: "local",
            validWorkspaceIDs: Set(workspaces.map(\.id)),
            defaults: defaults
        )

        XCTAssertEqual(
            WarrenDesktopWorkspaceContentModePersistence.restore(
                scope: "local",
                defaults: defaults
            ),
            [editorWorkspace.id: .editor]
        )
        XCTAssertTrue(
            WarrenDesktopWorkspaceContentModePersistence.restore(
                scope: "remote",
                defaults: defaults
            ).isEmpty
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
        let taskID = TaskID()
        let sessionID = fixture.sessions[0].id

        actions(.addProject)
        actions(.importSuperset)
        actions(.requestNewWorkspace(projectID))
        actions(.requestNewWorkspace(projectID, taskID: taskID))
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
        actions(.clearSelectedTab)
        actions(.toggleSidebar)
        actions(.dismissActivity(sessionID, .working))

        XCTAssertEqual(
            received,
            [
                .addProject,
                .importSuperset,
                .requestNewWorkspace(projectID),
                .requestNewWorkspace(projectID, taskID: taskID),
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
                .clearSelectedTab,
                .toggleSidebar,
                .dismissActivity(sessionID, .working),
            ]
        )
    }

    func testBuiltInPresetsMapToExplicitLaunchRequests() {
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.id), ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae"])
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.map(\.presetBarTitle),
            ["Shell", "Claude", "Codex", "OpenCode", "Pi", "Qoder", "Antigravity", "Trae"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.compactMap(\.presetBarIconName),
            ["preset-shell", "preset-claude", "preset-codex", "preset-opencode", "preset-pi", "preset-qoder", "preset-antigravity", "preset-trae"]
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.request), [.shell, .claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae])
        XCTAssertNil(TerminalSessionLaunchRequest.shell.command)
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.command, "claude")
        // Built-in presets carry no user title: the Host derives the default
        // display name from the kind and keeps the custom-title slot free for
        // automatic AI title generation. The launch title is presentation copy
        // owned by the preset catalog, not a session custom title.
        XCTAssertNil(TerminalSessionLaunchRequest.claude.title)
        XCTAssertEqual(
            TerminalSessionLaunchRequest.codex.command,
            "codex --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(TerminalSessionLaunchRequest.opencode.command, "opencode")
        XCTAssertNil(TerminalSessionLaunchRequest.opencode.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.pi.command, "pi")
        XCTAssertNil(TerminalSessionLaunchRequest.pi.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.qoder.command, "qoder")
        XCTAssertNil(TerminalSessionLaunchRequest.qoder.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.trae.command, "trae-cli interactive")
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI?.id, "claude")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.firstAI?
                .resolvedRequest(commandOverride: "claude --model sonnet").command,
            "claude --model sonnet"
        )
        // The command override keeps the preset title slot untouched (nil for
        // built-ins), so no preset name leaks into the custom-title slot.
        XCTAssertNil(
            WarrenDesktopSessionPreset.pinned.first { $0.id == "codex" }?
                .resolvedRequest(commandOverride: "codex --model gpt-5").title
        )
    }

    func testPresetOrderNormalizesPersistedIdentifiers() {
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder("codex,shell,codex,future"),
            ["codex", "shell", "claude", "opencode", "pi", "qoder", "antigravity", "trae"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder(""),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrderRawValue("codex,shell,codex,future"),
            "codex,shell,claude,opencode,pi,qoder,antigravity,trae"
        )
    }

    func testPresetOrderControlsPresentation() {
        let order = "shell,codex,claude,opencode,pi,qoder,antigravity,trae"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedPinned(by: order).map(\.id),
            ["shell", "codex", "claude", "opencode", "pi", "qoder", "antigravity", "trae"]
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI(orderedBy: order)?.id, "codex")
    }

    func testPresetVisibilityHidesTraeByDefaultAndControlsAutomaticAI() {
        XCTAssertEqual(WarrenDesktopSessionPreset.defaultHiddenRawValue, "trae")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedVisible(
                by: WarrenDesktopSessionPreset.defaultOrderRawValue,
                hidden: WarrenDesktopSessionPreset.defaultHiddenRawValue
            ).map(\.id),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity"]
        )

        let onlyTraeVisible = WarrenDesktopSessionPreset.pinned
            .map(\.id)
            .filter { $0 != "trae" }
            .joined(separator: ",")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.firstAI(
                orderedBy: "trae,shell,claude,codex",
                hidden: onlyTraeVisible
            )?.id,
            "trae"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.settingVisibility(of: "trae", visible: true, in: "trae"),
            ""
        )
    }

    func testPresetLaunchFeedbackDisablesDuplicateStarts() {
        XCTAssertFalse(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: false, isPending: false))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: true, isPending: false))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: false, isPending: true))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: false, isBusy: false, isPending: false))
        XCTAssertEqual(WarrenDesktopPresetLaunchFeedback.label(isPending: true), "Starting…")
        XCTAssertEqual(WarrenDesktopPresetLaunchFeedback.label(isPending: false), "Ready")
    }

    func testEveryPresetAcceptsItsOwnCommandOverride() {
        for preset in WarrenDesktopSessionPreset.pinned {
            XCTAssertEqual(
                preset.resolvedRequest(commandOverride: "personal-\(preset.id)").command,
                "personal-\(preset.id)"
            )
        }
        let trae = WarrenDesktopSessionPreset.pinned.first { $0.id == "trae" }
        XCTAssertEqual(trae?.resolvedRequest(commandOverride: "").command, "trae-cli interactive")
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
        let order = "shell,claude,codex,opencode,pi,qoder,antigravity,trae"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("codex", by: -1, in: order),
            "shell,codex,claude,opencode,pi,qoder,antigravity,trae"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("shell", by: -1, in: order),
            order
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("trae", by: 1, in: order),
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

    func testTabNumberSelectorAppendsTheLocalEditorTab() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs

        XCTAssertEqual(
            WarrenDesktopTabSelector.selection(
                in: tabs,
                includesEditor: true,
                number: tabs.count + 1
            ),
            .editor
        )
        XCTAssertNil(WarrenDesktopTabSelector.selection(
            in: tabs,
            includesEditor: false,
            number: tabs.count + 1
        ))
    }

    func testIDEPrimaryActionRequiresTheDefaultCheck() {
        XCTAssertEqual(
            WarrenDesktopIDEPrimaryAction.resolve(
                embeddedEditorDefault: false,
                embeddedEditorSelected: false
            ),
            .presentChoices
        )
        XCTAssertEqual(
            WarrenDesktopIDEPrimaryAction.resolve(
                embeddedEditorDefault: true,
                embeddedEditorSelected: false
            ),
            .openEmbeddedEditor
        )
        XCTAssertEqual(
            WarrenDesktopIDEPrimaryAction.resolve(
                embeddedEditorDefault: true,
                embeddedEditorSelected: true
            ),
            .presentChoices
        )
    }

    func testEmbeddedEditorInstallGuideUsesOfficialDocumentation() {
        XCTAssertEqual(
            WarrenDesktopExternalIDEPopoverContent.codeServerInstallationGuideURL
                .absoluteString,
            "https://coder.com/docs/code-server/install"
        )
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
            "codex · superset"
        )
    }

    func testTabTitleShowsForegroundCommandLine() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-cmdline",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell,
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "npm run dev · warren"
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

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "warren"
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

    func testTabTitleKeepsManagedAgentPurposeWhenForegroundProcessIsShell() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-codex-shell",
            title: "Codex",
            sessionID: sessionID,
            kind: .codex
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Codex",
            kind: .codex,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "codex · warren"
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
            "codex"
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

    func testPackagedPresetIconsAreValidImages() throws {
        let iconNames = try WarrenDesktopSessionPreset.pinned.map {
            try XCTUnwrap($0.presetBarIconName)
        } + ["preset-codex-white"]

        for iconName in iconNames {
            let image = try XCTUnwrap(WarrenPresetIconCache.shared.image(named: iconName))
            XCTAssertTrue(image.isValid, "Expected \(iconName) to decode as a valid image")
        }
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

    func testDeletingWorkspaceReturnsToTheMostRecentlyVisitedWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceA = fixture.groups[0].workspaces[0]
        let workspaceB = fixture.groups[1].workspaces[0]

        // 1. Visit workspace A
        let stateA = WarrenDesktopNavigationReducer.reduce(
            .init(),
            action: .selectWorkspace(workspaceA.id),
            in: fixture.projection
        )
        XCTAssertEqual(stateA.selection, .workspace(workspaceA.id))

        // 2. Jump to workspace B
        let stateB = WarrenDesktopNavigationReducer.reduce(
            stateA,
            action: .selectWorkspace(workspaceB.id),
            in: fixture.projection
        )
        XCTAssertEqual(stateB.selection, .workspace(workspaceB.id))

        // 3. Delete workspace B and reconcile with a projection that no longer has workspace B
        let deletedState = WarrenDesktopNavigationReducer.reduce(
            stateB,
            action: .deleteWorkspace(workspaceB.id, removeLocalWorktree: false),
            in: fixture.projection
        )

        let projectionWithoutB = WarrenDesktopProjection(
            host: fixture.host,
            groups: [fixture.groups[0]],
            sessions: fixture.sessions.filter { $0.workspaceID != workspaceB.id },
            tabs: fixture.tabs.filter { fixture.projection.workspaceID(forTabID: $0.id) != workspaceB.id }
        )

        let reconciled = WarrenDesktopNavigationReducer.reconcile(deletedState, with: projectionWithoutB)
        XCTAssertEqual(reconciled.selection, .workspace(workspaceA.id))
        XCTAssertEqual(reconciled.selectedTabID, "tab-main")
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

    func testDeletingSessionReturnsToTheMostRecentlyVisitedTab() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let session1 = WarrenDesktopSession(id: TerminalSessionID(), workspaceID: workspaceID, tabID: "tab-s1", title: "S1", kind: .shell)
        let session2 = WarrenDesktopSession(id: TerminalSessionID(), workspaceID: workspaceID, tabID: "tab-s2", title: "S2", kind: .shell)
        let tab1 = ClientTab(id: "tab-s1", title: "S1", sessionID: session1.id, kind: .shell)
        let tab2 = ClientTab(id: "tab-s2", title: "S2", sessionID: session2.id, kind: .shell)
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [session1, session2],
            tabs: [tab1, tab2],
            sessionWorkspaceIDs: [session1.id: workspaceID, session2.id: workspaceID],
            tabWorkspaceIDs: [tab1.id: workspaceID, tab2.id: workspaceID]
        )

        let s1 = WarrenDesktopNavigationReducer.reduce(.init(), action: .selectTab(tab1.id), in: projection)
        let s2 = WarrenDesktopNavigationReducer.reduce(s1, action: .selectTab(tab2.id), in: projection)
        XCTAssertEqual(s2.selectedTabID, tab2.id)

        let afterDeleteSession2 = WarrenDesktopNavigationReducer.reduce(s2, action: .deleteSession(session2.id), in: projection)
        XCTAssertEqual(afterDeleteSession2.selectedTabID, tab1.id)
    }

    func testDeletingTerminalGroupReturnsToPreviousSelection() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let group = TerminalGroup(hostID: fixture.host.id, name: "Scratch")
        let groupTab = ClientTab(id: "group-tab", title: "Scratch Tab", kind: .shell)
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            tabs: fixture.tabs + [groupTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: fixture.projection.tabWorkspaceIDs,
            terminalGroups: [group],
            tabTerminalGroupIDs: [groupTab.id: group.id]
        )

        // 1. Visit workspace
        let stateWS = WarrenDesktopNavigationReducer.reduce(.init(), action: .selectWorkspace(workspaceID), in: projection)
        XCTAssertEqual(stateWS.selection, .workspace(workspaceID))

        // 2. Jump to terminal group
        let stateGroup = WarrenDesktopNavigationReducer.reduce(stateWS, action: .selectTerminalGroup(group.id), in: projection)
        XCTAssertEqual(stateGroup.selection, .terminalGroup(group.id))

        // 3. Delete terminal group and reconcile with projection without the group
        let deleted = WarrenDesktopNavigationReducer.reduce(stateGroup, action: .deleteTerminalGroup(group.id), in: projection)
        let projectionWithoutGroup = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            tabs: fixture.tabs,
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: fixture.projection.tabWorkspaceIDs,
            terminalGroups: []
        )
        let reconciled = WarrenDesktopNavigationReducer.reconcile(deleted, with: projectionWithoutGroup)
        XCTAssertEqual(reconciled.selection, .workspace(workspaceID))
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
            activity: .blocked
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



    @MainActor
    func testRichWorkspaceRowsShowEveryLiveSessionAsALeaf() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let codex = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let claude = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Review API",
            kind: .claude,
            activity: .ready
        )
        // A shell the Host promoted through an Agent binding reports activity.
        let promotedShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Bound shell",
            kind: .shell,
            activity: .working
        )
        // A shell with no Agent binding reports no activity, but it is still a
        // live Session and therefore still a leaf of the tree.
        let plainShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Plain shell",
            kind: .shell
        )
        let ended = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Ended",
            kind: .codex,
            state: .exited,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [codex, claude, promotedShell, plainShell, ended]
        )
        let recorder = WarrenSemanticRecorder()
        var actions: [WarrenDesktopAction] = []
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            terminalGroups: [],
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState(
                expandedProjectIDs: [project.id]
            )),
            isCollapsed: false,
            selection: .workspace(workspace.id),
            selectedTabID: "tab.codex",
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onRequestTerminalGroupCreate: {},
            onRequestTerminalGroupEdit: { _ in },
            onAction: { actions.append($0) },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let richNodes = recorder.snapshot().nodes.filter {
            $0.id.hasPrefix("workspace-session.project-list.")
        }
        XCTAssertEqual(richNodes.count, 4)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: richNodes.map { ($0.label, $0.value) }),
            [
                // The open Session is the selected row, so its value carries the
                // selection the same way every other navigation row does.
                "Codex Session Implement API": "Working · API · feature · Selected",
                "Claude Code Session Review API": "Idle · API · feature",
                "Shell Session Bound shell": "Working · API · feature",
                "Shell Session Plain shell": "API · feature",
            ]
        )
        XCTAssertTrue(
            richNodes.first { $0.label.contains("Implement API") }?.isSelected == true
        )
        XCTAssertFalse(richNodes.contains { $0.label.contains("Ended") })

        try recorder.perform(
            .press,
            on: "workspace-session.project-list.\(workspace.id.description).\(codex.id.description)"
        )
        XCTAssertEqual(actions, [.openSession(codex.id)])
    }

    /// Opening a Session keeps its workspace as the navigation scope, so both
    /// rows match the selection. Only the leaf may claim it: it is the row the
    /// user clicked and the more specific answer to "where am I". The workspace
    /// states containment instead, so the rail still says which workspace is
    /// live without stealing the highlight from the row below it.
    @MainActor
    func testSelectingASessionLeafMovesTheHighlightOffItsWorkspace() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )

        func nodes(selectedTabID: String?) throws -> [String: WarrenSemanticNode] {
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: [],
                groups: projection.groups,
                terminalGroups: [],
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
                activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState(
                    expandedProjectIDs: [project.id]
                )),
                isCollapsed: false,
                selection: .workspace(workspace.id),
                selectedTabID: selectedTabID,
                deletingProjectIDs: [],
                deletingWorkspaceIDs: [],
                endpointCapabilities: .local,
                isInteractionDisabled: false,
                onAddProject: {},
                onRequestTaskCreate: {},
                onFocusTask: { _ in },
                onRequestTerminalGroupCreate: {},
                onRequestTerminalGroupEdit: { _ in },
                onAction: { _ in },
                onRequestRename: { _ in },
                onRequestDeletion: { _ in }
            )
            .frame(width: 420, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let workspaceID = "workspace.project-list.\(workspace.id.description)"
        let leafID = "workspace-session.project-list."
            + "\(workspace.id.description).\(session.id.description)"

        let withLeafOpen = try nodes(selectedTabID: "tab.codex")
        XCTAssertEqual(withLeafOpen[leafID]?.isSelected, true)
        XCTAssertEqual(withLeafOpen[workspaceID]?.isSelected, false)
        XCTAssertEqual(
            withLeafOpen[workspaceID]?.value,
            "Contains the selected session · Not selected"
        )

        // With no Session open the workspace is the deepest live row, so it
        // takes the selection back rather than leaving the rail unanswered.
        let withNoLeafOpen = try nodes(selectedTabID: nil)
        XCTAssertEqual(withNoLeafOpen[leafID]?.isSelected, false)
        XCTAssertEqual(withNoLeafOpen[workspaceID]?.isSelected, true)
    }

    /// The multi-Host sections are a second implementation of the same tree, so
    /// they carry the same rule: the leaf takes the selection, its workspace
    /// states containment. A background Host has nothing open, so none of its
    /// leaves draw as selected even where the tab IDs would collide.
    @MainActor
    func testHostSectionLeafTakesTheSelectionFromItsWorkspace() throws {
        let localHost = WarrenDomain.Host(name: "Local")
        let project = Project(hostID: localHost.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "feature", path: "/tmp/a")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        func projection(endpointID: String) -> WarrenDesktopSidebarHostProjection {
            WarrenDesktopSidebarHostProjection(
                endpointID: endpointID,
                endpointLabel: endpointID.capitalized,
                host: localHost,
                connectionState: .attached,
                projectGroups: [
                    WarrenDesktopProjectGroup(project: project, workspaces: [workspace]),
                ],
                activeSessionsByWorkspaceID: [workspace.id: [session]],
                activeWorkspaceIDs: [workspace.id]
            )
        }

        func nodes(activeEndpointID: String) throws -> [String: WarrenSemanticNode] {
            let recorder = WarrenSemanticRecorder()
            let state = SidebarHostRowsTestState(
                hosts: [projection(endpointID: "local"), projection(endpointID: "remote")],
                selection: .workspace(
                    WarrenDesktopHostResourceRef(endpointID: "local", id: workspace.id)
                )
            )
            let rows = SidebarHostRowsTestHarness(
                state: state,
                activeEndpointID: activeEndpointID,
                workspaceDisplayMode: .rich,
                selectedTabID: "tab.codex"
            )
            .frame(width: 420, height: 600)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let localWorkspaceID = "workspace.host.local.\(workspace.id.description)"
        let localLeafID = "workspace-session.host.local."
            + "\(workspace.id.description).\(session.id.description)"
        let remoteLeafID = "workspace-session.host.remote."
            + "\(workspace.id.description).\(session.id.description)"

        let onLocal = try nodes(activeEndpointID: "local")
        XCTAssertEqual(onLocal[localLeafID]?.isSelected, true)
        XCTAssertEqual(onLocal[localWorkspaceID]?.isSelected, false)
        // The two Hosts here project the same tab ID, so a leaf that matched on
        // the tab alone would light up in both sections at once.
        XCTAssertNotEqual(
            onLocal[remoteLeafID]?.isSelected,
            true,
            "A background Host has nothing open, so no leaf of its own is selected"
        )

        // With the selected workspace's Host in the background, nothing there is
        // open either, so its workspace row takes the selection back.
        let onRemote = try nodes(activeEndpointID: "remote")
        XCTAssertEqual(onRemote[localLeafID]?.isSelected, false)
        XCTAssertEqual(onRemote[localWorkspaceID]?.isSelected, true)
    }

    /// The collapsed rail is 32pt of glyphs. A leaf there has no parent row to
    /// sit under and no room for its title, so rich mode falls back to the
    /// workspace's aggregate marker until the rail is expanded.
    @MainActor
    func testCollapsedRailListsNoSessionLeaves() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            terminalGroups: [],
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState(
                expandedProjectIDs: [project.id]
            )),
            isCollapsed: true,
            selection: .workspace(workspace.id),
            selectedTabID: "tab.codex",
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onRequestTerminalGroupCreate: {},
            onRequestTerminalGroupEdit: { _ in },
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: WarrenLayoutMetrics.sidebarCollapsedWidth, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: WarrenLayoutMetrics.sidebarCollapsedWidth,
            height: 500
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let nodes = recorder.snapshot().nodes
        XCTAssertFalse(nodes.contains { $0.id.hasPrefix("workspace-session.") })
        XCTAssertTrue(
            nodes.contains { $0.id == "workspace.project-list.\(workspace.id.description)" },
            "The workspace glyph still stands in for its Sessions"
        )
    }

    /// A shell that the Host bound to an Agent must be named and drawn as that
    /// provider. Reading only the durable launch kind made every Agent started
    /// inside a shell render as a plain terminal.
    func testSessionPresentationFollowsTheBoundAgentProvider() {
        let workspaceID = WorkspaceID()
        let boundShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Implement API",
            kind: .shell,
            agentProvider: .claude,
            activity: .working
        )
        XCTAssertEqual(boundShell.presentedKind, .claude)
        XCTAssertEqual(boundShell.kind, .shell, "The durable launch kind must not be rewritten")
        XCTAssertTrue(boundShell.isAgentSession)

        // A dedicated Agent Session keeps its own kind even if the Host also
        // reports a provider for it.
        let codex = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Review",
            kind: .codex,
            agentProvider: .claude
        )
        XCTAssertEqual(codex.presentedKind, .codex)

        let plainShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell
        )
        XCTAssertEqual(plainShell.presentedKind, .shell)
        XCTAssertFalse(plainShell.isAgentSession)
    }

    /// The leaf names the provider and reports what the Session is actually
    /// doing: why an Agent is blocked, or what a plain shell is running. A
    /// shell with no Agent binding contributes no activity word.
    @MainActor
    func testRichSessionRowsReportAttentionReasonAndShellProcess() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "feature", path: "/tmp/api-feature")
        let blocked = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .shell,
            agentProvider: .claude,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Approve running tests")
            )
        )
        let shell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Shell",
            kind: .shell,
            runtimeProcess: "npm run dev"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [blocked, shell]
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            terminalGroups: [],
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState(
                expandedProjectIDs: [project.id]
            )),
            isCollapsed: false,
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onRequestTerminalGroupCreate: {},
            onRequestTerminalGroupEdit: { _ in },
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let rowsByLabel = Dictionary(
            uniqueKeysWithValues: recorder.snapshot().nodes
                .filter { $0.id.hasPrefix("workspace-session.") }
                .map { ($0.label, $0.value) }
        )
        XCTAssertEqual(
            rowsByLabel["Claude Code Session Implement API"],
            "Approval needed · Approve running tests · API · feature",
            "A bound Agent names its provider and explains what it is waiting for"
        )
        XCTAssertEqual(
            rowsByLabel["Shell Session Shell"],
            "npm run dev · API · feature",
            "A plain shell reports its process without claiming an activity it cannot observe"
        )
    }

    /// The tab strip no longer lists a workspace's other Sessions, so the leaf
    /// is the only place a Session can be renamed, pinned, or ended. A leaf
    /// without those actions would strand them.
    func testSessionLeafOwnsEveryPerSessionAction() {
        let titles = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: false,
            onTogglePin: {},
            onRename: {},
            onEnd: {}
        ).compactMap { action -> String? in
            guard case .button(let title, _, _) = action else { return nil }
            return title
        }
        XCTAssertEqual(titles, ["Pin Session", "Rename Session", "End Session…"])

        XCTAssertTrue(
            WarrenDesktopWorkspaceSessionRow.contextMenuActions(
                isPinned: false,
                onTogglePin: nil,
                onRename: nil,
                onEnd: nil
            ).isEmpty,
            "A background Host's leaf stays navigable but offers no mutations"
        )

        let pinned = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: true,
            onTogglePin: {},
            onRename: nil,
            onEnd: nil
        )
        guard case .button(let pinTitle, _, _) = pinned.first else {
            return XCTFail("Expected a pin action")
        }
        XCTAssertEqual(pinTitle, "Unpin Session")
    }

    /// A single pane gives the bar nothing to switch between, and its chip
    /// repeats a title the pane header carries and the sidebar leaf highlights.
    /// Chips are earned by having a second pane to choose.
    func testPaneBarShowsItsTrackOnlyWhenThereIsAPaneToChoose() {
        XCTAssertFalse(
            WarrenDesktopPaneBar.showsTrack(
                entryCount: 1,
                embeddedEditorTabVisible: false,
                mode: .rich
            )
        )
        XCTAssertTrue(
            WarrenDesktopPaneBar.showsTrack(
                entryCount: 2,
                embeddedEditorTabVisible: false,
                mode: .rich
            )
        )
        // The editor is a second surface to switch to, so it brings the track
        // back even with one terminal pane on screen.
        XCTAssertTrue(
            WarrenDesktopPaneBar.showsTrack(
                entryCount: 1,
                embeddedEditorTabVisible: true,
                mode: .rich
            )
        )
        XCTAssertFalse(
            WarrenDesktopPaneBar.showsTrack(
                entryCount: 0,
                embeddedEditorTabVisible: true,
                mode: .rich
            )
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
            activity: .working,
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

    /// Every combination of the two tree controls has to leave a Session
    /// reachable. The failure that motivated this was silent: compact stops
    /// listing leaves, and the bar had already stopped listing Sessions, so a
    /// workspace's second Session was in neither surface.
    func testEveryTreeStateLeavesSessionsReachable() {
        let sessionTabs = (1...3).map {
            ClientTab(id: "tab-\($0)", title: "Tab \($0)", kind: .shell)
        }
        let onePane = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))

        for mode in [WarrenDesktopWorkspaceDisplayMode.rich, .compact] {
            let barEntries = WarrenDesktopPaneBar.tabs(
                visibleIn: onePane,
                from: sessionTabs,
                selected: sessionTabs[0],
                mode: mode
            )
            let reachable = mode.sidebarListsSessions
                ? Set(sessionTabs.map(\.id))
                : Set(barEntries.map(\.id))
            XCTAssertEqual(
                reachable,
                Set(sessionTabs.map(\.id)),
                "\(mode.rawValue) left a Session in neither the tree nor the bar"
            )
            XCTAssertTrue(
                WarrenDesktopPaneBar.showsTrack(
                    entryCount: barEntries.count,
                    embeddedEditorTabVisible: false,
                    mode: mode
                ) || mode.sidebarListsSessions,
                "\(mode.rawValue) hid the bar that owns its Session list"
            )
        }
    }

    /// Turning the Sessions on while their projects are closed looks like the
    /// control did nothing, so it opens the projects that gained rows — and only
    /// those, since opening the rest would add empty depth.
    func testTurningOnSessionsOpensOnlyTheProjectsThatGainRows() {
        let host = WarrenDomain.Host(name: "Host")
        let withSessions = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let idle = Project(hostID: host.id, name: "Docs", rootPath: "/tmp/docs")
        let liveWorkspace = Workspace(projectID: withSessions.id, name: "feature", path: "/tmp/a")
        let idleWorkspace = Workspace(projectID: idle.id, name: "main", path: "/tmp/b")
        let groups = [
            WarrenDesktopProjectGroup(project: withSessions, workspaces: [liveWorkspace]),
            WarrenDesktopProjectGroup(project: idle, workspaces: [idleWorkspace]),
        ]

        XCTAssertEqual(
            WarrenDesktopSidebarRows.projectIDsToReveal(
                filteringToActiveOnly: false,
                in: groups,
                activeWorkspaceIDs: [liveWorkspace.id]
            ),
            [withSessions.id]
        )

        // The filter has already dropped everything it hides, so whatever
        // survives is worth opening.
        XCTAssertEqual(
            WarrenDesktopSidebarRows.projectIDsToReveal(
                filteringToActiveOnly: true,
                in: groups,
                activeWorkspaceIDs: [liveWorkspace.id]
            ),
            [withSessions.id, idle.id]
        )

        XCTAssertTrue(
            WarrenDesktopSidebarRows.projectIDsToReveal(
                filteringToActiveOnly: false,
                in: groups,
                activeWorkspaceIDs: []
            ).isEmpty,
            "With no live Session there is nothing to reveal"
        )
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
            terminalGroupMoveTargets: [],
            onMoveSession: { _, _ in endedSessions += 1 },
            onTogglePin: {},
            onDismissActivity: {},
            onRename: {},
            onClose: { closedPanes += 1 },
            onCloseOthers: { closedPanes += 1 },
            onCloseAll: { closedPanes += 1 }
        ).compactMap { action -> String? in
            guard case .button(let title, _, let run) = action else { return nil }
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

    /// A Task-linked workspace appears twice in the tree. Its Agent rows must
    /// stay in the Projects subtree in both Task states, so a running Session
    /// neither moves between rows nor disappears when Tasks is collapsed.
    @MainActor
    func testRichSessionRowsStayInProjectsTreeForTaskLinkedWorkspaces() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "delivery-api",
            path: "/tmp/api-delivery"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )

        for expandedTaskIDs in [Set<TaskID>(), Set([task.id])] {
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: projection.taskGroups,
                groups: projection.groups,
                terminalGroups: [],
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState(
                    expandedTaskIDs: expandedTaskIDs,
                    expandedProjectIDs: [project.id]
                )),
                isCollapsed: false,
                selection: nil,
                deletingProjectIDs: [],
                deletingWorkspaceIDs: [],
                endpointCapabilities: .local,
                isInteractionDisabled: false,
                onAddProject: {},
                onRequestTaskCreate: {},
                onFocusTask: { _ in },
                onRequestTerminalGroupCreate: {},
                onRequestTerminalGroupEdit: { _ in },
                onAction: { _ in },
                onRequestRename: { _ in },
                onRequestDeletion: { _ in }
            )
            .frame(width: 420, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            XCTAssertEqual(
                recorder.snapshot().nodes
                    .filter { $0.id.hasPrefix("workspace-session.") }
                    .map(\.id),
                [
                    "workspace-session.project-list.\(workspace.id.description)"
                        + ".\(session.id.description)",
                ],
                "Task expansion \(expandedTaskIDs.isEmpty ? "collapsed" : "expanded")"
            )
        }
    }

    @MainActor
    func testCompactWorkspaceRowsDoNotRenderAgentChildren() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "feature", path: "/tmp/api-feature")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            terminalGroups: [],
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .compact,
            tree: .constant(WarrenDesktopSidebarTreeState(
                expandedProjectIDs: [project.id]
            )),
            isCollapsed: false,
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onRequestTerminalGroupCreate: {},
            onRequestTerminalGroupEdit: { _ in },
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(recorder.snapshot().nodes.first {
            $0.id.hasPrefix("workspace-session.")
        })
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

    func testNavigationPersistenceIsolatedPerEndpointScope() throws {
        let suiteName = "WarrenDesktopTests.navigation.scoped.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sharedProjectID = ProjectID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let sharedWorkspaceID = WorkspaceID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        let localState = WarrenDesktopNavigationState(
            selection: .project(sharedProjectID),
            selectedTabID: "local-tab",
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: [sharedProjectID.description: sharedWorkspaceID.description]
            )
        )
        let remoteState = WarrenDesktopNavigationState(
            selection: .workspace(sharedWorkspaceID),
            selectedTabID: "remote-tab"
        )

        WarrenDesktopNavigationPersistence.save(localState, scope: "local", to: defaults)
        WarrenDesktopNavigationPersistence.save(remoteState, scope: "prod", to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "local", from: defaults),
            localState
        )
        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "prod", from: defaults),
            remoteState
        )
        XCTAssertNotEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "local", from: defaults),
            remoteState
        )
    }

    func testTabOrdersAreIsolatedPerEndpointScope() throws {
        let suiteName = "WarrenDesktopTests.navigation.scoped-tabs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceKey = "00000000-0000-4000-8000-000000000003"
        let localOrders = WarrenDesktopTabOrders(
            workspace: [workspaceKey: ["local-a", "local-b"]]
        )
        let remoteOrders = WarrenDesktopTabOrders(
            workspace: [workspaceKey: ["remote-a", "remote-b"]]
        )

        WarrenDesktopNavigationPersistence.saveTabOrders(localOrders, scope: "local", to: defaults)
        WarrenDesktopNavigationPersistence.saveTabOrders(remoteOrders, scope: "prod", to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restoreTabOrders(scope: "local", from: defaults),
            localOrders
        )
        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restoreTabOrders(scope: "prod", from: defaults),
            remoteOrders
        )
    }

    func testLegacyNavigationPersistenceMigratesToFirstRequestedScope() throws {
        let suiteName = "WarrenDesktopTests.navigation.legacy-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = ProjectID()
        let state = WarrenDesktopNavigationState(
            selection: .project(projectID),
            selectedTabID: "legacy-tab",
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: [projectID.description: "workspace"]
            )
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "prod", from: defaults),
            state
        )
        XCTAssertNil(
            WarrenDesktopNavigationPersistence.restore(scope: "local", from: defaults)
        )
    }

    func testHostTintAllocatorPreservesVisibleAssignmentsWhenAliasIsAdded() {
        let allocator = WarrenDesktopHostTintAllocator()
        let paletteCount = WarrenColorTokens.dark.hostSectionTints.count

        allocator.update(endpointIDs: ["dev", "prod"], paletteCount: paletteCount)
        let initial = allocator.assignments
        allocator.update(
            endpointIDs: ["dev", "prod", "staging"],
            paletteCount: paletteCount
        )

        XCTAssertEqual(allocator.assignments["dev"], initial["dev"])
        XCTAssertEqual(allocator.assignments["prod"], initial["prod"])
        XCTAssertNotNil(allocator.assignments["staging"])
    }

    func testSidebarTreePersistenceIsPerScopeAndRoundTrips() throws {
        let suiteName = "WarrenDesktopTests.sidebarTree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = WarrenDesktopSidebarTreeState(
            expandedTaskIDs: [TaskID(), TaskID()],
            expandedProjectIDs: [ProjectID(), ProjectID()],
            terminalGroupsCollapsed: true,
            tasksCollapsed: true,
            projectsCollapsed: true,
            showsActiveOnly: true
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

    @MainActor
    func testTerminalGroupsSectionHidesRowsWhenCollapsed() {
        let host = WarrenDomain.Host(name: "Terminal Host")
        let terminalGroup = TerminalGroup(hostID: host.id, name: "Operations")
        let group = WarrenDesktopTerminalGroup(group: terminalGroup)

        func snapshot(terminalGroupsCollapsed: Bool) -> WarrenSemanticSnapshot {
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: [],
                groups: [],
                terminalGroups: [group],
                workspaceActivitySummaries: [:],
                tree: .constant(WarrenDesktopSidebarTreeState(
                    terminalGroupsCollapsed: terminalGroupsCollapsed
                )),
                isCollapsed: false,
                selection: nil,
                deletingProjectIDs: [],
                deletingWorkspaceIDs: [],
                endpointCapabilities: .local,
                isInteractionDisabled: false,
                onAddProject: {},
                onRequestTaskCreate: {},
                onFocusTask: { _ in },
                onRequestTerminalGroupCreate: {},
                onRequestTerminalGroupEdit: { _ in },
                onAction: { _ in },
                onRequestRename: { _ in },
                onRequestDeletion: { _ in }
            )
            .frame(width: 420, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return recorder.snapshot()
        }

        let terminalGroupID = "terminal-group.\(terminalGroup.id.description)"
        XCTAssertNotNil(snapshot(terminalGroupsCollapsed: false).node(id: terminalGroupID))
        XCTAssertNil(snapshot(terminalGroupsCollapsed: true).node(id: terminalGroupID))
    }

    func testProjectionActiveWorkspaceIDs() {
        let host = WarrenDomain.Host(name: "TestHost")
        let project = Project(hostID: host.id, name: "Repo", rootPath: "/repo")
        let activeWorkspace = Workspace(projectID: project.id, name: "active", path: "/repo/active")
        let idleWorkspace = Workspace(projectID: project.id, name: "idle", path: "/repo/idle")
        let exitedWorkspace = Workspace(projectID: project.id, name: "exited", path: "/repo/exited")

        let activeSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: activeWorkspace.id,
            title: "active-shell",
            state: .attached
        )
        let exitedSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: exitedWorkspace.id,
            title: "exited-shell",
            state: .exited
        )

        let projection = WarrenDesktopProjection(
            host: host,
            groups: [
                WarrenDesktopProjectGroup(
                    project: project,
                    workspaces: [activeWorkspace, idleWorkspace, exitedWorkspace]
                ),
            ],
            sessions: [activeSession, exitedSession]
        )

        XCTAssertEqual(projection.activeWorkspaceIDs, Set([activeWorkspace.id]))
    }

    @MainActor
    func testSidebarRowsFiltersInactiveWorkspacesWhenShowsActiveOnlyIsTrue() {
        let host = WarrenDomain.Host(name: "TestHost")
        let project = Project(hostID: host.id, name: "Repo", rootPath: "/repo")
        let activeWorkspace = Workspace(projectID: project.id, name: "active", path: "/repo/active")
        let idleWorkspace = Workspace(projectID: project.id, name: "idle", path: "/repo/idle")

        let groups = [WarrenDesktopProjectGroup(project: project, workspaces: [activeWorkspace, idleWorkspace])]
        let recorder = WarrenSemanticRecorder()

        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: groups,
            terminalGroups: [],
            workspaceActivitySummaries: [:],
            activeWorkspaceIDs: [activeWorkspace.id],
            tree: .constant(WarrenDesktopSidebarTreeState(
                expandedProjectIDs: [project.id],
                showsActiveOnly: true
            )),
            isCollapsed: false,
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onRequestTerminalGroupCreate: {},
            onRequestTerminalGroupEdit: { _ in },
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        XCTAssertNotNil(snapshot.node(id: "workspace.project-list.\(activeWorkspace.id.description)"))
        XCTAssertNil(snapshot.node(id: "workspace.project-list.\(idleWorkspace.id.description)"))
    }

    func testSidebarRowsKeepsTaskGroupsWhenShowsActiveOnlyIsTrue() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "Repo", rootPath: "/repo")
        let idleWorkspace = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "idle",
            path: "/repo/idle"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [project],
            workspaces: [idleWorkspace]
        )
        let recorder = WarrenSemanticRecorder()

        let rows = WarrenDesktopSidebarRows(
            taskGroups: projection.taskGroups,
            groups: projection.groups,
            terminalGroups: [],
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeWorkspaceIDs: [],
            tree: .constant(WarrenDesktopSidebarTreeState(
                expandedTaskIDs: [task.id],
                showsActiveOnly: true
            )),
            isCollapsed: false,
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onRequestTerminalGroupCreate: {},
            onRequestTerminalGroupEdit: { _ in },
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        let taskNode = snapshot.node(id: "task.\(task.id.description)")
        XCTAssertEqual(taskNode?.label, "Task Delivery")
        XCTAssertEqual(taskNode?.value, "0 workspaces · Expanded")
        XCTAssertNil(snapshot.node(id: "workspace.task-list.\(idleWorkspace.id.description)"))
    }

    func testTaskRowExposesProjectStyleSecondaryActions() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let recorder = WarrenSemanticRecorder()
        let row = WarrenDesktopTaskRow(
            task: task,
            workspaceCount: 2,
            availableProjectGroups: [],
            isCollapsed: false,
            isExpanded: false,
            isInteractionDisabled: false,
            onToggleExpansion: {},
            onAttachWorkspace: { _ in },
            onCreateWorkspace: { _ in },
            onRename: {},
            onTogglePin: {},
            onDelete: {}
        )
        .frame(width: 420, height: WarrenLayoutMetrics.sidebarProjectRowHeight)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: row)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 420,
            height: WarrenLayoutMetrics.sidebarProjectRowHeight
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        XCTAssertEqual(
            snapshot.node(id: "task.\(task.id.description).toggle")?.label,
            "Expand task Delivery"
        )
        XCTAssertEqual(
            snapshot.node(id: "task.\(task.id.description).new-workspace")?.label,
            "Add workspace to task Delivery"
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

@MainActor
private final class PausingTaskCreationFake {
    private let callExpectations: [XCTestExpectation]
    private var continuations: [CheckedContinuation<TaskID, Error>] = []
    private(set) var requests: [WarrenDesktopTaskCreationRequest] = []

    var callCount: Int { requests.count }

    init(callExpectations: [XCTestExpectation]) {
        self.callExpectations = callExpectations
    }

    func create(_ request: WarrenDesktopTaskCreationRequest) async throws -> TaskID {
        requests.append(request)
        callExpectations[requests.count - 1].fulfill()
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeed(_ taskID: TaskID) {
        continuations.removeFirst().resume(returning: taskID)
    }

    func fail(_ error: Error) {
        continuations.removeFirst().resume(throwing: error)
    }
}
