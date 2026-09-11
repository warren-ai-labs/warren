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
