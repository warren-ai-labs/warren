import XCTest
@testable import WarrenTransport

/// Mirrors the presenter cases in `Web/src/connection.test.js` so both clients
/// keep the same promise: degrade slowly, recover instantly.
final class WarrenConnectionPresentationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testSubSecondFlapNeverReachesTheUser() {
        var presenter = WarrenConnectionPresenter()
        presenter.markLive()
        presenter.markUnsettled(detail: "Reconnecting…", at: start)
        XCTAssertEqual(presenter.presentation, .settling)

        presenter.refresh(at: start.addingTimeInterval(0.4))
        XCTAssertEqual(presenter.presentation, .settling)

        presenter.markLive()
        XCTAssertEqual(presenter.presentation, .live)
        XCTAssertNil(presenter.unsettledSince)
    }

    func testLossOutlastingTheGraceIsAnnouncedWithItsReason() {
        var presenter = WarrenConnectionPresenter()
        presenter.markLive()
        presenter.markUnsettled(detail: "Reconnecting…", at: start)

        let grace = warrenConnectionSettleGrace
        XCTAssertFalse(presenter.refresh(at: start.addingTimeInterval(grace - 0.2)))
        XCTAssertTrue(presenter.refresh(at: start.addingTimeInterval(grace + 0.1)))
        XCTAssertEqual(presenter.presentation, .interrupted)
        XCTAssertEqual(presenter.detail, "Reconnecting…")
    }

    func testAReconnectThatSucceedsInsideTheGraceStaysSilent() {
        var presenter = WarrenConnectionPresenter()
        presenter.markLive()
        presenter.markUnsettled(detail: "Reconnecting…", at: start)

        // A measured worst case against a real Relay over a 160ms RTT link: the
        // socket is replaced end to end in 1.3s. Nothing should be announced for
        // a recovery that was already working.
        XCTAssertFalse(presenter.refresh(at: start.addingTimeInterval(1.3)))
        XCTAssertEqual(presenter.presentation, .settling)
        presenter.markLive()
        XCTAssertEqual(presenter.presentation, .live)
    }

    func testAReconnectLoopCannotPostponeTheNoticeForever() {
        var presenter = WarrenConnectionPresenter()
        presenter.markLive()

        // Each retry re-reports "unsettled". The deadline must stay pinned to the
        // first attempt, or a fast retry loop would never tell the user anything.
        var now = start
        let attempts = Int((warrenConnectionSettleGrace / 0.4).rounded(.up)) + 1
        for _ in 0..<attempts {
            presenter.markUnsettled(detail: "Reconnecting…", at: now)
            now = now.addingTimeInterval(0.4)
            presenter.refresh(at: now)
        }
        XCTAssertEqual(presenter.presentation, .interrupted)
    }

    func testKnownHostAbsenceSkipsTheGrace() {
        var presenter = WarrenConnectionPresenter()
        presenter.markLive()
        presenter.markLost(detail: "Mac is offline", at: start)

        XCTAssertEqual(presenter.presentation, .interrupted)
        XCTAssertEqual(presenter.detail, "Mac is offline")
        XCTAssertNil(presenter.timeUntilInterrupted(from: start))
    }

    func testRecoveryFromAnAnnouncedInterruptionIsImmediate() {
        var presenter = WarrenConnectionPresenter()
        presenter.markLost(detail: "Mac is offline", at: start)
        XCTAssertTrue(presenter.markLive())
        XCTAssertEqual(presenter.presentation, .live)
        XCTAssertEqual(presenter.detail, "")
    }

    func testGenericRetryDoesNotOverwriteASpecificReason() {
        var presenter = WarrenConnectionPresenter()
        presenter.markLost(detail: "unauthorized", at: start)
        presenter.markUnsettled(detail: "Reconnecting…", at: start.addingTimeInterval(0.2))

        XCTAssertEqual(presenter.presentation, .interrupted)
        XCTAssertEqual(presenter.detail, "unauthorized")
    }

    func testColdStartIsSettlingSoTheFirstConnectCannotFlashOffline() {
        let presenter = WarrenConnectionPresenter()
        XCTAssertEqual(presenter.presentation, .settling)
        XCTAssertNil(presenter.unsettledSince)
        XCTAssertNil(presenter.timeUntilInterrupted(from: start))
    }

    func testHostOfflineDetailReadsAsASentence() {
        XCTAssertEqual(
            warrenHostOfflineDetail(
                hostName: "Mac",
                lastSeenAt: start.addingTimeInterval(-180),
                now: start
            ),
            "Mac is offline · last seen 3 minutes ago"
        )
        XCTAssertEqual(
            warrenHostOfflineDetail(hostName: "Mac", lastSeenAt: nil, now: start),
            "Mac is offline"
        )
        XCTAssertEqual(
            warrenHostOfflineDetail(hostName: nil, lastSeenAt: nil, now: start),
            "Host is offline"
        )
    }

    func testUsableTransportStatesMatchTheDocumentedContract() {
        XCTAssertTrue(WarrenRemoteConnectionState.connected.isUsableForPresentation)
        for state: WarrenRemoteConnectionState in [.connecting, .reconnecting, .disconnected, .stopped] {
            XCTAssertFalse(state.isUsableForPresentation, "\(state) must not read as usable")
        }
    }
}
