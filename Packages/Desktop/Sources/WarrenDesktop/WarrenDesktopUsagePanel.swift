import SwiftUI
import WarrenDesignSystem

/// Selectable ranges for the usage panel.
public enum WarrenUsageRange: String, CaseIterable, Identifiable, Sendable {
    case week = "7d"
    case month = "30d"
    case quarter = "90d"
    case year = "1y"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    public var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .year: "Year"
        }
    }
}

/// Load state, so the panel can tell "nothing recorded yet" apart from
/// "not fetched yet" and from an outright failure.
public enum WarrenUsageLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Which part of Usage a settings page should render.
public enum WarrenUsagePanelMode: Sendable {
    case overview
    case detail
}

/// The detailed intraday Usage panel.
public struct WarrenDesktopUsagePanel: View {
    let stats: WarrenUsageStats
    let state: WarrenUsageLoadState
    let tokens: WarrenColorTokens
    @Binding var range: WarrenUsageRange
    let onReload: () -> Void
    let mode: WarrenUsagePanelMode

    @State private var selectedDay: String?
    @State private var curveGranularity: WarrenUsageCurveGranularity = .halfHour

    public init(
        stats: WarrenUsageStats,
        state: WarrenUsageLoadState,
        tokens: WarrenColorTokens,
        range: Binding<WarrenUsageRange>,
        onReload: @escaping () -> Void,
        mode: WarrenUsagePanelMode = .detail
    ) {
        self.stats = stats
        self.state = state
        self.tokens = tokens
        self._range = range
        self.onReload = onReload
        self.mode = mode
    }

    private var heatmap: WarrenUsageHeatmap {
        WarrenUsageHeatmapBuilder.build(
            days: stats.days, fromDay: stats.fromDay, toDay: stats.toDay
        )
    }

    private var selectedDayStats: WarrenUsageDay? {
        guard let selectedDay else { return nil }
        return stats.days.first { $0.day == selectedDay }
    }

    private var curveDay: String? {
        if let selectedDay {
            return selectedDay
        }
        return stats.intervals.map(\.day).max() ?? stats.days.map(\.day).max()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.large) {
            rangePicker
            switch state {
            case .failed(let message):
                failureNotice(message)
            case .loading where stats.isEmpty:
                placeholder("Loading usage…")
            case .idle where stats.isEmpty:
                placeholder("Loading usage…")
            default:
                if stats.isEmpty {
                    placeholder("No Agent token usage recorded in this range.")
                } else {
                    content
                }
            }
        }
        // Single-argument onChange: the package's macOS 13 baseline predates the
        // two-argument form.
        .onChange(of: range) { _ in
            // A day selected in one range may not exist in the next.
            selectedDay = nil
            onReload()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .overview:
            overviewContent
        case .detail:
            detailContent
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.large) {
            WarrenDesktopUsageHeatmapView(
                heatmap: heatmap, tokens: tokens, selectedDay: .constant(nil)
            )
            summaryRow
            breakdowns
            footnote
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.large) {
            dayPicker
            detailStrip
            WarrenDesktopUsageCurveView(
                intervals: stats.intervals,
                day: curveDay,
                baseBucketMinutes: stats.intervalBucketMinutes,
                tokens: tokens,
                granularity: $curveGranularity
            )
        }
    }

    private var dayPicker: some View {
        let days = stats.days.map(\.day).sorted().reversed()
        return Group {
            if !days.isEmpty {
                Picker("Day", selection: selectedDayBinding) {
                    ForEach(Array(days), id: \.self) { day in
                        Text(WarrenUsageFormatting.dayLabel(day)).tag(day)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Usage day")
                .accessibilityIdentifier("usage.day")
            }
        }
    }

    private var selectedDayBinding: Binding<String> {
        Binding(
            get: { selectedDay ?? curveDay ?? "" },
            set: { selectedDay = $0.isEmpty ? nil : $0 }
        )
    }

    private var rangePicker: some View {
        HStack(spacing: WarrenSpacing.medium) {
            Picker("Range", selection: $range) {
                ForEach(WarrenUsageRange.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .accessibilityIdentifier("usage.range")

            Spacer(minLength: 0)

            if state == .loading {
                ProgressView().controlSize(.small)
            }
            Button {
                onReload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .font(WarrenTypography.settingsSupporting)
            .accessibilityIdentifier("usage.refresh")
        }
    }

    /// Shows the selected day, or the whole range when no day is selected, so
    /// the same row answers "what am I looking at" in both modes.
    private var detailStrip: some View {
        let buckets = selectedDayStats?.buckets ?? stats.total
        let cost = selectedDayStats?.cost ?? stats.cost
        let title = selectedDayStats.map { WarrenUsageFormatting.dayLabel($0.day) }
            ?? "\(range.label) total"

        return VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(spacing: WarrenSpacing.compact) {
                Text(title)
                    .font(WarrenTypography.settingsBodyEmphasis)
                if selectedDay != nil {
                    Button("Clear") { selectedDay = nil }
                        .buttonStyle(.plain)
                        .font(WarrenTypography.settingsGroupLabel)
                        .foregroundStyle(tokens.link)
                }
                Spacer(minLength: 0)
                Text(WarrenUsageFormatting.money(cost))
                    .font(WarrenTypography.settingsBodyEmphasis)
                    .foregroundStyle(tokens.highlight)
            }
            bucketBar(buckets)
            HStack(spacing: WarrenSpacing.standard) {
                bucketKey("Fresh input", buckets.freshInput, tokens.highlight)
                bucketKey("Cache write", buckets.cacheWrite, tokens.warning)
                bucketKey("Cache read", buckets.cacheRead, tokens.info)
                bucketKey("Output", buckets.output, tokens.success)
            }
        }
        .padding(WarrenSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .accessibilityIdentifier("usage.detail")
    }

    /// Proportional bar over the four disjoint token classes.
    private func bucketBar(_ buckets: WarrenUsageBuckets) -> some View {
        let total = max(buckets.total, 1)
        let parts: [(Int64, Color)] = [
            (buckets.freshInput, tokens.highlight),
            (buckets.cacheWrite, tokens.warning),
            (buckets.cacheRead, tokens.info),
            (buckets.output, tokens.success),
        ]
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.1)
                        .frame(width: geometry.size.width * CGFloat(part.0) / CGFloat(total))
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }

    private func bucketKey(_ label: String, _ value: Int64, _ color: Color) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(WarrenTypography.settingsGroupLabel)
                .foregroundStyle(tokens.mutedForeground)
            Text(WarrenUsageFormatting.tokens(value))
                .font(WarrenTypography.settingsGroupLabel)
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: WarrenSpacing.standard) {
            metric("Tokens", WarrenUsageFormatting.tokens(stats.total.total))
            metric("Calls", WarrenUsageFormatting.tokens(stats.cost.calls))
            metric(
                "Cache hit",
                stats.total.cacheHitRate.map(WarrenUsageFormatting.percent) ?? "—"
            )
            metric(
                "Per call",
                stats.cost.calls > 0
                    ? WarrenUsageFormatting.money(stats.cost.usd / Double(stats.cost.calls))
                    : "—"
            )
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            Text(label)
                .font(WarrenTypography.settingsGroupLabel)
                .foregroundStyle(tokens.mutedForeground)
            Text(value).font(WarrenTypography.settingsSectionTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var breakdowns: some View {
        // Three dimensions side by side rather than behind tabs: they answer
        // different questions about the same range and are usually read together.
        HStack(alignment: .top, spacing: WarrenSpacing.large) {
            breakdown("By agent", groups: stats.providers)
            breakdown("By model", groups: stats.models)
            breakdown("By project", groups: stats.projects)
        }
    }

    private func breakdown(_ title: String, groups: [WarrenUsageGroup]) -> some View {
        let peak = groups.map(\.buckets.total).max() ?? 0
        return VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            Text(title)
                .font(WarrenTypography.settingsGroupLabel)
                .foregroundStyle(tokens.mutedForeground)
            if groups.isEmpty {
                Text("—").font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
            } else {
                // Bounded so one dimension cannot push the others off screen.
                ForEach(groups.prefix(6)) { group in
                    groupRow(group, peak: peak)
                }
                if groups.count > 6 {
                    Text("+\(groups.count - 6) more")
                        .font(WarrenTypography.settingsGroupLabel)
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupRow(_ group: WarrenUsageGroup, peak: Int64) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            HStack(spacing: WarrenSpacing.small) {
                Text(group.displayName)
                    .font(WarrenTypography.settingsSupporting)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: WarrenSpacing.xs)
                Text(WarrenUsageFormatting.money(group.cost))
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                let ratio = peak > 0 ? CGFloat(group.buckets.total) / CGFloat(peak) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tokens.muted.opacity(0.5))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tokens.highlight.opacity(0.8))
                        .frame(width: max(geometry.size.width * ratio, ratio > 0 ? 2 : 0))
                }
            }
            .frame(height: 4)
        }
        .help(
            "\(group.displayName)\n\(WarrenUsageFormatting.exact(group.buckets.total)) tokens\n"
                + WarrenUsageFormatting.money(group.cost)
        )
    }

    /// States what the figures exclude, and how fresh the prices are.
    ///
    /// Present whenever anything is missing: a total that silently omits spend is
    /// worse than one that says what it left out.
    @ViewBuilder
    private var footnote: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            if let reason = WarrenUsageFormatting.incompleteReason(stats.cost) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.warning)
            }
            if let fetched = stats.pricesFetchedAt {
                Text("Prices from models.dev, updated \(fetched.formatted(.relative(presentation: .named)))")
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
            } else {
                Text("Model prices unavailable, so costs are not shown.")
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, WarrenSpacing.large)
            .accessibilityIdentifier("usage.placeholder")
    }

    private func failureNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.destructive)
            Button("Try again", action: onReload)
                .buttonStyle(.bordered)
                .font(WarrenTypography.settingsSupporting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("usage.error")
    }
}

/// Daily totals and cost breakdowns. The detailed `WarrenDesktopUsagePanel`
/// remains a separate view so the settings secondary navigation can keep the
/// overview and intraday curve surfaces independent.
public struct WarrenDesktopUsageOverviewPanel: View {
    private let stats: WarrenUsageStats
    private let state: WarrenUsageLoadState
    private let tokens: WarrenColorTokens
    @Binding private var range: WarrenUsageRange
    private let onReload: () -> Void

    public init(
        stats: WarrenUsageStats,
        state: WarrenUsageLoadState,
        tokens: WarrenColorTokens,
        range: Binding<WarrenUsageRange>,
        onReload: @escaping () -> Void
    ) {
        self.stats = stats
        self.state = state
        self.tokens = tokens
        self._range = range
        self.onReload = onReload
    }

    public var body: some View {
        WarrenDesktopUsagePanel(
            stats: stats,
            state: state,
            tokens: tokens,
            range: $range,
            onReload: onReload,
            mode: .overview
        )
    }
}
