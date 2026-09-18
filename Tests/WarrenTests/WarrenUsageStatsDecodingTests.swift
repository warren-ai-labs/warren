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
                       "unmeasuredProviders": ["antigravity", "qoder"],
                       "unpricedModels": ["<synthetic>", "gpt-5.6-terra"]},
              "days": [{"day": "2026-09-01", "buckets": {"freshInput": 1000},
                        "cost": {"nanoUsd": 0, "calls": 4, "pricedCalls": 1}}]
            }
            """
        )
        XCTAssertFalse(stats.cost.isComplete)
        XCTAssertEqual(stats.cost.unmeasuredProviders, ["antigravity", "qoder"])
        XCTAssertEqual(stats.cost.unpricedModels, ["<synthetic>", "gpt-5.6-terra"])
        // Tokens still surface: the spend happened even without a price.
        XCTAssertEqual(stats.total.freshInput, 1000)
        let reason = WarrenUsageFormatting.incompleteReason(stats.cost)
        XCTAssertTrue(reason?.contains("3 calls") ?? false)
        // Naming the models is what makes the gap actionable.
        XCTAssertTrue(reason?.contains("gpt-5.6-terra") ?? false)
        XCTAssertTrue(WarrenUsageFormatting.money(stats.cost).hasPrefix("≥"))
    }

    func testRebuildResponseReportsWhatItReplaced() throws {
        let response = try JSONDecoder().decode(
            WarrenUsageRebuildResponse.self,
            from: Data(
                """
                {"rebuilt": true, "providers": ["claude", "codex", "pi"],
                 "observations": 4261, "calls": 4007, "days": 19}
                """.utf8
            )
        )
        let summary = response.model
        XCTAssertEqual(summary.providers, ["claude", "codex", "pi"])
        XCTAssertEqual(summary.collapsedRepeats, 254)
        let outcome = WarrenUsageFormatting.rebuildOutcome(summary)
        XCTAssertTrue(outcome.contains("claude, codex, pi"))
        XCTAssertTrue(outcome.contains("19 days"))
        XCTAssertTrue(outcome.contains("counted once"))
    }

    func testDecodesTheRebuildAgeAndItsScope() throws {
        // Figures an older parser produced look exactly like current ones, so the
        // panel has to be able to state how old they are and what they cover.
        let stats = try decode(
            """
            {
              "fromDay": "2026-08-12", "toDay": "2026-09-10",
              "total": {"freshInput": 100},
              "lastRebuild": {"completedAt": "2026-09-10T09:00:00Z",
                              "providers": ["claude", "codex"], "calls": 4007}
            }
            """
        )
        let stamp = try XCTUnwrap(stats.lastRebuild)
        XCTAssertEqual(stamp.providers, ["claude", "codex"])
        XCTAssertEqual(stamp.calls, 4007)
        let now = stamp.completedAt.addingTimeInterval(7200)
        let line = WarrenUsageFormatting.rebuildAge(stamp, now: now)
        XCTAssertTrue(line.contains("claude, codex"), line)
        XCTAssertFalse(line.contains("just now"), line)
        // Within the first minute the relative form renders as "in 0 seconds", so
        // a rebuild that just landed is stated plainly instead.
        XCTAssertTrue(
            WarrenUsageFormatting.rebuildAge(stamp, now: stamp.completedAt).contains("just now")
        )
        // No stamp is its own fact, and the one most worth saying out loud.
        XCTAssertTrue(WarrenUsageFormatting.rebuildAge(nil).contains("Never rebuilt"))
    }

    func testRebuildResponseCarriesItsOwnStamp() throws {
        // The settings surface shows the age straight from the response, so the
        // line moves the moment the rebuild returns rather than after a refetch.
        let response = try JSONDecoder().decode(
            WarrenUsageRebuildResponse.self,
            from: Data(
                """
                {"rebuilt": true, "providers": ["claude"], "observations": 2, "calls": 1,
                 "days": 1, "completedAt": "2026-09-10T09:00:00Z"}
                """.utf8
            )
        )
        let stamp = try XCTUnwrap(response.model.stamp)
        XCTAssertEqual(stamp.providers, ["claude"])
        XCTAssertEqual(stamp.calls, 1)
    }

    func testRebuildResponseDecodesAnEmptyOutcome() throws {
        // A Host that replaced nothing sends an almost empty object, and the
        // summary must not invent a success story from missing keys.
        let response = try JSONDecoder().decode(
            WarrenUsageRebuildResponse.self,
            from: Data("{\"rebuilt\": false}".utf8)
        )
        XCTAssertFalse(response.rebuilt)
        XCTAssertEqual(response.model.collapsedRepeats, 0)
        XCTAssertTrue(WarrenUsageFormatting.rebuildOutcome(response.model).contains("no Agent"))
    }

    func testDecodesTheCostSplitAndIntervalIdentity() throws {
        // The token mix and the money mix disagree by design: cache reads dominate
        // the tokens at a tenth of the input rate. A client holding only the token
        // shares cannot derive the cost shares, so both travel.
        let stats = try decode(
            """
            {
              "fromDay": "2026-09-10", "toDay": "2026-09-10",
              "total": {"freshInput": 50, "cacheRead": 940, "output": 10},
              "cost": {"nanoUsd": 1000, "calls": 2, "pricedCalls": 2,
                       "byBucket": {"freshInput": 420, "cacheRead": 440, "output": 140}},
              "days": [],
              "intervals": [
                {"day": "2026-09-10", "minute": 600, "provider": "claude",
                 "model": "claude-opus-5", "buckets": {"freshInput": 40},
                 "cost": {"nanoUsd": 600, "calls": 1, "pricedCalls": 1}},
                {"day": "2026-09-10", "minute": 600, "provider": "codex",
                 "model": "gpt-5.6-luna", "buckets": {"freshInput": 10},
                 "cost": {"nanoUsd": 400, "calls": 1, "pricedCalls": 1}}
              ]
            }
            """
        )
        XCTAssertEqual(stats.cost.byBucket.total, stats.cost.nanoUSD)
        // 5% of tokens, 42% of the money.
        XCTAssertEqual(stats.total.freshInput, 50)
        XCTAssertEqual(stats.cost.byBucket.share(stats.cost.byBucket.freshInput), 0.42)
        XCTAssertEqual(stats.cost.byBucket.share(stats.cost.byBucket.cacheRead), 0.44)
        // Two rows share one minute, so identity has to include the model.
        XCTAssertEqual(stats.intervals.count, 2)
        XCTAssertEqual(Set(stats.intervals.map(\.id)).count, 2)
        XCTAssertEqual(stats.intervals.first?.provider, "claude")
        XCTAssertEqual(stats.intervals.first?.model, "claude-opus-5")
    }

    func testDecodesAnUnpricedCostSplitAsUnknownRatherThanZero() throws {
        let stats = try decode(
            """
            {"fromDay": "2026-09-10", "toDay": "2026-09-10",
             "total": {"freshInput": 100},
             "cost": {"nanoUsd": 0, "calls": 1, "pricedCalls": 0},
             "days": []}
            """
        )
        // No share is a made-up number, so there is none to render.
        XCTAssertNil(stats.cost.byBucket.share(stats.cost.byBucket.freshInput))
    }

    func testPerCallAverageUsesOnlyPricedCalls() {
        // Dividing a partial amount by every call reports an average low by the
        // exact share of spend the panel already admits it is missing.
        let cost = WarrenUsageCost(nanoUSD: 30_000_000_000, calls: 4, pricedCalls: 2)
        XCTAssertEqual(cost.usdPerPricedCall, 15)
        XCTAssertEqual(cost.unpricedCalls, 2)
        XCTAssertNil(WarrenUsageCost(nanoUSD: 0, calls: 3, pricedCalls: 0).usdPerPricedCall)
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
