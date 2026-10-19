import XCTest
import WarrenDomain
@testable import WarrenDesktop

/// A shell Session's two lines, from the OSC 133 prompt state the Host reports.
///
/// The design gives five states, and the row must reach the right one from the
/// state alone: what is running, what ran, whether it failed in a way that is
/// worth saying, what an empty shell shows instead, and how an ended shell
/// reads. The title is separate: it says where the shell is, never what it ran.
final class WarrenDesktopShellRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func shell(
        state: WarrenDesktopShellState?,
        kind: TerminalSessionKind = .shell,
        activity: AgentActivityState? = nil,
        sessionState: WarrenDesktopSessionState = .attached,
        directory: String = "",
        createdAt: Date? = nil,
        customTitle: String? = nil,
        title: String = "Shell",
        runtimeProcess: String = "",
        runtimeCommandLine: String = "",
        agentProvider: TerminalSessionKind? = nil,
        currentStep: String? = nil
    ) -> WarrenDesktopSession {
        WarrenDesktopSession(
            id: TerminalSessionID(),
            title: title,
            customTitle: customTitle,
            kind: kind,
            agentProvider: agentProvider,
            state: sessionState,
            activity: activity,
            createdAt: createdAt,
            runtimeProcess: runtimeProcess,
            runtimeCommandLine: runtimeCommandLine,
            workingDirectory: directory,
            shellState: state,
            currentStep: currentStep
        )
    }

    private func line(
        _ session: WarrenDesktopSession,
        at time: Date? = nil
    ) -> WarrenDesktopSessionSecondLine {
        WarrenDesktopWorkspaceSessionRow.secondLine(for: session, now: time ?? now)
    }

    func testARunningCommandDrawsRunningAndItsElapsedTime() {
        let session = shell(
            state: WarrenDesktopShellState(
                atPrompt: false,
                runningCommand: "npm run dev",
                commandStartedAt: now.addingTimeInterval(-3 * 60)
            )
        )
        let line = line(session)
        XCTAssertEqual(line.tone, .running)
        XCTAssertEqual(line.primary, "npm run dev", "A shell line names the command, with no verb")
        XCTAssertTrue(line.isCommand, "A command draws in the monospaced face")
        XCTAssertEqual(line.meta, .time("3m"))
        XCTAssertTrue(line.extras.isEmpty)
        XCTAssertEqual(session.rowStatusMark, .working, "A running shell's dot is green")
    }

    func testARunningCommandFallsBackToTheLastExitWhenTheStartWasNotSeen() {
        let session = shell(
            state: WarrenDesktopShellState(
                atPrompt: false,
                runningCommand: "swift build",
                lastExitAt: now.addingTimeInterval(-75)
            )
        )
        XCTAssertEqual(line(session).meta, .time("1m"))
    }

    func testAFinishedCommandDrawsRanWithItsDistance() {
        let session = shell(
            state: WarrenDesktopShellState(
                atPrompt: true,
                lastCommand: "swift build",
                lastExitCode: 0,
                lastExitAt: now.addingTimeInterval(-2 * 60)
            )
        )
        let line = line(session)
        XCTAssertEqual(line.tone, .idle)
        XCTAssertEqual(line.primary, "swift build")
        XCTAssertEqual(line.meta, .time("2m"))
        XCTAssertTrue(line.extras.isEmpty, "A zero exit code is not appended")
        XCTAssertNil(session.rowStatusMark, "A successful shell has no dot")
    }

    func testAFailedCommandAppendsTheExitCodeAndTurnsTheDotRed() {
        let session = shell(
            state: WarrenDesktopShellState(
                atPrompt: true,
                lastCommand: "swift test",
                lastExitCode: 1,
                lastExitAt: now.addingTimeInterval(-5 * 60)
            )
        )
        let line = line(session)
        XCTAssertEqual(line.primary, "swift test")
        XCTAssertEqual(line.extras, [.init(text: "exit 1", isFailure: true)])
        XCTAssertEqual(line.meta, .time("5m"))
        XCTAssertEqual(session.rowStatusMark, .failed, "A failed shell's dot is red")
    }

    func testAnInterruptIsNotAFailure() {
        for code in [130, 137, 143] {
            let session = shell(
                state: WarrenDesktopShellState(
                    atPrompt: true,
                    lastCommand: "tail -f relay.log",
                    lastExitCode: code,
                    lastExitAt: now.addingTimeInterval(-10)
                )
            )
            let line = line(session)
            XCTAssertTrue(line.extras.isEmpty, "exit \(code) must not be appended")
            XCTAssertNil(session.rowStatusMark, "exit \(code) must not draw a red dot")
        }
    }

    func testAnEmptyShellDrawsTheFullDirectoryAndTheSessionAge() {
        let session = shell(
            state: WarrenDesktopShellState(atPrompt: true, shellName: "zsh"),
            directory: "/work/warren-ai-labs/warren",
            createdAt: now.addingTimeInterval(-3600)
        )
        let line = line(session)
        XCTAssertEqual(line.primary, "/work/warren-ai-labs/warren")
        XCTAssertEqual(line.meta, .time("1h"))
        XCTAssertTrue(line.isLocation, "A location keeps its tail and fades its start")
        XCTAssertNil(session.rowStatusMark)
    }

    func testAFailedLastCommandDrawsTheCommandAndItsExitCode() {
        let session = shell(
            state: WarrenDesktopShellState(
                atPrompt: true,
                lastCommand: "make install",
                lastExitCode: 2,
                lastExitAt: now.addingTimeInterval(-86400)
            ),
            directory: "/work/ak"
        )
        let line = line(session)
        XCTAssertEqual(line.primary, "make install")
        XCTAssertEqual(line.extras, [.init(text: "exit 2", isFailure: true)])
        XCTAssertEqual(line.meta, .time("24h"))
        XCTAssertEqual(session.rowStatusMark, .failed, "A failed command is the state the dot carries")
    }

    func testAShellWithoutOSC133StateKeepsTheForegroundFallback() {
        let session = shell(
            state: nil,
            directory: "/work/warren",
            runtimeProcess: "npm",
            runtimeCommandLine: "npm run dev"
        )
        let line = line(session)
        XCTAssertEqual(line.primary, "npm run dev")
        XCTAssertNil(session.rowStatusMark)
    }

    func testAnAgentInsideAShellKeepsTheAgentRule() {
        let session = shell(
            state: WarrenDesktopShellState(atPrompt: false, runningCommand: "npm run dev"),
            kind: .shell,
            activity: .working,
            runtimeProcess: "node",
            runtimeCommandLine: "node /usr/local/bin/claude",
            agentProvider: .claude,
            currentStep: "Editing SidebarView.swift"
        )
        let line = line(session)
        XCTAssertEqual(line.primary, "Editing SidebarView.swift")
        XCTAssertEqual(line.tone, .running)
    }

    // MARK: - Title

    func testTheTitleNamesWhereTheShellIs() {
        let unnamed = shell(state: nil, directory: "/work/warren")
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.rowTitle(for: unnamed, worktreeRoot: "/work/warren"),
            "Shell",
            "With no shell name yet the root falls back to the kind"
        )

        let named = shell(
            state: WarrenDesktopShellState(atPrompt: true, shellName: "zsh"),
            directory: "/work/warren"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.rowTitle(for: named, worktreeRoot: "/work/warren"),
            "zsh"
        )

        let nested = shell(
            state: WarrenDesktopShellState(atPrompt: true, shellName: "zsh"),
            directory: "/work/warren/Sources/WarrenKit"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.rowTitle(for: nested, worktreeRoot: "/work/warren"),
            "Sources/WarrenKit"
        )
    }

    func testALocationPrimaryIsMarkedAndNotShortenedAsACommand() {
        let session = shell(
            state: WarrenDesktopShellState(atPrompt: true, shellName: "zsh"),
            directory: FileManager.default.homeDirectoryForCurrentUser.path + "/Downloads",
            createdAt: now.addingTimeInterval(-60)
        )
        let line = line(session)
        XCTAssertEqual(line.primary, "~/Downloads")
        XCTAssertTrue(line.isLocation, "A directory is drawn whole, not shortened to …/Downloads")
        XCTAssertFalse(line.primary.contains("…"))
    }

    func testTheExitCodeIsAppendedOnlyWhenTheWholeLineFits() {
        let line = WarrenDesktopSessionSecondLine(
            tone: .idle,
            primary: "Ran swift test SomeExtremelyLongTargetNameHere",
            extras: [.init(text: "exit 1", isFailure: true)],
            meta: .time("5m")
        )
        let wide = WarrenDesktopSessionSecondLineLayout.fit(line: line, availableWidth: 400)
        XCTAssertEqual(wide.extras, [.init(text: "exit 1", isFailure: true)])
        let narrow = WarrenDesktopSessionSecondLineLayout.fit(line: line, availableWidth: 120)
        XCTAssertTrue(narrow.isPrimaryTruncated)
        XCTAssertTrue(narrow.extras.isEmpty, "An exit code is never drawn truncated")
    }

    func testTheTitleNeverRepeatsTheCommand() {
        let session = shell(
            state: WarrenDesktopShellState(
                atPrompt: false,
                runningCommand: "npm run dev",
                shellName: "zsh"
            ),
            directory: "/work/warren"
        )
        let title = WarrenDesktopWorkspaceSessionRow.rowTitle(for: session, worktreeRoot: "/work/warren")
        XCTAssertEqual(title, "zsh")
        XCTAssertFalse(title.contains("npm run dev"))
    }

    func testTheRowAndTheTabNameAShellTheSameWay() {
        let session = shell(
            state: WarrenDesktopShellState(atPrompt: false, runningCommand: "npm run dev", shellName: "zsh"),
            directory: "/work/warren"
        )
        XCTAssertTrue(WarrenDesktopWorkspaceSessionRow.usesLocationTitle(for: session))
        // The row, the tab, and the pane header all ask the one title function.
        // The command travels beside the title, never inside it.
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.rowTitle(for: session, worktreeRoot: "/work/warren"),
            "zsh"
        )
        XCTAssertEqual(
            WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: "/work/warren").title,
            "zsh"
        )
    }

    // MARK: - Result sentence

    /// A resting Agent leads with what the turn accomplished, and falls back to
    /// its counts when the Host could not write a sentence.
    func testARestingAgentPrefersTheHostsResultSentence() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            title: "Fix the resize race",
            kind: .claude,
            activity: .ready,
            resultSentence: "Fixed the resize race, added 3 tests",
            turnCounts: ["Edited 2 files"]
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session, now: now).primary,
            "Fixed the resize race, added 3 tests"
        )
    }

    func testARestingAgentFallsBackToItsCountsWithoutASentence() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            title: "Fix the resize race",
            kind: .claude,
            activity: .ready,
            turnCounts: ["Edited 2 files"]
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session, now: now).primary,
            "Edited 2 files"
        )
    }

    /// A working Agent still says what it is doing: the sentence describes the
    /// turn that already ended.
    func testAWorkingAgentIgnoresTheResultSentence() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            title: "Fix the resize race",
            kind: .claude,
            activity: .working,
            currentStep: "Editing SplitLayout.swift",
            resultSentence: "Fixed the resize race, added 3 tests",
            turnCounts: ["Edited 2 files"]
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session, now: now).primary,
            "Editing SplitLayout.swift"
        )
    }

    // MARK: - Idle collapse

    private func collapsed(
        _ session: WarrenDesktopSession,
        seenAt: Date? = nil,
        pointerInside: Bool = false
    ) -> Bool {
        WarrenDesktopWorkspaceSessionRow.isCollapsedShell(
            for: session,
            seenAt: seenAt,
            pointerInsideSidebar: pointerInside,
            now: now
        )
    }

    func testAShellThatNeverRanStartsCollapsed() {
        let session = shell(
            state: WarrenDesktopShellState(atPrompt: true, shellName: "zsh"),
            createdAt: now.addingTimeInterval(-30)
        )
        XCTAssertTrue(collapsed(session))
    }

    func testAShellCollapsesTenMinutesAfterItsLastCommand() {
        let rested = shell(state: WarrenDesktopShellState(
            atPrompt: true, lastCommand: "swift build", lastExitCode: 0,
            lastExitAt: now.addingTimeInterval(-601)
        ))
        XCTAssertTrue(collapsed(rested))

        let recent = shell(state: WarrenDesktopShellState(
            atPrompt: true, lastCommand: "swift build", lastExitCode: 0,
            lastExitAt: now.addingTimeInterval(-599)
        ))
        XCTAssertFalse(collapsed(recent))
    }

    func testRunningAShellKeepsItTwoLines() {
        let session = shell(state: WarrenDesktopShellState(
            atPrompt: false, runningCommand: "npm run dev",
            lastExitAt: now.addingTimeInterval(-3600)
        ))
        XCTAssertFalse(collapsed(session))
    }

    func testAFailedCommandStaysTwoLinesUntilItHasBeenSeen() {
        let session = shell(state: WarrenDesktopShellState(
            atPrompt: true, lastCommand: "swift test", lastExitCode: 1,
            lastExitAt: now.addingTimeInterval(-3600)
        ))
        XCTAssertFalse(collapsed(session), "An unseen failure keeps its command and exit code")
        XCTAssertFalse(
            collapsed(session, seenAt: now.addingTimeInterval(-300)),
            "Seeing it starts a fresh ten-minute rest"
        )
        XCTAssertTrue(collapsed(session, seenAt: now.addingTimeInterval(-601)))
    }

    func testAPointerOnTheRailPostponesTheCollapse() {
        let session = shell(
            state: WarrenDesktopShellState(atPrompt: true, shellName: "zsh"),
            createdAt: now.addingTimeInterval(-3600)
        )
        XCTAssertTrue(collapsed(session))
        XCTAssertFalse(collapsed(session, pointerInside: true))
    }

    func testAnAgentInsideAShellNeverCollapses() {
        let session = shell(
            state: WarrenDesktopShellState(atPrompt: true, shellName: "zsh"),
            kind: .shell,
            activity: .ready,
            createdAt: now.addingTimeInterval(-3600),
            agentProvider: .claude
        )
        XCTAssertFalse(collapsed(session))
    }
}
