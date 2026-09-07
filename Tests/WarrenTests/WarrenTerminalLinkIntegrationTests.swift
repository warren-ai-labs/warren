import XCTest
import SwiftUI
import Combine
import GhosttyAdapter
import WarrenDomain
@testable import WarrenDesktop
@testable import Warren

final class WarrenTerminalLinkIntegrationTests: XCTestCase {
    private var tempDirectory: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: WarrenPreferenceKey.embeddedEditorOpenLinks)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        UserDefaults.standard.removeObject(forKey: WarrenPreferenceKey.embeddedEditorOpenLinks)
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    @MainActor
    func testLinkInterceptionHonorsDisabledPreference() throws {
        UserDefaults.standard.set(false, forKey: WarrenPreferenceKey.embeddedEditorOpenLinks)

        let surfaceManager = TerminalSurfaceManager()
        let remoteModel = WarrenRemoteApplicationModel(surfaceManager: surfaceManager)
        let editorModel = WarrenEmbeddedEditorModel()

        var openEditorNotificationFired = false
        NotificationCenter.default.publisher(for: WarrenDesktopCommand.openEmbeddedEditor)
            .sink { _ in openEditorNotificationFired = true }
            .store(in: &cancellables)

        let hostID = HostID()
        let projectID = ProjectID()
        let workspaceID = WorkspaceID()
        let workspace = Workspace(
            id: workspaceID,
            projectID: projectID,
            name: "test-workspace",
            path: tempDirectory.path
        )
        let project = Project(id: projectID, hostID: hostID, name: "test-project", rootPath: tempDirectory.path)
        let sessionID = TerminalSessionID()

        let projection = WarrenDesktopProjection(
            host: Host(id: hostID, name: "TestHost"),
            projects: [project],
            workspaces: [workspace],
            sessionWorkspaceIDs: [sessionID: workspaceID]
        )
        _ = remoteModel.publishProjectionIfChanged(projection)

        remoteModel.onOpenTerminalURL = { [weak remoteModel, weak editorModel] targetSessionID, urlString, kind, workingDirectory in
            guard UserDefaults.standard.bool(forKey: WarrenPreferenceKey.embeddedEditorOpenLinks) else {
                return false
            }
            guard let remoteModel, let editorModel else { return false }
            guard let targetWorkspaceID = remoteModel.projection.sessionWorkspaceIDs[targetSessionID],
                  let targetWorkspace = remoteModel.projection.groups.flatMap(\.workspaces).first(where: { $0.id == targetWorkspaceID }) else {
                return false
            }
            guard let target = WarrenTerminalLinkParser.parse(
                urlString,
                workingDirectory: workingDirectory,
                workspacePath: targetWorkspace.path
            ) else {
                return false
            }
            NotificationCenter.default.post(
                name: WarrenDesktopCommand.openEmbeddedEditor,
                object: targetWorkspace.id
            )
            editorModel.openFile(
                workspacePath: targetWorkspace.path,
                filePath: target.path,
                line: target.line,
                column: target.column
            )
            return true
        }

        let testFile = tempDirectory.appendingPathComponent("main.swift")
        try "print(1)".write(to: testFile, atomically: true, encoding: .utf8)

        let handled = remoteModel.onOpenTerminalURL?(sessionID, testFile.path, .text, tempDirectory.path) ?? false
        XCTAssertFalse(handled, "Link should not be handled when preference is disabled")
        XCTAssertFalse(openEditorNotificationFired)
    }

    @MainActor
    func testLinkInterceptionOpensEmbeddedEditorWhenEnabled() throws {
        UserDefaults.standard.set(true, forKey: WarrenPreferenceKey.embeddedEditorOpenLinks)

        let surfaceManager = TerminalSurfaceManager()
        let remoteModel = WarrenRemoteApplicationModel(surfaceManager: surfaceManager)
        let editorModel = WarrenEmbeddedEditorModel()

        let hostID = HostID()
        let projectID = ProjectID()
        let workspaceID = WorkspaceID()
        let workspace = Workspace(
            id: workspaceID,
            projectID: projectID,
            name: "test-workspace",
            path: tempDirectory.path
        )
        let project = Project(id: projectID, hostID: hostID, name: "test-project", rootPath: tempDirectory.path)
        let sessionID = TerminalSessionID()

        let projection = WarrenDesktopProjection(
            host: Host(id: hostID, name: "TestHost"),
            projects: [project],
            workspaces: [workspace],
            sessionWorkspaceIDs: [sessionID: workspaceID]
        )
        _ = remoteModel.publishProjectionIfChanged(projection)

        var receivedWorkspaceID: WorkspaceID?
        NotificationCenter.default.publisher(for: WarrenDesktopCommand.openEmbeddedEditor)
            .sink { note in receivedWorkspaceID = note.object as? WorkspaceID }
            .store(in: &cancellables)

        remoteModel.onOpenTerminalURL = { [weak remoteModel, weak editorModel] targetSessionID, urlString, kind, workingDirectory in
            guard UserDefaults.standard.bool(forKey: WarrenPreferenceKey.embeddedEditorOpenLinks) else {
                return false
            }
            guard let remoteModel, let editorModel else { return false }
            guard let targetWorkspaceID = remoteModel.projection.sessionWorkspaceIDs[targetSessionID],
                  let targetWorkspace = remoteModel.projection.groups.flatMap(\.workspaces).first(where: { $0.id == targetWorkspaceID }) else {
                return false
            }
            guard let target = WarrenTerminalLinkParser.parse(
                urlString,
                workingDirectory: workingDirectory,
                workspacePath: targetWorkspace.path
            ) else {
                return false
            }
            NotificationCenter.default.post(
                name: WarrenDesktopCommand.openEmbeddedEditor,
                object: targetWorkspace.id
            )
            editorModel.openFile(
                workspacePath: targetWorkspace.path,
                filePath: target.path,
                line: target.line,
                column: target.column
            )
            return true
        }

        let testFile = tempDirectory.appendingPathComponent("main.swift")
        try "print(1)".write(to: testFile, atomically: true, encoding: .utf8)

        // 1. External URL should NOT be intercepted
        let webHandled = remoteModel.onOpenTerminalURL?(sessionID, "https://github.com", .text, tempDirectory.path) ?? false
        XCTAssertFalse(webHandled, "Web URL must not be intercepted")
        XCTAssertNil(receivedWorkspaceID)

        // 2. Relative file link with line and column
        let fileHandled = remoteModel.onOpenTerminalURL?(sessionID, "main.swift:42:10", .text, tempDirectory.path) ?? false
        XCTAssertTrue(fileHandled, "Valid file link must be intercepted")
        XCTAssertEqual(receivedWorkspaceID, workspaceID)

        // 3. Verify editor target and pending open file were set
        XCTAssertEqual(editorModel.activeWorkspacePath, tempDirectory.path)
    }

    @MainActor
    func testGhosttySurfaceOpenURLHandlerRoutesToEmbeddedEditor() async throws {
        UserDefaults.standard.set(true, forKey: WarrenPreferenceKey.embeddedEditorOpenLinks)

        let surfaceManager = TerminalSurfaceManager()
        let remoteModel = WarrenRemoteApplicationModel(surfaceManager: surfaceManager)
        let editorModel = WarrenEmbeddedEditorModel()

        let hostID = HostID()
        let projectID = ProjectID()
        let workspaceID = WorkspaceID()
        let workspace = Workspace(
            id: workspaceID,
            projectID: projectID,
            name: "test-workspace",
            path: tempDirectory.path
        )
        let project = Project(id: projectID, hostID: hostID, name: "test-project", rootPath: tempDirectory.path)
        let sessionID = TerminalSessionID()

        let projection = WarrenDesktopProjection(
            host: Host(id: hostID, name: "TestHost"),
            projects: [project],
            workspaces: [workspace],
            sessionWorkspaceIDs: [sessionID: workspaceID]
        )
        _ = remoteModel.publishProjectionIfChanged(projection)

        var receivedWorkspaceID: WorkspaceID?
        NotificationCenter.default.publisher(for: WarrenDesktopCommand.openEmbeddedEditor)
            .sink { note in receivedWorkspaceID = note.object as? WorkspaceID }
            .store(in: &cancellables)

        remoteModel.onOpenTerminalURL = { [weak remoteModel, weak editorModel] targetSessionID, urlString, kind, workingDirectory in
            guard UserDefaults.standard.bool(forKey: WarrenPreferenceKey.embeddedEditorOpenLinks) else {
                return false
            }
            guard let remoteModel, let editorModel else { return false }
            guard let targetWorkspaceID = remoteModel.projection.sessionWorkspaceIDs[targetSessionID],
                  let targetWorkspace = remoteModel.projection.groups.flatMap(\.workspaces).first(where: { $0.id == targetWorkspaceID }) else {
                return false
            }
            guard let target = WarrenTerminalLinkParser.parse(
                urlString,
                workingDirectory: workingDirectory,
                workspacePath: targetWorkspace.path
            ) else {
                return false
            }
            NotificationCenter.default.post(
                name: WarrenDesktopCommand.openEmbeddedEditor,
                object: targetWorkspace.id
            )
            editorModel.openFile(
                workspacePath: targetWorkspace.path,
                filePath: target.path,
                line: target.line,
                column: target.column
            )
            return true
        }

        let tempPath = tempDirectory.path
        let surface = GhosttySurface(
            id: sessionID,
            attachmentID: TerminalAttachmentID(),
            workingDirectory: tempPath,
            onInput: { _ in },
            onResize: { _, _ in },
            onOpenURL: { [weak remoteModel] url, kind, workingDirectory in
                remoteModel?.onOpenTerminalURL?(sessionID, url, kind, workingDirectory ?? tempPath) ?? false
            }
        )

        let testFile = tempDirectory.appendingPathComponent("example.rs")
        try "fn main() {}".write(to: testFile, atomically: true, encoding: .utf8)

        // Simulate Ghostty openURLHandler invocation with a relative link
        surface.state.openURLHandler?("example.rs:15:3", .text)

        // Give MainActor Task time to execute
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(receivedWorkspaceID, workspaceID)
        XCTAssertEqual(editorModel.activeWorkspacePath, tempDirectory.path)
    }
}
