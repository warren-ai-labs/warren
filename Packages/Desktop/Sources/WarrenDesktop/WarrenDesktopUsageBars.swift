import CoreGraphics
import Foundation

/// The four disjoint token classes, in the order every Usage surface draws
/// them: the composition bars, their legend, the daily bars, and the readout.
///
/// One list so a surface cannot reorder or drop a class on its own; the colour
/// each one wears is mapped once, next to the views that draw it.
public enum WarrenUsageBucket: CaseIterable, Sendable {
    case freshInput
    case cacheWrite
    case cacheRead
    case output

    public var label: String {
        switch self {
        case .freshInput: "Fresh input"
        case .cacheWrite: "Cache write"
        case .cacheRead: "Cache read"
        case .output: "Output"
        }
    }

    public func tokens(in buckets: WarrenUsageBuckets) -> Int64 {
        switch self {
        case .freshInput: buckets.freshInput
        case .cacheWrite: buckets.cacheWrite
        case .cacheRead: buckets.cacheRead
        case .output: buckets.output
        }
    }

    public func nanoUSD(in cost: WarrenUsageBucketCost) -> Int64 {
        switch self {
        case .freshInput: cost.freshInput
        case .cacheWrite: cost.cacheWrite
        case .cacheRead: cost.cacheRead
        case .output: cost.output
        }
    }

    /// The class's share of one bar, in the unit the bar is drawn in.
    public func value(
        _ metric: WarrenUsageCurveMetric,
        buckets: WarrenUsageBuckets,
        cost: WarrenUsageCost
    ) -> Double {
        switch metric {
        case .tokens: Double(tokens(in: buckets))
        case .cost: Double(nanoUSD(in: cost.byBucket)) / 1_000_000_000
        }
    }
}

extension WarrenUsageBuckets {
    func adding(_ other: WarrenUsageBuckets) -> WarrenUsageBuckets {
        WarrenUsageBuckets(
            freshInput: freshInput + other.freshInput,
            cacheWrite: cacheWrite + other.cacheWrite,
            cacheRead: cacheRead + other.cacheRead,
            output: output + other.output,
            reasoning: reasoning + other.reasoning
        )
    }
}

extension WarrenUsageCost {
    func adding(_ other: WarrenUsageCost) -> WarrenUsageCost {
        WarrenUsageCost(
            nanoUSD: nanoUSD + other.nanoUSD,
            calls: calls + other.calls,
            pricedCalls: pricedCalls + other.pricedCalls,
            unmeasuredProviders: Array(
                Set(unmeasuredProviders).union(other.unmeasuredProviders)
            ).sorted(),
            unpricedModels: Array(
                Set(unpricedModels).union(other.unpricedModels)
            ).sorted(),
            byBucket: WarrenUsageBucketCost(
                freshInput: byBucket.freshInput + other.byBucket.freshInput,
                cacheWrite: byBucket.cacheWrite + other.byBucket.cacheWrite,
                cacheRead: byBucket.cacheRead + other.byBucket.cacheRead,
                output: byBucket.output + other.byBucket.output
            )
        )
    }
}

/// What one bar of the daily chart covers.
public enum WarrenUsageBarGrouping: String, CaseIterable, Identifiable, Sendable {
    case day
    case week

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        }
    }
}

/// One bar: a day, or the days of one calendar week inside the window.
public struct WarrenUsageBar: Equatable, Sendable, Identifiable {
    /// Every `yyyy-MM-dd` key the bar covers, oldest first. Never empty.
    public let days: [String]
    public let buckets: WarrenUsageBuckets
    public let cost: WarrenUsageCost
    /// A week the window's edge cut short, which the readout says so a short
    /// bar is not mistaken for a quiet week.
    public let isPartial: Bool

    public var id: String { days.first ?? "" }
    public var firstDay: String { days.first ?? "" }
    public var lastDay: String { days.last ?? "" }

    public init(days: [String], buckets: WarrenUsageBuckets, cost: WarrenUsageCost, isPartial: Bool = false) {
        self.days = days
        self.buckets = buckets
        self.cost = cost
        self.isPartial = isPartial
    }

    public func total(_ metric: WarrenUsageCurveMetric) -> Double {
        switch metric {
        case .tokens: Double(buckets.total)
        case .cost: cost.usd
        }
    }

    /// The bar's stack, in `WarrenUsageBucket.allCases` order.
    public func parts(_ metric: WarrenUsageCurveMetric) -> [Double] {
        WarrenUsageBucket.allCases.map { $0.value(metric, buckets: buckets, cost: cost) }
    }
}

public enum WarrenUsageBarsBuilder {
    /// The chart's reach. A month of daily bars is as many as stay legible at
    /// the settings width; the heatmap above already carries the longer view.
    public static let windowDays = 30

    /// Bars for the last `windowDays` days of the range, oldest first.
    ///
    /// Days without activity still get a bar, as in the heatmap: a gap is
    /// information, and dropping it would close up a quiet week. Weeks follow
    /// the calendar's own first weekday so a week bar covers the same days as a
    /// heatmap column.
    public static func build(
        days: [WarrenUsageDay],
        fromDay: String,
        toDay: String,
        grouping: WarrenUsageBarGrouping,
        windowDays: Int = windowDays,
        calendar: Calendar = .current
    ) -> [WarrenUsageBar] {
        let formatter = dayFormatter(calendar: calendar)
        guard windowDays > 0,
              let rangeStart = formatter.date(from: fromDay),
              let end = formatter.date(from: toDay),
              rangeStart <= end,
              let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: end) else {
            return []
        }
        let start = max(rangeStart, windowStart)

        var byDay: [String: WarrenUsageDay] = [:]
        for day in days {
            byDay[day.day] = day
        }

        var dailyBars: [(date: Date, bar: WarrenUsageBar)] = []
        var cursor = start
        while cursor <= end {
            let key = formatter.string(from: cursor)
            let entry = byDay[key]
            dailyBars.append((
                cursor,
                WarrenUsageBar(
                    days: [key],
                    buckets: entry?.buckets ?? WarrenUsageBuckets(),
                    cost: entry?.cost ?? WarrenUsageCost()
                )
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        guard grouping == .week else { return dailyBars.map(\.bar) }

        var weeks: [WarrenUsageBar] = []
        var currentWeek: Date?
        var pending: [WarrenUsageBar] = []
        func flush() {
            guard !pending.isEmpty else { return }
            weeks.append(
                WarrenUsageBar(
                    days: pending.flatMap(\.days),
                    buckets: pending.dropFirst().reduce(pending[0].buckets) { $0.adding($1.buckets) },
                    cost: pending.dropFirst().reduce(pending[0].cost) { $0.adding($1.cost) },
                    isPartial: pending.count < 7
                )
            )
            pending = []
        }
        for entry in dailyBars {
            let week = calendar.dateInterval(of: .weekOfYear, for: entry.date)?.start
            if week != currentWeek {
                flush()
                currentWeek = week
            }
            pending.append(entry.bar)
        }
        flush()
        return weeks
    }

    /// A round top for the value axis and the step its grid lines fall on.
    ///
    /// The step is 1, 2 or 5 of a power of ten, and the top a whole number of
    /// steps, so every grid label reads as a figure a person would say aloud
    /// rather than "US$7.83". Never zero, so an empty window still divides.
    public static func scale(peak: Double) -> (top: Double, step: Double) {
        guard peak > 0, peak.isFinite else { return (1, 0.5) }
        let power = pow(10, (log10(peak)).rounded(.down))
        let mantissa = peak / power
        let unit: Double
        switch mantissa {
        case ...1.5: unit = 0.5
        case ...3: unit = 1
        case ...6: unit = 2
        default: unit = 5
        }
        let step = unit * power
        return ((peak / step).rounded(.up) * step, step)
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// The text of the floating readout the daily bars and the heatmap share.
///
/// Built apart from the view so both surfaces phrase a day identically, and so
/// the phrasing is testable without rendering.
public struct WarrenUsageReadoutContent: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let bucket: WarrenUsageBucket
        public let value: String
    }

    public let title: String
    /// The figure in the unit being plotted.
    public let total: String
    /// The other unit, so a cost bar still says how many tokens it moved.
    public let secondary: String?
    public let rows: [Row]
    /// Why the amount is a lower bound, when it is one.
    public let caveat: String?
    /// What a click does.
    public let hint: String?

    public static func make(
        title: String,
        buckets: WarrenUsageBuckets,
        cost: WarrenUsageCost,
        metric: WarrenUsageCurveMetric,
        hint: String?
    ) -> WarrenUsageReadoutContent {
        guard buckets.total > 0 || cost.nanoUSD > 0 else {
            return WarrenUsageReadoutContent(
                title: title, total: "No activity", secondary: nil, rows: [], caveat: nil, hint: nil
            )
        }
        let tokenText = "\(WarrenUsageFormatting.tokens(buckets.total)) tokens"
        let moneyText = WarrenUsageFormatting.money(cost)
        let rows = WarrenUsageBucket.allCases.map { bucket in
            Row(
                bucket: bucket,
                value: metric == .cost
                    ? WarrenUsageFormatting.money(bucket.value(.cost, buckets: buckets, cost: cost))
                    : WarrenUsageFormatting.tokens(bucket.tokens(in: buckets))
            )
        }
        return WarrenUsageReadoutContent(
            title: title,
            total: metric == .cost ? moneyText : tokenText,
            secondary: metric == .cost ? tokenText : moneyText,
            rows: rows,
            caveat: WarrenUsageFormatting.incompleteReason(cost),
            hint: hint
        )
    }
}

/// Where the readout sits beside the thing it describes.
public enum WarrenUsageReadoutPlacement {
    /// The readout's top-left corner, in the coordinate space of `bounds`.
    ///
    /// It sits to the right of the anchor and flips to the left when it would
    /// leave the chart, so it never covers the bar it is reading out. Vertically
    /// it starts a little above the anchor and stays inside the bounds; a chart
    /// shorter than the readout centres it instead, overhanging both edges
    /// evenly rather than all of it at the bottom.
    public static func origin(
        anchor: CGRect,
        size: CGSize,
        bounds: CGSize,
        gap: CGFloat = 12,
        lift: CGFloat = 20
    ) -> CGPoint {
        var x = anchor.maxX + gap
        if x + size.width > bounds.width {
            x = anchor.minX - gap - size.width
        }
        x = min(max(x, 0), max(bounds.width - size.width, 0))

        let centred = (bounds.height - size.height) / 2
        let lowest = min(0, centred)
        let highest = max(bounds.height - size.height, centred)
        let y = min(max(anchor.minY - lift, lowest), highest)
        return CGPoint(x: x, y: y)
    }
}
