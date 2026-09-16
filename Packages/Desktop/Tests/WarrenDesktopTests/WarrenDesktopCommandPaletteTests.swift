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

    func testSearchIndexesTaskNameAndTheBranchesItSpans() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let task = WarrenTask(hostID: host.id, name: "Palette rewrite")
        let workspace = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "Review",
            path: "/tmp/warren-review",
            branch: "feature/search"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [project],
            workspaces: [workspace]
        )

        XCTAssertTrue(
            results(for: "palette rewrite", in: projection).contains { $0.kind == .task(task.id) }
        )
        // A Task is how work is named, so the branches it holds must find it.
        XCTAssertTrue(
            results(for: "feature/search", in: projection).contains { $0.kind == .task(task.id) }
        )
    }

    func testTaskWithoutWorkspacesIsNotIndexedBecauseItOpensNothing() {
        let host = Host(name: "Search Host")
        let task = WarrenTask(hostID: host.id, name: "Empty task")
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [],
            workspaces: []
        )

        XCTAssertTrue(results(for: "empty", in: projection).isEmpty)
    }

    func testEndedSessionsAreNotSearchable() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "Main", path: "/tmp/warren")
        let ended = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Deploy API",
            state: .exited,
            workingDirectory: workspace.path
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [ended]
        )

        XCTAssertTrue(results(for: "deploy", in: projection).isEmpty)
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
        XCTAssertEqual(result?.context, "Warren › Main")
    }

    func testRowExplainsAMatchOnAHiddenFacet() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "Main", path: "/tmp/warren")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Shell",
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev",
            workingDirectory: workspace.path
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )

        // The match happened on the running command, which is not otherwise on
        // screen, so the row has to say so.
        let evidence = results(for: "npm", in: projection).first?.evidence
        XCTAssertEqual(evidence?.text, "npm run dev")
        XCTAssertEqual(evidence?.role, .alias)

        // A title match needs no explanation.
        XCTAssertNil(results(for: "shell", in: projection).first?.evidence)
    }

    func testSessionRowsCarryTheProviderThatOwnsTheirIcon() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "Main", path: "/tmp/warren")
        let agent = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Review",
            kind: .codex,
            workingDirectory: workspace.path
        )
        // A shell the Host has promoted through an Agent binding reads as that
        // Agent: the row names what is running, not what Warren launched.
        let promoted = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Review runner",
            kind: .shell,
            agentProvider: .claude,
            workingDirectory: workspace.path
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [agent, promoted]
        )

        let rows = results(for: "review", in: projection)
        XCTAssertEqual(
            rows.first { $0.kind == .session(agent.id) }?.providerKind,
            .codex
        )
        XCTAssertEqual(
            rows.first { $0.kind == .session(promoted.id) }?.providerKind,
            .claude
        )
        // Every provider Warren integrates owns a catalog entry, which is what
        // supplies the mark; a missing one would silently fall back to a glyph.
        XCTAssertNotNil(WarrenDesktopSessionPreset.builtIn(for: .codex))
        XCTAssertNotNil(WarrenDesktopSessionPreset.builtIn(for: .claude))
        XCTAssertNotNil(WarrenDesktopSessionPreset.builtIn(for: .shell))
    }

    func testNonSessionRowsHaveNoProviderAndKeepTheirScopeGlyph() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "Warren review",
            path: "/tmp/warren-review"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace]
        )

        for row in results(for: "warren", in: projection) {
            XCTAssertNil(row.providerKind, "\(row.kind) is not a Session")
        }
    }

    func testStatusFilterNarrowsToAttentionWorthySessions() {
        let host = Host(name: "Search Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "Main", path: "/tmp/warren")
        let blocked = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Deploy API",
            agentStatus: AgentStatus(activity: .blocked),
            workingDirectory: workspace.path
        )
        let ready = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Deploy Worker",
            agentStatus: AgentStatus(activity: .ready),
            workingDirectory: workspace.path
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [blocked, ready]
        )

        XCTAssertEqual(
            results(for: "@blocked deploy", in: projection).map(\.kind),
            [.session(blocked.id)]
        )
        XCTAssertEqual(
            results(for: "s:deploy", in: projection).count,
            2
        )
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

        XCTAssertNil(titleMatch?.evidence)
        XCTAssertEqual(pathMatch?.evidence?.role, .path)
        XCTAssertTrue(pathMatch?.evidence?.text.contains("hidden-location") ?? false)
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
        XCTAssertEqual(suggestions.first?.status, .pinned)
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
