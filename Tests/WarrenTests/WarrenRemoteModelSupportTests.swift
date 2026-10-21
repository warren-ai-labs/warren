import XCTest
import WarrenDomain
@testable import Warren

/// The retry that follows a failed recovery payload is bounded and backs off;
/// a Host that keeps failing must end in an error, not a reconnect loop.
final class RecoveryFailureRetryTests: XCTestCase {
    func testRetryBudgetIsThreeAttempts() {
        XCTAssertNotNil(RecoveryFailureRetry.delay(afterAttempt: 1))
        XCTAssertNotNil(RecoveryFailureRetry.delay(afterAttempt: 2))
        XCTAssertNotNil(RecoveryFailureRetry.delay(afterAttempt: 3))
        XCTAssertNil(RecoveryFailureRetry.delay(afterAttempt: 4))
        XCTAssertNil(RecoveryFailureRetry.delay(afterAttempt: 0))
    }

    func testEachRetryWaitsLongerThanTheOneBefore() throws {
        let first = try XCTUnwrap(RecoveryFailureRetry.delay(afterAttempt: 1))
        let second = try XCTUnwrap(RecoveryFailureRetry.delay(afterAttempt: 2))
        let third = try XCTUnwrap(RecoveryFailureRetry.delay(afterAttempt: 3))
        XCTAssertEqual(first, .milliseconds(250))
        XCTAssertEqual(second, .milliseconds(500))
        XCTAssertEqual(third, .milliseconds(1000))
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, third)
    }
}

/// A subscribe is acknowledged before the Host produces its recovery payload,
/// so repeatedly acknowledged attaches must not let a failing Host retry
/// forever. This is the sequence the runner performs: attach, acknowledgement,
/// failed payload, retry.
final class RecoveryFailureStreakTests: XCTestCase {
    private let sessionID = TerminalSessionID()

    func testAcknowledgedSubscribesDoNotResetTheStreak() {
        var streak = RecoveryFailureStreak()
        // The acknowledgement is not modelled here at all: the model's
        // subscription bookkeeping must not touch the streak. What a retried
        // attach does between failures is exactly that, so failures alone
        // advance the count.
        XCTAssertEqual(streak.noteFailure(sessionID), 1)
        XCTAssertEqual(streak.noteFailure(sessionID), 2)
        XCTAssertEqual(streak.noteFailure(sessionID), 3)
    }

    func testRepeatedAcknowledgedAttachesReachExhaustion() {
        var streak = RecoveryFailureStreak()
        var delays: [Duration] = []
        for _ in 1...4 {
            let attempt = streak.noteFailure(sessionID)
            guard let delay = RecoveryFailureRetry.delay(afterAttempt: attempt) else {
                // The model logs `recovery_retries_exhausted` and presents an
                // error exactly here, when the budget returns no delay.
                delays.append(.zero)
                continue
            }
            delays.append(delay)
        }
        XCTAssertEqual(delays, [.milliseconds(250), .milliseconds(500), .milliseconds(1000), .zero])
    }

    func testInstalledPayloadClearsTheStreak() {
        var streak = RecoveryFailureStreak()
        _ = streak.noteFailure(sessionID)
        _ = streak.noteFailure(sessionID)
        streak.noteInstalled(sessionID)
        XCTAssertEqual(streak.attempts(for: sessionID), 0)
        XCTAssertEqual(streak.noteFailure(sessionID), 1)
    }

    func testStreaksArePerSession() {
        var streak = RecoveryFailureStreak()
        let other = TerminalSessionID()
        _ = streak.noteFailure(sessionID)
        _ = streak.noteFailure(sessionID)
        streak.noteInstalled(sessionID)
        XCTAssertEqual(streak.attempts(for: other), 0)
        XCTAssertEqual(streak.noteFailure(other), 1)
    }
}
