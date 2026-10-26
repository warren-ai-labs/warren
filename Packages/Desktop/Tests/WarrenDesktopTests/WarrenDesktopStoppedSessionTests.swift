import SwiftUI
import XCTest
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
@testable import WarrenDesktop

/// The rule that decides which ended Sessions keep a Tab, and what that Tab
/// offers. It is one rule for every Desktop roster, so it is tested as one.
final class WarrenDesktopStoppedSessionTests: XCTestCase {
    private func input(
        _ id: String,
        lifecycle: String = "running",
        kind: String = "shell",
        runtimeKind: String? = nil,
        endReason: String? = nil,
        resumedFrom: String? = nil
    ) -> WarrenDesktopStoppedSessionInput {
        WarrenDesktopStoppedSessionInput(
            sessionID: id,
            lifecycle: lifecycle,
            kind: kind,
            runtimeKind: runtimeKind,
            endReason: endReason,
            resumedFrom: resumedFrom
        )
    }

    func testOnlyUnrequestedEndsKeepAStoppedTab() {
        let sessions = [
            input("missing", lifecycle: "ended", endReason: "runtimeMissing"),
            input("exited", lifecycle: "ended", kind: "codex", endReason: "processExited"),
            input("closed", lifecycle: "ended", endReason: "userClosed"),
            input("legacy", lifecycle: "ended"),
            input("future", lifecycle: "ended", endReason: "somethingNew"),
            input("live"),
        ]
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.stoppedSessionIDs(sessions),
            ["missing", "exited"]
        )
    }

    func testASessionWithNoTerminalToShowKeepsNoTab() {
        let sessions = [
            input("browser", lifecycle: "ended", kind: "browser", endReason: "runtimeMissing"),
            input("chat", lifecycle: "ended", kind: "codex", runtimeKind: "acp", endReason: "runtimeMissing"),
        ]
        XCTAssertTrue(WarrenDesktopStoppedSessionRoster.stoppedSessionIDs(sessions).isEmpty)
    }

    /// Resuming moves the conversation to a new Session. The stopped one stops
    /// being a Tab instead of sitting beside the conversation it handed over.
    func testAResumedStoppedSessionLeavesTheTabList() {
        let sessions = [
            input("stopped", lifecycle: "ended", kind: "codex", endReason: "runtimeMissing"),
            input("stopped-again", lifecycle: "ended", kind: "pi", endReason: "runtimeMissing"),
            input("resumed", kind: "codex", resumedFrom: "stopped"),
        ]
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.stoppedSessionIDs(sessions),
            ["stopped-again"]
        )
        // Only a running continuation supersedes: an ended resume attempt leaves
        // the original stopped Tab where it was.
        let failedResume = [
            input("stopped", lifecycle: "ended", kind: "codex", endReason: "runtimeMissing"),
            input("attempt", lifecycle: "ended", kind: "codex", endReason: "processExited", resumedFrom: "stopped"),
        ]
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.stoppedSessionIDs(failedResume),
            ["stopped", "attempt"]
        )
    }

    func testAnAgentWithAConversationOffersResume() {
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.action(
                kind: "codex",
                agentProvider: nil,
                agentSessionID: "thread-1"
            ),
            .resume
        )
        // A shell promoted by a provider binding resumes through the binding.
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.action(
                kind: "shell",
                agentProvider: "claude",
                agentSessionID: "thread-2"
            ),
            .resume
        )
    }

    func testAShellOffersRestart() {
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.action(kind: "shell", agentProvider: nil, agentSessionID: nil),
            .restart
        )
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.action(kind: "custom", agentProvider: "", agentSessionID: ""),
            .restart
        )
    }

    /// An Agent Session with no recorded conversation has nothing to continue,
    /// and re-running the provider would silently start a different one.
    func testAnAgentWithoutAConversationOffersNothing() {
        XCTAssertNil(
            WarrenDesktopStoppedSessionRoster.action(kind: "codex", agentProvider: nil, agentSessionID: nil)
        )
        // A provider the Host cannot resume is not offered either.
        XCTAssertNil(
            WarrenDesktopStoppedSessionRoster.action(
                kind: "qoder",
                agentProvider: nil,
                agentSessionID: "conversation-1"
            )
        )
    }

    func testEndReasonCopyIsWiredToTheReason() {
        XCTAssertEqual(WarrenDesktopEndReason(wire: nil), .unknown)
        XCTAssertEqual(WarrenDesktopEndReason(wire: "  "), .unknown)
        XCTAssertEqual(WarrenDesktopEndReason(wire: "runtimeMissing"), .runtimeMissing)
        XCTAssertEqual(WarrenDesktopEndReason(wire: "exitedBySomethingNew"), .unknown)
        XCTAssertTrue(WarrenDesktopEndReason.runtimeMissing.detail.contains("runtime"))
        XCTAssertTrue(WarrenDesktopEndReason.processExited.detail.contains("program"))
    }

    /// A sidebar row opens whatever has a Tab to land on. A stopped Session's
    /// Tab is where its Resume lives, so requiring a live runtime left every
    /// stopped row inert after a Host restart.
    func testAStoppedSessionWithATabIsOpenable() {
        let hostID = HostID(rawValue: UUID())
        let projectID = ProjectID(rawValue: UUID())
        let workspaceID = WorkspaceID(rawValue: UUID())
        let live = TerminalSessionID(rawValue: UUID())
        let stopped = TerminalSessionID(rawValue: UUID())
        let history = TerminalSessionID(rawValue: UUID())
        func session(_ id: TerminalSessionID, state: WarrenDesktopSessionState) -> WarrenDesktopSession {
            WarrenDesktopSession(
                id: id,
                workspaceID: workspaceID,
                tabID: "tab-\(id)",
                title: "Session",
                kind: .claude,
                state: state
            )
        }
        let projection = WarrenDesktopProjection(
            host: WarrenDomain.Host(id: hostID, name: "Local"),
            projects: [Project(id: projectID, hostID: hostID, name: "P", rootPath: "/p")],
            workspaces: [Workspace(id: workspaceID, projectID: projectID, name: "main", path: "/p", branch: "main")],
            sessions: [
                session(live, state: .attached),
                session(stopped, state: .exited),
                session(history, state: .exited),
            ],
            // The Host keeps a Tab for the stopped Session; the other ended one
            // is history only.
            tabs: [
                ClientTab(id: "tab-\(live)", title: "Live", sessionID: live, kind: .claude),
                ClientTab(id: "tab-\(stopped)", title: "Stopped", sessionID: stopped, kind: .claude),
            ],
            sessionWorkspaceIDs: [live: workspaceID, stopped: workspaceID, history: workspaceID]
        )

        XCTAssertTrue(projection.canOpenSession(live))
        XCTAssertTrue(projection.canOpenSession(stopped))
        XCTAssertFalse(projection.canOpenSession(history), "An ended Session with no Tab has nothing to open")
        XCTAssertFalse(projection.canOpenSession(TerminalSessionID(rawValue: UUID())))
    }

    /// Resume All continues one stopped record per conversation, the newest,
    /// and leaves out the conversation the current banner's Resume covers.
    func testResumeAllTakesTheNewestRecordOfEachOtherConversation() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let candidates = [
            WarrenDesktopResumeCandidate(sessionID: "current", conversationID: "conv-a", createdAt: new),
            WarrenDesktopResumeCandidate(sessionID: "same-as-current", conversationID: "conv-a", createdAt: old),
            WarrenDesktopResumeCandidate(sessionID: "b-old", conversationID: "conv-b", createdAt: old),
            WarrenDesktopResumeCandidate(sessionID: "c", conversationID: "conv-c"),
            WarrenDesktopResumeCandidate(sessionID: "b-new", conversationID: "conv-b", createdAt: new),
        ]

        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.resumeAllTargets(candidates, besides: "current"),
            ["c", "b-new"]
        )
        // From a banner that offers no Resume of its own, every conversation is
        // someone else's.
        XCTAssertEqual(
            WarrenDesktopStoppedSessionRoster.resumeAllTargets(candidates, besides: "a-shell"),
            ["current", "c", "b-new"]
        )
        XCTAssertTrue(
            WarrenDesktopStoppedSessionRoster.resumeAllTargets(
                [candidates[0], candidates[1]],
                besides: "current"
            ).isEmpty,
            "Only the current conversation is stopped, so there is nothing else to resume"
        )
    }

    /// A stopped Session's title is quiet whether or not it is selected, so a
    /// Session that can only be resumed reads apart from a running one.
    @MainActor
    func testAStoppedSessionTitleIsQuiet() {
        let tokens = WarrenColorTokens.resolved(for: .dark, material: .opaque)
        func session(_ state: WarrenDesktopSessionState) -> WarrenDesktopSession {
            WarrenDesktopSession(
                id: TerminalSessionID(rawValue: UUID()),
                workspaceID: WorkspaceID(rawValue: UUID()),
                title: "Claude Code",
                kind: .claude,
                state: state
            )
        }
        for isSelected in [false, true] {
            XCTAssertEqual(
                WarrenDesktopWorkspaceSessionRow.titleInk(
                    session: session(.exited), isSelected: isSelected, tokens: tokens
                ),
                tokens.treeQuietText
            )
        }
        // A running Session at rest takes the resting ink; its dot, when
        // lit, lifts it to the live one.
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.titleInk(
                session: session(.attached), isSelected: false, tokens: tokens
            ),
            tokens.treeSessionRestingText
        )
    }
}
