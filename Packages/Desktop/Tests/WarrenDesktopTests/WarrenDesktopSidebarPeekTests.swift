import XCTest
import WarrenDesignSystem
@testable import WarrenDesktop

/// A clock that records the pending action so the test fires it by hand.
@MainActor
private final class ManualPeekClock: WarrenDesktopSidebarPeekClock {
    struct Pending {
        let delay: Duration
        let action: @MainActor () -> Void
    }

    private(set) var pending: Pending?
    private(set) var schedules = 0

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        pending = Pending(delay: delay, action: action)
        schedules += 1
    }

    func cancelPending() {
        pending = nil
    }

    @discardableResult
    func fire() -> Bool {
        guard let pending else { return false }
        self.pending = nil
        pending.action()
        return true
    }
}

@MainActor
final class WarrenDesktopSidebarPeekTests: XCTestCase {
    private func makeController() -> (WarrenDesktopSidebarPeekController, ManualPeekClock) {
        let clock = ManualPeekClock()
        let controller = WarrenDesktopSidebarPeekController(clock: clock)
        controller.setCollapsed(true)
        return (controller, clock)
    }

    func testHoveringTheButtonRevealsAfterTheDwell() {
        let (controller, clock) = makeController()

        controller.setPointer(.sidebarButton, isInside: true)
        XCTAssertEqual(clock.pending?.delay, .milliseconds(250))
        XCTAssertFalse(controller.isPeeking, "The reveal waits out the dwell")

        clock.fire()
        XCTAssertTrue(controller.isPeeking)
    }

    func testTheEdgeRevealsOnTheSameDwell() {
        let (controller, clock) = makeController()

        controller.setPointer(.edge, isInside: true)
        XCTAssertEqual(clock.pending?.delay, .milliseconds(250))
        XCTAssertFalse(controller.isPeeking)

        clock.fire()
        XCTAssertTrue(controller.isPeeking)
    }

    func testLeavingThePanelHidesAfterTheGracePeriod() {
        let (controller, clock) = makeController()
        controller.show()

        controller.setPointer(.panel, isInside: false)
        XCTAssertEqual(clock.pending?.delay, .milliseconds(300))
        XCTAssertTrue(controller.isPeeking, "The panel stays through the grace period")

        clock.fire()
        XCTAssertFalse(controller.isPeeking)
    }

    func testReturningDuringTheGracePeriodKeepsThePanel() {
        let (controller, clock) = makeController()
        controller.show()

        controller.setPointer(.panel, isInside: true)
        controller.setPointer(.panel, isInside: false)
        XCTAssertNotNil(clock.pending)

        controller.setPointer(.panel, isInside: true)
        XCTAssertNil(clock.pending, "Coming back cancels the pending hide")
        XCTAssertTrue(controller.isPeeking)

        clock.fire()
        XCTAssertTrue(controller.isPeeking, "A cancelled hide cannot fire")
    }

    func testABackgroundWindowNeverPeeks() {
        let (controller, clock) = makeController()
        controller.setWindowKey(false)

        controller.setPointer(.sidebarButton, isInside: true)
        XCTAssertNil(clock.pending)
        clock.fire()
        XCTAssertFalse(controller.isPeeking)

        controller.show()
        XCTAssertFalse(controller.isPeeking, "The keyboard entry obeys the key-window gate too")

        // Losing the keyboard retires a panel that is already open.
        controller.setWindowKey(true)
        controller.show()
        XCTAssertTrue(controller.isPeeking)
        controller.setWindowKey(false)
        XCTAssertFalse(controller.isPeeking)
    }

    func testAnExpandedSidebarNeverPeeks() {
        let (controller, clock) = makeController()
        controller.setCollapsed(false)

        controller.setPointer(.edge, isInside: true)
        XCTAssertNil(clock.pending)
        controller.show()
        XCTAssertFalse(controller.isPeeking)
    }

    func testTheKeyboardRevealsWithoutADwell() {
        let (controller, _) = makeController()

        controller.show()
        XCTAssertTrue(controller.isPeeking)
    }

    func testEscapeHoldsUntilThePointerLeaves() {
        let (controller, clock) = makeController()
        // The pointer is resting on the panel when Esc dismisses it.
        controller.setPointer(.panel, isInside: true)
        controller.show()

        controller.dismiss(suppressingUntilPointerLeaves: true)
        XCTAssertFalse(controller.isPeeking)

        // The same pointer is still reported inside: the reveal must not re-arm.
        controller.setPointer(.panel, isInside: true)
        XCTAssertNil(clock.pending)
        XCTAssertFalse(controller.isPeeking)

        // Leaving clears the hold, so the next entry reveals again.
        controller.setPointer(.panel, isInside: false)
        controller.setPointer(.panel, isInside: true)
        XCTAssertNotNil(clock.pending)
        clock.fire()
        XCTAssertTrue(controller.isPeeking)
    }

    func testSelectingASessionHidesImmediately() {
        let (controller, clock) = makeController()
        controller.show()

        controller.dismiss()
        XCTAssertNil(clock.pending)
        XCTAssertFalse(controller.isPeeking)
    }

    func testACollapsedStateRoundTripsThroughItsInitializer() {
        var state = WarrenDesktopSidebarState(width: 320)
        state.toggleCollapsed()
        XCTAssertEqual(state.renderedWidth, 0)

        // What the app writes to, and reads from, its defaults.
        let restored = WarrenDesktopSidebarState(
            width: state.width,
            isCollapsed: state.isCollapsed
        )
        XCTAssertTrue(restored.isCollapsed)
        XCTAssertEqual(restored.width, 320)
        XCTAssertEqual(restored.renderedWidth, 0)

        // A stored width below the snap threshold cannot revive a rail.
        let snapped = WarrenDesktopSidebarState(width: 40, isCollapsed: false)
        XCTAssertEqual(snapped.width, WarrenLayoutMetrics.sidebarExpandedWidth)
        XCTAssertFalse(snapped.isCollapsed)
    }
}

final class WarrenDesktopSidebarAttentionTests: XCTestCase {
    func testWorkingAndReadyNeverDrawTheDot() {
        XCTAssertNil(
            WarrenDesktopSidebarAttention.mark(among: [.working, .ready, .exited, nil])
        )
    }

    func testARequestDrawsTheDot() {
        XCTAssertEqual(
            WarrenDesktopSidebarAttention.mark(among: [.working, .inputNeeded]),
            .inputNeeded
        )
        XCTAssertEqual(
            WarrenDesktopSidebarAttention.mark(among: [.approvalNeeded, .attentionUnspecified]),
            .approvalNeeded
        )
    }

    func testAFailureOutranksEveryRequest() {
        XCTAssertEqual(
            WarrenDesktopSidebarAttention.mark(among: [.inputNeeded, .failed, .approvalNeeded]),
            .failed
        )
    }

    func testAnEmptyListDrawsNothing() {
        XCTAssertNil(WarrenDesktopSidebarAttention.mark(among: []))
    }

    func testDrawsMatchesTheTierThatNeedsAPerson() {
        XCTAssertTrue(WarrenDesktopSidebarAttention.draws(.failed))
        XCTAssertTrue(WarrenDesktopSidebarAttention.draws(.inputNeeded))
        XCTAssertFalse(WarrenDesktopSidebarAttention.draws(.working))
        XCTAssertFalse(WarrenDesktopSidebarAttention.draws(.ready))
    }
}
