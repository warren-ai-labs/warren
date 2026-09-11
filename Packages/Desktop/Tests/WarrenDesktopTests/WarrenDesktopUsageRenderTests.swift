import AppKit
import SwiftUI
import XCTest
import WarrenDesignSystem
@testable import WarrenDesktop

/// Mounts the panel in a real hosting view to prove it lays out rather than
/// merely compiling. A view that crashes or produces a zero-size layout would
/// pass every model test.
final class WarrenDesktopUsageRenderTests: XCTestCase {
    @MainActor
    private func mount<V: View>(_ view: V, height: CGFloat = 900) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: 896, height: height)))
        hosting.frame = NSRect(x: 0, y: 0, width: 896, height: height)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func sampleStats(days: Int, peak: Int64) -> WarrenUsageStats {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Date()
        var entries: [WarrenUsageDay] = []
        var intervals: [WarrenUsageInterval] = []
        for offset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            // Leave some days empty so the empty-cell path renders too.
            guard offset % 3 != 0 else { continue }
            let tokens = Int64(offset % 7 + 1) * peak / 7
            let dayKey = formatter.string(from: date)
            entries.append(
                WarrenUsageDay(
                    day: dayKey,
                    buckets: WarrenUsageBuckets(
                        freshInput: tokens / 4, cacheWrite: tokens / 8,
                        cacheRead: tokens / 2, output: tokens / 8, reasoning: tokens / 16
                    ),
                    cost: WarrenUsageCost(nanoUSD: tokens * 5, calls: 3, pricedCalls: 3)
                )
            )
            intervals.append(
                WarrenUsageInterval(
                    day: dayKey,
                    minute: 600,
                    buckets: WarrenUsageBuckets(freshInput: tokens),
                    cost: WarrenUsageCost(nanoUSD: tokens * 5, calls: 3, pricedCalls: 3)
                )
            )
            intervals.append(
                WarrenUsageInterval(
                    day: dayKey,
                    minute: 630,
                    buckets: WarrenUsageBuckets(output: tokens / 10),
                    cost: WarrenUsageCost(nanoUSD: tokens, calls: 1, pricedCalls: 1)
                )
            )
        }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return WarrenUsageStats(
            fromDay: formatter.string(from: start),
            toDay: formatter.string(from: today),
            total: WarrenUsageBuckets(
                freshInput: 43_994_788, cacheWrite: 7_343_419,
                cacheRead: 200_429_223, output: 733_057, reasoning: 4_210
            ),
            cost: WarrenUsageCost(nanoUSD: 30_800_000_000, calls: 1777, pricedCalls: 1777),
            days: entries,
            intervals: intervals,
            providers: [
                WarrenUsageGroup(key: "claude", buckets: WarrenUsageBuckets(freshInput: 200_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 28_000_000_000, calls: 1200, pricedCalls: 1200)),
                WarrenUsageGroup(key: "codex", buckets: WarrenUsageBuckets(freshInput: 50_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 2_800_000_000, calls: 577, pricedCalls: 577)),
            ],
            models: [
                WarrenUsageGroup(key: "claude-opus-5", buckets: WarrenUsageBuckets(freshInput: 200_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 28_000_000_000, calls: 1200, pricedCalls: 1200)),
            ],
            projects: [
                WarrenUsageGroup(key: "p1", label: "warren", buckets: WarrenUsageBuckets(freshInput: 250_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 30_800_000_000, calls: 1777, pricedCalls: 1777)),
            ],
            pricesFetchedAt: Date()
        )
    }

    @MainActor
    func testPanelLaysOutAFullYear() {
        var range = WarrenUsageRange.year
        let hosting = mount(
            WarrenDesktopUsagePanel(
                stats: sampleStats(days: 365, peak: 5_000_000),
                state: .loaded,
                tokens: .dark,
                range: Binding(get: { range }, set: { range = $0 }),
                onReload: {}
            )
        )
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertFalse(hosting.subviews.isEmpty)
    }

    @MainActor
    func testPanelLaysOutEveryLoadState() {
        var range = WarrenUsageRange.week
        for state in [
            WarrenUsageLoadState.idle,
            .loading,
            .loaded,
            .failed("Host unreachable"),
        ] {
            let hosting = mount(
                WarrenDesktopUsagePanel(
                    stats: WarrenUsageStats(),
                    state: state,
                    tokens: .dark,
                    range: Binding(get: { range }, set: { range = $0 }),
                    onReload: {}
                ),
                height: 400
            )
            XCTAssertGreaterThan(hosting.fittingSize.height, 0, "state \(state) produced no layout")
        }
    }

    @MainActor
    func testHeatmapFitsTheSettingsContentWidth() {
        // A year must not overflow 896pt, or the grid clips silently.
        let stats = sampleStats(days: 365, peak: 1_000_000)
        let heatmap = WarrenUsageHeatmapBuilder.build(
            days: stats.days, fromDay: stats.fromDay, toDay: stats.toDay
        )
        var selected: String?
        let hosting = mount(
            WarrenDesktopUsageHeatmapView(
                heatmap: heatmap,
                tokens: .dark,
                selectedDay: Binding(get: { selected }, set: { selected = $0 })
            ),
            height: 200
        )
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 896)
        XCTAssertGreaterThan(heatmap.weekCount, 50)
    }

    @MainActor
    func testCurveMountsWithBothGranularities() {
        let stats = sampleStats(days: 7, peak: 1_000_000)
        var granularity = WarrenUsageCurveGranularity.halfHour
        let hosting = mount(
            WarrenDesktopUsageCurveView(
                intervals: stats.intervals,
                day: stats.intervals.last?.day,
                tokens: .dark,
                granularity: Binding(get: { granularity }, set: { granularity = $0 })
            ),
            height: 260
        )
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        granularity = .hour
        hosting.rootView = AnyView(
            WarrenDesktopUsageCurveView(
                intervals: stats.intervals,
                day: stats.intervals.last?.day,
                tokens: .dark,
                granularity: Binding(get: { granularity }, set: { granularity = $0 })
            ).frame(width: 896, height: 260)
        )
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }
}
