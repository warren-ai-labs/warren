import AppKit
import WarrenDomain
import XCTest
@testable import WarrenDesktop

/// The icon a pane shows is named by its Agent when there is one, and by its
/// foreground process otherwise.
@MainActor
final class WarrenDesktopAppIconTests: XCTestCase {
    func testToolsWithoutAMarkBorrowTheirEcosystems() {
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "npx", commandLine: "npx vite"), .npm)
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "cargo", commandLine: "cargo test"), .rust)
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "gradlew", commandLine: "./gradlew assembleDebug"), .gradle)
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "pip3", commandLine: "pip3 install -e ."), .python)
    }

    func testProcessNamesAreReadFromPathsAndLoginShells() {
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "/opt/homebrew/bin/bun", commandLine: ""), .bun)
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "-zsh", commandLine: ""), .zsh)
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "python3.12", commandLine: ""), .python)
    }

    /// `npm run dev` reports `node` as its process; the command line names the
    /// tool the person actually typed.
    func testARuntimeDefersToTheLauncherOnItsCommandLine() {
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "node", commandLine: "npm run dev"), .npm)
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "node", commandLine: "node server.js"), .node)
        XCTAssertEqual(WarrenDesktopProgram.resolve(process: "python3", commandLine: "uv run pytest"), .uv)
    }

    func testUnknownProcessesHaveNoProgram() {
        XCTAssertNil(WarrenDesktopProgram.resolve(process: "htop", commandLine: "htop"))
        XCTAssertNil(WarrenDesktopProgram.resolve(process: "", commandLine: ""))
    }

    func testAnAgentBindingWinsOverTheProcess() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "claude",
            kind: .shell,
            agentProvider: .claude,
            runtimeProcess: "node",
            runtimeCommandLine: "node /usr/local/bin/claude"
        )
        XCTAssertEqual(WarrenDesktopAppIcon.resolve(session), .agent(.claude))
    }

    func testAShellRunningAProgramShowsTheProgram() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "zsh",
            runtimeProcess: "cargo",
            runtimeCommandLine: "cargo run"
        )
        XCTAssertEqual(WarrenDesktopAppIcon.resolve(session), .program(.rust))
    }

    func testEveryProgramShipsValidArtwork() throws {
        for program in WarrenDesktopProgram.allCases {
            let image = try XCTUnwrap(
                WarrenPresetIconCache.shared.image(named: program.resourceName, template: true),
                "Missing artwork for \(program)"
            )
            XCTAssertTrue(image.isValid, "Expected \(program.resourceName) to decode")
        }
    }

    func testAnUnknownProcessIsDrawnAsItsShell() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "fish",
            runtimeProcess: "htop",
            runtimeCommandLine: "htop"
        )
        XCTAssertEqual(WarrenDesktopAppIcon.resolve(session), .program(.fish))
    }

    func testEveryAgentWithArtworkShipsIt() throws {
        let kinds: [TerminalSessionKind] = [.claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae]
        for kind in kinds {
            let icon = WarrenDesktopAppIcon(kind: kind)
            let name = try XCTUnwrap(icon.resourceName, "No artwork named for \(kind)")
            let image = try XCTUnwrap(
                WarrenPresetIconCache.shared.image(named: name, template: icon.drawsWhiteGlyph),
                "Missing artwork for \(kind)"
            )
            XCTAssertTrue(image.isValid, "Expected \(name) to decode")
        }
    }

    /// A brand mark drawn white on its tile and the same file drawn in colour
    /// by the preset menu are two cache entries, so neither flips the other.
    func testTemplateAndAuthoredCopiesAreCachedApart() {
        let cache = WarrenPresetIconCache { _ in NSImage(size: NSSize(width: 12, height: 12)) }
        let tinted = cache.image(named: "preset-claude", template: true)
        let authored = cache.image(named: "preset-claude")
        XCTAssertEqual(tinted?.isTemplate, true)
        XCTAssertEqual(authored?.isTemplate, false)
        XCTAssertFalse(tinted === authored)
    }
}
