import XCTest
@testable import WarrenDomain

/// The one name a Session goes by, and the summarized command beside it.
///
/// The top bar, the sidebar row, a split pane's header, a tab, and the window
/// title all ask `SessionTitle.resolve`, so these tests are the contract for
/// every surface at once: the order of the branches, the shell's location
/// rule, and the command the top bar appends.
final class SessionTitleTests: XCTestCase {
    private func resolve(
        customTitle: String? = nil,
        title: String = "Shell",
        kind: TerminalSessionKind = .shell,
        process: String = "",
        commandLine: String = "",
        shellName: String = "",
        runningCommand: String = "",
        reportsPromptState: Bool = false,
        directory: String = "/work/warren",
        worktreeRoot: String = "/work/warren"
    ) -> SessionTitle {
        SessionTitle.resolve(
            customTitle: customTitle,
            title: title,
            kind: kind,
            process: process,
            commandLine: commandLine,
            shellName: shellName,
            runningCommand: runningCommand,
            reportsPromptState: reportsPromptState,
            directory: directory,
            worktreeRoot: worktreeRoot
        )
    }

    func testAUserSetNameWinsOverEverything() {
        let resolved = resolve(
            customTitle: "My Agent",
            title: "Fix the resize race",
            kind: .claude,
            process: "node",
            commandLine: "node /usr/local/bin/claude"
        )
        XCTAssertEqual(resolved.title, "My Agent")
        XCTAssertEqual(resolved.runningCommand, "")
    }

    func testAnAgentKeepsItsGeneratedTitle() {
        let resolved = resolve(
            title: "Fix the resize race",
            kind: .claude,
            process: "node",
            commandLine: "node /usr/local/bin/claude"
        )
        XCTAssertEqual(resolved.title, "Fix the resize race")
    }

    func testAnUnnamedAgentReadsAsItsKindName() {
        XCTAssertEqual(resolve(title: "Claude Code", kind: .claude).title, "Claude Code")
        XCTAssertEqual(resolve(title: "Codex", kind: .codex).title, "Codex")
    }

    func testAShellRunningACommandKeepsItsLocationAndCarriesTheSummary() {
        let resolved = resolve(
            shellName: "zsh",
            runningCommand: "npm run dev",
            reportsPromptState: true
        )
        XCTAssertEqual(resolved.title, "zsh")
        XCTAssertEqual(resolved.runningCommand, "npm run dev")
    }

    func testAnIdleShellCarriesNoCommand() {
        let resolved = resolve(
            shellName: "zsh",
            runningCommand: "",
            reportsPromptState: true
        )
        XCTAssertEqual(resolved.title, "zsh")
        XCTAssertEqual(resolved.runningCommand, "")
    }

    func testAShellInsideTheWorktreeNamesTheRelativePath() {
        let resolved = resolve(
            shellName: "zsh",
            reportsPromptState: true,
            directory: "/work/warren/Sources/WarrenKit"
        )
        XCTAssertEqual(resolved.title, "Sources/WarrenKit")
    }

    func testAShellOutsideTheWorktreeKeepsTheHomeShortening() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolved = resolve(
            shellName: "zsh",
            reportsPromptState: true,
            directory: home + "/Downloads",
            worktreeRoot: "/work/warren"
        )
        XCTAssertEqual(resolved.title, "~/Downloads")
    }

    func testAShellWithoutPromptStateStillFallsBackToTheKindName() {
        let resolved = resolve(
            process: "npm",
            commandLine: "npm run dev",
            directory: "/work/warren",
            worktreeRoot: "/work/warren"
        )
        XCTAssertEqual(resolved.title, "Shell")
        XCTAssertEqual(resolved.runningCommand, "npm run dev")
    }

    func testACustomCommandSessionNamesTheSummarizedCommand() {
        let resolved = resolve(
            title: "Custom",
            kind: .custom,
            process: "npm",
            commandLine: "npm run dev -- --port 3000"
        )
        XCTAssertEqual(resolved.title, "npm run dev")
        XCTAssertEqual(resolved.runningCommand, "")
    }

    func testABrowserNamesItsKind() {
        XCTAssertEqual(resolve(title: "Browser", kind: .browser).title, "Browser")
    }

    func testATitleIsNeverRepeatedAsARunningCommand() {
        let resolved = resolve(
            title: "zsh",
            shellName: "zsh",
            runningCommand: "zsh",
            reportsPromptState: true
        )
        XCTAssertEqual(resolved.title, "zsh")
        XCTAssertEqual(resolved.runningCommand, "")
    }
}
