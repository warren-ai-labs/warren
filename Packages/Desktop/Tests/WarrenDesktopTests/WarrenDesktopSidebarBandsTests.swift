import XCTest
import SwiftUI
import AppKit
@testable import WarrenDesktop
import WarrenDomain
import WarrenObservation

/// The Projects section's bands and a project's idle row, as the adopted
/// sidebar design specifies them.
final class WarrenDesktopSidebarBandsTests: XCTestCase {
    private let hostID = HostID()

    private func project(_ name: String, pinned: Bool = false, activeSince: Date? = nil) -> Project {
        Project(hostID: hostID, name: name, rootPath: "/tmp/\(name)", pinned: pinned, activeSince: activeSince)
    }

    func testBandsPutPinnedFirstThenActiveByWhenTheyBecameActiveThenTheRest() {
        let now = Date()
        let pinnedIdle = project("pinned-idle", pinned: true)
        let late = project("late", activeSince: now)
        let early = project("early", activeSince: now.addingTimeInterval(-60))
        let unstamped = project("unstamped")
        let stale = project("stale")
        let recent = project("recent")
        let last: [ProjectID: Date] = [
            stale.id: now.addingTimeInterval(-7 * 86_400),
            recent.id: now.addingTimeInterval(-86_400),
        ]
        let active: Set<ProjectID> = [late.id, early.id, unstamped.id]

        let bands = WarrenDesktopProjectBands(
            [late, stale, pinnedIdle, unstamped, recent, early],
            project: { $0 },
            isActive: { active.contains($0.id) },
            lastActiveAt: { last[$0.id] }
        )

        // A pinned project stays pinned whether or not anything runs in it.
        XCTAssertEqual(bands.pinned.map(\.name), ["pinned-idle"])
        // A project that became active later sits lower, so a status change
        // never reorders the band; a Host without stamps keeps its order last.
        XCTAssertEqual(bands.active.map(\.name), ["early", "late", "unstamped"])
        XCTAssertEqual(bands.inactive.map(\.name), ["recent", "stale"])
        XCTAssertEqual(bands.listed.map(\.name), ["pinned-idle", "early", "late", "unstamped"])
    }

    func testHoldKeepsAProjectThatClosedItsLastSessionInPlaceForAMinute() {
        let now = Date()
        let early = project("early", activeSince: now.addingTimeInterval(-120))
        let closed = project("closed", activeSince: now.addingTimeInterval(-60))
        let late = project("late", activeSince: now.addingTimeInterval(-30))
        let all = Set([early, closed, late].map(\.id.description))
        var hold = WarrenDesktopProjectHold()
        let before = WarrenDesktopProjectHold.Snapshot(
            active: [
                early.id.description: early.activeSince,
                closed.id.description: closed.activeSince,
                late.id.description: late.activeSince,
            ],
            existing: all
        )
        // The Host clears the stamp the moment the last Session goes away.
        let after = WarrenDesktopProjectHold.Snapshot(
            active: [
                early.id.description: early.activeSince,
                late.id.description: late.activeSince,
            ],
            existing: all
        )
        hold.update(from: before, to: after, now: now)
        XCTAssertTrue(hold.contains(closed.id.description))
        XCTAssertEqual(hold.nextExpiry, now.addingTimeInterval(WarrenDesktopProjectHold.interval))

        let cleared = Project(id: closed.id, hostID: hostID, name: "closed", rootPath: "/tmp/closed")
        let bands = WarrenDesktopProjectBands(
            [early, cleared, late],
            project: { $0 },
            isActive: { $0.id != cleared.id || hold.contains($0.id.description) },
            lastActiveAt: { _ in nil },
            activeSince: { hold.activeSince($0.id.description) ?? $0.activeSince }
        )
        // Its row stays between the same neighbours.
        XCTAssertEqual(bands.active.map(\.name), ["early", "closed", "late"])

        XCTAssertFalse(hold.expire(now: now.addingTimeInterval(59), keeping: []))
        XCTAssertTrue(hold.expire(now: now.addingTimeInterval(60), keeping: []))
        XCTAssertFalse(hold.contains(closed.id.description))
    }

    func testHoldEndsWhenTheProjectIsActiveAgainOrGone() {
        let now = Date()
        var hold = WarrenDesktopProjectHold()
        hold.lift("a", now: now)
        hold.lift("b", now: now)
        hold.update(
            from: .init(active: [:], existing: ["a", "b"]),
            to: .init(active: ["a": now], existing: ["a"]),
            now: now
        )
        XCTAssertFalse(hold.contains("a"))
        XCTAssertFalse(hold.contains("b"))
        XCTAssertNil(hold.nextExpiry)
    }

    func testLiftPutsAProjectBehindTheActiveBandAndSparesItWhileSelected() {
        let now = Date()
        let busy = project("busy", activeSince: now.addingTimeInterval(-600))
        let picked = project("picked")
        let other = project("other")
        var hold = WarrenDesktopProjectHold()
        hold.lift(picked.id.description, now: now)
        // Lifting again does not move it.
        hold.lift(picked.id.description, now: now.addingTimeInterval(30))

        let bands = WarrenDesktopProjectBands(
            [picked, other, busy],
            project: { $0 },
            isActive: { $0.id == busy.id || hold.contains($0.id.description) },
            lastActiveAt: { _ in nil },
            activeSince: { hold.activeSince($0.id.description) ?? $0.activeSince }
        )
        XCTAssertEqual(bands.active.map(\.name), ["busy", "picked"])
        XCTAssertEqual(bands.inactive.map(\.name), ["other"])

        let late = now.addingTimeInterval(120)
        XCTAssertFalse(hold.expire(now: late, keeping: [picked.id.description]))
        XCTAssertTrue(hold.expire(now: late, keeping: []))
    }

    @MainActor
    func testSelectingAnInactiveProjectLiftsItsFullRowIntoTheActiveBand() throws {
        let busy = project("warren", activeSince: Date())
        let busyMain = Workspace(projectID: busy.id, name: "main", path: "/tmp/warren", branch: "main")
        let sumi = project("sumi")
        let sumiMain = Workspace(projectID: sumi.id, name: "main", path: "/tmp/sumi", branch: "main")
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: busyMain.id,
            title: "Pull pr6",
            kind: .claude,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: Host(id: hostID, name: "studio"),
            projects: [busy, sumi],
            workspaces: [busyMain, sumiMain],
            sessions: [session]
        )

        struct Harness: View {
            let projection: WarrenDesktopProjection
            @State var selection: WarrenDesktopSidebarSelection?

            var body: some View {
                WarrenDesktopSidebarRows(
                    taskGroups: [],
                    groups: projection.groups,
                    workspaceActivitySummaries: projection.workspaceActivitySummaries,
                    activeWorkspaceIDs: projection.activeWorkspaceIDs,
                    activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                    workspaceDisplayMode: .rich,
                    tree: .constant(WarrenDesktopSidebarTreeState(inactiveProjectsExpanded: true)),
                    selection: selection,
                    deletingProjectIDs: [],
                    deletingWorkspaceIDs: [],
                    endpointCapabilities: .local,
                    isInteractionDisabled: false,
                    onAddProject: {},
                    onRequestTaskCreate: {},
                    onFocusTask: { _ in },
                    onAction: { action in
                        if case .selectProject(let id) = action { selection = .project(id) }
                    },
                    onRequestRename: { _ in },
                    onRequestDeletion: { _ in }
                )
            }
        }

        let recorder = WarrenSemanticRecorder()
        let root = Harness(projection: projection)
            .frame(width: 300, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
        func settle() {
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            hostingView.layoutSubtreeIfNeeded()
        }
        func nodes() -> [String: WarrenSemanticNode] {
            Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        settle()
        let rowID = "project.\(sumi.id.description)"
        XCTAssertEqual(nodes()["projects-inactive"]?.label, "1 inactive project")
        // The folded list's row has no actions of its own.
        XCTAssertNil(nodes()["\(rowID).new-workspace"])

        try recorder.perform(.press, on: rowID)
        settle()
        let lifted = nodes()
        // The project left the folded list for a full row with its actions.
        XCTAssertNil(lifted["projects-inactive"])
        XCTAssertNotNil(lifted["\(rowID).new-workspace"])
        XCTAssertEqual(lifted[rowID]?.isSelected, true)
    }

    func testSplitKeepsLiveOrderAndListsIdleByRecency() {
        let projectID = ProjectID()
        let now = Date()
        func workspace(_ name: String, last: TimeInterval? = nil) -> Workspace {
            Workspace(
                projectID: projectID,
                name: name,
                path: "/tmp/\(name)",
                lastActivityAt: last.map { now.addingTimeInterval(-$0) }
            )
        }
        let main = workspace("main")
        let old = workspace("old", last: 9 * 86_400)
        let feature = workspace("feature")
        let fresh = workspace("fresh", last: 2 * 86_400)
        let live: Set<String> = ["main", "feature"]

        let split = WarrenDesktopWorkspaceSplit([main, old, feature, fresh]) { live.contains($0.name) }

        XCTAssertEqual(split.live.map(\.name), ["main", "feature"])
        XCTAssertEqual(split.idle.map(\.name), ["fresh", "old"])
        XCTAssertTrue(split.showsIdleRow)

        // A project with no Session and one worktree is only its own row.
        let lone = WarrenDesktopWorkspaceSplit([main]) { _ in false }
        XCTAssertFalse(lone.showsIdleRow)
        XCTAssertFalse(lone.hasRows)
        // Several idle worktrees still fold into the row, so each stays
        // reachable.
        XCTAssertTrue(WarrenDesktopWorkspaceSplit([main, old]) { _ in false }.showsIdleRow)
    }

    func testSplitPutsTheDefaultBranchFirstInEachList() {
        let projectID = ProjectID()
        let now = Date()
        func workspace(_ branch: String, last: TimeInterval) -> Workspace {
            Workspace(
                projectID: projectID,
                name: branch,
                path: "/tmp/\(branch)",
                branch: branch,
                lastActivityAt: now.addingTimeInterval(-last)
            )
        }
        let feature = workspace("feat/a", last: 60)
        let main = workspace("main", last: 600)
        let fix = workspace("fix/b", last: 30)
        let master = workspace("master", last: 9_000)
        let recent = workspace("feat/recent", last: 10)
        let live: Set<WorkspaceID> = [feature.id, main.id, fix.id]

        let split = WarrenDesktopWorkspaceSplit(
            [feature, main, fix, master, recent],
            isLive: { live.contains($0.id) }
        )

        XCTAssertEqual(split.live.map(\.name), ["main", "feat/a", "fix/b"])
        // An older default branch still leads the idle list.
        XCTAssertEqual(split.idle.map(\.name), ["master", "feat/recent"])
    }

    func testBranchNamesDimTheirPrefixAndCutALongLeafInTheMiddle() {
        XCTAssertEqual(WarrenDesktopBranchName.parts("main").prefix, "")
        XCTAssertEqual(WarrenDesktopBranchName.parts("main").leaf, "main")

        let feature = WarrenDesktopBranchName.parts("feat/sidebar-topbar-polish")
        XCTAssertEqual(feature.prefix, "feat/")
        XCTAssertEqual(feature.leaf, "sidebar-topbar-polish")

        let long = WarrenDesktopBranchName.parts("fix/relay-reconnect-after-sleep-when-the-network-changes")
        XCTAssertEqual(long.prefix, "fix/")
        XCTAssertEqual(long.leaf, "relay-reconne…ork-changes")

        // The prefix runs to the last slash.
        XCTAssertEqual(WarrenDesktopBranchName.parts("release/ios/1.2").prefix, "release/ios/")

        // A Task's `project · branch` label is not a branch.
        let task = WarrenDesktopBranchName.parts("warren · ios/widget")
        XCTAssertEqual(task.prefix, "")
        XCTAssertEqual(task.leaf, "warren · ios/widget")

        // The row's last resort cuts the uncut leaf, so a name is never cut twice.
        let whole = WarrenDesktopBranchName.wholeParts("fix/relay-reconnect-after-sleep-when-the-network-changes")
        XCTAssertEqual(whole.prefix, "fix/")
        XCTAssertEqual(whole.leaf, "relay-reconnect-after-sleep-when-the-network-changes")
    }

    func testActivityAgeUsesTheSidebarsSingleForm() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        func age(_ seconds: TimeInterval) -> String {
            WarrenDesktopActivityAge.label(since: now.addingTimeInterval(-seconds), now: now, calendar: calendar)
        }
        XCTAssertEqual(WarrenDesktopActivityAge.label(since: nil, now: now), "")
        XCTAssertEqual(age(10), "now")
        XCTAssertEqual(age(59), "now")
        XCTAssertEqual(age(5 * 60), "5m")
        XCTAssertEqual(age(3 * 3_600), "3h")
        XCTAssertEqual(age(2 * 86_400), "2d")
        XCTAssertEqual(age(8 * 86_400), "1w")
        XCTAssertEqual(age(15 * 86_400), "2w")
        XCTAssertEqual(age(35 * 86_400), "5w", "Five whole weeks is still a week count")
        XCTAssertEqual(age(42 * 86_400), "Sep 4", "Past five weeks the age becomes a date")
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 10, day: 3))!
        XCTAssertEqual(
            WarrenDesktopActivityAge.label(since: lastYear, now: now, calendar: calendar),
            "Oct 3, 2025",
            "A date from another year carries the year"
        )
    }

    func testWorkspaceFallsBackToItsCreationForLastActivity() {
        let created = Date(timeIntervalSince1970: 100)
        let active = Date(timeIntervalSince1970: 200)
        var workspace = Workspace(projectID: ProjectID(), name: "w", path: "/tmp/w", createdAt: created)
        XCTAssertEqual(workspace.lastActiveAt, created)
        workspace.lastActivityAt = active
        XCTAssertEqual(workspace.lastActiveAt, active)
    }

    @MainActor
    func testProjectsSectionFoldsIdleWorktreesAndInactiveProjects() throws {
        let now = Date()
        let busy = project("warren", activeSince: now)
        let main = Workspace(projectID: busy.id, name: "main", path: "/tmp/warren", branch: "main")
        let idleA = Workspace(
            projectID: busy.id,
            name: "feat/monaco-lsp-editor",
            path: "/tmp/warren-a",
            branch: "feat/monaco-lsp-editor",
            lastActivityAt: now.addingTimeInterval(-3 * 86_400)
        )
        let idleB = Workspace(
            projectID: busy.id,
            name: "release/0.12.0",
            path: "/tmp/warren-b",
            branch: "release/0.12.0",
            lastActivityAt: now.addingTimeInterval(-8 * 86_400)
        )
        let quiet = project("quiet", pinned: true)
        let quietMain = Workspace(projectID: quiet.id, name: "main", path: "/tmp/quiet", branch: "main")
        let sumi = project("sumi")
        let sumiMain = Workspace(
            projectID: sumi.id,
            name: "main",
            path: "/tmp/sumi",
            branch: "main",
            lastActivityAt: now.addingTimeInterval(-2 * 86_400)
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: main.id,
            title: "Pull pr6",
            kind: .claude,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: Host(id: hostID, name: "studio"),
            projects: [busy, quiet, sumi],
            workspaces: [main, idleA, idleB, quietMain, sumiMain],
            sessions: [session]
        )

        func render(_ tree: WarrenDesktopSidebarTreeState) -> [String: WarrenSemanticNode] {
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
            .frame(width: 300, height: 700)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let idleRowID = "project-idle-worktrees.\(busy.id.description)"
        let folded = render(WarrenDesktopSidebarTreeState())
        // Both idle rows start folded.
        XCTAssertEqual(folded[idleRowID]?.label, "2 idle worktrees")
        XCTAssertEqual(folded[idleRowID]?.value, "Collapsed")
        XCTAssertNil(folded["workspace.project-list.\(idleA.id.description)"])
        XCTAssertEqual(folded["projects-inactive"]?.label, "1 inactive project")
        XCTAssertNil(folded["project.\(sumi.id.description)"])
        // A pinned project with no Session is its row alone.
        XCTAssertNotNil(folded["project.\(quiet.id.description)"])
        XCTAssertNil(folded["workspace.project-list.\(quietMain.id.description)"])
        XCTAssertNil(folded["project-idle-worktrees.\(quiet.id.description)"])

        let open = render(WarrenDesktopSidebarTreeState(
            expandedIdleWorkspaceProjectIDs: [busy.id],
            inactiveProjectsExpanded: true
        ))
        XCTAssertEqual(
            open["workspace.project-list.\(idleA.id.description)"]?.value,
            "No sessions · last active 3d ago"
        )
        XCTAssertEqual(
            open["workspace.project-list.\(idleB.id.description)"]?.value,
            "No sessions · last active 1w ago"
        )
        XCTAssertEqual(
            open["project.\(sumi.id.description)"]?.value,
            "No open sessions · last active 2d ago"
        )
    }
}
