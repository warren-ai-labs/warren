import XCTest
@testable import WarrenDesktop

final class WarrenDesktopUsageBarsTests: XCTestCase {
    private func gregorian() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func day(_ key: String, fresh: Int64, output: Int64 = 0) -> WarrenUsageDay {
        WarrenUsageDay(
            day: key,
            buckets: WarrenUsageBuckets(freshInput: fresh, output: output),
            cost: WarrenUsageCost(
                nanoUSD: fresh + output,
                calls: 1,
                pricedCalls: 1,
                byBucket: WarrenUsageBucketCost(freshInput: fresh, output: output)
            )
        )
    }

    // MARK: - Window

    func testDayBarsCoverTheLastThirtyDaysIncludingQuietOnes() {
        let bars = WarrenUsageBarsBuilder.build(
            days: [day("2026-01-15", fresh: 10), day("2026-03-31", fresh: 20)],
            fromDay: "2026-01-01",
            toDay: "2026-03-31",
            grouping: .day,
            calendar: gregorian()
        )
        XCTAssertEqual(bars.count, 30)
        XCTAssertEqual(bars.first?.firstDay, "2026-03-02")
        XCTAssertEqual(bars.last?.firstDay, "2026-03-31")
        // A day outside the window is not drawn; a quiet day inside it is.
        XCTAssertEqual(bars.filter { $0.buckets.total > 0 }.count, 1)
    }

    func testAShortRangeKeepsEveryDay() {
        let bars = WarrenUsageBarsBuilder.build(
            days: [], fromDay: "2026-01-01", toDay: "2026-01-07", grouping: .day, calendar: gregorian()
        )
        XCTAssertEqual(bars.count, 7)
    }

    func testInvertedRangeHasNoBars() {
        XCTAssertTrue(
            WarrenUsageBarsBuilder.build(
                days: [], fromDay: "2026-01-07", toDay: "2026-01-01", grouping: .day, calendar: gregorian()
            ).isEmpty
        )
    }

    func testWeekBarsFollowCalendarWeeksAndMarkCutWeeks() {
        // 2026-01-01 is a Thursday; with Sunday first the window splits into
        // Thu-Sat, a full week, and Sun-Wed.
        let bars = WarrenUsageBarsBuilder.build(
            days: [day("2026-01-02", fresh: 100), day("2026-01-03", fresh: 50, output: 5)],
            fromDay: "2026-01-01",
            toDay: "2026-01-14",
            grouping: .week,
            calendar: gregorian()
        )
        XCTAssertEqual(bars.map(\.days.count), [3, 7, 4])
        XCTAssertEqual(bars.map(\.isPartial), [true, false, true])
        XCTAssertEqual(bars[0].firstDay, "2026-01-01")
        XCTAssertEqual(bars[0].lastDay, "2026-01-03")
        XCTAssertEqual(bars[0].buckets.total, 155)
        XCTAssertEqual(bars[0].cost.byBucket.output, 5)
        XCTAssertEqual(bars[1].buckets.total, 0)
    }

    func testPartsFollowTheBucketOrderInBothUnits() {
        let bar = WarrenUsageBar(
            days: ["2026-01-01"],
            buckets: WarrenUsageBuckets(freshInput: 1, cacheWrite: 2, cacheRead: 3, output: 4),
            cost: WarrenUsageCost(
                nanoUSD: 4_000_000_000,
                byBucket: WarrenUsageBucketCost(freshInput: 1_000_000_000, output: 3_000_000_000)
            )
        )
        XCTAssertEqual(bar.parts(.tokens), [1, 2, 3, 4])
        XCTAssertEqual(bar.parts(.cost), [1, 0, 0, 3])
        XCTAssertEqual(bar.total(.cost), 4, accuracy: 0.0001)
    }

    // MARK: - Scale

    func testScaleRoundsUpToAWholeNumberOfFriendlySteps() {
        XCTAssertEqual(WarrenUsageBarsBuilder.scale(peak: 7.83).step, 5, accuracy: 0.0001)
        XCTAssertEqual(WarrenUsageBarsBuilder.scale(peak: 7.83).top, 10, accuracy: 0.0001)
        XCTAssertEqual(WarrenUsageBarsBuilder.scale(peak: 2.5).top, 3, accuracy: 0.0001)
        XCTAssertEqual(WarrenUsageBarsBuilder.scale(peak: 120).step, 50, accuracy: 0.0001)
        XCTAssertEqual(WarrenUsageBarsBuilder.scale(peak: 120).top, 150, accuracy: 0.0001)
    }

    func testScaleOfAnEmptyWindowStillDivides() {
        XCTAssertEqual(WarrenUsageBarsBuilder.scale(peak: 0).top, 1)
    }

    // MARK: - Readout

    func testReadoutPlacementSitsRightOfTheAnchor() {
        let origin = WarrenUsageReadoutPlacement.origin(
            anchor: CGRect(x: 10, y: 50, width: 14, height: 30),
            size: CGSize(width: 200, height: 100),
            bounds: CGSize(width: 400, height: 180)
        )
        XCTAssertEqual(origin.x, 36)
        XCTAssertEqual(origin.y, 30)
    }

    func testReadoutPlacementFlipsLeftAtTheEdge() {
        let origin = WarrenUsageReadoutPlacement.origin(
            anchor: CGRect(x: 380, y: 0, width: 14, height: 180),
            size: CGSize(width: 200, height: 100),
            bounds: CGSize(width: 400, height: 180)
        )
        XCTAssertEqual(origin.x, 168)
        XCTAssertEqual(origin.y, 0)
    }

    func testReadoutPlacementCentresOnAChartShorterThanItself() {
        let origin = WarrenUsageReadoutPlacement.origin(
            anchor: CGRect(x: 0, y: 40, width: 11, height: 11),
            size: CGSize(width: 200, height: 100),
            bounds: CGSize(width: 600, height: 60)
        )
        XCTAssertEqual(origin.y, -20)
    }

    func testReadoutReadsCostWithTokensBeside() {
        let cost = WarrenUsageCost(
            nanoUSD: 3_000_000_000,
            calls: 1,
            pricedCalls: 1,
            byBucket: WarrenUsageBucketCost(freshInput: 2_000_000_000, output: 1_000_000_000)
        )
        let content = WarrenUsageReadoutContent.make(
            title: "Day",
            buckets: WarrenUsageBuckets(freshInput: 900, output: 100),
            cost: cost,
            metric: .cost,
            hint: "Click"
        )
        XCTAssertEqual(content.total, WarrenUsageFormatting.money(cost))
        XCTAssertEqual(content.secondary, "\(WarrenUsageFormatting.tokens(1000)) tokens")
        XCTAssertEqual(content.rows.map(\.bucket), WarrenUsageBucket.allCases)
        XCTAssertEqual(content.rows.first?.value, WarrenUsageFormatting.money(2.0))
        XCTAssertNil(content.caveat)
        XCTAssertEqual(content.hint, "Click")
    }

    func testReadoutOfAQuietDaySaysSo() {
        let content = WarrenUsageReadoutContent.make(
            title: "Day", buckets: WarrenUsageBuckets(), cost: WarrenUsageCost(), metric: .tokens, hint: "Click"
        )
        XCTAssertEqual(content.total, "No activity")
        XCTAssertTrue(content.rows.isEmpty)
        XCTAssertNil(content.hint)
    }

    func testHeatmapCellsCarryTheDaysBuckets() {
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: [day("2026-01-02", fresh: 7, output: 3)],
            fromDay: "2026-01-01",
            toDay: "2026-01-03",
            calendar: gregorian()
        )
        let cell = heatmap.cells.first { $0.day == "2026-01-02" }
        XCTAssertEqual(cell?.buckets.output, 3)
        XCTAssertEqual(cell?.buckets.total, cell?.tokens)
    }
}
