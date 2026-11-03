import SwiftUI
import XCTest
import WarrenDesktop
import WarrenDomain
import WarrenClientCore

public struct WarrenDesktopFixture: Sendable {
    public let projection: WarrenDesktopProjection

    public var host: WarrenDomain.Host { projection.host }
    public var groups: [WarrenDesktopProjectGroup] { projection.groups }
    public var sessions: [WarrenDesktopSession] { projection.sessions }
    public var tabs: [ClientTab] { projection.tabs }
    public var isConnected: Bool { projection.isConnected }

    public init(projection: WarrenDesktopProjection) {
        self.projection = projection
    }

    public init(
        host: WarrenDomain.Host,
        groups: [WarrenDesktopProjectGroup],
        tabs: [ClientTab] = [],
        isConnected: Bool = true,
        sessions: [WarrenDesktopSession] = []
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                groups: groups,
                sessions: sessions,
                tabs: tabs,
                connectionState: isConnected ? .attached : .disconnected
            )
        )
    }

    public init(
        host: WarrenDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        tabs: [ClientTab] = [],
        isConnected: Bool = true,
        sessions: [WarrenDesktopSession] = []
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                projects: projects,
                workspaces: workspaces,
                sessions: sessions,
                tabs: tabs,
                connectionState: isConnected ? .attached : .disconnected
            )
        )
    }

    public func projectGroup(id: ProjectID) -> WarrenDesktopProjectGroup? {
        projection.projectGroup(id: id)
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        projection.workspace(id: id)
    }

    public func firstWorkspace(in projectID: ProjectID) -> Workspace? {
        projection.firstWorkspace(in: projectID)
    }

    /// Stable IDs keep preview diffing and UI tests deterministic.
    public static var preview: Self {
        let hostID = HostID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000001"))
        let projectID = ProjectID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000002"))
        let secondProjectID = ProjectID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000003"))
        let firstWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000004"))
        let secondWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000005"))
        let thirdWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000006"))
        let firstSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000007"))
        let secondSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000008"))
        let thirdSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000009"))

        let host = WarrenDomain.Host(id: hostID, name: "Local Mac")
        let project = Project(
            id: projectID,
            hostID: hostID,
            name: "Warren",
            rootPath: "/Users/demo/Code/warren"
        )
        let secondProject = Project(
            id: secondProjectID,
            hostID: hostID,
            name: "Superset",
            rootPath: "/Users/demo/Code/superset"
        )
        let workspaces = [
            Workspace(
                id: firstWorkspaceID,
                projectID: projectID,
                name: "main",
                path: "/Users/demo/Code/warren",
                branch: "main"
            ),
            Workspace(
                id: secondWorkspaceID,
                projectID: projectID,
                name: "feature/mobile-shell",
                path: "/Users/demo/Code/warren-feature",
                branch: "feature/mobile-shell"
            ),
            Workspace(
                id: thirdWorkspaceID,
                projectID: secondProjectID,
                name: "review",
                path: "/Users/demo/Code/superset-review",
                branch: "review/warren"
            ),
        ]
        let tabs = [
            ClientTab(
                id: "tab-main",
                title: "main",
                sessionID: firstSessionID,
                kind: .shell
            ),
            ClientTab(
                id: "tab-review",
                title: "review",
                sessionID: secondSessionID,
                kind: .claude
            ),
        ]
        let sessions = [
            WarrenDesktopSession(
                id: firstSessionID,
                workspaceID: firstWorkspaceID,
                tabID: "tab-main",
                title: "main",
                kind: .shell
            ),
            WarrenDesktopSession(
                id: secondSessionID,
                workspaceID: thirdWorkspaceID,
                tabID: "tab-review",
                title: "review",
                kind: .claude,
                // An unread completion, so the preview exercises the
                // acknowledgment path a real Host produces rather than only the
                // plain-shell case.
                activity: .ready,
                // ...and a last activity, so the preview shows the resting second
                // line a finished Session keeps.
                lastActivity: "Ran swift test"
            ),
            // A second Agent Session on the Workspace the probe expands, so the
            // real artifact shows an unread completion beside a running one
            // rather than only the plain-shell case.
            WarrenDesktopSession(
                id: thirdSessionID,
                workspaceID: firstWorkspaceID,
                tabID: "tab-agent",
                title: "migrate schema",
                kind: .codex,
                activity: .ready,
                lastActivity: "Edited Patch.swift"
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-00000000000A")),
                workspaceID: firstWorkspaceID,
                tabID: "tab-agent-working",
                title: "build docs",
                kind: .codex,
                activity: .working,
                currentStep: "Running swift build",
                lastActivity: "Ran swift build"
            ),
        ]

        return Self(
            projection: WarrenDesktopProjection(
                host: host,
                projects: [project, secondProject],
                workspaces: workspaces,
                sessions: sessions,
                tabs: tabs,
                sessionWorkspaceIDs: [
                    firstSessionID: firstWorkspaceID,
                    secondSessionID: thirdWorkspaceID,
                    thirdSessionID: firstWorkspaceID,
                    TerminalSessionID(
                        rawValue: Self.uuid("A0000000-0000-4000-8000-00000000000A")
                    ): firstWorkspaceID,
                ]
            )
        )
    }

    private static func uuid(_ string: String) -> UUID {
        // Fixture literals are compile-time-known and deliberately fail fast
        // if somebody edits one into a non-UUID value.
        UUID(uuidString: string)!
    }
}
