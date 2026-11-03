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
    /// The plan's current entry stands in when the tool step alone cannot say
    /// what the Agent is doing.
    func testSessionSecondLineUsesThePlanStepWhenTheToolStepIsSilent() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Claude Code",
            kind: .claude,
            activity: .working,
            plan: WarrenDesktopPlanProgress(done: 0, total: 2, currentStep: "Read the spec")
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session).primary,
            "Read the spec"
        )
    }
    /// A running Agent with neither a tool step nor a plan keeps the last
    /// primary fact it showed, instead of swapping to a foreground command or
    /// the previous turn's past-tense summary.
    func testSessionSecondLineKeepsThePreviousPrimaryForARunningAgent() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Claude Code",
            kind: .claude,
            activity: .working,
            primaryLine: "Running swift build",
            lastActivity: "Ran swift test"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session).primary,
            "Running swift build",
            "The row holds the last primary, not the previous turn's summary"
        )
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
        XCTAssertFalse(tree.collapsedTaskIDs.contains(returned.id))
        XCTAssertTrue(tree.collapsedTaskIDs.isEmpty)
        XCTAssertFalse(tree.tasksCollapsed)
    }
    /// Claude, Codex, and OpenCode launch as a Conversation over ACP when the
    /// interface asks for it; every other preset ignores the choice.
    func testConversationLaunchUsesACPOnlyForSupportingPresets() {
        let presets = Dictionary(uniqueKeysWithValues: WarrenDesktopSessionPreset.pinned.map { ($0.id, $0) })

        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.filter(\.supportsConversation).map(\.id),
            ["claude", "codex", "opencode"]
        )
        XCTAssertEqual(
            presets["claude"]?.resolvedRequest(commandOverride: "claude --model sonnet", conversation: true),
            TerminalSessionLaunchRequest(kind: .claude, agentHandler: "acp")
        )
        XCTAssertEqual(
            presets["codex"]?.resolvedRequest(commandOverride: "", conversation: false),
            .codex
        )
        XCTAssertEqual(
            presets["pi"]?.resolvedRequest(commandOverride: "", conversation: true),
            .pi
        )
        XCTAssertEqual(WarrenAgentInterface(storedValue: nil), .ask)
        XCTAssertEqual(WarrenAgentInterface(storedValue: "bogus"), .ask)
        XCTAssertEqual(WarrenAgentInterface(storedValue: "acp"), .acp)
    }
    func testTabTitleNamesAnAgentByItsKindWhenNoTitleIsSet() {
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
            "Codex"
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
            "Codex"
        )
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
    /// A Host can report an attention payload alongside a lifecycle value that
    /// has not caught up yet. Reading the lifecycle first drew the quiet idle
    /// marker on the one Session that needed someone.
    func testAStaleReadyCarryingAttentionStillReadsAsActionable() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "stale",
            title: "Stale",
            kind: .claude,
            agentStatus: AgentStatus(
                activity: .ready,
                attention: AgentAttention(kind: .input, reason: "Which branch?")
            )
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [session]
        )

        XCTAssertEqual(session.activityMark, .inputNeeded)
        XCTAssertEqual(projection.mark(in: workspaceID), .inputNeeded)
        XCTAssertEqual(session.activityMark?.tier, .actionable)
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
            runtimeProcess: "npm run dev",
            workingDirectory: "/tmp/api-feature/Sources"
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
            rowsByLabel["Shell Session Sources"],
            "npm run dev · API · feature",
            "A plain shell names where it is and reports its process without claiming an activity it cannot observe"
        )
    }
    /// A long conversation's first-turn title drifts, so an Agent Session can be
    /// renamed from what it is about now. A shell has no conversation to read,
    /// and the Host decides when the action can run: it knows whether the Agent
    /// has exchanged a user and an assistant text and whether a title endpoint
    /// is configured.
    func testRegenerateTitleIsOfferedForAgentSessionsOnly() {
        func regeneration(
            shows: Bool,
            can: Bool = true
        ) -> WarrenDesktopContextMenuAction? {
            WarrenDesktopWorkspaceSessionRow.contextMenuActions(
                isPinned: false,
                onTogglePin: {},
                onRename: {},
                onEnd: {},
                showsRegenerateTitle: shows,
                canRegenerateTitle: can,
                onRegenerateTitle: {}
            ).first { action in
                guard case .button(let title, _, _, _) = action else { return false }
                return title == "Regenerate Title"
            }
        }

        XCTAssertNil(
            regeneration(shows: false),
            "A shell Session has no conversation, so it offers no regeneration"
        )
        guard case .button(let title, let destructive, let isEnabled, _) = regeneration(shows: true) else {
            return XCTFail("An Agent Session offers a regeneration")
        }
        XCTAssertEqual(title, "Regenerate Title")
        XCTAssertFalse(destructive, "Regenerating keeps the Session's name slot, it does not delete work")
        XCTAssertTrue(isEnabled)

        guard case .button(_, _, let unavailable, _) = regeneration(shows: true, can: false) else {
            return XCTFail("The action stays listed while it cannot run")
        }
        XCTAssertFalse(unavailable, "The Host reports when it cannot name the conversation yet")

        // It reads in the same group as the manual rename, after it: the user's
        // own name and the Host's are the same kind of action.
        let titles = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: false,
            onTogglePin: {},
            onRename: {},
            onEnd: {},
            showsRegenerateTitle: true,
            canRegenerateTitle: false,
            onRegenerateTitle: {}
        ).compactMap { action -> String? in
            guard case .button(let title, _, _, _) = action else { return nil }
            return title
        }
        XCTAssertEqual(titles, ["Pin Session", "Rename Session", "Regenerate Title", "End Session…"])
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
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .compact,
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
}
