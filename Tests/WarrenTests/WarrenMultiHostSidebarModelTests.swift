import Foundation
import XCTest
@testable import Warren
import WarrenDesktop
import WarrenDomain
import WarrenTransport

final class WarrenMultiHostSidebarModelTests: XCTestCase {
    func testResolveAliasesPreservesOrderWithoutAddingCurrentHost() {
        let resolved = WarrenMultiHostSidebarModel.resolveAliases(
            display: WarrenDisplayConfiguration(endpoints: ["dev", "dev", "prod"]),
            current: "local"
        )

        XCTAssertEqual(resolved.aliases, ["dev", "prod"])
        XCTAssertNil(resolved.error)

        let legacy = WarrenMultiHostSidebarModel.resolveAliases(
            display: nil,
            current: "prod"
        )
        XCTAssertEqual(legacy.aliases, ["prod"])
        XCTAssertNil(legacy.error)
    }

    func testResolveAliasesFallsBackForMalformedOrFutureConfiguration() {
        let malformed = WarrenMultiHostSidebarModel.resolveAliases(
            display: WarrenDisplayConfiguration(endpoints: [" dev"]),
            current: "local"
        )
        XCTAssertEqual(malformed.aliases, ["local"])
        XCTAssertEqual(malformed.error, "The display endpoint set is invalid.")

        let future = WarrenMultiHostSidebarModel.resolveAliases(
            display: WarrenDisplayConfiguration(version: 2, endpoints: ["prod"]),
            current: "local"
        )
        XCTAssertEqual(future.aliases, ["local"])
        XCTAssertEqual(future.error, "Unsupported display configuration version 2.")
    }

    func testRosterRevisionPreventsOlderSnapshotFromReplacingNewerRoster() {
        let current = roster(revision: 4)

        XCTAssertFalse(WarrenMultiHostSidebarModel.shouldApplyRoster(
            roster(revision: 3),
            over: current
        ))
        XCTAssertTrue(WarrenMultiHostSidebarModel.shouldApplyRoster(
            roster(revision: 4),
            over: current
        ))
        XCTAssertTrue(WarrenMultiHostSidebarModel.shouldApplyRoster(
            roster(revision: 5),
            over: current
        ))
        XCTAssertFalse(WarrenMultiHostSidebarModel.shouldApplyRoster(
            roster(revision: nil),
            over: current
        ))
    }

    func testRosterProjectionRetainsTasksAndWorkspaceActivity() throws {
        let hostID = "00000000-0000-4000-8000-000000000001"
        let taskID = "00000000-0000-4000-8000-000000000002"
        let projectID = "00000000-0000-4000-8000-000000000003"
        let workspaceID = "00000000-0000-4000-8000-000000000004"
        let sessionID = "00000000-0000-4000-8000-000000000005"
        let roster = WarrenRemoteRoster(
            revision: 7,
            host: .init(id: hostID, name: "Build VPS"),
            tasks: [.init(id: taskID, name: "Release")],
            projects: [.init(id: projectID, name: "repository-a", path: "/srv/repository-a")],
            workspaces: [.init(
                id: workspaceID,
                projectID: projectID,
                taskID: taskID,
                name: "release/test",
                path: "/srv/repository-a"
            )],
            sessions: [.init(
                id: sessionID,
                workspaceID: workspaceID,
                title: "Codex",
                kind: "codex",
                lifecycle: "running",
                agentStatus: .init(activity: .working)
            )]
        )

        let projection = WarrenMultiHostSidebarModel.makeProjection(
            endpointID: "build",
            endpointLabel: "Build",
            roster: roster,
            connectionState: .attached,
            lastError: nil
        )
        let domainWorkspaceID = try XCTUnwrap(WorkspaceID(uuidString: workspaceID))

        XCTAssertEqual(projection.title, "Build · Build VPS")
        XCTAssertEqual(projection.tasks.map(\.name), ["Release"])
        XCTAssertEqual(projection.projectGroups.map(\.project.name), ["repository-a"])
        XCTAssertEqual(projection.projectGroups.first?.workspaces.map(\.name), ["release/test"])
        XCTAssertEqual(projection.activeWorkspaceIDs, [domainWorkspaceID])
        XCTAssertEqual(projection.workspaceActivitySummaries[domainWorkspaceID]?.activity, .working)
        XCTAssertEqual(projection.workspaceActivitySummaries[domainWorkspaceID]?.activeTabCount, 1)
    }

    @MainActor
    func testUnknownAndOverflowHostsDoNotReplaceTheActiveHostProjection() {
        let model = WarrenMultiHostSidebarModel()
        defer { model.stop() }

        let host = Host(name: "Local Mac")
        let project = Project(hostID: host.id, name: "local-project", rootPath: "/tmp/local-project")
        let activeProjection = WarrenDesktopProjection(
            host: host,
            groups: [.init(project: project)],
            connectionState: .attached
        )
        let aliases = ["local"] + (1...8).map { "missing-\($0)" }

        model.configure(
            display: WarrenDisplayConfiguration(endpoints: aliases),
            endpoints: [],
            activeEndpointID: "local",
            activeProjection: activeProjection,
            activeConnectionError: nil
        )

        XCTAssertEqual(model.projection.host(for: "local")?.projectGroups, activeProjection.groups)
        XCTAssertEqual(model.projection.host(for: "missing-1")?.connectionState, .failed)
        XCTAssertEqual(model.projection.host(for: "missing-8")?.connectionState, .disconnected)
        XCTAssertEqual(
            model.projection.host(for: "missing-8")?.lastError,
            "Sidebar connection limit reached."
        )
        XCTAssertEqual(
            model.configurationError,
            "Display endpoint missing-1 is not configured. Update the endpoint catalog and retry."
        )
    }

    @MainActor
    func testDisplayNamesApplyToLocalAndRemoteHostSections() {
        let model = WarrenMultiHostSidebarModel()
        defer { model.stop() }

        let host = Host(name: "Local Mac")
        let activeProjection = WarrenDesktopProjection(
            host: host,
            groups: [],
            connectionState: .attached
        )
        let remote = WarrenRemoteEndpointConfiguration(
            name: "prod",
            url: "http://127.0.0.1:1",
            token: "token"
        )

        model.configure(
            display: WarrenDisplayConfiguration(
                endpoints: ["local", "prod"],
                names: ["local": "Office Mac", "prod": "Production"]
            ),
            endpoints: [remote],
            activeEndpointID: "local",
            activeProjection: activeProjection,
            activeConnectionError: nil
        )

        XCTAssertEqual(model.projection.host(for: "local")?.endpointLabel, "Office Mac")
        XCTAssertEqual(model.projection.host(for: "local")?.title, "Office Mac · Local Mac")
        XCTAssertEqual(model.projection.host(for: "prod")?.endpointLabel, "Production")
    }

    private func roster(revision: UInt64?) -> WarrenRemoteRoster {
        WarrenRemoteRoster(
            revision: revision,
            host: .init(
                id: "00000000-0000-4000-8000-000000000099",
                name: "Test Host"
            )
        )
    }
}
