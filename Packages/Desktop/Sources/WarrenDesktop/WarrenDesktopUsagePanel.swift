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
    /// Range totals, the activity heatmap, and the range breakdowns.
    case overview
    /// One day: its intraday curve and its own breakdowns.
    case detail
}

/// The Usage panels.
///
/// One view drives both settings surfaces so the range picker, heatmap, and
/// day scoping have a single implementation. The Overview heatmap and the
/// Detail heatmap are the same control: picking a day in either one selects it,
/// so there is never a day the UI shows but cannot fetch.
public struct WarrenDesktopUsagePanel: View {
    let stats: WarrenUsageStats
    let state: WarrenUsageLoadState
    let tokens: WarrenColorTokens
    @Binding var range: WarrenUsageRange
    /// The day the person picked, or nil to follow the Host's most recent day.
    @Binding var selectedDay: String?
    /// Requests a fetch for a day range and an optional detail day.
    let onLoad: (_ days: Int, _ day: String?, _ force: Bool) -> Void
    /// Switches to the detail surface. Overview uses it to open the day the
    /// person clicked instead of leaving the click inert.
    let onOpenDetail: ((String) -> Void)?
    let mode: WarrenUsagePanelMode

    @State private var curveGranularity: WarrenUsageCurveGranularity = .halfHour
    @State private var curveMetric: WarrenUsageCurveMetric = .tokens

    public init(
        stats: WarrenUsageStats,
        state: WarrenUsageLoadState,
        tokens: WarrenColorTokens,
        range: Binding<WarrenUsageRange>,
        selectedDay: Binding<String?>,
        onLoad: @escaping (_ days: Int, _ day: String?, _ force: Bool) -> Void,
        onOpenDetail: ((String) -> Void)? = nil,
        mode: WarrenUsagePanelMode = .detail
    ) {
        self.stats = stats
        self.state = state
        self.tokens = tokens
        self._range = range
        self._selectedDay = selectedDay
        self.onLoad = onLoad
        self.onOpenDetail = onOpenDetail
        self.mode = mode
    }

    private var heatmap: WarrenUsageHeatmap {
        WarrenUsageHeatmapBuilder.build(
            days: stats.days, fromDay: stats.fromDay, toDay: stats.toDay
        )
    }

    /// The day every detail surface renders. Falls back to the Host's default
    /// so the curve has something to draw before a day is picked.
    private var detailDay: String? {
        stats.resolvedDetailDay(selected: selectedDay)
    }

    private var detailDayStats: WarrenUsageDay? {
        guard let detailDay else { return nil }
        return stats.days.first { $0.day == detailDay }
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
            onLoad(range.days, nil, false)
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

    // MARK: - Overview

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.large) {
            summaryGrid
            heatmapCard(subtitle: "Every day in range, shaded by tokens")
            breakdownHint
            breakdowns(providers: stats.providers, models: stats.models, projects: stats.projects)
            footnote
        }
    }

    private var breakdownHint: some View {
        Text("Click a day above to open its intraday curve and breakdown.")
            .font(WarrenTypography.settingsMeta)
            .foregroundStyle(tokens.mutedForeground)
    }

    // MARK: - Detail

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.large) {
            heatmapCard(subtitle: "Select a day to inspect")
            detailStrip
            WarrenDesktopUsageCurveView(
                intervals: stats.intervals,
                day: detailDay,
                baseBucketMinutes: stats.intervalBucketMinutes,
                tokens: tokens,
                granularity: $curveGranularity,
                metric: $curveMetric
            )
            dayBreakdowns
            footnote
        }
    }

    /// Shows the selected day, and its cost and token composition, so the strip
    /// answers "what am I looking at" before the curve is read.
    private var detailStrip: some View {
        // When a day is named but has no rows, show zeros rather than the range
        // total under a day heading: a title that disagrees with its figures is
        // worse than an empty day.
        let buckets = detailDayStats?.buckets ?? WarrenUsageBuckets()
        let cost = detailDayStats?.cost ?? WarrenUsageCost()
        let title = detailDay.map { WarrenUsageFormatting.dayLabel($0) }
            ?? "\(range.label) total"
        let share = WarrenUsageFormatting.percent(buckets.cacheHitRate ?? 0)

        return VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            HStack(spacing: WarrenSpacing.small) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text(title)
                        .font(WarrenTypography.settingsBodyEmphasis)
                    Text("Cache hit \(share) · \(WarrenUsageFormatting.tokens(cost.calls)) calls")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }
                Spacer(minLength: 0)
                if selectedDay != nil {
                    Button("Show latest") {
                        selectedDay = nil
                        onLoad(range.days, nil, false)
                    }
                    .buttonStyle(.plain)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.link)
                }
                Text(WarrenUsageFormatting.money(cost))
                    .font(WarrenTypography.settingsSectionTitle)
                    .foregroundStyle(tokens.highlight)
                    .monospacedDigit()
            }
            bucketBar(buckets)
            bucketLegend(buckets)
        }
        .padding(WarrenSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .accessibilityIdentifier("usage.detail")
    }

    private var dayBreakdowns: some View {
        // The Host narrows these to the selected day. Against an older Host that
        // sends no day groups at all (`detailDay` absent), fall back to the range
        // breakdowns rather than showing an empty section. A new Host that names
        // a quiet day legitimately sends empty groups, and that must stay empty.
        let hasDayScope = stats.detailDay != nil
        let providers = hasDayScope ? stats.dayProviders : stats.providers
        let models = hasDayScope ? stats.dayModels : stats.models
        let projects = hasDayScope ? stats.dayProjects : stats.projects
        return breakdowns(
            providers: providers,
            models: models,
            projects: projects,
            heading: hasDayScope ? "Day breakdown" : "Range breakdown"
        )
    }

    // MARK: - Shared pieces

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
                onLoad(range.days, selectedDay, true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .font(WarrenTypography.settingsSupporting)
            .accessibilityIdentifier("usage.refresh")
        }
    }

    private func heatmapCard(subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(WarrenTypography.settingsBodyEmphasis)
                Text(subtitle)
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer(minLength: 0)
                if stats.fromDay.isEmpty == false {
                    Text("\(WarrenUsageFormatting.dayLabel(stats.fromDay)) – \(WarrenUsageFormatting.dayLabel(stats.toDay))")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                }
            }
            WarrenDesktopUsageHeatmapView(
                heatmap: heatmap,
                tokens: tokens,
                selectedDay: heatmapSelection
            )
        }
        .padding(WarrenSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                .fill(tokens.chromeSurface)
        )
    }

    /// The heatmap writes through the same selection the detail surface reads.
    /// Overview additionally opens the detail page so a click leads somewhere;
    /// that page fetches on appear, so Overview does not request twice.
    private var heatmapSelection: Binding<String?> {
        Binding(
            get: { selectedDay },
            set: { day in
                guard let day else {
                    selectedDay = nil
                    return
                }
                selectedDay = day
                if mode == .overview, let onOpenDetail {
                    onOpenDetail(day)
                } else {
                    onLoad(range.days, day, false)
                }
            }
        )
    }

    private var summaryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 148, maximum: 320), spacing: WarrenSpacing.medium)],
            alignment: .leading,
            spacing: WarrenSpacing.medium
        ) {
            metricCard(
                "Cost",
                WarrenUsageFormatting.money(stats.cost),
                icon: "dollarsign.circle",
                accent: tokens.highlight
            )
            metricCard(
                "Tokens",
                WarrenUsageFormatting.tokens(stats.total.total),
                icon: "number",
                accent: tokens.info
            )
            metricCard(
                "Calls",
                WarrenUsageFormatting.tokens(stats.cost.calls),
                icon: "arrow.left.arrow.right",
                accent: tokens.success
            )
            metricCard(
                "Cache hit",
                stats.total.cacheHitRate.map(WarrenUsageFormatting.percent) ?? "—",
                icon: "bolt.horizontal.circle",
                accent: tokens.warning
            )
            metricCard(
                "Per call",
                stats.cost.calls > 0
                    ? WarrenUsageFormatting.money(stats.cost.usd / Double(stats.cost.calls))
                    : "—",
                icon: "divide.circle",
                accent: tokens.link
            )
        }
    }

    private func metricCard(_ label: String, _ value: String, icon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            HStack(spacing: WarrenSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(label)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
            }
            Text(value)
                .font(WarrenTypography.settingsSectionTitle)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WarrenSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                .fill(tokens.fillHover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
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
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }

    private func bucketLegend(_ buckets: WarrenUsageBuckets) -> some View {
        let total = max(buckets.total, 1)
        return HStack(spacing: WarrenSpacing.standard) {
            bucketKey("Fresh input", buckets.freshInput, total, tokens.highlight)
            bucketKey("Cache write", buckets.cacheWrite, total, tokens.warning)
            bucketKey("Cache read", buckets.cacheRead, total, tokens.info)
            bucketKey("Output", buckets.output, total, tokens.success)
        }
    }

    private func bucketKey(_ label: String, _ value: Int64, _ total: Int64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            HStack(spacing: WarrenSpacing.xs) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
            }
            HStack(spacing: WarrenSpacing.xs) {
                Text(WarrenUsageFormatting.tokens(value))
                    .font(WarrenTypography.settingsSupporting)
                    .monospacedDigit()
                Text(WarrenUsageFormatting.percent(Double(value) / Double(total)))
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdowns(
        providers: [WarrenUsageGroup],
        models: [WarrenUsageGroup],
        projects: [WarrenUsageGroup],
        heading: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            if let heading {
                Text(heading)
                    .font(WarrenTypography.settingsBodyEmphasis)
            }
            // Three dimensions side by side rather than behind tabs: they answer
            // different questions about the same range and are usually read together.
            HStack(alignment: .top, spacing: WarrenSpacing.large) {
                breakdown("By agent", groups: providers)
                breakdown("By model", groups: models)
                breakdown("By project", groups: projects)
            }
        }
    }

    private func breakdown(_ title: String, groups: [WarrenUsageGroup]) -> some View {
        let peak = groups.map(\.buckets.total).max() ?? 0
        let total = groups.map(\.buckets.total).reduce(0, +)
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
                    groupRow(group, peak: peak, total: total)
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

    private func groupRow(_ group: WarrenUsageGroup, peak: Int64, total: Int64) -> some View {
        let share = total > 0 ? Double(group.buckets.total) / Double(total) : 0
        return VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            HStack(spacing: WarrenSpacing.small) {
                Text(group.displayName)
                    .font(WarrenTypography.settingsSupporting)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: WarrenSpacing.xs)
                Text(WarrenUsageFormatting.percent(share))
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .monospacedDigit()
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
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            Text(text)
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WarrenSpacing.large)
        .accessibilityIdentifier("usage.placeholder")
    }

    private func failureNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.destructive)
            Button("Try again") { onLoad(range.days, selectedDay, true) }
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
    @Binding private var selectedDay: String?
    private let onLoad: (Int, String?, Bool) -> Void
    private let onOpenDetail: ((String) -> Void)?

    public init(
        stats: WarrenUsageStats,
        state: WarrenUsageLoadState,
        tokens: WarrenColorTokens,
        range: Binding<WarrenUsageRange>,
        selectedDay: Binding<String?>,
        onLoad: @escaping (Int, String?, Bool) -> Void,
        onOpenDetail: ((String) -> Void)? = nil
    ) {
        self.stats = stats
        self.state = state
        self.tokens = tokens
        self._range = range
        self._selectedDay = selectedDay
        self.onLoad = onLoad
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        WarrenDesktopUsagePanel(
            stats: stats,
            state: state,
            tokens: tokens,
            range: $range,
            selectedDay: $selectedDay,
            onLoad: onLoad,
            onOpenDetail: onOpenDetail,
            mode: .overview
        )
    }
}
