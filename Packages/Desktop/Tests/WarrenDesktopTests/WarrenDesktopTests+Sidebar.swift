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
    /// Indent is width taken from row titles, so no tier spends a step: every
    /// row is told apart by weight, brightness, glyph, or a second line.
    func testNoSidebarTierSpendsAnIndentStep() {
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
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.session,
            WarrenDesktopSidebarIndent.workspace,
            "A Session says it is inside a workspace by its icon and second line"
        )
    }
    /// A projection copy that only changes a Session's activity lines has to
    /// carry everything else, or an Agent step would erase arrangements the
    /// Host owns.
    func testSessionActivityLinesCopyKeepsTheRestOfTheProjection() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.projection.groups[0].workspaces[0].id
        let session = fixture.projection.activeSessions(in: workspaceID)[0]
        let group = PaneGroup(
            hostID: fixture.host.id,
            workspaceID: workspaceID,
            name: "main",
            tree: .leaf(sessionID: session.id),
            revision: 1
        )
        let arranged = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.projection.groups,
            sessions: fixture.projection.sessions,
            tabs: fixture.projection.tabs,
            paneGroups: [group],
            unreadNoticeCount: 3
        )
        let updated = arranged.withSessionActivityLines(
            currentStep: "Running git status",
            primaryLine: "Running git status",
            lastActivity: "Ran swift test",
            for: session.id
        )
        XCTAssertEqual(updated.paneGroups, [group], "A step update must not drop the arrangements")
        XCTAssertEqual(updated.unreadNoticeCount, 3)
        XCTAssertEqual(
            updated.session(id: session.id)?.currentStep,
            "Running git status"
        )
        XCTAssertEqual(updated.session(id: session.id)?.lastActivity, "Ran swift test")
        XCTAssertEqual(
            arranged.withSessionActivityLines(
                currentStep: session.currentStep,
                primaryLine: session.primaryLine,
                lastActivity: session.lastActivity,
                for: session.id
            ),
            arranged,
            "Nothing changed means no new projection"
        )
    }
    /// Folded groups pack into a compact list: each knows whether the group
    /// above it is folded, so only an open group draws the hairline.
    func testTreeGroupNeighboursReportTheFoldAbove() {
        struct Group: Identifiable { let id: String; let folded: Bool }
        let groups = [
            Group(id: "open", folded: false),
            Group(id: "quiet", folded: true),
            Group(id: "nexo", folded: true),
            Group(id: "last", folded: true),
        ]
        let neighbours = groups.map {
            WarrenDesktopTreeGroupNeighbours(of: $0, in: groups, isFolded: \.folded)
        }
        XCTAssertEqual(neighbours.map(\.isFirst), [true, false, false, false])
        XCTAssertEqual(
            neighbours.map(\.followsFolded),
            [false, false, true, true],
            "Only a folded group under another folded group skips the hairline"
        )
        XCTAssertEqual(neighbours.map(\.isLast), [false, false, false, true])
        XCTAssertEqual(
            2 * WarrenDesktopSidebarMetrics.foldedGroupInset,
            2,
            "Two folded neighbours sit 2pt apart"
        )
    }
    /// The other Hosts' tiles overlap 7pt at rest and fan out 24pt apart,
    /// raised 3pt, once lifted; the one under the pointer rises 3pt more and
    /// grows by 15%.
    func testOtherHostStackFansOutWhenLifted() {
        typealias Metrics = WarrenDesktopSidebarHostStackMetrics
        XCTAssertEqual(Metrics.tileOffset(index: 2, isLifted: false, hotIndex: nil), CGSize(width: 14, height: 0))
        XCTAssertEqual(Metrics.tileOffset(index: 2, isLifted: true, hotIndex: 1), CGSize(width: 48, height: -3))
        XCTAssertEqual(Metrics.tileOffset(index: 1, isLifted: true, hotIndex: 1), CGSize(width: 24, height: -6))
        XCTAssertEqual(Metrics.tileScale(index: 1, isLifted: true, hotIndex: 1), 1.15)
        XCTAssertEqual(Metrics.tileScale(index: 1, isLifted: false, hotIndex: 1), 1)
        XCTAssertEqual(Metrics.tileIndex(atX: 30, tileCount: 3), 1)
        XCTAssertNil(Metrics.tileIndex(atX: 22, tileCount: 3), "The gap between tiles names no Host")
        XCTAssertNil(Metrics.tileIndex(atX: 80, tileCount: 3))
    }
    /// The panel names where each Host is reached and whether it is online,
    /// and only an actionable Session lights the foot's dot.
    func testOtherHostDescribesItsAddressAndState() {
        XCTAssertEqual(WarrenDesktopSidebarOtherHost.address(fromDetail: "SSH · dev@fsn1"), "dev@fsn1")
        XCTAssertEqual(WarrenDesktopSidebarOtherHost.address(fromDetail: "10.0.4.12"), "10.0.4.12")
        XCTAssertNil(WarrenDesktopSidebarOtherHost.address(fromDetail: "  "))

        let server = WarrenDesktopSidebarOtherHost(
            id: "fsn1", name: "fsn1-dev", address: "10.0.4.12", marks: [.working]
        )
        XCTAssertEqual(server.panelSubtitle, "Server · 10.0.4.12")
        XCTAssertEqual(server.pickDetail, "10.0.4.12")
        XCTAssertEqual(server.initial, "f")
        XCTAssertFalse(server.needsAttention)

        let laptop = WarrenDesktopSidebarOtherHost(
            id: "mba", name: "MBA", isLocal: true, address: "MacBook Air", marks: [.inputNeeded]
        )
        XCTAssertEqual(laptop.panelSubtitle, "Local · MacBook Air")
        XCTAssertEqual(laptop.initial, "m")
        XCTAssertTrue(laptop.needsAttention)

        let offline = WarrenDesktopSidebarOtherHost(
            id: "tenc", name: "tenc_sh", address: "tenc", isOnline: false
        )
        XCTAssertEqual(offline.panelSubtitle, "Offline · tenc")
        XCTAssertEqual(offline.pickDetail, "offline")

        // An SSH alias named for its machine does not say its name twice.
        let alias = WarrenDesktopSidebarOtherHost(id: "beelink", name: "beelink", address: "beelink")
        XCTAssertNil(alias.pickDetail)
        XCTAssertEqual(alias.panelSubtitle, "Server")
    }
    /// The Host row says where the Host is, then what it is; while it is not
    /// connected, it says that instead.
    func testSidebarHostSubtitleNamesPlaceThenDetailOrConnection() {
        XCTAssertEqual(
            WarrenDesktopSidebarHostIdentity.subtitle(
                isLocal: true,
                detail: "Mac Studio",
                connectionState: .attached
            ),
            "Local · Mac Studio"
        )
        XCTAssertEqual(
            WarrenDesktopSidebarHostIdentity.subtitle(
                isLocal: false,
                detail: "  ",
                connectionState: .attached
            ),
            "Remote"
        )
        XCTAssertEqual(
            WarrenDesktopSidebarHostIdentity.subtitle(
                isLocal: false,
                detail: "fsn1-dev",
                connectionState: .failed
            ),
            "Remote · Connection failed"
        )
    }
    /// A project keeps its avatar colour across launches and reorderings, so
    /// the index comes from its ID and nothing else.
    func testProjectAvatarTintIsStablePerIdentity() {
        let first = WarrenDesktopProjectAvatar.stableIndex(for: "project-a", count: 5)
        XCTAssertEqual(first, WarrenDesktopProjectAvatar.stableIndex(for: "project-a", count: 5))
        XCTAssertTrue((0..<5).contains(first))
        XCTAssertEqual(WarrenDesktopProjectAvatar.stableIndex(for: "project-a", count: 0), 0)
    }
    /// The right sidebar falls back to an available page when the one a
    /// Workspace remembered is gone (the editor on a remote Host, say).
    func testRightSidebarTabResolutionFallsBackToAnAvailablePage() {
        XCTAssertEqual(
            WarrenDesktopRightSidebarTab.resolve(
                .editor,
                inspectorAvailable: true,
                editorAvailable: false
            ),
            .inspector(.changes)
        )
        XCTAssertEqual(
            WarrenDesktopRightSidebarTab.resolve(
                .inspector(.history),
                inspectorAvailable: true,
                editorAvailable: true
            ),
            .inspector(.history)
        )
        XCTAssertEqual(
            WarrenDesktopRightSidebarTab.resolve(nil, inspectorAvailable: false, editorAvailable: true),
            .editor
        )
        XCTAssertNil(
            WarrenDesktopRightSidebarTab.resolve(nil, inspectorAvailable: false, editorAvailable: false)
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
                    projectGroups: [localGroup],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(localGroup.workspaces.map(\.id))
                ),
                WarrenDesktopSidebarHostProjection(
                    endpointID: "remote",
                    endpointLabel: "Remote",
                    host: remoteHost,
                    connectionState: .attached,
                    projectGroups: [remoteGroup],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(remoteGroup.workspaces.map(\.id))
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
        // The tab bar names the list; the Host rows no longer carry a
        // Projects heading of their own.
        XCTAssertNil(initialSnapshot.node(id: "sidebar.projects.hosts"))
        guard let localHostHeader = initialSnapshot.node(id: "host.local.toggle") else {
            XCTFail("Multi-host sidebar must expose its Host headers")
            return
        }
        XCTAssertEqual(
            localHostHeader.frame.height,
            Double(WarrenLayoutMetrics.sidebarHostHeaderHeight),
            accuracy: 0.01
        )
        // Every project starts open; folding one Host's copy leaves the other
        // Host's copy of the same ID open.
        XCTAssertTrue(initialSnapshot.node(id: localID)?.value?.contains("Expanded") == true)
        XCTAssertTrue(initialSnapshot.node(id: remoteID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(initialSnapshot.node(id: localWorkspaceID))
        XCTAssertNotNil(initialSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "\(remoteID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        let remoteFoldedSnapshot = recorder.snapshot()
        XCTAssertNotNil(remoteFoldedSnapshot.node(id: localWorkspaceID))
        XCTAssertNil(remoteFoldedSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "\(remoteID).toggle")
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
        XCTAssertEqual(
            recorder.snapshot().node(id: "host.local.toggle")?.value,
            "Collapsed, 1 project"
        )
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
                    projectGroups: [group],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(group.workspaces.map(\.id))
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
        XCTAssertNotNil(recorder.snapshot().node(id: workspaceID))

        try recorder.perform(.press, on: projectID)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertTrue(state.selectedResources.isEmpty)
        XCTAssertTrue(snapshot.node(id: projectID)?.value?.contains("Collapsed") == true)
        XCTAssertNil(snapshot.node(id: workspaceID))
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
            projectGroups: [remoteGroup],
            // Each worktree has a Session, so the project keeps its full rows.
            activeWorkspaceIDs: Set(remoteGroup.workspaces.map(\.id))
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
            Double(
                WarrenDesktopSidebarMetrics.groupIconSize
                    + WarrenDesktopSidebarMetrics.groupIconSpacing
            ),
            accuracy: 0.01,
            "The starter row sits in the tree's text column, not on the Host heading's edge"
        )
        XCTAssertNil(initialSnapshot.node(id: localWorkspaceID))
        // Projects start open, so the other Host's copy is listed too.
        XCTAssertNotNil(recorder.snapshot().node(id: remoteWorkspaceID))

        state.hosts = [
            WarrenDesktopSidebarHostProjection(
                endpointID: "local",
                endpointLabel: "Local",
                host: localHost,
                connectionState: .attached,
                projectGroups: [localGroup],
                // Each worktree has a Session, so the project keeps its full rows.
                activeWorkspaceIDs: Set(localGroup.workspaces.map(\.id))
            ),
            remoteProjection,
        ]
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.node(id: localProjectID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(snapshot.node(id: localWorkspaceID))
        XCTAssertNotNil(snapshot.node(id: remoteWorkspaceID))
    }
    /// A connected Host this window cannot write to and that holds nothing is
    /// one line: the heading says "no projects" and there is no disclosure to
    /// offer. The active Host keeps its toggle.
    @MainActor
    func testBackgroundHostWithNoProjectsDrawsOneQuietRow() throws {
        let activeHost = Host(name: "Local Mac")
        let idleHost = Host(name: "Idle Server")
        let project = Project(
            hostID: activeHost.id,
            name: "Project",
            rootPath: "/tmp/project"
        )
        let state = SidebarHostRowsTestState(
            hosts: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: activeHost,
                    connectionState: .attached,
                    projectGroups: [
                        WarrenDesktopProjectGroup(project: project, workspaces: []),
                    ]
                ),
                WarrenDesktopSidebarHostProjection(
                    endpointID: "idle",
                    endpointLabel: "Idle",
                    host: idleHost,
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

        let snapshot = recorder.snapshot()
        XCTAssertNotNil(snapshot.node(id: "host.local.toggle"))
        XCTAssertNil(snapshot.node(id: "host.idle.toggle"))
        XCTAssertNotNil(snapshot.node(id: "host.idle.empty"))
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
                    projectGroups: [group],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(group.workspaces.map(\.id))
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
        XCTAssertTrue(initialSnapshot.node(id: projectID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(initialSnapshot.node(id: workspaceID))

        try recorder.perform(.press, on: "\(projectID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertNil(recorder.snapshot().node(id: workspaceID))
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
            canUseEmbeddedBrowser: true,
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
        XCTAssertTrue(endpoint.capabilities.canUseEmbeddedBrowser)
        XCTAssertTrue(endpoint.capabilities.canOpenExternalIDE)
        XCTAssertFalse(endpoint.capabilities.canAddProject)
    }
    // The browser runtime is a Host-launched Chromium, so a remote Host never
    // gets it however capable it is: the capability is not a settings toggle.
    func testRemoteEndpointsNeverAdvertiseTheEmbeddedBrowser() {
        XCTAssertFalse(WarrenDesktopEndpointCapabilities.remote.canUseEmbeddedBrowser)
        XCTAssertTrue(WarrenDesktopEndpointCapabilities.local.canUseEmbeddedBrowser)
        XCTAssertFalse(WarrenDesktopEndpointCapabilities.remote.canUseEmbeddedEditor)
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
    func testRemoteEndpointHidesLocalOnboardingAndEditorControls() throws {
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

        var nodeIDs = Set(recorder.snapshot().nodes.map(\.id))
        XCTAssertFalse(nodeIDs.contains("onboarding.add-project"))
        XCTAssertFalse(nodeIDs.contains("onboarding.import-superset"))
        // A remote Host has no embedded editor, so the right sidebar has no
        // Editor page and nothing to open it with.
        XCTAssertFalse(nodeIDs.contains("right-sidebar.tab.editor"))
        if nodeIDs.contains("right-sidebar.toggle") {
            try recorder.perform(.press, on: "right-sidebar.toggle")
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            nodeIDs = Set(recorder.snapshot().nodes.map(\.id))
        }
        XCTAssertFalse(nodeIDs.contains("right-sidebar.tab.editor"))
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
            persistedCollapses: [],
            autoCollapse: .projectsExcept(projectID)
        ))
        XCTAssertFalse(WarrenSidebarDragPresentation.isExpanded(
            otherProjectID,
            persistedCollapses: [],
            autoCollapse: .projectsExcept(projectID)
        ))
        XCTAssertFalse(WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedCollapses: [otherProjectID],
            autoCollapse: .allProjects
        ))
    }
    func testSidebarStateUsesSupersetSnapAndRestoreValues() {
        var state = WarrenDesktopSidebarState()
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)
        XCTAssertFalse(state.isCollapsed)

        // A drag below the snap threshold collapses the rail to nothing, but
        // the dragged-to width is kept so the peek reveals it unchanged.
        state.setWidth(119)
        XCTAssertTrue(state.isCollapsed)
        XCTAssertEqual(state.renderedWidth, WarrenLayoutMetrics.sidebarCollapsedWidth)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarCollapsedWidth, 0)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)

        state.toggleCollapsed()
        XCTAssertFalse(state.isCollapsed)
        XCTAssertEqual(state.renderedWidth, state.width)

        state.setWidth(399)
        XCTAssertEqual(state.width, 399)
        state.setWidth(401)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarMaximumWidth)

        // The handle's double-click reset returns the default expanded rail
        // even when the drag ran into the collapse snap.
        state.setWidth(WarrenLayoutMetrics.sidebarSnapThreshold - 1)
        XCTAssertTrue(state.isCollapsed)
        state.restoreExpanded()
        XCTAssertFalse(state.isCollapsed)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)
        XCTAssertEqual(state.renderedWidth, WarrenLayoutMetrics.sidebarExpandedWidth)
    }
    /// The width policy and `setWidth` both existed from the start, but nothing
    /// ever called them: the rail was pinned at one width with the collapse button
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
        XCTAssertEqual(
            node?.value,
            "\(Int(WarrenLayoutMetrics.sidebarExpandedWidth)) points"
        )

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
    /// During a drag the edge holds at the minimum instead of collapsing, and
    /// the drag's distance below it is the pull the indicator shows.
    func testSidebarDragHoldsAtTheMinimumAndMeasuresThePull() {
        let minimum = WarrenLayoutMetrics.sidebarMinimumWidth
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: 300), 300)
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: minimum - 60), minimum)
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: 10), minimum, "A drag never hides the rail mid-way")
        XCTAssertEqual(
            WarrenDesktopSidebarResize.liveWidth(for: WarrenLayoutMetrics.sidebarMaximumWidth + 50),
            WarrenLayoutMetrics.sidebarMaximumWidth
        )
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: .nan), WarrenLayoutMetrics.sidebarExpandedWidth)

        XCTAssertEqual(WarrenDesktopSidebarResize.overshoot(for: minimum - 40), 40)
        XCTAssertEqual(WarrenDesktopSidebarResize.overshoot(for: minimum + 40), 0)
        XCTAssertEqual(WarrenDesktopSidebarResize.overshoot(for: .infinity), 0)
    }
    /// Letting go below the hide threshold hides the rail through the stored
    /// policy's own collapse; anywhere else it stays at the minimum. The two
    /// decisions have to agree, because the release hands the proposal to it.
    func testSidebarReleaseHidesOnlyBelowTheThreshold() {
        let threshold = WarrenLayoutMetrics.sidebarSnapThreshold
        XCTAssertTrue(WarrenDesktopSidebarResize.releaseHides(threshold - 1))
        XCTAssertFalse(WarrenDesktopSidebarResize.releaseHides(threshold))
        XCTAssertFalse(WarrenDesktopSidebarResize.releaseHides(WarrenLayoutMetrics.sidebarMinimumWidth - 1))
        XCTAssertFalse(WarrenDesktopSidebarResize.releaseHides(.nan))
        for proposed: CGFloat in [0, 60, threshold - 0.5, threshold, 180, 220, 300, 500] {
            XCTAssertEqual(
                WarrenDesktopSidebarResize.releaseHides(proposed),
                WarrenLayoutMetrics.sidebarWidth(for: proposed) == WarrenLayoutMetrics.sidebarCollapsedWidth,
                "Release and policy disagree at \(proposed)"
            )
        }

        // A drag into the hold and back out leaves the rail at the minimum.
        var held = WarrenDesktopSidebarState()
        held.setWidth(WarrenDesktopSidebarResize.liveWidth(for: threshold + 20))
        XCTAssertFalse(held.isCollapsed)
        XCTAssertEqual(held.width, WarrenLayoutMetrics.sidebarMinimumWidth)

        // A drag that lets go below the threshold hides it.
        var hidden = WarrenDesktopSidebarState()
        hidden.setWidth(WarrenDesktopSidebarResize.liveWidth(for: threshold - 20))
        XCTAssertFalse(hidden.isCollapsed, "Still held while the pointer is down")
        if WarrenDesktopSidebarResize.releaseHides(threshold - 20) {
            hidden.setWidth(threshold - 20)
        }
        XCTAssertTrue(hidden.isCollapsed)
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
    func testProjectsSectionLeavesTaskWorkspacesToTheirTask() throws {
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
        var selectedTaskID: TaskID?
        var selectedWorkspaceID: WorkspaceID?
        var taskTree = WarrenDesktopSidebarTreeState(
            tasksCollapsed: true
        )
        func mount(_ tab: WarrenDesktopSidebarTab) -> WarrenSemanticSnapshot {
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [WarrenDesktopTaskGroup(task: task, workspaces: [assigned])],
            groups: groups,
            workspaceActivitySummaries: [:],
            // A Session keeps the project out of the inactive list.
            activeWorkspaceIDs: [available.id],
            tree: .constant(WarrenDesktopSidebarTreeState(selectedTab: tab)),
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
        return recorder.snapshot()
        }

        var snapshot = mount(.projects)
        // A Task's Workspace is listed under the Task only: the Projects
        // section neither repeats it nor links back to the Task.
        XCTAssertNil(snapshot.node(id: "workspace.project-list.\(assigned.id.description)"))
        XCTAssertNil(snapshot.node(id: "workspace-task.project-list.\(assigned.id.description)"))
        _ = selectedTaskID
        _ = selectedWorkspaceID

        let availableProjectNode = snapshot.node(
            id: "workspace.project-list.\(available.id.description)"
        )
        XCTAssertEqual(availableProjectNode?.label, "Workspace available")
        XCTAssertFalse(availableProjectNode?.value?.contains("Belongs to task") == true)
        XCTAssertNil(snapshot.node(id: "workspace-task.project-list.\(available.id.description)"))

        snapshot = mount(.tasks)
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
            WarrenDesktopSidebar.workspaceScrollTarget(for: assigned, tab: .tasks),
            "workspace.task-list.\(assigned.id.description)"
        )
        XCTAssertEqual(
            WarrenDesktopSidebar.workspaceScrollTarget(for: assigned, tab: .projects),
            "workspace.project-list.\(assigned.id.description)"
        )
        XCTAssertEqual(
            WarrenDesktopSidebar.workspaceScrollTarget(for: available, tab: .tasks),
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
    func testWorkspaceEditorStateIsKeyedByHostAndSurvivesRoundTrip() {
        let suiteName = "warren-workspace-editor-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceID = WorkspaceID()

        // Two Hosts can issue equal Workspace UUIDs, so the same ID under a
        // different Endpoint must be a different record rather than the same one.
        let local = WarrenDesktopWorkspaceEditorState(
            hostId: "local",
            workspaceId: workspaceID,
            enabled: true,
            lastRelativeFile: "Sources/App.swift",
            lastLine: 42,
            lastColumn: 1
        )
        let remote = WarrenDesktopWorkspaceEditorState(
            hostId: "remote",
            workspaceId: workspaceID,
            enabled: true,
            lastRelativeFile: "other.swift"
        )
        WarrenDesktopWorkspaceEditorStateStore.save(
            [
                WarrenDesktopWorkspaceEditorStateStore.key(for: local): local,
                WarrenDesktopWorkspaceEditorStateStore.key(for: remote): remote,
            ],
            defaults: defaults
        )

        let restored = WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults)
        XCTAssertEqual(restored.count, 2)
        let localKey = WarrenDesktopWorkspaceEditorKey(
            hostId: "local",
            workspaceId: workspaceID
        )
        XCTAssertEqual(restored[localKey]?.lastRelativeFile, "Sources/App.swift")
        XCTAssertEqual(restored[localKey]?.lastLine, 42)
        XCTAssertEqual(
            restored[
                WarrenDesktopWorkspaceEditorKey(hostId: "remote", workspaceId: workspaceID)
            ]?.lastRelativeFile,
            "other.swift"
        )
    }
    func testEditorActivityOverlayWidensOnlyItsOwnHost() {
        let sessionActive = WorkspaceID()
        let editorOnly = WorkspaceID()
        let otherHostEditor = WorkspaceID()
        var states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState] = [:]
        for (host, workspace) in [("local", editorOnly), ("remote", otherHostEditor)] {
            let state = WarrenDesktopWorkspaceEditorState(
                hostId: host,
                workspaceId: workspace,
                enabled: true
            )
            states[WarrenDesktopWorkspaceEditorStateStore.key(for: state)] = state
        }
        let overlay = WarrenDesktopEditorActivityOverlay(states: states)

        XCTAssertEqual(
            overlay.activeWorkspaceIDs([sessionActive], hostId: "local"),
            [sessionActive, editorOnly]
        )
        // A Workspace marked on another Endpoint must not read as active here.
        XCTAssertFalse(
            overlay.activeWorkspaceIDs([sessionActive], hostId: "local")
                .contains(otherHostEditor)
        )
        XCTAssertTrue(overlay.isEditorMarked(otherHostEditor, hostId: "remote"))
        XCTAssertFalse(overlay.isEditorMarked(otherHostEditor, hostId: "local"))
        // An unmarked Workspace with no Session stays filtered.
        XCTAssertEqual(
            WarrenDesktopEditorActivityOverlay().activeWorkspaceIDs([], hostId: "local"),
            []
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
        let token = UUID()

        actions(.addProject)
        actions(.importSuperset)
        actions(.requestNewWorkspace(projectID))
        actions(.requestNewWorkspace(projectID, taskID: taskID))
        actions(.selectWorkspace(workspaceID))
        actions(.openSession(sessionID))
        actions(.deleteSession(sessionID))
        actions(.moveSession(sessionID, to: .workspace(workspaceID)))
        actions(.requestNewSession(workspaceID, token: token))
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
                .requestNewSession(workspaceID, token: token),
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
    func testTabTitleNamesAShellAtTheWorktreeRootByItsShell() {
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
            "zsh"
        )
        XCTAssertEqual(
            WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: workspace.path)
                .runningCommand,
            ""
        )
    }
    func testSidebarSessionTitleNeverRepeatsTheRunningCommand() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            kind: .shell,
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev",
            workingDirectory: "/Users/me/Workspace/warren",
            shellState: WarrenDesktopShellState(
                atPrompt: false,
                runningCommand: "npm run dev",
                shellName: "zsh"
            )
        )
        let resolved = WarrenDesktopTabTitle.sessionTitle(
            for: session,
            worktreeRoot: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(resolved.title, "zsh")
        XCTAssertEqual(resolved.runningCommand, "npm run dev")
    }
    func testSidebarSessionTitleNamesAShellAtTheWorktreeRoot() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            kind: .shell,
            runtimeProcess: "zsh",
            runtimeCommandLine: "-zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: "/Users/me/Workspace/warren").title,
            "zsh"
        )
    }
    func testSidebarSessionTitlePrefersAUserSetName() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            customTitle: "My Agent",
            kind: .shell,
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: "/Users/me/Workspace/warren").title,
            "My Agent"
        )
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
    /// The rollup used to reduce to the lifecycle half of the status before it
    /// ever reached a row, so a collapsed Workspace could not say whether the
    /// Agent inside it wanted an approval, wanted an answer, or had merely
    /// stopped. Every one of those drew the same marker.
    func testWorkspaceRollupKeepsWhatTheHostIsAskingFor() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let working = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "working",
            title: "Working",
            kind: .codex,
            activity: .working
        )
        let awaitingApproval = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "approval",
            title: "Approval",
            kind: .claude,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Run rm -rf build?")
            )
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [working, awaitingApproval]
        )

        XCTAssertEqual(projection.mark(in: workspaceID), .approvalNeeded)
        XCTAssertEqual(
            projection.workspaceActivitySummaries[workspaceID]?.mark,
            .approvalNeeded
        )
        // The lifecycle accessors still answer as before, so a caller that only
        // compares states is unaffected by the richer rollup.
        XCTAssertEqual(projection.activity(in: workspaceID), .blocked)
    }
    /// Opening a Session keeps its workspace as the navigation scope, so both
    /// rows match the selection. Only the leaf may claim it: it is the row the
    /// user clicked and the more specific answer to "where am I". The workspace
    /// states containment instead, so the rail still says which workspace is
    /// live without stealing the highlight from the row below it.
    /// A project with one worktree has nothing to choose between, so it holds
    /// that worktree's Sessions directly and names the branch beside itself.
    /// A second worktree brings the worktree rows back.
    @MainActor
    func testProjectWithOneWorktreeHoldsItsSessionsDirectly() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let main = Workspace(projectID: project.id, name: "main", path: "/tmp/api", branch: "main")
        let feature = Workspace(projectID: project.id, name: "feature", path: "/tmp/api-feature")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: main.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )

        func nodes(workspaces: [Workspace]) -> [String: WarrenSemanticNode] {
            let projection = WarrenDesktopProjection(
                host: host,
                projects: [project],
                workspaces: workspaces,
                sessions: [session]
            )
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: [],
                groups: projection.groups,
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
                activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState()),
                selection: nil,
                deletingProjectIDs: [],
                deletingWorkspaceIDs: [],
                endpointCapabilities: .local,
                isInteractionDisabled: false,
                onAddProject: {},
                onRequestTaskCreate: {},
                onFocusTask: { _ in },
                onAction: { _ in },
                onRequestRename: { _ in },
                onRequestDeletion: { _ in }
            )
            .frame(width: 300, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let mainRowID = "workspace.project-list.\(main.id.description)"
        let leafID = "workspace-session.project-list.\(main.id.description).\(session.id.description)"

        let solo = nodes(workspaces: [main])
        XCTAssertNil(solo[mainRowID], "One worktree draws no worktree row")
        XCTAssertNotNil(solo[leafID], "Its Sessions hang under the project")

        // A second worktree with no Session is one idle worktree, not a
        // list, so it is drawn as a row beside the live one.
        let pair = nodes(workspaces: [main, feature])
        XCTAssertNotNil(pair[mainRowID])
        XCTAssertNotNil(pair["workspace.project-list.\(feature.id.description)"])
        XCTAssertNil(pair["project-idle-worktrees.\(project.id.description)"])
        XCTAssertNotNil(pair[leafID])
    }
    /// The multi-Host sections hold a one-worktree project's Sessions directly
    /// too, on the current Host and on a background one alike.
    @MainActor
    func testHostSectionProjectWithOneWorktreeHoldsItsSessionsDirectly() throws {
        let host = WarrenDomain.Host(name: "Local")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "main", path: "/tmp/api", branch: "main")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        func section(_ endpointID: String) -> WarrenDesktopSidebarHostProjection {
            WarrenDesktopSidebarHostProjection(
                endpointID: endpointID,
                endpointLabel: endpointID.capitalized,
                host: host,
                connectionState: .attached,
                projectGroups: [WarrenDesktopProjectGroup(project: project, workspaces: [workspace])],
                activeSessionsByWorkspaceID: [workspace.id: [session]],
                activeWorkspaceIDs: [workspace.id]
            )
        }
        let state = SidebarHostRowsTestState(hosts: [section("local"), section("remote")], selection: nil)
        let recorder = WarrenSemanticRecorder()
        let root = SidebarHostRowsTestHarness(
            state: state,
            activeEndpointID: "local",
            workspaceDisplayMode: .rich
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let ids = Set(recorder.snapshot().nodes.map(\.id))
        for endpointID in ["local", "remote"] {
            XCTAssertFalse(
                ids.contains("workspace.host.\(endpointID).\(workspace.id.description)"),
                "One worktree draws no worktree row on \(endpointID)"
            )
            XCTAssertTrue(
                ids.contains(
                    "workspace-session.host.\(endpointID).\(workspace.id.description).\(session.id.description)"
                ),
                "Its Sessions hang under the project on \(endpointID)"
            )
        }
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
        // A second worktree, so the project draws its worktree rows rather than
        // holding the only one's Sessions directly.
        let other = Workspace(projectID: project.id, name: "main", path: "/tmp/b")
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
                    WarrenDesktopProjectGroup(project: project, workspaces: [workspace, other]),
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
                    mode: mode
                ) || mode.sidebarListsSessions,
                "\(mode.rawValue) hid the bar that owns its Session list"
            )
        }
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
    func testCollapsedHostSummaryCountsProjectsAndKeepsTheMostActionableMark() {
        let host = Host(name: "vps-01")
        let project = Project(hostID: host.id, name: "api", rootPath: "/tmp/api")
        let other = Project(hostID: host.id, name: "web", rootPath: "/tmp/web")
        let working = Workspace(projectID: project.id, name: "main", path: "/tmp/api")
        let waiting = Workspace(projectID: other.id, name: "main", path: "/tmp/web")
        let exited = Workspace(projectID: other.id, name: "old", path: "/tmp/web-old")
        let projection = WarrenDesktopSidebarHostProjection(
            endpointID: "prod",
            endpointLabel: "Production",
            host: host,
            connectionState: .attached,
            projectGroups: [
                .init(project: project, workspaces: [working]),
                .init(project: other, workspaces: [waiting, exited]),
            ],
            workspaceActivitySummaries: [
                working.id: .init(mark: .working, activeTabCount: 1),
                waiting.id: .init(mark: .approvalNeeded),
                exited.id: .init(mark: .exited),
            ]
        )

        let summary = WarrenDesktopSidebarHostSummary(projection)
        XCTAssertEqual(summary.countLabel, "2 projects")
        XCTAssertEqual(summary.mark, .approvalNeeded)

        let quiet = WarrenDesktopSidebarHostSummary(WarrenDesktopSidebarHostProjection(
            endpointID: "prod",
            endpointLabel: "Production",
            host: host,
            connectionState: .attached,
            projectGroups: [.init(project: other, workspaces: [exited])],
            workspaceActivitySummaries: [exited.id: .init(mark: .exited)]
        ))
        XCTAssertEqual(quiet.countLabel, "1 project")
        XCTAssertNil(quiet.mark)
    }
    func testSidebarTreePersistenceIsPerScopeAndRoundTrips() throws {
        let suiteName = "WarrenDesktopTests.sidebarTree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = WarrenDesktopSidebarTreeState(
            collapsedTaskIDs: [TaskID(), TaskID()],
            collapsedProjectIDs: [ProjectID(), ProjectID()],
            collapsedWorkspaceIDs: [WorkspaceID()],
            expandedSubagentSessionIDs: [TerminalSessionID(), TerminalSessionID()],
            expandedSubagentDoneSessionIDs: [TerminalSessionID()],
            tasksCollapsed: true,
            projectsCollapsed: true,
            showsActiveOnly: true,
            expandedIdleWorkspaceProjectIDs: [ProjectID()],
            inactiveProjectsExpanded: true
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
            workspaceActivitySummaries: [:],
            activeWorkspaceIDs: [activeWorkspace.id],
            tree: .constant(WarrenDesktopSidebarTreeState(
                showsActiveOnly: true
            )),
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
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
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeWorkspaceIDs: [],
            tree: .constant(WarrenDesktopSidebarTreeState(
                selectedTab: .tasks,
                showsActiveOnly: true
            )),
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
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
