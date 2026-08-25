import AppKit
import XCTest
@testable import WarrenDesktop
import WarrenClientCore
import WarrenDomain

final class WarrenDesktopCommandPaletteTests: XCTestCase {
    func testSearchIndexesWorkspaceBranchAndPath() {
        let host = Host(name: "Search Host")
        let project = Project(
            hostID: host.id,
            name: "Warren",
            rootPath: "/Users/me/warren"
        )
        let workspace = Workspace(
            projectID: project.id,
            name: "Review",
            path: "/Users/me/warren-review",
            branch: "feature/search"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace]
        )

        XCTAssertTrue(
            results(for: "feature/search", in: projection).contains {
                if case .workspace(workspace.id) = $0.kind { return true }
                return false
            }
        )
        XCTAssertTrue(
            results(for: "warren-review", in: projection).contains {
                if case .workspace(workspace.id) = $0.kind { return true }
                return false
            }
        )
    }

    func testSearchIndexesCustomSessionTitleAndUsesOpenSessionResult() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "Main",
            path: "/tmp/warren"
        )
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "session-tab",
            title: "Shell",
            sessionID: sessionID
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspace.id,
            tabID: tab.id,
            title: "Shell",
            customTitle: "Deploy API",
            runtimeProcess: "zsh",
            workingDirectory: workspace.path
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session],
            tabs: [tab]
        )

        let result = results(for: "deploy", in: projection).first {
            if case .session(sessionID) = $0.kind { return true }
            return false
        }

        XCTAssertEqual(result?.title, "Deploy API")
        XCTAssertTrue(result?.detail.contains("zsh") ?? false)
    }

    func testSearchIndexesTerminalGroupTitle() {
        let host = Host(name: "Search Host")
        let group = TerminalGroup(
            hostID: host.id,
            name: "Build Queue",
            home: "/tmp/build"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            groups: [],
            terminalGroups: [group]
        )

        XCTAssertTrue(
            results(for: "queue", in: projection).contains {
                if case .terminalGroup(group.id) = $0.kind { return true }
                return false
            }
        )
    }

    func testSearchIndexesPendingTabTitle() {
        let host = Host(name: "Search Host")
        let tab = ClientTab(
            id: "pending-tab",
            title: "On-call Notes",
            kind: .custom
        )
        let projection = WarrenDesktopProjection(
            host: host,
            groups: [],
            tabs: [tab]
        )

        XCTAssertTrue(
            results(for: "on-call", in: projection).contains {
                if case .tab(tab.id) = $0.kind { return true }
                return false
            }
        )
    }

    func testDirectTitleMatchRanksBeforeContextMatches() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "Search",
            path: "/tmp/warren-search",
            branch: "feature/palette"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace]
        )

        let matches = results(for: "warren", in: projection)

        XCTAssertEqual(matches.first?.kind, .project(project.id))
        XCTAssertTrue(matches.contains { $0.kind == .workspace(workspace.id) })
    }

    func testSessionMatchDoesNotInjectUnmatchedAncestors() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "Main", path: "/tmp/warren")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Deploy API",
            runtimeProcess: "zsh",
            workingDirectory: workspace.path
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )

        let matches = results(for: "deploy", in: projection)

        XCTAssertEqual(matches.map(\.kind), [.session(session.id)])
    }

    func testPathAppearsOnlyWhenItExplainsTheMatch() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "Review",
            path: "/tmp/hidden-location/review",
            branch: "feature/palette"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace]
        )

        let titleMatch = results(for: "palette", in: projection).first {
            $0.kind == .workspace(workspace.id)
        }
        let pathMatch = results(for: "hidden-location", in: projection).first {
            $0.kind == .workspace(workspace.id)
        }

        XCTAssertFalse(titleMatch?.detail.contains("hidden-location") ?? true)
        XCTAssertTrue(pathMatch?.detail.contains("hidden-location") ?? false)
    }

    func testEmptyQuerySuggestionsContainOnlyActiveOrPinnedResources() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let pinned = Workspace(
            projectID: project.id,
            name: "Pinned",
            path: "/tmp/warren-pinned",
            pinned: true
        )
        let idle = Workspace(
            projectID: project.id,
            name: "Idle",
            path: "/tmp/warren-idle"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [pinned, idle]
        )

        let suggestions = WarrenDesktopCommandPaletteSearch.Index(
            projection: projection
        ).suggestions()

        XCTAssertEqual(suggestions.map(\.kind), [.workspace(pinned.id)])
        XCTAssertEqual(suggestions.first?.accessoryLabel, "Pinned")
    }

    func testSelectionMovementWrapsAndSupportsBoundaries() {
        XCTAssertNil(WarrenDesktopCommandPaletteSelection.index(
            after: .next,
            currentIndex: 0,
            count: 0
        ))
        XCTAssertEqual(WarrenDesktopCommandPaletteSelection.index(
            after: .previous,
            currentIndex: 0,
            count: 3
        ), 2)
        XCTAssertEqual(WarrenDesktopCommandPaletteSelection.index(
            after: .next,
            currentIndex: 2,
            count: 3
        ), 0)
        XCTAssertEqual(WarrenDesktopCommandPaletteSelection.index(
            after: .first,
            currentIndex: 2,
            count: 3
        ), 0)
        XCTAssertEqual(WarrenDesktopCommandPaletteSelection.index(
            after: .last,
            currentIndex: 0,
            count: 3
        ), 2)
    }

    func testNativeTextCommandsCoverPaletteKeyboardNavigation() {
        XCTAssertEqual(
            WarrenDesktopCommandPaletteTextCommand.command(
                for: #selector(NSResponder.moveUp(_:))
            ),
            .move(.previous)
        )
        XCTAssertEqual(
            WarrenDesktopCommandPaletteTextCommand.command(
                for: #selector(NSResponder.moveDown(_:))
            ),
            .move(.next)
        )
        XCTAssertEqual(
            WarrenDesktopCommandPaletteTextCommand.command(
                for: #selector(NSResponder.moveToBeginningOfDocument(_:))
            ),
            .move(.first)
        )
        XCTAssertEqual(
            WarrenDesktopCommandPaletteTextCommand.command(
                for: #selector(NSResponder.moveToEndOfDocument(_:))
            ),
            .move(.last)
        )
        XCTAssertEqual(
            WarrenDesktopCommandPaletteTextCommand.command(
                for: #selector(NSResponder.insertNewline(_:))
            ),
            .submit
        )
        XCTAssertEqual(
            WarrenDesktopCommandPaletteTextCommand.command(
                for: #selector(NSResponder.cancelOperation(_:))
            ),
            .cancel
        )
        XCTAssertNil(
            WarrenDesktopCommandPaletteTextCommand.command(
                for: #selector(NSResponder.deleteBackward(_:))
            )
        )
    }

    func testIndexedSearchPerformanceAtScale() {
        let projection = largeProjection()
        let index = WarrenDesktopCommandPaletteSearch.Index(projection: projection)

        XCTAssertEqual(index.results(for: "feature/199-19").first?.title, "feature/199-19")
        measure {
            _ = index.results(for: "feature/199-19")
            _ = index.results(for: "feature")
        }
    }

    func testSearchIndexBuildPerformanceAtScale() {
        let projection = largeProjection()

        measure {
            _ = WarrenDesktopCommandPaletteSearch.Index(projection: projection)
        }
    }

    func testBoundedResultsEqualThePrefixOfTheFullRanking() {
        let index = WarrenDesktopCommandPaletteSearch.Index(
            projection: largeProjection()
        )

        let bounded = index.results(for: "feature", limit: 60)
        let full = index.results(for: "feature", limit: 5_000)

        XCTAssertEqual(bounded, Array(full.prefix(60)))
        XCTAssertTrue(index.results(for: "feature", limit: 0).isEmpty)
    }

    func testTerminalContextFocusIntentDefaultsToTrueAndCanBeSuppressed() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Main",
            path: "/tmp/warren"
        )
        let tab = ClientTab(id: "tab", title: "Shell")

        let defaultContext = WarrenDesktopTerminalContext(
            workspace: workspace,
            tab: tab
        )
        let suppressedContext = WarrenDesktopTerminalContext(
            workspace: workspace,
            tab: tab,
            wantsTerminalFocus: false
        )

        XCTAssertTrue(defaultContext.wantsTerminalFocus)
        XCTAssertFalse(suppressedContext.wantsTerminalFocus)
    }

    private func results(
        for query: String,
        in projection: WarrenDesktopProjection
    ) -> [WarrenDesktopCommandPaletteSearch.Result] {
        WarrenDesktopCommandPaletteSearch.results(for: query, in: projection)
    }

    private func largeProjection() -> WarrenDesktopProjection {
        let host = Host(name: "Search Host")
        let groups = (0..<200).map { projectIndex in
            let project = Project(
                hostID: host.id,
                name: "Project \(projectIndex)",
                rootPath: "/tmp/project-\(projectIndex)"
            )
            let workspaces = (0..<20).map { workspaceIndex in
                Workspace(
                    projectID: project.id,
                    name: "Workspace \(workspaceIndex)",
                    path: "/tmp/project-\(projectIndex)/workspace-\(workspaceIndex)",
                    branch: "feature/\(projectIndex)-\(workspaceIndex)"
                )
            }
            return WarrenDesktopProjectGroup(project: project, workspaces: workspaces)
        }
        return WarrenDesktopProjection(host: host, groups: groups)
    }
}
