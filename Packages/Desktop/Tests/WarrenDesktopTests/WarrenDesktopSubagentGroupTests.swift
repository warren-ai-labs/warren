import WarrenDomain
import XCTest
@testable import WarrenDesktop

/// The subagent chip and reveal state machine, asserted without mounting a
/// view: `WarrenDesktopWorkspaceSessionRow` exposes the decisions as pure
/// functions so the chip's lifetime is testable on its own.
final class WarrenDesktopSubagentGroupTests: XCTestCase {
    /// The subagent chip: a running child always shows it; an all-done group
    /// only while it is open and its turn runs; a closed group whose children
    /// finished hides it. A closed group still reveals the one child that
    /// needs a person.
    func testSubagentGroupChipAndRevealStateMachine() {
        let running = WarrenDesktopSubagent(id: "a", title: "Explore", state: .running)
        let waiting = WarrenDesktopSubagent(
            id: "b",
            title: "general",
            state: .running,
            isWaiting: true
        )
        let done = WarrenDesktopSubagent(id: "c", title: "Plan", state: .completed)
        func session(
            _ subagents: [WarrenDesktopSubagent],
            activity: AgentActivityState?
        ) -> WarrenDesktopSession {
            WarrenDesktopSession(
                id: TerminalSessionID(),
                title: "Claude Code",
                kind: .claude,
                activity: activity,
                subagents: subagents
            )
        }

        XCTAssertTrue(
            WarrenDesktopWorkspaceSessionRow.showsSubagentCapsule(
                session: session([running], activity: .working),
                isExpanded: false
            ),
            "A running child shows the chip even while the group is closed"
        )
        XCTAssertFalse(
            WarrenDesktopWorkspaceSessionRow.showsSubagentCapsule(
                session: session([done], activity: .working),
                isExpanded: false
            ),
            "An all-done group that was never opened hides the chip"
        )
        XCTAssertTrue(
            WarrenDesktopWorkspaceSessionRow.showsSubagentCapsule(
                session: session([done], activity: .working),
                isExpanded: true
            ),
            "An open, all-done group keeps its dim chip until the turn ends"
        )
        XCTAssertFalse(
            WarrenDesktopWorkspaceSessionRow.showsSubagentCapsule(
                session: session([done], activity: .ready),
                isExpanded: true
            ),
            "The chip disappears when the parent's turn ends"
        )
        XCTAssertFalse(
            WarrenDesktopWorkspaceSessionRow.isSubagentGroupOpen(
                session: session([running], activity: .ready),
                isExpanded: true
            ),
            "A turn end closes the group even if the stored expansion lingers"
        )

        let mixed = session([running, waiting], activity: .working)
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.visibleSubagents(session: mixed, isExpanded: false).map(\.id),
            ["b"],
            "A closed group reveals only the child that needs a person"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.visibleSubagents(session: mixed, isExpanded: true).map(\.id),
            ["a", "b"],
            "An open group reveals every child"
        )
    }
}
