import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenObservation
import XCTest
@testable import WarrenDesktop

/// The stopped banner at its real size, mounted in a hosting view with no
/// window: it is what tells a person why a Session is not running and which one
/// action continues it, so both the copy and the button are asserted here rather
/// than only in the rule's unit test.
final class WarrenDesktopStoppedBannerRenderTests: XCTestCase {
    private struct Harness {
        let hosting: NSHostingView<AnyView>
        let recorder: WarrenSemanticRecorder
    }

    @MainActor
    private func mount(_ banner: WarrenDesktopStoppedBanner) -> Harness {
        let recorder = WarrenSemanticRecorder()
        let view = banner
            .frame(width: 640)
            .background(WarrenColorTokens.resolved(for: .dark, material: .opaque).workbenchCardFill)
            .environment(\.warrenSemanticRecorder, recorder)
            .environment(\.colorScheme, .dark)
            .warrenSemanticObservationRoot(recorder: recorder)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 70)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        return Harness(hosting: hosting, recorder: recorder)
    }

    @MainActor
    func testAResumableStoppedSessionSaysWhyItStoppedAndOffersResume() throws {
        var resumed = false
        let harness = mount(
            WarrenDesktopStoppedBanner(
                reason: .runtimeMissing,
                action: .resume,
                isBusy: false,
                failure: nil,
                historyFailure: nil,
                onAction: { resumed = true },
                onRetryHistory: {}
            )
        )
        let nodes = Dictionary(
            harness.recorder.snapshot().nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let banner = nodes["stopped-banner"]
        XCTAssertEqual(banner?.label, "Stopped")
        XCTAssertEqual(banner?.value, WarrenDesktopEndReason.runtimeMissing.detail)
        XCTAssertEqual(nodes["stopped-banner.action"]?.label, "Resume")
        XCTAssertEqual(nodes["stopped-banner.retry"], nil)

        try harness.recorder.perform(.press, on: "stopped-banner.action")
        XCTAssertTrue(resumed)
    }

    @MainActor
    func testResumeAllAppearsOnlyWhenOtherSessionsCanResume() throws {
        func nodes(count: Int, onResumeAll: @escaping () -> Void = {}) -> (Harness, [String: WarrenSemanticNode]) {
            let harness = mount(
                WarrenDesktopStoppedBanner(
                    reason: .runtimeMissing,
                    action: .resume,
                    isBusy: false,
                    failure: nil,
                    historyFailure: nil,
                    onAction: {},
                    onRetryHistory: {},
                    resumeAllCount: count,
                    onResumeAll: onResumeAll
                )
            )
            return (harness, Dictionary(
                harness.recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ))
        }

        XCTAssertNil(nodes(count: 0).1["stopped-banner.resume-all"])

        var resumedAll = false
        let (harness, shown) = nodes(count: 2) { resumedAll = true }
        XCTAssertEqual(shown["stopped-banner.resume-all"]?.label, "Resume All")
        XCTAssertEqual(shown["stopped-banner.resume-all"]?.value, "2")
        XCTAssertEqual(shown["stopped-banner.action"]?.label, "Resume")
        try harness.recorder.perform(.press, on: "stopped-banner.resume-all")
        XCTAssertTrue(resumedAll)
    }

    @MainActor
    func testAStoppedShellOffersRestartAndNoResume() {
        let harness = mount(
            WarrenDesktopStoppedBanner(
                reason: .processExited,
                action: .restart,
                isBusy: false,
                failure: nil,
                historyFailure: nil,
                onAction: {},
                onRetryHistory: {}
            )
        )
        let nodes = Dictionary(
            harness.recorder.snapshot().nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(nodes["stopped-banner.action"]?.label, "Restart")
        XCTAssertEqual(
            nodes["stopped-banner"]?.value,
            WarrenDesktopEndReason.processExited.detail
        )
    }

    /// A stopped Session with nothing left to continue still explains itself and
    /// offers no action rather than a button that cannot work.
    @MainActor
    func testAStoppedSessionWithNothingToContinueOffersNoAction() {
        let harness = mount(
            WarrenDesktopStoppedBanner(
                reason: .unknown,
                action: nil,
                isBusy: false,
                failure: nil,
                historyFailure: nil,
                onAction: {},
                onRetryHistory: {}
            )
        )
        let nodes = Dictionary(
            harness.recorder.snapshot().nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertNotNil(nodes["stopped-banner"])
        XCTAssertNil(nodes["stopped-banner.action"])
    }

    /// A read that failed replaces the reason line and offers Retry, so the pane
    /// never looks empty for a reason the person cannot act on.
    @MainActor
    func testAFailedHistoryReadOffersRetry() throws {
        var retried = false
        let harness = mount(
            WarrenDesktopStoppedBanner(
                reason: .runtimeMissing,
                action: .resume,
                isBusy: false,
                failure: nil,
                historyFailure: "Timed out",
                onAction: {},
                onRetryHistory: { retried = true }
            )
        )
        let nodes = Dictionary(
            harness.recorder.snapshot().nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(nodes["stopped-banner"]?.value, "The last output could not be read. Timed out")
        XCTAssertEqual(nodes["stopped-banner.retry"]?.label, "Retry output")

        try harness.recorder.perform(.press, on: "stopped-banner.retry")
        XCTAssertTrue(retried)
    }
}
