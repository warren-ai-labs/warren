import XCTest
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
}
