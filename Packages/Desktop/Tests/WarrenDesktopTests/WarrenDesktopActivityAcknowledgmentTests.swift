import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain

final class WarrenDesktopActivityAcknowledgmentTests: XCTestCase {
    private func session(
        _ id: TerminalSessionID,
        activity: AgentActivityState,
        attention: AgentAttention? = nil
    ) -> WarrenDesktopSession {
        WarrenDesktopSession(
            id: id,
            workspaceID: WorkspaceID(),
            tabID: "tab.\(id.description)",
            title: "Session \(id.shortDescription)",
            kind: .codex,
            agentStatus: AgentStatus(activity: activity, attention: attention)
        )
    }

    /// `ready` is news exactly once. This is the whole point of remembering what
    /// was read: a turn finishing is an event, not a property of a Session.
    func testASeenCompletionStopsDrawing() {
        let id = TerminalSessionID()
        let ready = session(id, activity: .ready)

        XCTAssertEqual(ready.activityMark, .ready)

        var seen = WarrenDesktopActivityAcknowledgments()
        XCTAssertTrue(seen.acknowledge(ready))
        XCTAssertEqual(seen[id], .ready)

        let acknowledged = ready.acknowledgingActivity(seen[id])
        XCTAssertNil(acknowledged.activityMark)
        // The status itself survives; only the notice is retired.
        XCTAssertEqual(acknowledged.activity, .ready)
    }

    /// The word names the event that put the mark on screen, not the state it
    /// happens to report. "Idle" described a property; "Done" is the news.
    func testTheReadyWordNamesTheCompletionNotTheState() {
        let ready = session(TerminalSessionID(), activity: .ready)
        XCTAssertEqual(ready.activityMark?.statusWord, "Done")
        XCTAssertEqual(ready.activityMark?.accessibilityLabel, "Agent finished")
    }

    /// An ended Session is a permanent state rather than an event. Every Session
    /// that ever ended would otherwise carry a grey dot forever, which is the
    /// background noise the whole encoding exists to remove.
    func testAnEndedSessionNeverDraws() {
        let ended = session(TerminalSessionID(), activity: .exited)

        XCTAssertEqual(ended.activityMark, .exited)
        XCTAssertFalse(ended.activityMark?.isDrawn ?? true)

        // Not acknowledgeable, because there is nothing to retire: it was never
        // news to begin with.
        var seen = WarrenDesktopActivityAcknowledgments()
        XCTAssertFalse(seen.acknowledge(ended))
        XCTAssertNil(seen[ended.id])
    }

    /// Looking is not answering. Selecting a Session that is waiting on an
    /// approval must not retire the request, or the one state that cannot
    /// resolve itself would disappear on a stray click.
    func testAnUnansweredRequestIsNotRetiredByBeingSeen() {
        for kind in AgentAttentionKind.allCases {
            let id = TerminalSessionID()
            let blocked = session(
                id,
                activity: .blocked,
                attention: AgentAttention(kind: kind, reason: "Continue?")
            )
            var seen = WarrenDesktopActivityAcknowledgments()
            XCTAssertFalse(seen.acknowledge(blocked), "\(kind) must not be acknowledgeable")
            XCTAssertNil(seen[id])
            XCTAssertNotNil(blocked.acknowledgingActivity(kind == .input ? .blocked : .blocked).activityMark)
        }
    }

    /// A failure does not un-fail because it was visited.
    func testAFailureIsNotRetiredByBeingSeen() {
        let id = TerminalSessionID()
        let failed = session(id, activity: .failed)
        var seen = WarrenDesktopActivityAcknowledgments()
        XCTAssertFalse(seen.acknowledge(failed))
        XCTAssertNil(seen[id])
        XCTAssertEqual(failed.activityMark, .failed)
    }

    /// Without this, a second completion is swallowed by the first one's
    /// acknowledgment: `ready → (seen) → working → ready` has to light up again,
    /// because the Agent did something new in between.
    func testACompletionAfterNewWorkIsNewsAgain() {
        let id = TerminalSessionID()
        var seen = WarrenDesktopActivityAcknowledgments()
        XCTAssertTrue(seen.acknowledge(session(id, activity: .ready)))
        XCTAssertEqual(seen[id], .ready)

        // The Host moves on, so the recorded notice is about a previous state.
        XCTAssertTrue(seen.invalidate(sessionID: id, currentActivity: .working))
        XCTAssertNil(seen[id])

        // It comes back when the same Session finishes again.
        let finished = session(id, activity: .ready)
        XCTAssertEqual(finished.activityMark, .ready)
        XCTAssertTrue(seen.acknowledge(finished))
        XCTAssertNil(finished.acknowledgingActivity(seen[id]).activityMark)
    }

    /// Invalidation must be a no-op while the recorded state still matches, or
    /// every roster tick would re-light a notice the person has already read.
    func testInvalidationIgnoresAStillCurrentState() {
        let id = TerminalSessionID()
        var seen = WarrenDesktopActivityAcknowledgments()
        XCTAssertTrue(seen.acknowledge(session(id, activity: .ready)))
        XCTAssertFalse(seen.invalidate(sessionID: id, currentActivity: .ready))
        XCTAssertEqual(seen[id], .ready)
    }

    /// A Sessions that never reported activity has nothing to acknowledge, and
    /// acknowledging it would record a phantom notice.
    func testAShellWithNoAgentHasNothingToAcknowledge() {
        let shell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            tabID: "tab.shell",
            title: "zsh",
            kind: .shell
        )
        var seen = WarrenDesktopActivityAcknowledgments()
        XCTAssertNil(shell.activityMark)
        XCTAssertFalse(seen.acknowledge(shell))
        XCTAssertTrue(seen.isEmpty)
    }

    /// Session IDs belong to one Host, so a long-lived install must not carry
    /// acknowledgments for Sessions that ended weeks ago.
    func testRetainForgetsSessionsTheHostNoLongerLists() {
        let gone = TerminalSessionID()
        let live = TerminalSessionID()
        var seen = WarrenDesktopActivityAcknowledgments()
        seen.acknowledge(session(gone, activity: .ready))
        seen.acknowledge(session(live, activity: .ready))

        seen.retain(sessionIDs: [live])

        XCTAssertNil(seen[gone])
        XCTAssertEqual(seen[live], .ready)
    }

    /// "不过期" is only true if it survives a relaunch. The roster that arrives
    /// afterwards carries no transition history, so without persistence the
    /// client would have to guess — and the first roster tick deliberately does
    /// not report transitions.
    func testAcknowledgmentsSurviveARelaunch() {
        let id = TerminalSessionID()
        let records: [String: String] = [id.description: AgentActivityState.ready.rawValue]

        let restored = WarrenDesktopActivityAcknowledgments(storageRecords: records)

        XCTAssertEqual(restored[id], .ready)
        XCTAssertEqual(restored.storageRecords, records)
        XCTAssertNil(session(id, activity: .ready).acknowledgingActivity(restored[id]).activityMark)
    }

    /// A record written by a build with a state this one does not know must not
    /// crash the restore, and an unparseable ID must not poison the rest.
    func testUnknownRecordsAreDroppedNotFatal() {
        let id = TerminalSessionID()
        let restored = WarrenDesktopActivityAcknowledgments(storageRecords: [
            id.description: AgentActivityState.ready.rawValue,
            "not-a-uuid": AgentActivityState.ready.rawValue,
            TerminalSessionID().description: "a-state-from-the-future",
        ])

        XCTAssertEqual(restored[id], .ready)
        XCTAssertEqual(restored.storageRecords.count, 1)
    }

    /// Round-trips through the on-disk form, scoped per endpoint like Tab order.
    func testStoreRoundTripsPerScope() {
        let suite = "warren-tests-activity-ack-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertTrue(WarrenDesktopActivityAcknowledgmentStore.restore(scope: "local", defaults: defaults).isEmpty)

        let id = TerminalSessionID()
        var seen = WarrenDesktopActivityAcknowledgments()
        seen.acknowledge(session(id, activity: .ready))
        WarrenDesktopActivityAcknowledgmentStore.save(seen, scope: "local", defaults: defaults)

        XCTAssertEqual(
            WarrenDesktopActivityAcknowledgmentStore.restore(scope: "local", defaults: defaults)[id],
            .ready
        )
        // A second Host's scope is untouched by the first one's records.
        XCTAssertTrue(
            WarrenDesktopActivityAcknowledgmentStore.restore(scope: "vps", defaults: defaults).isEmpty
        )
    }

    /// An empty store must clear its key rather than leave a stale record behind.
    func testSavingAnEmptyStoreRemovesTheKey() {
        let suite = "warren-tests-activity-ack-empty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let id = TerminalSessionID()
        var seen = WarrenDesktopActivityAcknowledgments()
        seen.acknowledge(session(id, activity: .ready))
        WarrenDesktopActivityAcknowledgmentStore.save(seen, scope: "local", defaults: defaults)
        XCTAssertFalse(WarrenDesktopActivityAcknowledgmentStore.restore(scope: "local", defaults: defaults).isEmpty)

        WarrenDesktopActivityAcknowledgmentStore.save(
            WarrenDesktopActivityAcknowledgments(),
            scope: "local",
            defaults: defaults
        )
        XCTAssertTrue(WarrenDesktopActivityAcknowledgmentStore.restore(scope: "local", defaults: defaults).isEmpty)
    }

    /// The rollup reads the drawn mark, so a Workspace whose Sessions have all
    /// been read reports nothing rather than the quietest state.
    func testAWorkspaceRollupFollowsWhatIsDrawn() {
        let workspaceID = WorkspaceID()
        let projectID = ProjectID()
        let read = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "tab.read",
            title: "Read",
            kind: .codex,
            activity: .ready
        )
        let unseen = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "tab.unseen",
            title: "Unseen",
            kind: .codex,
            activity: .ready
        )
        let host = Host(id: HostID(), name: "Host")
        let project = Project(id: projectID, hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(id: workspaceID, projectID: projectID, name: "feature", path: "/tmp/feature")

        let base = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [read, unseen]
        )
        XCTAssertEqual(base.mark(in: workspaceID), .ready)

        // Reading one of the two leaves the other's completion notice standing.
        var seen = WarrenDesktopActivityAcknowledgments()
        seen.acknowledge(read)
        let afterOne = base.withSessionAcknowledgedActivity(seen[read.id], for: read.id)
        XCTAssertEqual(afterOne.mark(in: workspaceID), .ready)

        seen.acknowledge(unseen)
        let afterBoth = afterOne.withSessionAcknowledgedActivity(seen[unseen.id], for: unseen.id)
        XCTAssertNil(afterBoth.mark(in: workspaceID))
    }
}
