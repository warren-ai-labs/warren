import XCTest
import SwiftUI
import AppKit
import Combine
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain
import WarrenClientCore
import WarrenObservation

/// Chrome must not depend on live metadata: a rendered title can be empty for a
/// moment while a Session's metadata is rewritten, and letting the pane header
/// disappear with it changes the pane's height by 28 pt, resizes the PTY, and
/// makes a full-screen TUI repaint end to end.
final class WarrenDesktopPaneHeaderTitleTests: XCTestCase {
    func testHeaderLabelNeverCollapsesToEmpty() {
        XCTAssertEqual(
            WarrenDesktopPaneView<EmptyView>.stablePaneHeaderTitle(
                rendered: "pi · main",
                sessionTitle: "Session",
                kindName: "pi"
            ),
            "pi · main"
        )
        XCTAssertEqual(
            WarrenDesktopPaneView<EmptyView>.stablePaneHeaderTitle(
                rendered: "   ",
                sessionTitle: "Session",
                kindName: "pi"
            ),
            "Session"
        )
        XCTAssertEqual(
            WarrenDesktopPaneView<EmptyView>.stablePaneHeaderTitle(
                rendered: "",
                sessionTitle: "\n",
                kindName: "pi"
            ),
            "pi"
        )
    }
}

private struct TestTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        Text("surface:\(context.tab.id):\(context.workspace?.id.rawValue.uuidString ?? "none")")
            // Named so a test can assert the Terminal is still mounted. A lone
            // pane draws no Tab chip, so the track cannot answer that.
            .warrenSemanticElement(
                id: "test-terminal.\(context.tab.id)",
                role: .group,
                label: "Terminal \(context.tab.id)"
            )
    }
}

@MainActor
private final class TabBarTestState: ObservableObject {
    @Published var tabs: [ClientTab]
    @Published var selectedTabID: String?

    init(tabs: [ClientTab], selectedTabID: String?) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }
}

private struct TabBarTestHarness: View {
    @ObservedObject var state: TabBarTestState

    var body: some View {
        makeTabBar(tabs: state.tabs, selectedTabID: state.selectedTabID)
            .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
    }
}

@MainActor
private final class SidebarHostRowsTestState: ObservableObject {
    @Published var hosts: [WarrenDesktopSidebarHostProjection]
    let selection: WarrenDesktopSidebarResourceSelection?
    @Published private(set) var selectedResources: [WarrenDesktopSidebarResourceSelection] = []

    init(
        hosts: [WarrenDesktopSidebarHostProjection],
        selection: WarrenDesktopSidebarResourceSelection?
    ) {
        self.hosts = hosts
        self.selection = selection
    }

    func recordSelection(_ selection: WarrenDesktopSidebarResourceSelection) {
        selectedResources.append(selection)
    }
}

private struct SidebarHostRowsTestHarness: View {
    @ObservedObject var state: SidebarHostRowsTestState
    let activeEndpointID: String
    var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact
    var selectedTabID: String? = nil

    var body: some View {
        WarrenDesktopSidebarHostRows(
            hosts: state.hosts,
            showsActiveOnly: false,
            workspaceDisplayMode: workspaceDisplayMode,
            selection: state.selection,
            activeEndpointID: activeEndpointID,
            selectedTabID: selectedTabID,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in },
            onSelect: { state.recordSelection($0) },
            onOpenWorkspace: { _ in },
            onFocusTask: { _ in },
            onToggleActiveOnly: {},
            onRetry: { _ in }
        )
    }
}

@MainActor
func makeTabBar(
    tabs: [ClientTab],
    selectedTabID: String?,
    soloPane: WarrenDesktopSoloPaneIdentity.Model? = nil
) -> WarrenDesktopTabBar {
    WarrenDesktopTabBar(
        presentation: WarrenDesktopPaneBarPresentation(
            listings: tabs,
            showsTrack: soloPane == nil,
            solo: soloPane
        ),
        tabTitles: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) }),
        tabMarks: [:],
        pinnedSessionIDs: [],
        selectedTabID: selectedTabID,
        isSidebarCollapsed: false,
        onToggleSidebar: {},
        onChromePopover: { _ in },
        rightSidebarOpen: false,
        rightSidebarAvailable: false,
        onToggleRightSidebar: {},
        onSelectTab: { _ in },
        onMoveTab: { _, _ in },
        sessionMoveTargets: [],
        sessionMoveDestinations: [:],
        onMoveSession: { _, _ in },
        canAddTab: true,
        isAddingTab: false,
        onAddTab: {},
        onCloseTab: { _ in },
        onCloseOtherTabs: { _ in },
        onCloseAllTabs: { _ in },
        onRequestRename: { _ in },
        onToggleSessionPin: { _, _ in },
        onDismissActivity: { _, _ in }
    )
}

@MainActor
final class WarrenDesktopTests: XCTestCase {
    func testPublicAccessUsesOwnerReachabilityTerminology() {
        XCTAssertEqual(WarrenPublicAccessCopy.title, "Public Access")
        XCTAssertEqual(WarrenPublicAccessCopy.relayURL, "Relay URL")
        XCTAssertEqual(WarrenPublicAccessCopy.publicHostname, "Public hostname")
        XCTAssertEqual(WarrenPublicAccessCopy.pathPrefix, "Path prefix")
        XCTAssertEqual(WarrenPublicAccessCopy.publicEndpoint, "Public URL")
        XCTAssertEqual(WarrenPublicAccessCopy.resetLocalSetup, "Reset local route")
        XCTAssertFalse(WarrenPublicAccessCopy.title.localizedCaseInsensitiveContains("sharing"))
    }

    /// The toggle names its effect on the tree. A speech bubble claimed every
    /// leaf is a conversation, which a plain shell is not.
    func testWorkspaceDisplayModeDescribesItsEffectOnTheTree() {
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode(rawValue: "rich"),
            .rich
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode.compact.toggleLabel,
            "Show Sessions in the navigation tree"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode.rich.toggleHint,
            "List each workspace without its running Sessions"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceDisplayMode.rich.systemImage,
            "list.bullet.indent"
        )
        XCTAssertNotEqual(
            WarrenDesktopWorkspaceDisplayMode.rich.systemImage,
            WarrenDesktopWorkspaceDisplayMode.compact.systemImage
        )
    }

    /// Rich mode is denser, so it needs more separation between project
    /// subtrees, not less.
    func testRichModeSeparatesProjectSubtreesMoreThanCompact() {
        XCTAssertGreaterThan(
            WarrenDesktopWorkspaceDisplayMode.rich.projectGroupSpacing,
            WarrenDesktopWorkspaceDisplayMode.compact.projectGroupSpacing
        )
        XCTAssertGreaterThan(
            WarrenDesktopWorkspaceDisplayMode.compact.projectGroupSpacing,
            WarrenSpacing.xxs
        )
    }

    /// Indent is width taken from row titles, so no tier spends a step: every
    /// row is told apart by weight, brightness, glyph, or a second line.
    func testNoSidebarTierSpendsAnIndentStep() {
        let rowInset = WarrenSpacing.compact

        XCTAssertEqual(WarrenDesktopSidebarIndent.host, WarrenDesktopSidebarIndent.section)
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.project + rowInset,
            WarrenDesktopSidebarIndent.section
        )
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.workspace,
            WarrenDesktopSidebarIndent.project,
            "A workspace says it is inside a project by weight, not position"
        )
        XCTAssertEqual(WarrenDesktopSidebarIndent.task, WarrenDesktopSidebarIndent.project)
        XCTAssertEqual(
            WarrenDesktopSidebarIndent.session,
            WarrenDesktopSidebarIndent.workspace,
            "A Session says it is inside a workspace by its icon and second line"
        )
    }

    /// The second line: a working Session says what it is doing, a resting one
    /// says what this turn did, and one that has done nothing says so rather
    /// than leaving a gap.
    func testSessionSecondLineLeadsWithTheOneThingThatMatters() {
        let workspaceID = WorkspaceID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        let working = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            customTitle: "Ghostty resize",
            kind: .claude,
            activity: .working,
            activityUpdatedAt: now.addingTimeInterval(-30),
            currentStep: "Running git status",
            lastActivity: "Ran swift test",
            turnStartedAt: now.addingTimeInterval(-18)
        )
        let running = WarrenDesktopWorkspaceSessionRow.secondLine(for: working, now: now)
        XCTAssertEqual(running.tone, .running)
        XCTAssertEqual(
            running.primary,
            "Running git status",
            "What it is doing outranks what it last did"
        )
        XCTAssertEqual(
            running.meta,
            .time("18s"),
            "A running row without a plan shows how long this turn has run"
        )

        let counted = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            customTitle: "Ghostty resize",
            kind: .claude,
            activity: .ready,
            activityUpdatedAt: now.addingTimeInterval(-42 * 60),
            lastActivity: "Read 2 files",
            turnCounts: ["Edited 3 files", "Ran 5 commands"]
        )
        let resting = WarrenDesktopWorkspaceSessionRow.secondLine(for: counted, now: now)
        XCTAssertEqual(resting.tone, .idle)
        XCTAssertEqual(
            resting.primary,
            "Edited 3 files",
            "The heaviest count leads a resting row"
        )
        XCTAssertEqual(
            resting.extras.map(\.text),
            ["Ran 5 commands"],
            "The second count is the one append a resting row has"
        )
        XCTAssertEqual(resting.meta, .time("42m"), "A resting row shows how long ago it was")

        let plain = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            kind: .claude,
            activity: .ready,
            lastActivity: "Read 2 files"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: plain, now: now).primary,
            "Read 2 files",
            "A turn that counted nothing falls back to the last action"
        )

        let fresh = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell
        )
        let untouched = WarrenDesktopWorkspaceSessionRow.secondLine(for: fresh, now: now)
        XCTAssertEqual(untouched.primary, "New session")
        XCTAssertEqual(untouched.meta, .none)
        XCTAssertNil(untouched.announcement)
    }

    /// The plan takes the trailing column, the elapsed time it displaced
    /// becomes an append, and a full context window joins it.
    func testSessionSecondLineFoldsPlanContextAndCounts() {
        let workspaceID = WorkspaceID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            kind: .claude,
            activity: .working,
            currentStep: "Running swift build",
            plan: WarrenDesktopPlanProgress(done: 3, total: 5, currentStep: "Wire the sidebar"),
            context: WarrenDesktopContextUsage(used: 88, size: 100),
            turnCounts: ["Edited 2 files", "Ran 3 commands"],
            turnStartedAt: now.addingTimeInterval(-72)
        )
        let line = WarrenDesktopWorkspaceSessionRow.secondLine(for: session, now: now)
        XCTAssertEqual(line.meta, .plan(done: 3, total: 5), "A plan owns the trailing column")
        XCTAssertEqual(
            line.extras.map(\.text),
            ["88% ctx", "1m", "Edited 2 files"],
            "The context reminder, the elapsed a plan displaced, then the heaviest count"
        )
        XCTAssertTrue(line.extras.first?.isWarning == true)
    }

    /// The plan's current entry stands in when the tool step alone cannot say
    /// what the Agent is doing.
    func testSessionSecondLineUsesThePlanStepWhenTheToolStepIsSilent() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Claude Code",
            kind: .claude,
            activity: .working,
            plan: WarrenDesktopPlanProgress(done: 0, total: 2, currentStep: "Read the spec")
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session).primary,
            "Read the spec"
        )
    }

    /// A running Agent with neither a tool step nor a plan keeps the last
    /// primary fact it showed, instead of swapping to a foreground command or
    /// the previous turn's past-tense summary.
    func testSessionSecondLineKeepsThePreviousPrimaryForARunningAgent() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Claude Code",
            kind: .claude,
            activity: .working,
            primaryLine: "Running swift build",
            lastActivity: "Ran swift test"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session).primary,
            "Running swift build",
            "The row holds the last primary, not the previous turn's summary"
        )
    }

    /// A shell row falls back to the command in the foreground; the Host keeps
    /// no history, so that is what there is to show.
    func testSessionSecondLineShellUsesTheForegroundCommand() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            customTitle: "Logs",
            kind: .shell,
            runtimeProcess: "head",
            runtimeCommandLine: "head -100 /Users/x/relay.log"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session).primary,
            "head -100 /Users/x/relay.log"
        )
    }

    /// An append is added only when the primary and that whole append fit, and
    /// the first one that does not fit stops the rest.
    func testSessionSecondLineFitAppendsOnlyWholeSegments() {
        let line = WarrenDesktopSessionSecondLine(
            tone: .running,
            primary: "Running swift build",
            extras: [
                .init(text: "88% ctx", isWarning: true),
                .init(text: "1m 12s"),
                .init(text: "Edited 2 files"),
            ],
            meta: .plan(done: 3, total: 5)
        )
        let wide = WarrenDesktopSessionSecondLineLayout.fit(line: line, availableWidth: 400)
        XCTAssertEqual(wide.extras.count, 3, "A wide row takes every append")
        XCTAssertFalse(wide.isPrimaryTruncated)

        let narrow = WarrenDesktopSessionSecondLineLayout.fit(line: line, availableWidth: 140)
        XCTAssertEqual(narrow.extras, [], "A narrow row appends nothing and fades the primary")
        XCTAssertTrue(narrow.isPrimaryTruncated)

        func width(primary: CGFloat, appends: [CGFloat], meta: CGFloat) -> CGFloat {
            meta + WarrenDesktopSessionSecondLineLayout.primaryMetaSpacing
                + primary + appends.reduce(0, +)
        }
        let primary = WarrenDesktopSessionSecondLineLayout.textWidth(
            "Running swift build",
            fontSize: WarrenDesktopSessionSecondLineLayout.primaryFontSize,
            monospaced: false
        )
        let first = WarrenDesktopSessionSecondLineLayout.separatorWidth + WarrenDesktopSessionSecondLineLayout.textWidth(
            "88% ctx",
            fontSize: WarrenDesktopSessionSecondLineLayout.primaryFontSize,
            monospaced: false
        )
        let second = WarrenDesktopSessionSecondLineLayout.separatorWidth + WarrenDesktopSessionSecondLineLayout.textWidth(
            "1m 12s",
            fontSize: WarrenDesktopSessionSecondLineLayout.primaryFontSize,
            monospaced: false
        )
        let meta = WarrenDesktopSessionSecondLineLayout.metaWidth(of: line.meta)
        let one = WarrenDesktopSessionSecondLineLayout.fit(
            line: line,
            availableWidth: width(primary: primary, appends: [first], meta: meta)
        )
        XCTAssertEqual(one.extras.map(\.text), ["88% ctx"], "Exactly one append fits")
        let stillOne = WarrenDesktopSessionSecondLineLayout.fit(
            line: line,
            availableWidth: width(primary: primary, appends: [first, second], meta: meta) - 1
        )
        XCTAssertEqual(
            stillOne.extras.map(\.text),
            ["88% ctx"],
            "The append that does not fit stops the rest instead of skipping ahead"
        )
    }

    /// The fade covers the line's last points and nothing else, so a title that
    /// fits keeps every glyph it has.
    func testOverflowFadeCoversTheLinesTail() {
        XCTAssertEqual(WarrenDesktopFadingLine<EmptyView>.fadeStart(in: 28), 0)
        XCTAssertEqual(WarrenDesktopFadingLine<EmptyView>.fadeStart(in: 10), 0)
        XCTAssertEqual(
            WarrenDesktopFadingLine<EmptyView>.fadeStart(in: 128),
            (128 - WarrenDesktopSidebarMetrics.sessionLineFadeWidth) / 128,
            accuracy: 0.0001
        )
    }

    /// The working row's drift crosses the line and then rests, so the eye is
    /// never offered a loop to settle on.
    func testActivityShimmerSweepsThenRests() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let period = WarrenDesktopActivityShimmer.period
        XCTAssertEqual(
            WarrenDesktopActivityShimmer.center(at: start),
            WarrenDesktopActivityShimmer.center(at: start.addingTimeInterval(period)),
            "One cycle is one cycle"
        )
        let entering = WarrenDesktopActivityShimmer.center(at: start)
        let middle = WarrenDesktopActivityShimmer.center(at: start.addingTimeInterval(period / 2))
        let leaving = WarrenDesktopActivityShimmer.center(
            at: start.addingTimeInterval(period * WarrenDesktopActivityShimmer.sweepShare)
        )
        XCTAssertEqual(
            entering,
            1 + WarrenDesktopActivityShimmer.bandWidth / 2,
            accuracy: 0.0001,
            "The band starts just past the line's right edge"
        )
        XCTAssertGreaterThan(entering, middle)
        XCTAssertGreaterThan(middle, leaving)
        XCTAssertEqual(
            leaving,
            -WarrenDesktopActivityShimmer.bandWidth / 2,
            accuracy: 0.0001,
            "The band comes to rest just past the line's left edge"
        )
        XCTAssertEqual(
            WarrenDesktopActivityShimmer.center(
                at: start.addingTimeInterval(period * WarrenDesktopActivityShimmer.sweepShare + 1)
            ),
            leaving,
            accuracy: 0.0001,
            "The rest of the cycle holds still"
        )
        XCTAssertEqual(WarrenDesktopActivityShimmer.smoothstep(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(WarrenDesktopActivityShimmer.smoothstep(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(WarrenDesktopActivityShimmer.smoothstep(2), 1, accuracy: 0.0001)
    }

    /// A projection copy that only changes a Session's activity lines has to
    /// carry everything else, or an Agent step would erase arrangements the
    /// Host owns.
    func testSessionActivityLinesCopyKeepsTheRestOfTheProjection() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.projection.groups[0].workspaces[0].id
        let session = fixture.projection.activeSessions(in: workspaceID)[0]
        let group = PaneGroup(
            hostID: fixture.host.id,
            workspaceID: workspaceID,
            name: "main",
            tree: .leaf(sessionID: session.id),
            revision: 1
        )
        let arranged = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.projection.groups,
            sessions: fixture.projection.sessions,
            tabs: fixture.projection.tabs,
            paneGroups: [group],
            unreadNoticeCount: 3
        )
        let updated = arranged.withSessionActivityLines(
            currentStep: "Running git status",
            primaryLine: "Running git status",
            lastActivity: "Ran swift test",
            for: session.id
        )
        XCTAssertEqual(updated.paneGroups, [group], "A step update must not drop the arrangements")
        XCTAssertEqual(updated.unreadNoticeCount, 3)
        XCTAssertEqual(
            updated.session(id: session.id)?.currentStep,
            "Running git status"
        )
        XCTAssertEqual(updated.session(id: session.id)?.lastActivity, "Ran swift test")
        XCTAssertEqual(
            arranged.withSessionActivityLines(
                currentStep: session.currentStep,
                primaryLine: session.primaryLine,
                lastActivity: session.lastActivity,
                for: session.id
            ),
            arranged,
            "Nothing changed means no new projection"
        )
    }

    /// A folded row keeps one dot per Session that has a state, capped so the
    /// dots still read as individual Sessions, and reserves exactly the room
    /// it draws in. An idle Session draws nothing and holds no room.
    func testLeafDisclosureShowsDotsOnlyWhileFolded() {
        let marks: [WarrenActivityMark?] = [
            .working, .exited, .ready, nil, .failed, .working, .ready, .inputNeeded, .working,
        ]
        let expanded = WarrenDesktopLeafDisclosure(isExpanded: true, marks: marks, toggle: {})
        XCTAssertEqual(expanded.visibleMarks, [])
        XCTAssertEqual(expanded.accessoryWidth, WarrenDesktopLeafDisclosure.chevronWidth)

        let folded = WarrenDesktopLeafDisclosure(isExpanded: false, marks: marks, toggle: {})
        XCTAssertEqual(
            folded.visibleMarks,
            [.working, .ready, .failed, .working, .ready, .inputNeeded],
            "Idle and exited Sessions draw no dot, and the count stops at the cap"
        )
        XCTAssertGreaterThan(folded.accessoryWidth, expanded.accessoryWidth)

        let quiet = WarrenDesktopLeafDisclosure(isExpanded: false, marks: [nil, .exited, nil], toggle: {})
        XCTAssertEqual(quiet.visibleMarks, [])
        XCTAssertEqual(
            quiet.accessoryWidth,
            WarrenDesktopLeafDisclosure.chevronWidth,
            "A folded row of idle Sessions holds no room for dots"
        )
        XCTAssertFalse(WarrenDesktopTreeFoldDots.drawsAny([nil, .exited]))
        XCTAssertTrue(WarrenDesktopTreeFoldDots.drawsAny([nil, .ready]))
    }

    /// Folded groups pack into a compact list: each knows whether the group
    /// above it is folded, so only an open group draws the hairline.
    func testTreeGroupNeighboursReportTheFoldAbove() {
        struct Group: Identifiable { let id: String; let folded: Bool }
        let groups = [
            Group(id: "open", folded: false),
            Group(id: "quiet", folded: true),
            Group(id: "nexo", folded: true),
            Group(id: "last", folded: true),
        ]
        let neighbours = groups.map {
            WarrenDesktopTreeGroupNeighbours(of: $0, in: groups, isFolded: \.folded)
        }
        XCTAssertEqual(neighbours.map(\.isFirst), [true, false, false, false])
        XCTAssertEqual(
            neighbours.map(\.followsFolded),
            [false, false, true, true],
            "Only a folded group under another folded group skips the hairline"
        )
        XCTAssertEqual(neighbours.map(\.isLast), [false, false, false, true])
        XCTAssertEqual(
            2 * WarrenDesktopSidebarMetrics.foldedGroupInset,
            2,
            "Two folded neighbours sit 2pt apart"
        )
    }

    /// The other Hosts' tiles overlap 7pt at rest and fan out 24pt apart,
    /// raised 3pt, once lifted; the one under the pointer rises 3pt more and
    /// grows by 15%.
    func testOtherHostStackFansOutWhenLifted() {
        typealias Metrics = WarrenDesktopSidebarHostStackMetrics
        XCTAssertEqual(Metrics.tileOffset(index: 2, isLifted: false, hotIndex: nil), CGSize(width: 14, height: 0))
        XCTAssertEqual(Metrics.tileOffset(index: 2, isLifted: true, hotIndex: 1), CGSize(width: 48, height: -3))
        XCTAssertEqual(Metrics.tileOffset(index: 1, isLifted: true, hotIndex: 1), CGSize(width: 24, height: -6))
        XCTAssertEqual(Metrics.tileScale(index: 1, isLifted: true, hotIndex: 1), 1.15)
        XCTAssertEqual(Metrics.tileScale(index: 1, isLifted: false, hotIndex: 1), 1)
        XCTAssertEqual(Metrics.tileIndex(atX: 30, tileCount: 3), 1)
        XCTAssertNil(Metrics.tileIndex(atX: 22, tileCount: 3), "The gap between tiles names no Host")
        XCTAssertNil(Metrics.tileIndex(atX: 80, tileCount: 3))
    }

    /// The panel names where each Host is reached and whether it is online,
    /// and only an actionable Session lights the foot's dot.
    func testOtherHostDescribesItsAddressAndState() {
        XCTAssertEqual(WarrenDesktopSidebarOtherHost.address(fromDetail: "SSH · dev@fsn1"), "dev@fsn1")
        XCTAssertEqual(WarrenDesktopSidebarOtherHost.address(fromDetail: "10.0.4.12"), "10.0.4.12")
        XCTAssertNil(WarrenDesktopSidebarOtherHost.address(fromDetail: "  "))

        let server = WarrenDesktopSidebarOtherHost(
            id: "fsn1", name: "fsn1-dev", address: "10.0.4.12", marks: [.working]
        )
        XCTAssertEqual(server.panelSubtitle, "Server · 10.0.4.12")
        XCTAssertEqual(server.pickDetail, "10.0.4.12")
        XCTAssertEqual(server.initial, "f")
        XCTAssertFalse(server.needsAttention)

        let laptop = WarrenDesktopSidebarOtherHost(
            id: "mba", name: "MBA", isLocal: true, address: "MacBook Air", marks: [.inputNeeded]
        )
        XCTAssertEqual(laptop.panelSubtitle, "Local · MacBook Air")
        XCTAssertEqual(laptop.initial, "m")
        XCTAssertTrue(laptop.needsAttention)

        let offline = WarrenDesktopSidebarOtherHost(
            id: "tenc", name: "tenc_sh", address: "tenc", isOnline: false
        )
        XCTAssertEqual(offline.panelSubtitle, "Offline · tenc")
        XCTAssertEqual(offline.pickDetail, "offline")

        // An SSH alias named for its machine does not say its name twice.
        let alias = WarrenDesktopSidebarOtherHost(id: "beelink", name: "beelink", address: "beelink")
        XCTAssertNil(alias.pickDetail)
        XCTAssertEqual(alias.panelSubtitle, "Server")
    }

    /// The Host row says where the Host is, then what it is; while it is not
    /// connected, it says that instead.
    func testSidebarHostSubtitleNamesPlaceThenDetailOrConnection() {
        XCTAssertEqual(
            WarrenDesktopSidebarHostIdentity.subtitle(
                isLocal: true,
                detail: "Mac Studio",
                connectionState: .attached
            ),
            "Local · Mac Studio"
        )
        XCTAssertEqual(
            WarrenDesktopSidebarHostIdentity.subtitle(
                isLocal: false,
                detail: "  ",
                connectionState: .attached
            ),
            "Remote"
        )
        XCTAssertEqual(
            WarrenDesktopSidebarHostIdentity.subtitle(
                isLocal: false,
                detail: "fsn1-dev",
                connectionState: .failed
            ),
            "Remote · Connection failed"
        )
    }

    /// A project keeps its avatar colour across launches and reorderings, so
    /// the index comes from its ID and nothing else.
    func testProjectAvatarTintIsStablePerIdentity() {
        let first = WarrenDesktopProjectAvatar.stableIndex(for: "project-a", count: 5)
        XCTAssertEqual(first, WarrenDesktopProjectAvatar.stableIndex(for: "project-a", count: 5))
        XCTAssertTrue((0..<5).contains(first))
        XCTAssertEqual(WarrenDesktopProjectAvatar.stableIndex(for: "project-a", count: 0), 0)
    }

    /// The weight is what replaced the indent, so a container row and the rows
    /// inside it must not resolve to the same font.
    func testContainerRowsCarryHeavierWeightThanWhatTheyContain() {
        XCTAssertEqual(WarrenTypography.sidebarContainerRow, WarrenTypography.navigationGroup)
        XCTAssertNotEqual(WarrenTypography.sidebarContainerRow, WarrenTypography.workspaceRow)
        XCTAssertEqual(WarrenTypography.workspaceRow, WarrenTypography.navigationItem)
    }

    /// The right sidebar falls back to an available page when the one a
    /// Workspace remembered is gone (the editor on a remote Host, say).
    func testRightSidebarTabResolutionFallsBackToAnAvailablePage() {
        XCTAssertEqual(
            WarrenDesktopRightSidebarTab.resolve(
                .editor,
                inspectorAvailable: true,
                editorAvailable: false
            ),
            .inspector(.changes)
        )
        XCTAssertEqual(
            WarrenDesktopRightSidebarTab.resolve(
                .inspector(.history),
                inspectorAvailable: true,
                editorAvailable: true
            ),
            .inspector(.history)
        )
        XCTAssertEqual(
            WarrenDesktopRightSidebarTab.resolve(nil, inspectorAvailable: false, editorAvailable: true),
            .editor
        )
        XCTAssertNil(
            WarrenDesktopRightSidebarTab.resolve(nil, inspectorAvailable: false, editorAvailable: false)
        )
    }

    func testEndpointAppearanceAssignsDifferentPaletteEntries() {
        let endpoints = [
            WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true),
            WarrenDesktopEndpointOption(id: "vps", label: "VPS"),
        ]

        let localColor = WarrenDesktopEndpointAppearance.color(
            for: "local",
            in: endpoints,
            tokens: WarrenColorTokens.dark
        )
        let remoteColor = WarrenDesktopEndpointAppearance.color(
            for: "vps",
            in: endpoints,
            tokens: WarrenColorTokens.dark
        )

        XCTAssertNotEqual(localColor, remoteColor)
    }

    func testHostResourceReferencesKeepEndpointScopeInIdentityAndNavigation() {
        let projectID = ProjectID()
        let local = WarrenDesktopHostResourceRef(endpointID: "local", id: projectID)
        let remote = WarrenDesktopHostResourceRef(endpointID: "prod", id: projectID)

        XCTAssertNotEqual(local, remote)
        XCTAssertNotEqual(local.navigationKey, remote.navigationKey)
        XCTAssertEqual(local.navigationKey, "local:\(projectID.description)")
        XCTAssertEqual(remote.navigationKey, "prod:\(projectID.description)")
    }

    @MainActor
    func testMultiHostSidebarScopesSelectionAndExpansionWhenIDsCollide() throws {
        let sharedProjectID = ProjectID()
        let sharedWorkspaceID = WorkspaceID()
        let localHost = Host(name: "Local Mac")
        let remoteHost = Host(name: "Build VPS")
        let localProject = Project(
            id: sharedProjectID,
            hostID: localHost.id,
            name: "Local Project",
            rootPath: "/tmp/local"
        )
        let remoteProject = Project(
            id: sharedProjectID,
            hostID: remoteHost.id,
            name: "Remote Project",
            rootPath: "/tmp/remote"
        )
        let localWorkspace = Workspace(
            id: sharedWorkspaceID,
            projectID: sharedProjectID,
            name: "Local Workspace",
            path: "/tmp/local"
        )
        let remoteWorkspace = Workspace(
            id: sharedWorkspaceID,
            projectID: sharedProjectID,
            name: "Remote Workspace",
            path: "/tmp/remote"
        )
        let localGroup = WarrenDesktopProjectGroup(
            project: localProject,
            workspaces: [localWorkspace]
        )
        let remoteGroup = WarrenDesktopProjectGroup(
            project: remoteProject,
            workspaces: [remoteWorkspace]
        )
        let scopedSelection = WarrenDesktopSidebarResourceSelection.project(
            WarrenDesktopHostResourceRef(endpointID: "local", id: sharedProjectID)
        )
        let recorder = WarrenSemanticRecorder()
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopProjection(
                host: remoteHost,
                groups: [remoteGroup],
                connectionState: .attached
            ),
            navigation: WarrenDesktopNavigationState(selection: .project(sharedProjectID)),
            endpointOptions: [
                .init(id: "local", label: "Local", isLocal: true),
                .init(id: "remote", label: "Remote"),
            ],
            selectedEndpointID: "remote",
            sidebarHostProjections: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: localHost,
                    connectionState: .attached,
                    projectGroups: [localGroup],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(localGroup.workspaces.map(\.id))
                ),
                WarrenDesktopSidebarHostProjection(
                    endpointID: "remote",
                    endpointLabel: "Remote",
                    host: remoteHost,
                    connectionState: .attached,
                    projectGroups: [remoteGroup],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(remoteGroup.workspaces.map(\.id))
                ),
            ],
            usesSidebarHostSections: true,
            sidebarResourceSelection: scopedSelection,
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let localID = "project.host.local.\(sharedProjectID.description)"
        let remoteID = "project.host.remote.\(sharedProjectID.description)"
        let localWorkspaceID = "workspace.host.local.\(sharedWorkspaceID.description)"
        let remoteWorkspaceID = "workspace.host.remote.\(sharedWorkspaceID.description)"
        let initialSnapshot = recorder.snapshot()
        XCTAssertEqual(initialSnapshot.node(id: "sidebar.projects.hosts")?.value, "2 hosts")
        guard let projectsHeader = initialSnapshot.node(id: "sidebar.projects.hosts"),
              let localHostHeader = initialSnapshot.node(id: "host.local.toggle") else {
            XCTFail("Multi-host sidebar must expose its Projects and Host headers")
            return
        }
        XCTAssertEqual(
            localHostHeader.frame.height,
            Double(WarrenLayoutMetrics.sidebarHostHeaderHeight),
            accuracy: 0.01
        )
        XCTAssertEqual(
            localHostHeader.frame.y,
            projectsHeader.frame.y + projectsHeader.frame.height + Double(WarrenSpacing.xs),
            accuracy: 0.01
        )
        // Every project starts open; folding one Host's copy leaves the other
        // Host's copy of the same ID open.
        XCTAssertTrue(initialSnapshot.node(id: localID)?.value?.contains("Expanded") == true)
        XCTAssertTrue(initialSnapshot.node(id: remoteID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(initialSnapshot.node(id: localWorkspaceID))
        XCTAssertNotNil(initialSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "\(remoteID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        let remoteFoldedSnapshot = recorder.snapshot()
        XCTAssertNotNil(remoteFoldedSnapshot.node(id: localWorkspaceID))
        XCTAssertNil(remoteFoldedSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "\(remoteID).toggle")
        try recorder.perform(.press, on: "\(localID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        let collapsedSnapshot = recorder.snapshot()
        XCTAssertNil(collapsedSnapshot.node(id: localWorkspaceID))
        XCTAssertNotNil(collapsedSnapshot.node(id: remoteWorkspaceID))

        try recorder.perform(.press, on: "host.local.toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            recorder.snapshot().node(id: "host.local.toggle")?.value,
            "Collapsed, 1 project"
        )
    }

    @MainActor
    func testMultiHostProjectPrimaryActionOnlyTogglesDisclosure() throws {
        let localHost = Host(name: "Local Mac")
        let remoteHost = Host(name: "Build VPS")
        let project = Project(
            hostID: localHost.id,
            name: "Project",
            rootPath: "/tmp/project"
        )
        let workspace = Workspace(
            projectID: project.id,
            name: "Workspace",
            path: "/tmp/project"
        )
        let group = WarrenDesktopProjectGroup(project: project, workspaces: [workspace])
        let state = SidebarHostRowsTestState(
            hosts: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: localHost,
                    connectionState: .attached,
                    projectGroups: [group],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(group.workspaces.map(\.id))
                ),
                WarrenDesktopSidebarHostProjection(
                    endpointID: "remote",
                    endpointLabel: "Remote",
                    host: remoteHost,
                    connectionState: .attached
                ),
            ],
            selection: nil
        )
        let recorder = WarrenSemanticRecorder()
        let root = SidebarHostRowsTestHarness(
            state: state,
            activeEndpointID: "local"
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let projectID = "project.host.local.\(project.id.description)"
        let workspaceID = "workspace.host.local.\(workspace.id.description)"
        XCTAssertNotNil(recorder.snapshot().node(id: workspaceID))

        try recorder.perform(.press, on: projectID)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertTrue(state.selectedResources.isEmpty)
        XCTAssertTrue(snapshot.node(id: projectID)?.value?.contains("Collapsed") == true)
        XCTAssertNil(snapshot.node(id: workspaceID))
    }

    @MainActor
    func testMultiHostSidebarRevealsTheScopedSelectionWhenItsRosterArrives() {
        let sharedProjectID = ProjectID()
        let sharedWorkspaceID = WorkspaceID()
        let localHost = Host(name: "Local Mac")
        let remoteHost = Host(name: "Build VPS")
        let localProject = Project(
            id: sharedProjectID,
            hostID: localHost.id,
            name: "Local Project",
            rootPath: "/tmp/local"
        )
        let remoteProject = Project(
            id: sharedProjectID,
            hostID: remoteHost.id,
            name: "Remote Project",
            rootPath: "/tmp/remote"
        )
        let localGroup = WarrenDesktopProjectGroup(
            project: localProject,
            workspaces: [
                Workspace(
                    id: sharedWorkspaceID,
                    projectID: sharedProjectID,
                    name: "Local Workspace",
                    path: "/tmp/local"
                ),
            ]
        )
        let remoteGroup = WarrenDesktopProjectGroup(
            project: remoteProject,
            workspaces: [
                Workspace(
                    id: sharedWorkspaceID,
                    projectID: sharedProjectID,
                    name: "Remote Workspace",
                    path: "/tmp/remote"
                ),
            ]
        )
        let localEmpty = WarrenDesktopSidebarHostProjection(
            endpointID: "local",
            endpointLabel: "Local",
            host: localHost,
            connectionState: .attached
        )
        let remoteProjection = WarrenDesktopSidebarHostProjection(
            endpointID: "remote",
            endpointLabel: "Remote",
            host: remoteHost,
            connectionState: .attached,
            projectGroups: [remoteGroup],
            // Each worktree has a Session, so the project keeps its full rows.
            activeWorkspaceIDs: Set(remoteGroup.workspaces.map(\.id))
        )
        let state = SidebarHostRowsTestState(
            hosts: [localEmpty, remoteProjection],
            selection: .project(
                WarrenDesktopHostResourceRef(
                    endpointID: "local",
                    id: sharedProjectID
                )
            )
        )
        let recorder = WarrenSemanticRecorder()
        let root = SidebarHostRowsTestHarness(
            state: state,
            activeEndpointID: "local"
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let localWorkspaceID = "workspace.host.local.\(sharedWorkspaceID.description)"
        let remoteWorkspaceID = "workspace.host.remote.\(sharedWorkspaceID.description)"
        let localProjectID = "project.host.local.\(sharedProjectID.description)"
        let initialSnapshot = recorder.snapshot()
        guard let localEmptyAction = initialSnapshot.node(
            id: "sidebar.empty.host.local.add-project"
        ), let localHostHeader = initialSnapshot.node(id: "host.local.toggle") else {
            XCTFail("Multi-host empty Host must expose its header and add-project action")
            return
        }
        XCTAssertEqual(
            localEmptyAction.frame.x - localHostHeader.frame.x,
            Double(
                WarrenDesktopSidebarIndent.hostEmptyState
                    - WarrenDesktopSidebarMetrics.rowHorizontalPadding
            ),
            accuracy: 0.01
        )
        XCTAssertNil(initialSnapshot.node(id: localWorkspaceID))
        // Projects start open, so the other Host's copy is listed too.
        XCTAssertNotNil(recorder.snapshot().node(id: remoteWorkspaceID))

        state.hosts = [
            WarrenDesktopSidebarHostProjection(
                endpointID: "local",
                endpointLabel: "Local",
                host: localHost,
                connectionState: .attached,
                projectGroups: [localGroup],
                // Each worktree has a Session, so the project keeps its full rows.
                activeWorkspaceIDs: Set(localGroup.workspaces.map(\.id))
            ),
            remoteProjection,
        ]
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.node(id: localProjectID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(snapshot.node(id: localWorkspaceID))
        XCTAssertNotNil(snapshot.node(id: remoteWorkspaceID))
    }

    /// A connected Host this window cannot write to and that holds nothing is
    /// one line: the heading says "no projects" and there is no disclosure to
    /// offer. The active Host keeps its toggle.
    @MainActor
    func testBackgroundHostWithNoProjectsDrawsOneQuietRow() throws {
        let activeHost = Host(name: "Local Mac")
        let idleHost = Host(name: "Idle Server")
        let project = Project(
            hostID: activeHost.id,
            name: "Project",
            rootPath: "/tmp/project"
        )
        let state = SidebarHostRowsTestState(
            hosts: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: activeHost,
                    connectionState: .attached,
                    projectGroups: [
                        WarrenDesktopProjectGroup(project: project, workspaces: []),
                    ]
                ),
                WarrenDesktopSidebarHostProjection(
                    endpointID: "idle",
                    endpointLabel: "Idle",
                    host: idleHost,
                    connectionState: .attached
                ),
            ],
            selection: nil
        )
        let recorder = WarrenSemanticRecorder()
        let root = SidebarHostRowsTestHarness(
            state: state,
            activeEndpointID: "local"
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertNotNil(snapshot.node(id: "host.local.toggle"))
        XCTAssertNil(snapshot.node(id: "host.idle.toggle"))
        XCTAssertNotNil(snapshot.node(id: "host.idle.empty"))
    }

    @MainActor
    func testSingleSidebarHostUsesLegacyProjectPresentation() throws {
        let host = Host(name: "Local Mac")
        let project = Project(
            hostID: host.id,
            name: "Project",
            rootPath: "/tmp/project"
        )
        let workspace = Workspace(
            projectID: project.id,
            name: "Workspace",
            path: "/tmp/project"
        )
        let group = WarrenDesktopProjectGroup(
            project: project,
            workspaces: [workspace]
        )
        let recorder = WarrenSemanticRecorder()
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopProjection(
                host: host,
                groups: [group],
                connectionState: .attached
            ),
            navigation: WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            endpointOptions: [
                .init(id: "local", label: "Local", isLocal: true),
            ],
            selectedEndpointID: "local",
            sidebarHostProjections: [
                WarrenDesktopSidebarHostProjection(
                    endpointID: "local",
                    endpointLabel: "Local",
                    host: host,
                    connectionState: .attached,
                    projectGroups: [group],
                    // Each worktree has a Session, so the project keeps its full rows.
                    activeWorkspaceIDs: Set(group.workspaces.map(\.id))
                ),
            ],
            usesSidebarHostSections: true,
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let projectID = "project.host.local.\(project.id.description)"
        let workspaceID = "workspace.host.local.\(workspace.id.description)"
        let initialSnapshot = recorder.snapshot()
        XCTAssertNil(initialSnapshot.node(id: "sidebar.projects.hosts"))
        XCTAssertNil(initialSnapshot.node(id: "host.local.toggle"))
        XCTAssertTrue(initialSnapshot.node(id: projectID)?.value?.contains("Expanded") == true)
        XCTAssertNotNil(initialSnapshot.node(id: workspaceID))

        try recorder.perform(.press, on: "\(projectID).toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertNil(recorder.snapshot().node(id: workspaceID))
    }

    func testMultiHostProjectsHeaderShowsTheCountOnHover() {
        XCTAssertEqual(
            WarrenDesktopSidebarHostsSectionPresentation.title(
                hostCount: 2,
                isHovered: false
            ),
            "PROJECTS · HOSTS"
        )
        XCTAssertEqual(
            WarrenDesktopSidebarHostsSectionPresentation.title(
                hostCount: 2,
                isHovered: true
            ),
            "PROJECTS · 2"
        )
    }

    func testHostTintAssignmentIsStableAcrossOrderAndResolvesCollisions() {
        let aliases = (0..<64).map { "host-\($0)" }
        let paletteCount = WarrenColorTokens.dark.hostSectionTints.count
        let first = WarrenDesktopHostTint.indices(for: aliases, count: paletteCount)
        let reordered = WarrenDesktopHostTint.indices(
            for: aliases.reversed(),
            count: paletteCount
        )

        XCTAssertEqual(first, reordered)
        var pair: (String, String)?
        for left in aliases {
            for right in aliases where left < right {
                guard WarrenDesktopHostTint.index(for: left, count: paletteCount)
                        == WarrenDesktopHostTint.index(for: right, count: paletteCount) else {
                    continue
                }
                pair = (left, right)
                break
            }
            if pair != nil { break }
        }
        guard let pair else {
            XCTFail("test aliases did not produce a palette collision")
            return
        }
        let collisionAssignments = WarrenDesktopHostTint.indices(
            for: [pair.0, pair.1],
            count: paletteCount
        )
        XCTAssertNotEqual(collisionAssignments[pair.0], collisionAssignments[pair.1])
    }

    func testEndpointOptionsDefaultCapabilitiesFollowEndpointOwnership() {
        let local = WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true)
        let remote = WarrenDesktopEndpointOption(id: "vps", label: "VPS")

        XCTAssertEqual(local.capabilities, .local)
        XCTAssertEqual(remote.capabilities, .remote)
    }

    func testEndpointCapabilitiesCanBeCustomizedForHostProvidedIntegrations() {
        let hostEditor = WarrenDesktopEndpointCapabilities(
            canAddProject: false,
            canImportSuperset: false,
            canUseEmbeddedEditor: true,
            canUseEmbeddedBrowser: true,
            canOpenExternalIDE: true,
            canCopyLocalWebURL: false
        )
        let endpoint = WarrenDesktopEndpointOption(
            id: "vps",
            label: "VPS",
            capabilities: hostEditor
        )

        XCTAssertEqual(endpoint.capabilities, hostEditor)
        XCTAssertTrue(endpoint.capabilities.canUseEmbeddedEditor)
        XCTAssertTrue(endpoint.capabilities.canUseEmbeddedBrowser)
        XCTAssertTrue(endpoint.capabilities.canOpenExternalIDE)
        XCTAssertFalse(endpoint.capabilities.canAddProject)
    }

    // The browser runtime is a Host-launched Chromium, so a remote Host never
    // gets it however capable it is: the capability is not a settings toggle.
    func testRemoteEndpointsNeverAdvertiseTheEmbeddedBrowser() {
        XCTAssertFalse(WarrenDesktopEndpointCapabilities.remote.canUseEmbeddedBrowser)
        XCTAssertTrue(WarrenDesktopEndpointCapabilities.local.canUseEmbeddedBrowser)
        XCTAssertFalse(WarrenDesktopEndpointCapabilities.remote.canUseEmbeddedEditor)
    }

    func testNoticePreservesDetailAndUnreadState() {
        let notice = WarrenDesktopNotice(
            kind: .error,
            title: "Unable to open IDE",
            message: "Launch denied",
            detail: "NSError(domain: WarrenDesktopTests, code: 1)"
        )

        XCTAssertEqual(notice.kind, .error)
        XCTAssertEqual(notice.detail, "NSError(domain: WarrenDesktopTests, code: 1)")
        XCTAssertTrue(notice.isUnread)

        var readNotice = notice
        readNotice.isUnread = false
        XCTAssertFalse(readNotice.isUnread)
    }

    func testNoticeDefaultsDetailToMessage() {
        let notice = WarrenDesktopNotice(title: "Connected", message: "Daemon is ready")

        XCTAssertEqual(notice.detail, notice.message)
        XCTAssertEqual(notice.kind, .info)
    }

    func testRootWorkspaceIsNotClassifiedAsWorktreeForDeletion() {
        let host = Host(name: "Local")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/Users/me/warren")
        let root = Workspace(projectID: project.id, name: "main", path: project.rootPath)
        let worktree = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/Users/me/warren-feature"
        )

        XCTAssertFalse(workspaceIsWorktree(root, project: project))
        XCTAssertTrue(workspaceIsWorktree(worktree, project: project))
    }

    func testExternalIDECatalogHasStableOrderAndBundleIdentifiers() {
        XCTAssertEqual(
            WarrenDesktopExternalIDE.supported.map(\.id),
            [
                .xcode,
                .visualStudioCode,
                .cursor,
                .windsurf,
                .zed,
                .intellijIDEA,
                .intellijIDEACommunity,
                .goLand,
                .pyCharm,
                .pyCharmCommunity,
                .webStorm,
                .phpStorm,
                .rubyMine,
                .clion,
                .rider,
                .dataGrip,
                .rustRover,
                .androidStudio,
                .sublimeText,
                .bbEdit,
                .textMate,
                .macVim,
                .nova,
            ]
        )
        XCTAssertEqual(
            WarrenDesktopExternalIDE.supported.map(\.bundleIdentifier),
            [
                "com.apple.dt.Xcode",
                "com.microsoft.VSCode",
                "com.todesktop.230313mzl4w4u92",
                "com.exafunction.windsurf",
                "dev.zed.Zed",
                "com.jetbrains.intellij",
                "com.jetbrains.intellij.ce",
                "com.jetbrains.goland",
                "com.jetbrains.pycharm",
                "com.jetbrains.pycharm.ce",
                "com.jetbrains.webstorm",
                "com.jetbrains.phpstorm",
                "com.jetbrains.rubymine",
                "com.jetbrains.clion",
                "com.jetbrains.rider",
                "com.jetbrains.datagrip",
                "com.jetbrains.rustrover",
                "com.google.android.studio",
                "com.sublimetext.4",
                "com.barebones.bbedit",
                "com.macromates.TextMate",
                "org.vim.MacVim",
                "com.panic.Nova",
            ]
        )
    }

    func testExternalIDEOptionsEnableOnlyInstalledApplicationsForLocalWorkspace() {
        let projectID = ProjectID()
        let workspace = Workspace(
            projectID: projectID,
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let codeURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.microsoft.VSCode" ? codeURL : nil
            },
            directoryExists: { $0.path == workspace.path },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(options.map(\.id), ["visualStudioCode"])
        XCTAssertEqual(options.map(\.isEnabled), [true])
        XCTAssertEqual(options.first?.workspaceURL?.path, workspace.path)
        XCTAssertEqual(options.first?.applicationURL, codeURL)
    }

    func testExternalIDEOptionsDisableEveryApplicationForRemoteWorkspace() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Remote",
            path: "/srv/warren"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in URL(fileURLWithPath: "/Applications/IDE.app") },
            directoryExists: { _ in true },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: false)

        XCTAssertEqual(options.count, WarrenDesktopExternalIDE.supported.count)
        XCTAssertTrue(options.allSatisfy { !$0.isEnabled })
    }

    func testExternalIDEOptionsDisableEveryApplicationWithoutExistingWorkspaceDirectory() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Missing",
            path: "/missing/worktree"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in URL(fileURLWithPath: "/Applications/IDE.app") },
            directoryExists: { _ in false },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        XCTAssertTrue(
            service.options(for: workspace, isLocalEndpoint: true)
                .allSatisfy { !$0.isEnabled }
        )
        XCTAssertTrue(
            service.options(for: nil, isLocalEndpoint: true)
                .allSatisfy { !$0.isEnabled }
        )
    }

    func testExternalIDEServiceLaunchesWorkspaceWithResolvedApplication() async throws {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var launchedWorkspaceURL: URL?
        var launchedApplicationURL: URL?
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in applicationURL },
            directoryExists: { _ in true },
            launch: { workspaceURL, resolvedApplicationURL in
                launchedWorkspaceURL = workspaceURL
                launchedApplicationURL = resolvedApplicationURL
            }
        )
        let option = try XCTUnwrap(
            service.options(for: workspace, isLocalEndpoint: true)
                .first { $0.id == "goLand" }
        )

        try await service.open(option)

        XCTAssertEqual(launchedWorkspaceURL?.path, workspace.path)
        XCTAssertEqual(launchedApplicationURL, applicationURL)
    }

    func testExternalIDECustomIDEsAppearInOptions() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let custom = WarrenDesktopCustomIDE(name: "Cursor", path: "/Applications/Cursor.app")
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in nil },
            directoryExists: { _ in true },
            loadCustomIDEs: { [custom] },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(options.map(\.id), ["custom:\(custom.id.uuidString)"])
        XCTAssertEqual(options.first?.name, "Cursor")
        XCTAssertEqual(options.first?.applicationURL?.path, "/Applications/Cursor.app")
        XCTAssertEqual(options.first?.isEnabled, true)
    }

    func testExternalIDEOptionsRequestApplicationIcon() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var requestedPaths: [String] = []
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.jetbrains.goland" ? applicationURL : nil
            },
            directoryExists: { _ in true },
            applicationIcon: { url in
                requestedPaths.append(url.path)
                return nil
            },
            launch: { _, _ in }
        )

        _ = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(requestedPaths, ["/Applications/GoLand.app"])
    }

    func testExternalIDEOptionsCacheApplicationResolutionAndIcons() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var resolvedBundleIdentifiers: [String] = []
        var requestedIconPaths: [String] = []
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                resolvedBundleIdentifiers.append(bundleIdentifier)
                return bundleIdentifier == "com.jetbrains.goland" ? applicationURL : nil
            },
            directoryExists: { _ in true },
            applicationIcon: { url in
                requestedIconPaths.append(url.path)
                return nil
            },
            launch: { _, _ in }
        )

        let firstOptions = service.options(for: workspace, isLocalEndpoint: true)
        let secondOptions = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(firstOptions.map(\.id), secondOptions.map(\.id))
        XCTAssertEqual(
            resolvedBundleIdentifiers.count,
            WarrenDesktopExternalIDE.supported.count
        )
        XCTAssertEqual(requestedIconPaths, [applicationURL.path])
    }

    func testExternalIDEOptionsCacheInvalidatesWhenWorkspaceDirectoryChanges() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var directoryExists = true
        var resolveCount = 0
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in
                resolveCount += 1
                return applicationURL
            },
            directoryExists: { _ in directoryExists },
            launch: { _, _ in }
        )

        let availableOptions = service.options(for: workspace, isLocalEndpoint: true)
        directoryExists = false
        let unavailableOptions = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertTrue(availableOptions.allSatisfy(\.isEnabled))
        XCTAssertTrue(unavailableOptions.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(resolveCount, WarrenDesktopExternalIDE.supported.count * 2)
    }

    func testExternalIDEOptionsCacheInvalidatesWhenCustomIDEsChange() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        var customIDEs: [WarrenDesktopCustomIDE] = []
        let custom = WarrenDesktopCustomIDE(
            name: "Custom IDE",
            path: "/Applications/Custom IDE.app"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in nil },
            directoryExists: { _ in true },
            loadCustomIDEs: { customIDEs },
            launch: { _, _ in }
        )

        XCTAssertTrue(service.options(for: workspace, isLocalEndpoint: true).isEmpty)
        customIDEs = [custom]
        let options = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(options.map(\.id), ["custom:\(custom.id.uuidString)"])
    }

    func testExternalIDEIconNormalizesAppKitIntrinsicSize() {
        let source = NSImage(size: NSSize(width: 32, height: 32))
        let normalized = WarrenDesktopExternalIDEIcon.normalized(source)

        XCTAssertEqual(WarrenDesktopExternalIDEIcon.opticalScale(for: "cursor"), 1.2)
        XCTAssertEqual(WarrenDesktopExternalIDEIcon.opticalScale(for: "xcode"), 1)
        XCTAssertEqual(
            WarrenLayoutMetrics.externalIDEIconSize,
            WarrenLayoutMetrics.chromeIconSize * WarrenLayoutMetrics.externalIDEIconScale
        )
        XCTAssertEqual(normalized.size.width, WarrenLayoutMetrics.externalIDEIconSize)
        XCTAssertEqual(normalized.size.height, WarrenLayoutMetrics.externalIDEIconSize)
        XCTAssertFalse(normalized === source)
    }

    func testExternalIDECustomStoreRoundTrips() {
        let defaults = UserDefaults.standard
        let key = "warren.customExternalIDEs"
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let custom = WarrenDesktopCustomIDE(name: "Cursor", path: "/Applications/Cursor.app")
        WarrenDesktopCustomIDEStore.save([custom])
        let loaded = WarrenDesktopCustomIDEStore.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Cursor")
        XCTAssertEqual(loaded.first?.path, "/Applications/Cursor.app")
    }

    func testExternalIDEIsApplicationBundleDetection() {
        XCTAssertTrue(
            WarrenDesktopExternalIDEService.isApplicationBundle(
                URL(fileURLWithPath: "/Applications/Xcode.app")
            )
        )
        XCTAssertFalse(
            WarrenDesktopExternalIDEService.isApplicationBundle(
                URL(fileURLWithPath: "/usr/local/bin/code")
            )
        )
    }

    func testExternalIDEMenuPresentationShowsOnlyInstalledApplications() {
        let options = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.microsoft.VSCode"
                    ? URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
                    : nil
            },
            directoryExists: { _ in true },
            launch: { _, _ in }
        ).options(
            for: Workspace(
                projectID: ProjectID(),
                name: "Feature",
                path: "/Users/me/Workspace/warren-feature"
            ),
            isLocalEndpoint: true
        )

        let items = WarrenDesktopExternalIDEMenuPresentation.items(from: options)

        XCTAssertEqual(items.map(\.title), ["Visual Studio Code"])
        XCTAssertEqual(items.map(\.isEnabled), [true])
    }

    func testRootLayoutMountsAtSupersetDesktopSizeWithoutPixelCapture() {
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(hostingView.bounds.width, 1280)
        XCTAssertEqual(hostingView.bounds.height, 800)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, hostingView.bounds.width)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, hostingView.bounds.height)
        XCTAssertGreaterThanOrEqual(
            hostingView.fittingSize.width,
            WarrenLayoutMetrics.sidebarExpandedWidth + WarrenLayoutMetrics.paneMinimumWidth
        )
        XCTAssertGreaterThanOrEqual(
            hostingView.fittingSize.height,
            WarrenLayoutMetrics.tabBarHeight
                + WarrenLayoutMetrics.paneHeaderHeight
                + WarrenLayoutMetrics.paneMinimumHeight
        )
    }

    func testRemoteEndpointHidesLocalOnboardingAndEditorControls() throws {
        let projection = WarrenDesktopProjection(
            host: Host(name: "Remote"),
            groups: [],
            connectionState: .attached
        )
        let recorder = WarrenSemanticRecorder()
        let root = WarrenDesktopRoot(
            projection: projection,
            endpointOptions: [
                WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true),
                WarrenDesktopEndpointOption(id: "remote", label: "Remote"),
            ],
            selectedEndpointID: "remote",
            embeddedEditorAvailable: true,
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        var nodeIDs = Set(recorder.snapshot().nodes.map(\.id))
        XCTAssertFalse(nodeIDs.contains("onboarding.add-project"))
        XCTAssertFalse(nodeIDs.contains("onboarding.import-superset"))
        // A remote Host has no embedded editor, so the right sidebar has no
        // Editor page and nothing to open it with.
        XCTAssertFalse(nodeIDs.contains("right-sidebar.tab.editor"))
        if nodeIDs.contains("right-sidebar.toggle") {
            try recorder.perform(.press, on: "right-sidebar.toggle")
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            nodeIDs = Set(recorder.snapshot().nodes.map(\.id))
        }
        XCTAssertFalse(nodeIDs.contains("right-sidebar.tab.editor"))
    }

    /// RFC 0021: the editor is a page of the right sidebar beside the Terminal,
    /// and the Terminal never leaves the screen.
    func testEmbeddedEditorOpensBesideTheTerminalAndClosesFromTheSameControl() throws {
        let defaults = UserDefaults.standard
        let previousDefault = defaults.object(
            forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE
        )
        // The sidebar's open switch is one global preference, so a value left
        // over from another run would open the sidebar — and, with no Inspector
        // surface on this root, its only page — before the first press.
        let previousInspectorOpen = defaults.object(forKey: "warren.desktop.inspectorOpen")
        defaults.set(false, forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE)
        defaults.set(false, forKey: "warren.desktop.inspectorOpen")
        defer {
            if let previousDefault {
                defaults.set(
                    previousDefault,
                    forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE
                )
            } else {
                defaults.removeObject(
                    forKey: WarrenPreferenceKey.embeddedEditorDefaultIDE
                )
            }
            if let previousInspectorOpen {
                defaults.set(previousInspectorOpen, forKey: "warren.desktop.inspectorOpen")
            } else {
                defaults.removeObject(forKey: "warren.desktop.inspectorOpen")
            }
        }
        let recorder = WarrenSemanticRecorder()
        var received: [WarrenDesktopAction] = []
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions { received.append($0) },
            embeddedEditorAvailable: true,
            editorSurface: { workspace in
                AnyView(
                    Text("editor:\(workspace.name)")
                        .warrenSemanticElement(
                            id: "embedded-editor.surface",
                            role: .group,
                            label: "Embedded editor"
                        )
                )
            },
            persistenceEnabled: false
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: root)
        // Wide enough to seat the Terminal and the editor region's floor at once.
        hostingView.frame = NSRect(x: 0, y: 0, width: 1600, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // The editor is never a Tab of the track, and nothing is mounted yet.
        XCTAssertNil(
            recorder.snapshot().nodes.first { $0.id == "tab.workspace-editor" }
        )
        XCTAssertNil(
            recorder.snapshot().nodes.first { $0.id == "embedded-editor.surface" }
        )

        try recorder.perform(.press, on: "right-sidebar.toggle")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        try recorder.perform(.press, on: "right-sidebar.tab.editor")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let split = recorder.snapshot()
        XCTAssertNotNil(split.nodes.first { $0.id == "embedded-editor.surface" })
        // The Terminal is still mounted: the editor took width, not its place.
        XCTAssertNotNil(split.nodes.first { $0.id == "test-terminal.tab-main" })
        // The "+" that holds the presets stays in the top bar.
        XCTAssertNotNil(split.nodes.first { $0.id == "tab.new" })
        XCTAssertNotNil(split.nodes.first { $0.id == "central-split.resize" })
        // Nothing about the editor is Host state.
        XCTAssertTrue(received.isEmpty)

        // The Workspace's own row says the activity is a local editor, which is
        // what keeps it visible under `Active only` without implying a Session.
        XCTAssertTrue(
            recorder.snapshot().nodes.contains { node in
                node.id.hasPrefix("workspace.")
                    && (node.value?.contains("Editor open on this Mac") ?? false)
            }
        )
        // The row's marker is also the entry back to the editor, so a Workspace
        // whose editor is open is reachable from the rail rather than only from
        // the chrome control that opened it.
        let editorEntry = try XCTUnwrap(
            recorder.snapshot().nodes.first {
                $0.id.hasPrefix("workspace-editor-entry.")
            }
        )
        XCTAssertEqual(editorEntry.value, "Show the editor")
        try recorder.perform(.press, on: editorEntry.id)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // Navigating from the rail keeps the region and asks only for selection:
        // the entry moves the user to the Workspace, it does not mutate a Host.
        XCTAssertNotNil(
            recorder.snapshot().nodes.first { $0.id == "embedded-editor.surface" }
        )
        XCTAssertTrue(
            received.allSatisfy {
                if case .selectWorkspace = $0 { true } else { false }
            },
            "unexpected actions: \(received)"
        )
        XCTAssertFalse(received.isEmpty)
        received.removeAll()

        // The Editor tab's close box turns the region off without hiding the
        // sidebar.
        try recorder.perform(.press, on: "right-sidebar.editor.close")
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let closed = recorder.snapshot()
        XCTAssertNil(closed.nodes.first { $0.id == "embedded-editor.surface" })
        // Closing does not end the Terminal's Session or reach the Host.
        XCTAssertNotNil(closed.nodes.first { $0.id == "test-terminal.tab-main" })
        XCTAssertTrue(received.isEmpty)
        // One close, not two: closing clears the marker, so the Workspace no
        // longer reads as editor-marked and a relaunch will not reopen it.
        XCTAssertFalse(
            closed.nodes.contains { node in
                node.id.hasPrefix("workspace.")
                    && (node.value?.contains("Editor open on this Mac") ?? false)
            }
        )
        // The rail's entry goes with the marker: nothing points at a region that
        // is no longer there.
        XCTAssertNil(
            closed.nodes.first { $0.id.hasPrefix("workspace-editor-entry.") }
        )
    }

    func testTabBarDragFillerSpansEmptyTrackWhenTabsFit() {
        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions()
        ) { context in
            TestTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let dragViews = descendantViews(
            of: hostingView,
            as: WarrenDesktopWindowDragView.self
        )
        guard let filler = dragViews.first(where: {
            $0.identifier?.rawValue == "warren.tab-bar-drag-region"
        }) else {
            XCTFail("Tab bar drag filler is missing")
            return
        }

        XCTAssertGreaterThanOrEqual(filler.frame.width, 100)
    }

    func testTabBarFollowsNewAndSelectedTabsInOverflowMode() {
        // Overflow now starts at the 96pt floor, not at a fixed width, so this
        // needs more Tabs than a 1000pt window can hold at the floor.
        let initialTabs = (0..<12).map { index in
            ClientTab(
                id: "tab-\(index)",
                title: "Session \(index)",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            )
        }
        let state = TabBarTestState(
            tabs: initialTabs,
            selectedTabID: initialTabs[0].id
        )
        let hostingView = NSHostingView(rootView: TabBarTestHarness(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        let initialScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)

        guard let scrollView = initialScrollViews.first else {
            XCTFail("Tab bar scroll view is missing")
            return
        }
        XCTAssertLessThanOrEqual(scrollView.contentView.bounds.minX, 1)

        let newTab = ClientTab(
            id: "tab-new",
            title: "New session",
            sessionID: TerminalSessionID(rawValue: UUID()),
            kind: .shell
        )
        state.tabs.append(newTab)
        state.selectedTabID = newTab.id
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        let updatedScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)

        guard let updatedScrollView = updatedScrollViews.first else {
            XCTFail("Updated tab bar scroll view is missing")
            return
        }
        XCTAssertGreaterThan(
            updatedScrollView.contentView.bounds.minX,
            1,
            "Selecting a new tab must reveal it in the overflow track"
        )

        state.selectedTabID = initialTabs[0].id
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()

        guard let restoredScrollView = descendantViews(of: hostingView, as: NSScrollView.self).first else {
            XCTFail("Restored tab bar scroll view is missing")
            return
        }

        XCTAssertLessThanOrEqual(
            restoredScrollView.contentView.bounds.minX,
            1,
            "Selecting the first tab must return the overflow track to the leading edge"
        )
    }

    func testTabBarEngagesOverflowModeWhenTrailingChromeLeavesNarrowTrack() {
        let tabs = (0..<12).map { index in
            ClientTab(
                id: "tab-\(index)",
                title: "Session \(index)",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            )
        }
        let tabBar = tabBar(tabs: tabs)

        let hostingView = NSHostingView(rootView: tabBar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        let scrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        XCTAssertTrue(
            WarrenDesktopTabTrack.overflows(
                count: tabs.count,
                tabWidth: WarrenDesktopTabTrack.minimumWidth,
                viewport: 1_000
            ),
            "Twelve Tabs cannot fit a 1000pt track at the floor width"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        let settledScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        XCTAssertEqual(
            settledScrollViews.map(\.frame.width),
            scrollViews.map(\.frame.width),
            "Overflow state must settle instead of toggling"
        )
    }

    /// Few Tabs take the ceiling, and the track still settles: the flexible
    /// track means the scroll view's own width no longer equals a fixed
    /// `count * 150`, so this pins the width a Tab gets instead.
    func testTabBarStaysInFitModeWhenTabsFit() {
        let tabs = [
            ClientTab(
                id: "tab-a",
                title: "A",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            ),
            ClientTab(
                id: "tab-b",
                title: "B",
                sessionID: TerminalSessionID(rawValue: UUID()),
                kind: .shell
            ),
        ]
        let tabBar = tabBar(tabs: tabs)

        let hostingView = NSHostingView(rootView: tabBar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        let scrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        XCTAssertFalse(scrollViews.isEmpty, "The track is a scroll view even when it fits")
        XCTAssertEqual(
            WarrenDesktopTabTrack.tabWidth(count: tabs.count, viewport: 1_000),
            WarrenDesktopTabTrack.maximumWidth,
            "Two Tabs take the ceiling rather than stretching past it"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        let settledScrollViews = descendantViews(of: hostingView, as: NSScrollView.self)
        XCTAssertEqual(
            settledScrollViews.map(\.frame.width),
            scrollViews.map(\.frame.width),
            "Fit state must settle instead of toggling"
        )
    }

    func testOverflowFadeScrollViewSettlesWithHorizontalOverflow() {
        let scroll = WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: 36,
            surface: .black,
            showsEdgeChevrons: true
        ) {
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { _ in
                    Color.white.frame(width: 150, height: 36)
                }
            }
        }
        .frame(width: 500, height: 36)

        let hostingView = NSHostingView(rootView: scroll)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 36)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hostingView.layoutSubtreeIfNeeded()

        let initialFrames = descendantViews(of: hostingView, as: NSScrollView.self).map(\.frame)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            descendantViews(of: hostingView, as: NSScrollView.self).map(\.frame),
            initialFrames
        )
    }

    func testOverflowFadeScrollViewRefreshesEdgesAfterViewportResize() {
        let scroll = WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: 36,
            surface: .black,
            showsEdgeChevrons: true
        ) {
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { _ in
                    Color.white.frame(width: 150, height: 36)
                }
            }
        }

        let hostingView = NSHostingView(rootView: scroll)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 36)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        let narrowWidth = descendantViews(of: hostingView, as: NSScrollView.self).first?.frame.width

        hostingView.setFrameSize(NSSize(width: 2000, height: 36))
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        let wideWidth = descendantViews(of: hostingView, as: NSScrollView.self).first?.frame.width
        XCTAssertNotEqual(narrowWidth, wideWidth)

        hostingView.setFrameSize(NSSize(width: 500, height: 36))
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            descendantViews(of: hostingView, as: NSScrollView.self).first?.frame.width,
            narrowWidth
        )
    }

    private func descendantViews<T: NSView>(
        of view: NSView,
        as type: T.Type
    ) -> [T] {
        var matches: [T] = []
        for subview in view.subviews {
            if let typed = subview as? T {
                matches.append(typed)
            }
            matches.append(contentsOf: descendantViews(of: subview, as: type))
        }
        return matches
    }

    private func tabBar(tabs: [ClientTab]) -> some View {
        makeTabBar(tabs: tabs, selectedTabID: tabs.first?.id)
            .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
    }

    func testWindowDragRegionUsesDedicatedAppKitView() {
        let view = WarrenDesktopWindowDragView()

        XCTAssertFalse(view.acceptsFirstResponder)
    }

    func testSidebarDragRequiresFivePointMovementThreshold() {
        let origin = CGPoint(x: 20, y: 20)

        XCTAssertFalse(WarrenSidebarDragGesture.hasExceededThreshold(
            from: origin,
            to: CGPoint(x: 23, y: 23)
        ))
        XCTAssertTrue(WarrenSidebarDragGesture.hasExceededThreshold(
            from: origin,
            to: CGPoint(x: 23, y: 24)
        ))
    }

    func testSidebarDragOverlayAcceptsFirstModifiedClick() {
        let session = WarrenDesktopSidebarDragSession()
        let view = WarrenDesktopSidebarDragOverlayView(session: session)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testSidebarDragSessionPublishesMeasurementChangesOncePerState() {
        let session = WarrenDesktopSidebarDragSession()
        let clientID = UUID()
        var measurementStates: [Bool] = []

        session.addClient(id: clientID) { measurementStates.append($0) }
        session.setActive(true)
        session.setActive(true)
        session.setActive(false)
        session.removeClient(id: clientID)

        XCTAssertEqual(measurementStates, [true, false])
    }

    func testSidebarDragAutoCollapseKeepsOnlyValidDestinationsVisible() {
        let projectID = ProjectID()
        let otherProjectID = ProjectID()
        let workspaceID = WorkspaceID()
        let projectInfo = WarrenSidebarRowDragInfo(
            id: projectID.description,
            kind: .project(projectID),
            name: "Project",
            isLastOfList: false
        )
        let workspaceInfo = WarrenSidebarRowDragInfo(
            id: workspaceID.description,
            kind: .workspace(workspaceID, projectID: projectID),
            name: "Workspace",
            isLastOfList: false
        )

        XCTAssertEqual(
            WarrenSidebarDragPresentation.autoCollapse(for: projectInfo),
            .allProjects
        )
        XCTAssertEqual(
            WarrenSidebarDragPresentation.autoCollapse(for: workspaceInfo),
            .projectsExcept(projectID)
        )
        XCTAssertTrue(WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedCollapses: [],
            autoCollapse: .projectsExcept(projectID)
        ))
        XCTAssertFalse(WarrenSidebarDragPresentation.isExpanded(
            otherProjectID,
            persistedCollapses: [],
            autoCollapse: .projectsExcept(projectID)
        ))
        XCTAssertFalse(WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedCollapses: [otherProjectID],
            autoCollapse: .allProjects
        ))
    }

    func testConnectionPresentationDistinguishesLoadingAndFailureStates() {
        let connecting = WarrenDesktopConnectionPresentation(.connecting)
        XCTAssertEqual(connecting.label, "Connecting…")
        XCTAssertEqual(connecting.tone, .info)
        XCTAssertTrue(connecting.isActive)

        let reconnecting = WarrenDesktopConnectionPresentation(.reconnecting)
        XCTAssertEqual(reconnecting.label, "Reconnecting…")
        XCTAssertEqual(reconnecting.tone, .warning)
        XCTAssertTrue(reconnecting.isActive)

        let failed = WarrenDesktopConnectionPresentation(.failed)
        XCTAssertEqual(failed.label, "Connection failed")
        XCTAssertEqual(failed.tone, .destructive)
        XCTAssertFalse(failed.isActive)
    }

    func testConnectionPresentationNamesRuntimeMigration() {
        let migrating = WarrenDesktopConnectionPresentation(
            .connecting,
            migratingRuntimeSessions: true
        )

        XCTAssertEqual(migrating.label, "Migrating runtime sessions…")
        XCTAssertEqual(migrating.tone, .info)
        XCTAssertTrue(migrating.isActive)
    }

    func testWindowDragRegionPerformsDragOnSingleClick() {
        let view = WarrenDesktopWindowDragView()
        let window = WarrenDragProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        view.mouseDown(with: Self.mouseDownEvent(clickCount: 1))

        XCTAssertTrue(window.didRequestDrag)
        XCTAssertFalse(window.didToggleFullScreen)
    }

    func testWindowDragRegionDoubleClickNeitherDragsNorEntersFullScreen() {
        let view = WarrenDesktopWindowDragView()
        let window = WarrenDragProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        view.mouseDown(with: Self.mouseDownEvent(clickCount: 2))

        // A double-click follows the system's title-bar preference, which
        // never means Spaces full screen.
        XCTAssertFalse(window.didToggleFullScreen)
        XCTAssertFalse(window.didRequestDrag)
    }

    func testTitleBarDoubleClickFollowsTheSystemPreference() {
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "Minimize"), .minimize)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "None"), .ignore)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "Maximize"), .zoom)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: "Fill"), .zoom)
        XCTAssertEqual(WarrenDesktopTitleBarDoubleClick.action(for: nil), .zoom, "Unset is the system default")
    }

    private static func mouseDownEvent(clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private static func mouseUpEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )!
    }

    private static func mouseEnteredEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 3,
            trackingNumber: 1,
            userData: nil
        )!
    }

    private static func mouseExitedEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 4,
            trackingNumber: 1,
            userData: nil
        )!
    }

    func testSidebarStateUsesSupersetSnapAndRestoreValues() {
        var state = WarrenDesktopSidebarState()
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)
        XCTAssertFalse(state.isCollapsed)

        // A drag below the snap threshold collapses the rail to nothing, but
        // the dragged-to width is kept so the peek reveals it unchanged.
        state.setWidth(119)
        XCTAssertTrue(state.isCollapsed)
        XCTAssertEqual(state.renderedWidth, WarrenLayoutMetrics.sidebarCollapsedWidth)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarCollapsedWidth, 0)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)

        state.toggleCollapsed()
        XCTAssertFalse(state.isCollapsed)
        XCTAssertEqual(state.renderedWidth, state.width)

        state.setWidth(399)
        XCTAssertEqual(state.width, 399)
        state.setWidth(401)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarMaximumWidth)

        // The handle's double-click reset returns the default expanded rail
        // even when the drag ran into the collapse snap.
        state.setWidth(WarrenLayoutMetrics.sidebarSnapThreshold - 1)
        XCTAssertTrue(state.isCollapsed)
        state.restoreExpanded()
        XCTAssertFalse(state.isCollapsed)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarExpandedWidth)
        XCTAssertEqual(state.renderedWidth, WarrenLayoutMetrics.sidebarExpandedWidth)
    }

    /// The width policy and `setWidth` both existed from the start, but nothing
    /// ever called them: the rail was pinned at one width with the collapse button
    /// as the only escape. The handle is what connects them, so it has to be in
    /// the tree and it has to drive a real resize.
    @MainActor
    func testSidebarResizeHandleDrivesTheWidthPolicy() throws {
        var state = WarrenDesktopSidebarState()
        var resets = 0
        let recorder = WarrenSemanticRecorder()
        let handle = WarrenDesktopSidebarResizeHandle(
            width: state.renderedWidth,
            onResize: { state.setWidth($0) },
            onReset: { resets += 1 }
        )
        .frame(height: 400)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: handle)
        hostingView.frame = NSRect(x: 0, y: 0, width: 20, height: 400)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let node = recorder.snapshot().nodes.first { $0.id == "sidebar.resize" }
        XCTAssertNotNil(node, "The rail's only resize affordance must be reachable")
        XCTAssertEqual(
            node?.value,
            "\(Int(WarrenLayoutMetrics.sidebarExpandedWidth)) points"
        )

        // The handle only ever forwards a proposal; the policy owns clamping and
        // the collapse snap, so a drag past either end cannot strand the rail.
        state.setWidth(state.renderedWidth + 200)
        XCTAssertEqual(state.width, WarrenLayoutMetrics.sidebarMaximumWidth)
        state.setWidth(WarrenLayoutMetrics.sidebarSnapThreshold - 1)
        XCTAssertTrue(state.isCollapsed)

        try recorder.perform(.press, on: "sidebar.resize")
        XCTAssertEqual(resets, 1, "Double-click is the way out of a drag gone wrong")

        // The strip has to be wide enough to catch a pointer without eating the
        // click target of the rows beside it.
        XCTAssertGreaterThan(WarrenDesktopSidebarResizeHandle.hitWidth, WarrenSpacing.hairline)
        XCTAssertLessThanOrEqual(WarrenDesktopSidebarResizeHandle.hitWidth, WarrenSpacing.compact)
    }

    /// During a drag the edge holds at the minimum instead of collapsing, and
    /// the drag's distance below it is the pull the indicator shows.
    func testSidebarDragHoldsAtTheMinimumAndMeasuresThePull() {
        let minimum = WarrenLayoutMetrics.sidebarMinimumWidth
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: 300), 300)
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: minimum - 60), minimum)
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: 10), minimum, "A drag never hides the rail mid-way")
        XCTAssertEqual(
            WarrenDesktopSidebarResize.liveWidth(for: WarrenLayoutMetrics.sidebarMaximumWidth + 50),
            WarrenLayoutMetrics.sidebarMaximumWidth
        )
        XCTAssertEqual(WarrenDesktopSidebarResize.liveWidth(for: .nan), WarrenLayoutMetrics.sidebarExpandedWidth)

        XCTAssertEqual(WarrenDesktopSidebarResize.overshoot(for: minimum - 40), 40)
        XCTAssertEqual(WarrenDesktopSidebarResize.overshoot(for: minimum + 40), 0)
        XCTAssertEqual(WarrenDesktopSidebarResize.overshoot(for: .infinity), 0)
    }

    /// Letting go below the hide threshold hides the rail through the stored
    /// policy's own collapse; anywhere else it stays at the minimum. The two
    /// decisions have to agree, because the release hands the proposal to it.
    func testSidebarReleaseHidesOnlyBelowTheThreshold() {
        let threshold = WarrenLayoutMetrics.sidebarSnapThreshold
        XCTAssertTrue(WarrenDesktopSidebarResize.releaseHides(threshold - 1))
        XCTAssertFalse(WarrenDesktopSidebarResize.releaseHides(threshold))
        XCTAssertFalse(WarrenDesktopSidebarResize.releaseHides(WarrenLayoutMetrics.sidebarMinimumWidth - 1))
        XCTAssertFalse(WarrenDesktopSidebarResize.releaseHides(.nan))
        for proposed: CGFloat in [0, 60, threshold - 0.5, threshold, 180, 220, 300, 500] {
            XCTAssertEqual(
                WarrenDesktopSidebarResize.releaseHides(proposed),
                WarrenLayoutMetrics.sidebarWidth(for: proposed) == WarrenLayoutMetrics.sidebarCollapsedWidth,
                "Release and policy disagree at \(proposed)"
            )
        }

        // A drag into the hold and back out leaves the rail at the minimum.
        var held = WarrenDesktopSidebarState()
        held.setWidth(WarrenDesktopSidebarResize.liveWidth(for: threshold + 20))
        XCTAssertFalse(held.isCollapsed)
        XCTAssertEqual(held.width, WarrenLayoutMetrics.sidebarMinimumWidth)

        // A drag that lets go below the threshold hides it.
        var hidden = WarrenDesktopSidebarState()
        hidden.setWidth(WarrenDesktopSidebarResize.liveWidth(for: threshold - 20))
        XCTAssertFalse(hidden.isCollapsed, "Still held while the pointer is down")
        if WarrenDesktopSidebarResize.releaseHides(threshold - 20) {
            hidden.setWidth(threshold - 20)
        }
        XCTAssertTrue(hidden.isCollapsed)
    }

    func testPreviewFixtureKeepsStableRowsAndRelationships() {
        let fixture = WarrenDesktopFixture.preview
        XCTAssertEqual(fixture.groups.count, 2)
        XCTAssertEqual(fixture.groups.first?.workspaces.count, 2)
        XCTAssertEqual(
            fixture.groups.first?.workspaces.first?.projectID,
            fixture.groups.first?.project.id
        )
        XCTAssertEqual(fixture.tabs.map(\.id), ["tab-main", "tab-review"])
        XCTAssertNotNil(fixture.workspace(id: fixture.groups[0].workspaces[0].id))
    }

    func testProjectionKeepsEmptyStateWithoutInventingRows() {
        let fixture = WarrenDesktopFixture.preview
        let projection = WarrenDesktopProjection.empty(host: fixture.host)

        XCTAssertTrue(projection.groups.isEmpty)
        XCTAssertTrue(projection.tabs.isEmpty)
        XCTAssertTrue(projection.isConnected)
        XCTAssertNil(projection.workspace(id: fixture.groups[0].workspaces[0].id))
    }

    func testProjectionFindsFirstWorkspaceAfterAnEmptyProject() {
        let host = WarrenDomain.Host(name: "Indexed Host")
        let emptyProject = Project(hostID: host.id, name: "Empty", rootPath: "/tmp/empty")
        let populatedProject = Project(hostID: host.id, name: "Populated", rootPath: "/tmp/full")
        let workspace = Workspace(
            projectID: populatedProject.id,
            name: "main",
            path: "/tmp/full"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [emptyProject, populatedProject],
            workspaces: [workspace]
        )

        XCTAssertEqual(projection.firstWorkspace, workspace)
        XCTAssertEqual(projection.firstWorkspace(in: populatedProject.id), workspace)
    }

    func testProjectionAggregatesTaskWorkspacesAcrossProjects() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let firstProject = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let secondProject = Project(hostID: host.id, name: "Web", rootPath: "/tmp/web")
        let firstWorkspace = Workspace(
            projectID: firstProject.id,
            taskID: task.id,
            name: "delivery-api",
            path: "/tmp/api-delivery"
        )
        let secondWorkspace = Workspace(
            projectID: secondProject.id,
            taskID: task.id,
            name: "delivery-web",
            path: "/tmp/web-delivery"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: firstWorkspace.id,
            title: "API"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [firstProject, secondProject],
            workspaces: [firstWorkspace, secondWorkspace],
            sessions: [session]
        )

        XCTAssertEqual(projection.taskGroups.map(\.task), [task])
        XCTAssertEqual(
            projection.taskGroups.first?.workspaces.map(\.id),
            [firstWorkspace.id, secondWorkspace.id]
        )
        XCTAssertEqual(projection.groups.map(\.project.id), [firstProject.id, secondProject.id])
        XCTAssertEqual(
            projection.withSessionActivity(.working, for: session.id).taskGroups,
            projection.taskGroups
        )
    }

    func testTaskDeletionIntentCarriesTaskIdentity() {
        let taskID = TaskID()

        guard case .deleteTask(let receivedID) = WarrenDesktopAction.deleteTask(taskID) else {
            return XCTFail("Expected a task deletion action")
        }

        XCTAssertEqual(receivedID, taskID)
    }

    func testTaskDeletionRequestCarriesTaskMetadata() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")

        guard case .task(let receivedTask) = WarrenDesktopDeletionRequest.task(task) else {
            return XCTFail("Expected a task deletion request")
        }

        XCTAssertEqual(receivedTask, task)
    }

    func testTaskRenameRequestCarriesTaskMetadata() {
        let taskID = TaskID()
        let request = WarrenDesktopRenameRequest.task(taskID, name: "Delivery")

        XCTAssertEqual(request.initialValue, "Delivery")
        XCTAssertEqual(request.title, "Rename Task")
        XCTAssertEqual(request.fieldLabel, "Task name")
        XCTAssertTrue(request.message.contains("linked workspaces"))
    }

    @MainActor
    func testProjectsSectionLeavesTaskWorkspacesToTheirTask() throws {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let assigned = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let available = Workspace(
            projectID: project.id,
            name: "available",
            path: "/tmp/api-available"
        )
        let groups = [WarrenDesktopProjectGroup(project: project, workspaces: [assigned, available])]
        let recorder = WarrenSemanticRecorder()
        var selectedTaskID: TaskID?
        var selectedWorkspaceID: WorkspaceID?
        var taskTree = WarrenDesktopSidebarTreeState(
            tasksCollapsed: true
        )
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [WarrenDesktopTaskGroup(task: task, workspaces: [assigned])],
            groups: groups,
            workspaceActivitySummaries: [:],
            // A Session keeps the project out of the inactive list.
            activeWorkspaceIDs: [available.id],
            tree: .constant(WarrenDesktopSidebarTreeState(
            )),
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { taskID in
                selectedTaskID = taskID
                WarrenDesktopSidebar.revealTask(taskID, in: &taskTree)
            },
            onAction: { action in
                if case .selectWorkspace(let workspaceID) = action {
                    selectedWorkspaceID = workspaceID
                }
            },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        // A Task's Workspace is listed under the Task only: the Projects
        // section neither repeats it nor links back to the Task.
        XCTAssertNil(snapshot.node(id: "workspace.project-list.\(assigned.id.description)"))
        XCTAssertNil(snapshot.node(id: "workspace-task.project-list.\(assigned.id.description)"))
        _ = selectedTaskID
        _ = selectedWorkspaceID

        let availableProjectNode = snapshot.node(
            id: "workspace.project-list.\(available.id.description)"
        )
        XCTAssertEqual(availableProjectNode?.label, "Workspace available")
        XCTAssertFalse(availableProjectNode?.value?.contains("Belongs to task") == true)
        XCTAssertNil(snapshot.node(id: "workspace-task.project-list.\(available.id.description)"))

        let assignedTaskNode = snapshot.node(
            id: "workspace.task-list.\(assigned.id.description)"
        )
        XCTAssertEqual(assignedTaskNode?.label, "Workspace API · assigned")
        XCTAssertFalse(assignedTaskNode?.label.contains("Delivery") == true)
        XCTAssertFalse(assignedTaskNode?.value?.contains("Belongs to task") == true)
        XCTAssertNil(snapshot.node(id: "workspace-task.task-list.\(assigned.id.description)"))
    }

    func testSidebarWorkspaceScrollTargetPrefersTaskListForAttachedWorkspace() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let assigned = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let available = Workspace(
            projectID: project.id,
            name: "available",
            path: "/tmp/api-available"
        )

        XCTAssertEqual(
            WarrenDesktopSidebar.workspaceScrollTarget(for: assigned),
            "workspace.task-list.\(assigned.id.description)"
        )
        XCTAssertEqual(
            WarrenDesktopSidebar.workspaceScrollTarget(for: available),
            "workspace.project-list.\(available.id.description)"
        )
    }

    func testHostScopedTaskWorkspaceScrollsToItsTaskRowRatherThanTheProjectTree() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let assigned = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let available = Workspace(
            projectID: project.id,
            name: "available",
            path: "/tmp/api-available"
        )

        // The Host tree renders a task-linked row unselectable, so navigation
        // has to land on the Task row instead of the Projects subtree.
        XCTAssertEqual(
            WarrenDesktopSidebar.hostWorkspaceScrollTarget(
                endpointID: "local",
                workspaceID: assigned.id,
                owningTaskID: task.id
            ),
            "workspace.task-list.\(assigned.id.description)"
        )
        XCTAssertEqual(
            WarrenDesktopSidebar.hostWorkspaceScrollTarget(
                endpointID: "local",
                workspaceID: available.id,
                owningTaskID: nil
            ),
            "host.local.workspace.\(available.id.description)"
        )
        // Tasks are current-Host-only, so a background Host keeps its own row
        // as the activation path even for a task-linked workspace.
        XCTAssertEqual(
            WarrenDesktopSidebar.hostWorkspaceScrollTarget(
                endpointID: "vps",
                workspaceID: assigned.id,
                owningTaskID: nil
            ),
            "host.vps.workspace.\(assigned.id.description)"
        )
    }

    func testTaskWorkspaceOptionsKeepOnlyUnassignedWorkspacesGroupedByProject() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let firstProject = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let secondProject = Project(hostID: host.id, name: "Web", rootPath: "/tmp/web")
        let availableWorkspace = Workspace(
            projectID: firstProject.id,
            name: "available",
            path: "/tmp/api-available"
        )
        let assignedWorkspace = Workspace(
            projectID: firstProject.id,
            taskID: task.id,
            name: "assigned",
            path: "/tmp/api-assigned"
        )
        let groups = [
            WarrenDesktopProjectGroup(
                project: firstProject,
                workspaces: [availableWorkspace, assignedWorkspace]
            ),
            WarrenDesktopProjectGroup(project: secondProject),
        ]

        let availableGroups = WarrenDesktopTaskWorkspaceOptions.availableGroups(from: groups)

        XCTAssertEqual(availableGroups.map(\.project.id), [firstProject.id])
        XCTAssertEqual(availableGroups.flatMap(\.workspaces).map(\.id), [availableWorkspace.id])
    }

    @MainActor
    func testTaskCreationSubmitRejectsUnpairedReferenceAndInvalidURL() async {
        var createCallCount = 0
        var createdRequest: WarrenDesktopTaskCreationRequest?
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            name: "Delivery",
            source: "tapd",
            externalID: "",
            url: "not a URL",
            onCreate: { request in
                createCallCount += 1
                createdRequest = request
                return TaskID()
            },
            onCreated: { _ in }
        )

        XCTAssertEqual(
            coordinator.validationMessage,
            "Source and external ID must be provided together."
        )
        await coordinator.submit()
        XCTAssertEqual(createCallCount, 0)

        coordinator.externalID = "123"
        XCTAssertEqual(
            coordinator.validationMessage,
            "URL must be an absolute HTTP(S) URL."
        )
        await coordinator.submit()
        XCTAssertEqual(createCallCount, 0)

        coordinator.url = "HTTPS://tracker.example/tasks/123"
        XCTAssertNil(coordinator.validationMessage)
        await coordinator.submit()
        XCTAssertEqual(createCallCount, 1)
        XCTAssertEqual(createdRequest?.url, "https://tracker.example/tasks/123")
    }

    @MainActor
    func testTaskCreationSubmitPreventsDuplicatesAndExpandsReturnedID() async {
        let requestID = UUID()
        let started = expectation(description: "Task creation started")
        let fake = PausingTaskCreationFake(callExpectations: [started])
        let host = WarrenDomain.Host(name: "Task Host")
        let first = WarrenTask(hostID: host.id, name: "Delivery")
        let returned = WarrenTask(hostID: host.id, name: "Delivery")
        var tree = WarrenDesktopSidebarTreeState()
        var isPresented = true
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            requestID: requestID,
            name: "Delivery",
            source: "tapd",
            externalID: "123",
            url: "https://tracker.example/tasks/123",
            onCreate: fake.create,
            onCreated: { taskID in
                WarrenDesktopTaskCreationPresentation.complete(
                    taskID: taskID,
                    tree: &tree,
                    onDismiss: { isPresented = false }
                )
            }
        )

        let submission = Task { await coordinator.submit() }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(fake.requests, [WarrenDesktopTaskCreationRequest(
            requestID: requestID,
            name: "Delivery",
            source: "tapd",
            externalID: "123",
            url: "https://tracker.example/tasks/123"
        )])
        XCTAssertTrue(coordinator.isSubmitting)
        XCTAssertTrue(isPresented)

        await coordinator.submit()
        XCTAssertEqual(fake.callCount, 1)

        fake.succeed(returned.id)
        await submission.value

        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertFalse(isPresented)
        XCTAssertNotEqual(first.id, returned.id)
        XCTAssertFalse(tree.collapsedTaskIDs.contains(returned.id))
        XCTAssertTrue(tree.collapsedTaskIDs.isEmpty)
        XCTAssertFalse(tree.tasksCollapsed)
    }

    @MainActor
    func testTaskCreationSubmitFailureKeepsInputsAndAllowsRetry() async {
        let firstStarted = expectation(description: "First task creation started")
        let retryStarted = expectation(description: "Task creation retry started")
        let fake = PausingTaskCreationFake(
            callExpectations: [firstStarted, retryStarted]
        )
        var isPresented = true
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            name: "Delivery",
            source: "tapd",
            externalID: "123",
            url: "https://tracker.example/tasks/123",
            onCreate: fake.create,
            onCreated: { _ in isPresented = false }
        )

        let firstSubmission = Task { await coordinator.submit() }
        await fulfillment(of: [firstStarted], timeout: 1)

        let failure = NSError(
            domain: "TaskCreationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Task creation failed"]
        )
        fake.fail(failure)
        await firstSubmission.value

        XCTAssertFalse(coordinator.isSubmitting)
        XCTAssertTrue(isPresented)
        XCTAssertEqual(coordinator.errorMessage, "Task creation failed")
        XCTAssertEqual(coordinator.name, "Delivery")
        XCTAssertEqual(coordinator.source, "tapd")
        XCTAssertEqual(coordinator.externalID, "123")
        XCTAssertEqual(coordinator.url, "https://tracker.example/tasks/123")

        coordinator.binding(\.url).wrappedValue = "HTTPS://tracker.example/tasks/123"
        XCTAssertNil(coordinator.errorMessage)
        coordinator.binding(\.url).wrappedValue = "https://tracker.example/tasks/123"

        let retry = Task { await coordinator.submit() }
        await fulfillment(of: [retryStarted], timeout: 1)
        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(fake.requests.map(\.requestID), [coordinator.requestID, coordinator.requestID])
        XCTAssertTrue(coordinator.isSubmitting)
        XCTAssertNil(coordinator.errorMessage)
        fake.succeed(TaskID())
        await retry.value
        XCTAssertFalse(isPresented)
    }

    @MainActor
    func testTaskCreationChangesRequestIDOnlyWhenSubmittedDraftChanges() async {
        let requestID = UUID()
        var requests: [WarrenDesktopTaskCreationRequest] = []
        let coordinator = WarrenDesktopTaskCreationCoordinator(
            requestID: requestID,
            name: "Delivery",
            onCreate: { request in
                requests.append(request)
                throw NSError(
                    domain: "TaskCreationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Task creation failed"]
                )
            },
            onCreated: { _ in XCTFail("Failed submissions must not complete creation") }
        )

        await coordinator.submit()
        await coordinator.submit()
        XCTAssertEqual(requests.map(\.requestID), [requestID, requestID])

        coordinator.binding(\.name).wrappedValue = "Updated delivery"
        XCTAssertNil(coordinator.errorMessage)
        await coordinator.submit()

        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(requests[2].requestID, requestID)
        XCTAssertEqual(requests[2].requestID, coordinator.requestID)
    }

    func testProjectionCarriesWorkspaceMergeStateThroughGrouping() {
        let host = WarrenDomain.Host(name: "Merge Host")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "review",
            path: "/tmp/warren-review",
            branch: "review",
            mergeState: .merged
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace]
        )

        XCTAssertEqual(projection.workspace(id: workspace.id)?.mergeState, .merged)
        XCTAssertEqual(
            projection.groups.first?.workspaces.first?.mergeState,
            .merged
        )
    }

    func testWorkspaceEditorStateIsKeyedByHostAndSurvivesRoundTrip() {
        let suiteName = "warren-workspace-editor-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceID = WorkspaceID()

        // Two Hosts can issue equal Workspace UUIDs, so the same ID under a
        // different Endpoint must be a different record rather than the same one.
        let local = WarrenDesktopWorkspaceEditorState(
            hostId: "local",
            workspaceId: workspaceID,
            enabled: true,
            lastRelativeFile: "Sources/App.swift",
            lastLine: 42,
            lastColumn: 1
        )
        let remote = WarrenDesktopWorkspaceEditorState(
            hostId: "remote",
            workspaceId: workspaceID,
            enabled: true,
            lastRelativeFile: "other.swift"
        )
        WarrenDesktopWorkspaceEditorStateStore.save(
            [
                WarrenDesktopWorkspaceEditorStateStore.key(for: local): local,
                WarrenDesktopWorkspaceEditorStateStore.key(for: remote): remote,
            ],
            defaults: defaults
        )

        let restored = WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults)
        XCTAssertEqual(restored.count, 2)
        let localKey = WarrenDesktopWorkspaceEditorKey(
            hostId: "local",
            workspaceId: workspaceID
        )
        XCTAssertEqual(restored[localKey]?.lastRelativeFile, "Sources/App.swift")
        XCTAssertEqual(restored[localKey]?.lastLine, 42)
        XCTAssertEqual(
            restored[
                WarrenDesktopWorkspaceEditorKey(hostId: "remote", workspaceId: workspaceID)
            ]?.lastRelativeFile,
            "other.swift"
        )
    }

    func testWorkspaceEditorStateStoresOnlyEnabledMarkers() {
        let suiteName = "warren-workspace-editor-enabled-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState] = [:]
        for (host, enabled) in [("local", true), ("local", false), ("remote", true)] {
            let state = WarrenDesktopWorkspaceEditorState(
                hostId: host,
                workspaceId: WorkspaceID(),
                enabled: enabled
            )
            states[WarrenDesktopWorkspaceEditorStateStore.key(for: state)] = state
        }

        // A disabled marker is not a record: it is the absence of one, so
        // forgetting a Workspace leaves nothing behind to restore.
        WarrenDesktopWorkspaceEditorStateStore.save(states, defaults: defaults)
        let restored = WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults)
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.values.allSatisfy(\.enabled))

        // Clearing every marker removes the value rather than leaving an empty
        // one behind.
        WarrenDesktopWorkspaceEditorStateStore.save([:], defaults: defaults)
        XCTAssertTrue(
            WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults).isEmpty
        )
    }

    func testWorkspaceEditorStateMigratesLegacyContentModeSelection() {
        let suiteName = "warren-workspace-editor-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceID = WorkspaceID()
        let legacyKey = "warren.desktop.workspaceContentModes.local"
        defaults.set([workspaceID.description], forKey: legacyKey)

        let migrated = WarrenDesktopWorkspaceEditorStateStore
            .restoreMigratingLegacyContentModes(scope: "local", defaults: defaults)

        let key = WarrenDesktopWorkspaceEditorKey(
            hostId: "local",
            workspaceId: workspaceID
        )
        XCTAssertEqual(migrated[key]?.enabled, true)
        // The legacy key is retired, so the migration does not repeat and cannot
        // resurrect a marker the user later forgot.
        XCTAssertNil(defaults.stringArray(forKey: legacyKey))
        XCTAssertEqual(
            WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults)[key]?.enabled,
            true
        )
    }

    func testEditorActivityOverlayWidensOnlyItsOwnHost() {
        let sessionActive = WorkspaceID()
        let editorOnly = WorkspaceID()
        let otherHostEditor = WorkspaceID()
        var states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState] = [:]
        for (host, workspace) in [("local", editorOnly), ("remote", otherHostEditor)] {
            let state = WarrenDesktopWorkspaceEditorState(
                hostId: host,
                workspaceId: workspace,
                enabled: true
            )
            states[WarrenDesktopWorkspaceEditorStateStore.key(for: state)] = state
        }
        let overlay = WarrenDesktopEditorActivityOverlay(states: states)

        XCTAssertEqual(
            overlay.activeWorkspaceIDs([sessionActive], hostId: "local"),
            [sessionActive, editorOnly]
        )
        // A Workspace marked on another Endpoint must not read as active here.
        XCTAssertFalse(
            overlay.activeWorkspaceIDs([sessionActive], hostId: "local")
                .contains(otherHostEditor)
        )
        XCTAssertTrue(overlay.isEditorMarked(otherHostEditor, hostId: "remote"))
        XCTAssertFalse(overlay.isEditorMarked(otherHostEditor, hostId: "local"))
        // An unmarked Workspace with no Session stays filtered.
        XCTAssertEqual(
            WarrenDesktopEditorActivityOverlay().activeWorkspaceIDs([], hostId: "local"),
            []
        )
    }

    func testEditorSplitHonorsTheRegionFloorBeforeTheTerminal() {
        let wide: CGFloat = 1400
        let usable = wide - WarrenLayoutMetrics.editorSplitDividerWidth

        // A drag that would starve the editor region stops at its floor rather
        // than clipping code-server's Explorer.
        XCTAssertEqual(
            WarrenLayoutMetrics.editorSplitTerminalWidth(
                proposedTerminalWidth: usable,
                availableWidth: wide
            ),
            usable - WarrenLayoutMetrics.editorRegionMinimumWidth
        )
        // A drag toward zero stops at the Terminal's own pane minimum.
        XCTAssertEqual(
            WarrenLayoutMetrics.editorSplitTerminalWidth(
                proposedTerminalWidth: 0,
                availableWidth: wide
            ),
            WarrenLayoutMetrics.paneMinimumWidth
        )
        // Too narrow to seat both: the caller is told, rather than handed a
        // width that silently breaks one side.
        XCTAssertNil(
            WarrenLayoutMetrics.editorSplitTerminalWidth(
                proposedTerminalWidth: 400,
                availableWidth: WarrenLayoutMetrics.editorRegionMinimumWidth
            )
        )
    }

    func testActionsExposeProjectWorkspaceAndTabIntentWithoutSideEffects() {
        var received: [WarrenDesktopAction] = []
        let actions = WarrenDesktopActions(
            send: { received.append($0) }
        )

        let fixture = WarrenDesktopFixture.preview
        let projectID = fixture.groups[0].project.id
        let workspaceID = fixture.groups[0].workspaces[0].id
        let taskID = TaskID()
        let sessionID = fixture.sessions[0].id

        actions(.addProject)
        actions(.importSuperset)
        actions(.requestNewWorkspace(projectID))
        actions(.requestNewWorkspace(projectID, taskID: taskID))
        actions(.selectWorkspace(workspaceID))
        actions(.openSession(sessionID))
        actions(.deleteSession(sessionID))
        actions(.moveSession(sessionID, to: .workspace(workspaceID)))
        actions(.requestNewSession(workspaceID))
        actions(.launchSession(workspaceID, .claude))
        actions(.selectTab("tab-main"))
        actions(.restoreNavigation(WarrenDesktopNavigationState(
            selection: .workspace(workspaceID),
            selectedTabID: "tab-main"
        )))
        actions(.clearSelectedTab)
        actions(.toggleSidebar)
        actions(.dismissActivity(sessionID, .working))

        XCTAssertEqual(
            received,
            [
                .addProject,
                .importSuperset,
                .requestNewWorkspace(projectID),
                .requestNewWorkspace(projectID, taskID: taskID),
                .selectWorkspace(workspaceID),
                .openSession(sessionID),
                .deleteSession(sessionID),
                .moveSession(sessionID, to: .workspace(workspaceID)),
                .requestNewSession(workspaceID),
                .launchSession(workspaceID, .claude),
                .selectTab("tab-main"),
                .restoreNavigation(WarrenDesktopNavigationState(
                    selection: .workspace(workspaceID),
                    selectedTabID: "tab-main"
                )),
                .clearSelectedTab,
                .toggleSidebar,
                .dismissActivity(sessionID, .working),
            ]
        )
    }

    func testBuiltInPresetsMapToExplicitLaunchRequests() {
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.id), ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae", "browser"])
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.map(\.presetBarTitle),
            ["Shell", "Claude", "Codex", "OpenCode", "Pi", "Qoder", "Antigravity", "Trae", "Browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.compactMap(\.presetBarIconName),
            ["preset-shell", "preset-claude", "preset-codex", "preset-opencode", "preset-pi", "preset-qoder", "preset-antigravity", "preset-trae", "preset-browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.map(\.request),
            [
                .shell, .claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae, TerminalSessionLaunchRequest(kind: .browser),
            ]
        )
        XCTAssertNil(TerminalSessionLaunchRequest.shell.command)
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.command, "claude")
        // Built-in presets carry no user title: the Host derives the default
        // display name from the kind and keeps the custom-title slot free for
        // automatic AI title generation. The launch title is presentation copy
        // owned by the preset catalog, not a session custom title.
        XCTAssertNil(TerminalSessionLaunchRequest.claude.title)
        XCTAssertEqual(
            TerminalSessionLaunchRequest.codex.command,
            "codex --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(TerminalSessionLaunchRequest.opencode.command, "opencode")
        XCTAssertNil(TerminalSessionLaunchRequest.opencode.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.pi.command, "pi")
        XCTAssertNil(TerminalSessionLaunchRequest.pi.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.qoder.command, "qoder")
        XCTAssertNil(TerminalSessionLaunchRequest.qoder.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.trae.command, "trae-cli interactive")
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI?.id, "claude")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.firstAI?
                .resolvedRequest(commandOverride: "claude --model sonnet").command,
            "claude --model sonnet"
        )
        // The command override keeps the preset title slot untouched (nil for
        // built-ins), so no preset name leaks into the custom-title slot.
        XCTAssertNil(
            WarrenDesktopSessionPreset.pinned.first { $0.id == "codex" }?
                .resolvedRequest(commandOverride: "codex --model gpt-5").title
        )
    }

    /// Claude, Codex, and OpenCode launch as a Conversation over ACP when the
    /// interface asks for it; every other preset ignores the choice.
    func testConversationLaunchUsesACPOnlyForSupportingPresets() {
        let presets = Dictionary(uniqueKeysWithValues: WarrenDesktopSessionPreset.pinned.map { ($0.id, $0) })

        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.filter(\.supportsConversation).map(\.id),
            ["claude", "codex", "opencode"]
        )
        XCTAssertEqual(
            presets["claude"]?.resolvedRequest(commandOverride: "claude --model sonnet", conversation: true),
            TerminalSessionLaunchRequest(kind: .claude, agentHandler: "acp")
        )
        XCTAssertEqual(
            presets["codex"]?.resolvedRequest(commandOverride: "", conversation: false),
            .codex
        )
        XCTAssertEqual(
            presets["pi"]?.resolvedRequest(commandOverride: "", conversation: true),
            .pi
        )
        XCTAssertEqual(WarrenAgentInterface(storedValue: nil), .ask)
        XCTAssertEqual(WarrenAgentInterface(storedValue: "bogus"), .ask)
        XCTAssertEqual(WarrenAgentInterface(storedValue: "acp"), .acp)
    }

    func testPresetOrderNormalizesPersistedIdentifiers() {
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder("codex,shell,codex,future"),
            ["codex", "shell", "claude", "opencode", "pi", "qoder", "antigravity", "trae", "browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder(""),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae", "browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrderRawValue("codex,shell,codex,future"),
            "codex,shell,claude,opencode,pi,qoder,antigravity,trae,browser"
        )
    }

    func testPresetOrderControlsPresentation() {
        let order = "shell,codex,claude,opencode,pi,qoder,antigravity,trae,browser"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedPinned(by: order).map(\.id),
            ["shell", "codex", "claude", "opencode", "pi", "qoder", "antigravity", "trae", "browser"]
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI(orderedBy: order)?.id, "codex")
    }

    func testPresetVisibilityHidesTraeByDefaultAndControlsAutomaticAI() {
        XCTAssertEqual(WarrenDesktopSessionPreset.defaultHiddenRawValue, "trae")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedVisible(
                by: WarrenDesktopSessionPreset.defaultOrderRawValue,
                hidden: WarrenDesktopSessionPreset.defaultHiddenRawValue
            ).map(\.id),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "browser"]
        )

        let onlyTraeVisible = WarrenDesktopSessionPreset.pinned
            .map(\.id)
            .filter { $0 != "trae" }
            .joined(separator: ",")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.firstAI(
                orderedBy: "trae,shell,claude,codex",
                hidden: onlyTraeVisible
            )?.id,
            "trae"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.settingVisibility(of: "trae", visible: true, in: "trae"),
            ""
        )
    }

    /// Only a local endpoint can show the page a browser Session draws, so a
    /// remote Host must not offer the preset. The preference is untouched: the
    /// preset returns when the endpoint does.
    func testBrowserPresetIsOfferedOnlyWhereItsPageCanBeSeen() {
        let order = WarrenDesktopSessionPreset.defaultOrderRawValue
        let hidden = WarrenDesktopSessionPreset.defaultHiddenRawValue

        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedLaunchable(
                by: order,
                hidden: hidden,
                embeddedBrowser: true
            ).map(\.id),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedLaunchable(
                by: order,
                hidden: hidden,
                embeddedBrowser: false
            ).map(\.id),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity"]
        )
        XCTAssertFalse(
            WarrenDesktopSessionPreset.normalizedHidden(hidden).contains("browser"),
            "Endpoint capability must not be recorded as a hidden-preset preference"
        )
    }

    func testPresetLaunchFeedbackDisablesDuplicateStarts() {
        XCTAssertFalse(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: false, isPending: false))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: true, isPending: false))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: false, isPending: true))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: false, isBusy: false, isPending: false))
        XCTAssertEqual(WarrenDesktopPresetLaunchFeedback.label(isPending: true), "Starting…")
        XCTAssertEqual(WarrenDesktopPresetLaunchFeedback.label(isPending: false), "Ready")
    }

    func testEveryPresetAcceptsItsOwnCommandOverride() {
        // A Chat preset has no command: the Host picks the provider's ACP server.
        for preset in WarrenDesktopSessionPreset.pinned where preset.request.kind != .browser && !preset.request.isConversation {
            XCTAssertEqual(
                preset.resolvedRequest(commandOverride: "personal-\(preset.id)").command,
                "personal-\(preset.id)"
            )
        }
        let trae = WarrenDesktopSessionPreset.pinned.first { $0.id == "trae" }
        XCTAssertEqual(trae?.resolvedRequest(commandOverride: "").command, "trae-cli interactive")
    }

    /// A browser Session has no command line: the Host launches Chromium
    /// itself. A typed override must not reach the launch request, or the
    /// preset would promise a command nothing runs.
    func testBrowserPresetIgnoresCommandOverrides() {
        let browser = WarrenDesktopSessionPreset.pinned.first { $0.id == "browser" }
        XCTAssertEqual(browser?.request.kind, .browser)
        XCTAssertNil(browser?.request.command)
        XCTAssertNil(browser?.resolvedRequest(commandOverride: "chromium --headless").command)
        XCTAssertNil(browser?.resolvedRequest(commandOverride: "").command)
        XCTAssertEqual(browser?.createButtonTitle, "Open Browser")
        XCTAssertFalse(browser?.isAI ?? true)
    }

    func testAutomaticShellPolicyIsOptInForAnEmptyWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let emptyWorkspaceID = fixture.groups[0].workspaces[1].id
        let action = WarrenDesktopAction.openWorkspace(emptyWorkspaceID)

        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: action,
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: false
        ))
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: action,
                in: fixture.projection,
                creatingWorkspaceIDs: [],
                autoOpenShell: true
            ),
            emptyWorkspaceID
        )
    }

    func testAutomaticShellPolicyRejectsPopulatedPendingAndPassiveActions() {
        let fixture = WarrenDesktopFixture.preview
        let populatedWorkspaceID = fixture.groups[0].workspaces[0].id
        let emptyWorkspaceID = fixture.groups[0].workspaces[1].id

        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .openWorkspace(populatedWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: true
        ))
        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .openWorkspace(emptyWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [emptyWorkspaceID],
            autoOpenShell: true
        ))
        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .selectWorkspace(emptyWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: true
        ))
    }

    func testAutomaticAIPolicyIsOptInAndWinsOnDoubleClick() {
        let fixture = WarrenDesktopFixture.preview
        let project = fixture.groups[0].project.id
        let emptyWorkspaceID = fixture.groups[0].workspaces[1].id

        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: .selectWorkspace(emptyWorkspaceID),
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: false,
            autoStartAI: false
        ))
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: .selectWorkspace(emptyWorkspaceID),
                in: fixture.projection,
                creatingWorkspaceIDs: [],
                autoOpenShell: false,
                autoStartAI: true
            ),
            emptyWorkspaceID
        )
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: .selectProject(project),
                in: WarrenDesktopProjection(
                    host: fixture.projection.host,
                    projects: [fixture.groups[0].project],
                    workspaces: [fixture.groups[0].workspaces[1]]
                ),
                creatingWorkspaceIDs: [],
                autoOpenShell: false,
                autoStartAI: true
            ),
            emptyWorkspaceID
        )
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: .openWorkspace(emptyWorkspaceID),
                in: fixture.projection,
                creatingWorkspaceIDs: [],
                autoOpenShell: true,
                autoStartAI: true
            ),
            emptyWorkspaceID
        )
    }

    func testPresetOrderMovesWithinBounds() {
        let order = "shell,claude,codex,opencode,pi,qoder,antigravity,trae,browser"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("codex", by: -1, in: order),
            "shell,codex,claude,opencode,pi,qoder,antigravity,trae,browser"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("shell", by: -1, in: order),
            order
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("browser", by: 1, in: order),
            order
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("trae", by: 1, in: order),
            "shell,claude,codex,opencode,pi,qoder,antigravity,browser,trae"
        )
    }

    /// Dragging a preset row onto another is one gesture, so it moves the row
    /// in front of its target rather than stepping through the ones between.
    func testPresetOrderMovesARowInFrontOfItsDropTarget() {
        let order = "shell,claude,codex,opencode,pi,qoder,antigravity,trae,browser"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("browser", before: "shell", in: order),
            "browser,shell,claude,codex,opencode,pi,qoder,antigravity,trae"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("shell", before: "codex", in: order),
            "claude,shell,codex,opencode,pi,qoder,antigravity,trae,browser"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("claude", before: "claude", in: order),
            order,
            "Dropping a row on itself changes nothing"
        )
    }

    func testTabCyclerRequiresMultipleTabsAndWrapsInBothDirections() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertEqual(tabs.count, 2)

        XCTAssertNil(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: [tabs[0]],
            selectedTabID: tabs[0].id
        ))
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: nil
        ), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: tabs[0].id
        ), tabs[1].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: true,
            in: tabs,
            selectedTabID: tabs[1].id
        ), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabCycler.tabID(
            forward: false,
            in: tabs,
            selectedTabID: tabs[0].id
        ), tabs[1].id)
    }

    func testTabNumberSelectorIsOneBasedAndBoundsChecked() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertEqual(WarrenDesktopTabSelector.tabID(in: tabs, number: 1), tabs[0].id)
        XCTAssertEqual(WarrenDesktopTabSelector.tabID(in: tabs, number: 2), tabs[1].id)
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: 0))
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: 3))
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: [], number: 1))
    }

    /// ⌘N addresses Sessions only.
    ///
    /// The editor used to occupy the position after the last Session, which made
    /// the same keystroke mean different things depending on whether a Workspace
    /// had ever opened it. It is a region beside the track now, reached from the
    /// rail instead.
    func testTabNumberSelectorAddressesSessionsOnly() {
        let tabs = WarrenDesktopFixture.preview.projection.tabs
        XCTAssertNil(WarrenDesktopTabSelector.tabID(in: tabs, number: tabs.count + 1))
    }

    func testTabTitleNamesAShellAtTheWorktreeRootByItsShell() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-1",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "warren",
            path: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: workspace
            ),
            "zsh"
        )
        XCTAssertEqual(
            WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: workspace.path)
                .runningCommand,
            ""
        )
    }

    func testTabTitleNamesAnAgentByItsKindWhenNoTitleIsSet() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-2",
            title: "Codex",
            sessionID: sessionID,
            kind: .codex
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Codex",
            kind: .codex,
            runtimeProcess: "codex",
            workingDirectory: "/Users/me/Workspace/superset"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "Codex"
        )
    }

    func testTabTitleSummarizesACustomCommandSession() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-cmdline",
            title: "Custom",
            sessionID: sessionID,
            kind: .custom
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Custom",
            kind: .custom,
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev -- --port 3000",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "npm run dev"
        )
    }

    func testTabTitleTreatsForegroundShellAsPrompt() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-shell-prompt",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell,
            runtimeProcess: "zsh",
            runtimeCommandLine: "-zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "warren",
            path: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: workspace
            ),
            "zsh"
        )
        XCTAssertEqual(
            WarrenDesktopTabTitle.resolvedCommand(
                kind: .shell,
                process: "zsh",
                commandLine: "-zsh"
            ),
            ""
        )
    }

    func testTabTitleKeepsManagedAgentPurposeWhenForegroundProcessIsShell() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-codex-shell",
            title: "Codex",
            sessionID: sessionID,
            kind: .codex
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Codex",
            kind: .codex,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: nil
            ),
            "Codex"
        )
    }

    func testTabTitleFallsBackWhenNoDirectoryIsKnown() {
        let tab = ClientTab(id: "tab-3", title: "Shell", kind: .shell)

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: nil,
                workspace: nil
            ),
            "Shell"
        )

        let codexTab = ClientTab(id: "tab-codex", title: "Codex", kind: .codex)
        let codexSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Codex",
            kind: .codex,
            runtimeProcess: "",
            workingDirectory: ""
        )
        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: codexTab,
                session: codexSession,
                workspace: nil
            ),
            "Codex"
        )
    }

    func testTabTitlePrefersCustomSessionTitle() {
        let workspaceID = WorkspaceID()
        let sessionID = TerminalSessionID()
        let tab = ClientTab(
            id: "tab-4",
            title: "Shell",
            sessionID: sessionID,
            kind: .shell
        )
        let session = WarrenDesktopSession(
            id: sessionID,
            workspaceID: workspaceID,
            title: "Shell",
            customTitle: "My Agent",
            kind: .shell,
            runtimeProcess: "zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "warren",
            path: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.displayTitle(
                tab: tab,
                session: session,
                workspace: workspace
            ),
            "My Agent"
        )
    }

    func testSidebarSessionTitleNeverRepeatsTheRunningCommand() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            kind: .shell,
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev",
            workingDirectory: "/Users/me/Workspace/warren",
            shellState: WarrenDesktopShellState(
                atPrompt: false,
                runningCommand: "npm run dev",
                shellName: "zsh"
            )
        )
        let resolved = WarrenDesktopTabTitle.sessionTitle(
            for: session,
            worktreeRoot: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(resolved.title, "zsh")
        XCTAssertEqual(resolved.runningCommand, "npm run dev")
    }

    func testSidebarSessionTitleNamesAShellAtTheWorktreeRoot() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            kind: .shell,
            runtimeProcess: "zsh",
            runtimeCommandLine: "-zsh",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: "/Users/me/Workspace/warren").title,
            "zsh"
        )
    }

    func testSidebarSessionTitlePrefersAUserSetName() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            customTitle: "My Agent",
            kind: .shell,
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev",
            workingDirectory: "/Users/me/Workspace/warren"
        )

        XCTAssertEqual(
            WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: "/Users/me/Workspace/warren").title,
            "My Agent"
        )
    }

    func testSessionDisplayTitlePrefersCustomTitle() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            customTitle: "My Agent"
        )
        XCTAssertEqual(session.displayTitle, "My Agent")

        let defaultSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Codex"
        )
        XCTAssertEqual(defaultSession.displayTitle, "Codex")
    }

    func testProjectionKeepsPinnedProjectsWorkspacesAndSessionsFirst() {
        let host = WarrenDomain.Host(name: "Pinned Host")
        let pinnedProject = Project(
            hostID: host.id,
            name: "Pinned",
            rootPath: "/tmp/pinned",
            pinned: true
        )
        let regularProject = Project(hostID: host.id, name: "Regular", rootPath: "/tmp/regular")
        let pinnedWorkspace = Workspace(
            projectID: pinnedProject.id,
            name: "Pinned Worktree",
            path: "/tmp/pinned-worktree",
            pinned: true
        )
        let regularWorkspace = Workspace(
            projectID: pinnedProject.id,
            name: "Regular Worktree",
            path: "/tmp/regular-worktree"
        )
        let pinnedSessionID = TerminalSessionID()
        let regularSessionID = TerminalSessionID()
        let pinnedSession = WarrenDesktopSession(
            id: pinnedSessionID,
            workspaceID: pinnedWorkspace.id,
            title: "Pinned",
            pinned: true
        )
        let regularSession = WarrenDesktopSession(
            id: regularSessionID,
            workspaceID: pinnedWorkspace.id,
            title: "Regular"
        )
        let pinnedTab = ClientTab(
            id: "pinned-tab",
            title: "Pinned",
            sessionID: pinnedSessionID
        )
        let regularTab = ClientTab(
            id: "regular-tab",
            title: "Regular",
            sessionID: regularSessionID
        )

        let projection = WarrenDesktopProjection(
            host: host,
            projects: [regularProject, pinnedProject],
            workspaces: [regularWorkspace, pinnedWorkspace],
            sessions: [regularSession, pinnedSession],
            tabs: [regularTab, pinnedTab],
            sessionWorkspaceIDs: [
                pinnedSessionID: pinnedWorkspace.id,
                regularSessionID: pinnedWorkspace.id,
            ]
        )

        XCTAssertEqual(projection.groups.first?.project.id, pinnedProject.id)
        XCTAssertEqual(projection.groups.first?.workspaces.first?.id, pinnedWorkspace.id)
        XCTAssertEqual(projection.tabs.first?.id, pinnedTab.id)
    }

    func testPresetIconCacheLoadsHitsAndMissesOnlyOnce() {
        var loads: [String] = []
        let expected = NSImage(size: NSSize(width: 12, height: 12))
        let cache = WarrenPresetIconCache { name in
            loads.append(name)
            return name == "known" ? expected : nil
        }

        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertEqual(loads, ["known", "missing"])
    }

    func testPackagedPresetIconsAreValidImages() throws {
        let iconNames = try WarrenDesktopSessionPreset.pinned.map {
            try XCTUnwrap($0.presetBarIconName)
        } + ["preset-codex-white"]

        for iconName in iconNames {
            let image = try XCTUnwrap(WarrenPresetIconCache.shared.image(named: iconName))
            XCTAssertTrue(image.isValid, "Expected \(iconName) to decode as a valid image")
        }
    }

    /// The cache marks an image as a template on first load and then hands that
    /// same instance to everyone, so a tintable icon must not be reachable under
    /// a name that also serves an untinted one.
    func testPresetIconCacheAppliesTemplateFlagOnFirstLoad() {
        let cache = WarrenPresetIconCache { _ in NSImage(size: NSSize(width: 12, height: 12)) }

        XCTAssertEqual(cache.image(named: "tinted", template: true)?.isTemplate, true)
        XCTAssertEqual(cache.image(named: "brand")?.isTemplate, false)
    }

    /// Only the single-color glyphs are tinted. A brand mark's color is its
    /// identity, so tinting one would erase it — and Codex's mark is two-tone,
    /// which a template mask would flatten into a solid blob.
    func testOnlySingleColorPresetGlyphsAreTinted() {
        let tintable = Set(
            WarrenDesktopSessionPreset.pinned
                .filter(\.presetBarIconIsTintable)
                .map(\.id)
        )

        XCTAssertEqual(tintable, ["shell", "opencode", "pi", "browser"])
        for brand in ["claude", "codex", "qoder", "antigravity", "trae"] {
            XCTAssertFalse(tintable.contains(brand), "\(brand) is a brand mark")
        }
    }

    func testSelectionReconcilesEmptyToLoadedProjection() {
        let fixture = WarrenDesktopFixture.preview
        let empty = WarrenDesktopProjection.empty(host: fixture.host)

        let emptyState = WarrenDesktopSelectionReconciler.reconcile(
            selection: nil,
            selectedTabID: nil,
            with: empty
        )
        XCTAssertNil(emptyState.selection)
        XCTAssertNil(emptyState.selectedTabID)

        let loadedState = WarrenDesktopSelectionReconciler.reconcile(
            selection: emptyState.selection,
            selectedTabID: emptyState.selectedTabID,
            with: fixture.projection
        )
        XCTAssertEqual(
            loadedState.selection,
            .workspace(fixture.groups[0].workspaces[0].id)
        )
        XCTAssertEqual(loadedState.selectedTabID, "tab-main")
    }

    func testSelectionReconcilesRemovedProjectWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let firstProjectID = fixture.groups[0].project.id
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let secondWorkspaceID = fixture.groups[1].workspaces[0].id

        let current = WarrenDesktopSelectionReconciler.reconcile(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main",
            with: fixture.projection
        )
        XCTAssertEqual(current.selection, .workspace(firstWorkspaceID))
        XCTAssertEqual(current.selectedTabID, "tab-main")

        let reducedGroups = fixture.projection.groups.filter { $0.project.id != firstProjectID }
        let reducedProjection = WarrenDesktopProjection(
            host: fixture.host,
            groups: reducedGroups,
            sessions: fixture.projection.sessions.filter { $0.tabID != "tab-main" },
            tabs: fixture.projection.tabs.filter { $0.id != "tab-main" },
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs
        )
        let reduced = WarrenDesktopSelectionReconciler.reconcile(
            selection: current.selection,
            selectedTabID: current.selectedTabID,
            with: reducedProjection
        )
        XCTAssertEqual(reduced.selection, .workspace(secondWorkspaceID))
        XCTAssertEqual(reduced.selectedTabID, "tab-review")

        let emptied = WarrenDesktopSelectionReconciler.reconcile(
            selection: reduced.selection,
            selectedTabID: reduced.selectedTabID,
            with: WarrenDesktopProjection.empty(host: fixture.host)
        )
        XCTAssertNil(emptied.selection)
        XCTAssertNil(emptied.selectedTabID)
    }

    func testSelectingWorkspaceNeverLeavesAnotherWorkspaceTabActive() {
        let fixture = WarrenDesktopFixture.preview
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let initial = WarrenDesktopNavigationState(
            selection: .workspace(firstWorkspaceID),
            selectedTabID: "tab-main"
        )

        let selected = WarrenDesktopNavigationReducer.reduce(
            initial,
            action: .selectWorkspace(workspaceWithoutTabID),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspaceWithoutTabID))
        XCTAssertNil(selected.selectedTabID)
        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reconcile(selected, with: fixture.projection),
            selected
        )
    }

    func testSelectingWorkspaceRestoresItsLastTab() {
        let fixture = WarrenDesktopFixture.preview
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let reviewWorkspaceID = fixture.groups[1].workspaces[0].id
        let alternateTab = ClientTab(
            id: "tab-alt",
            title: "Alternate",
            kind: .shell
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: fixture.tabs + [alternateTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [alternateTab.id: firstWorkspaceID]
        )

        let selectedAlternate = WarrenDesktopNavigationReducer.reduce(
            .init(),
            action: .selectTab(alternateTab.id),
            in: projection
        )
        let selectedReview = WarrenDesktopNavigationReducer.reduce(
            selectedAlternate,
            action: .selectWorkspace(reviewWorkspaceID),
            in: projection
        )
        let restored = WarrenDesktopNavigationReducer.reduce(
            selectedReview,
            action: .selectWorkspace(firstWorkspaceID),
            in: projection
        )

        XCTAssertEqual(selectedReview.selectedTabID, "tab-review")
        XCTAssertEqual(restored.selection, .workspace(firstWorkspaceID))
        XCTAssertEqual(restored.selectedTabID, alternateTab.id)
    }

    func testSelectingProjectRestoresItsLastWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let projectID = fixture.groups[0].project.id
        let firstWorkspaceID = fixture.groups[0].workspaces[0].id
        let secondWorkspaceID = fixture.groups[0].workspaces[1].id
        let featureTab = ClientTab(
            id: "tab-feature",
            title: "Feature",
            kind: .shell
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: fixture.tabs + [featureTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [featureTab.id: secondWorkspaceID]
        )

        let selectedFeature = WarrenDesktopNavigationReducer.reduce(
            .init(selection: .workspace(firstWorkspaceID), selectedTabID: "tab-main"),
            action: .selectTab(featureTab.id),
            in: projection
        )
        let restored = WarrenDesktopNavigationReducer.reduce(
            selectedFeature,
            action: .selectProject(projectID),
            in: projection
        )

        XCTAssertEqual(restored.selection, .workspace(secondWorkspaceID))
        XCTAssertEqual(restored.selectedTabID, featureTab.id)
    }

    func testRestoringSettingsPositionReturnsToThePreviousWorkspaceAndTab() {
        let fixture = WarrenDesktopFixture.preview
        let previous = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[1].workspaces[0].id),
            selectedTabID: "tab-review"
        )
        let current = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[0].workspaces[0].id),
            selectedTabID: "tab-main"
        )

        let restored = WarrenDesktopNavigationReducer.reduce(
            current,
            action: .restoreNavigation(previous),
            in: fixture.projection
        )

        XCTAssertEqual(restored.selection, previous.selection)
        XCTAssertEqual(restored.selectedTabID, previous.selectedTabID)
    }

    func testRestoringSettingsPositionReconcilesADeletedTabWithoutLeavingItsWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let previous = WarrenDesktopNavigationState(
            selection: .workspace(workspaceID),
            selectedTabID: "deleted-tab"
        )

        let restored = WarrenDesktopNavigationReducer.reduce(
            WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            action: .restoreNavigation(previous),
            in: fixture.projection
        )

        XCTAssertEqual(restored.selection, .workspace(workspaceID))
        XCTAssertEqual(restored.selectedTabID, "tab-main")
    }

    func testDeletingWorkspaceReturnsToTheMostRecentlyVisitedWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceA = fixture.groups[0].workspaces[0]
        let workspaceB = fixture.groups[1].workspaces[0]

        // 1. Visit workspace A
        let stateA = WarrenDesktopNavigationReducer.reduce(
            .init(),
            action: .selectWorkspace(workspaceA.id),
            in: fixture.projection
        )
        XCTAssertEqual(stateA.selection, .workspace(workspaceA.id))

        // 2. Jump to workspace B
        let stateB = WarrenDesktopNavigationReducer.reduce(
            stateA,
            action: .selectWorkspace(workspaceB.id),
            in: fixture.projection
        )
        XCTAssertEqual(stateB.selection, .workspace(workspaceB.id))

        // 3. Delete workspace B and reconcile with a projection that no longer has workspace B
        let deletedState = WarrenDesktopNavigationReducer.reduce(
            stateB,
            action: .deleteWorkspace(workspaceB.id, removeLocalWorktree: false),
            in: fixture.projection
        )

        let projectionWithoutB = WarrenDesktopProjection(
            host: fixture.host,
            groups: [fixture.groups[0]],
            sessions: fixture.sessions.filter { $0.workspaceID != workspaceB.id },
            tabs: fixture.tabs.filter { fixture.projection.workspaceID(forTabID: $0.id) != workspaceB.id }
        )

        let reconciled = WarrenDesktopNavigationReducer.reconcile(deletedState, with: projectionWithoutB)
        XCTAssertEqual(reconciled.selection, .workspace(workspaceA.id))
        XCTAssertEqual(reconciled.selectedTabID, "tab-main")
    }

    /// Taking the last pane off screen leaves the workspace selected with no
    /// live pane, and keeps the visit memory so the next split or selection can
    /// still fall back to the tab the user was last in.
    func testClearingTheSelectedTabKeepsScopeAndVisitMemory() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let tab1 = ClientTab(id: "tab-1", title: "Tab 1", kind: .shell)
        let tab2 = ClientTab(id: "tab-2", title: "Tab 2", kind: .shell)
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: [tab1, tab2],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [tab1.id: workspaceID, tab2.id: workspaceID]
        )

        let visited1 = WarrenDesktopNavigationReducer.reduce(.init(), action: .selectTab(tab1.id), in: projection)
        let visited2 = WarrenDesktopNavigationReducer.reduce(visited1, action: .selectTab(tab2.id), in: projection)
        let cleared = WarrenDesktopNavigationReducer.reduce(visited2, action: .clearSelectedTab, in: projection)

        XCTAssertEqual(cleared.selection, .workspace(workspaceID))
        XCTAssertNil(cleared.selectedTabID)
        XCTAssertEqual(cleared.memory, visited2.memory)

        // The Session is untouched, so selecting the workspace again picks the
        // most recently visited tab back up.
        let reselected = WarrenDesktopNavigationReducer.reduce(
            cleared,
            action: .selectWorkspace(workspaceID),
            in: projection
        )
        XCTAssertEqual(reselected.selectedTabID, tab2.id)
    }

    func testDeletingSessionReturnsToTheMostRecentlyVisitedTab() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let session1 = WarrenDesktopSession(id: TerminalSessionID(), workspaceID: workspaceID, tabID: "tab-s1", title: "S1", kind: .shell)
        let session2 = WarrenDesktopSession(id: TerminalSessionID(), workspaceID: workspaceID, tabID: "tab-s2", title: "S2", kind: .shell)
        let tab1 = ClientTab(id: "tab-s1", title: "S1", sessionID: session1.id, kind: .shell)
        let tab2 = ClientTab(id: "tab-s2", title: "S2", sessionID: session2.id, kind: .shell)
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [session1, session2],
            tabs: [tab1, tab2],
            sessionWorkspaceIDs: [session1.id: workspaceID, session2.id: workspaceID],
            tabWorkspaceIDs: [tab1.id: workspaceID, tab2.id: workspaceID]
        )

        let s1 = WarrenDesktopNavigationReducer.reduce(.init(), action: .selectTab(tab1.id), in: projection)
        let s2 = WarrenDesktopNavigationReducer.reduce(s1, action: .selectTab(tab2.id), in: projection)
        XCTAssertEqual(s2.selectedTabID, tab2.id)

        let afterDeleteSession2 = WarrenDesktopNavigationReducer.reduce(s2, action: .deleteSession(session2.id), in: projection)
        XCTAssertEqual(afterDeleteSession2.selectedTabID, tab1.id)
    }

    func testPendingShellTabBelongsToWorkspaceBeforeSessionExists() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[1].id
        let pendingTab = ClientTab(
            id: "pending-shell-\(workspaceID.description)",
            title: "Starting Shell…",
            kind: .shell
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: fixture.sessions,
            tabs: fixture.tabs + [pendingTab],
            sessionWorkspaceIDs: fixture.projection.sessionWorkspaceIDs,
            tabWorkspaceIDs: [pendingTab.id: workspaceID]
        )

        XCTAssertEqual(projection.tabs(in: workspaceID), [pendingTab])
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectWorkspace(workspaceID),
            in: projection
        )
        XCTAssertEqual(selected.selectedTabID, pendingTab.id)
    }

    func testWorkspaceActivityUsesMostActionableSessionState() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let working = fixture.sessions[0]
        let failed = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "failed",
            title: "Failed",
            kind: .codex,
            state: .failed,
            activity: .failed
        )
        let waiting = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "waiting",
            title: "Waiting",
            kind: .claude,
            activity: .blocked
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [working, waiting, failed]
        )

        XCTAssertEqual(projection.activity(in: workspaceID), .failed)
        XCTAssertEqual(projection.workspaceActivities[workspaceID], .failed)
        XCTAssertEqual(
            projection.workspaceActivitySummaries[workspaceID]?.activeTabCount,
            0
        )
        XCTAssertEqual(projection.session(id: failed.id), failed)
    }

    /// The rollup used to reduce to the lifecycle half of the status before it
    /// ever reached a row, so a collapsed Workspace could not say whether the
    /// Agent inside it wanted an approval, wanted an answer, or had merely
    /// stopped. Every one of those drew the same marker.
    func testWorkspaceRollupKeepsWhatTheHostIsAskingFor() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let working = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "working",
            title: "Working",
            kind: .codex,
            activity: .working
        )
        let awaitingApproval = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "approval",
            title: "Approval",
            kind: .claude,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Run rm -rf build?")
            )
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [working, awaitingApproval]
        )

        XCTAssertEqual(projection.mark(in: workspaceID), .approvalNeeded)
        XCTAssertEqual(
            projection.workspaceActivitySummaries[workspaceID]?.mark,
            .approvalNeeded
        )
        // The lifecycle accessors still answer as before, so a caller that only
        // compares states is unaffected by the richer rollup.
        XCTAssertEqual(projection.activity(in: workspaceID), .blocked)
    }

    /// A Host can report an attention payload alongside a lifecycle value that
    /// has not caught up yet. Reading the lifecycle first drew the quiet idle
    /// marker on the one Session that needed someone.
    func testAStaleReadyCarryingAttentionStillReadsAsActionable() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "stale",
            title: "Stale",
            kind: .claude,
            agentStatus: AgentStatus(
                activity: .ready,
                attention: AgentAttention(kind: .input, reason: "Which branch?")
            )
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [session]
        )

        XCTAssertEqual(session.activityMark, .inputNeeded)
        XCTAssertEqual(projection.mark(in: workspaceID), .inputNeeded)
        XCTAssertEqual(session.activityMark?.tier, .actionable)
    }



    @MainActor
    func testRichWorkspaceRowsShowEveryLiveSessionAsALeaf() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let codex = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let claude = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Review API",
            kind: .claude,
            activity: .ready
        )
        // A shell the Host promoted through an Agent binding reports activity.
        let promotedShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Bound shell",
            kind: .shell,
            activity: .working
        )
        // A shell with no Agent binding reports no activity, but it is still a
        // live Session and therefore still a leaf of the tree.
        let plainShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Plain shell",
            kind: .shell
        )
        let ended = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Ended",
            kind: .codex,
            state: .exited,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [codex, claude, promotedShell, plainShell, ended]
        )
        let recorder = WarrenSemanticRecorder()
        var actions: [WarrenDesktopAction] = []
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState()),
            selection: .workspace(workspace.id),
            selectedTabID: "tab.codex",
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onAction: { actions.append($0) },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let richNodes = recorder.snapshot().nodes.filter {
            $0.id.hasPrefix("workspace-session.project-list.")
        }
        XCTAssertEqual(richNodes.count, 4)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: richNodes.map { ($0.label, $0.value) }),
            [
                // The open Session is the selected row, so its value carries the
                // selection the same way every other navigation row does.
                "Codex Session Implement API": "Working · API · feature · Selected",
                "Claude Code Session Review API": "Done · API · feature",
                "Shell Session Bound shell": "Working · API · feature",
                "Shell Session Plain shell": "API · feature",
            ]
        )
        XCTAssertTrue(
            richNodes.first { $0.label.contains("Implement API") }?.isSelected == true
        )
        XCTAssertFalse(richNodes.contains { $0.label.contains("Ended") })

        try recorder.perform(
            .press,
            on: "workspace-session.project-list.\(workspace.id.description).\(codex.id.description)"
        )
        XCTAssertEqual(actions, [.openSession(codex.id)])
    }

    /// A completion notice is news exactly once. Selecting the row is what
    /// retires it, so the tree stops drawing it while the Session keeps reporting
    /// `ready` — and a failure or a request is never retired by being seen.
    @MainActor
    func testACompletionStopsDrawingOnceItsRowHasBeenSelected() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let finished = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Migrate",
            kind: .claude,
            activity: .ready
        )
        let awaiting = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Rename",
            kind: .codex,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Run the migration?")
            )
        )
        var acknowledgments = WarrenDesktopActivityAcknowledgments()
        acknowledgments.acknowledge(finished)

        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [
                finished.acknowledgingActivity(acknowledgments[finished.id]),
                awaiting,
            ]
        )
        let recorder = WarrenSemanticRecorder()
        var actions: [WarrenDesktopAction] = []
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState()),
            selection: .workspace(workspace.id),
            selectedTabID: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onAction: { actions.append($0) },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // The read completion says nothing; the unanswered request still does.
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: recorder.snapshot().nodes.filter {
                $0.id.hasPrefix("workspace-session.project-list.")
            }.map { ($0.label, $0.value) }),
            [
                "Claude Code Session Migrate": "API · feature",
                "Codex Session Rename": "Approval needed · Run the migration? · API · feature",
            ]
        )
        // The Workspace rollup follows what is drawn, so it names the request
        // rather than the read completion.
        XCTAssertEqual(projection.mark(in: workspace.id), .approvalNeeded)
    }

    /// Two Sessions that both read as "blocked" to the Host ask a person for
    /// different things. The tree used to name them identically — one shared
    /// "Needs attention" — and draw them identically, so the row could not be
    /// acted on without opening it first.
    @MainActor
    func testARowNamesWhichRequestIsWaiting() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let approval = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Migrate",
            kind: .claude,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Run the migration?")
            )
        )
        let question = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Rename",
            kind: .codex,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .input, reason: "Which branch?")
            )
        )
        // No payload to explain it, so the row must not name a request.
        let unexplained = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Stalled",
            kind: .codex,
            activity: .blocked
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [approval, question, unexplained]
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState()),
            selection: .workspace(workspace.id),
            selectedTabID: nil,
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
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let leaves = recorder.snapshot().nodes.filter {
            $0.id.hasPrefix("workspace-session.project-list.")
        }
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: leaves.map { ($0.label, $0.value) }),
            [
                "Claude Code Session Migrate": "Approval needed · Run the migration? · API · feature",
                "Codex Session Rename": "Input needed · Which branch? · API · feature",
                "Codex Session Stalled": "Needs attention · API · feature",
            ]
        )
    }

    /// Opening a Session keeps its workspace as the navigation scope, so both
    /// rows match the selection. Only the leaf may claim it: it is the row the
    /// user clicked and the more specific answer to "where am I". The workspace
    /// states containment instead, so the rail still says which workspace is
    /// live without stealing the highlight from the row below it.
    /// A project with one worktree has nothing to choose between, so it holds
    /// that worktree's Sessions directly and names the branch beside itself.
    /// A second worktree brings the worktree rows back.
    @MainActor
    func testProjectWithOneWorktreeHoldsItsSessionsDirectly() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let main = Workspace(projectID: project.id, name: "main", path: "/tmp/api", branch: "main")
        let feature = Workspace(projectID: project.id, name: "feature", path: "/tmp/api-feature")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: main.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )

        func nodes(workspaces: [Workspace]) -> [String: WarrenSemanticNode] {
            let projection = WarrenDesktopProjection(
                host: host,
                projects: [project],
                workspaces: workspaces,
                sessions: [session]
            )
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: [],
                groups: projection.groups,
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
                activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState()),
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
            .frame(width: 300, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let mainRowID = "workspace.project-list.\(main.id.description)"
        let leafID = "workspace-session.project-list.\(main.id.description).\(session.id.description)"

        let solo = nodes(workspaces: [main])
        XCTAssertNil(solo[mainRowID], "One worktree draws no worktree row")
        XCTAssertNotNil(solo[leafID], "Its Sessions hang under the project")

        // A second worktree with no Session folds into the idle row, so the
        // project still lists its one live worktree by name.
        let pair = nodes(workspaces: [main, feature])
        XCTAssertNotNil(pair[mainRowID])
        XCTAssertNil(pair["workspace.project-list.\(feature.id.description)"])
        XCTAssertNotNil(pair["project-idle-worktrees.\(project.id.description)"])
        XCTAssertNotNil(pair[leafID])
    }

    @MainActor
    func testSelectingASessionLeafMovesTheHighlightOffItsWorkspace() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        // A second worktree, so the project draws its worktree rows rather than
        // holding the only one's Sessions directly.
        let other = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/api"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace, other],
            sessions: [session]
        )

        func nodes(selectedTabID: String?) throws -> [String: WarrenSemanticNode] {
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: [],
                groups: projection.groups,
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
                activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState()),
                selection: .workspace(workspace.id),
                selectedTabID: selectedTabID,
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
            .frame(width: 420, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let workspaceID = "workspace.project-list.\(workspace.id.description)"
        let leafID = "workspace-session.project-list."
            + "\(workspace.id.description).\(session.id.description)"

        let withLeafOpen = try nodes(selectedTabID: "tab.codex")
        XCTAssertEqual(withLeafOpen[leafID]?.isSelected, true)
        XCTAssertEqual(withLeafOpen[workspaceID]?.isSelected, false)
        XCTAssertEqual(
            withLeafOpen[workspaceID]?.value,
            "Contains the selected session · Not selected"
        )

        // With no Session open the workspace is the deepest live row, so it
        // takes the selection back rather than leaving the rail unanswered.
        let withNoLeafOpen = try nodes(selectedTabID: nil)
        XCTAssertEqual(withNoLeafOpen[leafID]?.isSelected, false)
        XCTAssertEqual(withNoLeafOpen[workspaceID]?.isSelected, true)
    }

    /// The multi-Host sections hold a one-worktree project's Sessions directly
    /// too, on the current Host and on a background one alike.
    @MainActor
    func testHostSectionProjectWithOneWorktreeHoldsItsSessionsDirectly() throws {
        let host = WarrenDomain.Host(name: "Local")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "main", path: "/tmp/api", branch: "main")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        func section(_ endpointID: String) -> WarrenDesktopSidebarHostProjection {
            WarrenDesktopSidebarHostProjection(
                endpointID: endpointID,
                endpointLabel: endpointID.capitalized,
                host: host,
                connectionState: .attached,
                projectGroups: [WarrenDesktopProjectGroup(project: project, workspaces: [workspace])],
                activeSessionsByWorkspaceID: [workspace.id: [session]],
                activeWorkspaceIDs: [workspace.id]
            )
        }
        let state = SidebarHostRowsTestState(hosts: [section("local"), section("remote")], selection: nil)
        let recorder = WarrenSemanticRecorder()
        let root = SidebarHostRowsTestHarness(
            state: state,
            activeEndpointID: "local",
            workspaceDisplayMode: .rich
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let ids = Set(recorder.snapshot().nodes.map(\.id))
        for endpointID in ["local", "remote"] {
            XCTAssertFalse(
                ids.contains("workspace.host.\(endpointID).\(workspace.id.description)"),
                "One worktree draws no worktree row on \(endpointID)"
            )
            XCTAssertTrue(
                ids.contains(
                    "workspace-session.host.\(endpointID).\(workspace.id.description).\(session.id.description)"
                ),
                "Its Sessions hang under the project on \(endpointID)"
            )
        }
    }

    /// The multi-Host sections are a second implementation of the same tree, so
    /// they carry the same rule: the leaf takes the selection, its workspace
    /// states containment. A background Host has nothing open, so none of its
    /// leaves draw as selected even where the tab IDs would collide.
    @MainActor
    func testHostSectionLeafTakesTheSelectionFromItsWorkspace() throws {
        let localHost = WarrenDomain.Host(name: "Local")
        let project = Project(hostID: localHost.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "feature", path: "/tmp/a")
        // A second worktree, so the project draws its worktree rows rather than
        // holding the only one's Sessions directly.
        let other = Workspace(projectID: project.id, name: "main", path: "/tmp/b")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        func projection(endpointID: String) -> WarrenDesktopSidebarHostProjection {
            WarrenDesktopSidebarHostProjection(
                endpointID: endpointID,
                endpointLabel: endpointID.capitalized,
                host: localHost,
                connectionState: .attached,
                projectGroups: [
                    WarrenDesktopProjectGroup(project: project, workspaces: [workspace, other]),
                ],
                activeSessionsByWorkspaceID: [workspace.id: [session]],
                activeWorkspaceIDs: [workspace.id]
            )
        }

        func nodes(activeEndpointID: String) throws -> [String: WarrenSemanticNode] {
            let recorder = WarrenSemanticRecorder()
            let state = SidebarHostRowsTestState(
                hosts: [projection(endpointID: "local"), projection(endpointID: "remote")],
                selection: .workspace(
                    WarrenDesktopHostResourceRef(endpointID: "local", id: workspace.id)
                )
            )
            let rows = SidebarHostRowsTestHarness(
                state: state,
                activeEndpointID: activeEndpointID,
                workspaceDisplayMode: .rich,
                selectedTabID: "tab.codex"
            )
            .frame(width: 420, height: 600)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let localWorkspaceID = "workspace.host.local.\(workspace.id.description)"
        let localLeafID = "workspace-session.host.local."
            + "\(workspace.id.description).\(session.id.description)"
        let remoteLeafID = "workspace-session.host.remote."
            + "\(workspace.id.description).\(session.id.description)"

        let onLocal = try nodes(activeEndpointID: "local")
        XCTAssertEqual(onLocal[localLeafID]?.isSelected, true)
        XCTAssertEqual(onLocal[localWorkspaceID]?.isSelected, false)
        // The two Hosts here project the same tab ID, so a leaf that matched on
        // the tab alone would light up in both sections at once.
        XCTAssertNotEqual(
            onLocal[remoteLeafID]?.isSelected,
            true,
            "A background Host has nothing open, so no leaf of its own is selected"
        )

        // With the selected workspace's Host in the background, nothing there is
        // open either, so its workspace row takes the selection back.
        let onRemote = try nodes(activeEndpointID: "remote")
        XCTAssertEqual(onRemote[localLeafID]?.isSelected, false)
        XCTAssertEqual(onRemote[localWorkspaceID]?.isSelected, true)
    }

    /// A shell that the Host bound to an Agent must be named and drawn as that
    /// provider. Reading only the durable launch kind made every Agent started
    /// inside a shell render as a plain terminal.
    func testSessionPresentationFollowsTheBoundAgentProvider() {
        let workspaceID = WorkspaceID()
        let boundShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Implement API",
            kind: .shell,
            agentProvider: .claude,
            activity: .working
        )
        XCTAssertEqual(boundShell.presentedKind, .claude)
        XCTAssertEqual(boundShell.kind, .shell, "The durable launch kind must not be rewritten")
        XCTAssertTrue(boundShell.isAgentSession)

        // A dedicated Agent Session keeps its own kind even if the Host also
        // reports a provider for it.
        let codex = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Review",
            kind: .codex,
            agentProvider: .claude
        )
        XCTAssertEqual(codex.presentedKind, .codex)

        let plainShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell
        )
        XCTAssertEqual(plainShell.presentedKind, .shell)
        XCTAssertFalse(plainShell.isAgentSession)
    }

    /// The leaf names the provider and reports what the Session is actually
    /// doing: why an Agent is blocked, or what a plain shell is running. A
    /// shell with no Agent binding contributes no activity word.
    @MainActor
    func testRichSessionRowsReportAttentionReasonAndShellProcess() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "feature", path: "/tmp/api-feature")
        let blocked = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .shell,
            agentProvider: .claude,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .approval, reason: "Approve running tests")
            )
        )
        let shell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Shell",
            kind: .shell,
            runtimeProcess: "npm run dev",
            workingDirectory: "/tmp/api-feature/Sources"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [blocked, shell]
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState()),
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
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let rowsByLabel = Dictionary(
            uniqueKeysWithValues: recorder.snapshot().nodes
                .filter { $0.id.hasPrefix("workspace-session.") }
                .map { ($0.label, $0.value) }
        )
        XCTAssertEqual(
            rowsByLabel["Claude Code Session Implement API"],
            "Approval needed · Approve running tests · API · feature",
            "A bound Agent names its provider and explains what it is waiting for"
        )
        XCTAssertEqual(
            rowsByLabel["Shell Session Sources"],
            "npm run dev · API · feature",
            "A plain shell names where it is and reports its process without claiming an activity it cannot observe"
        )
    }

    /// The tab strip no longer lists a workspace's other Sessions, so the leaf
    /// is the only place a Session can be renamed, pinned, or ended. A leaf
    /// without those actions would strand them.
    func testSessionLeafOwnsEveryPerSessionAction() {
        let titles = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: false,
            onTogglePin: {},
            onRename: {},
            onEnd: {}
        ).compactMap { action -> String? in
            guard case .button(let title, _, _) = action else { return nil }
            return title
        }
        XCTAssertEqual(titles, ["Pin Session", "Rename Session", "End Session…"])

        XCTAssertTrue(
            WarrenDesktopWorkspaceSessionRow.contextMenuActions(
                isPinned: false,
                onTogglePin: nil,
                onRename: nil,
                onEnd: nil
            ).isEmpty,
            "A background Host's leaf stays navigable but offers no mutations"
        )

        let pinned = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: true,
            onTogglePin: {},
            onRename: nil,
            onEnd: nil
        )
        guard case .button(let pinTitle, _, _) = pinned.first else {
            return XCTFail("Expected a pin action")
        }
        XCTAssertEqual(pinTitle, "Unpin Session")

        // With activity to retire, the leaf offers what the Tab offers, in
        // the Tab's order.
        let withActivity = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: false,
            onTogglePin: {},
            onRename: {},
            onEnd: {},
            hasActivity: true,
            onDismissActivity: {}
        ).compactMap { action -> String? in
            guard case .button(let title, _, _) = action else { return nil }
            return title
        }
        XCTAssertEqual(
            withActivity,
            ["Pin Session", "Dismiss Activity", "Rename Session", "End Session…"]
        )
    }

    /// A single pane gives the bar nothing to switch between, and its chip
    /// repeats a title the pane header carries and the sidebar leaf highlights.
    /// Chips are earned by having a second pane to choose.
    func testPaneBarShowsItsTrackOnlyWhenThereIsAPaneToChoose() {
        XCTAssertFalse(
            WarrenDesktopPaneBar.showsTrack(entryCount: 1, mode: .rich)
        )
        XCTAssertTrue(
            WarrenDesktopPaneBar.showsTrack(entryCount: 2, mode: .rich)
        )
        // The editor no longer earns the track a stop. It is a region beside the
        // whole track, so a lone pane is still a lone pane while it is open.
        XCTAssertFalse(
            WarrenDesktopPaneBar.showsTrack(entryCount: 0, mode: .rich)
        )
        // Compact mode's tree does not list Sessions, so one entry is still the
        // only way back to it.
        XCTAssertTrue(
            WarrenDesktopPaneBar.showsTrack(entryCount: 1, mode: .compact)
        )
    }

    /// The identity slot and the pane track occupy the same row, so exactly one
    /// of them is drawn. Rich mode with one pane is the case that motivated it:
    /// the row is free, and the 28pt pane header below the presets was spending
    /// a third band to say the same thing.
    @MainActor
    func testTopChromeShowsPaneIdentityExactlyWhenThereIsNoTrack() throws {
        let identity = WarrenDesktopSoloPaneIdentity.Model(
            tabID: "tab-1",
            title: "Implement API",
            fullTitle: "Implement API · codex · feature",
            providerPresetID: "codex",
            mark: .working,
            canClose: true
        )
        let recorder = WarrenSemanticRecorder()
        let bar = makeTabBar(tabs: [ClientTab(
            id: "tab-1",
            title: "Implement API",
            sessionID: TerminalSessionID(),
            kind: .codex
        )], selectedTabID: "tab-1", soloPane: identity)
            .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: bar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let nodes = recorder.snapshot().nodes
        XCTAssertTrue(
            nodes.contains { $0.id == "pane.solo" && $0.label.contains("Implement API") }
        )
        XCTAssertFalse(
            nodes.contains { $0.id.hasPrefix("tab.tab-1") },
            "The identity replaces the chip rather than sitting beside it"
        )
        // Closing is still offered, since the bar's own x went away with the
        // chip and the pane header is gone in this state.
        XCTAssertTrue(nodes.contains { $0.id == "pane.solo.close" })
    }

    /// Every combination of the two tree controls has to leave a Session
    /// reachable. The failure that motivated this was silent: compact stops
    /// listing leaves, and the bar had already stopped listing Sessions, so a
    /// workspace's second Session was in neither surface.
    func testEveryTreeStateLeavesSessionsReachable() {
        let sessionTabs = (1...3).map {
            ClientTab(id: "tab-\($0)", title: "Tab \($0)", kind: .shell)
        }
        let onePane = SplitLayoutTree.leaf(SplitPaneItem(id: "pane-1", tabID: "tab-1"))

        for mode in [WarrenDesktopWorkspaceDisplayMode.rich, .compact] {
            let barEntries = WarrenDesktopPaneBar.tabs(
                visibleIn: onePane,
                from: sessionTabs,
                selected: sessionTabs[0],
                mode: mode
            )
            let reachable = mode.sidebarListsSessions
                ? Set(sessionTabs.map(\.id))
                : Set(barEntries.map(\.id))
            XCTAssertEqual(
                reachable,
                Set(sessionTabs.map(\.id)),
                "\(mode.rawValue) left a Session in neither the tree nor the bar"
            )
            XCTAssertTrue(
                WarrenDesktopPaneBar.showsTrack(
                    entryCount: barEntries.count,
                    mode: mode
                ) || mode.sidebarListsSessions,
                "\(mode.rawValue) hid the bar that owns its Session list"
            )
        }
    }

    /// Turning the Sessions on while their projects are closed looks like the
    /// control did nothing, so it opens the projects that gained rows — and only
    /// those, since opening the rest would add empty depth.
    func testTurningOnSessionsOpensOnlyTheProjectsThatGainRows() {
        let host = WarrenDomain.Host(name: "Host")
        let withSessions = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let idle = Project(hostID: host.id, name: "Docs", rootPath: "/tmp/docs")
        let liveWorkspace = Workspace(projectID: withSessions.id, name: "feature", path: "/tmp/a")
        let idleWorkspace = Workspace(projectID: idle.id, name: "main", path: "/tmp/b")
        let groups = [
            WarrenDesktopProjectGroup(project: withSessions, workspaces: [liveWorkspace]),
            WarrenDesktopProjectGroup(project: idle, workspaces: [idleWorkspace]),
        ]

        XCTAssertEqual(
            WarrenDesktopSidebarRows.projectIDsToReveal(
                filteringToActiveOnly: false,
                in: groups,
                activeWorkspaceIDs: [liveWorkspace.id]
            ),
            [withSessions.id]
        )

        // The filter has already dropped everything it hides, so whatever
        // survives is worth opening.
        XCTAssertEqual(
            WarrenDesktopSidebarRows.projectIDsToReveal(
                filteringToActiveOnly: true,
                in: groups,
                activeWorkspaceIDs: [liveWorkspace.id]
            ),
            [withSessions.id, idle.id]
        )

        XCTAssertTrue(
            WarrenDesktopSidebarRows.projectIDsToReveal(
                filteringToActiveOnly: false,
                in: groups,
                activeWorkspaceIDs: []
            ).isEmpty,
            "With no live Session there is nothing to reveal"
        )
    }

    /// A pane bar entry only ever takes panes off screen. Offering to end a
    /// Session here would contradict "walk out and it keeps running", and would
    /// end it from the one control the user reaches for to tidy the layout.
    func testPaneBarEntryClosesPanesWithoutEndingTheSession() {
        var closedPanes = 0
        var endedSessions = 0
        let titles = WarrenDesktopTabItem.contextMenuActions(
            sessionID: TerminalSessionID(),
            isPinned: false,
            hasActivity: false,
            workspaceMoveTargets: [],
            onMoveSession: { _, _ in endedSessions += 1 },
            onTogglePin: {},
            onDismissActivity: {},
            onRename: {},
            onClose: { closedPanes += 1 },
            onCloseOthers: { closedPanes += 1 },
            onCloseAll: { closedPanes += 1 }
        ).compactMap { action -> String? in
            guard case .button(let title, _, let run) = action else { return nil }
            run()
            return title
        }

        XCTAssertEqual(
            titles,
            ["Pin Session", "Rename Session", "Close Pane", "Close Other Panes", "Close All Panes"]
        )
        XCTAssertEqual(closedPanes, 3)
        XCTAssertEqual(endedSessions, 0)
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("End Session") })
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("Close Tab") })
    }

    /// A Task-linked workspace appears twice in the tree, but only one copy owns
    /// navigation: the Task copy. Leaves follow navigability, so the Projects
    /// copy lists none and the Task copy lists them.
    ///
    /// With the Task collapsed the Task copy is not mounted at all, so those
    /// Sessions leave the tree the same way collapsing Projects hides the ones
    /// that copy owns.
    @MainActor
    func testRichSessionRowsFollowTheNavigableWorkspaceCopy() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "delivery-api",
            path: "/tmp/api-delivery"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )

        for isTaskFolded in [true, false] {
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: projection.taskGroups,
                groups: projection.groups,
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState(
                    collapsedTaskIDs: isTaskFolded ? [task.id] : []
                )),
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
            .frame(width: 420, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            let sessionIDs = recorder.snapshot().nodes
                .filter { $0.id.hasPrefix("workspace-session.") }
                .map(\.id)
            let expected: [String] = isTaskFolded
                ? []
                : [
                    "workspace-session.task-list.\(workspace.id.description)"
                        + ".\(session.id.description)",
                ]
            XCTAssertEqual(
                sessionIDs,
                expected,
                "Task expansion \(isTaskFolded ? "collapsed" : "expanded")"
            )

            // The Task lists the Workspace; Projects does not draw it again.
            let snapshot = recorder.snapshot()
            XCTAssertNil(
                snapshot.node(id: "workspace.project-list.\(workspace.id.description)"),
                "The Projects section does not repeat a Task's Workspace"
            )
            if !isTaskFolded {
                XCTAssertTrue(
                    snapshot.node(id: "workspace.task-list.\(workspace.id.description)")?
                        .isEnabled ?? false,
                    "The Task copy owns navigation and therefore the leaves"
                )
            }
        }
    }

    @MainActor
    func testCompactWorkspaceRowsDoNotRenderAgentChildren() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(projectID: project.id, name: "feature", path: "/tmp/api-feature")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )
        let recorder = WarrenSemanticRecorder()
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .compact,
            tree: .constant(WarrenDesktopSidebarTreeState()),
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
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(recorder.snapshot().nodes.first {
            $0.id.hasPrefix("workspace-session.")
        })
    }



    func testWorkspaceActivityCountsOnlyVisibleWorkingTabs() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let visibleWorkingIDs = [TerminalSessionID(), TerminalSessionID()]
        let hiddenWorkingID = TerminalSessionID()
        let waitingID = TerminalSessionID()
        let sessions = [
            WarrenDesktopSession(
                id: visibleWorkingIDs[0],
                workspaceID: workspaceID,
                title: "Working One",
                kind: .codex,
                activity: .working
            ),
            WarrenDesktopSession(
                id: visibleWorkingIDs[1],
                workspaceID: workspaceID,
                title: "Working Two",
                kind: .claude,
                activity: .working
            ),
            WarrenDesktopSession(
                id: hiddenWorkingID,
                workspaceID: workspaceID,
                title: "Hidden Working",
                kind: .codex,
                activity: .working
            ),
            WarrenDesktopSession(
                id: waitingID,
                workspaceID: workspaceID,
                title: "Waiting",
                kind: .claude,
                activity: .blocked
            ),
        ]
        let tabs = [
            ClientTab(
                id: "working-one",
                title: "Working One",
                sessionID: visibleWorkingIDs[0],
                kind: .codex
            ),
            ClientTab(
                id: "working-two",
                title: "Working Two",
                sessionID: visibleWorkingIDs[1],
                kind: .claude
            ),
            ClientTab(
                id: "waiting",
                title: "Waiting",
                sessionID: waitingID,
                kind: .claude
            ),
        ]
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: sessions,
            tabs: tabs
        )

        let summary = projection.workspaceActivitySummaries[workspaceID]
        XCTAssertEqual(summary?.activity, .blocked)
        XCTAssertEqual(summary?.activeTabCount, 2)
    }

    func testProjectionChangesOneSessionActivityWithoutChangingRelationships() {
        let projection = WarrenDesktopFixture.preview.projection
        let session = projection.sessions[0]
        let updated = projection.withSessionActivity(.working, for: session.id)

        XCTAssertEqual(updated.session(id: session.id)?.activity, .working)
        XCTAssertEqual(updated.groups, projection.groups)
        XCTAssertEqual(updated.tabs, projection.tabs)
        XCTAssertEqual(updated.sessionWorkspaceIDs, projection.sessionWorkspaceIDs)
        XCTAssertEqual(updated.tabWorkspaceIDs, projection.tabWorkspaceIDs)
        XCTAssertEqual(
            updated.tabs(in: session.workspaceID),
            projection.tabs(in: session.workspaceID)
        )
        XCTAssertEqual(updated.activity(in: session.workspaceID), .working)
    }

    func testSelectingTabSynchronizesSidebarWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let reviewWorkspaceID = fixture.groups[1].workspaces[0].id
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectTab("tab-review"),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(reviewWorkspaceID))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
    }

    func testClearingTheSelectedTabStaysInsideWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: .workspace(fixture.groups[0].workspaces[0].id), selectedTabID: "tab-main"),
            action: .clearSelectedTab,
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(fixture.groups[0].workspaces[0].id))
        XCTAssertNil(selected.selectedTabID)
    }

    func testSelectingProjectResolvesItsDefaultWorkspaceAndLocalTab() {
        let fixture = WarrenDesktopFixture.preview
        let project = fixture.groups[1].project
        let workspace = fixture.groups[1].workspaces[0]

        let selected = WarrenDesktopNavigationReducer.reduce(
            .init(selection: nil, selectedTabID: nil),
            action: .selectProject(project.id),
            in: fixture.projection
        )

        XCTAssertEqual(selected.selection, .workspace(workspace.id))
        XCTAssertEqual(selected.selectedTabID, "tab-review")
        XCTAssertEqual(fixture.projection.tabs(in: workspace.id).map(\.id), ["tab-review"])
    }

    func testBackgroundTabPublicationDoesNotStealExplicitEmptyWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceWithoutTabID = fixture.groups[0].workspaces[1].id
        let state = WarrenDesktopNavigationState(
            selection: .workspace(workspaceWithoutTabID),
            selectedTabID: nil
        )

        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reconcile(state, with: fixture.projection),
            state
        )
    }

    func testNavigationPersistenceRoundTripsWorkspaceAndTab() throws {
        let suiteName = "WarrenDesktopTests.navigation.workspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = WarrenDesktopFixture.preview
        let state = WarrenDesktopNavigationState(
            selection: .workspace(fixture.groups[0].workspaces[0].id),
            selectedTabID: "tab-main",
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: [
                    fixture.groups[0].project.id.description:
                        fixture.groups[0].workspaces[0].id.description,
                ],
                tabByWorkspaceID: [
                    fixture.groups[0].workspaces[0].id.description: "tab-main",
                ]
            )
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)
        XCTAssertEqual(WarrenDesktopNavigationPersistence.restore(from: defaults), state)
    }

    func testNavigationPersistenceRoundTripsProject() throws {
        let suiteName = "WarrenDesktopTests.navigation.project.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = WarrenDesktopFixture.preview
        let state = WarrenDesktopNavigationState(
            selection: .project(fixture.groups[0].project.id),
            selectedTabID: nil
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)
        XCTAssertEqual(WarrenDesktopNavigationPersistence.restore(from: defaults), state)
    }

    func testNavigationPersistenceClearsWhenEmpty() throws {
        let suiteName = "WarrenDesktopTests.navigation.empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WarrenDesktopNavigationPersistence.save(
            WarrenDesktopNavigationState(selection: nil, selectedTabID: nil),
            to: defaults
        )

        XCTAssertNil(WarrenDesktopNavigationPersistence.restore(from: defaults))
    }

    func testNavigationPersistenceRetainsMemoryWithoutForegroundSelection() throws {
        let suiteName = "WarrenDesktopTests.navigation.memory-only.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = WarrenDesktopNavigationState(
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: ["project": "workspace"],
                tabByWorkspaceID: ["workspace": "tab"]
            )
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(from: defaults),
            state
        )
    }

    func testNavigationPersistenceIsolatedPerEndpointScope() throws {
        let suiteName = "WarrenDesktopTests.navigation.scoped.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sharedProjectID = ProjectID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let sharedWorkspaceID = WorkspaceID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        let localState = WarrenDesktopNavigationState(
            selection: .project(sharedProjectID),
            selectedTabID: "local-tab",
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: [sharedProjectID.description: sharedWorkspaceID.description]
            )
        )
        let remoteState = WarrenDesktopNavigationState(
            selection: .workspace(sharedWorkspaceID),
            selectedTabID: "remote-tab"
        )

        WarrenDesktopNavigationPersistence.save(localState, scope: "local", to: defaults)
        WarrenDesktopNavigationPersistence.save(remoteState, scope: "prod", to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "local", from: defaults),
            localState
        )
        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "prod", from: defaults),
            remoteState
        )
        XCTAssertNotEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "local", from: defaults),
            remoteState
        )
    }

    func testTabOrdersAreIsolatedPerEndpointScope() throws {
        let suiteName = "WarrenDesktopTests.navigation.scoped-tabs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceKey = "00000000-0000-4000-8000-000000000003"
        let localOrders = WarrenDesktopTabOrders(
            workspace: [workspaceKey: ["local-a", "local-b"]]
        )
        let remoteOrders = WarrenDesktopTabOrders(
            workspace: [workspaceKey: ["remote-a", "remote-b"]]
        )

        WarrenDesktopNavigationPersistence.saveTabOrders(localOrders, scope: "local", to: defaults)
        WarrenDesktopNavigationPersistence.saveTabOrders(remoteOrders, scope: "prod", to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restoreTabOrders(scope: "local", from: defaults),
            localOrders
        )
        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restoreTabOrders(scope: "prod", from: defaults),
            remoteOrders
        )
    }

    func testLegacyNavigationPersistenceMigratesToFirstRequestedScope() throws {
        let suiteName = "WarrenDesktopTests.navigation.legacy-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = ProjectID()
        let state = WarrenDesktopNavigationState(
            selection: .project(projectID),
            selectedTabID: "legacy-tab",
            memory: WarrenDesktopNavigationMemory(
                workspaceByProjectID: [projectID.description: "workspace"]
            )
        )

        WarrenDesktopNavigationPersistence.save(state, to: defaults)

        XCTAssertEqual(
            WarrenDesktopNavigationPersistence.restore(scope: "prod", from: defaults),
            state
        )
        XCTAssertNil(
            WarrenDesktopNavigationPersistence.restore(scope: "local", from: defaults)
        )
    }

    func testHostTintAllocatorPreservesVisibleAssignmentsWhenAliasIsAdded() {
        let allocator = WarrenDesktopHostTintAllocator()
        let paletteCount = WarrenColorTokens.dark.hostSectionTints.count

        allocator.update(endpointIDs: ["dev", "prod"], paletteCount: paletteCount)
        let initial = allocator.assignments
        allocator.update(
            endpointIDs: ["dev", "prod", "staging"],
            paletteCount: paletteCount
        )

        XCTAssertEqual(allocator.assignments["dev"], initial["dev"])
        XCTAssertEqual(allocator.assignments["prod"], initial["prod"])
        XCTAssertNotNil(allocator.assignments["staging"])
    }

    func testCollapsedHostSummaryCountsProjectsAndKeepsTheMostActionableMark() {
        let host = Host(name: "vps-01")
        let project = Project(hostID: host.id, name: "api", rootPath: "/tmp/api")
        let other = Project(hostID: host.id, name: "web", rootPath: "/tmp/web")
        let working = Workspace(projectID: project.id, name: "main", path: "/tmp/api")
        let waiting = Workspace(projectID: other.id, name: "main", path: "/tmp/web")
        let exited = Workspace(projectID: other.id, name: "old", path: "/tmp/web-old")
        let projection = WarrenDesktopSidebarHostProjection(
            endpointID: "prod",
            endpointLabel: "Production",
            host: host,
            connectionState: .attached,
            projectGroups: [
                .init(project: project, workspaces: [working]),
                .init(project: other, workspaces: [waiting, exited]),
            ],
            workspaceActivitySummaries: [
                working.id: .init(mark: .working, activeTabCount: 1),
                waiting.id: .init(mark: .approvalNeeded),
                exited.id: .init(mark: .exited),
            ]
        )

        let summary = WarrenDesktopSidebarHostSummary(projection)
        XCTAssertEqual(summary.countLabel, "2 projects")
        XCTAssertEqual(summary.mark, .approvalNeeded)

        let quiet = WarrenDesktopSidebarHostSummary(WarrenDesktopSidebarHostProjection(
            endpointID: "prod",
            endpointLabel: "Production",
            host: host,
            connectionState: .attached,
            projectGroups: [.init(project: other, workspaces: [exited])],
            workspaceActivitySummaries: [exited.id: .init(mark: .exited)]
        ))
        XCTAssertEqual(quiet.countLabel, "1 project")
        XCTAssertNil(quiet.mark)
    }

    func testSidebarTreePersistenceIsPerScopeAndRoundTrips() throws {
        let suiteName = "WarrenDesktopTests.sidebarTree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = WarrenDesktopSidebarTreeState(
            collapsedTaskIDs: [TaskID(), TaskID()],
            collapsedProjectIDs: [ProjectID(), ProjectID()],
            collapsedWorkspaceIDs: [WorkspaceID()],
            expandedSubagentSessionIDs: [TerminalSessionID(), TerminalSessionID()],
            expandedSubagentDoneSessionIDs: [TerminalSessionID()],
            tasksCollapsed: true,
            projectsCollapsed: true,
            showsActiveOnly: true,
            expandedIdleWorkspaceProjectIDs: [ProjectID()],
            inactiveProjectsExpanded: true
        )

        WarrenDesktopSidebarTreePersistence.save(state, scope: "local", defaults: defaults)

        XCTAssertEqual(
            WarrenDesktopSidebarTreePersistence.restore(scope: "local", defaults: defaults),
            state
        )
        XCTAssertEqual(
            WarrenDesktopSidebarTreePersistence.restore(scope: "server", defaults: defaults),
            WarrenDesktopSidebarTreeState()
        )
    }

    func testProjectionActiveWorkspaceIDs() {
        let host = WarrenDomain.Host(name: "TestHost")
        let project = Project(hostID: host.id, name: "Repo", rootPath: "/repo")
        let activeWorkspace = Workspace(projectID: project.id, name: "active", path: "/repo/active")
        let idleWorkspace = Workspace(projectID: project.id, name: "idle", path: "/repo/idle")
        let exitedWorkspace = Workspace(projectID: project.id, name: "exited", path: "/repo/exited")

        let activeSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: activeWorkspace.id,
            title: "active-shell",
            state: .attached
        )
        let exitedSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: exitedWorkspace.id,
            title: "exited-shell",
            state: .exited
        )

        let projection = WarrenDesktopProjection(
            host: host,
            groups: [
                WarrenDesktopProjectGroup(
                    project: project,
                    workspaces: [activeWorkspace, idleWorkspace, exitedWorkspace]
                ),
            ],
            sessions: [activeSession, exitedSession]
        )

        XCTAssertEqual(projection.activeWorkspaceIDs, Set([activeWorkspace.id]))
    }

    @MainActor
    func testSidebarRowsFiltersInactiveWorkspacesWhenShowsActiveOnlyIsTrue() {
        let host = WarrenDomain.Host(name: "TestHost")
        let project = Project(hostID: host.id, name: "Repo", rootPath: "/repo")
        let activeWorkspace = Workspace(projectID: project.id, name: "active", path: "/repo/active")
        let idleWorkspace = Workspace(projectID: project.id, name: "idle", path: "/repo/idle")

        let groups = [WarrenDesktopProjectGroup(project: project, workspaces: [activeWorkspace, idleWorkspace])]
        let recorder = WarrenSemanticRecorder()

        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: groups,
            workspaceActivitySummaries: [:],
            activeWorkspaceIDs: [activeWorkspace.id],
            tree: .constant(WarrenDesktopSidebarTreeState(
                showsActiveOnly: true
            )),
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
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        XCTAssertNotNil(snapshot.node(id: "workspace.project-list.\(activeWorkspace.id.description)"))
        XCTAssertNil(snapshot.node(id: "workspace.project-list.\(idleWorkspace.id.description)"))
    }

    func testSidebarRowsKeepsTaskGroupsWhenShowsActiveOnlyIsTrue() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "Repo", rootPath: "/repo")
        let idleWorkspace = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "idle",
            path: "/repo/idle"
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [project],
            workspaces: [idleWorkspace]
        )
        let recorder = WarrenSemanticRecorder()

        let rows = WarrenDesktopSidebarRows(
            taskGroups: projection.taskGroups,
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeWorkspaceIDs: [],
            tree: .constant(WarrenDesktopSidebarTreeState(
                showsActiveOnly: true
            )),
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
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        let taskNode = snapshot.node(id: "task.\(task.id.description)")
        XCTAssertEqual(taskNode?.label, "Task Delivery")
        XCTAssertEqual(taskNode?.value, "0 workspaces · Expanded")
        XCTAssertNil(snapshot.node(id: "workspace.task-list.\(idleWorkspace.id.description)"))
    }

    func testTaskRowExposesProjectStyleSecondaryActions() {
        let host = WarrenDomain.Host(name: "Task Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let recorder = WarrenSemanticRecorder()
        let row = WarrenDesktopTaskRow(
            task: task,
            workspaceCount: 2,
            availableProjectGroups: [],
            isExpanded: false,
            isInteractionDisabled: false,
            onToggleExpansion: {},
            onAttachWorkspace: { _ in },
            onCreateWorkspace: { _ in },
            onRename: {},
            onTogglePin: {},
            onDelete: {}
        )
        .frame(width: 420, height: WarrenLayoutMetrics.sidebarProjectRowHeight)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: row)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 420,
            height: WarrenLayoutMetrics.sidebarProjectRowHeight
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let snapshot = recorder.snapshot()
        XCTAssertEqual(
            snapshot.node(id: "task.\(task.id.description).toggle")?.label,
            "Expand task Delivery"
        )
        XCTAssertEqual(
            snapshot.node(id: "task.\(task.id.description).new-workspace")?.label,
            "Add workspace to task Delivery"
        )
    }

    func testNavigationReducerIgnoresSidebarMoves() {
        let projection = WarrenDesktopFixture.preview.projection
        let initial = WarrenDesktopNavigationReducer.initial(for: projection)
        let projectID = projection.groups[0].project.id

        XCTAssertEqual(
            WarrenDesktopNavigationReducer.reduce(
                initial,
                action: .moveProject(projectID, before: nil),
                in: projection
            ),
            initial
        )
        if let workspace = projection.groups[0].workspaces.first {
            XCTAssertEqual(
                WarrenDesktopNavigationReducer.reduce(
                    initial,
                    action: .moveWorkspace(workspace.id, before: nil),
                    in: projection
                ),
                initial
            )
        }
        if let sessionID = projection.sessions.first?.id {
            XCTAssertEqual(
                WarrenDesktopNavigationReducer.reduce(
                    initial,
                    action: .dismissActivity(sessionID, .working),
                    in: projection
                ),
                initial
            )
            if let workspaceID = projection.groups.first?.workspaces.first?.id {
                XCTAssertEqual(
                    WarrenDesktopNavigationReducer.reduce(
                        initial,
                        action: .moveSession(sessionID, to: .workspace(workspaceID)),
                        in: projection
                    ),
                    initial
                )
            }
        }
    }
}

@MainActor
private final class WarrenDragProbeWindow: NSWindow {
    var didRequestDrag = false
    var didToggleFullScreen = false

    override func performDrag(with event: NSEvent) {
        didRequestDrag = true
    }

    override func toggleFullScreen(_ sender: Any?) {
        didToggleFullScreen = true
    }
}

@MainActor
private final class PausingTaskCreationFake {
    private let callExpectations: [XCTestExpectation]
    private var continuations: [CheckedContinuation<TaskID, Error>] = []
    private(set) var requests: [WarrenDesktopTaskCreationRequest] = []

    var callCount: Int { requests.count }

    init(callExpectations: [XCTestExpectation]) {
        self.callExpectations = callExpectations
    }

    func create(_ request: WarrenDesktopTaskCreationRequest) async throws -> TaskID {
        requests.append(request)
        callExpectations[requests.count - 1].fulfill()
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeed(_ taskID: TaskID) {
        continuations.removeFirst().resume(returning: taskID)
    }

    func fail(_ error: Error) {
        continuations.removeFirst().resume(throwing: error)
    }
}
