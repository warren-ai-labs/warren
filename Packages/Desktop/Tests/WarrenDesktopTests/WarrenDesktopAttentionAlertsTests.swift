import XCTest
@testable import WarrenDesktop
import WarrenDomain

final class WarrenDesktopAttentionAlertsTests: XCTestCase {
    private func alert(_ sessionID: TerminalSessionID, key: String) -> WarrenDesktopAttentionAlert {
        WarrenDesktopAttentionAlert(
            sessionID: sessionID,
            key: key,
            title: "Claude Code",
            location: "warren \u{00B7} main",
            body: "Claude wants to run a command\nswift test",
            quickAnswer: nil
        )
    }

    func testARequestAlertsOnceAndIsWithdrawnWhenNobodyAsks() {
        var tracker = WarrenDesktopAttentionAlertTracker()
        let session = TerminalSessionID()

        let first = tracker.update([alert(session, key: "a")])
        XCTAssertEqual(first.post.map(\.key), ["a"])
        XCTAssertTrue(first.withdraw.isEmpty)

        let again = tracker.update([alert(session, key: "a")])
        XCTAssertTrue(again.post.isEmpty)
        XCTAssertTrue(again.withdraw.isEmpty)

        let gone = tracker.update([])
        XCTAssertTrue(gone.post.isEmpty)
        XCTAssertEqual(gone.withdraw, [session])
    }

    func testANewRequestOnTheSameSessionAlertsAgainWithoutAWithdrawal() {
        var tracker = WarrenDesktopAttentionAlertTracker()
        let session = TerminalSessionID()
        _ = tracker.update([alert(session, key: "a")])

        let next = tracker.update([alert(session, key: "b")])

        XCTAssertEqual(next.post.map(\.key), ["b"])
        XCTAssertTrue(next.withdraw.isEmpty)
    }

    func testQuickAnswerAllowsTheFirstOptionAndRejectsTheFirstRejection() {
        let decision = WarrenDesktopPendingDecision(
            id: "request-1",
            ask: "Claude wants to run a command",
            detail: "swift test",
            options: [
                .init(id: "allow", label: "Allow once"),
                .init(id: "always", label: "Always allow"),
                .init(id: "reject", label: "Reject", isReject: true),
            ]
        )

        let answer = WarrenDesktopAttentionAlerts.quickAnswer(decision)

        XCTAssertEqual(answer?.decisionID, "request-1")
        XCTAssertEqual(answer?.allowOptionID, "allow")
        XCTAssertEqual(answer?.rejectOptionID, "reject")
    }

    func testADecisionWithoutARejectionIsAnsweredInTheWindow() {
        let decision = WarrenDesktopPendingDecision(
            id: "question-1",
            ask: "Which branch?",
            detail: "",
            options: [.init(id: "main", label: "main"), .init(id: "dev", label: "dev")]
        )

        XCTAssertNil(WarrenDesktopAttentionAlerts.quickAnswer(decision))
    }
}
