import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain

final class WarrenDesktopApprovalTrayTests: XCTestCase {
    private func session(
        _ id: TerminalSessionID = TerminalSessionID(),
        tabID: String? = nil,
        activity: AgentActivityState,
        attention: AgentAttention? = nil
    ) -> WarrenDesktopSession {
        WarrenDesktopSession(
            id: id,
            workspaceID: WorkspaceID(),
            tabID: tabID ?? "tab.\(id.description)",
            title: "Session \(id.shortDescription)",
            kind: .claude,
            agentStatus: AgentStatus(activity: activity, attention: attention)
        )
    }

    private func entries(
        _ sessions: [WarrenDesktopSession],
        selectedTabID: String? = nil,
        decisions: [TerminalSessionID: WarrenDesktopPendingDecision] = [:]
    ) -> [WarrenDesktopApprovalTrayEntry] {
        WarrenDesktopApprovalTray.entries(
            sessions: sessions,
            selectedTabID: selectedTabID,
            decisions: decisions,
            title: \.title,
            location: { _ in "warren \u{00B7} main" }
        )
    }

    private func decision(id: String) -> WarrenDesktopPendingDecision {
        WarrenDesktopPendingDecision(
            id: id,
            ask: "Claude wants to run a command",
            detail: "swift test",
            options: [
                .init(id: "allow", label: "Allow once"),
                .init(id: "always", label: "Always allow"),
                .init(id: "reject", label: "Reject", isReject: true),
            ]
        )
    }

    func testWaitingIsTheBlockedHalfOfTheActionableTier() {
        XCTAssertTrue(WarrenActivityMark.approvalNeeded.isWaitingOnPerson)
        XCTAssertTrue(WarrenActivityMark.inputNeeded.isWaitingOnPerson)
        XCTAssertTrue(WarrenActivityMark.attentionUnspecified.isWaitingOnPerson)
        XCTAssertFalse(WarrenActivityMark.failed.isWaitingOnPerson)
        XCTAssertFalse(WarrenActivityMark.working.isWaitingOnPerson)
        XCTAssertFalse(WarrenActivityMark.ready.isWaitingOnPerson)
    }

    func testOnlyRequestsAreListedAndTheCurrentTabIsLeftOut() {
        let approval = session(
            activity: .blocked,
            attention: AgentAttention(kind: .approval, reason: "permission")
        )
        let current = session(
            tabID: "current",
            activity: .blocked,
            attention: AgentAttention(kind: .input, reason: "question")
        )
        let failed = session(activity: .failed)
        let working = session(activity: .working)

        let rows = entries([approval, current, failed, working], selectedTabID: "current")

        XCTAssertEqual(rows.map(\.id), [approval.id])
        XCTAssertEqual(rows.first?.ask, "permission")
        XCTAssertNil(rows.first?.decision)
    }

    func testApprovalsComeBeforeInputRequests() {
        let input = session(activity: .blocked, attention: AgentAttention(kind: .input, reason: "question"))
        let approval = session(activity: .blocked, attention: AgentAttention(kind: .approval, reason: "permission"))

        XCTAssertEqual(entries([input, approval]).map(\.id), [approval.id, input.id])
    }

    func testTheDecisionIsShownWhenItIsTheRequestTheAgentIsStoppedOn() {
        let waiting = session(
            activity: .blocked,
            attention: AgentAttention(kind: .approval, reason: "permission", requestID: "req-1")
        )

        let rows = entries([waiting], decisions: [waiting.id: decision(id: "req-1")])

        XCTAssertEqual(rows.first?.decision?.options.map(\.label), ["Allow once", "Always allow", "Reject"])
        XCTAssertEqual(rows.first?.ask, "Claude wants to run a command")
        XCTAssertEqual(rows.first?.detail, "swift test")
    }

    func testAStaleDecisionFallsBackToOpenOnly() {
        let waiting = session(
            activity: .blocked,
            attention: AgentAttention(kind: .approval, reason: "permission", requestID: "req-2")
        )

        let rows = entries([waiting], decisions: [waiting.id: decision(id: "req-1")])

        XCTAssertNil(rows.first?.decision)
        XCTAssertNil(rows.first?.detail)
        XCTAssertEqual(rows.first?.ask, "permission")
    }

    func testTheDotAndTheTrayShareTheirPopulation() {
        let current = session(tabID: "current", activity: .failed)
        let other = session(activity: .failed)

        let unattended = WarrenDesktopSidebarAttention.unattended([current, other], selectedTabID: "current")

        XCTAssertEqual(unattended.map(\.id), [other.id])
    }
}
