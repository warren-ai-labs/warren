import AppKit
import SwiftUI
import XCTest
import WarrenDesignSystem
import WarrenDesktop
import WarrenDomain
import WarrenTransport
@testable import Warren

/// The three "needs you" panels at the width they sit on the composer, driven
/// by fixture data so no Host is involved. Set `WARREN_LEAD_PANEL_IMAGES` to a
/// directory to write the PNGs; the test skips otherwise.
final class WarrenLeadPanelsRenderTests: XCTestCase {
    /// The panels' own row metrics, as the design draws them.
    private let width: CGFloat = 620

    @MainActor
    private func mount(_ view: some View, light: Bool, height: CGFloat = 0) -> NSWindow {
        let hosting = NSHostingView(rootView: AnyView(
            view
                // A definite width: the panels wrap their own text, and a
                // hosting view left to propose one wraps at nothing.
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, light ? .light : .dark)
        ))
        // The panels' own height, so the stack is not stretched to a guess and
        // the gap between two of them is not mistaken for spacing.
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        hosting.layoutSubtreeIfNeeded()
        let height = height > 0 ? height : max(hosting.fittingSize.height, 40)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        // The panels rest on the Conversation pane's ground, not on a page of
        // their own; a transparent capture would read as white and show the
        // dark palette's light ink on nothing.
        window.backgroundColor = NSColor(
            WarrenConversationPalette.resolved(for: light ? .light : .dark).card
        )
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func write(_ window: NSWindow, to directory: String, name: String, light: Bool) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(WarrenConversationPalette.resolved(for: light ? .light : .dark).card).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }

    private var checks: [WarrenLeadMessage.Check] {
        [
            .init(what: "The sidebar folds idle Worktrees into one row", at: "Sidebar.swift:118"),
            .init(what: "A folded row still opens on click", at: "Sidebar.swift:204"),
            .init(what: "The idle count updates when a Session starts", at: "SidebarRows.swift:66"),
        ]
    }

    private var members: [WarrenLeadCrewMember] {
        [
            WarrenLeadCrewMember(
                id: "1",
                session: WarrenDesktopSession(
                    id: TerminalSessionID(),
                    title: "Codex",
                    kind: .codex,
                    state: .attached,
                    activity: .working,
                    currentStep: "Running the Sidebar tests"
                ),
                markerTitle: "Sidebar rows"
            ),
            WarrenLeadCrewMember(
                id: "2",
                session: WarrenDesktopSession(
                    id: TerminalSessionID(),
                    title: "Claude",
                    kind: .claude,
                    state: .attached,
                    activity: .ready,
                    lastActivity: "Edited Sidebar.swift"
                ),
                markerTitle: "Idle folding"
            ),
            WarrenLeadCrewMember(
                id: "3",
                session: WarrenDesktopSession(
                    id: TerminalSessionID(),
                    title: "Shell",
                    kind: .shell,
                    state: .exited
                ),
                markerTitle: nil
            ),
        ]
    }

    @MainActor
    func testLeadPanelsRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_LEAD_PANEL_IMAGES"] else {
            throw XCTSkip("Set WARREN_LEAD_PANEL_IMAGES to write the panel PNGs")
        }
        let decision = WarrenLeadDecisionPanel(
            question: "The idle row hides Worktrees you may still want. Keep it or drop it?",
            reason: "The row appears whenever a Worktree has no Session, and it is the only way to reach those branches.",
            options: ["Keep the folded row", "Drop the row", "Keep it, but only while folded manually"],
            highlight: 0,
            onChoose: { _ in }
        )

        let checksPanel = WarrenLeadChecksPanel(
            checks: checks,
            outcomes: [.passed, nil, .problem(note: "The count only refreshes on the next projection.")],
            noting: 2,
            onToggle: { _ in },
            onProblem: { _ in },
            onClear: { _ in },
            onAllPassed: { },
            onSend: { }
        )

        let crew = WarrenLeadCrewStrip(
            members: members,
            latest: "Sidebar rows",
            onOpen: { _ in }
        )

        for light in [false, true] {
            let suffix = light ? "light" : "dark"
            try write(
                mount(
                    // The dock the Conversation pane builds: one joined stack,
                    // the top panel rounded and the one under it square.
                    VStack(spacing: -1) {
                        WarrenConversationStackPanel(
                            outline: WarrenConversationPalette.resolved(for: light ? .light : .dark).line2,
                            roundsTop: true
                        ) { decision }
                        WarrenConversationStackPanel(
                            outline: WarrenConversationPalette.resolved(for: light ? .light : .dark).line2,
                            roundsTop: false
                        ) { checksPanel }
                    }
                    .padding(.vertical, 16),
                    light: light
                ),
                to: directory,
                name: "lead-decision-\(suffix)",
                light: light
            )
            try write(
                mount(
                    WarrenConversationStackPanel(
                        outline: WarrenConversationPalette.resolved(for: light ? .light : .dark).line2,
                        roundsTop: true
                    ) { crew }
                    .padding(.vertical, 16),
                    light: light
                ),
                to: directory,
                name: "lead-crew-\(suffix)",
                light: light
            )
        }
    }
}
