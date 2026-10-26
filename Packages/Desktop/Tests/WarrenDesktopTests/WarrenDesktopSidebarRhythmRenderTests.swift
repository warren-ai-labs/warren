import AppKit
import SwiftUI
import XCTest

import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
@testable import WarrenDesktop

private final class RhythmRenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct RhythmTerminalSurface: View {
    let context: WarrenDesktopTerminalContext
    var body: some View { Color.clear }
}

/// Renders a busy sidebar — two Tasks across projects, a project with many
/// worktrees, idle worktrees, solo-worktree projects — so its rhythm can be
/// looked at against the design rather than only measured.
final class WarrenDesktopSidebarRhythmRenderTests: XCTestCase {
    @MainActor
    func testWritesABusySidebarWhenAnArtifactDirectoryIsGiven() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_SIDEBAR_IMAGES"] else {
            throw XCTSkip("Set WARREN_SIDEBAR_IMAGES to write sidebar PNGs")
        }
        let now = Date()
        let host = Host(name: "mbp14-m3")
        let degrade = WarrenTask(hostID: host.id, name: "最常访问头像直播降级标志 live_degrade")
        let report = WarrenTask(hostID: host.id, name: "PC 端社区互动与播放行为上报字段")

        let warren = Project(hostID: host.id, name: "warren", rootPath: "/w/warren", pinned: true)
        let gateway = Project(hostID: host.id, name: "go-gateway", rootPath: "/w/go-gateway")
        let dolly = Project(hostID: host.id, name: "dolly", rootPath: "/w/dolly")
        let h2 = Project(hostID: host.id, name: "h2nexus", rootPath: "/w/h2nexus")
        let bili = Project(hostID: host.id, name: "bili-gateway", rootPath: "/w/bili-gateway")
        let bapis = Project(hostID: host.id, name: "bapis", rootPath: "/w/bapis")
        let dynamic = Project(hostID: host.id, name: "go-dynamic", rootPath: "/w/go-dynamic")
        let click = Project(hostID: host.id, name: "click", rootPath: "/w/click")

        func ws(_ project: Project, _ name: String, task: WarrenTask? = nil, branch: String? = nil) -> Workspace {
            Workspace(projectID: project.id, taskID: task?.id, name: name, path: "\(project.rootPath)/\(name)", branch: branch)
        }
        let degradeBranch = "release/bili/live-degrade"
        let reportBranch = "release/click/interaction-report-fields"
        let wBili = ws(bili, degradeBranch, task: degrade, branch: degradeBranch)
        let wBapis = ws(bapis, degradeBranch, task: degrade, branch: degradeBranch)
        let wDynamic = ws(dynamic, degradeBranch, task: degrade, branch: degradeBranch)
        let wGatewayTask = ws(gateway, reportBranch, task: report, branch: reportBranch)
        let wClick = ws(click, "release/click/polaris-action-id", task: report, branch: "release/click/polaris-action-id")
        let wMain = ws(warren, "main")
        let wOsc = ws(warren, "feat/osc-7501-program-status", branch: "feat/osc-7501-program-status")
        let wKeep = ws(warren, "feat/keep-ended-sessions", branch: "feat/keep-ended-sessions")
        let wLead = ws(warren, "feat/lead-agent", branch: "feat/lead-agent")
        let wIdle = ws(warren, "feat/old-idea", branch: "feat/old-idea")
        let wStory = ws(gateway, "Story OGV 相关推荐", branch: "Story OGV 相关推荐")
        let wGatewayMain = ws(gateway, "main")
        let wDolly = ws(dolly, "main")
        let wH2 = ws(h2, "main")

        func agent(_ w: Workspace, _ kind: TerminalSessionKind, _ title: String, _ last: String, ago: TimeInterval, working: String? = nil) -> WarrenDesktopSession {
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: w.id,
                tabID: UUID().uuidString,
                title: title,
                kind: kind,
                activity: working == nil ? .ready : .working,
                activityUpdatedAt: now.addingTimeInterval(-ago),
                currentStep: working,
                lastActivity: last
            )
        }
        func shell(_ w: Workspace, ago: TimeInterval) -> WarrenDesktopSession {
            WarrenDesktopSession(
                id: TerminalSessionID(),
                workspaceID: w.id,
                tabID: UUID().uuidString,
                title: "Shell",
                kind: .shell,
                createdAt: now.addingTimeInterval(-ago),
                workingDirectory: w.path,
                shellState: WarrenDesktopShellState(atPrompt: true, shellName: "fish")
            )
        }
        let sessions = [
            agent(wGatewayTask, .claude, "inspect 需求分析及 GenReportParams 透传", "Added polaris_action_id support to play reports", ago: 23 * 60),
            agent(wMain, .claude, "implement 派活 pi 开发 设计 产品形态", "Added parser and Crew inference changes", ago: 3 * 3600),
            agent(wMain, .pi, "inspect 关闭主窗口 和菜单栏 helper 是否钉住", "Added mount prompt before installing helper", ago: 33 * 60),
            agent(wMain, .claude, "inspect 侧边栏 滚动掉帧原因", "Fixed sidebar rebuilds and per-frame paints", ago: 33 * 60),
            agent(wMain, .claude, "implement 侧边栏缩进 淡化 worktree 分区", "Ran swift build", ago: 120, working: "Running swift build"),
            shell(wMain, ago: 23 * 60),
            agent(wOsc, .claude, "inspect 当前分支 merge main 之后的状态", "Merged and rewrote program status follow-up", ago: 4 * 86400),
            agent(wKeep, .pi, "keep ended sessions", "Fixed session endReason loss in Desktop", ago: 4 * 86400),
            agent(wLead, .codex, "lead agent (codex)", "Stopped using window activation and more", ago: 4 * 60),
            agent(wStory, .claude, "inspect rebase changelog 删除临时代码", "Updated docs and MR 13098 with host aliases", ago: 4 * 86400),
            shell(wStory, ago: 95 * 3600),
            agent(wDolly, .pi, "implement 添加项目到 warren inspect 本地构建", "Renamed and recompiled app with user-scoped id", ago: 3 * 86400),
            shell(wDolly, ago: 13 * 60),
            agent(wH2, .pi, "fix ssh 配置 Host 缺失导致认证失败", "Fixed mihomo.yaml override losing key", ago: 33 * 60),
        ]
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [degrade, report],
            projects: [warren, gateway, dolly, h2, bili, bapis, dynamic, click],
            workspaces: [wBili, wBapis, wDynamic, wGatewayTask, wClick, wMain, wOsc, wKeep, wLead, wIdle, wStory, wGatewayMain, wDolly, wH2],
            sessions: sessions
        )
        for scheme in [ColorScheme.dark, .light] {
            let root = WarrenDesktopRoot(projection: projection, persistenceEnabled: false) { context in
                RhythmTerminalSurface(context: context)
            }
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .key)
            let hosting = NSHostingView(rootView: AnyView(root))
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 2000)
            let window = RhythmRenderWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                return XCTFail("No bitmap")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("sidebar-rhythm-\(scheme == .dark ? "dark" : "light").png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            window.contentView = nil
        }
    }
}
