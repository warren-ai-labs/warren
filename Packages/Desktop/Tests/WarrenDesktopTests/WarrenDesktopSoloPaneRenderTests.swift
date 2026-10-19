import AppKit
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import XCTest

@testable import WarrenDesktop

/// Writes the lone pane's chrome to PNGs when asked, so the appended command,
/// the width cap, the tail fade, the title menu, and the detail card can be
/// looked at as they are drawn rather than only measured.
@MainActor
final class WarrenDesktopSoloPaneRenderTests: XCTestCase {
    private func artifactDirectory(_ variable: String) throws -> String {
        guard let directory = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set \(variable) to write solo pane PNGs")
        }
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func write(
        _ view: AnyView,
        width: CGFloat,
        height: CGFloat,
        named name: String,
        to directory: String
    ) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("No bitmap for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func pill(_ model: WarrenDesktopSoloPaneIdentity.Model) -> AnyView {
        AnyView(
            WarrenDesktopSoloPaneIdentity(
                identity: model,
                onCopyTitle: {},
                onClose: {}
            )
            .environment(\.colorScheme, .dark)
            .environment(\.warrenForceHover, true)
        )
    }

    private var backdrop: Color {
        WarrenColorTokens.resolved(for: .dark, material: .opaque).workbenchCardFill
    }

    /// The cases that decide how the pill lays out: a short name with a running
    /// command, a generated Agent name, and names long enough to drop the
    /// command and then to fade.
    private var cases: [(name: String, model: WarrenDesktopSoloPaneIdentity.Model)] {
        [
            (
                "shell-running",
                .init(
                    tabID: "tab-shell",
                    title: "zsh",
                    runningCommand: "git push",
                    fullTitle: "git push -u origin feat/sidebar-topbar-polish",
                    providerPresetID: nil,
                    mark: nil,
                    canClose: true
                )
            ),
            (
                "agent",
                .init(
                    tabID: "tab-agent",
                    title: "Fix sidebar topbar polish",
                    fullTitle: "Fix sidebar topbar polish",
                    providerPresetID: "claude",
                    mark: nil,
                    canClose: true
                )
            ),
            (
                "long-agent",
                .init(
                    tabID: "tab-long",
                    title: "多 host 侧边栏 UI 优化设计确认与实现",
                    fullTitle: "多 host 侧边栏 UI 优化设计确认与实现",
                    providerPresetID: "claude",
                    mark: nil,
                    canClose: true
                )
            ),
            (
                "long-running",
                .init(
                    tabID: "tab-long-running",
                    title: "多 host 侧边栏 UI 优化设计确认",
                    runningCommand: "swift build --package-path Packages/WarrenKit",
                    fullTitle: "swift build --package-path Packages/WarrenKit",
                    providerPresetID: nil,
                    mark: nil,
                    canClose: true
                )
            ),
        ]
    }

    func testWritesTheSoloPanePillWhenAnArtifactDirectoryIsGiven() throws {
        let directory = try artifactDirectory("WARREN_SOLO_PANE_IMAGES")
        for (name, model) in cases {
            for width in [240.0, 320.0, 460.0] {
                let background = ZStack(alignment: .leading) {
                    backdrop
                    pill(model)
                        .frame(width: width, alignment: .leading)
                }
                .environment(\.colorScheme, .dark)
                try write(
                    AnyView(background),
                    width: width,
                    height: 40,
                    named: "solo-pane-\(name)-\(Int(width))",
                    to: directory
                )
            }
        }
    }

    func testWritesTheDetailCardWhenAnArtifactDirectoryIsGiven() throws {
        let directory = try artifactDirectory("WARREN_SOLO_PANE_IMAGES")
        let card = WarrenDesktopDetailCard(rows: [
            .init(
                label: "Command",
                value: "/Users/x/.local/bin/claude --dangerously-skip-permissions --session-id 8ee1cc80-4b1e"
            ),
            .init(label: "Directory", value: "~/conductor/warren/abdc3af6-feat-sidebar-topbar-polish"),
            .init(label: "Branch", value: "feat/sidebar-topbar-polish"),
            .init(label: "Kind", value: "Agent · Claude Code"),
        ])
        .environment(\.colorScheme, .dark)
        .warrenMenuSurface(width: WarrenDesktopDetailCard.width)
        let view = ZStack(alignment: .topLeading) {
            backdrop
            card.padding(20)
        }
        .environment(\.colorScheme, .dark)
        try write(
            AnyView(view),
            width: WarrenDesktopDetailCard.width + 40,
            height: 220,
            named: "solo-pane-detail-card",
            to: directory
        )
    }

    func testWritesTheDialogWhenAnArtifactDirectoryIsGiven() throws {
        let directory = try artifactDirectory("WARREN_SOLO_PANE_IMAGES")
        let dialog = WarrenTextInputDialog(
            title: "Rename Session",
            message: "The name shows in the sidebar, the top bar, and every client.",
            fieldLabel: "Name",
            text: .constant("Fix resize race"),
            confirmLabel: "Rename",
            onCancel: {},
            onConfirm: {}
        )
        .environment(\.colorScheme, .dark)
        try write(
            AnyView(dialog),
            width: 720,
            height: 420,
            named: "dialog-rename",
            to: directory
        )
    }

    func testWritesTheTabBarWhenAnArtifactDirectoryIsGiven() throws {
        let directory = try artifactDirectory("WARREN_SOLO_PANE_IMAGES")
        let few = [
            ClientTab(id: "tab-1", title: "Fix sidebar topbar polish", kind: .claude),
            ClientTab(id: "tab-2", title: "zsh", kind: .shell),
            ClientTab(id: "tab-3", title: "Relay reconnect", kind: .codex),
        ]
        for (name, tabs, width) in [
            ("tab-bar-selected", few, CGFloat(640)),
            ("tab-bar-overflow", (1...14).map { index in
                ClientTab(id: "tab-\(index)", title: "Session \(index)", kind: .shell)
            }, CGFloat(700)),
        ] {
            let view = ZStack(alignment: .leading) {
                backdrop
                makeTabBar(tabs: tabs, selectedTabID: tabs[1].id)
                    .frame(width: width)
            }
            .environment(\.colorScheme, .dark)
            try write(
                AnyView(view),
                width: width,
                height: WarrenLayoutMetrics.tabBarHeight,
                named: name,
                to: directory
            )
        }
    }

    func testWritesTheTitleMenuWhenAnArtifactDirectoryIsGiven() throws {
        let directory = try artifactDirectory("WARREN_SOLO_PANE_IMAGES")
        let center = WarrenDesktopMenuCenter()
        center.present(
            [
                .button(title: "Rename Session…") {},
                .button(title: "Copy Command") {},
                .button(title: "Copy Path") {},
                .menu(title: "Open in Editor", actions: [
                    .button(title: "Visual Studio Code") {},
                    .button(title: "Cursor") {},
                ]),
            ],
            at: CGPoint(x: 16, y: 16)
        )
        let view = ZStack {
            backdrop
            Color.clear.frame(width: 340, height: 300)
        }
        .warrenMenuOverlay(center)
        .environment(\.colorScheme, .dark)
        try write(
            AnyView(view),
            width: 340,
            height: 300,
            named: "solo-pane-title-menu",
            to: directory
        )
    }
}
