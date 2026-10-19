import XCTest
@testable import WarrenDomain

/// The command summary the top bar and the sidebar's second line share.
///
/// The examples are the ones the design's rule table lists, so a change to the
/// shortening rule has to change this table too.
final class CommandSummaryTests: XCTestCase {
    func testTheProgramKeepsOnlyItsLastPathSegment() {
        XCTAssertEqual(
            CommandSummary.summarize("/opt/homebrew/bin/tail -f /var/log/relay.log"),
            "tail relay.log"
        )
    }

    func testASubcommandToolKeepsItsSubcommand() {
        XCTAssertEqual(CommandSummary.summarize("git push -u origin feat/x"), "git push")
    }

    func testRunAndExecKeepOneWordMore() {
        XCTAssertEqual(
            CommandSummary.summarize("npm run dev -- --port 3000"),
            "npm run dev"
        )
    }

    func testOtherProgramsKeepTheFirstPositionalArgument() {
        XCTAssertEqual(
            CommandSummary.summarize("python3 scripts/bench.py --n 10"),
            "python3 bench.py"
        )
    }

    func testSudoAndEnvironmentPrefixesAreDropped() {
        XCTAssertEqual(CommandSummary.summarize("sudo git push"), "git push")
        XCTAssertEqual(CommandSummary.summarize("FOO=1 make test"), "make test")
    }

    func testACompoundCommandAnnouncesTheRestIsDropped() {
        XCTAssertEqual(
            CommandSummary.summarize("FOO=1 make test && open out"),
            "make test …"
        )
    }

    func testAFlagValueIsNotMistakenForAPositional() {
        XCTAssertEqual(
            CommandSummary.summarize("tail --lines 20 /var/log/relay.log"),
            "tail relay.log"
        )
    }

    func testAnEmptyCommandSummarizesToNothing() {
        XCTAssertEqual(CommandSummary.summarize(""), "")
        XCTAssertEqual(CommandSummary.summarize("   "), "")
    }

    func testTheSubcommandToolListIsConfigurable() {
        XCTAssertEqual(
            CommandSummary.summarize("frobnicate deploy", subcommandTools: ["frobnicate"]),
            "frobnicate deploy"
        )
    }
}
