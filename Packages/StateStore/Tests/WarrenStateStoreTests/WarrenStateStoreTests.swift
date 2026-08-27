import Foundation
import XCTest
import GRDB
@testable import WarrenStateStore
import WarrenClientCore
import WarrenDomain

final class WarrenStateStoreTests: XCTestCase {
    func testSQLiteClientLayoutRoundTripKeepsWorkspaceViewsIndependent() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        var state = try makeRecoverableState()
        let firstWorkspace = state.workspaces[0]
        let secondWorkspace = Workspace(
            projectID: state.projects[0].id,
            name: "review",
            path: "/tmp/warren-review",
            branch: "review"
        )
        let secondSession = PersistedTerminalSession(
            workspaceID: secondWorkspace.id,
            workingDirectory: secondWorkspace.path,
            terminalSize: try XCTUnwrap(TerminalSize(columns: 100, rows: 30)),
            title: "Review"
        )
        state.workspaces.append(secondWorkspace)
        state.terminalSessions.append(secondSession)
        try await repository.save(state)

        let clientID = ClientID()
        let windowID = ClientWindowID()
        let firstTab = ClientTab(
            id: "first",
            title: "Codex",
            sessionID: state.terminalSessions[0].id,
            kind: .codex
        )
        let secondTab = ClientTab(
            id: "second",
            title: "Review",
            sessionID: secondSession.id
        )
        let firstGroupID = TerminalGroupID()
        let secondGroupID = TerminalGroupID()
        let firstGroupTab = ClientTab(
            id: "group-first",
            title: "Remote shell",
            sessionID: TerminalSessionID(),
            kind: .shell
        )
        let secondGroupTab = ClientTab(
            id: "group-second",
            title: "Remote Codex",
            sessionID: TerminalSessionID(),
            kind: .codex
        )
        let window = try XCTUnwrap(ClientWindowLayout(
            id: windowID,
            workspaceViews: [
                ClientWorkspaceView(
                    workspaceID: firstWorkspace.id,
                    tabs: [firstTab],
                    activeTabID: firstTab.id
                ),
                ClientWorkspaceView(
                    workspaceID: secondWorkspace.id,
                    tabs: [secondTab],
                    activeTabID: secondTab.id
                ),
            ],
            activeTerminalGroupID: firstGroupID,
            terminalGroupViews: [
                ClientTerminalGroupView(
                    terminalGroupID: firstGroupID,
                    tabs: [firstGroupTab],
                    activeTabID: firstGroupTab.id
                ),
                ClientTerminalGroupView(
                    terminalGroupID: secondGroupID,
                    tabs: [secondGroupTab],
                    activeTabID: secondGroupTab.id
                ),
            ]
        ))
        let expected = ClientLayoutSnapshot(clientID: clientID, windows: [window])
        try await repository.saveClientLayout(expected)

        let loaded = try await repository.loadClientLayout(
            clientID: clientID,
            defaultWindowID: windowID
        )
        XCTAssertEqual(loaded, expected)
    }

    func testSQLiteRoundTripPreservesNormalizedResourceGraph() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        var state = try makeRecoverableState()
        state.projects[0].pinned = true
        state.workspaces[0].pinned = true
        state.terminalSessions[0].customTitle = "My Custom Session"
        state.terminalSessions[0].pinned = true

        try await repository.save(state)
        let loaded = try await repository.load()

        XCTAssertEqual(loaded, state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.url.path))
    }

    func testSQLiteDeleteSessionRemovesTerminalGroupTabReferences() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        let state = try makeRecoverableState()
        try await repository.save(state)

        let clientID = ClientID()
        let windowID = ClientWindowID()
        let groupID = TerminalGroupID()
        let tab = ClientTab(
            id: "group-session",
            title: "Remote session",
            sessionID: state.terminalSessions[0].id
        )
        let window = try XCTUnwrap(ClientWindowLayout(
            id: windowID,
            activeTerminalGroupID: groupID,
            terminalGroupViews: [
                ClientTerminalGroupView(
                    terminalGroupID: groupID,
                    tabs: [tab],
                    activeTabID: tab.id
                ),
            ]
        ))
        try await repository.saveClientLayout(ClientLayoutSnapshot(clientID: clientID, windows: [window]))

        try await repository.deleteSession(state.terminalSessions[0].id)

        let loaded = try await repository.loadClientLayout(
            clientID: clientID,
            defaultWindowID: windowID
        )
        XCTAssertEqual(loaded.windows[0].terminalGroupView(for: groupID)?.tabs, [])
        XCTAssertNil(loaded.windows[0].terminalGroupView(for: groupID)?.activeTabID)
    }

    func testSQLiteDeleteWorkspaceRemovesSessionsAndReceipts() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        var state = try makeRecoverableState()
        state.requestReceipts.append(
            PersistedRequestReceipt(
                requestID: UUID(),
                commandKind: "create_workspace",
                resourceID: state.workspaces[0].id.description,
                completedAt: Date()
            )
        )
        try await repository.save(state)
        let workspaceID = state.workspaces[0].id
        let sessionID = state.terminalSessions[0].id

        try await repository.deleteWorkspace(workspaceID)

        let loaded = try await repository.load()
        XCTAssertFalse(loaded.workspaces.contains { $0.id == workspaceID })
        XCTAssertFalse(loaded.terminalSessions.contains { $0.id == sessionID })
        XCTAssertFalse(loaded.requestReceipts.contains {
            $0.resourceID == workspaceID.description
        })
    }

    func testSQLiteDeleteProjectRemovesWorkspacesSessionsAndReceipts() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        var state = try makeRecoverableState()
        state.requestReceipts.append(
            PersistedRequestReceipt(
                requestID: UUID(),
                commandKind: "create_workspace",
                resourceID: state.workspaces[0].id.description,
                completedAt: Date()
            )
        )
        try await repository.save(state)
        let projectID = state.projects[0].id
        let workspaceID = state.workspaces[0].id
        let sessionID = state.terminalSessions[0].id

        try await repository.deleteProject(projectID)

        let loaded = try await repository.load()
        XCTAssertFalse(loaded.projects.contains { $0.id == projectID })
        XCTAssertFalse(loaded.workspaces.contains { $0.id == workspaceID })
        XCTAssertFalse(loaded.terminalSessions.contains { $0.id == sessionID })
        XCTAssertFalse(loaded.requestReceipts.contains {
            $0.resourceID == workspaceID.description
        })
    }

    func testSQLiteConstraintFailureRollsBackWholeSave() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        let original = try makeRecoverableState()
        try await repository.save(original)

        let project = try XCTUnwrap(original.projects.first)
        let duplicatePath = try XCTUnwrap(original.workspaces.first).path
        let invalid = PersistedHostState(
            hosts: original.hosts,
            projects: original.projects,
            workspaces: original.workspaces + [
                Workspace(
                    projectID: project.id,
                    name: "duplicate",
                    path: duplicatePath,
                    branch: "duplicate"
                ),
            ],
            terminalSessions: original.terminalSessions
        )

        do {
            try await repository.save(invalid)
            XCTFail("Expected duplicate normalized workspace path to fail")
        } catch let error as HostStateRepositoryError {
            guard case .databaseWriteFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let recovered = try await repository.load()
        XCTAssertEqual(recovered, original)
    }

    func testSQLiteRejectsOrphanedWorkspaceAndKeepsPreviousState() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        let original = try makeRecoverableState()
        try await repository.save(original)
        let orphan = Workspace(
            projectID: ProjectID(),
            name: "orphan",
            path: "/tmp/warren-orphan"
        )

        do {
            try await repository.save(
                PersistedHostState(
                    hosts: original.hosts,
                    projects: original.projects,
                    workspaces: original.workspaces + [orphan],
                    terminalSessions: original.terminalSessions
                )
            )
            XCTFail("Expected foreign key violation")
        } catch let error as HostStateRepositoryError {
            guard case .databaseWriteFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let recovered = try await repository.load()
        XCTAssertEqual(recovered, original)
    }

    func testJSONRoundTripPreservesRecoverableState() async throws {
        let host = Host(name: "Mac")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/warren",
            branch: "main"
        )
        let persistedSession = PersistedTerminalSession(
            workspaceID: workspace.id,
            epoch: 4,
            sequence: 19,
            workingDirectory: "/tmp/warren",
            terminalSize: try XCTUnwrap(TerminalSize(columns: 120, rows: 40)),
            runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor(
                runtime: "ghostline",
                identifier: "warren-main",
                metadata: [:]
            ),
            agentSessionID: "codex-thread-123"
        )
        let state = PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persistedSession]
        )
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)

        try await repository.save(state)
        let loaded = try await repository.load()

        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.terminalSessions[0].agentSessionID, "codex-thread-123")
        XCTAssertEqual(loaded.terminalSessions[0].terminalSession.epoch, 4)
        XCTAssertEqual(loaded.terminalSessions[0].terminalSize.columns, 120)
    }

    func testSaveAtomicallyOverwritesPreviousDocument() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)
        let first = PersistedHostState(hosts: [Host(name: "first")])
        let second = PersistedHostState(hosts: [Host(name: "second")])

        try await repository.save(first)
        let firstData = try Data(contentsOf: temporaryFile.url)
        try await repository.save(second)
        let secondData = try Data(contentsOf: temporaryFile.url)
        let loaded = try await repository.load()

        XCTAssertNotEqual(firstData, secondData)
        XCTAssertEqual(loaded, second)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporaryFile.url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".\(temporaryFile.url.lastPathComponent).") &&
            $0.pathExtension == "tmp" }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMissingFileReturnsEmptyState() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)
        let state = try await repository.load()

        XCTAssertEqual(state, .empty)
    }

    func testCorruptedJSONReturnsStructuredError() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        try Data("{ definitely not JSON".utf8).write(to: temporaryFile.url)
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)

        do {
            _ = try await repository.load()
            XCTFail("Expected corrupted JSON to fail")
        } catch let error as HostStateRepositoryError {
            guard case .corruptedJSON = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFutureSchemaReturnsStructuredError() async throws {
        let temporaryFile = try TemporaryStateFile()
        defer { try? temporaryFile.cleanup() }
        let futureVersion = PersistedHostState.currentSchemaVersion + 1
        let futureState = PersistedHostState(schemaVersion: futureVersion)
        try JSONEncoder().encode(futureState).write(to: temporaryFile.url)
        let repository = JSONFileHostStateRepository(fileURL: temporaryFile.url)

        do {
            _ = try await repository.load()
            XCTFail("Expected a future schema to fail")
        } catch let error as HostStateRepositoryError {
            XCTAssertEqual(
                error,
                .unsupportedSchemaVersion(
                    found: futureVersion,
                    supported: PersistedHostState.currentSchemaVersion
                )
            )
        }
    }

    func testTransientStateCannotEnterPersistedModel() throws {
        let state = PersistedHostState(hosts: [Host(name: "Mac")])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        XCTAssertNil(object["attachments"])
        XCTAssertNil(object["controlLeases"])
        XCTAssertNil(object["clientLayouts"])
        XCTAssertFalse(Mirror(reflecting: state).children.contains { child in
            ["attachments", "controlLease", "clientLayout"].contains(child.label ?? "")
        })
    }

    func testLegacySessionJSONDefaultsKindToShellAndKeepsRecoveryFields() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "workspaceID": "22222222-2222-4222-8222-222222222222",
          "epoch": 3,
          "sequence": 12,
          "workingDirectory": "/tmp/warren",
          "terminalSize": {"columns": 120, "rows": 40}
        }
        """
        let session = try JSONDecoder().decode(
            PersistedTerminalSession.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(session.kind, .shell)
        XCTAssertNil(session.title)
        XCTAssertEqual(session.epoch, 3)
        XCTAssertEqual(session.sequence, 12)
        XCTAssertEqual(session.terminalSize.columns, 120)
    }

    func testLegacyProjectAndWorkspaceJSONDefaultOrderToZero() throws {
        let projectJSON = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "hostID": "22222222-2222-4222-8222-222222222222",
          "name": "warren",
          "rootPath": "/tmp/warren"
        }
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(projectJSON.utf8))
        XCTAssertEqual(project.order, 0)

        let workspaceJSON = """
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "projectID": "11111111-1111-4111-8111-111111111111",
          "name": "main",
          "path": "/tmp/warren",
          "branch": "main"
        }
        """
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(workspaceJSON.utf8))
        XCTAssertEqual(workspace.order, 0)
    }

    func testSQLiteSidebarOrderRoundTripAndMove() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        let host = Host(name: "Mac")
        let alpha = Project(hostID: host.id, name: "alpha", rootPath: "/tmp/alpha", order: 1)
        let bravo = Project(hostID: host.id, name: "bravo", rootPath: "/tmp/bravo", order: 0)
        let alphaMain = Workspace(
            projectID: alpha.id,
            name: "main",
            path: "/tmp/alpha",
            branch: "main",
            order: 1
        )
        let alphaReview = Workspace(
            projectID: alpha.id,
            name: "review",
            path: "/tmp/alpha-review",
            branch: "review",
            order: 0
        )
        let state = PersistedHostState(
            hosts: [host],
            projects: [alpha, bravo],
            workspaces: [alphaMain, alphaReview]
        )
        try await repository.save(state)

        var loaded = try await repository.load()
        XCTAssertEqual(loaded.projects.map(\.name), ["bravo", "alpha"])
        XCTAssertEqual(
            loaded.workspaces.filter { $0.projectID == alpha.id }.map(\.name),
            ["review", "main"]
        )

        try await repository.moveProject(alpha.id, before: bravo.id)
        try await repository.moveWorkspace(alphaMain.id, before: alphaReview.id)

        loaded = try await repository.load()
        XCTAssertEqual(loaded.projects.map(\.name), ["alpha", "bravo"])
        XCTAssertEqual(
            loaded.workspaces.filter { $0.projectID == alpha.id }.map(\.name),
            ["main", "review"]
        )
        XCTAssertEqual(
            loaded.workspaces.filter { $0.projectID == alpha.id }.map(\.order),
            [0, 1]
        )
        XCTAssertEqual(loaded.projects.map(\.order), [0, 1])
    }

    func testSQLiteOrderAndPinningMigrationsRunIndependently() async throws {
        let database = try TemporaryStateDatabase()
        defer { try? database.cleanup() }
        let repository = try SQLiteHostStateRepository(databaseURL: database.url)
        let host = Host(name: "Mac")
        let project = Project(
            hostID: host.id,
            name: "warren",
            rootPath: "/tmp/warren",
            pinned: true
        )
        let workspace = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/warren",
            branch: "main",
            pinned: true,
            order: 2
        )
        try await repository.save(PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace]
        ))

        // Simulate a database that already ran main's pinning migration but
        // never ran the sidebar-order migration: drop the order columns and
        // forget the migration record, then reopen.
        let queue = try DatabaseQueue(path: database.url.path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4_sidebar_order'")
            try db.execute(sql: "ALTER TABLE projects DROP COLUMN position")
            try db.execute(sql: "ALTER TABLE workspaces DROP COLUMN position")
        }

        let reopened = try SQLiteHostStateRepository(databaseURL: database.url)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.projects[0].pinned, true)
        XCTAssertEqual(loaded.workspaces[0].pinned, true)
        XCTAssertEqual(loaded.workspaces[0].order, 0)
    }

    private func makeRecoverableState() throws -> PersistedHostState {
        let host = Host(name: "Mac")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/warren",
            branch: "main"
        )
        let persistedSession = PersistedTerminalSession(
            workspaceID: workspace.id,
            epoch: 4,
            sequence: 19,
            workingDirectory: "/tmp/warren",
            terminalSize: try XCTUnwrap(TerminalSize(columns: 120, rows: 40)),
            runtimeAdoptionDescriptor: RuntimeAdoptionDescriptor(
                runtime: "ghostline",
                identifier: "warren-main-\(UUID().uuidString)",
                metadata: [:]
            ),
            kind: .codex,
            title: "Codex"
        )
        return PersistedHostState(
            hosts: [host],
            projects: [project],
            workspaces: [workspace],
            terminalSessions: [persistedSession]
        )
    }
}

private struct TemporaryStateFile {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarrenStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("host-state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

private struct TemporaryStateDatabase {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarrenSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("state.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
