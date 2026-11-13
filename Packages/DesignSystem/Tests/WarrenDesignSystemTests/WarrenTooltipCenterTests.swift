#if os(macOS)
import XCTest
@testable import WarrenDesignSystem

@MainActor
final class WarrenTooltipCenterTests: XCTestCase {
    private func tip(_ id: String, isRow: Bool = false) -> WarrenTooltipCenter.Tip {
        WarrenTooltipCenter.Tip(id: id, text: id, shortcut: nil, anchor: .zero, isRow: isRow)
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A control's tip, once up, hands straight over to the next control.
    func testControlTipGlidesToTheNextControl() async {
        let center = WarrenTooltipCenter()
        center.enter(tip("a"))
        await settle(WarrenTooltipCenter.showDelay + 0.1)
        XCTAssertEqual(center.tip?.id, "a")

        center.enter(tip("b"))
        XCTAssertEqual(center.tip?.id, "b")
        XCTAssertTrue(center.glides)
    }

    /// Moving down a list never carries a row's tip onto the next row, and a
    /// warm control tip does not make a row answer at once either.
    func testRowTipWaitsItsDwellEveryTime() async {
        let center = WarrenTooltipCenter()
        center.enter(tip("control"))
        await settle(WarrenTooltipCenter.showDelay + 0.1)
        XCTAssertEqual(center.tip?.id, "control")

        center.enter(tip("row-1", isRow: true))
        XCTAssertNil(center.tip, "a row never takes over a showing tip")

        await settle(WarrenTooltipCenter.rowShowDelay + 0.1)
        XCTAssertEqual(center.tip?.id, "row-1")
        XCTAssertFalse(center.glides)

        center.leave("row-1")
        XCTAssertNil(center.tip, "a row's tip leaves with the pointer")
        center.enter(tip("row-2", isRow: true))
        XCTAssertNil(center.tip, "the next row waits its own dwell")
    }
}
#endif
