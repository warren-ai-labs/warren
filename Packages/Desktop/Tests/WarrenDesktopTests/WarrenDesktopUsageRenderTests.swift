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
        let detailDay = entries.last?.day
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
            detailDay: detailDay,
            dayProviders: [
                WarrenUsageGroup(key: "claude", buckets: WarrenUsageBuckets(freshInput: 4_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 800_000_000, calls: 12, pricedCalls: 12)),
                WarrenUsageGroup(key: "codex", buckets: WarrenUsageBuckets(freshInput: 1_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 200_000_000, calls: 5, pricedCalls: 5)),
            ],
            dayModels: [
                WarrenUsageGroup(key: "claude-opus-5", buckets: WarrenUsageBuckets(freshInput: 4_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 800_000_000, calls: 12, pricedCalls: 12)),
            ],
            dayProjects: [
                WarrenUsageGroup(key: "p1", label: "warren", buckets: WarrenUsageBuckets(freshInput: 5_000_000),
                                 cost: WarrenUsageCost(nanoUSD: 1_000_000_000, calls: 17, pricedCalls: 17)),
            ],
            pricesFetchedAt: Date()
        )
    }

    @MainActor
    func testOverviewPanelLaysOutSummaryHeatmapAndBreakdowns() {
        var range = WarrenUsageRange.month
        var selected: String?
        let hosting = mount(
            WarrenDesktopUsagePanel(
                stats: sampleStats(days: 30, peak: 5_000_000),
                state: .loaded,
                tokens: .dark,
                range: Binding(get: { range }, set: { range = $0 }),
                selectedDay: Binding(get: { selected }, set: { selected = $0 }),
                onLoad: { _, _, _ in },
                onOpenDetail: { selected = $0 },
                mode: .overview
            )
        )
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertFalse(hosting.subviews.isEmpty)
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
                selectedDay: .constant(nil),
                onLoad: { _, _, _ in }
            )
        )
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertFalse(hosting.subviews.isEmpty)
    }

    @MainActor
    func testDetailPanelLaysOutTheSelectedDayCurveAndBreakdowns() {
        let stats = sampleStats(days: 30, peak: 5_000_000)
        var range = WarrenUsageRange.month
        var selected: String? = stats.days.first?.day
        let hosting = mount(
            WarrenDesktopUsagePanel(
                stats: stats,
                state: .loaded,
                tokens: .dark,
                range: Binding(get: { range }, set: { range = $0 }),
                selectedDay: Binding(get: { selected }, set: { selected = $0 }),
                onLoad: { _, _, _ in },
                mode: .detail
            )
        )
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertEqual(selected, stats.days.first?.day)
    }

    /// Segment labels of every segmented control in the rendered tree.
    ///
    /// The identifiers SwiftUI attaches do not reach the backing NSView, so the
    /// controls are found by what they offer. That also makes the assertion about
    /// the visible choices rather than a name only the source knows.
    @MainActor
    private func segmentLabels(in view: NSView) -> [String] {
        var labels: [String] = []
        if let segmented = view as? NSSegmentedControl {
            for index in 0..<segmented.segmentCount {
                if let label = segmented.label(forSegment: index) {
                    labels.append(label)
                }
            }
        }
        for subview in view.subviews {
            labels.append(contentsOf: segmentLabels(in: subview))
        }
        return labels
    }

    @MainActor
    func testRangePickerAppearsOnlyWhereTheRangeIsWhatIsShown() {
        // The detail surface is one day: its strip, curve, and breakdowns all
        // describe that day, so a range control there changed nothing visible and
        // read as broken. The Host does narrow by range -- 7/30/90/365 return
        // different day counts -- which is why the control stays on the overview
        // rather than the ranges being dropped.
        let stats = sampleStats(days: 90, peak: 5_000_000)
        var range = WarrenUsageRange.month
        var selected: String? = stats.days.first?.day

        func mountPanel(_ mode: WarrenUsagePanelMode) -> NSHostingView<AnyView> {
            mount(
                WarrenDesktopUsagePanel(
                    stats: stats,
                    state: .loaded,
                    tokens: .dark,
                    range: Binding(get: { range }, set: { range = $0 }),
                    selectedDay: Binding(get: { selected }, set: { selected = $0 }),
                    onLoad: { _, _, _ in },
                    mode: mode
                )
            )
        }
        let overview = segmentLabels(in: mountPanel(.overview))
        XCTAssertTrue(
            overview.contains(WarrenUsageRange.quarter.label),
            "the overview is the range, so it must offer every range: \(overview)"
        )
        let detail = segmentLabels(in: mountPanel(.detail))
        for option in WarrenUsageRange.allCases {
            XCTAssertFalse(
                detail.contains(option.label),
                "\(option.label) does nothing on a single day's surface: \(detail)"
            )
        }
        // The curve's own controls do act on what the detail surface shows.
        XCTAssertTrue(detail.contains(WarrenUsageCurveMetric.cost.label), "\(detail)")
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
                    selectedDay: .constant(nil),
                    onLoad: { _, _, _ in }
                ),
                height: 400
            )
            XCTAssertGreaterThan(hosting.fittingSize.height, 0, "state \(state) produced no layout")
        }
    }

    @MainActor
    func testFilterKeepsEachSurfaceInItsOwnScope() {
        // The Host names a detail day by default, so scope must follow the surface
        // instead. Reading it off the detail day made an Overview filter silently
        // swap the range total for one day's, while the list the filter was picked
        // from still described the range.
        let rangeOnly = WarrenUsageGroup(
            key: "codex",
            buckets: WarrenUsageBuckets(freshInput: 50_000_000),
            cost: WarrenUsageCost(nanoUSD: 2_800_000_000, calls: 577, pricedCalls: 577)
        )
        let dayOnly = WarrenUsageGroup(
            key: "codex",
            buckets: WarrenUsageBuckets(freshInput: 1_000_000),
            cost: WarrenUsageCost(nanoUSD: 200_000_000, calls: 5, pricedCalls: 5)
        )
        let stats = WarrenUsageStats(
            fromDay: "2026-09-01", toDay: "2026-09-10",
            total: WarrenUsageBuckets(freshInput: 250_000_000),
            cost: WarrenUsageCost(nanoUSD: 30_800_000_000, calls: 1777, pricedCalls: 1777),
            days: [
                WarrenUsageDay(
                    day: "2026-09-10",
                    buckets: WarrenUsageBuckets(freshInput: 5_000_000),
                    cost: WarrenUsageCost(nanoUSD: 1_000_000_000, calls: 17, pricedCalls: 17)
                )
            ],
            providers: [rangeOnly],
            models: [],
            projects: [],
            detailDay: "2026-09-10",
            dayProviders: [dayOnly]
        )
        var range = WarrenUsageRange.month
        for (mode, expected) in [
            (WarrenUsagePanelMode.overview, rangeOnly.cost.nanoUSD),
            (WarrenUsagePanelMode.detail, dayOnly.cost.nanoUSD),
        ] {
            let panel = WarrenDesktopUsagePanel(
                stats: stats,
                state: .loaded,
                tokens: .dark,
                range: Binding(get: { range }, set: { range = $0 }),
                selectedDay: .constant("2026-09-10"),
                onLoad: { _, _, _ in },
                mode: mode
            )
            let hosting = mount(panel)
            XCTAssertGreaterThan(hosting.fittingSize.height, 0, "mode \(mode) produced no layout")
            XCTAssertEqual(
                panel.scopedProvidersForTesting.first?.cost.nanoUSD, expected,
                "mode \(mode) resolved the wrong scope"
            )
        }
    }

    @MainActor
    func testFilteredCurveNarrowsToTheSelectedModel() {
        // The Host sends one interval row per Agent and model, which is what lets
        // the filter narrow the curve. Before that the filter tinted a chip and
        // changed no number on this surface.
        let day = "2026-09-10"
        let intervals = [
            WarrenUsageInterval(
                day: day, minute: 600, provider: "claude", model: "claude-opus-5",
                buckets: WarrenUsageBuckets(freshInput: 100),
                cost: WarrenUsageCost(nanoUSD: 500, calls: 1, pricedCalls: 1)
            ),
            WarrenUsageInterval(
                day: day, minute: 600, provider: "codex", model: "gpt-5.6-luna",
                buckets: WarrenUsageBuckets(freshInput: 900),
                cost: WarrenUsageCost(nanoUSD: 180, calls: 1, pricedCalls: 1)
            ),
        ]
        let unfiltered = WarrenUsageCurveBuilder.build(
            intervals: intervals, day: day, granularity: .hour
        )
        XCTAssertEqual(unfiltered.first(where: { $0.minute == 600 })?.tokens, 1000)

        let claudeOnly = WarrenUsageCurveBuilder.build(
            intervals: intervals, day: day, granularity: .hour,
            include: { $0.provider == "claude" }
        )
        XCTAssertEqual(claudeOnly.first(where: { $0.minute == 600 })?.tokens, 100)
        // Rows sharing a minute must stay distinct, or SwiftUI collapses them.
        XCTAssertEqual(Set(intervals.map(\.id)).count, 2)

        var granularity = WarrenUsageCurveGranularity.hour
        var metric = WarrenUsageCurveMetric.tokens
        let hosting = mount(
            WarrenDesktopUsageCurveView(
                intervals: intervals,
                day: day,
                tokens: .dark,
                granularity: Binding(get: { granularity }, set: { granularity = $0 }),
                metric: Binding(get: { metric }, set: { metric = $0 }),
                scopeLabel: "claude",
                include: { $0.provider == "claude" }
            ),
            height: 260
        )
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    @MainActor
    func testIncompleteCostRendersItsExplanationBesideTheAmount() {
        // The "≥" marker is unreadable on its own, so an incomplete range has to
        // carry its explanation where the amounts are, not in a trailing footnote.
        var stats = sampleStats(days: 7, peak: 1_000_000)
        stats = WarrenUsageStats(
            fromDay: stats.fromDay,
            toDay: stats.toDay,
            total: stats.total,
            cost: WarrenUsageCost(
                nanoUSD: 30_800_000_000, calls: 1777, pricedCalls: 1200,
                unmeasuredProviders: ["qoder"], unpricedModels: ["gpt-5.6-terra"]
            ),
            days: stats.days,
            intervals: stats.intervals,
            providers: stats.providers,
            models: stats.models,
            projects: stats.projects,
            detailDay: stats.detailDay,
            dayProviders: stats.dayProviders,
            dayModels: stats.dayModels,
            dayProjects: stats.dayProjects,
            pricesFetchedAt: stats.pricesFetchedAt
        )
        var range = WarrenUsageRange.week
        for mode in [WarrenUsagePanelMode.overview, .detail] {
            let hosting = mount(
                WarrenDesktopUsagePanel(
                    stats: stats,
                    state: .loaded,
                    tokens: .dark,
                    range: Binding(get: { range }, set: { range = $0 }),
                    selectedDay: .constant(stats.detailDay),
                    onLoad: { _, _, _ in },
                    mode: mode
                )
            )
            XCTAssertGreaterThan(hosting.fittingSize.height, 0, "mode \(mode) produced no layout")
        }
        let reason = WarrenUsageFormatting.incompleteReason(stats.cost)
        XCTAssertTrue(reason?.contains("577 calls") ?? false, "reason = \(reason ?? "nil")")
        XCTAssertTrue(reason?.contains("gpt-5.6-terra") ?? false)
        XCTAssertTrue(reason?.contains("qoder") ?? false)
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
        var metric = WarrenUsageCurveMetric.tokens
        let hosting = mount(
            WarrenDesktopUsageCurveView(
                intervals: stats.intervals,
                day: stats.intervals.last?.day,
                tokens: .dark,
                granularity: Binding(get: { granularity }, set: { granularity = $0 }),
                metric: Binding(get: { metric }, set: { metric = $0 })
            ),
            height: 260
        )
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        granularity = .hour
        metric = .cost
        hosting.rootView = AnyView(
            WarrenDesktopUsageCurveView(
                intervals: stats.intervals,
                day: stats.intervals.last?.day,
                tokens: .dark,
                granularity: Binding(get: { granularity }, set: { granularity = $0 }),
                metric: Binding(get: { metric }, set: { metric = $0 })
            ).frame(width: 896, height: 260)
        )
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }
}
