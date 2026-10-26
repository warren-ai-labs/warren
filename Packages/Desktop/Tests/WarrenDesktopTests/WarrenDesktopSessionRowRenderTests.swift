import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation
import XCTest
@testable import WarrenDesktop

/// The Session row at its real size, mounted in a hosting view.
///
/// The row is always two lines. Model tests can see which second line a Session
/// resolves to but not how much height the row takes to draw it, and the row's
/// whole point is that a working Session and a resting one are the same height:
/// anything else makes a worktree's Sessions jump as turns start and end.
final class WarrenDesktopSessionRowRenderTests: XCTestCase {
    private struct Harness {
        let hosting: NSHostingView<AnyView>
        let recorder: WarrenSemanticRecorder
        let projection: WarrenDesktopProjection
    }

    @MainActor
    private func mount(
        workspaceID: WorkspaceID,
        sessions: [WarrenDesktopSession],
        width: CGFloat = 300,
        height: CGFloat = 400,
        tree: WarrenDesktopSidebarTreeState = WarrenDesktopSidebarTreeState()
    ) -> Harness {
        let hostID = HostID()
        let projectID = ProjectID()
        let project = Project(
            id: projectID,
            hostID: hostID,
            name: "warren",
            rootPath: "/tmp/warren"
        )
        let workspace = Workspace(
            id: workspaceID,
            projectID: projectID,
            name: "feat/sidebar",
            path: "/tmp/warren-sidebar",
            branch: "feat/sidebar"
        )
        let projection = WarrenDesktopProjection(
            host: Host(id: hostID, name: "studio"),
            projects: [project],
            workspaces: [workspace],
            sessions: sessions
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeWorkspaceIDs: projection.activeWorkspaceIDs,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(tree),
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
        .frame(width: width, height: height, alignment: .topLeading)
        // The real sidebar draws its rows on the workbench card; the harness has
        // to paint that ground too, or a light text tier is judged on white.
        .background(WarrenColorTokens.resolved(for: .dark, material: .opaque).workbenchCardFill)
        .environment(\.warrenSemanticRecorder, recorder)
        .environment(\.colorScheme, .dark)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hosting = NSHostingView(rootView: AnyView(rows))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        return Harness(hosting: hosting, recorder: recorder, projection: projection)
    }

    @MainActor
    func testAWorkingAndARestingSessionRowAreTheSameTwoLineHeight() {
        let workspaceID = WorkspaceID()
        let working = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "tab-working",
            title: "build docs",
            kind: .codex,
            activity: .working,
            currentStep: "Running swift build",
            lastActivity: "Ran swift test"
        )
        let resting = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "tab-resting",
            title: "migrate schema",
            kind: .codex,
            activity: .ready,
            lastActivity: "Edited Patch.swift"
        )
        let untouched = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "tab-new",
            title: "Shell",
            kind: .shell
        )
        // The Workspace the Sessions hang under has to be the one in the tree,
        // so the fixture is rebuilt around these IDs.
        let harness = mount(workspaceID: workspaceID, sessions: [working, resting, untouched])
        let nodes = Dictionary(
            harness.recorder.snapshot().nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ids = [working, resting, untouched].map { session in
            "workspace-session.project-list.\(session.workspaceID!.description).\(session.id.description)"
        }
        for id in ids {
            XCTAssertNotNil(nodes[id], "\(id) should be on screen")
        }
        let heights = ids.compactMap { nodes[$0]?.frame.height }
        XCTAssertEqual(heights.count, 3)
        XCTAssertEqual(
            Set(heights.map { ($0 * 2).rounded() / 2 }).count,
            1,
            "Every Session row is the same height: \(heights)"
        )
        XCTAssertEqual(
            heights.first ?? 0,
            WarrenDesktopSidebarMetrics.sessionRowHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(WarrenDesktopSidebarMetrics.sessionRowHeight, 45, accuracy: 0.001)
    }

    /// Writes the mounted sidebar to PNGs when asked, so the row can be looked
    /// at as it is drawn rather than only measured. The design checks the same
    /// sessions at the narrow, default, and wide sidebar widths.
    @MainActor
    func testWritesTheSidebarWhenAnArtifactDirectoryIsGiven() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_SIDEBAR_IMAGES"] else {
            throw XCTSkip("Set WARREN_SIDEBAR_IMAGES to write sidebar PNGs")
        }
        let workspaceID = WorkspaceID()
        let now = Date()
        let planSessionID = TerminalSessionID()
        let doneSessionID = TerminalSessionID()
        let sessions = [
            WarrenDesktopSession(
                id: planSessionID,
                workspaceID: workspaceID,
                tabID: "tab-working",
                title: "多 host 侧边栏 UI 优化设计确认",
                kind: .claude,
                activity: .working,
                currentStep: "Running swift build --package-path Packages/WarrenKit",
                lastActivity: "Ran swift test",
                plan: WarrenDesktopPlanProgress(done: 3, total: 5, currentStep: "Wire the sidebar"),
                context: WarrenDesktopContextUsage(used: 88, size: 100),
                turnCounts: ["Edited 2 files"],
                turnStartedAt: now.addingTimeInterval(-72),
                subagents: [
                    WarrenDesktopSubagent(
                        id: "agent-1",
                        title: "Explore",
                        summary: "查找 SidebarView 的所有调用点",
                        state: .running,
                        lastActivity: "Searching SidebarView"
                    ),
                    WarrenDesktopSubagent(
                        id: "agent-2",
                        title: "Plan",
                        summary: "拆分侧栏改动成 3 个 PR",
                        state: .running
                    ),
                    WarrenDesktopSubagent(
                        id: "agent-3",
                        title: "Explore",
                        summary: "读取 sidebar-adopted 规范",
                        state: .completed
                    ),
                ]
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-codex",
                title: "codex 与 claude 自动标题调研",
                kind: .codex,
                activity: .working,
                currentStep: "Editing SidebarView.swift",
                context: WarrenDesktopContextUsage(used: 88, size: 100),
                turnCounts: ["Read 4 files"],
                turnStartedAt: now.addingTimeInterval(-18),
                subagents: [
                    WarrenDesktopSubagent(
                        id: "agent-4",
                        title: "general",
                        summary: "对比 codex 的标题生成 prompt",
                        state: .running
                    ),
                ]
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-shell-running",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-4200),
                runtimeProcess: "npm",
                runtimeCommandLine: "npm run dev",
                workingDirectory: "/tmp/warren-sidebar",
                shellState: WarrenDesktopShellState(
                    atPrompt: false,
                    runningCommand: "sudo npm run dev --package-path Packages/WarrenKit",
                    shellName: "zsh",
                    commandStartedAt: now.addingTimeInterval(-3 * 60)
                )
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-shell-ran",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-4200),
                workingDirectory: "/tmp/warren-sidebar/Sources/WarrenKit",
                shellState: WarrenDesktopShellState(
                    atPrompt: true,
                    lastCommand: "swift build --package-path Packages/WarrenKit",
                    lastExitCode: 0,
                    lastExitAt: now.addingTimeInterval(-2 * 60),
                    shellName: "zsh"
                )
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-shell-failed",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-4200),
                workingDirectory: "/tmp/warren-sidebar/Sources/WarrenKit/Tests",
                shellState: WarrenDesktopShellState(
                    atPrompt: true,
                    lastCommand: "swift test --filter Sidebar",
                    lastExitCode: 1,
                    lastExitAt: now.addingTimeInterval(-5 * 60),
                    shellName: "zsh"
                )
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-shell-new",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-3600),
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path + "/Downloads",
                shellState: WarrenDesktopShellState(atPrompt: true, shellName: "zsh")
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-counted",
                title: "梳理二级菜单与右键弹层",
                kind: .pi,
                activity: .ready,
                activityUpdatedAt: now.addingTimeInterval(-42 * 60),
                lastActivity: "Edited 3 files",
                turnCounts: ["Edited 3 files", "Ran 5 commands"]
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-qa",
                title: "切回原生 claude",
                kind: .pi,
                activity: .ready,
                activityUpdatedAt: now.addingTimeInterval(-2 * 3600),
                lastActivity: "Read 2 files"
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-context",
                title: "ak：claude 用 pi 的命令补全",
                kind: .claude,
                activity: .ready,
                activityUpdatedAt: now.addingTimeInterval(-3 * 3600),
                lastActivity: "Edited settings.json",
                context: WarrenDesktopContextUsage(used: 84, size: 100)
            ),
            WarrenDesktopSession(
                id: doneSessionID,
                workspaceID: workspaceID,
                tabID: "tab-subagents-done",
                title: "把子代理收进胶囊",
                kind: .codex,
                activity: .working,
                currentStep: "Running swift build",
                turnStartedAt: now.addingTimeInterval(-30),
                subagents: [
                    WarrenDesktopSubagent(
                        id: "agent-done-1",
                        title: "Explore",
                        summary: "查找胶囊的绘制点",
                        state: .completed
                    ),
                    WarrenDesktopSubagent(
                        id: "agent-done-2",
                        title: "Plan",
                        summary: "拆分子代理状态机",
                        state: .completed
                    ),
                ]
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-subagents-waiting",
                title: "子代理等待态",
                kind: .codex,
                agentStatus: AgentStatus(
                    activity: .working,
                    attention: AgentAttention(kind: .approval, reason: "permission")
                ),
                currentStep: "Running apply_patch",
                turnStartedAt: now.addingTimeInterval(-12),
                subagents: [
                    WarrenDesktopSubagent(
                        id: "agent-ask",
                        title: "general",
                        summary: "让用户确认写入范围",
                        state: .running,
                        lastActivity: "Waiting for permission",
                        isWaiting: true
                    ),
                    WarrenDesktopSubagent(
                        id: "agent-busy",
                        title: "Explore",
                        summary: "扫描调用点",
                        state: .running,
                        lastActivity: "Searching SidebarRows"
                    ),
                ]
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-sticky",
                title: "保留上一步的主信息",
                kind: .claude,
                activity: .working,
                primaryLine: "Running swift test",
                lastActivity: "Ran swift build",
                turnStartedAt: now.addingTimeInterval(-9)
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "tab-new",
                title: "新会话",
                kind: .pi
            ),
        ]
        let tree = WarrenDesktopSidebarTreeState(
            expandedSubagentSessionIDs: [planSessionID, doneSessionID]
        )
        for width in [220.0, 300.0, 400.0] {
            let harness = mount(
                workspaceID: workspaceID,
                sessions: sessions,
                width: width,
                height: 920,
                tree: tree
            )
            let view = harness.hosting
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return XCTFail("No bitmap for the sidebar")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("sidebar-session-rows-\(Int(width)).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Writes the four shell states as their own rows when asked.
    @MainActor
    func testWritesTheShellStatesWhenAnArtifactDirectoryIsGiven() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_SIDEBAR_IMAGES"] else {
            throw XCTSkip("Set WARREN_SIDEBAR_IMAGES to write sidebar PNGs")
        }
        let now = Date()
        let hostID = HostID()
        let projectID = ProjectID()
        let project = Project(
            id: projectID,
            hostID: hostID,
            name: "warren",
            rootPath: "/work/warren"
        )
        let workspaceID = WorkspaceID()
        let workspace = Workspace(
            id: workspaceID,
            projectID: projectID,
            name: "feat/shell",
            path: "/work/warren",
            branch: "feat/shell"
        )
        let sessions = [
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "shell-running",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-4200),
                workingDirectory: "/work/warren",
                shellState: WarrenDesktopShellState(
                    atPrompt: false,
                    runningCommand: "sudo npm run dev --package-path Packages/WarrenKit",
                    shellName: "zsh",
                    commandStartedAt: now.addingTimeInterval(-3 * 60)
                )
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "shell-ran",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-4200),
                workingDirectory: "/work/warren/Sources/WarrenKit",
                shellState: WarrenDesktopShellState(
                    atPrompt: true,
                    lastCommand: "swift build --package-path Packages/WarrenKit",
                    lastExitCode: 0,
                    lastExitAt: now.addingTimeInterval(-2 * 60),
                    shellName: "zsh"
                )
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "shell-failed",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-4200),
                workingDirectory: "/work/warren/Sources/WarrenKit/Tests",
                shellState: WarrenDesktopShellState(
                    atPrompt: true,
                    lastCommand: "swift test --filter Sidebar",
                    lastExitCode: 1,
                    lastExitAt: now.addingTimeInterval(-5 * 60),
                    shellName: "zsh"
                )
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: workspaceID,
                tabID: "shell-new",
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-3600),
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path + "/code/warren-ai-labs/warren",
                shellState: WarrenDesktopShellState(atPrompt: true, shellName: "zsh")
            ),
        ]
        for width in [220.0, 300.0, 400.0] {
            let rows = VStack(spacing: 0) {
                ForEach(sessions) { session in
                    WarrenDesktopWorkspaceSessionRow(
                        session: session,
                        project: project,
                        workspace: workspace,
                        semanticScope: "render",
                        isInteractionDisabled: false,
                        onOpen: {}
                    )
                }
            }
            .frame(width: width, alignment: .topLeading)
            .background(WarrenColorTokens.resolved(for: .dark, material: .opaque).workbenchCardFill)
            .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: AnyView(rows))
            let height = CGFloat(WarrenDesktopSidebarMetrics.sessionRowHeight) * CGFloat(sessions.count)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                return XCTFail("No bitmap for the shell rows")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("sidebar-shell-states-\(Int(width)).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
