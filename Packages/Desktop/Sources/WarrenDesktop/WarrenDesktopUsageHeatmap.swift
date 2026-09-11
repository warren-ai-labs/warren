import Foundation

/// One cell of the heatmap grid.
public struct WarrenUsageHeatmapCell: Equatable, Sendable, Identifiable {
    public let day: String
    /// Column from the left, one per week.
    public let week: Int
    /// Row within the week, 0 = the grid's first weekday.
    public let weekday: Int
    public let tokens: Int64
    public let cost: WarrenUsageCost
    /// Intensity from 0 to 1 used to pick a shade. Zero-token days are nil so
    /// they render as the empty track rather than the lightest active shade.
    public let intensity: Double?

    public var id: String { day }

    public init(
        day: String,
        week: Int,
        weekday: Int,
        tokens: Int64,
        cost: WarrenUsageCost,
        intensity: Double?
    ) {
        self.day = day
        self.week = week
        self.weekday = weekday
        self.tokens = tokens
        self.cost = cost
        self.intensity = intensity
    }

    /// True when this day's cost is a lower bound, which the cell marks so an
    /// incomplete figure is not mistaken for a precise one.
    public var hasIncompleteCost: Bool { tokens > 0 && !cost.isComplete }
}

/// A calendar grid of daily token usage, laid out in week columns.
///
/// Cells are keyed on tokens rather than cost deliberately: token counts exist
/// for every measured provider, while cost is missing wherever a model has no
/// published price. Encoding cost would leave real work looking like an empty
/// day, which is exactly the impression the grid must not give.
public struct WarrenUsageHeatmap: Equatable, Sendable {
    public let cells: [WarrenUsageHeatmapCell]
    public let weekCount: Int
    /// Highest single-day token count, the top of the intensity scale.
    public let peakTokens: Int64
    /// Month labels for the columns where a new month starts.
    public let monthLabels: [WarrenUsageHeatmapMonthLabel]

    public init(
        cells: [WarrenUsageHeatmapCell],
        weekCount: Int,
        peakTokens: Int64,
        monthLabels: [WarrenUsageHeatmapMonthLabel]
    ) {
        self.cells = cells
        self.weekCount = weekCount
        self.peakTokens = peakTokens
        self.monthLabels = monthLabels
    }

    public static let empty = WarrenUsageHeatmap(
        cells: [], weekCount: 0, peakTokens: 0, monthLabels: []
    )
}

/// A month name anchored to the grid column where that month begins.
public struct WarrenUsageHeatmapMonthLabel: Equatable, Sendable, Identifiable {
    public let week: Int
    public let text: String

    public var id: Int { week }

    public init(week: Int, text: String) {
        self.week = week
        self.text = text
    }
}

public enum WarrenUsageHeatmapBuilder {
    /// Number of shades the scale is quantized into, excluding the empty state.
    public static let shadeCount = 4

    /// Build the grid for an inclusive day range.
    ///
    /// The range is laid out continuously so that days with no activity still
    /// occupy a cell: gaps are information, and collapsing them would make a
    /// quiet week indistinguishable from a busy one.
    ///
    /// - Parameters:
    ///   - days: Daily aggregates. Days absent here are rendered as empty.
    ///   - fromDay: First day, `yyyy-MM-dd`.
    ///   - toDay: Last day, inclusive.
    ///   - calendar: Calendar used for week alignment, injected for tests.
    public static func build(
        days: [WarrenUsageDay],
        fromDay: String,
        toDay: String,
        calendar: Calendar = .current
    ) -> WarrenUsageHeatmap {
        let formatter = dayFormatter(calendar: calendar)
        guard let start = formatter.date(from: fromDay),
              let end = formatter.date(from: toDay),
              start <= end else {
            return .empty
        }

        var byDay: [String: WarrenUsageDay] = [:]
        for day in days {
            byDay[day.day] = day
        }
        let peak = days.map(\.buckets.total).max() ?? 0

        // Align the first column to the calendar's own first weekday so the
        // rows read as the week the person's locale actually uses.
        let startWeekday = calendar.component(.weekday, from: start)
        let leadingOffset = (startWeekday - calendar.firstWeekday + 7) % 7

        var cells: [WarrenUsageHeatmapCell] = []
        var monthLabels: [WarrenUsageHeatmapMonthLabel] = []
        var lastLabeledMonth = -1
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = .autoupdatingCurrent
        monthFormatter.setLocalizedDateFormatFromTemplate("MMM")

        var cursor = start
        var index = 0
        while cursor <= end {
            let key = formatter.string(from: cursor)
            let position = leadingOffset + index
            let week = position / 7
            let weekday = position % 7
            let entry = byDay[key]
            let tokens = entry?.buckets.total ?? 0

            cells.append(
                WarrenUsageHeatmapCell(
                    day: key,
                    week: week,
                    weekday: weekday,
                    tokens: tokens,
                    cost: entry?.cost ?? WarrenUsageCost(),
                    intensity: intensity(tokens: tokens, peak: peak)
                )
            )

            let month = calendar.component(.month, from: cursor)
            // Label a month at its first column, and only when that column has
            // room to render the name without colliding with the next.
            if month != lastLabeledMonth, weekday == 0 || index == 0 {
                if monthLabels.last?.week != week {
                    monthLabels.append(
                        WarrenUsageHeatmapMonthLabel(
                            week: week,
                            text: monthFormatter.string(from: cursor)
                        )
                    )
                }
                lastLabeledMonth = month
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            index += 1
        }

        let weekCount = (cells.last?.week ?? -1) + 1
        return WarrenUsageHeatmap(
            cells: cells,
            weekCount: weekCount,
            peakTokens: peak,
            monthLabels: monthLabels
        )
    }

    /// Map a day's tokens onto the shade scale.
    ///
    /// The scale is a fourth root rather than linear because daily usage spans
    /// orders of magnitude: under a linear ramp a single heavy day flattens
    /// every ordinary one into the lightest shade, which hides exactly the
    /// day-to-day variation the grid exists to show.
    static func intensity(tokens: Int64, peak: Int64) -> Double? {
        guard tokens > 0, peak > 0 else { return nil }
        let ratio = Double(tokens) / Double(peak)
        let eased = pow(ratio.clamped(to: 0...1), 0.25)
        // Quantize so cells read as a small set of steps, and keep any nonzero
        // day at the first active step rather than rounding it away to empty.
        let step = (eased * Double(shadeCount)).rounded(.up)
        return max(1, min(Double(shadeCount), step)) / Double(shadeCount)
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        // Fixed format and POSIX locale: these keys come from the Host as
        // yyyy-MM-dd and must not be reinterpreted by the user's locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
