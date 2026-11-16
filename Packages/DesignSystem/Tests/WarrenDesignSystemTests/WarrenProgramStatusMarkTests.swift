import XCTest
@testable import WarrenDesignSystem

final class WarrenProgramStatusMarkTests: XCTestCase {
    func testIdleAndUnknownStatesDrawNothing() {
        XCTAssertNil(WarrenActivityMark.resolve(program: .idle))
        XCTAssertNil(WarrenActivityMark.resolve(program: .unknown))
        XCTAssertNil(WarrenActivityMark.resolve(program: nil))
    }

    func testOnlyAWorkingProgramAnimates() {
        XCTAssertEqual(WarrenActivityMark.resolve(program: .working), .working)
        XCTAssertEqual(WarrenActivityMark.resolve(program: .working)?.isAnimated, true)
        XCTAssertEqual(WarrenActivityMark.resolve(program: .blocked, blockedKind: .permission)?.isAnimated, false)
    }

    func testBlockedKindNamesWhatTheProgramWaitsFor() {
        XCTAssertEqual(WarrenActivityMark.resolve(program: .blocked, blockedKind: .permission), .approvalNeeded)
        XCTAssertEqual(WarrenActivityMark.resolve(program: .blocked, blockedKind: .question), .inputNeeded)
        XCTAssertEqual(WarrenActivityMark.resolve(program: .blocked, blockedKind: .unnamed), .attentionUnspecified)
        XCTAssertEqual(WarrenActivityMark.resolve(program: .blocked), .attentionUnspecified)
    }

    func testDoneDrawsTheFinishedMark() {
        XCTAssertEqual(WarrenActivityMark.resolve(program: .done), .ready)
        XCTAssertEqual(WarrenActivityMark.resolve(program: .done)?.isDrawn, true)
    }

    func testAnErrorStaysFailed() {
        XCTAssertEqual(WarrenActivityMark.resolve(program: .error), .failed)
        XCTAssertEqual(WarrenActivityMark.resolve(program: .error)?.tier, .actionable)
    }

    func testAuthAndUnknownKindsAreUnnamed() {
        XCTAssertEqual(WarrenProgramBlockedKind(protocolKind: "auth"), .unnamed)
        XCTAssertEqual(WarrenProgramBlockedKind(protocolKind: "PERMISSION"), .permission)
        XCTAssertEqual(WarrenProgramBlockedKind(protocolKind: nil), .unnamed)
    }
}
