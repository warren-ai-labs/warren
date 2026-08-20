import XCTest
@testable import WarrenDesignSystem

final class WarrenDesignSystemTests: XCTestCase {
    func testSidebarWidthPolicySnapsAndClamps() {
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 119), 52)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 220), 220)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 320), 320)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 401), 400)
    }

    func testInteractionStatePriority() {
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: true, pressed: true, selected: true, focused: true, hovered: true),
            .disabled
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: true, selected: true, focused: true, hovered: true),
            .pressed
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: true, focused: true, hovered: true),
            .selected
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: false, focused: true, hovered: true),
            .focused
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: false, focused: false, hovered: true),
            .hovered
        )
    }

    func testMotionPolicyDisablesAnimationsForReducedMotion() {
        XCTAssertNil(WarrenMotion.animation(.feedback, reduceMotion: true))
        XCTAssertNil(WarrenMotion.animation(.stateChange, reduceMotion: true))
        XCTAssertNil(WarrenMotion.animation(.overlay, reduceMotion: true))
        XCTAssertNotNil(WarrenMotion.animation(.feedback, reduceMotion: false))
        XCTAssertLessThan(WarrenMotion.feedbackDuration, WarrenMotion.overlayDuration)
    }

    func testBrailleSpinnerFrameDurationFormsAnEightStepCycle() {
        XCTAssertEqual(WarrenMotion.spinnerFrameDuration, 0.09)
        XCTAssertEqual(WarrenMotion.spinnerFrameDuration * 8, 0.72, accuracy: 0.0001)
    }

    func testPresentationStackTracksTopmostRole() {
        var stack = WarrenPresentationStack()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertNil(stack.top)
        stack.push(.popover)
        stack.push(.modal)
        XCTAssertEqual(stack.top, .modal)
        XCTAssertEqual(stack.popTop(), .modal)
        XCTAssertEqual(stack.top, .popover)
        XCTAssertEqual(stack.popTop(), .popover)
        XCTAssertTrue(stack.isEmpty)
    }

    func testModalNeverDismissesOnBackdrop() {
        let stack = WarrenPresentationStack()
        XCTAssertFalse(stack.allowsBackdropDismiss(role: .modal, hasEdits: false))
        XCTAssertFalse(stack.allowsBackdropDismiss(role: .modal, hasEdits: true))
    }

    func testSheetBackdropDismissRequiresNoUncommittedEdits() {
        let stack = WarrenPresentationStack()
        XCTAssertFalse(stack.allowsBackdropDismiss(role: .sheet, hasEdits: true))
        XCTAssertTrue(stack.allowsBackdropDismiss(role: .sheet, hasEdits: false))
    }

    func testCommandPopoverAndMenuDismissOnBackdrop() {
        let stack = WarrenPresentationStack()
        for role in [WarrenPresentationRole.commandSurface, .popover, .menu] {
            XCTAssertTrue(stack.allowsBackdropDismiss(role: role, hasEdits: true), "\(role)")
        }
    }

    func testEscapeDismissalIsAllowedForInteractiveSurfacesOnly() {
        let stack = WarrenPresentationStack()
        for role in [WarrenPresentationRole.modal, .sheet, .commandSurface, .popover, .menu] {
            XCTAssertTrue(stack.allowsEscapeDismiss(role: role), "\(role)")
        }
        XCTAssertFalse(stack.allowsEscapeDismiss(role: .status))
        XCTAssertFalse(stack.allowsEscapeDismiss(role: .inline))
    }

}
