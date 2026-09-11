import Foundation

/// Number and money formatting for the usage panel.
public enum WarrenUsageFormatting {
    /// Compact token count: 1.2M, 943K, 512.
    ///
    /// Token counts routinely reach hundreds of millions, where exact digits are
    /// noise. The precise value stays available in tooltips.
    public static func tokens(_ value: Int64) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 1_000_000_000...:
            return trimmed(Double(value) / 1_000_000_000) + "B"
        case 1_000_000...:
            return trimmed(Double(value) / 1_000_000) + "M"
        case 10_000...:
            return trimmed(Double(value) / 1_000) + "K"
        default:
            return exact(value)
        }
    }

    /// Exact token count with digit grouping, for tooltips.
    public static func exact(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Money, with precision scaled to magnitude.
    ///
    /// A single call can cost a fraction of a cent while a month reaches tens of
    /// dollars. A fixed 2-decimal format would render most single calls as
    /// "$0.00", which reads as free.
    public static func money(_ usd: Double) -> String {
        let magnitude = abs(usd)
        let fractionDigits: Int
        switch magnitude {
        case 0:
            fractionDigits = 2
        case ..<0.01:
            fractionDigits = 4
        case ..<1:
            fractionDigits = 3
        default:
            fractionDigits = 2
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = .autoupdatingCurrent
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: usd)) ?? String(format: "$%.2f", usd)
    }

    /// Money with a marker when the amount is a lower bound.
    ///
    /// The prefix is the panel's only honest way to show a total whose price was
    /// partly unknown. Rendering the bare number would overstate confidence.
    public static func money(_ cost: WarrenUsageCost) -> String {
        let text = money(cost.usd)
        return cost.isComplete ? text : "≥ " + text
    }

    /// Percentage with one decimal.
    public static func percent(_ ratio: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.locale = .autoupdatingCurrent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: ratio)) ?? "—"
    }

    /// Long-form day for tooltips, from a `yyyy-MM-dd` key.
    public static func dayLabel(_ day: String, calendar: Calendar = .current) -> String {
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let display = DateFormatter()
        display.calendar = calendar
        display.locale = .autoupdatingCurrent
        display.timeZone = calendar.timeZone
        display.setLocalizedDateFormatFromTemplate("EEE MMM d, yyyy")
        return display.string(from: date)
    }

    /// Explains why a figure is incomplete, or nil when it is not.
    ///
    /// Kept as one function so every surface phrases the caveat identically.
    public static func incompleteReason(_ cost: WarrenUsageCost) -> String? {
        if cost.isComplete { return nil }
        var reasons: [String] = []
        let unpriced = cost.calls - cost.pricedCalls
        if unpriced > 0 {
            let calls = unpriced == 1 ? "1 call" : "\(exact(unpriced)) calls"
            reasons.append("\(calls) had no published price")
        }
        if !cost.unmeasuredProviders.isEmpty {
            let names = cost.unmeasuredProviders.joined(separator: ", ")
            reasons.append("\(names) report no token counts")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    private static func trimmed(_ value: Double) -> String {
        // One decimal, dropped when it would read as a trailing .0.
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}
