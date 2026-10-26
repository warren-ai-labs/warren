import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain

final class WarrenDesktopLeadSessionTests: XCTestCase {
    private func session(activity: AgentActivityState) -> WarrenDesktopSession {
        WarrenDesktopSession(
            id: TerminalSessionID(),
            title: "Ship Lead Agent",
            kind: .codex,
            state: .attached,
            activity: activity
        )
    }

    func testALeadsUnansweredRequestRaisesTheSessionsMark() {
        let ready = session(activity: .ready)
        XCTAssertEqual(ready.effectiveActivityMark, .ready)

        let waiting = ready.withLead(isLead: true, needsAttention: true)
        XCTAssertTrue(waiting.isLead)
        XCTAssertTrue(waiting.leadNeedsAttention)
        XCTAssertEqual(waiting.effectiveActivityMark, .inputNeeded)
        XCTAssertEqual(waiting.title, ready.title)
    }

    func testAPlainLeadMessageLeavesTheHostLifecycleAlone() {
        let working = session(activity: .working)
        let lead = working.withLead(isLead: true, needsAttention: false)
        XCTAssertEqual(lead.effectiveActivityMark, .working)
    }

    func testClearingTheLeadFlagsRestoresTheHostMark() {
        let ready = session(activity: .ready)
            .withLead(isLead: true, needsAttention: true)
            .withLead(isLead: false, needsAttention: false)
        XCTAssertFalse(ready.isLead)
        XCTAssertFalse(ready.leadNeedsAttention)
        XCTAssertEqual(ready.effectiveActivityMark, .ready)
    }
}
