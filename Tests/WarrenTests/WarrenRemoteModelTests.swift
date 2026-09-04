import Foundation
import XCTest
@testable import WarrenDesktop
import WarrenDomain
import WarrenClientCore
@testable import Warren

final class WarrenRemoteModelTests: XCTestCase {
    @MainActor
    func testRemoteModelStartsInConnectingState() {
        let model = WarrenRemoteApplicationModel()

        XCTAssertEqual(model.projection.connectionState, .connecting)
    }

    @MainActor
    func testConnectionFailureBeforeTransportEntersFailedState() {
        let model = WarrenRemoteApplicationModel()
        model.markConnectionFailed(NSError(
            domain: "WarrenRemote",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "The local daemon is not running"]
        ))

        XCTAssertEqual(model.projection.connectionState, .failed)
        XCTAssertFalse(model.notices.isEmpty)
    }

    @MainActor
    func testPendingConnectionCanBeStoppedBeforeTransportExists() {
        let model = WarrenRemoteApplicationModel()

        model.markConnectionConnecting()
        XCTAssertEqual(model.projection.connectionState, .connecting)

        model.stopConnection()
        XCTAssertEqual(model.projection.connectionState, .disconnected)
    }

    @MainActor
    func testRemoteDateParserAcceptsFractionalAndPlainRFC3339Values() throws {
        let fractional = try XCTUnwrap(
            WarrenRemoteApplicationModel.parseISO8601Date(
                "2026-09-04T20:38:48.743185884+08:00"
            )
        )
        let plain = try XCTUnwrap(
            WarrenRemoteApplicationModel.parseISO8601Date("2026-09-04T12:38:48Z")
        )

        XCTAssertEqual(
            fractional.timeIntervalSince1970,
            plain.timeIntervalSince1970 + 0.743185884,
            accuracy: 0.001
        )
        XCTAssertNil(WarrenRemoteApplicationModel.parseISO8601Date("not-a-date"))
        XCTAssertNil(WarrenRemoteApplicationModel.parseISO8601Date("  "))
    }

    @MainActor
    func testPublicAccessBrowserOpenAddsAuthFragmentOnlyForCurrentEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://tunnel.example/t/host/"))
        let opened = WarrenRemoteApplicationModel.publicAccessBrowserURL(
            endpoint,
            currentEndpoint: endpoint,
            daemonToken: "daemon-token"
        )
        XCTAssertEqual(opened.absoluteString, "https://tunnel.example/t/host/#t=daemon-token")

        let canonical = URL(string: "https://tunnel.example/t/host/")!
        XCTAssertEqual(
            WarrenRemoteApplicationModel.publicAccessBrowserURL(
                opened,
                currentEndpoint: endpoint,
                daemonToken: "daemon-token"
            ),
            opened
        )
        XCTAssertEqual(
            WarrenRemoteApplicationModel.publicAccessBrowserURL(
                canonical,
                currentEndpoint: URL(string: "https://other.example/t/host/")!,
                daemonToken: "daemon-token"
            ),
            canonical
        )
    }

    @MainActor
    func testPublicAccessBrowserOpenPercentEncodesBase64AuthFragment() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://tunnel.example/t/host/"))
        let opened = WarrenRemoteApplicationModel.publicAccessBrowserURL(
            endpoint,
            currentEndpoint: endpoint,
            daemonToken: "a+/="
        )

        XCTAssertEqual(opened.absoluteString, "https://tunnel.example/t/host/#t=a%2B%2F%3D")
        XCTAssertEqual(
            URLComponents(url: opened, resolvingAgainstBaseURL: false)?.fragment,
            "t=a+/="
        )
    }

    @MainActor
    func testAuthenticatedWebURLEncodesLegacyTokenWithoutAPlaintextFragment() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://tunnel.example/t/host/"))
        let opened = WarrenRemoteApplicationModel.authenticatedWebURL(
            endpoint,
            daemonToken: "a+/="
        )

        XCTAssertEqual(opened.absoluteString, "https://tunnel.example/t/host/#t=a%2B%2F%3D")
        XCTAssertEqual(
            URLComponents(url: opened, resolvingAgainstBaseURL: false)?.fragment,
            "t=a+/="
        )
    }

    @MainActor
    func testNoticeHistoryIsBoundedAndSupportsReadDismiss() {
        let model = WarrenRemoteApplicationModel()

        for index in 0..<51 {
            model.addNotice(
                title: "Notice \(index)",
                message: "Message \(index)"
            )
        }

        XCTAssertEqual(model.notices.count, 50)
        XCTAssertEqual(model.notices.first?.title, "Notice 50")
        let firstID = model.notices[0].id
        model.markNoticeRead(firstID)
        XCTAssertFalse(model.notices[0].isUnread)
        model.dismissNotice(firstID)
        XCTAssertFalse(model.notices.contains(where: { $0.id == firstID }))
    }

    @MainActor
    func testConnectIsIdempotentForTheSameEndpoint() {
        let model = WarrenRemoteApplicationModel()
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Test",
            url: "http://127.0.0.1:9",
            token: "token",
            ssh: nil
        )

        model.connect(endpoint)
        XCTAssertTrue(model.isConnected(to: endpoint))

        // A root `.task` restart on full-screen transitions calls connect
        // again; this must not tear down the healthy connection.
        model.connect(endpoint)
        XCTAssertTrue(model.isConnected(to: endpoint))

        model.disconnect()
        XCTAssertFalse(model.isConnected(to: endpoint))
        model.disconnect()
        XCTAssertFalse(model.isConnected(to: endpoint))
    }

    @MainActor
    func testEqualProjectionDoesNotPublishAgain() {
        let model = WarrenRemoteApplicationModel()
        let initial = model.projection

        XCTAssertFalse(model.publishProjectionIfChanged(initial))
        XCTAssertEqual(model.projectionPublicationCount, 0)

        let changed = type(of: initial).empty(host: Host(name: "Changed"))
        XCTAssertTrue(model.publishProjectionIfChanged(changed))
        XCTAssertEqual(model.projectionPublicationCount, 1)
        XCTAssertFalse(model.publishProjectionIfChanged(changed))
        XCTAssertEqual(model.projectionPublicationCount, 1)
    }

    func testRemoteSubscribeParametersCarryViewportAndClaimControl() throws {
        let sessionID = TerminalSessionID()
        let size = try XCTUnwrap(TerminalSize(columns: 117, rows: 38))

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.subscribeParameters(
                sessionID: sessionID,
                size: size,
                claimControl: true
            ),
            [
                "id": sessionID.description,
                "claim": "true",
                "cols": "117",
                "rows": "38",
            ]
        )
    }

    func testRemoteSubscribeParametersRemainExplicitlyPassiveWithoutGrid() {
        let sessionID = TerminalSessionID()

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.subscribeParameters(sessionID: sessionID, size: nil),
            ["id": sessionID.description]
        )
    }

    func testTaskCreateRequestCarriesOptionalMetadata() {
        let requestID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let request = WarrenRemoteTaskProtocol.createRequest(
            WarrenDesktopTaskCreationRequest(
                requestID: requestID,
                name: "Delivery",
                source: "tapd",
                externalID: "123",
                url: "https://tracker.example/tasks/123"
            )
        )

        XCTAssertEqual(request.method, "task.create")
        XCTAssertEqual(request.params, [
            "name": "Delivery",
            "source": "tapd",
            "externalID": "123",
            "url": "https://tracker.example/tasks/123",
            "requestId": requestID.uuidString.lowercased(),
        ])
    }

    func testTaskCreateResultUsesHostReturnedIDAndRejectsInvalidID() throws {
        let taskID = TaskID()
        let result = Data("{\"id\":\"\(taskID.description)\"}".utf8)

        XCTAssertEqual(try WarrenRemoteTaskProtocol.taskID(from: result), taskID)
        XCTAssertThrowsError(
            try WarrenRemoteTaskProtocol.taskID(from: Data("{\"id\":\"invalid\"}".utf8))
        )
        XCTAssertThrowsError(
            try WarrenRemoteTaskProtocol.taskID(from: Data("{}".utf8))
        )
    }

    @MainActor
    func testTaskSubmitKeepsDraftForInvalidHostIDsUntilValidRetry() async {
        let validID = TaskID()
        var responses = [
            Data("{}".utf8),
            Data("{\"id\":\"invalid\"}".utf8),
            Data("{\"id\":\"\(validID.description)\"}".utf8),
        ]
        var isPresented = true
        var createdTaskID: TaskID?
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            name: "Delivery",
            source: "tapd",
            externalID: "123",
            url: "https://tracker.example/tasks/123",
            onCreate: { _ in
                try WarrenRemoteTaskProtocol.taskID(from: responses.removeFirst())
            },
            onCreated: {
                createdTaskID = $0
                isPresented = false
            }
        )

        await coordinator.submit()
        XCTAssertTrue(isPresented)
        XCTAssertNil(createdTaskID)
        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.name, "Delivery")
        XCTAssertEqual(coordinator.source, "tapd")
        XCTAssertEqual(coordinator.externalID, "123")
        XCTAssertEqual(coordinator.url, "https://tracker.example/tasks/123")

        await coordinator.submit()
        XCTAssertTrue(isPresented)
        XCTAssertNil(createdTaskID)
        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertNotNil(coordinator.errorMessage)

        await coordinator.submit()
        XCTAssertFalse(isPresented)
        XCTAssertEqual(createdTaskID, validID)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testWorkspaceCreateParametersCarryTaskWhenProvided() {
        let projectID = ProjectID()
        let taskID = TaskID()
        let requestID = UUID()
        let creation = WorkspaceCreationRequest(
            requestID: requestID,
            displayName: "Delivery API",
            branch: "feature/delivery",
            path: ""
        )

        XCTAssertEqual(
            WarrenRemoteWorkspaceProtocol.createParameters(
                projectID: projectID,
                taskID: taskID,
                creation: creation
            ),
            [
                "project": projectID.description,
                "task": taskID.description,
                "branch": "feature/delivery",
                "name": "Delivery API",
                "path": "",
                "requestId": requestID.uuidString.lowercased(),
                "runSetupScript": "false",
            ]
        )
    }

    func testWorkspaceCreateParametersRemainCompatibleWithoutTask() {
        let projectID = ProjectID()
        let requestID = UUID()
        let creation = WorkspaceCreationRequest(
            requestID: requestID,
            displayName: "Standalone",
            branch: "feature/standalone",
            path: ""
        )

        XCTAssertEqual(
            WarrenRemoteWorkspaceProtocol.createParameters(
                projectID: projectID,
                taskID: nil,
                creation: creation
            ),
            [
                "project": projectID.description,
                "branch": "feature/standalone",
                "name": "Standalone",
                "path": "",
                "requestId": requestID.uuidString.lowercased(),
                "runSetupScript": "false",
            ]
        )
    }

    @MainActor
    func testWorkspaceSubmitPreventsDuplicatesKeepsFailureAndDismissesOnRetry() async {
        let requestID = UUID()
        let projectID = ProjectID()
        let taskID = TaskID()
        let firstStarted = expectation(description: "First workspace creation started")
        let retryStarted = expectation(description: "Workspace creation retry started")
        let fake = PausingWorkspaceCreationFake(
            projectID: projectID,
            taskID: taskID,
            callExpectations: [firstStarted, retryStarted]
        )
        var dismissCount = 0
        let coordinator = WarrenWorkspaceCreationCoordinator(
            requestID: requestID,
            displayName: "Delivery API",
            branch: "feature/delivery",
            path: "/tmp/delivery",
            onCreate: fake.create,
            onDismiss: { dismissCount += 1 }
        )

        let firstSubmission = Task { await coordinator.submit() }
        await fulfillment(of: [firstStarted], timeout: 1)

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(fake.parameters, [[
            "project": projectID.description,
            "task": taskID.description,
            "branch": "feature/delivery",
            "name": "Delivery API",
            "path": "/tmp/delivery",
            "requestId": requestID.uuidString.lowercased(),
            "runSetupScript": "false",
        ]])
        XCTAssertTrue(coordinator.isSubmitting)
        XCTAssertEqual(dismissCount, 0)

        await coordinator.submit()
        XCTAssertEqual(fake.callCount, 1)

        let failure = NSError(
            domain: "WorkspaceCreationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Workspace creation failed"]
        )
        fake.fail(failure)
        await firstSubmission.value

        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(coordinator.errorMessage, "Workspace creation failed")
        XCTAssertEqual(coordinator.requestID, requestID)
        XCTAssertEqual(coordinator.displayName, "Delivery API")
        XCTAssertEqual(coordinator.branch, "feature/delivery")
        XCTAssertEqual(coordinator.path, "/tmp/delivery")

        coordinator.binding(\.branch).wrappedValue = "feature/delivery-retry"
        XCTAssertNil(coordinator.errorMessage)
        coordinator.binding(\.branch).wrappedValue = "feature/delivery"

        let retry = Task { await coordinator.submit() }
        await fulfillment(of: [retryStarted], timeout: 1)
        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(fake.requests.map(\.requestID), [requestID, requestID])
        XCTAssertTrue(coordinator.isSubmitting)
        XCTAssertNil(coordinator.errorMessage)
        fake.succeed()
        await retry.value

        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertEqual(dismissCount, 1)
    }

    @MainActor
    func testWorkspaceCreationChangesRequestIDOnlyWhenSubmittedDraftChanges() async {
        let requestID = UUID()
        var requests: [WorkspaceCreationRequest] = []
        let coordinator = WarrenWorkspaceCreationCoordinator(
            requestID: requestID,
            displayName: "Delivery API",
            branch: "feature/delivery",
            onCreate: { request in
                requests.append(request)
                throw NSError(
                    domain: "WorkspaceCreationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Workspace creation failed"]
                )
            },
            onDismiss: { XCTFail("Failed submissions must not dismiss the modal") }
        )

        await coordinator.submit()
        await coordinator.submit()
        XCTAssertEqual(requests.map(\.requestID), [requestID, requestID])

        coordinator.binding(\.branch).wrappedValue = "feature/delivery-retry"
        XCTAssertNil(coordinator.errorMessage)
        await coordinator.submit()

        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(requests[2].requestID, requestID)
        XCTAssertEqual(requests[2].requestID, coordinator.requestID)
    }

    func testRemoteAttachParametersIncludeRecoveryAnchorWhenKnown() throws {
        let sessionID = TerminalSessionID()
        let anchor = TerminalOutputAnchor(epoch: 3, sequence: 4096)

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.subscribeParameters(
                sessionID: sessionID,
                size: nil,
                anchor: anchor
            ),
            [
                "id": sessionID.description,
                "epoch": "3",
                "sequence": "4096",
            ]
        )
    }

    func testSubscribeParametersCarryAnchorWithoutFocusClaim() throws {
        let sessionID = TerminalSessionID()

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.subscribeParameters(sessionID: sessionID, size: nil),
            ["id": sessionID.description]
        )

        let anchor = TerminalOutputAnchor(epoch: 7, sequence: 8192)
        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.subscribeParameters(
                sessionID: sessionID,
                size: nil,
                anchor: anchor
            ),
            [
                "id": sessionID.description,
                "epoch": "7",
                "sequence": "8192",
            ]
        )
    }

    func testSubscribeParametersCanClaimMeasuredViewport() {
        let sessionID = TerminalSessionID()
        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.subscribeParameters(
                sessionID: sessionID,
                size: TerminalSize(columns: 120, rows: 40),
                claimControl: true
            ),
            [
                "id": sessionID.description,
                "claim": "true",
                "cols": "120",
                "rows": "40",
            ]
        )
    }

    func testControlClaimParametersDisableOutputWork() {
        let sessionID = TerminalSessionID()

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.controlClaimParameters(sessionID: sessionID),
            [
                "id": sessionID.description,
                "output": "false",
            ]
        )
    }

    func testRemoteRosterAttachesInitialTabAndDoesNotDuplicateMountedSurface() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 1
        ))
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-2",
            mountedSurfaceCount: 1
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: nil,
            mountedSurfaceCount: 0
        ))
    }

    func testRemoteRosterReattachesSameTabAfterTransportReset() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
    }

    func testRemoteRosterDecodesOptionalWorkspaceMergeState() throws {
        let data = Data(
            """
            {
              "host": {"id": "11111111-1111-4111-8111-111111111111", "name": "Mac"},
              "projects": [],
              "workspaces": [
                {
                  "id": "22222222-2222-4222-8222-222222222222",
                  "project": "33333333-3333-4333-8333-333333333333",
                  "name": "review",
                  "path": "/tmp/review",
                  "branch": "review",
                  "mergeState": "merged"
                },
                {
                  "id": "44444444-4444-4444-8444-444444444444",
                  "project": "33333333-3333-4333-8333-333333333333",
                  "name": "legacy",
                  "path": "/tmp/legacy",
                  "branch": "legacy"
                },
                {
                  "id": "55555555-5555-4555-8555-555555555555",
                  "project": "33333333-3333-4333-8333-333333333333",
                  "name": "future",
                  "path": "/tmp/future",
                  "branch": "future",
                  "mergeState": "future-state"
                }
              ],
              "terminalGroups": [],
              "sessions": []
            }
            """.utf8
        )

        let roster = try JSONDecoder().decode(RemoteRoster.self, from: data)
        XCTAssertEqual(roster.workspaces[0].mergeState, "merged")
        XCTAssertNil(roster.workspaces[1].mergeState)
        XCTAssertEqual(roster.workspaces[2].mergeState, "future-state")
        XCTAssertEqual(
            roster.workspaces[0].mergeState.flatMap(WorkspaceMergeState.init(rawValue:)),
            .merged
        )
        XCTAssertNil(
            roster.workspaces[2].mergeState.flatMap(WorkspaceMergeState.init(rawValue:))
        )
    }

    func testRemoteRosterAppliesRevisionedEntityDelta() throws {
        let roster = try JSONDecoder().decode(
            RemoteRoster.self,
            from: Data(
                """
                {
                  "revision": 7,
                  "host": {"id": "host", "name": "Before"},
                  "tasks": [
                    {"id": "task-a", "name": "Delivery", "source": "tapd", "externalID": "123"}
                  ],
                  "projects": [
                    {"id": "project-a", "name": "A", "path": "/a"},
                    {"id": "project-b", "name": "B", "path": "/b"}
                  ],
                  "workspaces": [
                    {"id": "workspace-old", "project": "project-a", "name": "Old", "path": "/a"}
                  ],
                  "terminalGroups": [],
                  "sessions": []
                }
                """.utf8
            )
        )
        let message = try JSONDecoder().decode(
            RemoteRoster.StreamMessage.self,
            from: Data(
                """
                {
                  "t": "roster.delta",
                  "baseRevision": 7,
                  "revision": 9,
                  "host": {"id": "host", "name": "After"},
                  "tasks": {
                    "upsert": [{"id": "task-b", "name": "Follow-up"}],
                    "remove": ["task-a"],
                    "order": ["task-b"]
                  },
                  "projects": {
                    "upsert": [{"id": "project-a", "name": "A renamed", "path": "/a"}],
                    "order": ["project-b", "project-a"]
                  },
                  "workspaces": {
                    "upsert": [{"id": "workspace-new", "project": "project-a", "name": "New", "path": "/a/new"}],
                    "remove": ["workspace-old"],
                    "order": ["workspace-new"]
                  }
                }
                """.utf8
            )
        )
        let delta = try XCTUnwrap(message.delta)
        let updated = try XCTUnwrap(roster.applying(delta))

        XCTAssertEqual(updated.revision, 9)
        XCTAssertEqual(updated.host.name, "After")
        XCTAssertEqual(updated.tasks.map(\.id), ["task-b"])
        XCTAssertEqual(updated.tasks.first?.name, "Follow-up")
        XCTAssertEqual(updated.projects.map(\.id), ["project-b", "project-a"])
        XCTAssertEqual(updated.projects.last?.name, "A renamed")
        XCTAssertEqual(updated.workspaces.map(\.id), ["workspace-new"])
        XCTAssertNil(updated.sessions.first)

        let staleMessage = try JSONDecoder().decode(
            RemoteRoster.StreamMessage.self,
            from: Data("{\"t\":\"roster.delta\",\"baseRevision\":8,\"revision\":10}".utf8)
        )
        XCTAssertNil(updated.applying(try XCTUnwrap(staleMessage.delta)))
    }

    func testReorderingTabsPreservesTasksInProjection() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "delivery",
            path: "/tmp/api-delivery"
        )
        let firstSessionID = TerminalSessionID()
        let secondSessionID = TerminalSessionID()
        let firstTab = ClientTab(
            id: "first",
            title: "First",
            sessionID: firstSessionID
        )
        let secondTab = ClientTab(
            id: "second",
            title: "Second",
            sessionID: secondSessionID
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [project],
            workspaces: [workspace],
            sessions: [
                WarrenDesktopSession(
                    id: firstSessionID,
                    workspaceID: workspace.id,
                    title: "First"
                ),
                WarrenDesktopSession(
                    id: secondSessionID,
                    workspaceID: workspace.id,
                    title: "Second"
                ),
            ],
            tabs: [firstTab, secondTab],
            sessionWorkspaceIDs: [
                firstSessionID: workspace.id,
                secondSessionID: workspace.id,
            ]
        )

        let reordered = projection.reorderingTabs(
            tabID: firstTab.id,
            accordingTo: [secondTab.id, firstTab.id]
        )

        XCTAssertEqual(reordered.taskGroups.map(\.task), [task])
        XCTAssertEqual(reordered.taskGroups.first?.workspaces, [workspace])
        XCTAssertEqual(reordered.tabs.map(\.id), [secondTab.id, firstTab.id])
    }

    func testRemoteRosterDecodesAgentTurn() throws {
        let roster = try JSONDecoder().decode(
            RemoteRoster.self,
            from: Data("""
            {
              "host": {"id": "11111111-1111-4111-8111-111111111111", "name": "Mac"},
              "projects": [],
              "workspaces": [],
              "terminalGroups": [],
              "sessions": [
                {
                  "id": "22222222-2222-4222-8222-222222222222",
                  "title": "Codex",
                  "kind": "codex",
                  "lifecycle": "running",
                  "agentTurn": {"id": 8, "status": "completed"}
                }
              ]
            }
            """.utf8)
        )

        XCTAssertEqual(roster.sessions[0].agentTurn, .init(id: 8, status: "completed"))
    }

    func testReconnectDelayBacksOffExponentiallyAndCapsAtThirtySeconds() {
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 0), 500)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 1), 1_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 2), 2_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 6), 30_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 99), 30_000)
    }

    func testPermanentSSHFailuresDoNotEnterTheRetryLoop() {
        let permanent = NSError(
            domain: "WarrenEmbeddedSSHTunnel",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "SSH config disables known_hosts; strict host-key verification is required"]
        )
        let transient = NSError(
            domain: "WarrenEmbeddedSSHTunnel",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "The embedded SSH helper timed out while establishing the tunnel."]
        )

        XCTAssertTrue(WarrenRemoteApplicationModel.isPermanentConnectionError(permanent))
        XCTAssertFalse(WarrenRemoteApplicationModel.isPermanentConnectionError(transient))
    }

    func testSSHAuthenticationFailuresAreClassifiedAsPermanent() {
        for message in [
            "authenticate SSH host 203.0.113.10: ssh: unable to authenticate",
            "remote Warren rejected the bootstrap token",
        ] {
            let error = NSError(
                domain: "WarrenEmbeddedSSHTunnel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            XCTAssertTrue(
                WarrenRemoteApplicationModel.isPermanentConnectionError(error),
                "expected permanent failure for: \(message)"
            )
        }
    }

    func testDiagnosticsDoNotExposeEndpointCredentials() {
        let error = NSError(
            domain: "WarrenRemote",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "request failed"]
        )
        let text = WarrenRemoteApplicationModel.diagnosticText(
            error: error,
            endpoint: "https://user:password@example.test/warren?token=secret#t=secret"
        )

        XCTAssertTrue(text.contains("endpoint: https://example.test/warren"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("secret"))
    }

    func testRemoteTabOrderingMovesBeforeDestinationAndToEnd() {
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-c", before: "tab-a", in: [
                "tab-a", "tab-b", "tab-c",
            ]),
            ["tab-c", "tab-a", "tab-b"]
        )
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-a", before: nil, in: [
                "tab-a", "tab-b", "tab-c",
            ]),
            ["tab-b", "tab-c", "tab-a"]
        )
    }

    func testRemoteTabOrderingRejectsInvalidMoves() {
        let tabs = ["tab-a", "tab-b", "tab-c"]

        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("missing", before: "tab-a", in: tabs),
            tabs
        )
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-a", before: "missing", in: tabs),
            tabs
        )
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-a", before: "tab-a", in: tabs),
            tabs
        )
    }

    func testRemoteTabOrderingReconcilesRosterChanges() {
        XCTAssertEqual(
            WarrenRemoteTabOrdering.reconciling(
                preferredOrder: ["tab-c", "closed", "tab-a", "tab-c"],
                availableTabIDs: ["tab-a", "tab-b", "tab-c", "tab-new"]
            ),
            ["tab-c", "tab-a", "tab-b", "tab-new"]
        )
    }

    func testStaleSessionDeleteErrorIsBenign() {
        let sessionID = TerminalSessionID()

        XCTAssertTrue(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "session not found: \(sessionID)",
            ]),
            sessionID: sessionID
        ))
        XCTAssertFalse(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "session not found: another-id",
            ]),
            sessionID: sessionID
        ))
        XCTAssertFalse(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ghostline kill failed",
            ]),
            sessionID: sessionID
        ))
    }

    func testDeletionStateRetainsOnlyResourcesStillInTheRoster() {
        XCTAssertEqual(
            WarrenRemoteApplicationModel.reconcileDeletionIDs(
                ["project-a", "project-b"],
                against: ["project-b", "project-c"]
            ),
            ["project-b"]
        )
    }

    func testRosterRefreshAppliesOnlyFromItsCurrentGeneration() {
        XCTAssertTrue(WarrenRemoteApplicationModel.shouldApplyRoster(
            startedAt: 4,
            currentGeneration: 4
        ))
        XCTAssertFalse(WarrenRemoteApplicationModel.shouldApplyRoster(
            startedAt: 4,
            currentGeneration: 5
        ))
    }

    func testIdenticalRosterIsNotAppliedTwice() throws {
        let roster = try JSONDecoder().decode(
            RemoteRoster.self,
            from: Data("""
            {
              "host": {"id": "11111111-1111-4111-8111-111111111111", "name": "Mac"},
              "projects": [],
              "workspaces": [],
              "terminalGroups": [],
              "sessions": []
            }
            """.utf8)
        )

        XCTAssertTrue(WarrenRemoteApplicationModel.shouldApplyRoster(roster, after: nil))
        XCTAssertFalse(WarrenRemoteApplicationModel.shouldApplyRoster(roster, after: roster))
    }

    func testRosterActivityOverridesStaleLiveActivity() {
        XCTAssertEqual(
            WarrenRemoteApplicationModel.resolvedAgentStatus(
                rosterStatus: .init(activity: "ready", attention: nil),
                liveStatus: AgentStatus(activity: .working)
            )?.activity,
            .ready
        )
        XCTAssertEqual(
            WarrenRemoteApplicationModel.resolvedAgentStatus(
                rosterStatus: .init(activity: "working", attention: nil),
                liveStatus: AgentStatus(activity: .ready)
            )?.activity,
            .working
        )
    }

    func testAgentCompletionTrackerSeedsInitialRosterAndEmitsEachCompletionOnce() {
        let sessionID = TerminalSessionID()
        var tracker = WarrenAgentCompletionTracker()

        XCTAssertEqual(tracker.observe([
            sessionID: .init(id: 4, status: "completed"),
        ]), [])
        XCTAssertEqual(tracker.observe([
            sessionID: .init(id: 5, status: "started"),
        ]), [])
        XCTAssertEqual(tracker.observe([
            sessionID: .init(id: 5, status: "completed"),
        ]), [sessionID])
        XCTAssertEqual(tracker.observe([
            sessionID: .init(id: 5, status: "completed"),
        ]), [])
    }

    func testAgentCompletionTrackerIgnoresFailedAndReboundTurns() {
        let sessionID = TerminalSessionID()
        var tracker = WarrenAgentCompletionTracker()
        _ = tracker.observe([sessionID: .init(id: 5, status: "completed")])

        XCTAssertEqual(tracker.observe([
            sessionID: .init(id: 6, status: "failed"),
        ]), [])
        XCTAssertEqual(tracker.observe([
            sessionID: .init(id: 1, status: "completed"),
        ]), [])
        XCTAssertEqual(tracker.observe([
            sessionID: .init(id: 2, status: "completed"),
        ]), [sessionID])
    }

    func testLiveActivityFillsMissingRosterActivity() {
        XCTAssertEqual(
            WarrenRemoteApplicationModel.resolvedAgentStatus(
                rosterStatus: nil,
                liveStatus: AgentStatus(activity: .working)
            )?.activity,
            .working
        )
        XCTAssertNil(WarrenRemoteApplicationModel.resolvedAgentStatus(
            rosterStatus: nil,
            liveStatus: nil
        ))
    }

    func testLatestValueSignalCoalescesPendingValues() {
        var signal = WarrenLatestValueSignal<Int>()

        XCTAssertTrue(signal.offer(1))
        XCTAssertFalse(signal.offer(2))
        XCTAssertEqual(signal.take(), 2)
        XCTAssertTrue(signal.offer(3))
        XCTAssertEqual(signal.take(), 3)
    }

    func testResizeRequestBufferKeepsOnlyLatestUnsentSize() throws {
        let first = try XCTUnwrap(TerminalSize(columns: 80, rows: 24))
        let second = try XCTUnwrap(TerminalSize(columns: 100, rows: 30))
        let final = try XCTUnwrap(TerminalSize(columns: 120, rows: 36))
        var buffer = WarrenResizeRequestBuffer()

        XCTAssertTrue(buffer.offer(first))
        XCTAssertFalse(buffer.offer(second))
        XCTAssertFalse(buffer.offer(final))
        XCTAssertEqual(buffer.take(), final)
        buffer.markSent(final)
        XCTAssertFalse(buffer.offer(final))

        XCTAssertTrue(buffer.offer(second))
        XCTAssertEqual(buffer.take(), second)
    }

    func testRemoteTransportFailureHasUnknownRequestOutcome() {
        let timeout = NSError(
            domain: NSURLErrorDomain,
            code: URLError.Code.timedOut.rawValue
        )
        let wrappedTimeout = NSError(
            domain: "WarrenRemote",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: timeout]
        )
        let rejected = NSError(
            domain: "WarrenRemote",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )

        XCTAssertTrue(WarrenRemoteApplicationModel.isRemoteRequestOutcomeUnknown(wrappedTimeout))
        XCTAssertFalse(WarrenRemoteApplicationModel.isRemoteRequestOutcomeUnknown(rejected))

        let reset = NSError(
            domain: "WarrenRemote",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation couldn’t be completed. Connection reset by peer",
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: 54
                ),
            ]
        )
        XCTAssertTrue(WarrenRemoteApplicationModel.isRemoteRequestOutcomeUnknown(reset))
    }

    func testActivityDismissalHidesOnlyTheDismissedState() {
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: .ready,
                dismissed: nil
            ),
            WarrenActivityDismissal.Presentation(
                activity: .ready,
                clearsDismissal: false
            )
        )
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: .ready,
                dismissed: .ready
            ),
            WarrenActivityDismissal.Presentation(
                activity: nil,
                clearsDismissal: false
            )
        )
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: .working,
                dismissed: .ready
            ),
            WarrenActivityDismissal.Presentation(
                activity: .working,
                clearsDismissal: true
            )
        )
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: nil,
                dismissed: .ready
            ),
            WarrenActivityDismissal.Presentation(
                activity: nil,
                clearsDismissal: true
            )
        )
        XCTAssertTrue(WarrenActivityDismissal.canDismiss(
            candidate: .working,
            expected: .working
        ))
        XCTAssertFalse(WarrenActivityDismissal.canDismiss(
            candidate: .blocked,
            expected: .working
        ))
    }

    func testLosslessAsyncBufferBackpressuresAndPreservesOrder() async throws {
        let buffer = WarrenLosslessAsyncBuffer<Int>(capacity: 2)
        let progress = SendProgress()
        let producer = Task {
            for value in 0..<100 {
                guard await buffer.send(value) else { return false }
                await progress.recordSend()
            }
            return true
        }

        await progress.waitForSends(2)
        try await Task.sleep(for: .milliseconds(2))
        let sentBeforeConsumption = await progress.sentCount
        XCTAssertEqual(sentBeforeConsumption, 2)

        var iterator = buffer.stream.makeAsyncIterator()
        var received: [Int] = []
        for _ in 0..<100 {
            let next = await iterator.next()
            received.append(try XCTUnwrap(next))
        }
        let completed = await producer.value
        XCTAssertTrue(completed)
        buffer.finish()
        XCTAssertEqual(received, Array(0..<100))
    }

    func testOrderedInputBridgePreservesBracketedPasteFenceposts() async throws {
        let recorder = LockedDataRecorder()
        let bridge = WarrenOrderedInputBridge { data in
            recorder.append(data)
        }
        let pasteStart = Data("\u{1b}[200~".utf8)
        let pasteEnd = Data("\u{1b}[201~".utf8)
        let pasteCount = 10_000
        var expected = Data()
        for index in 0..<pasteCount {
            expected.append(pasteStart)
            expected.append(Data("payload-\(index)".utf8))
            expected.append(pasteEnd)
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for index in 0..<pasteCount {
                    bridge.send(pasteStart)
                    bridge.send(Data("payload-\(index)".utf8))
                    bridge.send(pasteEnd)
                }
                continuation.resume()
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while recorder.count < expected.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recorder.data, expected)
    }

    func testTerminalInputRouterBuffersUntilAttachAndDropsStaleSurfaceInput() async throws {
        let router = WarrenTerminalInputRouter()
        let recorder = LockedDataRecorder()
        let firstSessionID = TerminalSessionID()
        let secondSessionID = TerminalSessionID()

        router.prepare(for: firstSessionID)
        router.enqueue(Data("before-attach".utf8), for: firstSessionID)
        router.activate(for: firstSessionID) { data in
            recorder.append(data)
        }

        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while recorder.count < Data("before-attach".utf8).count,
              ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(recorder.data, Data("before-attach".utf8))

        router.prepare(for: secondSessionID)
        router.enqueue(Data("stale".utf8), for: firstSessionID)
        router.enqueue(Data("second".utf8), for: secondSessionID)
        router.activate(for: secondSessionID) { data in
            recorder.append(data)
        }

        let expected = Data("before-attachsecond".utf8)
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while recorder.count < expected.count, ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(recorder.data, expected)
    }

    func testTerminalOutputBufferDeduplicatesOverlapAndKeepsSequenceGaps() {
        var buffer = WarrenTerminalOutputBuffer()
        buffer.reset(epoch: 7, sequence: 0)
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 3, payload: Data("defghi".utf8))

        var slices: [WarrenTerminalOutputSlice] = []
        while let slice = buffer.take(maxBytes: 4) { slices.append(slice) }
        XCTAssertEqual(slices.map(\.sequence), [0, 4, 6])
        XCTAssertEqual(
            Data(slices.flatMap { $0.payload }),
            Data("abcdefghi".utf8)
        )
        XCTAssertEqual(buffer.enqueuedSequence, 9)

        buffer.append(epoch: 8, sequence: 100, payload: Data("xyz".utf8))
        XCTAssertEqual(buffer.take(maxBytes: 8), WarrenTerminalOutputSlice(
            epoch: 8,
            sequence: 100,
            payload: Data("xyz".utf8)
        ))
    }
}

private actor SendProgress {
    private(set) var sentCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordSend() {
        sentCount += 1
        let ready = waiters.filter { sentCount >= $0.count }
        waiters.removeAll { sentCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForSends(_ count: Int) async {
        guard sentCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private final class LockedDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }
}

@MainActor
private final class PausingWorkspaceCreationFake {
    private let projectID: ProjectID
    private let taskID: TaskID?
    private let callExpectations: [XCTestExpectation]
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var requests: [WorkspaceCreationRequest] = []
    private(set) var parameters: [[String: String]] = []

    var callCount: Int { parameters.count }

    init(
        projectID: ProjectID,
        taskID: TaskID?,
        callExpectations: [XCTestExpectation]
    ) {
        self.projectID = projectID
        self.taskID = taskID
        self.callExpectations = callExpectations
    }

    func create(_ request: WorkspaceCreationRequest) async throws {
        requests.append(request)
        parameters.append(WarrenRemoteWorkspaceProtocol.createParameters(
            projectID: projectID,
            taskID: taskID,
            creation: request
        ))
        callExpectations[parameters.count - 1].fulfill()
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeed() {
        continuations.removeFirst().resume()
    }

    func fail(_ error: Error) {
        continuations.removeFirst().resume(throwing: error)
    }
}
