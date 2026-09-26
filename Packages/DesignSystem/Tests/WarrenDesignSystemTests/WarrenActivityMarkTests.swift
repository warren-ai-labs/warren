import XCTest
@testable import WarrenDesignSystem

final class WarrenActivityMarkTests: XCTestCase {
    /// The case order is the rollup order, so a Workspace summary can be `max()`
    /// over its Sessions. Pinning it here keeps the ladder from drifting away
    /// from `DESIGN.md` §8.2 when a case is inserted.
    func testPriorityLadderMatchesTheDocumentedOrder() {
        XCTAssertEqual(
            WarrenActivityMark.allCases,
            [.exited, .ready, .working, .attentionUnspecified, .inputNeeded, .approvalNeeded, .failed]
        )
        XCTAssertEqual(WarrenActivityMark.allCases, WarrenActivityMark.allCases.sorted())

        // The coarse ladder the document states, independent of how the
        // attention tier is subdivided.
        XCTAssertGreaterThan(WarrenActivityMark.failed, .approvalNeeded)
        XCTAssertGreaterThan(WarrenActivityMark.attentionUnspecified, .working)
        XCTAssertGreaterThan(WarrenActivityMark.working, .ready)
        XCTAssertGreaterThan(WarrenActivityMark.ready, .exited)
    }

    /// A Session with no Agent bound has no state Warren can observe. Drawing
    /// anything for it would claim knowledge of a process the Host never tracks.
    func testAPlainShellResolvesToNoMark() {
        XCTAssertNil(WarrenActivityMark.resolve(lifecycle: nil, attention: nil))
    }

    /// The Desktop used to render the lifecycle alone, so a `ready` snapshot
    /// carrying an attention payload drew the quiet idle marker on the one row
    /// that needed a person. iOS and the Web already ranked attention first;
    /// this is the rule all three now share.
    func testAttentionOutranksTheLifecycleItArrivesWith() {
        XCTAssertEqual(
            WarrenActivityMark.resolve(lifecycle: .ready, attention: .approval),
            .approvalNeeded
        )
        XCTAssertEqual(
            WarrenActivityMark.resolve(lifecycle: .working, attention: .input),
            .inputNeeded
        )
    }

    /// A turn that already ended badly is the more specific fact, so it keeps
    /// outranking a stale request the Host has not withdrawn yet.
    func testFailedOutranksAttention() {
        XCTAssertEqual(
            WarrenActivityMark.resolve(lifecycle: .failed, attention: .approval),
            .failed
        )
    }

    /// The live Host only ever sets `blocked` by marking attention, so a
    /// `blocked` with no payload comes from an older or partial snapshot. It must
    /// not borrow another kind's word and name a request Warren cannot see.
    func testARequestWarrenCannotNameStaysUnspecified() {
        // `blocked` with no payload: an older Host, or a partial update.
        // An `unnamed` kind beside a stale lifecycle: a wire value this build
        // does not recognize, which is still a real request.
        for (lifecycle, attention) in [
            (WarrenAgentLifecycle.blocked, WarrenAgentAttentionKind?.none),
            (.blocked, .unnamed),
            (.ready, .unnamed),
            (.working, .unnamed),
        ] {
            let mark = WarrenActivityMark.resolve(lifecycle: lifecycle, attention: attention)
            XCTAssertEqual(mark, .attentionUnspecified, "\(lifecycle) + \(String(describing: attention))")
            XCTAssertEqual(mark?.tier, .actionable)
        }
    }

    func testLifecycleWithoutAttentionMapsStraightThrough() {
        XCTAssertEqual(WarrenActivityMark.resolve(lifecycle: .working, attention: nil), .working)
        XCTAssertEqual(WarrenActivityMark.resolve(lifecycle: .ready, attention: nil), .ready)
        XCTAssertEqual(WarrenActivityMark.resolve(lifecycle: .exited, attention: nil), .exited)
    }

    /// A completion notice is news once, not a property of a Session. Reading it
    /// is what retires it; every idle Agent reports `ready`, so without this the
    /// loudest thing on screen was the one state that needs nothing.
    func testASeenCompletionStopsDrawing() {
        XCTAssertEqual(WarrenActivityMark.resolve(lifecycle: .ready, attention: nil), .ready)
        XCTAssertNil(WarrenActivityMark.resolve(lifecycle: .ready, attention: nil, acknowledged: .ready))
    }

    /// An ended Session is a permanent state, not an event. Every Session that
    /// ever ended would otherwise carry a grey dot forever, which is exactly the
    /// background noise this encoding removes.
    func testAnEndedSessionIsNeverNews() {
        XCTAssertEqual(WarrenActivityMark.resolve(lifecycle: .exited, attention: nil), .exited)
        XCTAssertFalse(WarrenActivityMark.exited.isAcknowledgeable)
        XCTAssertFalse(WarrenActivityMark.exited.isDrawn)
        // Nothing about an ended Session becomes actionable later.
        XCTAssertEqual(WarrenActivityMark.resolve(lifecycle: .exited, attention: .approval), .approvalNeeded)
        XCTAssertTrue(WarrenActivityMark.approvalNeeded.isDrawn)
    }

    /// Looking is not answering. An approval or a question is unresolved by being
    /// seen, and a failure does not un-fail because it was visited.
    func testOnlyTheIdleTierCanBeRetiredByBeingSeen() {
        XCTAssertTrue(WarrenActivityMark.ready.isAcknowledgeable)
        // (lifecycle, attention) pairs that produce each non-idle mark.
        let cases: [(WarrenActivityMark, WarrenAgentLifecycle, WarrenAgentAttentionKind?)] = [
            (.approvalNeeded, .blocked, .approval),
            (.inputNeeded, .ready, .input),
            (.attentionUnspecified, .blocked, nil),
            (.failed, .failed, nil),
            (.working, .working, nil),
        ]
        for (mark, lifecycle, attention) in cases {
            XCTAssertFalse(mark.isAcknowledgeable, "\(mark) must not be acknowledgeable")
            XCTAssertEqual(
                WarrenActivityMark.resolve(lifecycle: lifecycle, attention: attention),
                mark,
                "the case list must actually produce \(mark)"
            )
            // Even an explicitly acknowledged matching lifecycle leaves it drawn.
            XCTAssertEqual(
                WarrenActivityMark.resolve(
                    lifecycle: lifecycle,
                    attention: attention,
                    acknowledged: mark.lifecycle
                ),
                mark,
                "\(mark) must survive an acknowledgment of its own lifecycle"
            )
        }
    }

    /// The record self-invalidates: `ready → (seen) → working → ready` must light
    /// up again, because the Agent did something new in between.
    func testAnAcknowledgmentOnlyMatchesItsOwnState() {
        XCTAssertEqual(
            WarrenActivityMark.resolve(lifecycle: .ready, attention: nil, acknowledged: .working),
            .ready
        )
        XCTAssertEqual(
            WarrenActivityMark.resolve(lifecycle: .ready, attention: nil, acknowledged: .exited),
            .ready
        )
    }

    /// Every mark that draws has to be distinguishable, and every one that does
    /// not draw has to be silent. A half-drawn state is the worst of both.
    func testOnlyLiveAndActionableMarksDraw() {
        XCTAssertTrue(WarrenActivityMark.working.isDrawn)
        XCTAssertTrue(WarrenActivityMark.ready.isDrawn)
        for mark in [WarrenActivityMark.approvalNeeded, .inputNeeded, .attentionUnspecified, .failed] {
            XCTAssertTrue(mark.isDrawn, "\(mark) must draw")
        }
        XCTAssertFalse(WarrenActivityMark.exited.isDrawn)
    }

    /// Motion now means exactly one thing: work is progressing. `blocked` used
    /// to pulse as well, which left the pulse marking "not ready, failed, or
    /// exited" — no single fact — and left a halted Session animating for as
    /// long as it waited for a person.
    func testOnlyProgressingWorkAnimates() {
        XCTAssertTrue(WarrenActivityMark.working.isAnimated)
        for mark in WarrenActivityMark.allCases where mark != .working {
            XCTAssertFalse(mark.isAnimated, "\(mark) must not animate")
        }
    }

    func testTiersCoverEveryMarkWithoutOverlap() {
        XCTAssertEqual(WarrenActivityMark.ready.tier, .idle)
        XCTAssertEqual(WarrenActivityMark.exited.tier, .idle)
        XCTAssertEqual(WarrenActivityMark.working.tier, .live)
        for mark in [WarrenActivityMark.attentionUnspecified, .inputNeeded, .approvalNeeded, .failed] {
            XCTAssertEqual(mark.tier, .actionable, "\(mark) must be actionable")
        }
    }

    /// Every mark reaches assistive technology with its own sentence. Two marks
    /// sharing a label would make them indistinguishable to a screen reader now
    /// that the dot carries no glyph to tell them apart.
    func testLabelsAreDistinctPerMark() {
        let words = WarrenActivityMark.allCases.filter(\.isDrawn).map(\.statusWord)
        XCTAssertEqual(Set(words).count, words.count)
        let labels = WarrenActivityMark.allCases.filter(\.isDrawn).map(\.accessibilityLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }

    /// The dot sits in a slot wider than itself, so a row's trailing edge does
    /// not shift when a Session enters or leaves a state.
    func testTheDotSitsInAWiderSlot() {
        let metrics = WarrenActivityMarkMetrics(dotSize: 7)
        XCTAssertGreaterThan(metrics.slotSize, metrics.dotSize)
        XCTAssertEqual(metrics.slotSize, metrics.dotSize * 1.6)
    }
}
