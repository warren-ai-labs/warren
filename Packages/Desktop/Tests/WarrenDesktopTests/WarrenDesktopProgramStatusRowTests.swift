import XCTest
import WarrenDesignSystem
import WarrenDomain
@testable import WarrenDesktop

/// A row whose program reported over OSC 7501: the report joins the badge's
/// dot through the one activity encoding, and its message leads the second
/// line. An Agent status still outranks it.
final class WarrenDesktopProgramStatusRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        mark: WarrenActivityMark?,
        message: String? = nil,
        shell: WarrenDesktopShellState? = nil,
        kind: TerminalSessionKind = .shell,
        activity: AgentActivityState? = nil
    ) -> WarrenDesktopSession {
        WarrenDesktopSession(
            id: TerminalSessionID(),
            title: "Shell",
            kind: kind,
            state: .attached,
            activity: activity,
            shellState: shell,
            programStatusMark: mark,
            programStatusMessage: message
        )
    }

    func testABlockedProgramOutranksTheRunningCommand() {
        let row = session(
            mark: .approvalNeeded,
            shell: WarrenDesktopShellState(atPrompt: false, runningCommand: "terraform apply")
        )
        XCTAssertEqual(row.rowStatusMark, .approvalNeeded)
    }

    func testAShellFailureStillShowsBesideAWorkingProgram() {
        let row = session(
            mark: .working,
            shell: WarrenDesktopShellState(atPrompt: true, lastCommand: "make", lastExitCode: 2, lastExitAt: now)
        )
        XCTAssertEqual(row.rowStatusMark, .failed)
    }

    func testAProgramWithoutShellStateStillGetsADot() {
        XCTAssertEqual(session(mark: .working).rowStatusMark, .working)
        XCTAssertNil(session(mark: nil).rowStatusMark)
    }

    func testADoneProgramKeepsItsDotAtThePrompt() {
        let row = session(
            mark: .ready,
            shell: WarrenDesktopShellState(atPrompt: true, lastCommand: "make", lastExitCode: 0, lastExitAt: now)
        )
        XCTAssertEqual(row.rowStatusMark, .ready)
    }

    /// The protocol calls the root record's label the window title, so an Agent
    /// that names itself outranks the name Warren generated for the row.
    func testAnAgentsProgramTitleNamesTheRow() {
        let row = WarrenDesktopSession(
            id: TerminalSessionID(),
            title: "Fix the resize race",
            kind: .claude,
            state: .attached,
            activity: .working,
            programStatusMark: .working,
            programStatusMessage: "Uploading 3 of 8",
            programStatusTitle: "Audit the resize race"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.rowTitle(for: row, worktreeRoot: ""),
            "Audit the resize race"
        )

        let shell = session(mark: .working)
        XCTAssertNotEqual(
            WarrenDesktopWorkspaceSessionRow.rowTitle(for: shell, worktreeRoot: ""),
            "plan"
        )
    }

    func testAnAgentStatusOutranksTheProgram() {
        let row = session(mark: .failed, kind: .codex, activity: .working)
        XCTAssertEqual(row.rowStatusMark, .working)
    }

    func testTheProgramMessageLeadsTheSecondLine() {
        let row = session(
            mark: .working,
            message: "Uploading 3 of 8",
            shell: WarrenDesktopShellState(
                atPrompt: false,
                runningCommand: "deploy",
                commandStartedAt: now.addingTimeInterval(-90)
            )
        )
        let line = WarrenDesktopWorkspaceSessionRow.secondLine(for: row, now: now)
        XCTAssertEqual(line.primary, "Uploading 3 of 8")
        XCTAssertEqual(line.tone, .running)
        XCTAssertFalse(line.isMonospaced)
        XCTAssertNotEqual(line.meta, .none)
    }

    func testABlockedMessageRestsAndAMessagelessProgramKeepsTheShellRule() {
        let blocked = session(mark: .approvalNeeded, message: "Apply 3 to add?")
        XCTAssertEqual(WarrenDesktopWorkspaceSessionRow.secondLine(for: blocked, now: now).tone, .idle)

        let silent = session(
            mark: .working,
            shell: WarrenDesktopShellState(atPrompt: false, runningCommand: "npm run build")
        )
        let line = WarrenDesktopWorkspaceSessionRow.secondLine(for: silent, now: now)
        XCTAssertEqual(line.tone, .running)
        XCTAssertEqual(line.primary, "running")
    }
}
