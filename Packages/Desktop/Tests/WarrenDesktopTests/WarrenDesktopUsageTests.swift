import XCTest
@testable import WarrenDesktop

final class WarrenDesktopUsageTests: XCTestCase {
    private func gregorian() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func day(_ key: String, tokens: Int64, calls: Int64 = 1, priced: Int64 = 1) -> WarrenUsageDay {
        WarrenUsageDay(
            day: key,
            buckets: WarrenUsageBuckets(freshInput: tokens),
            cost: WarrenUsageCost(nanoUSD: tokens, calls: calls, pricedCalls: priced)
        )
    }

    // MARK: - Buckets

    func testBucketTotalSumsTheFourClasses() {
        let buckets = WarrenUsageBuckets(
            freshInput: 100, cacheWrite: 20, cacheRead: 300, output: 50, reasoning: 40
        )
        // Reasoning is inside output and must not inflate the total.
        XCTAssertEqual(buckets.total, 470)
    }

    func testCacheHitRateExcludesOutputFromTheDenominator() {
        let buckets = WarrenUsageBuckets(freshInput: 250, cacheRead: 750, output: 1_000_000)
        XCTAssertEqual(buckets.cacheHitRate ?? 0, 0.75, accuracy: 0.0001)
    }

    func testCacheHitRateIsNilWithoutCacheableInput() {
        XCTAssertNil(WarrenUsageBuckets(output: 500).cacheHitRate)
    }

    // MARK: - Cost completeness

    func testCostIsIncompleteWhenACallHadNoPrice() {
        let cost = WarrenUsageCost(nanoUSD: 1, calls: 10, pricedCalls: 9)
        XCTAssertFalse(cost.isComplete)
    }

    func testCostIsIncompleteWhenAProviderReportsNoTokens() {
        let cost = WarrenUsageCost(
            nanoUSD: 1, calls: 10, pricedCalls: 10, unmeasuredProviders: ["qoder"]
        )
        // Every counted call was priced, but whole Agents are missing from the
        // figure, so it still may not read as whole.
        XCTAssertFalse(cost.isComplete)
    }

    func testCostIsCompleteOnlyWhenNothingIsMissing() {
        XCTAssertTrue(WarrenUsageCost(nanoUSD: 5, calls: 3, pricedCalls: 3).isComplete)
    }

    // MARK: - Intraday curve

    func testCurveKeepsHalfHourBoundariesAndMergesIntoHours() {
        let intervals = [
            WarrenUsageInterval(
                day: "2026-09-10", minute: 600,
                buckets: WarrenUsageBuckets(freshInput: 100),
                cost: WarrenUsageCost(nanoUSD: 10, calls: 1, pricedCalls: 1)
            ),
            WarrenUsageInterval(
                day: "2026-09-10", minute: 600,
                buckets: WarrenUsageBuckets(output: 50),
                cost: WarrenUsageCost(nanoUSD: 5, calls: 1, pricedCalls: 1)
            ),
            WarrenUsageInterval(
                day: "2026-09-10", minute: 630,
                buckets: WarrenUsageBuckets(freshInput: 200),
                cost: WarrenUsageCost(nanoUSD: 20, calls: 1, pricedCalls: 1)
            ),
        ]

        let halfHour = WarrenUsageCurveBuilder.build(
            intervals: intervals, day: "2026-09-10", granularity: .halfHour
        )
        XCTAssertEqual(halfHour.count, 48)
        XCTAssertEqual(halfHour[20].minute, 600)
        XCTAssertEqual(halfHour[20].tokens, 150)
        XCTAssertEqual(halfHour[20].cost.calls, 2)
        XCTAssertEqual(halfHour[21].tokens, 200)

        let hour = WarrenUsageCurveBuilder.build(
            intervals: intervals, day: "2026-09-10", granularity: .hour
        )
        XCTAssertEqual(hour.count, 24)
        XCTAssertEqual(hour[10].minute, 600)
        XCTAssertEqual(hour[10].tokens, 350)
        XCTAssertEqual(hour[10].cost.nanoUSD, 35)
        XCTAssertEqual(hour[10].cost.calls, 3)
    }

    func testCurveFillsQuietSlotsAndIgnoresOtherDays() {
        let intervals = [
            WarrenUsageInterval(
                day: "2026-09-09", minute: 600,
                buckets: WarrenUsageBuckets(freshInput: 999), cost: WarrenUsageCost()
            ),
            WarrenUsageInterval(
                day: "2026-09-10", minute: 1_439,
                buckets: WarrenUsageBuckets(output: 12), cost: WarrenUsageCost()
            ),
        ]
        let points = WarrenUsageCurveBuilder.build(
            intervals: intervals, day: "2026-09-10", granularity: .halfHour
        )
        XCTAssertEqual(points.count, 48)
        XCTAssertEqual(points[0].tokens, 0)
        XCTAssertEqual(points[47].minute, 1_410)
        XCTAssertEqual(points[47].tokens, 12)
    }

    // MARK: - Heatmap layout

    func testHeatmapLaysOutEveryDayInRangeIncludingEmptyOnes() {
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: [day("2026-01-05", tokens: 100)],
            fromDay: "2026-01-01",
            toDay: "2026-01-31",
            calendar: gregorian()
        )
        // A quiet day must still occupy a cell; collapsing gaps would make an
        // idle week look like a busy one.
        XCTAssertEqual(heatmap.cells.count, 31)
        XCTAssertEqual(heatmap.cells.filter { $0.intensity != nil }.count, 1)
        XCTAssertEqual(heatmap.peakTokens, 100)
    }

    func testHeatmapAlignsFirstColumnToCalendarWeek() {
        // 2026-01-01 is a Thursday; with Sunday as first weekday it sits at row 4.
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: [], fromDay: "2026-01-01", toDay: "2026-01-03", calendar: gregorian()
        )
        XCTAssertEqual(heatmap.cells.first?.weekday, 4)
        XCTAssertEqual(heatmap.cells.first?.week, 0)
        // Saturday 2026-01-03 closes the same column.
        XCTAssertEqual(heatmap.cells.last?.weekday, 6)
        XCTAssertEqual(heatmap.cells.last?.week, 0)
    }

    func testHeatmapStartsANewColumnOnTheWeekBoundary() {
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: [], fromDay: "2026-01-01", toDay: "2026-01-05", calendar: gregorian()
        )
        // Sunday 2026-01-04 begins the next week column.
        let sunday = heatmap.cells.first { $0.day == "2026-01-04" }
        XCTAssertEqual(sunday?.week, 1)
        XCTAssertEqual(sunday?.weekday, 0)
        XCTAssertEqual(heatmap.weekCount, 2)
    }

    func testHeatmapRejectsInvertedOrUnparsableRange() {
        let calendar = gregorian()
        XCTAssertEqual(
            WarrenUsageHeatmapBuilder.build(
                days: [], fromDay: "2026-02-01", toDay: "2026-01-01", calendar: calendar
            ),
            .empty
        )
        XCTAssertEqual(
            WarrenUsageHeatmapBuilder.build(
                days: [], fromDay: "not-a-day", toDay: "2026-01-01", calendar: calendar
            ),
            .empty
        )
    }

    func testHeatmapMarksDaysWhoseCostIsALowerBound() {
        let partial = WarrenUsageDay(
            day: "2026-01-02",
            buckets: WarrenUsageBuckets(freshInput: 500),
            cost: WarrenUsageCost(nanoUSD: 0, calls: 2, pricedCalls: 0)
        )
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: [day("2026-01-01", tokens: 500), partial],
            fromDay: "2026-01-01",
            toDay: "2026-01-02",
            calendar: gregorian()
        )
        XCTAssertEqual(heatmap.cells.first { $0.day == "2026-01-01" }?.hasIncompleteCost, false)
        XCTAssertEqual(heatmap.cells.first { $0.day == "2026-01-02" }?.hasIncompleteCost, true)
    }

    func testEmptyDayIsNeverMarkedIncomplete() {
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: [], fromDay: "2026-01-01", toDay: "2026-01-01", calendar: gregorian()
        )
        // No work happened, so there is nothing to caveat.
        XCTAssertEqual(heatmap.cells.first?.hasIncompleteCost, false)
    }

    // MARK: - Intensity scale

    func testIntensityIsNilForAnEmptyDay() {
        XCTAssertNil(WarrenUsageHeatmapBuilder.intensity(tokens: 0, peak: 1000))
        XCTAssertNil(WarrenUsageHeatmapBuilder.intensity(tokens: 100, peak: 0))
    }

    func testIntensityPeaksAtOne() {
        XCTAssertEqual(WarrenUsageHeatmapBuilder.intensity(tokens: 1000, peak: 1000), 1.0)
    }

    func testIntensityKeepsATinyDayVisible() {
        // The reason for a compressive scale: under a linear ramp a day at
        // 0.1% of peak would round to nothing and read as idle.
        let intensity = WarrenUsageHeatmapBuilder.intensity(tokens: 1, peak: 1000)
        XCTAssertNotNil(intensity)
        XCTAssertGreaterThan(intensity ?? 0, 0)
    }

    func testIntensityQuantizesIntoTheShadeScale() {
        let steps = Set(
            (1...1000).compactMap {
                WarrenUsageHeatmapBuilder.intensity(tokens: Int64($0), peak: 1000)
            }
        )
        XCTAssertLessThanOrEqual(steps.count, WarrenUsageHeatmapBuilder.shadeCount)
        for step in steps {
            XCTAssertGreaterThan(step, 0)
            XCTAssertLessThanOrEqual(step, 1)
        }
    }

    func testIntensityIsMonotonic() {
        var previous = 0.0
        for tokens in stride(from: Int64(1), through: 1000, by: 37) {
            let value = WarrenUsageHeatmapBuilder.intensity(tokens: tokens, peak: 1000) ?? 0
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    // MARK: - Formatting

    func testTokenFormattingScalesByMagnitude() {
        XCTAssertEqual(WarrenUsageFormatting.tokens(512), "512")
        XCTAssertEqual(WarrenUsageFormatting.tokens(9_999), "9,999")
        XCTAssertEqual(WarrenUsageFormatting.tokens(943_000), "943K")
        XCTAssertEqual(WarrenUsageFormatting.tokens(1_200_000), "1.2M")
        XCTAssertEqual(WarrenUsageFormatting.tokens(252_500_487), "252.5M")
        XCTAssertEqual(WarrenUsageFormatting.tokens(11_610_810_204), "11.6B")
    }

    func testMoneyKeepsSmallAmountsFromReadingAsFree() {
        // A single call often costs a fraction of a cent. Two decimals would
        // print $0.00 and imply it was free.
        XCTAssertTrue(WarrenUsageFormatting.money(0.000_2).contains("0.0002"))
        XCTAssertTrue(WarrenUsageFormatting.money(0.2024).contains("0.202"))
        XCTAssertTrue(WarrenUsageFormatting.money(36.75).contains("36.75"))
    }

    func testMoneyMarksALowerBound() {
        let complete = WarrenUsageCost(nanoUSD: 5_000_000_000, calls: 1, pricedCalls: 1)
        let partial = WarrenUsageCost(nanoUSD: 5_000_000_000, calls: 2, pricedCalls: 1)
        XCTAssertFalse(WarrenUsageFormatting.money(complete).hasPrefix("≥"))
        XCTAssertTrue(WarrenUsageFormatting.money(partial).hasPrefix("≥"))
    }

    func testIncompleteReasonNamesBothCauses() {
        let cost = WarrenUsageCost(
            nanoUSD: 1, calls: 10, pricedCalls: 7, unmeasuredProviders: ["antigravity", "qoder"]
        )
        let reason = WarrenUsageFormatting.incompleteReason(cost)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("3 calls") ?? false)
        XCTAssertTrue(reason?.contains("antigravity") ?? false)
        XCTAssertNil(
            WarrenUsageFormatting.incompleteReason(
                WarrenUsageCost(nanoUSD: 1, calls: 2, pricedCalls: 2)
            )
        )
    }

    func testGroupFallsBackToAnExplicitUnattributedLabel() {
        let group = WarrenUsageGroup(
            key: "", buckets: WarrenUsageBuckets(), cost: WarrenUsageCost()
        )
        XCTAssertEqual(group.displayName, "Unattributed")
        XCTAssertEqual(
            WarrenUsageGroup(key: "codex", buckets: WarrenUsageBuckets(), cost: WarrenUsageCost())
                .displayName,
            "codex"
        )
    }
}
