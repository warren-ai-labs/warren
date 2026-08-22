import XCTest
@testable import Warren

final class WarrenTerminalOpenRequestTests: XCTestCase {
    func testParsesTerminalGroupName() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal?group=Inbox")!)
        )

        XCTAssertEqual(request.group, "Inbox")
        XCTAssertNil(request.project)
        XCTAssertNil(request.workspace)
        XCTAssertNil(request.session)
    }

    func testDecodesTerminalGroupName() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal?group=Daily%20Shell")!)
        )

        XCTAssertEqual(request.group, "Daily Shell")
    }

    func testParsesProjectWorkspaceAndSessionSelectors() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(
                string: "warren://terminal?project=Warren&workspace=feature&session=Claude%20Code"
            )!)
        )

        XCTAssertEqual(request.project, "Warren")
        XCTAssertEqual(request.workspace, "feature")
        XCTAssertEqual(request.session, "Claude Code")
        XCTAssertTrue(request.hasResourceTarget)
    }

    func testParsesResourceHostPathSelector() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://workspace/feature")!)
        )

        XCTAssertEqual(request.workspace, "feature")
        XCTAssertNil(request.project)
        XCTAssertNil(request.session)
    }

    func testParsesResourcePathFromTerminalHost() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(
                string: "warren://terminal/project/Warren/workspace/feature/session/Claude"
            )!)
        )

        XCTAssertEqual(request.project, "Warren")
        XCTAssertEqual(request.workspace, "feature")
        XCTAssertEqual(request.session, "Claude")
    }

    func testMissingGroupUsesDefaultTerminalGroup() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal")!)
        )

        XCTAssertNil(request.group)
    }

    func testRejectsUnknownURL() {
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "https://example.com")!))
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "warren://project")!))
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "warren://unknown/thing")!))
    }
}
