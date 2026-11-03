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
    func testPublicAccessUsesOwnerReachabilityTerminology() {
        XCTAssertEqual(WarrenPublicAccessCopy.title, "Public Access")
        XCTAssertEqual(WarrenPublicAccessCopy.relayURL, "Relay URL")
        XCTAssertEqual(WarrenPublicAccessCopy.publicHostname, "Public hostname")
        XCTAssertEqual(WarrenPublicAccessCopy.pathPrefix, "Path prefix")
        XCTAssertEqual(WarrenPublicAccessCopy.publicEndpoint, "Public URL")
        XCTAssertEqual(WarrenPublicAccessCopy.resetLocalSetup, "Reset local route")
        XCTAssertFalse(WarrenPublicAccessCopy.title.localizedCaseInsensitiveContains("sharing"))
    }
    /// The fade covers the line's last points and nothing else, so a title that
    /// fits keeps every glyph it has.
    func testOverflowFadeCoversTheLinesTail() {
        XCTAssertEqual(WarrenDesktopFadingLine<EmptyView>.fadeStart(in: WarrenDesktopSidebarMetrics.sessionLineFadeWidth), 0)
        XCTAssertEqual(WarrenDesktopFadingLine<EmptyView>.fadeStart(in: 10), 0)
        XCTAssertEqual(
            WarrenDesktopFadingLine<EmptyView>.fadeStart(in: 128),
            (128 - WarrenDesktopSidebarMetrics.sessionLineFadeWidth) / 128,
            accuracy: 0.0001
        )
    }
    /// The weight is what replaced the indent, so a container row and the rows
    /// inside it must not resolve to the same font.
    func testContainerRowsCarryHeavierWeightThanWhatTheyContain() {
        XCTAssertEqual(WarrenTypography.sidebarContainerRow, WarrenTypography.navigationGroup)
        XCTAssertNotEqual(WarrenTypography.sidebarContainerRow, WarrenTypography.workspaceRow)
        XCTAssertEqual(WarrenTypography.workspaceRow, WarrenTypography.navigationItem)
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
    func descendantViews<T: NSView>(
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
    static func mouseDownEvent(clickCount: Int) -> NSEvent {
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
    static func mouseUpEvent() -> NSEvent {
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
    static func mouseEnteredEvent() -> NSEvent {
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
    static func mouseExitedEvent() -> NSEvent {
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
    /// A completion notice is news exactly once. Selecting the row is what
    /// retires it, so the tree stops drawing it while the Session keeps reporting
    /// `ready` — and a failure or a request is never retired by being seen.
    @MainActor
    func testACompletionStopsDrawingOnceItsRowHasBeenSelected() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let finished = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Migrate",
            kind: .claude,
            activity: .ready
        )
        let awaiting = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Rename",
            kind: .codex,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Run the migration?")
            )
        )
        var acknowledgments = WarrenDesktopActivityAcknowledgments()
        acknowledgments.acknowledge(finished)

        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [
                finished.acknowledgingActivity(acknowledgments[finished.id]),
                awaiting,
            ]
        )
        let recorder = WarrenSemanticRecorder()
        var actions: [WarrenDesktopAction] = []
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState()),
            selection: .workspace(workspace.id),
            selectedTabID: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
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

        // The read completion says nothing; the unanswered request still does.
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: recorder.snapshot().nodes.filter {
                $0.id.hasPrefix("workspace-session.project-list.")
            }.map { ($0.label, $0.value) }),
            [
                "Claude Code Session Migrate": "API · feature",
                "Codex Session Rename": "Approval needed · Run the migration? · API · feature",
            ]
        )
        // The Workspace rollup follows what is drawn, so it names the request
        // rather than the read completion.
        XCTAssertEqual(projection.mark(in: workspace.id), .approvalNeeded)
    }
    /// Two Sessions that both read as "blocked" to the Host ask a person for
    /// different things. The tree used to name them identically — one shared
    /// "Needs attention" — and draw them identically, so the row could not be
    /// acted on without opening it first.
    @MainActor
    func testARowNamesWhichRequestIsWaiting() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let approval = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Migrate",
            kind: .claude,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Run the migration?")
            )
        )
        let question = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Rename",
            kind: .codex,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .input, reason: "Which branch?")
            )
        )
        // No payload to explain it, so the row must not name a request.
        let unexplained = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Stalled",
            kind: .codex,
            activity: .blocked
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [approval, question, unexplained]
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState()),
            selection: .workspace(workspace.id),
            selectedTabID: nil,
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

        let leaves = recorder.snapshot().nodes.filter {
            $0.id.hasPrefix("workspace-session.project-list.")
        }
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: leaves.map { ($0.label, $0.value) }),
            [
                "Claude Code Session Migrate": "Approval needed · Run the migration? · API · feature",
                "Codex Session Rename": "Input needed · Which branch? · API · feature",
                "Codex Session Stalled": "Needs attention · API · feature",
            ]
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
}
