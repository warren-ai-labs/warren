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

    /// A call count, which is a count of things rather than a token magnitude.
    ///
    /// Separate from `tokens` because the compact form is only right for the
    /// latter: 12,400 calls abbreviated to "12K calls" hides the digit a person
    /// is actually comparing between two days.
    public static func calls(_ value: Int64) -> String {
        value == 1 ? "1 call" : "\(exact(value)) calls"
    }

    /// One sentence describing what a Usage rebuild replaced.
    public static func rebuildOutcome(_ summary: WarrenUsageRebuildSummary) -> String {
        let providers = summary.providers.isEmpty
            ? "no Agent"
            : summary.providers.joined(separator: ", ")
        var text = "Replaced \(providers): \(calls(summary.calls)) across "
            + "\(summary.days) \(summary.days == 1 ? "day" : "days")."
        if summary.collapsedRepeats > 0 {
            text += " \(exact(summary.collapsedRepeats)) repeated measurements were counted once."
        }
        return text
    }

    /// How old the stored figures are.
    ///
    /// The gap is the useful fact, not the instant: a rebuild from three releases
    /// ago produces numbers that look exactly like current ones. When nothing has
    /// been rebuilt this says so rather than going quiet, since that is the state
    /// in which the figures are most likely to be wrong.
    public static func rebuildAge(
        _ stamp: WarrenUsageRebuildStamp?,
        now: Date = Date()
    ) -> String {
        guard let stamp else {
            return "Never rebuilt"
        }
        // Relative formatting renders a rebuild that just finished as "in 0
        // seconds", and a Host clock a little ahead of this one pushes it into the
        // future, so the first minute is stated plainly instead.
        let elapsed = now.timeIntervalSince(stamp.completedAt)
        let age = elapsed < 60
            ? "just now"
            : stamp.completedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        guard !stamp.providers.isEmpty else {
            return "Rebuilt \(age)"
        }
        return "Rebuilt \(age) · \(stamp.providers.joined(separator: ", "))"
    }

    /// Explains why a figure is incomplete, or nil when it is not.
    ///
    /// Kept as one function so every surface phrases the caveat identically, and
    /// it names what is missing rather than only how much: an unpriced model is
    /// one catalog entry away from being fixed, and without the name nobody can
    /// tell which entry.
    public static func incompleteReason(_ cost: WarrenUsageCost) -> String? {
        if cost.isComplete { return nil }
        var reasons: [String] = []
        if cost.unpricedCalls > 0 {
            var reason = "\(calls(cost.unpricedCalls)) had no published price"
            if !cost.unpricedModels.isEmpty {
                reason += " (\(cost.unpricedModels.joined(separator: ", ")))"
            }
            reasons.append(reason)
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
