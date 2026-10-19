import AppKit
import SwiftUI
import XCTest
import WarrenDomain
import WarrenTransport
@testable import Warren

/// The Conversation pane at its real size, driven by a synthetic event stream
/// so the whole view renders with no Host. Set `WARREN_CHAT_PANE_IMAGES` to a
/// directory to write the PNGs; the test skips otherwise.
final class WarrenConversationPaneRenderTests: XCTestCase {
    private struct Fixture {
        var events: [WarrenRemoteAgentEvent] = []
        var status: AgentStatus?
        var queued: [WarrenConversationFeed.QueuedPrompt] = []
        var attachments: [WarrenConversationFeed.PendingAttachment] = []
        var loaded = true
    }

    // MARK: Harness

    @MainActor
    private struct Mount {
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
    }

    @MainActor
    private func mount(
        _ fixture: Fixture,
        width: CGFloat,
        height: CGFloat = 780,
        expanded: Bool = false,
        actions: WarrenConversationActions = {
            var actions = WarrenConversationActions()
            actions.supportsConfig = true
            return actions
        }()
    ) -> Mount {
        let feed = WarrenConversationFeed(sessionID: TerminalSessionID())
        feed.merge(fixture.events, streamID: "fixture-stream")
        feed.status = fixture.status
        feed.queuedPrompts = fixture.queued
        feed.pendingAttachments = fixture.attachments
        if fixture.loaded { feed.markLoaded() }
        let view = WarrenConversationView(
            feed: feed,
            providerName: "Claude",
            root: "/Users/dev/warren",
            branch: "feat/sidebar-topbar-polish",
            actions: actions
        )
        .environment(\.colorScheme, .dark)
        .environment(\.conversationForcesExpanded, expanded)
        let hosting = NSHostingView(rootView: AnyView(view))
        // The pane has to be in a real window: a SwiftUI ScrollView only
        // resolves its scroll offset and anchoring once it has a window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        return Mount(hosting: hosting, window: window)
    }

    @MainActor
    private func write(_ mount: Mount, to directory: String, name: String) throws {
        // The directory is the caller's to name, so create it: a render check
        // that fails because the images had nowhere to land costs a round trip
        // that says nothing about the pane.
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        mount.hosting.layoutSubtreeIfNeeded()
        let bounds = mount.hosting.bounds
        let bitmap = try XCTUnwrap(mount.hosting.bitmapImageRepForCachingDisplay(in: bounds))
        mount.hosting.cacheDisplay(in: bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        mount.window.orderOut(nil)
    }

    @MainActor
    func testWritesThePaneStatesWhenAnArtifactDirectoryIsGiven() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_CHAT_PANE_IMAGES"] else {
            throw XCTSkip("Set WARREN_CHAT_PANE_IMAGES to write chat pane PNGs")
        }
        let doneView = mount(Self.done(), width: 960)
        try write(doneView, to: directory, name: "chat-pane-done-wide.png")
        let narrow = mount(Self.done(), width: 460)
        try write(narrow, to: directory, name: "chat-pane-done-narrow.png")
        let working = mount(Self.working(), width: 960)
        try write(working, to: directory, name: "chat-pane-working-wide.png")
        let needsYou = mount(Self.needsYou(), width: 960)
        try write(needsYou, to: directory, name: "chat-pane-needs-you-wide.png")
        let empty = mount(Fixture(), width: 960)
        try write(empty, to: directory, name: "chat-pane-empty-wide.png")
        let expanded = mount(Self.done(), width: 960, expanded: true)
        try write(expanded, to: directory, name: "chat-pane-work-expanded-wide.png")
        let attachments = mount(Self.uploading(), width: 960)
        try write(attachments, to: directory, name: "chat-pane-attachments-wide.png")
        let explained = mount(Self.decisionWithExplanation(), width: 960)
        try write(explained, to: directory, name: "chat-pane-decision-explained-wide.png")
    }

    // MARK: Fixtures

    private static let longPrompt = """
    The sidebar has too many idle worktrees: 8 branches, one row each, about 240pt of noise.

    **Three changes:**
    1. Fold worktrees with no sessions into one row
    2. Dim branch prefixes with a quieter grey
    3. Truncate in the middle so the tail survives

    > Don't touch the multi-host code, another branch is working on it.

    The files should be `WarrenDesktopSidebarRowsView.swift` and `WarrenDesktopWorkspaceRowView.swift`.

    Also, `worktreeSpacing` is 6 but the mockup says 4. Run the Sidebar tests.
    """

    private static func done() -> Fixture {
        let start = Date().addingTimeInterval(-108)
        var events: [WarrenRemoteAgentEvent] = [
            ev(1, "turn.started", occurredAt: start),
            ev(2, "message.created", role: "user", content: longPrompt),
            ev(3, "tool.started", toolKind: "grep", detail: "worktreeSpacing", id: "c1"),
            ev(4, "tool.completed", toolKind: "grep", detail: "worktreeSpacing", id: "c1"),
            ev(5, "tool.started", toolKind: "read", detail: "Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarRowsView.swift", id: "c2"),
            ev(6, "tool.completed", toolKind: "read", detail: "Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarRowsView.swift", id: "c2"),
            ev(7, "tool.started", toolKind: "edit", detail: "Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarRowsView.swift", id: "c3"),
            ev(8, "tool.completed", toolKind: "edit", detail: "Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarRowsView.swift", id: "c3", payload: [
                "diff": .object([
                    "file": .string("Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarRowsView.swift"),
                    "additions": .number(41),
                    "deletions": .number(98),
                    "diff": .string("@@ -1,3 +1,3 @@\n-let spacing = 6\n+let spacing = 4"),
                ]),
            ]),
            ev(9, "tool.started", toolKind: "edit", detail: "Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarMetrics.swift", id: "c4"),
            ev(10, "tool.completed", toolKind: "edit", detail: "Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarMetrics.swift", id: "c4", payload: [
                "diff": .object([
                    "file": .string("Packages/Desktop/Sources/WarrenDesktop/Sidebar/WarrenDesktopSidebarMetrics.swift"),
                    "additions": .number(4),
                    "deletions": .number(2),
                    "diff": .string("@@ -10 +10 @@\n+    static let idleRowHeight: CGFloat = 22"),
                ]),
            ]),
            ev(11, "tool.started", toolKind: "ran", detail: "swift test --filter Sidebar", id: "c5"),
            ev(12, "tool.completed", toolKind: "ran", detail: "swift test --filter Sidebar", id: "c5", output: "Building for debugging...\n[124/124] Compiling WarrenDesktop\nTest Suite 'Sidebar' passed\n   Executed 18 tests, 0 failures"),
            ev(13, "reasoning.delta", content: "A worktree should count as idle when it has no sessions at all, not just no running ones, or a session that just exited would make the branch jump between groups. The folded row goes after the project's last worktree.", occurredAt: start.addingTimeInterval(94)),
            // A second delta closes the thinking span, so the collapsed row can
            // show the duration the design asks for rather than a bare
            // "Thought".
            ev(150, "reasoning.delta", content: "The row takes the project's own indentation.", occurredAt: start.addingTimeInterval(106)),
            ev(14, "message.created", role: "assistant", content: """
            All three are done, and the 18 Sidebar tests pass.

            ## What changed

            - Worktrees with no sessions fold into one `8 idle worktrees` row.
            - Branch names are split into prefix and name.
            - Truncation is now `.middle`.

            ```swift
            let idle = worktrees.filter { $0.sessions.isEmpty }
            if !idle.isEmpty {
                IdleWorktreeRow(count: idle.count)
                    .frame(height: SidebarMetrics.idleRowHeight) // 22
            }
            ```

            | Token | Before | After |
            |---|---|---|
            | worktreeSpacing | 6 | 4, matches the mockup |
            | idleRowHeight | — | 22 |
            """, id: "m1"),
            ev(15, "message.completed", role: "assistant", content: "", id: "m1"),
            ev(16, "turn.completed", occurredAt: Date()),
            ev(17, "context.updated", payload: ["used": .number(76000), "size": .number(200000)]),
            ev(18, "plan.updated", payload: ["items": .array([
                .object(["title": .string("Fold idle worktrees"), "state": .string("completed")]),
                .object(["title": .string("Dim branch prefixes"), "state": .string("in_progress")]),
                .object(["title": .string("Middle truncation"), "state": .string("pending")]),
                .object(["title": .string("Run the Sidebar tests"), "state": .string("pending")]),
            ])]),
            configEvent(19),
        ]
        return Fixture(events: events, status: AgentStatus(activity: .ready))
    }

    private static func working() -> Fixture {
        let start = Date().addingTimeInterval(-42)
        return Fixture(
            events: [
                ev(1, "turn.started", occurredAt: start),
                ev(2, "message.created", role: "user", content: shortPrompt),
                ev(3, "tool.started", toolKind: "read", detail: "WarrenDesktopSidebarRowsView.swift", id: "c1"),
                ev(4, "tool.completed", toolKind: "read", detail: "WarrenDesktopSidebarRowsView.swift", id: "c1"),
                ev(5, "tool.started", toolKind: "edit", detail: "WarrenDesktopSidebarRowsView.swift", id: "c2"),
                ev(6, "tool.completed", toolKind: "edit", detail: "WarrenDesktopSidebarRowsView.swift", id: "c2"),
                ev(7, "tool.started", toolKind: "ran", detail: "swift test --filter Sidebar", id: "c3"),
                ev(8, "message.created", role: "assistant", content: "I'll treat a worktree as idle only when it has no sessions at all, so a session that just exited won't make the branch jump. Updating the row view now"),
                ev(9, "reasoning.delta", content: "The folded row goes after the project's last worktree so the group reads in place."),
                ev(10, "plan.updated", payload: ["items": .array([
                    .object(["title": .string("Fold idle worktrees"), "state": .string("completed")]),
                    .object(["title": .string("Dim branch prefixes"), "state": .string("in_progress")]),
                    .object(["title": .string("Middle truncation"), "state": .string("pending")]),
                    .object(["title": .string("Run the Sidebar tests"), "state": .string("pending")]),
                ])]),
                configEvent(11),
                ev(12, "context.updated", payload: ["used": .number(178000), "size": .number(200000)]),
            ],
            status: AgentStatus(activity: .working),
            queued: [.init(id: "q1", text: "Also hide the TASKS section when it is empty")]
        )
    }

    private static func needsYou() -> Fixture {
        let start = Date().addingTimeInterval(-72)
        return Fixture(
            events: [
                ev(1, "turn.started", occurredAt: start),
                ev(2, "message.created", role: "user", content: shortPrompt),
                ev(3, "tool.started", toolKind: "edit", detail: "WarrenDesktopSidebarRowsView.swift", id: "c1"),
                ev(4, "tool.completed", toolKind: "edit", detail: "WarrenDesktopSidebarRowsView.swift", id: "c1"),
                ev(5, "message.created", role: "assistant", content: "Edits are in. Next I'll run the Sidebar tests to check for regressions."),
                ev(6, "interaction.requested", payload: [
                    "interactionId": .string("i1"),
                    "version": .number(1),
                    "kind": .string("permission"),
                    "title": .string("Permission"),
                    "description": .string("Claude requests permission to run swift test"),
                    "toolKind": .string("ran"),
                    "toolDetail": .string("swift test --filter Sidebar --parallel"),
                    "options": .array([
                        .object(["id": .string("allow_once"), "label": .string("Allow once"), "kind": .string("allow_once")]),
                        .object(["id": .string("allow_always"), "label": .string("Always allow swift test in this session"), "kind": .string("allow_always")]),
                        .object(["id": .string("reject_once"), "label": .string("Deny"), "kind": .string("reject_once")]),
                    ]),
                ]),
                configEvent(7),
                ev(8, "context.updated", payload: ["used": .number(90000), "size": .number(200000)]),
            ],
            status: AgentStatus(activity: .blocked)
        )
    }

    private static func uploading() -> Fixture {
        Fixture(
            events: done().events,
            status: AgentStatus(activity: .ready),
            attachments: [
                .init(id: "a1", name: "trace.log", size: 1_240_000, progress: 0.62),
                .init(
                    id: "a2",
                    name: "screenshot.png",
                    size: 482_000,
                    progress: 1,
                    reference: WarrenRemoteAgentAttachmentRef(
                        attachmentID: "att-2",
                        name: "screenshot.png",
                        mime: "image/png",
                        size: 482_000
                    )
                ),
                .init(id: "a3", name: "huge.bin", size: 90_000_000, failure: "Upload failed: the file is too large."),
            ]
        )
    }

    /// A pending decision with the explanation the two-step send leaves queued:
    /// a permission cannot take a note, so the text waits as the next prompt.
    private static func decisionWithExplanation() -> Fixture {
        var fixture = needsYou()
        fixture.queued = [
            .init(id: "q1", text: "Don't run the whole suite; target the Sidebar tests only.")
        ]
        return fixture
    }

    private static let shortPrompt = "The pane title is the terminal's OSC title and it's way too long. Use the session title instead."

    // MARK: Event helpers

    private static func ev(
        _ sequence: UInt64,
        _ type: String,
        role: String? = nil,
        content: String? = nil,
        toolKind: String? = nil,
        detail: String? = nil,
        id: String = "",
        output: String? = nil,
        occurredAt: Date? = nil,
        payload: [String: WarrenRemoteJSONValue]? = nil
    ) -> WarrenRemoteAgentEvent {
        var body = payload ?? [:]
        // The projection reads role and content from the payload, not the
        // event's own columns (RFC 0010 timeline events).
        if let role { body["role"] = .string(role) }
        if let content { body["content"] = .string(content) }
        if let toolKind { body["toolKind"] = .string(toolKind) }
        if let detail { body["toolDetail"] = .string(detail) }
        if let output { body["output"] = .string(output) }
        return WarrenRemoteAgentEvent(
            sequence: sequence,
            turnID: "t1",
            id: id.isEmpty ? "e\(sequence)" : id,
            provider: "claude",
            type: type,
            role: role,
            content: content,
            occurredAt: occurredAt.map(iso),
            payload: body.isEmpty ? nil : body
        )
    }

    private static func configEvent(_ sequence: UInt64) -> WarrenRemoteAgentEvent {
        ev(sequence, "config.updated", payload: ["configOptions": .array([
            .object([
                "id": .string("mode"),
                "name": .string("Mode"),
                "category": .string("mode"),
                "currentValue": .string("acceptEdits"),
                "options": .array([
                    .object(["value": .string("default"), "name": .string("Default")]),
                    .object(["value": .string("acceptEdits"), "name": .string("Accept edits")]),
                    .object(["value": .string("plan"), "name": .string("Plan")]),
                ]),
            ]),
            .object([
                "id": .string("model"),
                "name": .string("Model"),
                "category": .string("model"),
                "currentValue": .string("opus"),
                "options": .array([
                    .object(["value": .string("opus"), "name": .string("Opus")]),
                    .object(["value": .string("sonnet"), "name": .string("Sonnet")]),
                ]),
            ]),
        ])])
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated private static func iso(_ date: Date) -> String { formatter.string(from: date) }
}
