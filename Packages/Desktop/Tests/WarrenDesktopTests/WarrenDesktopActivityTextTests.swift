import XCTest
@testable import WarrenDesktop

/// The activity line as the sidebar draws it.
///
/// The rules come from the sidebar design: a path keeps its last segment, a
/// `--flag value` pair either goes away or becomes the object of the line, and a
/// compound command keeps its first command and the shape of the rest. What the
/// row cannot show is still in the model, so every case here is about reading,
/// not about what Warren knows.
final class WarrenDesktopActivityTextTests: XCTestCase {
    func testAPathKeepsOnlyItsLastSegment() {
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran head -100 /Users/me/Downloads/relay.log"),
            "Ran head -100 …/relay.log"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Read Sources/Warren/Row.swift"),
            "Read …/Row.swift"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Edited PopoverMenu.swift"),
            "Edited PopoverMenu.swift",
            "A bare file name has nothing to shorten"
        )
    }

    func testAFlagThatNamesTheObjectBecomesTheObject() {
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Running swift build --package-path Packages/WarrenKit"),
            "Running swift build · WarrenKit"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran swift test --filter Sidebar"),
            "Ran swift test",
            "A flag that only configures the run is not worth the width"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran swift test --filter=Sidebar"),
            "Ran swift test"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran git commit --no-verify -m fix"),
            "Ran git commit --no-verify -m fix",
            "A flag with no value is not a pair, and does not eat the next flag"
        )
    }

    func testACompoundCommandKeepsItsFirstCommandAndItsLastWord() {
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened(
                "Running uptime; for i in $(seq 1 8); do (sleep 1; echo $i) & done"
            ),
            "Running uptime; for … done"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran swift build && swift test"),
            "Ran swift build && … test"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran cat a.log | tail -5"),
            "Ran cat a.log | … -5"
        )
    }

    func testAURLIsNotAPathToShorten() {
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Fetched https://example.com/docs/sidebar"),
            "Fetched https://example.com/docs/sidebar"
        )
    }

    func testALaunchPrefixIsDropped() {
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("sudo make install"),
            "make install"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("FOO=1 BAR=2 npm run dev"),
            "npm run dev"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("sudo FOO=1 npm run dev"),
            "npm run dev"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran env FOO=1 tail -f /var/log/relay.log"),
            "Ran env FOO=1 tail -f …/relay.log",
            "An assignment that is an argument is not a launch prefix"
        )
    }

    func testALaunchPrefixBehindAnAgentsVerbIsDropped() {
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran T=76acbab4c47d2ba5 go vet"),
            "Ran go vet"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Running sudo FOO=1 npm run dev"),
            "Running npm run dev"
        )
        XCTAssertEqual(
            WarrenDesktopActivityText.shortened("Ran FOO=1"),
            "Ran FOO=1",
            "A line that is only a prefix keeps it rather than going blank"
        )
    }
}
