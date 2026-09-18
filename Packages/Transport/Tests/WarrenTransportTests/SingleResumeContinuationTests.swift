import Foundation
import XCTest
@testable import WarrenTransport

/// Pins the resume-once contract that keeps a double-invoked URLSession ping
/// completion from trapping the process during a Relay reconnect.
final class SingleResumeContinuationTests: XCTestCase {
    func testSecondResumeIsIgnoredAfterSuccess() async throws {
        let resumer = SingleResumeContinuation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            resumer.attach(continuation)
            resumer.succeed()
            // A racing cancellation callback must be a no-op, not a trap.
            resumer.fail(CancellationError())
        }
    }

    func testFirstFailureWins() async {
        let resumer = SingleResumeContinuation()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resumer.attach(continuation)
                resumer.fail(URLError(.cancelled))
                resumer.succeed()
            }
            XCTFail("expected the first failure to win")
        } catch {
            XCTAssertEqual(error as? URLError, URLError(.cancelled))
        }
    }

    func testCancellationBeforeAttachFailsInsteadOfLeaking() async {
        let resumer = SingleResumeContinuation()
        resumer.fail(CancellationError())
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resumer.attach(continuation)
            }
            XCTFail("expected the cancelled continuation to fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
