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
    @State private var selectedAgentFilter: String? = nil
    @State private var selectedModelFilter: String? = nil

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
        .onChange(of: range) { _ in
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
        VStack(alignment: .leading, spacing: WarrenSpacing.xlarge) {
            summaryGrid
            heatmapCard(subtitle: "Daily activity across selected range")
            breakdownHint
            breakdowns(providers: stats.providers, models: stats.models, projects: stats.projects)
            footnote
        }
    }

    private var breakdownHint: some View {
        HStack(spacing: WarrenSpacing.xs) {
            Image(systemName: "hand.tap")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(tokens.mutedForeground)
            Text("Click any day in the heatmap to view its intraday curve and breakdown.")
                .font(WarrenTypography.settingsMeta)
                .foregroundStyle(tokens.mutedForeground)
        }
        .padding(.horizontal, WarrenSpacing.xxs)
    }

    // MARK: - Detail

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xlarge) {
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

    private var detailStrip: some View {
        let buckets = detailDayStats?.buckets ?? WarrenUsageBuckets()
        let cost = detailDayStats?.cost ?? WarrenUsageCost()
        let title = detailDay.map { WarrenUsageFormatting.dayLabel($0) }
            ?? "\(range.label) total"
        let share = WarrenUsageFormatting.percent(buckets.cacheHitRate ?? 0)

        return VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            HStack(alignment: .center, spacing: WarrenSpacing.small) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    HStack(spacing: WarrenSpacing.xs) {
                        Circle()
                            .fill(tokens.highlight)
                            .frame(width: 7, height: 7)
                        Text(title)
                            .font(WarrenTypography.settingsBodyEmphasis)
                            .foregroundStyle(tokens.foreground)

                        if let curDay = detailDay, let idx = stats.days.firstIndex(where: { $0.day == curDay }), stats.days.count > 1 {
                            HStack(spacing: 2) {
                                Button {
                                    if idx > 0 {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                            selectedDay = stats.days[idx - 1].day
                                        }
                                        onLoad(range.days, selectedDay, false)
                                    }
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 9, weight: .regular))
                                        .frame(width: 20, height: 20)
                                        .background(tokens.border.opacity(0.18))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(idx == 0)
                                .opacity(idx == 0 ? 0.35 : 1)
                                .help("Previous day")

                                Button {
                                    if idx < stats.days.count - 1 {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                            selectedDay = stats.days[idx + 1].day
                                        }
                                        onLoad(range.days, selectedDay, false)
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .regular))
                                        .frame(width: 20, height: 20)
                                        .background(tokens.border.opacity(0.18))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(idx >= stats.days.count - 1)
                                .opacity(idx >= stats.days.count - 1 ? 0.35 : 1)
                                .help("Next day")
                            }
                            .padding(.leading, WarrenSpacing.xxs)
                        }
                    }
                    Text("Cache hit rate \(share) · \(WarrenUsageFormatting.tokens(cost.calls)) calls")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }

                Spacer(minLength: 0)

                if selectedDay != nil {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedDay = nil
                        }
                        onLoad(range.days, nil, false)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Latest")
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.link)
                    .padding(.horizontal, WarrenSpacing.compact)
                    .padding(.vertical, WarrenSpacing.xxs)
                    .background(tokens.link.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Text(WarrenUsageFormatting.money(cost))
                    .font(WarrenTypography.pageTitle)
                    .foregroundStyle(tokens.highlight)
                    .monospacedDigit()
            }

            bucketBar(buckets)
            bucketLegend(buckets)
        }
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
        )
        .accessibilityIdentifier("usage.detail")
    }

    private var dayBreakdowns: some View {
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

    private var activeFilteredBuckets: WarrenUsageBuckets {
        if let model = selectedModelFilter,
           let match = (stats.detailDay != nil ? stats.dayModels : stats.models).first(where: { $0.key == model }) {
            return match.buckets
        }
        if let agent = selectedAgentFilter,
           let match = (stats.detailDay != nil ? stats.dayProviders : stats.providers).first(where: { $0.key == agent }) {
            return match.buckets
        }
        return stats.total
    }

    private var activeFilteredCost: WarrenUsageCost {
        if let model = selectedModelFilter,
           let match = (stats.detailDay != nil ? stats.dayModels : stats.models).first(where: { $0.key == model }) {
            return match.cost
        }
        if let agent = selectedAgentFilter,
           let match = (stats.detailDay != nil ? stats.dayProviders : stats.providers).first(where: { $0.key == agent }) {
            return match.cost
        }
        return stats.cost
    }

    private var activeFilterLabel: String? {
        if let model = selectedModelFilter {
            return (stats.detailDay != nil ? stats.dayModels : stats.models).first(where: { $0.key == model })?.displayName ?? model
        }
        if let agent = selectedAgentFilter {
            return (stats.detailDay != nil ? stats.dayProviders : stats.providers).first(where: { $0.key == agent })?.displayName ?? agent
        }
        return nil
    }

    private var rangePicker: some View {
        HStack(spacing: WarrenSpacing.small) {
            Picker("Range", selection: $range) {
                ForEach(WarrenUsageRange.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .accessibilityIdentifier("usage.range")

            // Agent filter
            Menu {
                Button("All Agents") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedAgentFilter = nil
                    }
                }
                Divider()
                ForEach(stats.providers) { group in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedAgentFilter = (selectedAgentFilter == group.key) ? nil : group.key
                        }
                    } label: {
                        HStack {
                            Text(group.displayName)
                            if selectedAgentFilter == group.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 11, weight: .regular))
                    Text(selectedAgentFilter.flatMap { key in stats.providers.first { $0.key == key }?.displayName } ?? "All Agents")
                        .font(WarrenTypography.settingsGroupLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .regular))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selectedAgentFilter != nil ? tokens.highlight.opacity(0.12) : tokens.chromeSurface)
                .foregroundStyle(selectedAgentFilter != nil ? tokens.highlight : tokens.foreground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selectedAgentFilter != nil ? tokens.highlight.opacity(0.4) : tokens.border.opacity(0.4), lineWidth: WarrenSpacing.hairline)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("usage.filter.agent")

            // Model filter
            Menu {
                Button("All Models") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedModelFilter = nil
                    }
                }
                Divider()
                ForEach(stats.models) { group in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedModelFilter = (selectedModelFilter == group.key) ? nil : group.key
                        }
                    } label: {
                        HStack {
                            Text(group.displayName)
                            if selectedModelFilter == group.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .regular))
                    Text(selectedModelFilter.flatMap { key in stats.models.first { $0.key == key }?.displayName } ?? "All Models")
                        .font(WarrenTypography.settingsGroupLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .regular))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selectedModelFilter != nil ? tokens.highlight.opacity(0.12) : tokens.chromeSurface)
                .foregroundStyle(selectedModelFilter != nil ? tokens.highlight : tokens.foreground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selectedModelFilter != nil ? tokens.highlight.opacity(0.4) : tokens.border.opacity(0.4), lineWidth: WarrenSpacing.hairline)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("usage.filter.model")

            if selectedAgentFilter != nil || selectedModelFilter != nil {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedAgentFilter = nil
                        selectedModelFilter = nil
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11, weight: .regular))
                        Text("Reset")
                            .font(WarrenTypography.settingsMeta)
                    }
                    .foregroundStyle(tokens.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("usage.filter.reset")
            }

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
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text("Activity Calendar")
                        .font(WarrenTypography.settingsBodyEmphasis)
                        .foregroundStyle(tokens.foreground)
                    Text(subtitle)
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }
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
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
        )
    }

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
        let buckets = activeFilteredBuckets
        let cost = activeFilteredCost
        let filterLabel = activeFilterLabel

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160, maximum: 340), spacing: WarrenSpacing.standard)],
            alignment: .leading,
            spacing: WarrenSpacing.standard
        ) {
            metricCard(
                "Estimated Spend",
                WarrenUsageFormatting.money(cost),
                subtitle: filterLabel != nil
                    ? "Filtered by \(filterLabel!)"
                    : (cost.calls > 0 ? "\(WarrenUsageFormatting.money(cost.usd / Double(cost.calls))) / call avg" : "No priced calls"),
                icon: "dollarsign.circle",
                accent: tokens.highlight
            )
            metricCard(
                "Total Tokens",
                WarrenUsageFormatting.tokens(buckets.total),
                subtitle: "\(WarrenUsageFormatting.tokens(buckets.freshInput)) fresh · \(WarrenUsageFormatting.tokens(buckets.output)) out",
                icon: "sparkles",
                accent: tokens.info
            )
            metricCard(
                "Cache Hit Rate",
                buckets.cacheHitRate.map(WarrenUsageFormatting.percent) ?? "—",
                subtitle: "\(WarrenUsageFormatting.tokens(buckets.cacheRead)) read (\(WarrenUsageFormatting.tokens(buckets.cacheWrite)) write)",
                icon: "bolt.shield",
                accent: tokens.warning
            )
            metricCard(
                "API Activity",
                "\(WarrenUsageFormatting.tokens(cost.calls)) calls",
                subtitle: filterLabel != nil
                    ? "Calls in selection"
                    : "\(stats.days.filter { $0.buckets.total > 0 }.count) active days in range",
                icon: "waveform.path.ecg",
                accent: tokens.success
            )
        }
    }

    private func metricCard(
        _ label: String,
        _ value: String,
        subtitle: String? = nil,
        icon: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(spacing: WarrenSpacing.small) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.opacity(0.10))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(accent)
                }
                Text(label)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
            }

            Text(value)
                .font(WarrenTypography.pageTitle)
                .foregroundStyle(tokens.foreground)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let subtitle {
                Text(subtitle)
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.35), lineWidth: WarrenSpacing.hairline)
        )
    }

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
        .frame(height: 7)
        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
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
                    .foregroundStyle(tokens.foreground)
            }
            HStack(alignment: .top, spacing: WarrenSpacing.standard) {
                breakdownCard(
                    "By Agent",
                    icon: "person.2",
                    groups: providers,
                    selectedKey: selectedAgentFilter,
                    onSelect: { group in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedAgentFilter = (selectedAgentFilter == group.key) ? nil : group.key
                        }
                    }
                )
                breakdownCard(
                    "By Model",
                    icon: "cpu",
                    groups: models,
                    selectedKey: selectedModelFilter,
                    onSelect: { group in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedModelFilter = (selectedModelFilter == group.key) ? nil : group.key
                        }
                    }
                )
                breakdownCard(
                    "By Project",
                    icon: "folder",
                    groups: projects,
                    selectedKey: nil,
                    onSelect: nil
                )
            }
        }
    }

    private func brandColor(for key: String) -> Color {
        let lower = key.lowercased()
        if lower.contains("claude") || lower.contains("anthropic") {
            return Color(red: 0.85, green: 0.45, blue: 0.3)
        } else if lower.contains("codex") || lower.contains("openai") || lower.contains("gpt") {
            return Color(red: 0.1, green: 0.7, blue: 0.5)
        } else if lower.contains("opencode") {
            return Color(red: 0.2, green: 0.6, blue: 0.9)
        } else if lower.contains("pi") {
            return Color(red: 0.65, green: 0.35, blue: 0.85)
        } else if lower.contains("qoder") {
            return Color(red: 0.9, green: 0.6, blue: 0.1)
        } else if lower.contains("trae") {
            return Color(red: 0.3, green: 0.5, blue: 0.95)
        } else {
            return tokens.highlight
        }
    }

    private func breakdownCard(
        _ title: String,
        icon: String,
        groups: [WarrenUsageGroup],
        selectedKey: String? = nil,
        onSelect: ((WarrenUsageGroup) -> Void)? = nil
    ) -> some View {
        let peak = groups.map(\.buckets.total).max() ?? 0
        let total = groups.map(\.buckets.total).reduce(0, +)
        return VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(spacing: WarrenSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
                Text(title)
                    .font(WarrenTypography.settingsGroupLabel)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
                if !groups.isEmpty {
                    Text("\(groups.count)")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .padding(.bottom, WarrenSpacing.xxs)

            if groups.isEmpty {
                Text("No activity recorded")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, WarrenSpacing.large)
            } else {
                VStack(spacing: WarrenSpacing.compact) {
                    ForEach(groups.prefix(6)) { group in
                        groupRow(
                            group,
                            peak: peak,
                            total: total,
                            isSelected: selectedKey == group.key,
                            onSelect: onSelect != nil ? { onSelect?(group) } : nil
                        )
                    }
                }
                if groups.count > 6 {
                    Text("+\(groups.count - 6) more")
                        .font(WarrenTypography.settingsGroupLabel)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.top, WarrenSpacing.xxs)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
        )
    }

    private func groupRow(
        _ group: WarrenUsageGroup,
        peak: Int64,
        total: Int64,
        isSelected: Bool = false,
        onSelect: (() -> Void)? = nil
    ) -> some View {
        let share = total > 0 ? Double(group.buckets.total) / Double(total) : 0
        let dotColor = brandColor(for: group.key)

        return VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            HStack(spacing: WarrenSpacing.small) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)

                Text(group.displayName)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(isSelected ? tokens.highlight : tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: WarrenSpacing.xs)

                Text(WarrenUsageFormatting.percent(share))
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .monospacedDigit()

                Text(WarrenUsageFormatting.money(group.cost))
                    .font(WarrenTypography.settingsBody)
                    .foregroundStyle(tokens.foreground)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                let ratio = peak > 0 ? CGFloat(group.buckets.total) / CGFloat(peak) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tokens.muted.opacity(0.35))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [dotColor.opacity(0.9), dotColor.opacity(0.65)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * ratio, ratio > 0 ? 2 : 0))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, onSelect != nil ? 6 : 0)
        .padding(.vertical, onSelect != nil ? 4 : 0)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? tokens.highlight.opacity(0.10) : Color.clear)
        )
        .overlay(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tokens.highlight.opacity(0.40), lineWidth: WarrenSpacing.hairline)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
        .help(
            "\(group.displayName)\n\(WarrenUsageFormatting.exact(group.buckets.total)) tokens\n"
                + WarrenUsageFormatting.money(group.cost)
                + (onSelect != nil ? "\nClick to filter" : "")
        )
    }

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
        .padding(.horizontal, WarrenSpacing.xxs)
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
