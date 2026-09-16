import XCTest
@testable import WarrenDomain

final class TerminalSessionPresentationTests: XCTestCase {
    func testCommandLabelPrefersTheCommandLine() {
        XCTAssertEqual(
            TerminalSessionPresentation.commandLabel(
                kind: .shell,
                process: "npm",
                commandLine: "npm run dev"
            ),
            "npm run dev"
        )
    }

    func testCommandLabelTreatsAForegroundShellAsNoCommand() {
        XCTAssertEqual(
            TerminalSessionPresentation.commandLabel(
                kind: .shell,
                process: "zsh",
                commandLine: "-zsh"
            ),
            ""
        )
        XCTAssertEqual(
            TerminalSessionPresentation.commandLabel(
                kind: .shell,
                process: "/bin/bash",
                commandLine: ""
            ),
            ""
        )
    }

    func testCommandLabelKeepsManagedAgentPurposes() {
        XCTAssertEqual(
            TerminalSessionPresentation.commandLabel(
                kind: .codex,
                process: "node",
                commandLine: "node /usr/local/bin/codex"
            ),
            "codex"
        )
    }

    func testTabTitleUsesCommandAndDirectory() {
        XCTAssertEqual(
            TerminalSessionPresentation.tabTitle(
                customTitle: nil,
                kind: .shell,
                process: "npm",
                commandLine: "npm run dev",
                directory: "/Users/me/Workspace/warren"
            ),
            "npm run dev · warren"
        )
        XCTAssertEqual(
            TerminalSessionPresentation.tabTitle(
                customTitle: nil,
                kind: .shell,
                process: "zsh",
                commandLine: "-zsh",
                directory: "/Users/me/Workspace/warren"
            ),
            "warren"
        )
    }

    func testTabTitlePrefersAMeaningfulGeneratedTitle() {
        XCTAssertEqual(
            TerminalSessionPresentation.tabTitle(
                customTitle: nil,
                title: "Implement API",
                kind: .codex,
                process: "codex",
                commandLine: "codex",
                directory: "/Users/me/Workspace/warren"
            ),
            "Implement API"
        )
        // The generated default repeats the kind, so the directory and command
        // carry the label instead.
        XCTAssertEqual(
            TerminalSessionPresentation.tabTitle(
                customTitle: nil,
                title: "Codex",
                kind: .codex,
                process: "codex",
                commandLine: "codex",
                directory: "/Users/me/Workspace/warren"
            ),
            "codex · warren"
        )
    }

    func testTabTitlePrefersTheUserSetName() {
        XCTAssertEqual(
            TerminalSessionPresentation.tabTitle(
                customTitle: "My Agent",
                kind: .shell,
                process: "zsh",
                commandLine: "zsh",
                directory: "/Users/me/Workspace/warren"
            ),
            "My Agent"
        )
    }

    func testGeneratedDefaultTitleDetection() {
        XCTAssertTrue(
            TerminalSessionPresentation.isGeneratedDefaultTitle("Shell", kind: .shell)
        )
        XCTAssertTrue(
            TerminalSessionPresentation.isGeneratedDefaultTitle("Codex", kind: .codex)
        )
        XCTAssertFalse(
            TerminalSessionPresentation.isGeneratedDefaultTitle("My Agent", kind: .shell)
        )
    }
}
