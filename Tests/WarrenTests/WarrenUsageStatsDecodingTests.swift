import XCTest
@testable import Warren
import WarrenDesktop

final class WarrenUsageStatsDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> WarrenUsageStats {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(WarrenUsageStatsResponse.self, from: data).model
    }

    func testDecodesTheHostPayload() throws {
        let stats = try decode(
            """
            {
              "fromDay": "2026-08-12", "toDay": "2026-09-10",
              "total": {"freshInput": 43994788, "cacheWrite": 7343419,
                        "cacheRead": 200429223, "output": 733057, "reasoning": 4210},
              "cost": {"nanoUsd": 30800000000, "calls": 1777, "pricedCalls": 1777},
              "days": [
                {"day": "2026-09-10",
                 "buckets": {"freshInput": 100, "output": 20},
                 "cost": {"nanoUsd": 500000, "calls": 1, "pricedCalls": 1}}
              ],
              "intervalBucketMinutes": 5,
              "intervals": [
                {"day": "2026-09-10", "minute": 600,
                 "buckets": {"freshInput": 100, "output": 20},
                 "cost": {"nanoUsd": 500000, "calls": 1, "pricedCalls": 1}}
              ],
              "providers": [
                {"key": "claude", "buckets": {"freshInput": 100},
                 "cost": {"nanoUsd": 500000, "calls": 1, "pricedCalls": 1}}
              ],
              "models": [
                {"key": "claude-opus-5", "buckets": {"freshInput": 100},
                 "cost": {"nanoUsd": 500000, "calls": 1, "pricedCalls": 1}}
              ],
              "projects": [
                {"key": "p1", "label": "warren", "buckets": {"freshInput": 100},
                 "cost": {"nanoUsd": 500000, "calls": 1, "pricedCalls": 1}}
              ],
              "pricesFetchedAt": "2026-09-10T12:00:00Z"
            }
            """
        )
        XCTAssertEqual(stats.fromDay, "2026-08-12")
        XCTAssertEqual(stats.total.freshInput, 43_994_788)
        XCTAssertEqual(stats.total.cacheRead, 200_429_223)
        XCTAssertEqual(stats.total.total, 252_500_487)
        XCTAssertEqual(stats.cost.calls, 1777)
        XCTAssertEqual(stats.cost.usd, 30.8, accuracy: 0.0001)
        XCTAssertTrue(stats.cost.isComplete)
        XCTAssertEqual(stats.days.count, 1)
        XCTAssertEqual(stats.intervalBucketMinutes, 5)
        XCTAssertEqual(stats.intervals.count, 1)
        XCTAssertEqual(stats.intervals.first?.minute, 600)
        XCTAssertEqual(stats.projects.first?.displayName, "warren")
        XCTAssertNotNil(stats.pricesFetchedAt)
        XCTAssertFalse(stats.isEmpty)
    }

    func testDecodesOmittedFieldsAsZero() throws {
        // The Host omits zero-valued fields, so absent must mean zero rather
        // than failing the whole decode and blanking the panel.
        let stats = try decode(#"{"fromDay":"2026-09-01","toDay":"2026-09-10","days":[]}"#)
        XCTAssertEqual(stats.total.total, 0)
        XCTAssertEqual(stats.cost.calls, 0)
        XCTAssertEqual(stats.intervalBucketMinutes, 5)
        XCTAssertTrue(stats.intervals.isEmpty)
        XCTAssertTrue(stats.isEmpty)
        XCTAssertNil(stats.pricesFetchedAt)
    }

    func testDecodesIncompleteCostAndUnmeasuredProviders() throws {
        let stats = try decode(
            """
            {
              "fromDay": "2026-09-01", "toDay": "2026-09-10",
              "total": {"freshInput": 1000},
              "cost": {"nanoUsd": 0, "calls": 4, "pricedCalls": 1,
                       "unmeasuredProviders": ["antigravity", "qoder"]},
              "days": [{"day": "2026-09-01", "buckets": {"freshInput": 1000},
                        "cost": {"nanoUsd": 0, "calls": 4, "pricedCalls": 1}}]
            }
            """
        )
        XCTAssertFalse(stats.cost.isComplete)
        XCTAssertEqual(stats.cost.unmeasuredProviders, ["antigravity", "qoder"])
        // Tokens still surface: the spend happened even without a price.
        XCTAssertEqual(stats.total.freshInput, 1000)
        let reason = WarrenUsageFormatting.incompleteReason(stats.cost)
        XCTAssertTrue(reason?.contains("3 calls") ?? false)
        XCTAssertTrue(WarrenUsageFormatting.money(stats.cost).hasPrefix("≥"))
    }

    func testDecodesDetailDayAndDayGroups() throws {
        let stats = try decode(
            """
            {
              "fromDay": "2026-09-01", "toDay": "2026-09-10",
              "detailDay": "2026-09-05",
              "days": [
                {"day": "2026-09-05", "buckets": {"freshInput": 100}},
                {"day": "2026-09-08", "buckets": {"freshInput": 900}}
              ],
              "intervals": [
                {"day": "2026-09-05", "minute": 600, "buckets": {"freshInput": 100}}
              ],
              "dayProviders": [
                {"key": "claude", "buckets": {"freshInput": 100}}
              ],
              "dayModels": [
                {"key": "claude-opus-5", "buckets": {"freshInput": 100}}
              ],
              "dayProjects": [
                {"key": "p1", "label": "warren", "buckets": {"freshInput": 100}}
              ]
            }
            """
        )
        XCTAssertEqual(stats.detailDay, "2026-09-05")
        XCTAssertEqual(stats.dayProviders.first?.key, "claude")
        XCTAssertEqual(stats.dayProjects.first?.displayName, "warren")
        XCTAssertEqual(stats.intervals.map(\.day), ["2026-09-05"])
        XCTAssertEqual(stats.resolvedDetailDay(selected: nil), "2026-09-05")
        // A selected day that is not in the payload falls back to the Host's
        // default rather than pointing the curve at a day with no rows.
        XCTAssertEqual(stats.resolvedDetailDay(selected: "2026-01-01"), "2026-09-05")
    }

    func testResolvedDetailDayFallsBackToTheLatestDay() throws {
        let stats = try decode(
            """
            {
              "fromDay": "2026-09-01", "toDay": "2026-09-10",
              "days": [
                {"day": "2026-09-05", "buckets": {"freshInput": 100}},
                {"day": "2026-09-08", "buckets": {"freshInput": 900}}
              ]
            }
            """
        )
        XCTAssertNil(stats.detailDay)
        XCTAssertEqual(stats.resolvedDetailDay(selected: nil), "2026-09-08")
        XCTAssertEqual(stats.resolvedDetailDay(selected: "2026-09-05"), "2026-09-05")
    }

    func testUsageRequestWindowNamesTheTrailingRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 12))!

        let week = WarrenUsageStatsRequest.window(days: 7, selectedDay: nil, now: now, calendar: calendar)
        XCTAssertEqual(week.fromDay, "2026-09-04")
        XCTAssertEqual(week.toDay, "2026-09-10")
        XCTAssertNil(week.intervalDay)
        XCTAssertEqual(week.cacheKey, "2026-09-04..2026-09-10..-")
        XCTAssertNil(week.parameters["intervalDay"])

        let scoped = WarrenUsageStatsRequest.window(
            days: 30, selectedDay: "2026-08-20", now: now, calendar: calendar
        )
        XCTAssertEqual(scoped.fromDay, "2026-08-12")
        XCTAssertEqual(scoped.intervalDay, "2026-08-20")
        XCTAssertEqual(scoped.parameters["intervalDay"], "2026-08-20")

        // An empty pick means "follow the Host's default", not a day named "".
        let empty = WarrenUsageStatsRequest.window(
            days: 7, selectedDay: "", now: now, calendar: calendar
        )
        XCTAssertNil(empty.intervalDay)
    }

    func testParsesTimestampWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(WarrenUsageStatsResponse.parseTimestamp("2026-09-10T12:00:00Z"))
        XCTAssertNotNil(WarrenUsageStatsResponse.parseTimestamp("2026-09-10T12:00:00.123Z"))
        XCTAssertNil(WarrenUsageStatsResponse.parseTimestamp(""))
        XCTAssertNil(WarrenUsageStatsResponse.parseTimestamp("not-a-date"))
    }

    func testHeatmapBuildsFromADecodedPayload() throws {
        let stats = try decode(
            """
            {
              "fromDay": "2026-09-01", "toDay": "2026-09-07",
              "total": {"freshInput": 300},
              "cost": {"nanoUsd": 3, "calls": 3, "pricedCalls": 3},
              "days": [
                {"day": "2026-09-01", "buckets": {"freshInput": 100},
                 "cost": {"nanoUsd": 1, "calls": 1, "pricedCalls": 1}},
                {"day": "2026-09-05", "buckets": {"freshInput": 200},
                 "cost": {"nanoUsd": 2, "calls": 2, "pricedCalls": 2}}
              ]
            }
            """
        )
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: stats.days, fromDay: stats.fromDay, toDay: stats.toDay
        )
        XCTAssertEqual(heatmap.cells.count, 7)
        XCTAssertEqual(heatmap.peakTokens, 200)
        XCTAssertEqual(heatmap.cells.filter { $0.intensity != nil }.count, 2)
        // The busiest day tops the scale.
        XCTAssertEqual(heatmap.cells.first { $0.day == "2026-09-05" }?.intensity, 1.0)
    }
}
