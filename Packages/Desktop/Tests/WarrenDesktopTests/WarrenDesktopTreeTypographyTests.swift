import SwiftUI
import XCTest
@testable import WarrenDesktop

/// A group name is drawn script by script, so a Chinese name and an English
/// name share one optical size instead of the Chinese one reading a step
/// larger. These tests hold the cut points, since the fonts hang off them.
final class WarrenDesktopTreeTypographyTests: XCTestCase {
    private func runs(_ name: String) -> [(text: String, isWide: Bool)] {
        WarrenDesktopTreeTypography.scriptRuns(name)
    }

    func testLatinNameIsOneNarrowRun() {
        let runs = runs("go-gateway")

        XCTAssertEqual(runs.map(\.text), ["go-gateway"])
        XCTAssertEqual(runs.map(\.isWide), [false])
    }

    func testChineseNameIsOneWideRun() {
        let runs = runs("内部工具")

        XCTAssertEqual(runs.map(\.text), ["内部工具"])
        XCTAssertEqual(runs.map(\.isWide), [true])
    }

    func testNameSplitsAtTheScriptChange() {
        let runs = runs("PC 端社区交互")

        XCTAssertEqual(runs.map(\.text), ["PC ", "端社区交互"])
        XCTAssertEqual(runs.map(\.isWide), [false, true])
    }

    func testAlternatingScriptsKeepTheirOrder() {
        let runs = runs("端-go端")

        XCTAssertEqual(runs.map(\.text), ["端", "-go", "端"])
        XCTAssertEqual(runs.map(\.isWide), [true, false, true])
    }

    func testDigitsAndCustomIDsStayLatin() {
        let runs = runs("1143363994005063740")

        XCTAssertEqual(runs.map(\.text), ["1143363994005063740"])
        XCTAssertEqual(runs.map(\.isWide), [false])
    }

    func testChinesePunctuationAndFullwidthFormsAreWide() {
        XCTAssertEqual(runs("端，。").map(\.isWide), [true])
        XCTAssertEqual(runs("ＡＢ").map(\.isWide), [true])
        XCTAssertEqual(runs("端,A").map(\.text), ["端", ",A"])
        XCTAssertEqual(runs("端,A").map(\.isWide), [true, false])
    }

    func testWideScriptTakesTheSmallerSize() {
        XCTAssertEqual(WarrenDesktopTreeTypography.groupNameSize, 13.5)
        XCTAssertEqual(WarrenDesktopTreeTypography.groupNameWideSize, 13)
        XCTAssertLessThan(
            WarrenDesktopTreeTypography.groupNameWideSize,
            WarrenDesktopTreeTypography.groupNameSize
        )
    }
}
