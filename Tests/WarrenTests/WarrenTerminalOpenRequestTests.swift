import XCTest
@testable import Warren

final class WarrenTerminalOpenRequestTests: XCTestCase {
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

    func testBareTerminalLinkHasNoResourceTarget() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal")!)
        )

        XCTAssertFalse(request.hasResourceTarget)
    }

    func testIgnoresRemovedGroupSelector() throws {
        let request = try XCTUnwrap(
            WarrenTerminalOpenRequest(url: URL(string: "warren://terminal?group=Shell")!)
        )

        XCTAssertFalse(request.hasResourceTarget)
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "warren://group/Shell")!))
    }

    func testRejectsUnknownURL() {
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "https://example.com")!))
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "warren://project")!))
        XCTAssertNil(WarrenTerminalOpenRequest(url: URL(string: "warren://unknown/thing")!))
    }
}
